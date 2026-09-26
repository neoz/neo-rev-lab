---
name: using-idasql
description: "Entry point for any idasql / IDA Pro database work in this project. Use FIRST, before any other idasql skill (analysis, decompiler, xrefs, connect, ...), whenever the user mentions idasql, IDA, an .i64/.idb, or a native binary under workspace/ and asks to analyze, triage, decompile, disassemble, find callers/xrefs, search strings, rename, comment, retype, or patch it. Use this instead of connect to start a session in this project. Bootstraps idasql inside the neo-rev-lab Docker container and routes the request to the right idasql domain skill."
metadata:
  argument-hint: "[binary or .i64 under workspace/] [what you want to know]"
allowed-tools:
  - Bash
  - Read
  - Skill
---

# Using idasql in this project

This skill is a router. It does two things: bootstrap an idasql session the
way this project requires (inside Docker), then hand off to one of the 15
idasql domain skills. It never replaces them — load the target skill and
follow it.

## 1. Bootstrap (project-specific)

`idasql` is NOT on the host. It runs only inside the `neo-rev-lab` container,
and only `/workspace/` (host `./workspace/`) is shared. Put the input binary
or database in `./workspace/` first.

**Translation rule:** every `idasql ...` command or `curl localhost:8080/...`
call shown in the domain skills must be rewritten into one of the two forms
below. Everything else they say (SQL, contracts, schemas) applies as-is.
Specifically:
- Port `8080` in the domain skills becomes the port of your server.
- `-f <file>` / `--export <file>` paths must be under `/workspace/`.
- `-i` (REPL) needs `docker exec -it`.
- REPL dot-commands such as `.schema <t>` do not work over HTTP; use
  `PRAGMA table_xinfo(<t>);` instead.

One-shot query (few queries, or a quick look):

```bash
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab \
  /opt/ida-pro/idasql -s /workspace/<file> -q "SELECT * FROM binary;"
```

Iterative session (preferred for real analysis — the database is loaded once):

```bash
# 0. One server per database, one port per server (8081, 8082, ...).
#    Check for a stale server on the same database or the same port.
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab pgrep -af idasql
#    Stop it cleanly (a --write server saves on shutdown)
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab \
  curl -s -X POST http://127.0.0.1:<port>/shutdown

# 1. Start the server (add --write if mutations must persist to the .i64)
MSYS_NO_PATHCONV=1 docker exec -d neo-rev-lab \
  /opt/ida-pro/idasql -s /workspace/<file> --http 8081

# 2. Query it
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab \
  curl -s http://127.0.0.1:8081/query -d "SELECT * FROM binary;"
```

Notes:
- `MSYS_NO_PATHCONV=1` is mandatory under Git Bash, otherwise `/workspace/...`
  is rewritten to a Windows path.
- `-s` accepts a raw binary (`.exe`, `.dll`, ELF, firmware) as well as an
  `.i64`/`.idb`; a raw binary is auto-analyzed. The `.i64` is saved next to it
  only when `--write` is given — without it every open re-analyzes from
  scratch, so use `--write` on the first open of a large binary.
- First open of a large binary can take minutes: start the HTTP server and
  poll with `SELECT * FROM binary;`. If it still has not answered after a few
  minutes, check `pgrep -af idasql`; if the process is gone, rerun once with
  `-q` in the foreground to see the error (a legacy `.idb` exits with code 3
  and prints a `reopen_with` path to use instead).
- Mutations (renames, comments, types, patches) persist only with `--write`,
  and are saved when the server stops via `/shutdown` or `pkill` (SIGTERM).
  Never `pkill -9` a write session — or run `SELECT save_database();` first.
- Always orient first with `SELECT * FROM binary;` before routing.

## 2. Route the request

Pick the primary skill from the user's intent, then invoke it with the Skill
tool (for example `Skill(decompiler)`).

| User intent / trigger words | Skill |
|-----------------------------|-------|
| "what does this binary do", triage, suspicious behavior, crypto/network, audit | `analysis` |
| list/inspect the binary's functions (`funcs`), segments, instructions, basic blocks, operands, disasm | `disassembly` |
| decompile, pseudocode, ctree, local variables, labels | `decompiler` |
| callers, callees, who calls X, imports usage, call graph, data refs | `xrefs` |
| find a function/type/label/member by name pattern | `grep` |
| strings, byte patterns, raw bytes, rebuild string list | `data` |
| rename, comment, bookmark, apply prototype, clean up for review, function folders | `annotations` |
| create/modify struct, union, enum, typedef, parse C declaration, type folders | `types` |
| breakpoints, patch bytes, patch inventory | `debugger` |
| store notes/progress in the database (netnode_kv) | `storage` |
| look up an idasql built-in SQL function signature (not the binary's functions) | `functions` |
| what's on screen / selected in the IDA GUI | `ui-context` — unavailable in neo-rev-lab (headless idalib); say so and ask for an address or name instead |
| needs IDA SDK logic not exposed as SQL | `idapython` |
| recursive annotation, structure recovery, bottom-up source rebuild | `re-source` |
| CLI flags, REPL, HTTP/MCP server details, runtime settings, schema catalog | `connect` |

Multi-domain requests: run the primary skill first, then enrich with adjacent
ones. Common chains:

- **Triage to annotated function:** `analysis` -> `xrefs` -> `decompiler` -> `annotations`
- **String IOC to patch:** `data` -> `xrefs` -> `debugger` (or `annotations`)
- **Type recovery:** `decompiler` -> `types` -> `annotations`

If the intent is unclear or no row matches, load `connect` — its
"Skill Routing Matrix" and schema catalog are the authoritative fallback.

## 3. Handoff checklist

1. Session bootstrapped and `SELECT * FROM binary;` answered.
2. Target skill loaded via the Skill tool (not recalled from memory).
3. Every command from the target skill translated to the Docker form above.
4. For writes: server started with `--write`, the target skill's
   read -> mutate -> re-read loop followed, and the server stopped with
   `/shutdown` when done.
