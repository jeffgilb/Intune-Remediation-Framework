<#
.SYNOPSIS
Remediates the UsoSvc (Update Orchestrator Service) configuration.

.DESCRIPTION
Ensures the specified service exists, is configured to start
automatically, and is currently running. Actions are performed
only when required (idempotent). Logs all activity in CMTrace-
compatible format and returns appropriate exit codes for
Intune Remediations reporting.

.NOTES
Version: 1.0.0
Author: Jeff Gilbert

.EXITCODES
0 = Service compliant or successfully remediated
1 = Remediation attempted but desired state not achieved
2 = Service missing, unavailable, or unexpected error occurred
#>

#region Logging
function Write-Log {

    #-- THIS FUNCTION REQUIRES THE FOLLOWING BE DECLARED IN THE MAIN SCRIPT --#
    # $logPath                                                              
    # $logName                                                              
    # $detectionOutput = [System.Collections.Generic.List[string]]::new() 
    #-------------------------------------------------------------------------#

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]    [ValidateNotNullOrEmpty()]  [string] $Message,
        [Parameter(Mandatory = $false, Position = 1)]   [string] $Component = "Detection",
        [Parameter(Mandatory = $false, Position = 2)]   [ValidateSet(1, 2, 3)]      [int] $Type = 1,
        [Parameter(Mandatory = $false)]                 [switch] $StdOut
    )
  # Capture once to avoid drift between Time/Date
    $now = Get-Date 
    $Time = $now.ToString('HH:mm:ss.ffffff', [System.Globalization.CultureInfo]::InvariantCulture)
    $Date = $now.ToString('MM-dd-yyyy',      [System.Globalization.CultureInfo]::InvariantCulture)
  # Escape message for CMTrace payload (XML-like). SecurityElement.Escape handles &, <, >, " (quotes) safely
    $escapedMessage = [System.Security.SecurityElement]::Escape($Message).Replace('&apos;', "'")
  # Identify if it was a function that called Log and make it the component"
    $scriptFullPath = $PSCommandPath ; $scriptName = Split-Path -Path $scriptFullPath -Leaf
    $caller = (Get-PSCallStack)[1].Command
    if (-not ($caller -eq $scriptName)){ $Component = $caller }  
  # Build CMTrace entry (keep empty attributes as per CMTrace spec)
    $logLine = ('<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="" file="">' `
                -f $escapedMessage, $Time, $Date, $Component, $Type)
    try { 
      # Write the log entry
        $script:logFile = Join-Path $logPath "$logName.log"
        $dir = Split-Path -Path  $logFile -Parent 
      # Ensure log directory exists
        New-Item -ItemType Directory -Path $dir -Force | Out-Null 
      # Write message to the log file
        Add-Content -LiteralPath $logFile -Value $logLine -Encoding UTF8
      # Add message to detection results sent to the Intune admin center  
        if ($StdOut) { $detectionOutput.Add($Message) }
      # Write all log lines to console for interactive testing/transcript capture
        if ($InteractiveLogging) {
            switch ($Type) {
                1 { Write-Host $Message -ForegroundColor Gray }
                2 { Write-Host $Message -ForegroundColor Yellow }
                3 { Write-Host $Message -ForegroundColor Red }
                default { Write-Host $Message }
            }
        }
    }
    catch { # If writing fails write error
        Write-Error -Message ("Failed to write log to '{0}': {1}" -f $logFile, $_.Exception.Message)
        return
    }
}
#endregion Logging

#region Helpers
function Restart-64Bit {
    # If we are running as a 32-bit process on an x64 system, re-launch as a 64-bit process first
    if ("$env:PROCESSOR_ARCHITEW6432" -ne "ARM64") {
        if (Test-Path "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe") {
            & "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy bypass -NoProfile -File "$PSCommandPath"
            Exit $lastexitcode
            }
        }
}

#endregion Helpers

# ---      Script Configuration     ---
$ErrorActionPreference  = 'Stop'                        # Ensures try/catch works reliably
$logPath                = "$env:SystemDrive\Logs\IR"    # Ensure this path is pulled with Intune collects diagnostics
$logName                = "UsoSvcRemediation"           # Name of the log file
$ScriptVersion          = "1.0.0"                       # Script version
$InteractiveLogging     = $true                         # Display console output for testing 
Restart-64Bit                                           # Ensure we are running as a 64-bit process on an x64 system    
# -------------------------------------

#---------------------------------------------- BEGIN ----------------------------------------------|

Write-Log "*****    Starting remediation script actions.    *****" 
Write-Log "Remediation script version: $ScriptVersion." -Component "Version"



try {
    # Service name to check
    $ServiceName = "UsoSvc"
    # Update Orchestrator Service. Manages Windows Updates. If stopped, 
    # your devices will not be able to download and install the latest updates.

  # Get startup type via WMI/Win32_Service
    $svcConfig = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop  
    if (-not $svcConfig) {
        Write-Log -Message "Service config unavailable — can not remediate." -Type 3 -StdOut
    } else {
        # 1. Fix startup type (idempotent)
        if ($svcConfig.StartMode -notin @("Auto", "Automatic")) { # CIM reports 'Auto'; ChangeStartMode accepts 'Automatic'
            Write-Log "Changing StartMode from $($svcConfig.StartMode) to Automatic."
            try {
                $changeResult = Invoke-CimMethod -InputObject $svcConfig -MethodName ChangeStartMode -Arguments @{ StartMode = 'Automatic' }
                if ($changeResult.ReturnValue -ne 0) {
                    throw "ChangeStartMode failed with return value $($changeResult.ReturnValue)."
                }
                $svcConfig = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
            } catch {
                Write-Log "$($_.Exception.Message)" -Type 3
                exit 1
            }
        }

        # 2. Ensure service is running (idempotent)
        Write-Log "Verifying the $ServiceName Service is running."
        $service = Get-Service -Name $ServiceName
        if (-not $service) {
            Write-Log "The $ServiceName Service disappeared after StartMode change — aborting." -Type 3
            exit 1
        }

        if ($service.Status -ne 'Running') { # e.g. 'Running', 'Stopped'
            Write-Log "The $ServiceName Service is not running (current state: $($service.Status))." -Type 2
            try {
                Start-Service -Name $ServiceName -ErrorAction Stop
                $service = Get-Service -Name $ServiceName
                $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
                $service = Get-Service -Name $ServiceName
            } catch {
                Write-Log "$($_.Exception.Message)" -Type 3
                exit 2
            }
        }

        # 3. Post-check for telemetry and confidence
        if ($svcConfig.StartMode -eq "Auto" -and
            $service.Status -eq "Running") {
            Write-Log "Remediation successful — the $ServiceName Service starts automatically and is running." 
            exit 0
        } else {
            Write-Log "Remediation failed — service not in desired state." -Type 3
            exit 1
        }
    }
} catch {
    Write-Log "$($_.Exception.Message)" -Type 3
    Exit 2
} finally {
    Write-Log "*****     End of remediation script actions.     *****"
}