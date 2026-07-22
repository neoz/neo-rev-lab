# CLAUDE.md

## idasql must run inside the Docker container

`idasql` is not installed on the host. It runs inside the `neo-rev-lab` Docker
container, with databases under `/workspace/` (bind-mounted from `./workspace/`
on the host).

The container name is always `neo-rev-lab` — use it directly, no discovery
needed:

```bash
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab \
  /opt/ida-pro/idasql -s /workspace/<db>.i64 -q "SELECT * FROM binary;"
```

For iterative analysis, start a long-lived HTTP server once and query it
repeatedly (avoids per-query docker-exec overhead):

```bash
MSYS_NO_PATHCONV=1 docker exec -d neo-rev-lab \
  /opt/ida-pro/idasql -s /workspace/<db>.i64 --http 8081

docker exec neo-rev-lab curl -s http://127.0.0.1:8081/query \
  -d "SELECT * FROM binary;"
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
- `idasql` — IDA Pro SQL frontend (`/opt/ida-pro`, version-independent install path)
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
- `r2pipe` — Python bindings for radare2 (use from any in-container script)
- `python3`, `uvx`, `bun`, `java` — runtimes on PATH

Project reversing scripts (under `/opt/scripts`, shim on PATH):
- `delphi-reverser` — `/opt/scripts/delphi_reverser.py` (shim `/usr/local/bin/delphi-reverser`)

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

## `delphi-reverser` — Delphi PE structural analyzer

`delphi-reverser` is a project-local Python script (source at
`tools/scripts/delphi_reverser.py`, baked into the image at
`/opt/scripts/delphi_reverser.py`) that wraps `r2pipe` to recover Delphi-
specific structure from any Win32 / Win64 binary built with Embarcadero /
Borland RAD Studio (verified Delphi 2010 through Delphi 12 / Athens).

Capabilities:
- Auto-detects bitness and confirms Delphi via the compiler string or
  `dbk_fcall_wrapper` export.
- Scans `.data` / `.rdata` / `.text` for VMT self-pointer signatures and
  recovers per-class `ClassName`, `Parent`, `InstanceSize`, `TypeInfo`,
  `FieldTable`, `MethodTable`, `IntfTable`, plus published method
  `(name, address)` pairs. Probes both the classic 22-slot and modern
  25-slot VMT header layouts.
- Dumps Delphi long-string constants (UnicodeString @ codepage 1200,
  AnsiString @ 1252 / 0 / 65001) by matching the `-1` ref-count + length
  header that precedes string literals.
- Enumerates RCDATA resources into `DVCLAL`, `PACKAGEINFO`, `TFORM`,
  `OTHER_RCDATA` buckets; can dump each `TPF0`-magic DFM stream verbatim.
- Heuristic xref hunt for license / serial / trial code paths.

Invocation (always inside the container, binary in `/workspace/`):

```bash
MSYS_NO_PATHCONV=1 docker exec neo-rev-lab \
  delphi-reverser /workspace/<binary>.exe --out /workspace/<outdir>
```

Actions (default `info classes strings resources`; `all` runs everything):

    info  classes  methods  strings  forms  resources  licenses  all

Useful flags:
- `--out DIR` — output dir (defaults to `./delphi_out` relative to cwd; use
  a `/workspace/...` path so artifacts survive on the host)
- `--limit N` — cap on dumped DFM forms (default 100)
- `--no-analysis` — skip the r2 `aa` pass (much faster, but `licenses`
  xref data will be empty)
- `--quiet` — suppress r2's chatter

Output layout under `--out`:
- `info.txt`, `classes.txt`, `methods.txt`, `strings.txt`, `resources.txt`
- `forms/<TFormName>.dfm` — raw DFM bytes (run a DFM parser separately to
  decode; the script intentionally does not)
- `licenses.json` — list of `{addr, text, keywords, xrefs[]}` hits

Implementation notes worth remembering:
- One r2 session is held open for the whole run, so `aa` is paid once.
- Bulk reads use `p8` (raw hex) rather than `pxj` (JSON list) — roughly 4x
  faster for the megabyte-scale scans in `scan_vmts` / `scan_delphi_strings`.
- VMT parent resolution dereferences once: `vmtParent` stores the address of
  the parent VMT's `SelfPtr` slot, not the parent VMT itself.
