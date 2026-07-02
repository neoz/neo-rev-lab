# run.ps1 - Bootstrap a Claude Code reverse-engineering workspace
#
# Usage:
#   .\run.ps1 [TARGET_DIR]
#
# If TARGET_DIR is omitted, defaults to the current directory.
# Creates: workspace/, .mcp.json, CLAUDE.md, .claude/skills/
# Resources are fetched from https://github.com/neoz/neo-rev-lab

[CmdletBinding()]
param(
    [string]$Target = "."
)

$ErrorActionPreference = 'Stop'

$RepoUrl     = "https://github.com/neoz/neo-rev-lab.git"
$DockerImage = "ghcr.io/neoz/neo-rev-lab:latest"

New-Item -ItemType Directory -Force -Path $Target | Out-Null
$Target = (Resolve-Path $Target).Path

Write-Host "Setting up Claude Code reverse-engineering workspace in: $Target"

# -- 1. Create workspace directory -----------------------------------------
New-Item -ItemType Directory -Force -Path (Join-Path $Target 'workspace') | Out-Null
Write-Host "[+] workspace/"

# -- 2. Clone repo to a temp dir for resources -----------------------------
$TmpDir = Join-Path $env:TEMP ("neo-rev-lab-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

try {
    Write-Host "[*] Fetching resources from $RepoUrl ..."
    git clone --depth 1 --quiet $RepoUrl (Join-Path $TmpDir 'repo')
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }

    # -- 3. Copy .mcp.json from repo (rewrite dev image -> published image) -
    # The repo's .mcp.json is the single source of truth for the MCP server
    # list. It references the locally-built image tag "neo-rev-lab"; for a
    # bootstrapped workspace we swap that for the published $DockerImage so a
    # fresh machine can pull it. Only the `docker run` image (followed by `]`)
    # is rewritten -- the `--name`/`exec` container name stays "neo-rev-lab".
    $RepoMcp = Join-Path $TmpDir 'repo\.mcp.json'
    if (Test-Path $RepoMcp) {
        $McpJson = (Get-Content -Raw $RepoMcp) -replace '"neo-rev-lab"\]', "`"$DockerImage`"]"
        Set-Content -Path (Join-Path $Target '.mcp.json') -Value $McpJson -Encoding utf8
        if ($McpJson -notmatch [regex]::Escape($DockerImage)) {
            Write-Host "[!] WARNING: could not rewrite image reference in .mcp.json - verify it manually"
        }
        Write-Host "[+] .mcp.json (from repo)"
    } else {
        Write-Host "[!] WARNING: .mcp.json not found in repo"
    }

    # -- 4. Copy CLAUDE.md from repo ---------------------------------------
    $RepoClaudeMd = Join-Path $TmpDir 'repo\CLAUDE.md'
    if (Test-Path $RepoClaudeMd) {
        Copy-Item -Force $RepoClaudeMd (Join-Path $Target 'CLAUDE.md')
        Write-Host "[+] CLAUDE.md (from repo)"
    } else {
        Write-Host "[!] WARNING: CLAUDE.md not found in repo"
    }

    # -- 5. Copy skills from repo ------------------------------------------
    New-Item -ItemType Directory -Force -Path (Join-Path $Target '.claude') | Out-Null

    $RepoSkills   = Join-Path $TmpDir 'repo\.claude\skills'
    $TargetSkills = Join-Path $Target '.claude\skills'
    if (Test-Path $RepoSkills) {
        if (Test-Path $TargetSkills) {
            Remove-Item -Recurse -Force $TargetSkills
        }
        Copy-Item -Recurse -Force $RepoSkills $TargetSkills
        $SkillCount = (Get-ChildItem -Path $TargetSkills -Recurse -Filter 'SKILL.md' -File).Count
        Write-Host "[+] .claude/skills/ ($SkillCount skills copied)"
    } else {
        Write-Host "[!] WARNING: No skills found in repo - skipping"
    }

    # -- 6. Create .gitignore ----------------------------------------------
    $GitIgnorePath = Join-Path $Target '.gitignore'
    if (-not (Test-Path $GitIgnorePath)) {
        $GitIgnore = @'
# Local Claude Code settings
.claude/settings.local.json

# Workspace binaries and databases (large files)
workspace/*.i64
workspace/*.idb
workspace/*.id0
workspace/*.id1
workspace/*.id2
workspace/*.nam
workspace/*.til
'@
        Set-Content -Path $GitIgnorePath -Value $GitIgnore -Encoding utf8
        Write-Host "[+] .gitignore"
    } else {
        Write-Host "[=] .gitignore already exists, skipping"
    }
}
finally {
    if (Test-Path $TmpDir) {
        Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Done! To start working:"
Write-Host "  1. Place your binaries in $Target\workspace\"
Write-Host "  2. Run 'claude' from $Target\"
Write-Host "  3. The ida-mcp server pulls $DockerImage automatically via Docker"
