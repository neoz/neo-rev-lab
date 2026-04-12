# reverse

AI-assisted reverse engineering lab powered by Claude Code and MCP (Model Context Protocol).

Runs IDA Pro, JADX, .NET decompiler, and angr inside a Docker container, exposed to Claude Code as MCP tool servers so you can analyze binaries conversationally.

## Prerequisites

- **Docker Desktop** -- install from https://www.docker.com/products/docker-desktop/ if not already available.
- **Claude Code** -- install via `npm install -g @anthropic-ai/claude-code`.
- **IDA Pro installer** -- place `ida-pro_93_x64linux.run` in `tools/ida/`.
- **idasql binary** -- place the Linux `idasql` binary in `tools/idasql/`.

## Quick Start

### 1. Build the Docker image

Open PowerShell in the project root and run:

```powershell
.\build.ps1
```

This builds the `neo-rev-lab` Docker image containing IDA Pro, idasql, JADX MCP, .NET MCP, angr, and the ida-mcp server.

### 2. Place your target binary in the workspace

Copy the binary (ELF, PE, APK, .NET assembly, etc.) you want to analyze into the `workspace/` folder:

```
workspace/
  your_target.exe
  another_sample.apk
```

This folder is bind-mounted into the container at `/workspace/`, so any file you place here becomes accessible to the analysis tools.

### 3. Launch Claude Code

Start Claude Code from the project root:

```bash
claude
```

On first launch, Claude Code will detect the `.mcp.json` configuration and prompt you to approve the MCP servers. **Accept all three**:

| Server | Purpose |
|---|---|
| `ida-mcp` | IDA Pro decompiler, disassembly, xrefs, type analysis |
| `dotnet-mcp` | .NET assembly decompilation and inspection |
| `jadx-mcp` | Android APK/DEX decompilation |

The `ida-mcp` server starts the Docker container automatically. The other two servers (`dotnet-mcp`, `jadx-mcp`) run inside the same container via `docker exec`.

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

## Project Structure

```
.
├── .mcp.json          # MCP server configuration for Claude Code
├── build.ps1          # Builds the neo-rev-lab Docker image
├── debug.ps1          # Opens a shell inside the running container
├── Dockerfile         # Container with IDA Pro, JADX, .NET MCP, angr
├── workspace/         # Drop target binaries here (mounted at /workspace/)
├── reports/           # Analysis reports output
└── tools/
    ├── ida/           # IDA Pro installer and keygen patch
    ├── idasql/        # idasql binary (SQL interface for IDA)
    ├── idasql-skills/ # Claude Code plugin with IDA analysis skills
    ├── jadx-mcp/      # JADX MCP server jar
    ├── dotnet-mcp/    # .NET decompiler MCP server
    └── symbolic-execution-tutorial/
```

## Debugging

To open an interactive shell inside the running container:

```powershell
.\debug.ps1
```

## Notes

- Only one `ida-mcp` container runs at a time. If the container is already running, Claude Code will reuse it for `dotnet-mcp` and `jadx-mcp` via `docker exec`.
- IDA databases (`.i64`) are created alongside binaries in `workspace/` and persist between sessions.
- The `angr` Python library is pre-installed in the container for symbolic execution tasks.
