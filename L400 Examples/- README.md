# Intune Remediation Examples

## Example Script Templates
### template-detection
Intune Remediation detection script template. This script template provides a starting point for creating Intune Remediation scripts.

#### Features
- CMTrace-compatible logging
- Automatic relaunch in 64-bit PowerShell when required
- Remediation run counter
- Remediation result tracking in the registry
- Transcript logging support for troubleshooting

#### Registry Checkpoint Location
    HKLM:\SOFTWARE\IntuneRemediations\<LogName>

#### Log File
    <SystemDrive>\Logs\IR\<LogName>.log

#### Verbose Log File (optional)
    <SystemDrive>\Logs\IR\<LogName>_verbose.log

#### Registry Checkpoint Values
- Detection result
- Detection run time timestamps
- Runtime duration
- Detection results
- Script version
- Script exit code

#### Intune Output
Messages logged with the -StdOut switch are returned to the Intune admin center.

####  Exit Codes
- 0 = Compliant
- 1 = Non-compliant
- 2 = Detection script error

### template-remediation
Intune Remediation remediation script template. This script template provides a starting point for creating Intune Remediation scripts.

#### Features
- CMTrace-compatible logging
- Automatic relaunch in 64-bit PowerShell when required
- Remediation run counter
- Remediation result tracking in the registry
- Verbose transcript logging support for troubleshooting (optional)

#### Registry Checkpoint Location
    HKLM:\SOFTWARE\IntuneRemediations\<LogName>

#### Log File
    <SystemDrive>\Logs\IR\<LogName>.log

#### Verbose Log File (optional)
    <SystemDrive>\Logs\IR\<LogName>_verbose.log

#### Registry Checkpoint Values
- RunId (correlation identifier)
- RunCount
- Remediation result
- Runtime duration
- Remediation timestamps
- Last detection failure details
- Script version

#### Exit Codes
- 0 = Remediation successful
- 1 = Remediation failed
- 2 = Error encountered

-----

## Example Remediations
The following examples are based on the templates with the same features.

### Contoso Registry Value Check
- **contoso-detection**. Ensures *HKLM:\SOFTWARE\Contoso\Settings\Enabled* is a DWORD with value 1.
Logs the remediation and records its result and run metadata in the
configured Intune remediation state registry key.
- **contoso-remediation**. Ensures *HKLM:\SOFTWARE\Contoso\Settings\Enabled* is a DWORD with value 1.
Logs the remediation and records its result and run metadata in the
configured Intune remediation state registry key.

### Custom Log Location Collection
- **logCollection-detection**. Verifies custom log collection entries have been configured.
This script checks the following registry path: *HKLM:\SOFTWARE\Microsoft\MdmDiagnostics\Area\Autopilot\FileEntry*.
It verifies that specific REG_DWORD value names (log path wildcard entries) exist and that each value is
configured with decimal value 255 (maximum diagnostic collection). If any required registry key or value is
missing, unreadable, or misconfigured, the script exits with a non-zero code, triggering remediation.
- **logCollection-remediation**. Creates required Autopilot MDM Diagnostics custom log collection registry entries.
The script validates and enforces the presence of the following registry key: *HKLM:\SOFTWARE\Microsoft\MdmDiagnostics\Area\Autopilot\FileEntry*.
If the key does not exist, it is created. If required registry values are missing, they are created as REG_DWORD
entries with a decimal value of 255, enabling maximum diagnostic log collection. Existing registry values are not modified.