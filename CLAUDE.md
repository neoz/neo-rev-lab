# CLAUDE.md

## idasql must run inside the Docker container

`idasql` is not installed on the host. It runs inside the `neo-rev-lab` Docker
container, with databases under `/workspace/` (bind-mounted from `./workspace/`
on the host).

The container name is always `neo-rev-lab` — use it directly, no discovery
needed:

```bash
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab \
  /opt/ida-pro-9.3/idasql -s /workspace/<db>.i64 -q "SELECT * FROM welcome;"
```

For iterative analysis, start a long-lived HTTP server once and query it
repeatedly (avoids per-query docker-exec overhead):

```bash
MSYS_NO_PATHCONV=1 docker exec -d neo-rev-lab \
  /opt/ida-pro-9.3/idasql -s /workspace/<db>.i64 --http 8081

docker exec neo-rev-lab curl -s http://127.0.0.1:8081/query \
  -d "SELECT * FROM welcome;"
```

Notes:
- `MSYS_NO_PATHCONV=1` is required under Git Bash — otherwise Unix-style paths
  (`/workspace/...`, `/opt/...`) get rewritten to Windows paths before reaching
  `docker.exe` and the exec fails.
- Use `--write` on the idasql command line when mutations must persist to the
  `.i64` on exit.
- Only one `--http` server per database at a time; kill stale servers before
  reopening the same database.

## Other reverse-engineering tools live in the same container

`neo-rev-lab` ships a broader RE toolbox. Most tools have shims on
`/usr/local/bin`, so the canonical invocation is just the tool name through
`docker exec` — same shape as the idasql examples above:

```bash
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab r2 -A /workspace/<binary>
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab jadx -d /workspace/out /workspace/<app>.apk
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab apktool d /workspace/<app>.apk
```

### Installed tool catalog (current)

Authoritative list — use this instead of running `ls /opt` each session. If a
tool looks missing in practice, the image may have evolved; verify with the
discovery commands at the end of this section before assuming the list is
stale.

Disassembly / decompilation:
- `idasql` — IDA Pro 9.3 SQL frontend (`/opt/ida-pro-9.3`, also at `/opt/ida-pro`)
- `r2`, `radare2` — radare2 6.1.4 (`/usr/bin/`)

Java decompilers (the four-decompiler ladder — pick per artifact):
- `jadx` — `/opt/jadx/jadx.jar` (shim `/usr/local/bin/jadx`)
- `cfr` — `/opt/cfr/cfr.jar` (shim `/usr/local/bin/cfr`)
- `procyon` — `/opt/procyon/procyon.jar` (shim `/usr/local/bin/procyon`)
- `vineflower` — `/opt/vineflower/vineflower.jar` (shim `/usr/local/bin/vineflower`, also aliased as `fernflower`)

Android / mobile:
- `apktool` — `/opt/apktool/apktool.jar` (shim `/usr/local/bin/apktool`)
- `hbctool` — Hermes bytecode editor (pip-installed, `/usr/local/bin/hbctool`)
- `hbc-decompiler`, `hbc-disassembler`, `hbc-file-parser` — `hermes-dec` entry points (pip-installed under `/usr/local/bin/`)

Symbolic execution / scripting:
- `angr` — Python module + `/usr/local/bin/angr` CLI; `unicorn` is also installed
- `python3`, `uvx`, `bun`, `java` — runtimes on PATH

Triage utilities (Debian packages, on PATH):
- `file`, `xxd`, `rg` (ripgrep)

Tools without a shim (e.g. the Java decompiler `.jar`s) can also be invoked
directly from their install dir when you need flags the shim swallows:

```bash
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab \
  java -jar /opt/cfr/cfr.jar /workspace/<input>.jar --outputdir /workspace/out
```

Re-discovery (only if the catalog above looks stale):

```bash
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab ls /opt              # installed packages
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab command -v <tool>    # is it on PATH?
```

Conventions to keep in mind:
- All paths inside the container are POSIX; the same `MSYS_NO_PATHCONV=1`
  caveat applies to every `docker exec` from Git Bash, not just idasql.
- Use `/workspace/...` for any input/output you want visible on the host
  (it's the only bind-mount). Anything written elsewhere stays inside the
  container and disappears on rebuild.
- For interactive sessions (e.g. `r2` REPL) add `-it`:
  `MSYS_NO_PATHCONV=1 docker exec -it neo-rev-lab r2 /workspace/<binary>`.
