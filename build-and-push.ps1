# build-and-push.ps1
# Build Docker image and push to GitHub Container Registry (ghcr.io)

param(
    [string]$Tag = "",
    [string]$Registry = "ghcr.io",
    [string]$Owner = "neoz",
    [string]$ImageName = "neo-rev-lab",
    [switch]$NoPush,
    [switch]$Latest
)

$ErrorActionPreference = "Stop"

# Ensure QEMU is set up for cross-platform builds
Write-Host "Setting up QEMU for cross-platform builds ..." -ForegroundColor Cyan
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >$null

# Derive tag from git if not provided
if (-not $Tag) {
    $Tag = git describe --tags --always 2>$null
    if (-not $Tag) {
        $Tag = (git rev-parse --short HEAD)
    }

    # Append branch suffix for non-master branches
    $Branch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($Branch -and $Branch -ne "master") {
        # Sanitize branch name: replace / and \ with -, lowercase
        $BranchSuffix = $Branch -replace '[/\\]', '-' -replace '[^a-zA-Z0-9._-]', '' | ForEach-Object { $_.ToLower() }
        if ($Branch -eq "dev") {
            $Tag = "$Tag-beta"
        } else {
            $Tag = "$Tag-$BranchSuffix"
        }
    }
}

$FullImage = "$Registry/$Owner/$ImageName"

# Check if the tag already exists in the registry
Write-Host "Checking if ${FullImage}:${Tag} already exists ..." -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$manifest = docker manifest inspect "${FullImage}:${Tag}" 2>&1
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -eq 0) {
    Write-Host "Image ${FullImage}:${Tag} already exists in registry. Skipping build." -ForegroundColor Yellow
    exit 0
}

Write-Host "Building $FullImage`:$Tag ..." -ForegroundColor Cyan

docker buildx build --platform linux/amd64 --provenance=false --build-arg "VERSION=${Tag}" -t "${FullImage}:${Tag}" --load .

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed." -ForegroundColor Red
    exit 1
}

if ($Latest) {
    docker tag "${FullImage}:${Tag}" "${FullImage}:latest"
    Write-Host "Tagged ${FullImage}:latest" -ForegroundColor Green
}

if ($NoPush) {
    Write-Host "Build complete (push skipped)." -ForegroundColor Yellow
    exit 0
}

# Login to ghcr.io if not already authenticated
$ErrorActionPreference = "Continue"
$loginCheck = docker pull "${FullImage}:nonexistent" 2>&1
$ErrorActionPreference = "Stop"
if ($loginCheck -match "unauthorized" -or $loginCheck -match "denied") {
    Write-Host "Logging in to $Registry ..." -ForegroundColor Cyan
    Write-Host "Provide a GitHub PAT with write:packages scope:" -ForegroundColor Yellow
    $token = Read-Host -AsSecureString "Token"
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $plainToken | docker login $Registry -u $Owner --password-stdin
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Login failed." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Pushing ${FullImage}:${Tag} ..." -ForegroundColor Cyan
docker push "${FullImage}:${Tag}"

if ($Latest) {
    Write-Host "Pushing ${FullImage}:latest ..." -ForegroundColor Cyan
    docker push "${FullImage}:latest"
}

Write-Host "Done: ${FullImage}:${Tag}" -ForegroundColor Green
