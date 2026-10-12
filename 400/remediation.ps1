<#
.SYNOPSIS
    Intune Remediation script that restores the Update Session Orchestrator (UsoSvc)
    service to a compliant state.

.DESCRIPTION
    This script remediates devices where the UsoSvc service is not configured
    correctly. It verifies the service exists, ensures the startup type is set
    to Automatic, and confirms the service is running.

    Activity is logged to a CMTrace-compatible log file and remediation results
    are written to the registry for historical tracking and reporting.
    Each execution generates a unique RunId and maintains a remediation run count
    to assist with troubleshooting and trend analysis.

.FEATURES
    - CMTrace-compatible logging
    - Automatic relaunch in 64-bit PowerShell when required
    - Service startup type remediation
    - Service state remediation
    - Registry-based remediation history and telemetry
    - Remediation run counter
    - Transcript logging support for troubleshooting

.NOTES
    Registry Location:
        HKLM:\SOFTWARE\Intune\Remediations\<LogName>

    Log File:
        <SystemDrive>\Logs\IR\<LogName>.log

    Recorded Metadata:
        - RunId (correlation identifier)
        - RunCount
        - Remediation result
        - Runtime duration
        - Remediation timestamps
        - Last detection failure details
        - Script version

    Version: 1.0.0
    Author: Jeff Gilbert

.REMEDIATION ACTIONS
    1. Validate the target service exists.
    2. Change the startup type to Automatic if required.
    3. Start the service if it is not running.
    4. Verify the service is compliant after remediation.
    5. Store remediation telemetry in the registry.

.EXIT CODES
0 = Remediation successful
1 = Remediation failed
2 = Error encountered or service unavailable

.PARAMETER ServiceName
    Name of the Windows service to remediate. Default: UsoSvc.

.AUTHOR
    Jeff Gilbert

.VERSION
    1.0.0
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
        [Parameter(Mandatory = $false, Position = 1)]   [string] $Component = "Remediation",
        [Parameter(Mandatory = $false, Position = 2)]   [ValidateSet(1, 2, 3)]      [int] $Type = 1,
        [Parameter(Mandatory = $false)]                 [switch] $StdOut
    )
  # Capture once to avoid drift between Time/Date
    $now = Get-Date 
    $Time = $now.ToString('HH:mm:ss.ffffff', [System.Globalization.CultureInfo]::InvariantCulture)
    $Date = $now.ToString('MM-dd-yyyy',      [System.Globalization.CultureInfo]::InvariantCulture)
  # Escape message for CMTrace payload (XML-like). SecurityElement.Escape handles &, <, >, " (quotes) safely
    $escapedMessage = [System.Security.SecurityElement]::Escape($Message)
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

