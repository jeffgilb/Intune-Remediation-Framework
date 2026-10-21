<#
.SYNOPSIS
Creates required Autopilot MDM Diagnostics custom log collection registry entries.

.DESCRIPTION
This script is intended to be used as the **Remediation** portion of a Microsoft Intune
Remediation. It ensures that required custom log collection registry entries exist for 
Windows Autopilot MDM Diagnostics.

The script validates and enforces the presence of the following registry key:
HKLM:\SOFTWARE\Microsoft\MdmDiagnostics\Area\Autopilot\FileEntry

If the key does not exist, it is created. If required registry values are missing,
they are created as REG_DWORD entries with a decimal value of 255, enabling maximum
diagnostic log collection.

Existing registry values are not modified.

The script writes CMTrace‑compatible logs to the Intune Management Extension (IME)
diagnostics directory and always logs remediation actions to the *_ERR.log file.

.REGISTRY CONFIGURATION ENFORCED
Registry Key:
HKLM:\SOFTWARE\Microsoft\MdmDiagnostics\Area\Autopilot\FileEntry

Registry Values Created (if missing):
- %SystemDrive%\Logs* = REG_DWORD 255
- %SystemRoot%\System32\config\systemprofile\AppData\Local\HPConnect\Logs* = REG_DWORD 255
- %ProgramData%\Microsoft\EdgeUpdate\Log\*.log = REG_DWORD 255
.LOGGING
Log File Location:
%ProgramData%\Microsoft\IntuneManagementExtension\Logs

Log File Used by This Script:
- IR_CustomLogCollection_ERR.log

Logging format is CMTrace‑compatible and suitable for Intune diagnostics collection.

.REMEDIATION LOGIC
- Ensures the Autopilot FileEntry registry key exists
- Creates missing registry values only (does not overwrite existing values)
- Logs all remediation actions and errors
- Exits successfully when remediation completes without error

.ERROR HANDLING
- Non‑terminating errors are promoted to terminating errors
- All terminating errors are caught and logged
- Script exits with a non‑zero exit code on failure conditions

.EXIT CODES
0  - Remediation completed successfully
1  - Remediation failed due to an error

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
$logPath  = "$env:SystemDrive\Logs\IR"                              # This path is pulled when Intune collects diagnostics
$logName = "CustomLogCollection"                                    # Default log name is the name of the remediation workspace
$logFile = Join-Path -Path $logPath -ChildPath $logName"_ERR.log"   # Remediation scripts write to the ERR log

Log "`n"
Log "`n***** Begin $logName Remediation *****"                      # Clean break from detection to remediation in ERR log

#------------------------------------ Begin Script ------------------------------------
$ErrorActionPreference = 'Stop' # Ensure non-terminating errors become terminating for try/catch

try {
    $regPath = 'HKLM:\SOFTWARE\Microsoft\MdmDiagnostics\Area\Autopilot\FileEntry'
    $entries = @{
        '%SystemDrive%\Logs\*' = 255
        '%SystemRoot%\System32\config\systemprofile\AppData\Local\HPConnect\Logs\*' = 255
        '%ProgramData%\Microsoft\EdgeUpdate\Log\*.log' = 255
    }

    # Ensure key exists
    if (-not (Test-Path $regPath)) {
        Log "Autopilot\FileEntry registry key not found" -Type 3
        New-Item -Path $regPath -Force | Out-Null

        if (Test-Path $regPath) {
            Log "Successfully created the Autopilot\FileEntry registry key"
        }
        else {
            Log "Failed to create the Autopilot\FileEntry registry key" -Type 3
            return
        }
    }
    else {
        Log "Autopilot\FileEntry registry key present"
    }

    # Get existing value names once
    $existingValues = (Get-Item $regPath).GetValueNames()
    foreach ($name in $entries.Keys) {
        if ($existingValues -contains $name) {
            Log "Registry value already present, skipping creation: $name"
            continue
        }
        New-ItemProperty `
            -Path $regPath `
            -Name $name `
            -Value $entries[$name] `
            -PropertyType DWord `
            -Force | Out-Null
        Log "Created registry value: $name (DWORD = $($entries[$name]))"
    }

    Log "***** End $logName Remediation *****"                      # Clean end for remediation in ERR log
    Exit 0

} catch {
    Log "An error occurred: $_"    
}

Exit
