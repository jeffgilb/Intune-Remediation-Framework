# Detection: Check if the Update Orchestrator Service service is running
# The Update Orchestrator Service manages Windows Updates. If stopped, 
# devices will not be able to download and install the latest updates.

$service = Get-Service -Name "UsoSvc" 

if ($service.Status -eq "Running") {
    exit 0   # Compliant
} else {
    exit 1   # Non-compliant
}

