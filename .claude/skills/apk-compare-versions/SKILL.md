---
name: apk-compare-versions
description: "Diff two versions of the same Android APK to surface every meaningful change: permissions, exported components, SDK flags, declared endpoints, hardcoded secrets, SSL pinning wiring, native libraries, and — for React Native apps — the JS bundle and endpoint registry. Static analysis only, runs entirely inside the neo-rev-lab Docker container (jadx CLI, apktool, hermes-dec/hbctool). Handles native Android AND React Native builds as first-class; the RN bundle diff is not a fallback. Use whenever the user wants to compare two APKs, audit a version bump, check what a release changed, diff an old vs new build, investigate a regression, or understand the delta between two installs — even if they don't say the word 'diff'. Prefer this skill over running apk-find-api twice by hand, and over generic file-tree diffs, for any task that starts from two APK files of the same app."
metadata:
  argument-hint: "<old.apk> <new.apk>"
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

## Scope and constraints

This skill runs inside the `neo-rev-lab` Docker image and is static-only. Every tool it relies on lives in the container; the host only drives `docker exec` and reads results from the bind-mounted workspace. There is no Frida, no device, no traffic capture, and no dynamic runtime comparison — if the user wants behavioural differences, say so and stop.

Tools actually available (unchanged from `apk-find-api`):

| Tool | Location | Use for |
|------|----------|---------|
| `jadx` CLI (`java -cp /opt/jadx/jadx.jar jadx.cli.JadxCLI`) | docker | Decompile both APKs to Java/Kotlin trees |
| `apktool` (`/usr/local/bin/apktool`) | docker | Lossless manifest + resource + `apktool.yml` (for versionCode/versionName) |
| `hermes-dec` (`hbc-decompiler`, `hbc-disassembler`) | docker | Decompile RN Hermes bytecode bundles |
| `hbctool` | docker | Alternate Hermes backend (per-function disasm + string-table JSON) |
| `unzip`, `diff`, `comm`, `sort`, `grep`, `head`, `wc`, `sed`, `awk`, `od`, `python3` | docker | Plumbing |
| `ida-mcp` + `idasql` | MCP + docker | Optional: deep `.so` diff (only on user request) |
| `Grep` / `Read` / `Glob` / `Bash` | Host | Sweeps over decompiled output under the bind-mounted workspace |

