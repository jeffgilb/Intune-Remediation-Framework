# Remediation: Start the Update Orchestrator Service service if it's not running
$service = Get-Service -Name "UsoSvc"

if ($service.Status -ne "Running") {
    Start-Service -Name "UsoSvc"
}

