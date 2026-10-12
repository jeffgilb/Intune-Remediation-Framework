<#
.SYNOPSIS
    Intune Remediation detection script for validating the USO (Update Session Orchestrator) service configuration.

.DESCRIPTION
    Verifies that the specified Windows service exists, is configured for Automatic startup,
    and is currently running. Results are logged in CMTrace-compatible format, written to
    the registry for historical tracking, and returned to the Intune admin center through
    standard output.

    The script includes helper functions for:
      - CMTrace-style logging
      - 64-bit PowerShell relaunch
      - Detection result tracking in the registry
      - Automatic cleanup of stale remediation logs

.NOTES
    Detection results are stored under:
        HKLM:\SOFTWARE\Intune\Remediations

    Detection output written with the -StdOut switch is displayed in the
    Intune admin center.

    Version: 1.0.0
    Author: Jeff Gilbert

.EXIT CODES
0 = Compliant
1 = Non-compliant (remediation required)
2 = Error or service configuration unavailable
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

function Detection-Result {
    param(
        [string]$logName,
        [string]$ScriptVersion,
        [datetime]$StartTime,
        [datetime]$EndTime
    )

    $BaseKey = Join-Path $StateKey $logName
    if (-not (Test-Path $BaseKey)) { New-Item -Path $BaseKey -Force | Out-Null }
    $DurationSeconds = [math]::Round((($EndTime).ToUniversalTime() -
    ($StartTime).ToUniversalTime()).TotalSeconds, 2)

    if ($compliant -ne $true) {
        $DetectionResult = "Fail"
        $details = ($detectionOutput -join " | ")
    } else {
        $DetectionResult = "Pass"
        $details = "[PASS] All checks successful"
    }

    $Properties = @{
        DetectionValue          = $DetectionResult
        DetectionEndTimeUtc     = $EndTime.ToUniversalTime().ToString("o")
        DetectionRuntimeSeconds = $DurationSeconds
        DetectionBeginTimeUtc   = $StartTime.ToUniversalTime().ToString("o")
        DetectionState          = $details
        DetectionScriptVersion  = $ScriptVersion
    }

    foreach ($Property in $Properties.GetEnumerator()) {
        New-ItemProperty `
            -Path $BaseKey `
            -Name $Property.Key `
            -Value $Property.Value `
            -PropertyType String `
            -Force | Out-Null
    }
}

function Remove-ExpiredRemediationLog {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateRange(0, 36500)]
        [int] $RetainDays = 30
    )

    if (-not (Test-Path -LiteralPath $BaseKey)) {
        Write-Log "Registry key not found: $BaseKey" -Type 2
        return
    }

    $keyProperties = Get-ItemProperty -LiteralPath $BaseKey
    $resultProperty = $keyProperties.PSObject.Properties['RemediationResult']
    if ($null -eq $resultProperty) { # No remediation was recorded, so remove the unnecessary log.
        if (Test-Path -LiteralPath $LogFile) {
            if ($PSCmdlet.ShouldProcess($LogFile, 'Delete log with no remediation result')) {
                Remove-Item -LiteralPath $LogFile -Force
            }
        }
        return
    } else { # A remediation has occured, let's see how long ago.
        $lastRunTime = Get-ItemPropertyValue -LiteralPath $BaseKey `
            -Name 'RemediationBeginTimeUtc' -ErrorAction SilentlyContinue

        $lastRun = [DateTimeOffset]::MinValue
        if ([string]::IsNullOrWhiteSpace($lastRunTime) -or
            -not [DateTimeOffset]::TryParse(
                $lastRunTime,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None,
                [ref]$lastRun
            )) {
            Write-Warning "RemediationBeginTimeUtc is missing or invalid in $BaseKey; keeping the log."
            return
        }
        $cutOff = [DateTimeOffset]::UtcNow.AddDays(-$RetainDays)
        if ($lastRun -lt $cutOff -and (Test-Path -LiteralPath $LogFile)) {
            if ($PSCmdlet.ShouldProcess($LogFile, "Delete log older than $RetainDays days")) {
                Remove-Item -LiteralPath $LogFile -Force
            }
        }
    }
}
#endregion Helpers

#region Config
# --- Standard Variable Definitions ---
$ScriptVersion      = "1.0.0"                       # Version of the script
$logPath            = "$env:SystemDrive\Logs\IR"    # Ensure this path is pulled with Intune collects diagnostics
$logName            = "UsoSvcRemediation"           # Name of the log file
$StateKey           = "HKLM:\SOFTWARE\Intune\Remediations" # Base registry key for storing remediation state
# -------------------------------------

# ---   Remediation Specific vars   ---
$ServiceName        = "UsoSvc"                      # Service name to check
# -------------------------------------

# ---     General Configuration     ---
$ErrorActionPreference  = 'Stop'                    # Ensures try/catch works reliably
$InteractiveLogging     = $true                     # Display console output for troubleshooting 
$verboseLogging         = $false                    # Enables script transcript for troubleshooting
$compliant              = $true                     # Intitalize compliance state
$detectionOutput = [System.Collections.Generic.List[string]]::new() # list of remediation detection output to display in Intune admin center
Restart-64Bit                                       # Ensure we are running as a 64-bit process on an x64 system 
$StartTime = Get-Date
# -------------------------------------
#endregion Config

#---------------------------------------------- BEGIN ----------------------------------------------|
if ($verboseLogging) { Start-Transcript -Path (Join-Path $logPath "${logName}_verbose.log") }  
Write-Log "***** Starting detection for the $ServiceName service *****" -Component 'Detection Begin'
Write-Log "Detection script version: $ScriptVersion" -Component 'Version'

try {
  # Detection logic goes here
    $service = Get-Service -Name $ServiceName
    if (-not $service) {
        Write-Log "[FAIL] $ServiceName Service missing." -Type 3 -StdOut
        exit 2
    }

    $svcConfig = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop  
    if (-not $svcConfig) {
        Write-Log -Message "Service config unavailable — cannot remediate." -Type 3 -StdOut
        exit 2
    }

    if ($svcConfig.StartMode -ne "Auto") { # e.g. 'Automatic', 'Manual', 'Disabled'
        Write-Log "[FAIL] The $ServiceName StartMode is $($svcConfig.StartMode) (expected Auto)" -Type 3 -StdOut
        $compliant = $false
    }

    if ($svcConfig.State -ne "Running") { # e.g. 'Running', 'Stopped'
        Write-Log "[FAIL] The $ServiceName Service state is $($svcConfig.State) (expected Running)" -Type 3 -StdOut
        $compliant = $false
    }

  # Compliance Result
    if ($compliant) {
        Write-Log "[PASS] The $ServiceName Service is compliant." -StdOut
      # How long do you want to retain logs after a successful remediation has run?  
        $retainDays = 30
      # Delete remediation logs that have been remediated longer than $retainDays ago
        Remove-ExpiredRemediationLog
        exit 0
    } else { # Device is not compliant
        Write-Log "[FAIL] The $ServiceName Service is non-compliant." -Type 3 -StdOut
        Write-Log "*****              End of detection actions             *****" -Component "Detection End"
        exit 1
    }
} catch {
    Write-Log "[ERROR] $_" -Type 3 -StdOut
    exit 2
} finally {
    $EndTime = Get-Date
    Detection-Result -logName $logName -ScriptVersion $ScriptVersion -StartTime $StartTime -EndTime $EndTime
    Write-Output ($detectionOutput -join " | ") # This is all the StdOut lines displayed in the Intune admin center's detection output
    if ($verboseLogging) { Stop-Transcript }
}