Known environment details (so runs don't waste calls rediscovering them):

- Prefix every `docker exec` with `MSYS_NO_PATHCONV=1`. Git Bash on Windows otherwise rewrites `/workspace/...` to a Windows path before the call reaches `docker.exe` and the exec fails silently or with a confusing "no such file" error.
- Invoke jadx via the CLI class (`jadx.cli.JadxCLI`). The `/usr/local/bin/jadx` wrapper defaults to the GUI entrypoint, which crashes headlessly on missing `libharfbuzz` and produces an empty output directory with exit code 0 — a false success that invalidates every subsequent phase.
- `file` and `xxd` are not installed. Inspect bundle magic with `od -c` piped from `head -c`.
- There is no `apkid`, `apkleaks`, `trufflehog`, `d2j-dex2jar`, `apk.sh`, `justapk`, `frida`, or `objection` in this container. The reference compare-versions skill in `tools/todo/areclaw/` relies on several of these — do not copy commands from that skill verbatim. Version metadata comes from `apktool.yml`; secret scanning comes from grep patterns; anything device-facing is out of scope.

If any preflight tool is missing, state the degradation in the report header rather than silently skipping a phase.

## Trigger intents

Use this skill when the user says things like:

- "Diff these two APKs."
- "What changed between `v4.12.apk` and `v5.29.apk`?"
- "Compare the old build against the new one."
- "Audit the version bump from X to Y."
- "Did they tighten security in the latest release?"
- "Which endpoints were added/removed between these releases?"
- "Regression report between these two builds."
- Any message that names two APK paths of the same package.

Route elsewhere when:

- User wants a single APK audited → `apk-find-api` (endpoint discovery) or `analysis` (general triage).
- User wants runtime diff / behaviour comparison → not supported here; say so explicitly.
- User has two binaries that are *not* APKs → `analysis` or the IDA skills.

## Workspace conventions

These paths intentionally mirror `apk-find-api` so artifacts compose cleanly if the user later drills into one version.

- Old APK decompile: `workspace/output/<pkg>_<oldver>/`, `workspace/apktool/<pkg>_<oldver>/`
- New APK decompile: `workspace/output/<pkg>_<newver>/`, `workspace/apktool/<pkg>_<newver>/`
- Diff artifacts (permission lists, component lists, host lists, endpoint TSVs per version, intermediate `diff` output): `workspace/artifacts/<pkg>-diff/`
- Final report: `workspace/reports/compare-<pkg>-<oldver>-vs-<newver>.md`
- Container preamble for every command:
  ```bash
  CONTAINER=$(docker ps --filter ancestor=neo-rev-lab --format '{{.Names}}' | head -1)
  # MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" <command>
  ```

Prefer `workspace/artifacts/<pkg>-diff/` over `/tmp/` for every intermediate file. The host is Windows; `/tmp/` inside the container is ephemeral across restarts and invisible from the host. Keeping artifacts in the workspace makes later passes cheap to re-run without re-decompiling.

## Phase 0 — Preflight

Spend ~30 seconds verifying the environment before committing to two parallel jadx decompiles. The goal is to catch three specific traps that produce misleading "success" states further downstream: the GUI-wrapper jadx, a dead container, and missing input APKs. Each check is a single command.

```bash
# Container reachable?
CONTAINER=$(docker ps --filter ancestor=neo-rev-lab --format '{{.Names}}' | head -1)
[ -z "$CONTAINER" ] && echo "No neo-rev-lab container; ask user to launch one via run.sh"

# jadx CLI class works?
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
  java -cp /opt/jadx/jadx.jar jadx.cli.JadxCLI --version

# apktool works?
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" apktool --version

# Both APKs exist inside the container's /workspace/?
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" ls -l /workspace/<old.apk> /workspace/<new.apk>
```

Parse `$ARGUMENTS` as `<old> <new>` — first positional is OLD, second is NEW. If the user passes paths outside `workspace/`, ask them to copy the APKs into the bind-mount; container commands only see `/workspace/`.

Record any preflight failure in the report header. Do not fabricate a comparison from partial state.

## Phase 1 — Decompile both

Run jadx and apktool against each APK. The two APKs are independent, so run jadx-old and jadx-new in parallel; apktool is fast enough to run sequentially afterwards without dominating wall time. jadx on a ~50 MB APK takes 1–3 minutes.

```bash
# jadx for old and new (spawn both in parallel)
for tag in old new; do
  apk=...  # pick the matching input
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c "
    rm -rf /workspace/output/<pkg>_${tag} && mkdir -p /workspace/output/<pkg>_${tag} &&
    java -cp /opt/jadx/jadx.jar jadx.cli.JadxCLI \
      -d /workspace/output/<pkg>_${tag} --deobf /workspace/${apk}
  " &
done
wait
```

Use `--deobf` on both. Without it, R8-mangled names (`a.b.c`) differ randomly between any two decompiles even of the same APK, and the Phase 3 file-tree diff becomes pure noise. `--deobf` assigns stable pseudo-names that preserve cross-version comparison.

Then apktool, which also gives you the version metadata:

```bash
for tag in old new; do
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c "
    mkdir -p /workspace/apktool/<pkg>_${tag} &&
    apktool d -f -s -o /workspace/apktool/<pkg>_${tag} /workspace/<apk_${tag}>
  "
done

# Extract package name + versionName + versionCode from each apktool.yml
for tag in old new; do
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
    grep -E 'versionCode|versionName|-|package' /workspace/apktool/<pkg>_${tag}/apktool.yml
done
```

`-s` skips smali — we have the jadx Java tree. `apktool.yml` is the authoritative source for `versionCode` / `versionName`; the manifest's `android:versionName` is also present but `apktool.yml` is easier to grep and already aggregates everything. Use these values to compute `<oldver>` / `<newver>` and name the report file.

A handful of jadx decompile errors is normal (Google Play Integrity / `com.pairip.licensecheck.*` typically fail). Proceed as long as `workspace/output/<pkg>_*/sources/` is populated on both sides.

## Phase 2 — Manifest and configuration diff

Before diffing code, diff the declared surface. This is usually the highest signal-to-noise section of the whole report: permissions and components are small enough to inspect by hand and load-bearing for security posture.

```bash
# Permissions
for tag in old new; do
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
    grep -oE 'uses-permission [^>]+' /workspace/apktool/<pkg>_${tag}/AndroidManifest.xml \
    | sort -u > /workspace/artifacts/<pkg>-diff/perms_${tag}.txt
done
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
  diff /workspace/artifacts/<pkg>-diff/perms_old.txt \
       /workspace/artifacts/<pkg>-diff/perms_new.txt
```

Repeat the same pattern for:

- **Components**: grep `<activity |service |receiver |provider ` lines. Watch for `android:exported="true"` flips and added `<intent-filter>` actions.
- **SDK and flags**: extract `compileSdkVersion`, `targetSdkVersion`, `minSdkVersion`, `android:debuggable`, `android:allowBackup`, `android:usesCleartextTraffic`, `android:networkSecurityConfig`. A drop in `targetSdkVersion` or an `allowBackup="true"` flip after previously being `false` is worth flagging.
- **Meta-data**: `<meta-data name=... value=...>` — catches hardcoded API keys (Google Maps, Firebase App ID), SDK secrets (AppsFlyer, Facebook, App Center), and feature flags.
- **Deep links**: `<data android:scheme=.../host=...>` — new scheme or host may indicate a new entry point.
- **Bundled asset URLs**: `grep -rohE 'https?://[^"<> ]+' res/ assets/` (exclude the RN bundle; Phase 3b covers it). New asset-level hosts are often forgotten configs.

For each category, write per-version lists to `workspace/artifacts/<pkg>-diff/` and `diff` them. Capture the diff output into the report under `## Permissions / Components / SDK & flags / Meta-data / Deep links / Resource URLs` subsections.

Flag any newly-dangerous permission (`CAMERA`, `READ_SMS`, `RECORD_AUDIO`, `ACCESS_FINE_LOCATION`, `READ_CONTACTS`, `SYSTEM_ALERT_WINDOW`, etc.). The bar for "dangerous" is the Android runtime-permission table, not a subjective guess.

## Phase 2.5 — Framework fingerprint diff

Different frameworks put endpoints and logic in different places. Running a Java-code diff on a RN app returns zero meaningful signal (the Java tree is framework-only and identical across app versions). Fingerprint each APK independently, then decide which of Phase 3a or 3b applies.

```bash
for tag in old new; do
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c "
    echo '=== ${tag} ==='
    echo -n 'RN bundle: '; ls /workspace/apktool/<pkg>_${tag}/assets/index.android.bundle 2>/dev/null || echo NONE
    echo -n 'Flutter:   '; ls /workspace/apktool/<pkg>_${tag}/lib/*/libflutter.so 2>/dev/null || echo NONE
    echo 'Native libs:'
    ls /workspace/apktool/<pkg>_${tag}/lib/arm64-v8a/ 2>/dev/null | head -15
  "
done
```

Decision table:

| Old | New | Treatment |
|-----|-----|-----------|
| Native | Native | Phase 3a (Java-tree diff) + Phase 4 (Retrofit diff) |
| RN | RN | Phase 3b (bundle diff) — skip 3a noise |
| Flutter | Flutter | Note limited static surface; diff `libapp.so` string tables via Phase 6 |
| Native | RN (or RN → Native) | **Framework migration**. Diff becomes "old API surface vs new API surface", not file-level. Run both phases for each side against its own format, then merge into the report under a dedicated "Framework migration" section. |

Framework migrations are the loudest possible signal — a rewrite. Do not try to file-diff across frameworks; it is meaningless. Compare intents: declared permissions, declared deep links, and the set of endpoints. That is what the user actually cares about after a rewrite.

## Phase 3a — Native Android code diff (both sides native)

When both APKs are native Android, a file-level diff of the `--deobf` jadx output is useful. Skip this entirely if either side is RN or Flutter — the Java tree carries no app logic there.

```bash
for tag in old new; do
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c "
    cd /workspace/output/<pkg>_${tag}/sources && \
    find . -name '*.java' -o -name '*.kt' | sort \
      > /workspace/artifacts/<pkg>-diff/files_${tag}.txt
  "
done

MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c "
  cd /workspace/artifacts/<pkg>-diff && \
  comm -13 files_old.txt files_new.txt > added_files.txt && \
  comm -23 files_old.txt files_new.txt > removed_files.txt && \
  comm -12 files_old.txt files_new.txt > common_files.txt && \
  wc -l added_files.txt removed_files.txt common_files.txt
"
```

Filter the added/removed lists by domain. The most informative prefixes are the app's own package (reverse-DNS of the manifest `package`) — library changes (`androidx/`, `com/google/`, `kotlin/`) matter mostly when they indicate a dependency upgrade, not a direct code change.

For content diff, don't `diff -r` the whole tree — on a real app this produces tens of thousands of lines of noise from R8 renaming artefacts and string-pool reordering, even with `--deobf`. Instead, target the files that carry security-relevant signal:

- Retrofit service interfaces (files containing `@GET`/`@POST`)
- `Retrofit.Builder` / `OkHttpClient.Builder` call sites
- `Interceptor` / `Authenticator` implementations (auth and refresh logic)
- Classes whose name matches `(?i)auth|login|token|crypto|cipher|cert|pin|secure`
- DI modules (`@Module`, `@Provides`) — base URLs and timeouts live here
- `BuildConfig.java` generated files — injected build-time constants

Use grep to find the files that exist in both versions and match one of these patterns, then run `diff` only on those. The ratio of signal to noise is ~100× better than tree-wide diff.

## Phase 3b — React Native bundle diff (first-class)

This is the phase the reference skill lacks entirely. On RN builds, virtually all change lives in `assets/index.android.bundle`. Plan for it; don't treat it as an afterthought.

### Step 1 — Identify bundle format per side and materialize greppable `.js`

```bash
for tag in old new; do
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c "
    b=/workspace/apktool/<pkg>_${tag}/assets/index.android.bundle
    echo -n '${tag} bundle magic: '; head -c 16 \$b | od -c | head -1
    echo -n '${tag} bundle size:  '; wc -c < \$b
  "
done
```

Magic-byte interpretation:

- Starts with `var __BUNDLE_START_TIME__` or `(function(global)` → **Metro plain JS**. Already readable. Copy to `workspace/artifacts/<pkg>-diff/bundle_<tag>.js`.
- Starts with `HBCx` (or bytes `c1 1e c0 c3`) → **Hermes bytecode**. Run `hbc-decompiler` to produce pseudo-JS at the same path.

If the two sides disagree on format (e.g. old = Metro, new = HBC), that alone is a noteworthy migration — record it in the report. Normalize both to pseudo-JS so string-level diff works across the pair.

If `hbc-decompiler` fails on either side (HBC-version drift), cascade: `hbc-disassembler` for HBC asm (URLs appear as `LoadConstString` operands), then `hbctool disasm` (different version coverage, produces per-function `.hasm` plus a flat string-table JSON). Only fall back to `strings` as a last resort; structural loss that forces this falls in the "Unresolved" report section.

### Step 2 — Host-level diff

Dedup URL hosts on each side, then set-diff. This filters out dependency doc-URL noise (mozilla.org, css-infos.net, github.com) in one pass and surfaces app-level host additions and removals cheaply.

```bash
for tag in old new; do
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c "
    grep -ohE 'https?://[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]' \
      /workspace/artifacts/<pkg>-diff/bundle_${tag}.js \
      | sort -u > /workspace/artifacts/<pkg>-diff/hosts_${tag}.txt
  "
done

MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c "
  cd /workspace/artifacts/<pkg>-diff && \
  comm -13 hosts_old.txt hosts_new.txt > added_hosts.txt && \
  comm -23 hosts_old.txt hosts_new.txt > removed_hosts.txt
"
```

Bucket the added/removed hosts into app-owned, cloud (AWS/GCP/Firebase/AppCenter), and noise. Only app-owned and cloud hosts belong in the report.

### Step 3 — Endpoint-registry diff

RN apps almost always centralize endpoints in a single config module that declares `var HOST = ...`, helper functions like `getApiUrl(p) { return HOST + VER + p; }`, and hundreds of named constants (`LOGIN`, `GET_PROFILE`, …). This is the registry. For each side:

1. Find the registry line range by grepping for `var HOST` / `var [A-Z_]+_?(HOST|URL|API|BASE)[ =]` co-located with the app's own domain.
2. Extract every `var NAME = helperFn('path')` and `var NAME = 'literal';` to a TSV `(name, resolved_url)` using the helper definitions.
3. Set-diff the constant-name lists and the URL lists.

The extractor is a ~30-line Python snippet that mirrors the approach in `apk-find-api` Phase 3b Step 3; adapt it to read both sides into `endpoints_old.tsv` and `endpoints_new.tsv`, then produce `added_endpoints.txt`, `removed_endpoints.txt`, and `renamed_or_rehomed.txt` (same constant name, URL changed).

**Renamed-or-rehomed** is the most informative list. An endpoint moving from `host_a/api/v1/foo` to `host_b/api/v2/foo` under the same constant name is the kind of change that silently breaks any API consumer that wasn't generated from this bundle. Call these out individually in the report.

### Step 4 — HTTP-client wrapper diff

Find each side's HTTP wrapper (the `_makeAuthRequest`-style function, or the `axios.create`/`fetch` wrapper) and diff them directly with `diff -u`. The meaningful deltas are:

- Default headers (`Content-Type`, `Cache-Control`, auth key names)
- Auth-token attachment strategy (`Authorization: Bearer` vs. custom header vs. cookie)
- **Hardcoded Bearer literals** — was `Bearer <hex>` added, removed, or rotated? (See Phase 5.)
- **SSL pinning wiring** — is `sslPinning: { certs: [...] }` built into a `params` object that is actually passed to the HTTP call, or is it still dead code built and dropped? (See Phase 5.)
- Success-envelope logic (`response.status_code === 200` vs. HTTP-status trust)
- Refresh / 401 handling

### Step 5 — Java-side sanity check

```bash
grep -rnE '@(GET|POST|PUT|DELETE)' workspace/output/<pkg>_old/sources/ \
  workspace/output/<pkg>_new/sources/  # expect zero on pure RN
```

If either side returns hits, the app is hybrid — also run Phase 3a/4 on those results and merge.

## Phase 4 — API endpoint diff

This phase produces normalized endpoint lists per version and diffs them. The extraction heuristics depend on the framework detected in Phase 2.5:

- **Both native**: grep `@(GET|POST|PUT|DELETE|PATCH|HEAD|HTTP|Url)` across each decompile and extract `(verb, path, return_type)` tuples per interface file. Then set-diff paths. Base-URL changes come from `baseUrl(...)` call sites and `BuildConfig` constants.
- **Both RN**: use the Phase 3b Step 3 output directly. The registry diff *is* the endpoint diff.
- **Hybrid / migration**: produce both tables and label each side's origin.

Regardless of path, write the normalized tuples to `workspace/artifacts/<pkg>-diff/endpoints_{old,new}.tsv` and the diff outputs to `added.tsv`, `removed.tsv`, `changed_base_url.tsv`. These are the canonical artefacts the report cites.

For every `changed_base_url.tsv` row, also note *how* the base URL moved — a host change (prod → staging, or one backend → another) is a much bigger deal than a version suffix bump (`/api/v1/` → `/api/v2/`). Both happen in practice.

## Phase 5 — Security diff

Static patterns that catch most of what matters, across either framework. Run each grep against both decompile trees *and* both normalized bundle copies (for RN), then diff the per-pattern outputs.

Targets:

- **Hardcoded Bearer literals**: `Bearer [a-fA-F0-9]{16,}`. List them per side, then diff. Rotation, addition, or removal each mean something different.
- **Authorization-header construction**: lines containing `Authorization` and either `Bearer` or a custom scheme. Catches auth-flow rewrites.
- **SSL pinning wiring**: search for `sslPinning`, `CertificatePinner`, `OkHttpClient.Builder().certificatePinner`, `trustManager`. For RN, check whether `sslPinning` appears in the *params object passed to the HTTP call* or only in a discarded local — the dead-code anti-pattern is specific to the latter, and "moved from dead code to live" is a security improvement worth celebrating.
- **Cleartext flags**: `usesCleartextTraffic` in the manifest; per-domain exceptions in `res/xml/network_security_config.xml`.
- **Staging host bake-ins**: `https?://[a-z0-9.-]*(staging|stg|dev|qa|uat)[a-z0-9.-]*` and `HOST.*===.*staging` branches. Both compilation of a staging URL and runtime detection of it are red flags; track per side.
- **Hardcoded secrets**: `AKIA[A-Z0-9]{16}` (AWS access key), `AIza[0-9A-Za-z_-]{35}` (Google API key), `ya29\.[A-Za-z0-9_-]+` (Google OAuth token), `sk_(live|test)_[0-9a-zA-Z]{24,}` (Stripe), `xox[baprs]-[0-9A-Za-z-]+` (Slack).
- **Root / Frida / integrity checks**: `isRooted`, `SafetyNet`, `PlayIntegrity`, `frida`, `/proc/self/maps`, `ptrace`. Newly-added detection routines belong under "Security → Improvements"; removed ones under "Regressions".
- **Crypto**: `Cipher.getInstance("AES`", `"DES"`, `"RC4"`, `SHA1`, `MD5` — diff of usage changes.
- **Storage key names**: `EncryptedSharedPreferences`, `DataStore`, `getSharedPreferences("(.*)"` keys. Changes indicate a storage-schema migration consumers may need to mirror.

Report each finding with: pattern, per-version match count, the specific lines added or removed, and a one-line "why this matters" note.

## Phase 6 — Native library diff

Cheap pass: compare the set and sizes of `lib/*/*.so` between the two APKs.

```bash
for tag in old new; do
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c "
    unzip -l /workspace/<apk_${tag}> | awk '/\.so\$/ {print \$4, \$1}' \
      | sort > /workspace/artifacts/<pkg>-diff/so_${tag}.txt
  "
done

MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
  diff /workspace/artifacts/<pkg>-diff/so_old.txt \
       /workspace/artifacts/<pkg>-diff/so_new.txt
```

Added `.so` files often indicate a new dependency (e.g. a newly-introduced `libsqlcipher.so` implies encrypted storage adoption). Removed `.so` files indicate feature removal or a framework migration (losing `libflutter.so` alongside gaining `libhermes-executor-release.so` = Flutter → RN rewrite).

Deep symbol-level diff of a specific `.so` via IDA/idasql is **opt-in only**. It is expensive (two sequential IDA database loads) and useful only when the size delta or added/removed binary merits it. When the user asks for it, follow the project's `CLAUDE.md` idasql-over-HTTP pattern on each `.i64` in turn, extract exported-symbol sets and URL string tables, and diff those. Kill each idasql HTTP server before moving on (one server per database is the hard limit).

## Phase 7 — Report

Save to `workspace/reports/compare-<pkg>-<oldver>-vs-<newver>.md`. Keep section names stable — downstream tooling and future skill runs key on them.

```markdown
# Version Comparison: <App Name> (<pkg>)

> Static analysis only (neo-rev-lab Docker). No runtime traffic was captured.
>
> - Old: <versionName> (<versionCode>)  —  `<old.apk>`
> - New: <versionName> (<versionCode>)  —  `<new.apk>`
> - Old framework: <native | RN | Flutter | hybrid>
> - New framework: <native | RN | Flutter | hybrid>    <flag if they differ>
> - Bundle format (RN): <Metro plain JS | Hermes bytecode | n/a>  (per side)

## Summary
<3–5 bullets that would stand alone if the rest of the report were unread.>

## Permissions
### Added
- <permission> — <runtime-permission tier / why it matters>
### Removed
- <permission>

## Components
### Added
- <type> <name> — exported: <yes/no>, new intent-filter: <...>
### Removed
- ...
### Exported-flag flips
- <name> — was exported=<yes/no>, now exported=<yes/no>

## SDK & flags
| Key | Old | New | Notes |

## Meta-data and deep links
<Added / removed / changed hosts and schemes.>

## API changes
### New endpoints
| Constant / interface | Verb | URL | Notes |
### Removed endpoints
| ... |
### Changed base URL or path
| Constant | Old URL | New URL | What changed |

## RN bundle changes
<Only if either side is RN. Output of Phase 3b Steps 2–4.>
### Endpoint-registry constant diff
### Host-URL literal diff
### HTTP-client wrapper diff

## Auth-wrapper changes
### Hardcoded Bearer literals
| Status | Backend / base URL | Literal | Evidence |
| added / removed / rotated | ... | ... | file:line |
### SSL-pinning wiring
<Dead-code → live, live → dead-code, unchanged. Per-callsite.>

## Security changes
### Improvements
- <change> — <impact>
### Regressions
- <change> — <risk>

## Native library changes
### Added `.so`
### Removed `.so`
### Size deltas (> 10%)

## Framework migration notes
<Only if framework changed. What moved where, which surfaces were rewritten, which stayed.>

## Unresolved / obfuscated
- <Endpoints that couldn't be statically resolved on either side>
- <Bundles that failed hermes-dec + hbctool + hbc-disassembler (structural loss documented)>

## Source map
- Old decompile: `workspace/output/<pkg>_<oldver>/`, `workspace/apktool/<pkg>_<oldver>/`
- New decompile: `workspace/output/<pkg>_<newver>/`, `workspace/apktool/<pkg>_<newver>/`
- Diff artefacts: `workspace/artifacts/<pkg>-diff/`
- Per-version endpoint TSVs: `endpoints_old.tsv`, `endpoints_new.tsv`
- Diff outputs: `added.tsv`, `removed.tsv`, `changed_base_url.tsv`, `added_hosts.txt`, `removed_hosts.txt`, `added_files.txt`, `removed_files.txt`
```

Do not emit a synthetic Postman collection from the diff. The container cannot capture traffic, and a collection derived from diff-only evidence would misrepresent reliability.

## Failure and recovery

- **One jadx run errors out, the other succeeds**: proceed with what you have and mark the failed side in the report header. A partial diff honestly labelled is more useful than no report.
- **Both sides are RN, but one's bundle is Hermes and the other is Metro**: normalize both to pseudo-JS via `hbc-decompiler`, then diff the text. Format-migration is itself a finding; put it in "RN bundle changes".
- **apktool fails on the new APK (new resource-table layout)**: rerun with `apktool --advanced` or update apktool in the container. If still failing, note "manifest diff unavailable for new version" in the header and proceed with what jadx gave you — permission and component extraction can also be scraped from the smali-free jadx resource output as a fallback.
- **Phase 3a produces runaway diff output on two native APKs with aggressive obfuscation**: `--deobf` wasn't enough. Narrow to grep-seeded target files (see Phase 3a) and skip the tree-wide diff. Record the obfuscation level in the report so the reader knows the file-level diff is not exhaustive.
- **Endpoint extraction on RN can't resolve a helper function** (e.g. the registry uses `_dependencyMap[N]` for a constant that is itself built from a cross-module call): list the unresolved constants in "Unresolved / obfuscated" with their line numbers rather than guessing. An honest gap is more useful than a fabricated endpoint.
- **Preflight failure**: stop and ask the user to launch the container. Do not fabricate a comparison from partial state.

## Handoff patterns

- `apk-compare-versions` → `apk-find-api`: when a single version is interesting enough to warrant its own full API surface report.
- `apk-compare-versions` → `xrefs` / `decompiler`: when a specific Java/Kotlin function added in the new version needs deep reading.
- `apk-compare-versions` → `analysis`: when the diff surfaces suspicious new behaviour worth whole-app triage (e.g. a new dex loader or reflection-heavy module).
- `apk-compare-versions` → `annotations`: when findings should be persisted into an IDA database for the native `.so` that changed.
