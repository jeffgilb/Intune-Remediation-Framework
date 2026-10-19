<#
.SYNOPSIS
    Standard Intune Remediation Script Template with CMTrace-compatible logging 
    and registry checkpoint reporting.

.DESCRIPTION
    This script template provides a starting point for creating Intune Remediation scripts.

.FEATURES
    - CMTrace-compatible logging
    - Automatic relaunch in 64-bit PowerShell when required
    - Remediation run counter
    - Remediation result tracking in the registry
    - Transcript logging support for troubleshooting

.NOTES
    Registry Location:
        HKLM:\SOFTWARE\IntuneRemediations\<LogName>

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

.EXIT CODES
    0 = Remediation successful
    1 = Remediation failed
    2 = Error encountered

#>

#region Logging
# Template logging function for the Intune remediation script
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
        [Parameter(Mandatory = $false, Position = 1)]   [string] $Component = "Remediation",
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

#region Helpers
function Restart-64Bit {
    # If we are running as a 32-bit process on an x64 system, re-launch as a 64-bit process first
    if ("$env:PROCESSOR_ARCHITEW6432" -ne "ARM64") {
        if (Test-Path "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe") {
            & "$(C:\WINDOWS)\SysNative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy bypass -NoProfile -File "$PSCommandPath"
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
        Write-Log "Failed to increment remediation run count: $($_.Exception.Message)" -Type 2
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
        [string]$Details = "".
        [string]$exitCode
    )

    try {
        if (-not (Test-Path $baseKey)) { New-Item -Path $baseKey -Force | Out-Null }
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
            RemediationRuntimeSeconds   = $DurationSeconds.ToString()
            RunId                       = $RunId
            RemediationScriptVersion    = $ScriptVersion
            RemediationScriptExitCode   = $exitCode
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
        Write-Log "*****     End of remediation script actions.     *****"
    }
    catch {
        $exitCode = 2    
        Write-Log "Failed to write remediation registry result: $($_.Exception.Message)" -Type 2
        Write-Log "*****     End of remediation script actions.     *****"
    }
}

#endregion Helpers

#region Your Helpers

# Your helper functions for the Intune remediation script go here

#endregion Your Helpers


#---------------------------------------------- BEGIN ----------------------------------------------|
# ---      Script Configuration     ---
# * MODIFY THESE AS NEEDED *
$scriptVersion      = "1.0.0"                       # Script version
$logPath            = "$env:SystemDrive\Logs\IR"    # Log path must match the path in the detection script
$logName            = "contoso"                    # Log name must match the name in the detection script
$stateKey           = "HKLM:\SOFTWARE\IntuneRemediations" # Regkey must match the regkey in the detection script
$interactiveLogging = $true                        # Display console output for troubleshooting
$verboseLogging     = $false                        # Enables script transcript for troubleshooting
# -------------------------------------

#region Do Not Modify
# * DO NOT MODIFY THESE *
$ErrorActionPreference  = 'Stop'                    # Ensures try/catch works reliably [do not modify]
$logFile            = Join-Path $logPath "$logName.log" # Full path to the log file [do not modify]
$baseKey            = Join-Path $stateKey "$logName"    # Base registry key for storing remediation state [do not modify]
$exitCode           = 0                             # Intitalize exit code for compliance [do not modify]
$RunId = [guid]::NewGuid().ToString()               # Generates a new Correlation Id (CID) on every run [do not modify]
$detectionOutput = [System.Collections.Generic.List[string]]::new() # Detection output to display in Intune admin center [do not modify]
$StartTime          = Get-Date                      # Record script execution start time [do not modify]
Restart-64Bit                                       # Ensure we are running as a 64-bit process on an x64 system [do not modify]   
$RunCount = Increment-RemediationRunCount -LogName $logName # Keep track of how many times this script has run [do not modify]
if ($verboseLogging) { Start-Transcript -Path (Join-Path $logPath "${logName}_verbose.log") -Append }  
Write-Log "*****    Starting remediation script actions.    *****" 
Write-Log "Remediation script version: $scriptVersion." -Component "Version"
Write-Log "RunId: $RunId" 
Write-Log "Remediation Run Count: $RunCount"
# -------------------------------------
#endregion Do Not Modify

try {

    <#  INSTRUCTIONS:
    For any remediation failures:
     - Set $exitCode = 1 for remediation failures.
     - Set $exitCode = 2 for script failures.
     - Add -StdOut at the end of the Write-Log commands to append issues in the registry checkpoint RemediationDetails value
    
    # ----------------------------------------------------
    # --------- Your remediation logic goes here ---------  
    # --------------------------------------------------#>

    # example:
    $RegPath = "HKLM:\SOFTWARE\Contoso\Settings"
    $ValueName = "Enabled"

    if (-not (Test-Path $RegPath)) {
      # Create the registry key if it does not exist
        Write-Log "Contoso settings registry key not found." -Type 2
        New-Item -Path $RegPath -Force | Out-Null

      # Validate the regkey was successfully created
        If (-not (Test-Path $RegPath)) {
            Write-Log "Failed to create Contoso settings registry key." -Type 3 -StdOut
            $RemediationSucceeded = $false
            $exitCode = 1
        } else {
            Write-Log "Contoso settings registry key successfully created."
        }
    }
    
    if ((Get-ItemProperty -Path $RegPath).$ValueName -ne 1) {
      # Create the registry value if it does not exist
        New-ItemProperty -Path $RegPath -Name $ValueName -Value 1 -PropertyType DWord -Force | Out-Null

      # Validate the registry value was successfully created
        If ((Get-ItemProperty -Path $RegPath).$ValueName -ne 1) {
            Write-Log "Failed to set $ValueName to 1 in $RegPath." -Type 3 -StdOut
            $RemediationSucceeded = $false
            $exitCode = 1
        } else {
            Write-Log "$($ValueName) successfully set to 1 in $RegPath."
            $RemediationSucceeded = $true
        }
    } else {
        Write-Log "$ValueName is already set to 1 in $RegPath."
    }

    # ----------------------------------------------------
    # ---------   End of your remediation logic  --------- 
    # ----------------------------------------------------

} catch { # * DO NOT MODIFY  *
    $exitCode = 2
    Write-Log "[ERROR] $($_.Exception.Message)" -Type 3 -StdOut
    Write-Log "*****     End of remediation script actions.     *****"
} finally { # * DO NOT MODIFY  *
   $EndTime = Get-Date
  # Create registry checkpoint for remediation results
    Remediation-Result -logName $logName -ScriptVersion $ScriptVersion -StartTime $StartTime -EndTime $EndTime -RunId $RunId -exitCode $exitCode
    if ($verboseLogging) { Stop-Transcript }
}
