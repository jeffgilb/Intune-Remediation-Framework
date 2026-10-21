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
- **contoso-detection**. Ensures HKLM:\SOFTWARE\Contoso\Settings\Enabled is a DWORD with value 1.
Logs the remediation and records its result and run metadata in the
configured Intune remediation state registry key.
- **contoso-remediation**. Ensures HKLM:\SOFTWARE\Contoso\Settings\Enabled is a DWORD with value 1.
Logs the remediation and records its result and run metadata in the
configured Intune remediation state registry key.