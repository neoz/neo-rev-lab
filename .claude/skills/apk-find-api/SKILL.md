---
name: apk-find-api
description: "Discover and document every API endpoint of an Android APK using static analysis only: jadx CLI, apktool, grep, plus ida-mcp/idasql for native .so libraries. Handles native Android (Retrofit/OkHttp/Ktor) AND React Native (Hermes/JSC) builds — the RN bundle case is first-class, not a fallback. Use whenever the user wants to map an app's API surface, find endpoints, enumerate Retrofit/OkHttp calls, reverse-engineer an API client, or list the URLs an APK talks to — even if they don't say the word 'API'. Prefer this skill over generic reverse-engineering skills for any task that starts from an APK file or Android package name."
metadata:
  argument-hint: "<apk_path_or_package_name>"
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

## Scope and constraints

This skill runs inside the `neo-rev-lab` Docker image. It is static-only. There is no Frida, no device, no network interception, no Postman/OpenAPI generator, and no `apkleaks` inside the container — so obfuscated or reflection-hidden endpoints must be resolved statically or explicitly left unresolved. Do not fabricate endpoints.

Tools actually available:

| Tool | Where | Use for |
|------|------|---------|
| `jadx` CLI (via `java -cp`) | `/opt/jadx/jadx.jar` (docker) | Decompilation to disk, enabling bulk Grep |
| `apktool` | `/usr/local/bin/apktool` (docker) | Fast manifest + resource extraction (lossless) |
| `hermes-dec` (`hbc-decompiler`, `hbc-disassembler`) | docker (`pip`-installed from P1sec/hermes-dec) | Decompile Hermes RN bundles (`.hbc` / `index.android.bundle`) to pseudo-JS |
| `hbctool` | docker (`pip`-installed from bongtrop/hbctool) | Alternate Hermes backend: per-function disassembly + string-table dump; useful when hermes-dec doesn't support the HBC version, or when only URL literals (not call sites) are needed |
| `ida-mcp` + `idasql` | MCP + docker | Native `lib/*.so` endpoint discovery (strings, xrefs, imports) |
| `Grep` / `Read` / `Glob` / `Bash` | Host | Pattern sweeps over decompiled output |

