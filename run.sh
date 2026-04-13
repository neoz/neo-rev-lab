#!/usr/bin/env bash
# run.sh - Bootstrap a Claude Code reverse-engineering workspace
#
# Usage:
#   ./run.sh [TARGET_DIR]
#
# If TARGET_DIR is omitted, defaults to the current directory.
# Creates: workspace/, .mcp.json, CLAUDE.md, .claude/skills/
# Resources are fetched from https://github.com/neoz/neo-rev-lab

set -euo pipefail

REPO_URL="https://github.com/neoz/neo-rev-lab.git"
DOCKER_IMAGE="ghcr.io/neoz/neo-rev-lab:latest"
TARGET="${1:-.}"
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"

echo "Setting up Claude Code reverse-engineering workspace in: $TARGET"

# ── 1. Create workspace directory ──────────────────────────────────────────
mkdir -p "$TARGET/workspace"
echo "[+] workspace/"

# ── 2. Clone repo to a temp dir for resources ─────────────────────────────
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "[*] Fetching resources from $REPO_URL ..."
git clone --depth 1 --quiet "$REPO_URL" "$TMPDIR/repo"

# ── 3. Create .mcp.json ───────────────────────────────────────────────────
cat > "$TARGET/.mcp.json" << MCP_EOF
{
  "mcpServers": {
    "ida-mcp": {
      "command": "docker",
      "args": ["run", "--rm", "-i", "--name", "neo-rev-lab", "-v", "./workspace:/workspace", "$DOCKER_IMAGE"]
    },
    "dotnet-mcp": {
      "command": "docker",
      "args": ["exec", "-i", "neo-rev-lab", "/opt/dotnet-mcp/MCPPOC"]
    },
    "jadx-mcp": {
      "command": "docker",
      "args": ["exec", "-i", "neo-rev-lab", "java", "-Dspring.ai.mcp.server.stdio=true", "-jar", "/opt/jadx-mcp/jadx-mcp-server-1.0.0.jar"]
    }
  }
}
MCP_EOF
echo "[+] .mcp.json"

# ── 4. Copy CLAUDE.md from repo ───────────────────────────────────────────
if [ -f "$TMPDIR/repo/CLAUDE.md" ]; then
  cp "$TMPDIR/repo/CLAUDE.md" "$TARGET/CLAUDE.md"
  echo "[+] CLAUDE.md (from repo)"
else
  echo "[!] WARNING: CLAUDE.md not found in repo"
fi

# ── 5. Copy skills from repo ──────────────────────────────────────────────
mkdir -p "$TARGET/.claude"

if [ -d "$TMPDIR/repo/.claude/skills" ]; then
  rm -rf "$TARGET/.claude/skills"
  cp -r "$TMPDIR/repo/.claude/skills" "$TARGET/.claude/skills"
  SKILL_COUNT=$(find "$TARGET/.claude/skills" -name "SKILL.md" | wc -l)
  echo "[+] .claude/skills/ ($SKILL_COUNT skills copied)"
else
  echo "[!] WARNING: No skills found in repo - skipping"
fi

# ── 6. Create .gitignore ──────────────────────────────────────────────────
if [ ! -f "$TARGET/.gitignore" ]; then
  cat > "$TARGET/.gitignore" << 'GITIGNORE_EOF'
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
GITIGNORE_EOF
  echo "[+] .gitignore"
else
  echo "[=] .gitignore already exists, skipping"
fi

echo ""
echo "Done! To start working:"
echo "  1. Place your binaries in $TARGET/workspace/"
echo "  2. Run 'claude' from $TARGET/"
echo "  3. The ida-mcp server pulls $DOCKER_IMAGE automatically via Docker"
