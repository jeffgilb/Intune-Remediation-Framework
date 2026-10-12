# Detection: Check if the Windows Update service is running
$ServiceName = "UsoSvc"

try {
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
} catch {
    # Service missing = non-compliant
    Write-Output "[ERR] Service went out for milk and never came back."
    exit 1
}

if ($service.Status -eq "Running") {
    Write-Output "[PASS] Service is running."
    exit 0   # Compliant

} else {
    Write-Output "[FAIL] Service is not running."
    exit 1   # Non-compliant
}
