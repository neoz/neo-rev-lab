$container = docker ps --filter ancestor=neo-rev-lab --format "{{.ID}}" | Select-Object -First 1
if (-not $container) {
    Write-Error "No running neo-rev-lab container found."
    exit 1
}
docker exec -it $container /bin/bash