function Increment-RemediationRunCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogName
    )

    try {
        $baseKey = "HKLM:\SOFTWARE\Intune\Remediations\$LogName"
        if (-not (Test-Path -LiteralPath $baseKey)) { New-Item -Path $baseKey -Force | Out-Null }
        
        $existing = Get-ItemProperty -Path $baseKey -Name "RunCount" -ErrorAction SilentlyContinue
        $currentCount = if ($null -ne $existing) { [int]$existing.RunCount } else { 0 }

        $newCount = $currentCount + 1

        New-ItemProperty `
            -Path $baseKey `
            -Name "RunCount" `
            -Value $newCount `
            -PropertyType DWord `
            -Force | Out-Null

        return $newCount
    }
    catch {
        Log "Failed to increment remediation run count: $($_.Exception.Message)" -Type 2
        return 0
    }
}

function Remediation-Result {
    param(
        [string]$LogName,
        [string]$ScriptVersion,
        [string]$RunId,
        [string]$LastRemediationResult,
        [datetime]$StartTime,
        [datetime]$EndTime = (Get-Date),
        [int]$ExitCode = 0,
        [string]$Details = ""       
    )

    try {
        $BaseKey = Join-Path $StateKey $logName
        if (-not (Test-Path $BaseKey)) { New-Item -Path $BaseKey -Force | Out-Null }
        $DurationSeconds = [math]::Round((($EndTime).ToUniversalTime() -
        ($StartTime).ToUniversalTime()).TotalSeconds, 2)

        $LastDetectionFailure = (Get-ItemProperty -Path $baseKey -Name "DetectionState" -ErrorAction SilentlyContinue).DetectionState

        if ($RemediationSucceeded -ne $true) {
            $RemediationResult = "Fail"
            $RemediationDetails = ($detectionOutput -join " | ")
        } else {
            $RemediationResult = "Pass"
            $RemediationDetails = "[PASS] All checks successful"
        }

        $properties = [ordered]@{
            LastDetectionFailure        = $LastDetectionFailure
            RemediationDetails          = $RemediationDetails
            RemediationResult           = $RemediationResult
            RemediationBeginTimeUtc     = $StartTime.ToUniversalTime().ToString("o")
            RemediationEndTimeUtc       = $EndTime.ToUniversalTime().ToString("o")
            RemediationRuntimeSeconds   = $durationSeconds.ToString()
            RemediationExitCode         = $ExitCode.ToString()
            RunId                       = $RunId
            RemediationScriptVersion    = $ScriptVersion
        }

        foreach ($property in $properties.GetEnumerator()) {
            New-ItemProperty `
                -Path $baseKey `
                -Name $property.Key `
                -Value $property.Value `
                -PropertyType String `
                -Force | Out-Null
        }

        New-ItemProperty `
            -Path $baseKey `
            -Name "RunCount" `
            -Value ([int]$script:RunCount) `
            -PropertyType DWord `
            -Force | Out-Null

        Write-Log "Registry checkpoint updated: $baseKey"
        
    }
    catch {
        Write-Log "Failed to write remediation registry result: $($_.Exception.Message)" -Type 2
    }
}

#endregion Helpers

#region Config
# --- Standard Variable Definitions ---
$ScriptVersion      = "1.0.0"                       # Script version
$logPath            = "$env:SystemDrive\Logs\IR"    # Ensure this path is pulled with Intune collects diagnostics
$logName            = "UsoSvcRemediation"           # Name of the log file
$StateKey           = "HKLM:\SOFTWARE\Intune\Remediations" # Base registry key for storing remediation state
# -------------------------------------

# ---   Remediation Specific vars   ---
$ServiceName        = "UsoSvc"                      # Service name to check
# -------------------------------------

# --- General Configuration ---
$ErrorActionPreference  = 'Stop'                    # Ensures try/catch works reliably
$InteractiveLogging     = $true                     # Display console output for troubleshooting
$verboseLogging         = $false                    # Enables script transcript for troubleshooting
$RemediationSucceeded   = $true                     # Intitalize remediation state
$RunId = [guid]::NewGuid().ToString()               # Generates a new Correlation Id (CID) on every run
Restart-64Bit                                       # Ensure we are running as a 64-bit process on an x64 system    
$StartTime              = Get-Date                  # Record script execution start time
$RunCount = Increment-RemediationRunCount -LogName $logName # Keep track of how many times this script has run
# -------------------------------------

#endregion Config

#---------------------------------------------- BEGIN ----------------------------------------------|
if ($verboseLogging) { Start-Transcript -Path (Join-Path $logPath "${logName}_verbose.log") }  
Write-Log "*****    Starting remediation for service $ServiceName.    *****" 
Write-Log "Remediation script version: $ScriptVersion." -Component "Version"
Write-Log "RunId: $RunId" 
Write-Log "Remediation Run Count: $RunCount"

# Get startup type via WMI/Win32_Service
try {
    $service = Get-Service -Name $ServiceName
    if (-not $service) {
        Write-Log "[FAIL] $ServiceName Service missing." -Type 3
        exit 2
    }

    $svcConfig = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop  
    if (-not $svcConfig) {
        Write-Log -Message "Service config unavailable — cannot remediate." -Type 3
        exit 2
    }

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
            Write-Log "$_" -Type 3
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
            Write-Log "$_" -Type 3
            exit 2
        }
    }

    # 3. Post-check for telemetry and confidence
    if ($svcConfig.StartMode -eq "Auto" -and
        $service.Status -eq "Running") {
        Write-Log "Remediation successful. The $ServiceName Service now starts automatically and is running." 
        exit 0
    } else {
        Write-Log "Remediation failed — service not in desired state." -Type 3
        $RemediationSucceeded = $false
        exit 1
    }
} catch {
    Write-Log "$_" -Type 3
    Exit 2
} finally {
    $EndTime = Get-Date
    Remediation-Result -logName $logName -ScriptVersion $ScriptVersion -StartTime $StartTime -EndTime $EndTime -RunId $RunId
    if ($verboseLogging) { Stop-Transcript }
}