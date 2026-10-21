<#
.SYNOPSIS
Detects required Autopilot MDM Diagnostics custom log collection registry values and reports compliance.

.DESCRIPTION
This script is intended to be used as the **Detection** portion of a Microsoft Intune
Remediation. It validates the presence and configuration of custom MDM Diagnostics 
log collection registry entries used by Windows Autopilot diagnostics.

The script checks the following registry path:
HKLM:\SOFTWARE\Microsoft\MdmDiagnostics\Area\Autopilot\FileEntry

It verifies that specific REG_DWORD value names (log path wildcard entries) exist
and that each value is configured with decimal value 255 (maximum diagnostic collection).

If any required registry key or value is missing, unreadable, or misconfigured,
the script exits with a non-zero code, triggering remediation.

The script implements CMTrace-compatible logging and conditionally creates an
error log (_ERR.log) when non-compliance is detected.

.REQUIRED REGISTRY CONFIGURATION
Registry Key:
HKLM:\SOFTWARE\Microsoft\MdmDiagnostics\Area\Autopilot\FileEntry

Required REG_DWORD Values:
- %SystemDrive%\Logs* = 255
- %SystemRoot%\System32\config\systemprofile\AppData\Local\HPConnect\Logs* = 255
- %ProgramData%\Microsoft\EdgeUpdate\Log\*.log = 255

.LOGGING
Log File Location:
%SystemDrive%\Logs\IR

Log Files:
- CustomLogCollection.log        (created during detection)
- CustomLogCollection_ERR.log    (created only when non-compliant)

Logs are written in CMTrace-readable format and surfaced in Intune diagnostics
collection.

.DETECTION LOGIC
- Confirms the Autopilot FileEntry registry key exists
- Enumerates required registry value names
- Validates each value is readable and set to decimal 255
- Continues evaluation when individual values fail to ensure full reporting
- Produces PASS or FAIL output for Intune admin center visibility

.EXIT CODES
0  - Compliant (all required registry values present and correct)
1  - Not compliant (remediation required)

.NOTES
Author: Jeff Gilbert  
Date:   4.9.26

7.1.26  Added '%ProgramData%\Microsoft\EdgeUpdate\Log\*.log' to log collection locations.
#>

