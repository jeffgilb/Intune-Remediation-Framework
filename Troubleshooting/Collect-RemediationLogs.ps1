<#PSScriptInfo

.VERSION 1.0.2

.GUID 4db7d295-a70a-4313-aeeb-909de8d2880b

.AUTHOR Jeff Gilbert

.COMPANYNAME 

.COPYRIGHT 

.TAGS Intune

.LICENSEURI 

.PROJECTURI 

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES
    10.13.26    v1.0.2  Initial release.
#>

<#
.SYNOPSIS
    Collects Microsoft Intune Management Extension and Remediation
    troubleshooting information from a Windows endpoint.
    
.DESCRIPTION
    Collects:
      - Remediation-related Intune Management Extension logs
      - Custom Intune Remediation logs [$customLogPath]
      - Custom registry checkpoint paths [$CheckpointPath]
      - IME service information
      - HealthScripts cache inventory
      - Script package file hashes
      - Relevant registry information
      - DeviceManagement Enterprise Diagnostics event log
      - Device and enrollment summary
      - Recent IME log entries containing remediation-related terms

    Cached detection and remediation script contents are not collected
    unless -IncludeCachedScripts is specified.

Run this from an elevated PowerShell session. It creates a timestamped ZIP file in C:\Windows\Temp by default.

Normal execution
.\Collect-RemediationLogs.ps1

Collect seven days of events
.\Collect-RemediationLogs.ps1 -OutputPath "C:\Support" -DaysOfEvents 7

Include cached script contents
[REQUIRES: RunAs System]
.\Collect-RemediationLogs.ps1 -IncludeCachedScripts

.PARAMETER OutputPath
    Directory where the final ZIP file will be created.

.PARAMETER DaysOfEvents
    Number of days of DeviceManagement Enterprise Diagnostics events
    to include.

.PARAMETER IncludeCachedScripts
    Requires the script be run with System permissions! Try using PsExec.
    Copies cached DetectionScript.ps1 and RemediationScript.ps1 files.
    Use carefully because scripts can contain internal implementation details.

.EXAMPLE
    .\Collect-RemediationLogs.ps1

.EXAMPLE
    .\Collect-RemediationLogs.ps1 -OutputPath "C:\Support" -DaysOfEvents 7

.EXAMPLE
    .\Collect-RemediationLogs.ps1 -IncludeCachedScripts
#>

[CmdletBinding()]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = "$env:windir\Temp",

    [Parameter()]
    [ValidateRange(1, 90)]
    [int]$DaysOfEvents = 3,

    [Parameter()]
    [switch]$IncludeCachedScripts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$computerName = $env:COMPUTERNAME

$collectionName = "IntuneRemediationLogs_${computerName}_${timestamp}"
$workingPath = Join-Path -Path $env:TEMP -ChildPath $collectionName
$zipPath = Join-Path -Path $OutputPath -ChildPath "$collectionName.zip"

$imeLogPath = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'
$healthScriptsPath = 'C:\Windows\IMECache\HealthScripts'
$customLogPath = 'C:\Logs\IR'

$remediationImeLogPattern =
    '^(HealthScripts|AgentExecutor|IntuneManagementExtension)(-\d{8}-\d{6})?\.log$'

$imeRegistryPath =
    'HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension'

$sideCarRegistryPath =
    'HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\SideCarPolicies\Scripts'

$CheckpointPath =
    'HKLM:\SOFTWARE\Intune\Remediations'

$legacyCheckpointPath =
    'HKLM:\SOFTWARE\MMS\IntuneRemediations'

$eventLogName =
    'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'

