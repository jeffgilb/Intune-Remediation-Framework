<# 
.SYNOPSIS
    Intune Remediation detection script template.

.DESCRIPTION
    This script template provides a starting point for creating Intune Remediation scripts.

.FEATURES
    - CMTrace-compatible logging
    - Automatic relaunch in 64-bit PowerShell when required
    - Remediation run counter
    - Remediation result tracking in the registry
    - Transcript logging support for troubleshooting

    Registry Checkpoint Location:
        HKLM:\SOFTWARE\IntuneRemediations\<LogName>

    Log File:
        <SystemDrive>\Logs\IR\<LogName>.log

    Verbose Log File (optional):
        <SystemDrive>\Logs\IR\<LogName>_verbose.log

    Registry Checkpoint Values:
        - Detection result
        - Detection run time timestamps
        - Runtime duration
        - Detection results
        - Script version
        - Script exit code

Exit Codes:
0 = Compliant
1 = Non-compliant
2 = Error encountered

Intune Output:
Messages logged with the -StdOut switch are returned to the Intune admin center.
#>

#region Logging
# Template logging function for the Intune detection script
# * DO NOT MODIFY  *
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
        $dir = Split-Path -Path  $logFile -Parent 
      # Ensure log directory exists
        New-Item -ItemType Directory -Path $dir -Force | Out-Null 
      # Write message to the log file
        $logLine | Out-File -LiteralPath $logFile -Append -Encoding UTF8
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

#region Template Helpers
# Template helper functions for the Intune detection script
# * DO NOT MODIFY  *
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
        [datetime]$EndTime,
        [string]$exitCode
    )

    try{
        if (-not (Test-Path $BaseKey)) { New-Item -Path $BaseKey -Force | Out-Null }
        $DurationSeconds = [math]::Round((($EndTime).ToUniversalTime() -
        ($StartTime).ToUniversalTime()).TotalSeconds, 2)

        if ($exitCode -ne 0) {
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
            DetectionScriptExitCode = $exitCode
        }

        foreach ($Property in $Properties.GetEnumerator()) {
            New-ItemProperty `
                -Path $BaseKey `
                -Name $Property.Key `
                -Value $Property.Value `
                -PropertyType String `
                -Force | Out-Null
        }
    
        Write-Log "*****       End of detection script actions       *****"
    }
    catch {
        Write-Log "Failed to write detection registry result: $($_.Exception.Message)" -Type 2
        Write-Log "*****       End of detection script actions       *****"
        $exitCode = 2
    }
}

function Remove-ExpiredRemediationLog {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateRange(0, 36500)]
        [int] $RetainDays = 30
    )

	if ($exitCode -eq 1) { # Do not delete the log  
        return
    }
        
    $BaseKey = Join-Path -Path $StateKey -ChildPath $logName

	if (-not (Test-Path -LiteralPath $BaseKey)) {
    	Remove-Item -LiteralPath $LogFile -Force
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
#endregion Template Helpers

#region Your Helpers

# Your helper functions for the Intune detection script go here

#endregion Your Helpers

#---------------------------------------------- BEGIN ----------------------------------------------|

# ---      Script Configuration     ---
# * MODIFY THESE AS NEEDED *
$ScriptVersion          = "1.0.0"                               # Version of the script
$logPath                = "$env:SystemDrive\Logs\IR"            # Ensure this path is pulled with Intune collects diagnostics
$logName                = "MyRemediation"                      # Name of the log file
$StateKey               = "HKLM:\SOFTWARE\IntuneRemediations"   # Base registry key for storing remediation state
$InteractiveLogging     = $false                                # Enable/disable display console output for troubleshooting (DO NOT deploy as $true)
$verboseLogging         = $false                                # Enable/disable script transcript for troubleshooting
$retainDays             = 30                                    # How long to retain logs after a successful remediation has run (default is 30 days)
# -------------------------------------

#region Do Not Modify
# * DO NOT MODIFY THESE  * 
$ErrorActionPreference  = 'Stop'                                # Ensures try/catch works reliably [do not modify]
$logFile                = Join-Path $logPath "$logName.log"     # Full path to the log file [do not modify]
$baseKey                = Join-Path $StateKey "$logName"        # Base registry key for storing remediation state [do not modify]
$exitCode               = 0                                     # Intitalize exit code for compliance [do not modify]
$StartTime              = Get-Date                              # Record script execution start time [do not modify]
$detectionOutput = [System.Collections.Generic.List[string]]::new() # Detection output to display in Intune admin center [do not modify]
Restart-64Bit                                                   # Ensure we are running as a 64-bit process on an x64 system [do not modify]
if ($verboseLogging) { Start-Transcript -Path (Join-Path $logPath "${logName}_verbose.log") -Append }  
Write-Log "*****      Starting detection script actions.     *****"  -Component 'Detection Begin'
Write-Log "Detection script version: $ScriptVersion" -Component 'Version'
# -------------------------------------
#endregion Do Not Modify

try { 
    <#  INSTRUCTIONS:
        - Only modify the detection content within this Try block!
        - You only need to check for failures. If checks fail, set $exitCode = 1. If script fails, set $exitCode = 2. 
        - Use Write-Log to output messages to the log (also ouputs to the console if $InteractiveLogging is $true).
        If you want to include the output in the Intune admin center's detection output, add -StdOut 
        to the end of the line. Max length of all aggregated messages is 2,048 characters total. 

    # ----------------------------------------------------
    # --------- Your detection logic starts here ---------  
    # --------------------------------------------------#>





    # ----------------------------------------------------
    # ----------   End of your detection logic  ----------  
    # ----------------------------------------------------
    
  # Compliance Result * DO NOT MODIFY  *
    if ($exitCode -eq 0) { # Log will not be saved if there are no issues to log and the device hasn't been non-compliant recently.
        Write-Log "[PASS] The device is compliant." -StdOut # Intune detection output 
        exit $exitCode
    } elseif ($exitCode -eq 2){ # Script failure
        Write-Log "[FAIL] The device is non-compliant due to a script failure." -Type 3 -StdOut
        exit $exitCode
    } else { # Device is not compliant
        Write-Log "[FAIL] The device is non-compliant."
        exit $exitCode
    }
} catch { # * DO NOT MODIFY  *
    $exitCode = 2
    Write-Log "[ERROR] $($_.Exception.Message)" -Type 3 -StdOut
    exit $exitCode
} finally {  # * DO NOT MODIFY  *
    $EndTime = Get-Date
  # Create registry checkpoint for detection results
    Detection-Result -logName $logName -ScriptVersion $ScriptVersion -StartTime $StartTime -EndTime $EndTime -exitCode $exitCode
  # Delete existing remediation logs for issues that have been remediated longer than $retainDays ago.
    Remove-ExpiredRemediationLog -RetainDays $retainDays
    Write-Output ($detectionOutput -join " | ")     # Intune detection output
    if ($verboseLogging) { Stop-Transcript }
}

