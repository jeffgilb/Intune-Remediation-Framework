$ErrorActionPreference = 'Stop'

$ServiceName = 'UsoSvc'
$LogDirectory = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
$TranscriptPath = Join-Path $LogDirectory 'L200-UsoSvcRemediation.log'

try {
    Start-Transcript -Path $TranscriptPath -Append -Force
    
    $service = Get-Service -Name $ServiceName -ErrorAction Stop

    if ($service.Status -ne 'Running') {
        Write-Output "$ServiceName is not running."
        if ($service.StartType -eq 'Disabled') {
            Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop
        }
        Write-Output "Starting $ServiceName."
        Start-Service -Name $ServiceName -ErrorAction Stop
    }

    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        Write-Error "Failed to remediate '$ServiceName': $message" -ErrorAction Continue
        Exit 1
    } else { 
        Write-Output "Successfully started $ServiceName."
    }
    Exit 0
} catch {
    Write-Error "An error occurred: $($_.Exception.Message)" -ErrorAction Continue
    Exit 1
} finally {
    Stop-Transcript
}