function Write-CollectionLog {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $entry = '[{0}] [{1}] {2}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
        $Level,
        $Message

    Write-Host $entry

    if (Test-Path -LiteralPath $workingPath) {
        $entry | Out-File `
            -FilePath (Join-Path $workingPath 'Collection.log') `
            -Append `
            -Encoding utf8
    }
}

function Export-RegistryTree {
    param (
        [Parameter(Mandatory)]
        [string]$PowerShellPath,

        [Parameter(Mandatory)]
        [string]$RegExePath,

        [Parameter(Mandatory)]
        [string]$OutputFile
    )

    if (-not (Test-Path -LiteralPath $PowerShellPath)) {
        Write-CollectionLog `
            -Message "Registry path not present: $PowerShellPath" `
            -Level WARN

        return
    }

    try {
        & reg.exe export $RegExePath $OutputFile /y | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "reg.exe returned exit code $LASTEXITCODE."
        }

        Write-CollectionLog "Exported registry path: $RegExePath"
    }
    catch {
        Write-CollectionLog `
            -Message "Could not export $RegExePath. $($_.Exception.Message)" `
            -Level ERROR
    }
}

try {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item `
            -Path $OutputPath `
            -ItemType Directory `
            -Force |
            Out-Null
    }

    if (Test-Path -LiteralPath $workingPath) {
        Remove-Item `
            -LiteralPath $workingPath `
            -Recurse `
            -Force
    }

    New-Item `
        -Path $workingPath `
        -ItemType Directory `
        -Force |
        Out-Null

    Write-CollectionLog "Starting Intune Remediation log collection."

    # ------------------------------------------------------------
    # Collection directories
    # ------------------------------------------------------------

    $imeDestination =
        Join-Path $workingPath 'IntuneManagementExtension-Logs'

    $customDestination =
        Join-Path $workingPath 'Custom-Remediation-Logs'

    $registryDestination =
        Join-Path $workingPath 'Registry'

    $eventDestination =
        Join-Path $workingPath 'EventLogs'

    $cacheDestination =
        Join-Path $workingPath 'HealthScripts-Cache'

    foreach ($directory in @(
        $imeDestination,
        $customDestination,
        $registryDestination,
        $eventDestination,
        $cacheDestination
    )) {
        New-Item `
            -Path $directory `
            -ItemType Directory `
            -Force |
            Out-Null
    }

    # ------------------------------------------------------------
    # IME logs
    # ------------------------------------------------------------

    $remediationImeLogs = @()

    if (Test-Path -LiteralPath $imeLogPath) {
        $remediationImeLogs = @(
            Get-ChildItem `
            -LiteralPath $imeLogPath `
            -File `
            -ErrorAction Stop |
            Where-Object Name -Match $remediationImeLogPattern
        )

        if ($remediationImeLogs.Count -gt 0) {
            $remediationImeLogs |
                Copy-Item `
                -Destination $imeDestination `
                -Force `
                -ErrorAction Stop

            Write-CollectionLog `
                "Collected $($remediationImeLogs.Count) remediation-related IME logs."
        }
        else {
            Write-CollectionLog `
                -Message "No remediation-related IME logs were found in: $imeLogPath" `
                -Level WARN
        }
    }
    else {
        Write-CollectionLog `
            -Message "IME log folder was not found: $imeLogPath" `
            -Level WARN
    }

    # ------------------------------------------------------------
    # Custom remediation logs
    # ------------------------------------------------------------

    if (Test-Path -LiteralPath $customLogPath) {
        Copy-Item `
            -LiteralPath $customLogPath `
            -Destination $customDestination `
            -Recurse `
            -Force `
            -ErrorAction Continue

        Write-CollectionLog "Collected custom remediation logs."
    }
    else {
        Write-CollectionLog `
            -Message "Custom remediation log folder was not found." `
            -Level WARN
    }

    # ------------------------------------------------------------
    # IME service information
    # ------------------------------------------------------------

    $serviceOutput =
        Join-Path $workingPath 'IntuneManagementExtension-Service.txt'

    try {
        $imeService = Get-CimInstance `
            -ClassName Win32_Service `
            -Filter "Name='IntuneManagementExtension'"

        if ($null -ne $imeService) {
            $imeService |
                Select-Object `
                    Name,
                    DisplayName,
                    State,
                    StartMode,
                    StartName,
                    ProcessId,
                    PathName |
                Format-List |
                Out-File `
                    -FilePath $serviceOutput `
                    -Encoding utf8
        }
        else {
            'The IntuneManagementExtension service was not found.' |
                Out-File `
                    -FilePath $serviceOutput `
                    -Encoding utf8
        }
    }
    catch {
        $_ |
            Out-String |
            Out-File `
                -FilePath $serviceOutput `
                -Encoding utf8
    }

    # ------------------------------------------------------------
    # Device summary
    # ------------------------------------------------------------

    $deviceOutput =
        Join-Path $workingPath 'Device-Summary.txt'

    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS

    [pscustomobject]@{
        ComputerName        = $computerName
        Manufacturer        = $computerSystem.Manufacturer
        Model               = $computerSystem.Model
        SerialNumber        = $bios.SerialNumber
        OperatingSystem     = $operatingSystem.Caption
        OSVersion           = $operatingSystem.Version
        OSBuild             = $operatingSystem.BuildNumber
        LastBootTime        = $operatingSystem.LastBootUpTime
        PowerShellVersion   = $PSVersionTable.PSVersion.ToString()
        CollectionTime      = Get-Date
        CollectionUser      = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Is64BitOperatingSystem = [System.Environment]::Is64BitOperatingSystem
        Is64BitProcess      = [System.Environment]::Is64BitProcess
    } |
        Format-List |
        Out-File `
            -FilePath $deviceOutput `
            -Encoding utf8

    # ------------------------------------------------------------
    # Scheduled tasks related to Enterprise Management
    # ------------------------------------------------------------

    $taskOutput =
        Join-Path $workingPath 'EnterpriseManagement-ScheduledTasks.txt'

    try {
        Get-ScheduledTask -ErrorAction Stop |
            Where-Object {
                $_.TaskPath -like '\Microsoft\Windows\EnterpriseMgmt*' -or
                $_.TaskName -match 'Intune|Enterprise'
            } |
            Select-Object `
                TaskPath,
                TaskName,
                State,
                Description |
            Sort-Object TaskPath, TaskName |
            Format-Table -AutoSize |
            Out-String -Width 300 |
            Out-File `
                -FilePath $taskOutput `
                -Encoding utf8
    }
    catch {
        $_ |
            Out-String |
            Out-File `
                -FilePath $taskOutput `
                -Encoding utf8
    }

    # ------------------------------------------------------------
    # HealthScripts cache inventory
    # ------------------------------------------------------------

    $inventoryCsv =
        Join-Path $cacheDestination 'HealthScripts-Inventory.csv'

    if (Test-Path -LiteralPath $healthScriptsPath) {
        $scriptFiles = Get-ChildItem `
            -LiteralPath $healthScriptsPath `
            -File `
            -Recurse `
            -ErrorAction Continue

        $inventory = foreach ($file in $scriptFiles) {
            $hash = $null

            try {
                $hash = (
                    Get-FileHash `
                        -LiteralPath $file.FullName `
                        -Algorithm SHA256 `
                        -ErrorAction Stop
                ).Hash
            }
            catch {
                $hash = "Hash failed: $($_.Exception.Message)"
            }

            [pscustomobject]@{
                RelativePath = $file.FullName.Substring(
                    $healthScriptsPath.Length
                ).TrimStart('\')

                FileName      = $file.Name
                Length        = $file.Length
                LastWriteTime = $file.LastWriteTime
                SHA256        = $hash
            }
        }

        $inventory |
            Export-Csv `
                -LiteralPath $inventoryCsv `
                -NoTypeInformation `
                -Encoding utf8

        if ($IncludeCachedScripts) {
            Copy-Item `
                -LiteralPath $healthScriptsPath `
                -Destination $cacheDestination `
                -Recurse `
                -Force `
                -ErrorAction Continue

            Write-CollectionLog `
                "Collected HealthScripts inventory and cached script files."
        }
        else {
            Write-CollectionLog `
                "Collected HealthScripts inventory and hashes. Script contents were excluded."
        }
    }
    else {
        Write-CollectionLog `
            -Message "HealthScripts cache was not found: $healthScriptsPath" `
            -Level WARN
    }

    # ------------------------------------------------------------
    # Registry exports
    # ------------------------------------------------------------

    Export-RegistryTree `
        -PowerShellPath $imeRegistryPath `
        -RegExePath 'HKLM\SOFTWARE\Microsoft\IntuneManagementExtension' `
        -OutputFile (
            Join-Path $registryDestination `
                'IntuneManagementExtension.reg'
        )

    Export-RegistryTree `
        -PowerShellPath $sideCarRegistryPath `
        -RegExePath `
            'HKLM\SOFTWARE\Microsoft\IntuneManagementExtension\SideCarPolicies\Scripts' `
        -OutputFile (
            Join-Path $registryDestination `
                'SideCarPolicies-Scripts.reg'
        )

    Export-RegistryTree `
        -PowerShellPath $CheckpointPath `
        -RegExePath `
            'HKLM:\SOFTWARE\Intune\Remediations' `
        -OutputFile (
            Join-Path $registryDestination `
                'USBank-IntuneRemediations.reg'
        )

    Export-RegistryTree `
        -PowerShellPath $legacyCheckpointPath `
        -RegExePath `
            'HKLM\SOFTWARE\MMS\IntuneRemediations' `
        -OutputFile (
            Join-Path $registryDestination `
                'MMS-IntuneRemediations.reg'
        )

    # ------------------------------------------------------------
    # DeviceManagement Enterprise Diagnostics event log
    # ------------------------------------------------------------

    $startTime = (Get-Date).AddDays(-$DaysOfEvents)

    try {
        $events = Get-WinEvent `
            -FilterHashtable @{
                LogName   = $eventLogName
                StartTime = $startTime
            } `
            -ErrorAction Stop

        $events |
            Select-Object `
                TimeCreated,
                Id,
                LevelDisplayName,
                ProviderName,
                Message |
            Export-Csv `
                -LiteralPath (
                    Join-Path $eventDestination `
                        'DeviceManagement-Enterprise-Diagnostics.csv'
                ) `
                -NoTypeInformation `
                -Encoding utf8

        Write-CollectionLog `
            "Collected $($events.Count) DeviceManagement events."
    }
    catch {
        Write-CollectionLog `
            -Message "Could not collect DeviceManagement events. $($_.Exception.Message)" `
            -Level WARN
    }

    # Export the native event log when possible.
    try {
        $evtxOutput =
            Join-Path $eventDestination `
                'DeviceManagement-Enterprise-Diagnostics.evtx'

        & wevtutil.exe epl $eventLogName $evtxOutput

        if ($LASTEXITCODE -ne 0) {
            throw "wevtutil.exe returned exit code $LASTEXITCODE."
        }
    }
    catch {
        Write-CollectionLog `
            -Message "Could not export the EVTX file. $($_.Exception.Message)" `
            -Level WARN
    }

    # ------------------------------------------------------------
    # Remediation-focused log extracts
    # ------------------------------------------------------------

    $extractOutput =
        Join-Path $workingPath 'Remediation-Relevant-Log-Entries.txt'

    $searchTerms = @(
        'HealthScripts',
        'Remediation',
        'DetectionScript',
        'RemediationScript',
        'exit code',
        'SideCarPolicies',
        'error',
        'exception',
        'failed'
    )

    foreach ($logFile in $remediationImeLogs) {
        "============================================================" |
            Out-File `
                -FilePath $extractOutput `
                -Append `
                -Encoding utf8

        "SOURCE: $($logFile.FullName)" |
            Out-File `
                -FilePath $extractOutput `
                -Append `
                -Encoding utf8

        "============================================================" |
            Out-File `
                -FilePath $extractOutput `
                -Append `
                -Encoding utf8

        Select-String `
            -LiteralPath $logFile.FullName `
            -Pattern $searchTerms `
            -SimpleMatch `
            -ErrorAction Continue |
            Select-Object `
                Path,
                LineNumber,
                Line |
            Format-Table -Wrap |
            Out-String -Width 400 |
            Out-File `
                -FilePath $extractOutput `
                -Append `
                -Encoding utf8
    }

    # ------------------------------------------------------------
    # Package manifest
    # ------------------------------------------------------------

    Get-ChildItem `
        -LiteralPath $workingPath `
        -File `
        -Recurse |
        Select-Object `
            FullName,
            Length,
            LastWriteTime |
        Export-Csv `
            -LiteralPath (
                Join-Path $workingPath 'Collection-Manifest.csv'
            ) `
            -NoTypeInformation `
            -Encoding utf8

    # ------------------------------------------------------------
    # Compress the package
    # ------------------------------------------------------------

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item `
            -LiteralPath $zipPath `
            -Force
    }

    Compress-Archive `
        -Path (Join-Path $workingPath '*') `
        -DestinationPath $zipPath `
        -CompressionLevel Optimal `
        -Force

    Write-CollectionLog "Collection completed successfully."
    Write-Host
    Write-Host "Output package: $zipPath" -ForegroundColor Green

    Get-Item -LiteralPath $zipPath |
        Select-Object FullName, Length, LastWriteTime
}
catch {
    Write-CollectionLog `
        -Message "Collection failed. $($_.Exception.Message)" `
        -Level ERROR

    throw
}
finally {
    if (Test-Path -LiteralPath $workingPath) {
        Remove-Item `
            -LiteralPath $workingPath `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}