#-------------------------------------- Functions -------------------------------------
function Log {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]    [ValidateNotNullOrEmpty()]  [string] $Message,
        [Parameter(Mandatory = $false, Position = 1)]   [string] $Component = 'Remediation',
        [Parameter(Mandatory = $false, Position = 2)]   [ValidateSet(1, 2, 3)]      [int] $Type = 1
    )
  # Capture once to avoid drift between Time/Date
    $now = Get-Date 
    $Time = $now.ToString('HH:mm:ss.ffffff', [System.Globalization.CultureInfo]::InvariantCulture)
    $Date = $now.ToString('MM-dd-yyyy',      [System.Globalization.CultureInfo]::InvariantCulture)
  # Escape message for CMTrace payload (XML-like). SecurityElement.Escape handles &, <, >, " (quotes) safely
    $escapedMessage = [System.Security.SecurityElement]::Escape($Message)
  # Identify if it was a function that called Log and make it the component; default is "Remediation"
    $scriptFullPath = $PSCommandPath ; $scriptName = Split-Path -Path $scriptFullPath -Leaf
    $caller = (Get-PSCallStack)[1].Command
    if (-not ($caller -eq $scriptName)){ $Component = $caller }  
  # Build CMTrace entry (keep empty attributes as per CMTrace spec)
    $logLine = ('<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="" file="">' `
                -f $escapedMessage, $Time, $Date, $Component, $Type)
    try { # Write the log entry
        $dir = Split-Path -Path $LogFile -Parent # Ensure directory exists
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value $logLine -Encoding UTF8
    }
    catch { # If writing fails write error
        Write-Error -Message ("Failed to write log to '{0}': {1}" -f $LogFile, $_.Exception.Message)
        return
    }
  # Write all log lines to console for interactive testing/transcript capture
    switch ($Type) {
        1 { Write-Host $Message -ForegroundColor Gray }
        2 { Write-Host $Message -ForegroundColor Yellow }
        3 { Write-Host $Message -ForegroundColor Red }
        default { Write-Host $Message }
    }
}

# ------------------------------ Configuration & Logging ------------------------------

# Log directory/name, and transcript path
$logPath  = "$env:SystemDrive\Logs\IR"                               # This path is pulled when Intune collects diagnostics
    if (-not (Test-Path -Path $logPath)){ New-Item -Path $logPath -ItemType Directory -Force | Out-Null }
$logName = "CustomLogCollection"                                     # Default log name is the name of the remediation workspace
$logFile = Join-Path -Path $logPath -ChildPath $logName".log"        # Default $logFile is IR_ + logName.log
$errFile = Join-Path -Path $logPath -ChildPath $logName"_ERR.log"    # Default $errFile is logFile + _ERR.log

#------------------------------------ Begin Script ------------------------------------
Log "***** Begin $logName Detection *****"                  # Creates $logFile
$script:exitCode = 0                                        # Exit code variable to determine whether we keep the log or not

#-------------------------------------------------------------
# Detection Actions: Required Registry Location & Values
#-------------------------------------------------------------
try {
    $regPath = 'HKLM:\SOFTWARE\Microsoft\MdmDiagnostics\Area\Autopilot\FileEntry'
    $requiredEntries = @(
        '%SystemDrive%\Logs\*', # Don't forget the trailing \ before the file collection type (i.e. *.log or * for everything in the folder)
        '%SystemRoot%\System32\config\systemprofile\AppData\Local\HPConnect\Logs\*',
        '%ProgramData%\Microsoft\EdgeUpdate\Log\*.log'
    )

    if (-not (Test-Path $regPath)) { 
        $message = "[FAIL] Autopilot\FileEntry key $regpath not found"
        Log $message        # Error log output (Log function also performes write-output for Detection output displayed in the Intune admin center)
        $script:exitCode++  # Remediation required. Increment script exit code variable to trigger Exit 1 [FAIL] and ERR log creation
    } else {

        $regKey = Get-Item $regPath
        $existingValues = $regKey.GetValueNames()

        foreach ($entry in $requiredEntries) {
            if (-not ($existingValues -contains $entry)) {
                $message = "[FAIL] Registry value not found: $entry"
                Log $message ; $script:exitCode++
                continue # Silently continue to next entry if one is missing
            }

            $value = Get-ItemProperty -Path $regPath -Name $entry -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty $entry -ErrorAction SilentlyContinue

            if ($null -eq $value) {
                # Value name exists but could not be read (very rare, but safe)
                $message = "[FAIL] Registry value unreadable: $entry"
                Log $message ; $script:exitCode++
                continue
            }

            if ($value -ne 255) {
                $message = "[FAIL] Registry value incorrect ($value) for: $entry"
                Log $message ; $script:exitCode++
            }
        }
    }

#-------------------------------------------------------------
# End of Detection Actions: Exit Code & Logging
#-------------------------------------------------------------
    If ($script:exitCode -eq 0){    
        # Device is compliant
        Write-Output "[PASS] Custom log collection values found"            # Detection output for Intune admin center
        Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue     # Delete log, it's not necesary
    # Clean up ERR logs older than 14 days
        if (Test-Path $errFile){
            $retainDays = 14
            $cutOff = (Get-Date).AddDays(-$retainDays)
            $errAge = (Get-Item $errFile).LastWriteTime
        if ( $errAge -lt $cutOff ){ Remove-Item $errFile -Force -ErrorAction SilentlyContinue }
        }
        Exit 0                                                              # Remediation not required    
    } else {    
        # Device is not compliant
        Log "*****  End $logName Detection *****"                           # Cleanly end detection section of log file
        Write-Output "[FAIL] Custom log collection values not found"        # Detection output for Intune admin center
    # Create ERR log file
        If (!(Test-Path $errFile )){ Rename-Item $logFile $errFile -Force } # Create the ERR log in IME logs directory (remediation will append to it) 
        else {  Remove-Item $errFile -Force -ErrorAction SilentlyContinue   # Old ERR log found, replace with new ERR log w/current detections
                Rename-Item $logFile $errFile }     
        Exit 1                                                              # Remediation required
    }
}
catch {
    # Do this if a terminating exception happens
    Write-Output "An error occurred: $_"    # Detection error output for Intune admin center
}

Exit
