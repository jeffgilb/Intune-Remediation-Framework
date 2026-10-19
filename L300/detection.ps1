<#
.SYNOPSIS
Detects whether the Windows Update service (wuauserv) is configured and running as expected.

.DESCRIPTION
Validates that the Windows Update service exists, is configured for Automatic startup,
and is currently Running. Results are logged in CMTrace format and summarized to the
Intune admin center. A log file is removed automatically when the device is compliant.

.NOTES
Version : 1.0.0
Author  : Jeff Gilbert

Exit Codes:
0 = Compliant
1 = Non-compliant
2 = Detection error

Intune Output:
Messages logged with the -StdOut switch are returned to the Intune admin center.
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
$ScriptVersion          = "1.0.0"                       # Version of the script
$InteractiveLogging     = $false                         # Display console output for testing 
$compliant              = $true                         # Intitalize compliance state
$detectionOutput = [System.Collections.Generic.List[string]]::new() # list of remediation detection output to display in Intune admin center
Restart-64Bit                                           # Ensure we are running as a 64-bit process on an x64 system 
# -------------------------------------

#---------------------------------------------- BEGIN ----------------------------------------------|
  
Write-Log "*****     Starting detection script actions.     *****" 
Write-Log "Detection script version: $ScriptVersion" -Component 'Version'

# Service name to check
$ServiceName = "UsoSvc"
# Update Orchestrator Service. Manages Windows Updates. If stopped, 
# your devices will not be able to download and install the latest updates.

try {

  # Get startup type via WMI/Win32_Service
    $svcConfig = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop  
    if (-not $svcConfig) {
        Write-Log -Message "Service config unavailable — cannot remediate." -Type 3 -StdOut
        $compliant = $false
    } else {
        if ($svcConfig.StartMode -ne "Auto") { # e.g. 'Automatic', 'Manual', 'Disabled'
            Write-Log "[FAIL] The $ServiceName StartMode is $($svcConfig.StartMode) (expected Auto)" -Type 3 -StdOut
            $compliant = $false
        }
        if ($svcConfig.State -ne "Running") { # e.g. 'Running', 'Stopped'
            Write-Log "[FAIL] The $ServiceName Service state is $($svcConfig.State) (expected Running)" -Type 3 -StdOut
            $compliant = $false
        }
    }

    if ($compliant) {
        Write-Log "[PASS] The $ServiceName Service is compliant." -StdOut
      # Delete unnecessary log for a succesful detection  
        if (Test-Path $LogFile) { Remove-Item -Path $LogFile -Force }
        exit 0
    } else {
        Write-Log "*****      End of detection script actions.      *****"  -Component "Detection End"
        exit 1
    }
} catch {
    Write-Log "[ERROR] $($_.Exception.Message)" -Type 3 -StdOut
    exit 2
} finally {
    Write-Output ($detectionOutput -join " | ") # This is all the StdOut lines displayed in the Intune admin center's detection output
}


