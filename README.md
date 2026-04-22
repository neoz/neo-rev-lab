# reverse

AI-assisted reverse engineering lab powered by Claude Code and MCP (Model Context Protocol).

Runs IDA Pro, a .NET decompiler, angr, and a full Android toolchain (jadx, apktool, hermes-dec / hbctool for React Native Hermes bytecode) inside a Docker container, exposed to Claude Code as MCP tool servers and skills so you can analyze binaries conversationally.

## Prerequisites

- **Docker Desktop** -- install from https://www.docker.com/products/docker-desktop/ if not already available.
- **Claude Code** -- see the official site for installation instructions: https://claude.com/claude-code.

## Quick Start

### 1. Set up the workspace

Run the setup script in any directory where you want to work.

**Linux / macOS (bash):**

```bash
# Set up in the current directory
curl -fsSL https://raw.githubusercontent.com/neoz/neo-rev-lab/master/run.sh | bash

# Or set up in a specific directory
curl -fsSL https://raw.githubusercontent.com/neoz/neo-rev-lab/master/run.sh | bash -s /path/to/my-project
```

**Windows (PowerShell):**

```powershell
# Set up in the current directory
iwr -useb https://raw.githubusercontent.com/neoz/neo-rev-lab/master/run.ps1 | iex

# Or set up in a specific directory
$script = iwr -useb https://raw.githubusercontent.com/neoz/neo-rev-lab/master/run.ps1
& ([scriptblock]::Create($script.Content)) C:\path\to\my-project
```

> If execution policy blocks the script, run PowerShell with `-ExecutionPolicy Bypass`, or download `run.ps1` first and invoke it as `pwsh -ExecutionPolicy Bypass -File .\run.ps1`.

This creates the following structure:
- `workspace/` -- drop your target binaries here (mounted at `/workspace/` in the container)
- `.mcp.json` -- MCP server configuration pointing to `ghcr.io/neoz/neo-rev-lab:latest`
- `CLAUDE.md` -- project instructions for Claude Code
- `.claude/skills/` -- all reverse engineering skills (IDA, angr, etc.)

The Docker image is pulled automatically on first use -- no build step required.

**Pre-pulling the image (optional).** The image is large, so the first `claude` launch can take a while as Docker fetches it in the background. To avoid the wait -- and to get a visible progress bar -- pull it ahead of time:

```bash
docker pull ghcr.io/neoz/neo-rev-lab:latest
```

The same command also updates an existing install to the latest image (new tools, bug fixes) without re-running `run.sh` / `run.ps1`. Your `workspace/`, `.mcp.json`, `CLAUDE.md`, and `.claude/skills/` are left untouched. Re-run the bootstrap script only when you want to refresh `CLAUDE.md` or pick up new skills from the repo.

### 2. Place your target binary in the workspace

Copy the binary (ELF, PE, APK, .NET assembly, etc.) you want to analyze into the `workspace/` folder:

```
workspace/
  your_target.exe
  another_sample.apk
```

### 3. Launch Claude Code

Start Claude Code from the project directory:

```bash
claude
```

On first launch, Claude Code will detect the `.mcp.json` configuration and prompt you to approve the MCP servers. **Accept both**:

| Server | Purpose |
|---|---|
| `ida-mcp` | IDA Pro decompiler, disassembly, xrefs, type analysis |
| `dotnet-mcp` | .NET assembly decompilation and inspection |

The `ida-mcp` server starts the Docker container automatically. The `dotnet-mcp` server runs inside the same container via `docker exec`.

### 4. Start reversing

Once Claude Code is running with MCP servers connected, you can ask it to analyze your target. Examples:

```
> Open workspace/challenge.elf and list all functions
> Decompile the main function and explain what it does
> Find all cross-references to the encryption routine
> Load workspace/app.apk and show the main activity source
> Write an angr script to solve this CTF challenge
```

## Skills (Slash Commands)

This project ships with specialized skills that Claude Code can invoke via slash commands or automatically based on your request. Skills provide domain-specific workflows, reference material, and best practices.

### idasql Skills

The `idasql` plugin (`tools/idasql-skills/`) adds a full suite of IDA analysis skills.

**Always start with `/connect` to bootstrap the session before using any other idasql skill:**

```
> /connect /workspace/your_target.i64
```