Known gaps in this container (so skill runs don't waste calls rediscovering them):

- **No `file`, no `xxd`** — use `od -c` (with `head -c`) to inspect magic bytes.
- **No `hbcdump`** — but `hermes-dec` and `hbctool` are both installed, so Hermes bundles are first-class. Use `hbc-decompiler` (hermes-dec) for pseudo-JS as the primary path, and `hbctool disasm` as a peer fallback when the decompiler doesn't support the bundle's HBC version — hbctool's per-function disassembly plus string-table dump often works on builds where hermes-dec chokes, and its string table alone recovers all URL literals (see Phase 3b Step 1).
- **The `/usr/local/bin/jadx` wrapper defaults to the GUI entrypoint**, which crashes headlessly on missing `libharfbuzz`. Always invoke the CLI class directly (see Phase 0).
- **Git Bash on Windows** rewrites Unix-style paths (`/workspace/...`) on the way to `docker.exe` — prefix every `docker exec` with `MSYS_NO_PATHCONV=1`.

If any tool is unavailable in the current session, state that limitation in the report header rather than silently skipping a phase.

---

## Trigger intents

Use this skill when the user says things like:

- "Find all API endpoints of this APK."
- "What URLs does `com.example.app` call?"
- "Map the API surface of `base.apk`."
- "Reverse the API client so I can rebuild it."
- "List every Retrofit interface / OkHttp call in this app."
- "What backend does this Android app talk to?"
- A path ending in `.apk` plus any question about networking, auth, or server communication.

Route elsewhere when:

- User wants interactive / runtime tracing → needs Frida; not supported here. Say so.
- User wants generic binary triage, not an APK → `analysis`.
- User already has a specific native function address and wants call-graph detail → `xrefs` / `decompiler`.

---

## Workspace conventions

Follow the project conventions from `CLAUDE.md`:

- APK lives at `workspace/<something>.apk` (mounted at `/workspace/` inside the container).
- jadx decompile goes to `workspace/output/<pkg>/`.
- apktool decode goes to `workspace/apktool/<pkg>/`.
- Intermediate artifacts (host dedup lists, extracted bundle copies) go to `workspace/artifacts/<pkg>/`.
- Final report goes to `workspace/reports/<pkg>-api.md`.
- All container commands use this preamble:

```bash
CONTAINER=$(docker ps --filter ancestor=neo-rev-lab --format '{{.Names}}' | head -1)
# MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" <command>
```

If no container is running, ask the user to launch one (typically by starting Claude Code in a project set up via `run.sh`) before proceeding — do not try to build or start one yourself.

---

## Phase 0 — Preflight

Spend ~30 seconds verifying the environment before committing to a 2-minute decompile. This catches the GUI-wrapper trap, a broken container, and missing utilities that would cause silent failures downstream.

```bash
# 1. Container reachable?
CONTAINER=$(docker ps --filter ancestor=neo-rev-lab --format '{{.Names}}' | head -1)
[ -z "$CONTAINER" ] && echo "No neo-rev-lab container; ask user to launch one"

# 2. jadx entrypoint (the wrapper script defaults to JadxGUI on this image)
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'java -cp /opt/jadx/jadx.jar jadx.cli.JadxCLI --version'

# 3. apktool works?
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" apktool --version

# 4. APK exists at the provided path?
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" ls -l /workspace/<apk>
```

If `java -cp /opt/jadx/jadx.jar jadx.cli.JadxCLI` prints a version, use that invocation everywhere in Phase 1. Do not call the `jadx` wrapper directly — it loads `jadx.gui.JadxGUI` by default and crashes on headless containers that lack font libraries, producing an empty output directory with exit code 0 (a false success).

Record any preflight failures in the report header so the user knows which phases degraded.

---

## Phase 1 — Decompile (jadx CLI)

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'rm -rf /workspace/output/<pkg> && mkdir -p /workspace/output/<pkg> && \
   java -cp /opt/jadx/jadx.jar jadx.cli.JadxCLI \
     -d /workspace/output/<pkg> --deobf /workspace/<apk>'
```

`--deobf` replaces R8-mangled names (`a.b.c`) with stable pseudo-names, which dramatically improves Grep signal. A handful of decompile errors (often from Google Play Integrity / `com.pairip.licensecheck.*`) is expected and does not block analysis — proceed as long as `workspace/output/<pkg>/sources/` is populated.

In parallel, run apktool for the manifest and resources — jadx produces decompiled XML but apktool's output is lossless and faster to navigate:

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'mkdir -p /workspace/apktool/<pkg> && \
   apktool d -f -s -o /workspace/apktool/<pkg> /workspace/<apk>'
```

`-s` skips smali (we have jadx for code); this is the fast path for manifest + resources + bundled assets + native libs listing.

Extract the package name from the manifest's root element and use it for the `<pkg>` token in subsequent paths.

---

## Phase 2 — Manifest and configuration baseline

Before touching code, drain every URL and host that is declared in metadata. These are the easiest wins and often the authoritative list.

1. Read `workspace/apktool/<pkg>/AndroidManifest.xml`:
   - `usesCleartextTraffic` flag
   - `android:networkSecurityConfig` reference → pull the referenced XML
   - `<intent-filter>` `<data>` host/scheme/path — deep-link URLs frequently mirror web/API hosts
   - API keys in `<meta-data>` (Google Maps `com.google.android.geo.API_KEY`, Firebase `firebase_*` metadata, Facebook `com.facebook.sdk.ApplicationId`)
   - Exported activities/services/receivers and their intent actions
2. Scan resources and bundled assets:
   - `res/values/strings.xml` — URLs sometimes live under keys like `base_url`, `api_host`
   - `res/xml/network_security_config.xml` — pinned hosts and cleartext exceptions
   - `res/raw/*` and `assets/*` — configs, JSON, properties, bundled scripts, `.cer` certificates for pinning

```bash
# Quick URL sweep across all resources
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -rohE 'https?://[^\"<> ]+' /workspace/apktool/<pkg>/res/ /workspace/apktool/<pkg>/assets/ 2>/dev/null | sort -u"
```

Record every host seen into a running "candidate hosts" list. Validate them against code in later phases.

---

## Phase 2.5 — Framework fingerprint

Different frameworks put endpoints in different places, and guessing wrong wastes the whole analysis. Fingerprint before branching:

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'echo "--- RN? ---"; ls /workspace/apktool/<pkg>/assets/index.android.bundle 2>/dev/null
   echo "--- Flutter? ---"; ls /workspace/apktool/<pkg>/lib/*/libflutter.so /workspace/apktool/<pkg>/lib/*/libapp.so 2>/dev/null
   echo "--- Native libs ---"; ls /workspace/apktool/<pkg>/lib/*/ 2>/dev/null | head -20'
```

Decision table:

| Signal | Framework | Primary phase |
|---|---|---|
| `assets/index.android.bundle` exists, `libhermes-*.so` / `libreactnativejni.so` in `lib/` | **React Native** | Phase 3b |
| `lib/*/libflutter.so` + `lib/*/libapp.so` + `assets/flutter_assets/` | **Flutter** | Phase 6 (`libapp.so` holds URL strings) |
| Neither of the above | **Native Android** (Retrofit / OkHttp / Ktor / Volley) | Phase 3a |

A build can also be hybrid (e.g. a native shell with RN screens) — do both branches and merge.

---

## Phase 3a — Retrofit / declared HTTP interfaces (native Android)

This is the goldmine on native Android apps. One grep pass finds them all:

```bash
grep -rnE '@(GET|POST|PUT|DELETE|PATCH|HEAD|HTTP|Url|FormUrlEncoded|Multipart|Streaming)\b' \
  workspace/output/<pkg>/sources/
```

For every file with hits, read the full source — annotation parameters and imports matter.

For each annotated method, extract:

| Field | Source |
|------|--------|
| HTTP verb | The annotation name |
| Path | Annotation value (literal or `{var}` interpolation) |
| Query params | `@Query`, `@QueryMap`, `@QueryName` |
| Form fields | `@Field`, `@FieldMap` |
| Path params | `@Path` |
| Body | `@Body` (note the type) |
| Headers | `@Header`, `@Headers`, `@HeaderMap` |
| Return type | Method signature — usually `Call<T>`, `Observable<T>`, `Flow<T>`, or a `suspend` function returning `T` |
| Auth requirement | Look for `@Authenticated`, or an `Interceptor` that attaches a token (Phase 9) |

For every response/request type `T`, read the model class and list its fields. JSON field names (from `@SerializedName`, `@Json`, `@JsonProperty`, or the bare field name) are what you document.

If Phase 3a returns zero Retrofit annotations on a build that is *not* RN/Flutter, the app likely uses OkHttp directly or Ktor. Jump to Phase 5; also search for Kotlin `suspend fun` declarations in files ending in `*Api.kt` or `*Client.kt`.

---

## Phase 3b — React Native bundle (when `assets/index.android.bundle` is present)

The Java side of an RN app contains only RN bridge libraries — no app endpoints. The authoritative API surface lives in the JS bundle. Treat this as the primary path for RN builds, not a fallback.

### Step 1 — Identify bundle format and materialize a greppable `.js`

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'head -c 16 /workspace/apktool/<pkg>/assets/index.android.bundle | od -c | head -2'
```

**Metro-format plain JS** — starts with `var __BUNDLE_START_TIME__` or `(function(global)`. Already readable source; copy it to a `.js` path so host-side Grep/Read can treat it as text:

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'mkdir -p /workspace/artifacts/<pkg> && \
   cp /workspace/apktool/<pkg>/assets/index.android.bundle \
      /workspace/artifacts/<pkg>/index.android.bundle.js'
```

**Hermes bytecode** — starts with bytes `c1 1e c0 c3` / ASCII `HBCx`. Decompile to pseudo-JS with `hermes-dec` (preinstalled in the container from `github.com/P1sec/hermes-dec`):

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'mkdir -p /workspace/artifacts/<pkg> && \
   hbc-decompiler /workspace/apktool/<pkg>/assets/index.android.bundle \
     /workspace/artifacts/<pkg>/index.android.bundle.js'
```

The output is *pseudo-JS*, not the original source: locals often render as `r0`/`r1`, closures and control flow are approximate, and minified module wrappers stay minified. But string literals — URLs, constant names, header markers like `Authorization`/`Bearer`, envelope fields like `status_code` — decompile verbatim, which is exactly what Steps 2–5 grep for. That means the rest of this phase works on Hermes builds unchanged.

If `hbc-decompiler` errors or produces an empty file (rare, usually an unsupported HBC version), fall back progressively:

1. `hbc-disassembler /workspace/apktool/<pkg>/assets/index.android.bundle /workspace/artifacts/<pkg>/index.android.bundle.hasm` — HBC assembly is noisier but URL literals appear as operands to `LoadConstString`/`NewObjectWithBuffer` instructions, still greppable.
2. `hbctool disasm /workspace/apktool/<pkg>/assets/index.android.bundle /workspace/artifacts/<pkg>/hbctool-out/` — alternate Hermes backend from `bongtrop/hbctool`. Produces a directory with per-function `.hasm` files plus a separate metadata/string-table JSON that enumerates every literal in the bundle. Two reasons to reach for this before giving up on structure:
   - **Version coverage is different from hermes-dec** — when Facebook ships a new Hermes release, one of the two tools often supports the new HBC revision while the other lags. If the hermes-dec cascade fails cleanly, hbctool is worth trying before resorting to `strings`.
   - **The string table is a shortcut for Step 2** — if you only need the host/URL enumeration and not call-site structure, grep the string-table JSON directly; it's flat, deduped by hbctool, and skips the noise of instruction streams.
3. As a last resort, `strings` over the raw bundle bytes. Recovers URLs only; document the loss of structural context (verbs, request shapes, call sites) in the report's "Unresolved" section.

### Step 2 — Host-first dedup (avoid drowning in dependency noise)

A raw `grep 'https?://…'` over an RN bundle returns tens of thousands of lines — most from transitively-bundled CSS/HTML tooling (Mozilla docs, `csstree`, `cssselect`, GitHub warning URLs). Always dedup by host before drilling into paths:

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -ohE 'https?://[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]' \
     /workspace/artifacts/<pkg>/index.android.bundle.js \
     | sort -u > /workspace/artifacts/<pkg>/hosts.txt; wc -l /workspace/artifacts/<pkg>/hosts.txt"
```

Then bucket the hosts:

- **App-owned** — hosts that look like the package's domain, or share a suffix with declared hosts from the manifest/strings.xml.
- **Cloud** — `*.googleapis.com`, `*.amazonaws.com`, `*.firebaseio.com`, `*.cloudfunctions.net`, `*.appcenter.ms`, `*.facebook.com`.
- **Noise** — `mozilla.org`, `reactnative.dev`, `redux.js.org`, `npmjs.org`, `github.com`, `fb.me`, `git.io`, `lodash.com`, `css-infos.net`, `webkit.org`, `drafts.csswg.org`. These get filtered out of the final report; they come from bundled dependency doc strings.

### Step 3 — Find the endpoint-registry module

RN apps almost always centralize endpoints in a single configuration module that declares named base URLs and constants for every path. That module is the mother lode — find it once, extract everything:

```bash
# Find co-located base-URL literals (they cluster in one module)
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -nE 'var [A-Z_]+_?(HOST|URL|API|BASE)[ =]' /workspace/artifacts/<pkg>/index.android.bundle.js | head -20"

# Cluster detection — if many URL literals share a line range, that's the module
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -nE '\"https?://[^\"]*<app-owned-suffix>[^\"]*\"' /workspace/artifacts/<pkg>/index.android.bundle.js | head -30"
```

Read the surrounding ±200 lines. Typical shape:

```js
var HOST = 'https://api.example.com';
var HOST_FOO = 'https://foo.example.com';
var version = '/api/v1/';
var getApiUrl = function(p) { return 'https://api.example.com/api/v1/' + p; };
var LOGIN = getApiUrl('auth/login');
var GET_PROFILE = getApiUrl('user/profile');
// ... often 100s of these
var _default = exports.default = { LOGIN: LOGIN, GET_PROFILE: GET_PROFILE, ... };
```

Record the line range in `workspace/artifacts/<pkg>/endpoint-registry.js` for the report's "Source map" section.

### Step 4 — Identify the HTTP client

```bash
# Count candidates to pick the right wrapper to read
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "f=/workspace/artifacts/<pkg>/index.android.bundle.js; \
   echo 'axios:' \$(grep -c 'axios\\.' \$f); \
   echo 'fetch(:' \$(grep -c 'fetch(' \$f); \
   echo 'XMLHttpRequest:' \$(grep -c 'XMLHttpRequest' \$f); \
   echo 'WebSocket:' \$(grep -c 'WebSocket' \$f)"
```

Whichever is dominant, read that wrapper (typically a `post()` / `get()` helper near the same line range that references `Bearer`, `Authorization`, or a token-store module). Capture:

- Default headers (`Content-Type`, `Cache-Control`, language hints)
- How the auth token is retrieved (`AsyncStorage`, a `CacheLocal`/`Storage` module)
- How auth is attached (`Authorization: Bearer …`, custom header, cookie)
- The success-envelope convention — many RN apps check a `status_code`/`code`/`success` field in the *body* and treat HTTP 200 with a non-success code as an error. Document this; it's load-bearing for anyone rebuilding the client.
- **Dead-code SSL pinning**: watch for a `params` object containing `sslPinning:{certs:[…]}` that is built but *not passed* to the actual HTTP call. This is a common footgun.

### Step 5 — Endpoint → verb expansion

The registry gives you every URL, but not the HTTP verb for each. Resolve verbs by grepping the bundle for each constant and looking at which helper is called:

```bash
# For each constant FOO in the registry:
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -nE '_API\\.default\\.FOO|_API\\[\"FOO\"\\]' /workspace/artifacts/<pkg>/index.android.bundle.js | head -5"
```

The call site will look like `ApiClient.post(_API.default.LOGIN, ...)` → verb is POST. Apply this to every constant; for large registries (>100 endpoints), write a small bash loop over the extracted constant names.

### Step 6 — Java-side sanity check

Confirm no additional endpoints leak from the native side:

```bash
grep -rnE '@(GET|POST|PUT|DELETE)' workspace/output/<pkg>/sources/  # expect zero on pure RN
grep -rnE '<your-app-domain>'      workspace/output/<pkg>/sources/  # expect zero
```

If either returns hits, the app is hybrid — handle them via Phase 3a.

---

## Phase 4 — Base URL / host discovery (native Android path)

Retrofit path strings are relative. Find their bases:

```bash
grep -rnE 'baseUrl|BASE_URL|API_URL|SERVER_URL|ENDPOINT|api_host|Retrofit\.Builder|\.baseUrl\(' \
  workspace/output/<pkg>/sources/
grep -rnE 'https?://[A-Za-z0-9._~:/?#@!$&'\''()*+,;=-]+' workspace/output/<pkg>/sources/ | head -200
```

Cross-check against:

- `BuildConfig.java` generated classes (R8-safe constants often end up here)
- `strings.xml` values from Phase 2
- DI modules (`@Module`, `@Provides`, Dagger/Hilt/Koin) — the base URL is usually injected into a `Retrofit.Builder().baseUrl(...)` site

If multiple base URLs exist (prod, staging, CDN, analytics), document which Retrofit service uses which. A `Retrofit.Builder` with one base URL produces a client for a *set* of interfaces; pair them up.

For RN builds, the base URLs have already been captured in Phase 3b Step 3 — skip this phase.

---

## Phase 5 — Non-Retrofit HTTP, WebSocket, GraphQL, gRPC

Not every app uses Retrofit. Sweep for alternatives on the native side:

```bash
# Raw HTTP
grep -rnE 'HttpURLConnection|OkHttpClient\.Builder|Request\.Builder|\.newCall\(|Volley|RequestQueue|WebView\.loadUrl|loadDataWithBaseURL' workspace/output/<pkg>/sources/

# WebSockets
grep -rnE 'WebSocket|newWebSocket|ws://|wss://|Socket\.IO|io\.socket' workspace/output/<pkg>/sources/

# GraphQL
grep -rnE 'graphql|/graphql|apollo|query\s*[A-Za-z]+\s*[({]' workspace/output/<pkg>/sources/

# gRPC
grep -rnE 'ManagedChannelBuilder|\.grpc\.|\.proto\b|newBlockingStub|newAsyncStub' workspace/output/<pkg>/sources/
```

For RN builds, also check the bundle with the same patterns (adjusted for JS):

```bash
grep -nE 'wss?://|new WebSocket|socket\.io|io\.connect|graphql|/graphql' \
  workspace/artifacts/<pkg>/index.android.bundle.js | head -30
```

For each matching call site, read the enclosing method and trace how the URL/path is constructed (literal, `String.format`, concatenation, `Uri.Builder`, template literal). Note that React Native's built-in `WebSocket` polyfill and `@react-native-firebase/*` Firestore listeners both show up as `WebSocket` hits but don't represent app-level WS endpoints — distinguish accordingly.

---

## Phase 6 — Native (JNI / Flutter) endpoints

Many apps push sensitive URLs into native code to dodge static analysis of the Java side. And every Flutter app puts its endpoints in `libapp.so` (Dart AOT).

1. Enumerate native libraries:
   ```bash
   MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
     unzip -l /workspace/<apk> | grep -E 'lib/.*\.so$'
   ```

   For pure-RN apps, all libs under `lib/` are stock (hermes, jsc, reactnativejni, folly, yoga, fresco, etc.) — you can skip this phase entirely and note "no custom native networking" in the report.

2. For each candidate (prioritize `arm64-v8a`; skip duplicates across ABIs), extract and open in IDA:
   ```bash
   MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
     unzip -o /workspace/<apk> "lib/arm64-v8a/*.so" -d /workspace/native/<pkg>/
   ```
   Then `mcp__ida-mcp__open_database` on the `.so`, and `mcp__ida-mcp__wait_for_analysis`.
3. Start an idasql HTTP server and query via curl (per project `CLAUDE.md`):
   ```bash
   MSYS_NO_PATHCONV=1 docker exec -d "$CONTAINER" \
     /opt/ida-pro-9.3/idasql -s /workspace/native/<pkg>/<lib>.i64 --http 8081

   docker exec "$CONTAINER" curl -s http://127.0.0.1:8081/query -d "
     SELECT content, printf('0x%X', address) AS addr
     FROM strings
     WHERE content LIKE '%http%' OR content LIKE '%/api/' OR content LIKE '%/v1/' OR content LIKE '%/v2/'
     ORDER BY length DESC;"
   ```
4. Tie each URL string back to a `Java_*` JNI function via `xrefs` + `call_graph` (see the `xrefs` skill for patterns). A URL that is only referenced from `Java_com_example_Foo_getToken` tells you that the Java-side `Foo.getToken()` is the entry point — record both.
5. Also check `imports` for `curl_easy_*`, `SSL_*`, `CFURL*`, BoringSSL symbols, and platform networking syscalls; they corroborate that the library actually does HTTP rather than just storing a URL string.

Kill the idasql HTTP server when done to avoid the "one server per database" limit from `CLAUDE.md`.

---

## Phase 7 — Obfuscation triage (static only)

If Phases 3–6 returned suspicious placeholders — single-letter paths, bytes that decode to URLs at runtime, or `Class.forName` / `Method.invoke` patterns — do a static decoding pass instead of punting to Frida (which isn't available):

- Look for string-decoder methods: single-arg `String -> String` or `byte[] -> String` static methods called many times from `<clinit>` blocks. Read the decompilation, and mentally (or on paper) evaluate it over observed inputs. Common patterns: Base64, single-byte XOR with a constant key, char-offset rotation, AES with a hardcoded key.
- For reflective calls, look for adjacent string constants that, once decoded, form class/method names.
- For `BuildConfig` values that are obviously not literal in the source, the original `build.gradle` injected them; check `res/values/strings.xml` and the manifest for injected values.
- **For Metro RN bundles**, modules are addressed by numeric ID (`__d(function(...){...},1234,[...])`). A `_dependencyMap[N]` reference means "the Nth module listed in this file's dependency array". If a URL is built via `_API.default.SOME_THING` where `_API` is `_$$_REQUIRE(_dependencyMap[N])`, resolve N by reading the dependency array at the module's declaration site. This is routine static analysis, not obfuscation per se, but it trips up naive grep.

Every endpoint you cannot resolve this way goes into a dedicated "Unresolved / obfuscated" section in the report. That honest gap is more useful than guessing.

---

## Phase 8 — Security / red-flag audit

Endpoint discovery naturally surfaces several classes of operational/security issue that users want called out explicitly. Run these greps as a fixed pass over both the bundle (for RN) and the decompiled Java tree (for native), and drop any hits into a dedicated report section:

```bash
TARGETS="/workspace/artifacts/<pkg>/index.android.bundle.js /workspace/output/<pkg>/sources"

# Raw IPs (should almost never appear in production endpoints)
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -rohE 'https?://([0-9]{1,3}\\.){3}[0-9]{1,3}(:[0-9]+)?' \$TARGETS 2>/dev/null | sort -u"

# RFC1918 internal IPs specifically (10.x, 172.16-31.x, 192.168.x — indicate dev/staging leak)
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -rohE 'https?://(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)[0-9.]+' \$TARGETS 2>/dev/null | sort -u"

# Any cleartext HTTP endpoint
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -rohE 'http://[^/\"\\x27 ]+/' \$TARGETS 2>/dev/null | sort -u"

# Staging/dev URLs shipped in production
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -rohE 'https?://[^\"\\x27 ]*(staging|stg|dev|qa|uat|test)[^\"\\x27 ]*' \$TARGETS 2>/dev/null | sort -u"

# Hardcoded secrets
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -rohE 'AKIA[A-Z0-9]{16}|AIza[0-9A-Za-z_-]{35}' \$TARGETS 2>/dev/null | sort -u"

# Client-secret shaped keys in assets
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
  grep -rlE 'app_secret|client_secret|api_key' /workspace/apktool/<pkg>/assets/ 2>/dev/null
```

Also look for these anti-patterns in the HTTP client wrapper:

- **Configured-but-unused SSL pinning** — a `params` object built with `sslPinning:{certs:[…]}` that is never passed to the actual request call. The bundled `.cer` under `assets/` is then a legacy artifact and pinning is not enforced.
- **Body-envelope trust** — success determined only by a body field like `status_code`, with HTTP status ignored. Not a bug per se, but callers rebuilding the client need to mirror the convention or they'll see spurious "successes".
- **Staging detection compiled in** — code like `if (HOST === 'https://staging.example.com') { ... }` with special device-ID / bypass logic. If this ships in the production APK, the staging environment is effectively reachable with a repack.

Put every hit into the report's "Security / operational findings" section with the source file and line.

---

## Phase 9 — Auth flow and UI → API correlation

The endpoint list alone is not enough to rebuild a client; the user also needs to know how auth works and which screen triggers what.

**Auth flow reconstruction (native Android):**

1. Find the login endpoint from Phase 3a (usually `POST /auth/login` or similar).
2. Trace its response model to find where the token is stored. Grep for `getSharedPreferences`, `EncryptedSharedPreferences`, `DataStore`, or SQLCipher calls receiving the token field.
3. Find the OkHttp `Interceptor` subclasses:
   ```bash
   grep -rnE 'implements Interceptor|extends Interceptor|: Interceptor' workspace/output/<pkg>/sources/
   ```
   The interceptor shows how the token is attached on subsequent requests (`Authorization: Bearer`, cookie, custom header).
4. Find the refresh flow — usually a second interceptor (`Authenticator`) or a `401` handler. Document the refresh endpoint and the trigger condition.

**Auth flow reconstruction (React Native):**

1. Find the login call site in the bundle (grep for the `LOGIN` / `LOGIN_V2` constant).
2. Record the request body shape (fields like `username`, `password`, `otp`, `fcm_token`, `device_id`).
3. Trace the success path to where `setToken` / `AsyncStorage.setItem` persists the returned `access_token`.
4. The token is attached in the HTTP wrapper you identified in Phase 3b Step 4 — that wrapper is the RN equivalent of an Interceptor.
5. Check for a refresh or 401 handler near the wrapper; many RN apps don't implement refresh and just log the user out.

**UI → API correlation:**

- Grep the sources/bundle for exported activity or screen names and note which endpoints they reference. In RN, screen names are usually declared in a `screenNames` object — once you have those, grep for call sites that mention both a screen and a service constant.
- Record the 3–5 entry points that account for most of the traffic (login, home, profile, list-children, notifications) so the reader can prioritize.

---

## Phase 10 — Output

Write the report to `workspace/reports/<pkg>-api.md`. Use this template — downstream tooling and other skills key off these section names:

```markdown
# API Documentation: <App Name> (<pkg>)

> Static analysis only. No dynamic traffic was captured. Endpoints marked
> "Unresolved" could not be resolved statically.
>
> Framework: <Native Android | React Native | Flutter | Hybrid>
> HTTP client: <Retrofit | OkHttp | axios | fetch | Ktor | ...>
> Bundle format (RN): <Metro plain JS | Hermes bytecode | n/a>

## Base URLs
- Production: https://api.example.com (used by `ApiService`, `UserService`)
- CDN: https://cdn.example.com (used by `ImageService`)
- Staging (compiled in): https://staging.example.com — <yes/no>

## Authentication
- Type: Bearer JWT
- Login: `POST /auth/login` -> { access_token, refresh_token, expires_in }
- Token attached via: `Authorization: Bearer <token>` header, added by `AuthInterceptor` (<class or module path>)
- Refresh: `POST /auth/refresh` on 401 (`TokenAuthenticator`)
- Token storage: EncryptedSharedPreferences / AsyncStorage key `auth_token`
- Response envelope: <HTTP status trusted | body `status_code` field trusted>

## Endpoints

### Auth
| Method | Path | Auth | Request body | Response | Caller |
|--------|------|------|--------------|----------|--------|
| POST | /auth/login | No | { email, password } | TokenResponse | `AuthService.login` (Java) / `_API.default.LOGIN` (JS module N) |

### <Next domain>
...

## Data models
### TokenResponse
| Field | Type | JSON name |
|-------|------|-----------|
| accessToken | String | access_token |
| refreshToken | String | refresh_token |
| expiresIn | Int | expires_in |

## WebSocket / real-time
<or "None detected">

## Native endpoints
<from Phase 6, or "No custom native networking — all libs are stock framework runtime">

## Security / operational findings
<from Phase 8 — raw IPs, cleartext HTTP, disabled pinning, staging leaks, hardcoded secrets>

## Unresolved / obfuscated
- `ApiService.foo()` calls a path built from `Decoder.a("XYZ==")`; decoder returns a non-literal value at runtime.
- ...

## Source map
- Retrofit interfaces (native): `com/example/net/*.java`
- DI module with base URL: `com/example/di/NetworkModule.java`
- Auth interceptor: `com/example/net/AuthInterceptor.java`
- Endpoint registry (RN): `index.android.bundle` lines <start>–<end>
- HTTP client wrapper (RN): `index.android.bundle` lines <start>–<end>
```

Do not emit a Postman collection — the container cannot capture traffic, so the collection would be synthetic and misleading. If the user explicitly asks for one, produce a best-effort file from the static endpoint table and label it clearly as "derived from static analysis, not verified against a live server".

---

## Failure and recovery

- **jadx CLI fails on an obfuscated APK** → try `apktool d` for resources and re-run jadx with `--no-src` just for the skeleton, then work class-by-class from the smali emitted by apktool.
- **No Retrofit annotations anywhere on a non-RN/Flutter build** → the app likely uses OkHttp directly or Ktor. Jump to Phase 5; also search for Kotlin `suspend fun` declarations in files ending in `*Api.kt` or `*Client.kt`.
- **`hbc-decompiler` fails on a Hermes bundle** → HBC-version support drifts between tools, so cascade: try `hbc-disassembler` for HBC asm (URLs still appear as `LoadConstString` operands), then `hbctool disasm` (alternate backend from `bongtrop/hbctool` with different version coverage; also produces a flat string-table JSON that's a shortcut if only URL enumeration is needed, not call-site structure). Only downgrade to `strings` over the raw bytes if all three fail. Document whatever structural context (HTTP verb, request shape) could not be recovered in the report's "Unresolved" section.
- **Native `.so` too large or stripped** → narrow IDA work to `Java_*` exported symbols only (`SELECT name FROM funcs WHERE name LIKE 'Java%';`) rather than full analysis.
- **Endpoint strings come back empty despite URL-using imports** → strings may be encrypted in the binary; fall back to Phase 7 and document as unresolved.
- **Preflight fails (no container, no jadx, no apktool)** → stop; ask the user to launch the environment. Do not fabricate a report from partial output.

---

## Handoff patterns

- `apk-find-api` → `xrefs`: when a single endpoint's call graph matters more than breadth.
- `apk-find-api` → `decompiler`: for deep review of a native JNI function implementing an endpoint.
- `apk-find-api` → `annotations`: when the user wants the findings persisted into the IDA database for the native library.
- `apk-find-api` → `analysis`: when scope widens from API surface to general app behavior.