This opens the IDA database, starts the idasql HTTP server inside the container, and prepares the session. Once connected, all other idasql skills become available.

| Skill | Trigger | What it does |
|---|---|---|
| `/analysis` | Triage, audit, detect crypto/network activity | Full binary triage with multi-table SQL queries |
| `/annotations` | Add comments, rename symbols, apply types | Edit IDA databases: comments, names, bookmarks |
| `/connect` | Open databases, bootstrap sessions | Connect to IDA databases and start idasql servers |
| `/data` | Search strings, find byte patterns | Query strings, bytes, and binary data via SQL |
| `/decompiler` | Decompile functions, inspect pseudocode | Pseudocode, ctree AST, local variables, labels |
| `/disassembly` | Query instructions, blocks, segments | Functions, segments, instructions, control flow |
| `/functions` | Look up idasql SQL function signatures | Complete reference catalog for idasql SQL functions |
| `/grep` | Find functions/labels/types by name pattern | Search named entities by regex pattern |
| `/idapython` | Run IDAPython snippets | Execute IDAPython via idasql when SQL is insufficient |
| `/re-source` | Recursive annotation, struct recovery | Bottom-up program understanding and type reconstruction |
| `/storage` | Persist metadata in IDA databases | Key-value storage via netnode for tracking progress |
| `/types` | Create/modify structs, enums, typedefs | IDA type system: structs, unions, enums, C declarations |
| `/ui-context` | Capture current IDA GUI state | Read what's on screen or selected in the IDA UI |
| `/xrefs` | Callers, callees, call graphs | Cross-reference analysis and dependency chains |

### angr Skill

The `/angr` skill writes and runs angr Python scripts inside the Docker container for:

- Solving CTF challenges via symbolic execution
- Finding inputs that reach a target address (e.g., "find the flag")
- Cracking keygens and license checks
- Automated exploit generation (AEG)
- Deobfuscating control flow flattening (CFF/OLLVM)
- Concolic testing for vulnerability discovery

The skill handles the Docker workflow automatically -- it writes the solve script to `workspace/`, runs it inside the container, and returns the results.

Usage example:

```
> /angr solve workspace/crackme for the flag
> Use angr to find the input that prints "Correct!"
```

### Android APK Skills

Android analysis runs as skills driving the CLI tools (`jadx`, `apktool`, `hermes-dec`, `hbctool`) inside the container -- no dedicated MCP server is needed. Both native Android (Java/Kotlin) and React Native (Hermes bytecode) apps are first-class.

| Skill | Trigger | What it does |
|---|---|---|
| `/apk-find-api` | Map an APK's API surface, list endpoints, reverse-engineer an API client | Static discovery of every endpoint an APK talks to (Retrofit / OkHttp / Ktor / RN fetch), including native `.so` libs via ida-mcp |
| `/apk-compare-versions` | Diff two versions of the same APK, audit a version bump, investigate a release regression | Full delta between two APKs: permissions, exported components, SDK flags, endpoints, hardcoded secrets, SSL pinning, native libs, and the JS bundle for RN apps |

Usage examples:

```
> /apk-find-api workspace/app.apk
> /apk-compare-versions workspace/app-v1.2.apk workspace/app-v1.3.apk
> Diff these two builds and tell me what network endpoints changed
```

## Project Structure

After running `run.sh`, your workspace looks like this:

```
.
├── .mcp.json          # MCP server configuration (ghcr.io/neoz/neo-rev-lab:latest)
├── CLAUDE.md          # Project instructions for Claude Code
├── .claude/
│   └── skills/        # Reverse engineering skills (IDA, angr, etc.)
└── workspace/         # Drop target binaries here (mounted at /workspace/)
```

## Notes

- Only one `ida-mcp` container runs at a time. If the container is already running, Claude Code will reuse it for `dotnet-mcp` and for skill-driven CLI calls (`jadx`, `apktool`, `hermes-dec`, `hbctool`, `angr`) via `docker exec`.
- IDA databases (`.i64`) are created alongside binaries in `workspace/` and persist between sessions.
- The `angr` and `unicorn` Python libraries are pre-installed in the container for symbolic execution and emulation tasks.
- `jadx`, `apktool`, `hermes-dec`, and `hbctool` are pre-installed on `PATH` inside the container for Android / React Native analysis.
