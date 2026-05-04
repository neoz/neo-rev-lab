---
name: java-analysis
description: "Reverse-engineer Java artifacts using static analysis only: a four-decompiler ladder (jadx → CFR → Procyon → Vineflower), plus unzip / strings / file / xxd / ripgrep, plus ida-mcp/idasql for any bundled JNI .so libraries. Handles plain JARs, fat/uber-jars (Spring Boot, Shadow), WAR/EAR server deployments, standalone .class files, and loose .dex outside an APK — first-class, not an afterthought. Use whenever the user wants to understand, audit, deobfuscate, or extract behavior from a Java archive: enumerating REST/Servlet endpoints, finding the Main-Class, mapping plugin SPI, hunting deserialization gadgets, dumping hardcoded secrets, or rebuilding a CLI's argument flow — even if they don't say the words 'reverse engineer'. Prefer this skill over generic binary-analysis skills for any task that starts from a .jar / .war / .ear / .class / .dex (non-APK) input. For .apk inputs, route to apk-find-api or apk-compare-versions instead."
metadata:
  argument-hint: "<jar_or_war_or_class_path>"
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

## Scope and constraints

This skill runs inside the `neo-rev-lab` Docker image. It is static-only — there is no Frida, no JVM agent, no JDI debugger attach, no traffic capture, and no live deserialization-gadget execution. Every finding must trace back to a literal in the decompiled output or a structural fact about the archive.

Tools actually available in this container (verified, not assumed):

| Tool | Where | Use for |
|------|-------|---------|
| `jadx` CLI (via `java -cp /opt/jadx/jadx.jar jadx.cli.JadxCLI`) | docker | Primary decompiler. JAR/WAR/EAR/.class/.dex → Java sources on disk for bulk Grep. Best on obfuscated code and dex |
| `cfr` | `/usr/local/bin/cfr` (docker) | First fallback when jadx refuses a class. Best at modern Java features (records, sealed classes, switch expressions, pattern matching) |
| `procyon` | `/usr/local/bin/procyon` (docker) | Second fallback. Best at lambdas, anonymous inner classes, and synthetic-method quirks |
| `vineflower` (alias `fernflower`) | `/usr/local/bin/vineflower` (docker) | Third fallback. Algorithmically distinct (the maintained Fernflower successor); often succeeds where the tree decompilers above fail |
| `apktool` | `/usr/local/bin/apktool` (docker) | Only useful if the artifact happens to be a `.dex` extracted from an APK — otherwise route to `apk-find-api` |
| `unzip` | docker | List and extract archive contents (JAR, WAR, EAR, fat-jar are all ZIP) |
| `file` | docker | Identify input type from magic bytes — `file <input>` is more readable than `od -c` |
| `xxd` | docker | Hex-dump raw `.class` bytes when even decompiler chains fail |
| `rg` (ripgrep) | docker | Fast in-container pattern sweep; the host-side Grep tool is still preferable on already-decompiled trees because it avoids per-call `docker exec` overhead |
| `strings` | docker | Last-resort literal extraction from `.class` files when every decompiler fails |
| `python3` | docker | Small extractors / `.class` parsers (the JDK ships only the JRE here, so see "Known gaps" below) |
| `ida-mcp` + `idasql` | MCP + docker | Any JNI `.so` shipped inside the JAR's resources (some commercial Java libs ship native code under `META-INF/native/` or similar) |
| `Grep` / `Read` / `Glob` / `Bash` | Host | Pattern sweeps over decompiled output |

Known gaps in this container (so the skill doesn't burn calls rediscovering them):

- **No `javap`, `javac`, `jdeps`, `jlink`, `jstack`** — the container ships an OpenJDK 21 JRE only. Anything that needs JDK tooling has to be replaced with jadx output, raw `.class` parsing, or a Python `class`-file walker. In practice, jadx covers most of what `javap -c` would tell you.
- **No Krakatau** — jadx, CFR, Procyon, and Vineflower are installed; Krakatau (Rust v2) is intentionally not bundled to keep the image small. The four installed decompilers cover ~all real-world cases. If you hit a JAR that none of the four can read, document it under "Unresolved" rather than reaching for tools the container doesn't have.
- **The `/usr/local/bin/jadx` wrapper defaults to `jadx.gui.JadxGUI`**, which crashes headlessly on missing `libharfbuzz` and produces an empty output directory with exit code 0 — a false success. Always invoke `jadx.cli.JadxCLI` directly (see Phase 0).
- **Git Bash on Windows** rewrites Unix-style paths (`/workspace/...`) on the way to `docker.exe`. Prefix every `docker exec` with `MSYS_NO_PATHCONV=1`.

If any tool is unavailable in the current session, state the limitation in the report header rather than silently skipping a phase.

---

## Trigger intents

Use this skill when the user says things like:

- "Reverse this JAR for me."
- "What does `tool.jar` actually do?"
- "Find the REST endpoints in this Spring Boot fat-jar."
- "Map the servlets in this WAR."
- "Pull all hardcoded credentials out of `app.jar`."
- "Find the `main` method and trace argument parsing."
- "Is there a Java deserialization sink in this JAR?"
- "Decompile and explain `Loader.class`."
- "What plugins does this app load? (SPI / `META-INF/services/`)"
- "Deobfuscate this JAR — names look ProGuarded."
- A path ending in `.jar`, `.war`, `.ear`, `.class`, or `.dex` plus any question about behavior, structure, security, or endpoints.

Route elsewhere when:

- Path ends in `.apk` → `apk-find-api` (single APK) or `apk-compare-versions` (two APKs). The Android skills already handle dex extraction, manifests, and resource pipelines; don't redo that work here.
- User wants runtime tracing / dynamic instrumentation → not supported in this container; say so explicitly.
- User has a native binary (no Java involved) → `analysis` or the IDA skills (`disassembly`, `decompiler`, `xrefs`).
- User has the source already and just wants a code review → this skill is for when source is *not* available.

---

## Workspace conventions

These paths intentionally mirror `apk-find-api` so artifacts compose cleanly if the user later reverses an APK that bundles the same library, or vice versa. `<artifact>` is a stable slug derived from the input filename minus extension (e.g. `app-1.2.3.jar` → `app-1.2.3`).

- Input: `workspace/<artifact>.jar` (or `.war`, `.ear`, `.class`, `.dex`) — bind-mounted to `/workspace/` inside the container.
- jadx decompile: `workspace/output/<artifact>/`
- Raw `unzip` extraction (only when needed for resources / `META-INF/`): `workspace/extracted/<artifact>/`
- Intermediate artifacts (endpoint lists, dependency manifests, secret hits): `workspace/artifacts/<artifact>/`
- Final report: `workspace/reports/<artifact>-java.md`
- Container preamble for every command:

```bash
CONTAINER=$(docker ps --filter ancestor=neo-rev-lab --format '{{.Names}}' | head -1)
# MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" <command>
```

If no container is running, ask the user to launch one (typically by starting Claude Code in a project set up via `run.sh`) before proceeding. Do not try to build or start a container yourself.

---

## Phase 0 — Preflight

Spend ~30 seconds verifying the environment before committing to a multi-minute decompile. The goal is to catch three specific traps that produce misleading "success" states downstream: the GUI-wrapper jadx, a dead container, and an input that isn't actually a Java archive.

```bash
# 1. Container reachable?
CONTAINER=$(docker ps --filter ancestor=neo-rev-lab --format '{{.Names}}' | head -1)
[ -z "$CONTAINER" ] && echo "No neo-rev-lab container; ask user to launch one"

# 2. jadx CLI class works (the wrapper script defaults to GUI)?
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
  java -cp /opt/jadx/jadx.jar jadx.cli.JadxCLI --version

# 3. Input exists and looks like a Java archive?
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'ls -l /workspace/<input> && file /workspace/<input>'
```

`file` interpretation (the human-readable string is the load-bearing fact):

- `Java archive data (JAR)` / `Zip archive data` → `.jar`, `.war`, `.ear`, fat-jar, Spring Boot launchable JAR. Continue with Phase 1.
- `compiled Java class data, version <N>.0` → standalone `.class` file. Skip directly to a single-class jadx invocation in Phase 1; the version tells you the minimum target JDK.
- `Dalvik dex file version <NNN>` → loose `.dex`. jadx handles it directly; treat like a JAR for Phase 1 onward, but note in the report header that the user may have wanted `apk-find-api` instead.
- `Android package (APK)` → wrong skill; route to `apk-find-api`.
- Anything else → not a Java artifact. Stop and ask the user to confirm the path.

Record any preflight failure in the report header so the reader knows which phases degraded. Do not fabricate a report from partial state.

---

## Phase 1 — Decompile (jadx CLI)

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'rm -rf /workspace/output/<artifact> && mkdir -p /workspace/output/<artifact> && \
   java -cp /opt/jadx/jadx.jar jadx.cli.JadxCLI \
     -d /workspace/output/<artifact> --deobf /workspace/<input>'
```

`--deobf` replaces ProGuard/R8/Allatori-mangled names (`a.b.c`) with stable pseudo-names. Without it, every grep on an obfuscated JAR returns garbage. With it, you get readable identifiers that let class-name patterns like `*Controller`, `*Service`, `*Servlet` actually match.

A handful of decompile errors is normal — jadx will refuse some classes that use unusual bytecode tricks (often ProGuard-optimized `<clinit>` blocks, Kotlin-coroutine state machines, or invokedynamic-heavy lambdas). Proceed as long as `workspace/output/<artifact>/sources/` is populated.

For each class jadx couldn't decompile, walk the **decompiler fallback ladder** before giving up. Each step uses an algorithmically different strategy, so a class one tool refuses is often readable to the next:

```bash
# Extract just the failing class so the fallbacks aren't fighting the whole archive
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'unzip -p /workspace/<input> com/example/Foo.class > /workspace/artifacts/<artifact>/Foo.class'

# 1. CFR — best at modern Java (records, sealed types, switch expressions, pattern matching)
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
  cfr /workspace/artifacts/<artifact>/Foo.class \
    > /workspace/artifacts/<artifact>/Foo.cfr.java 2>&1

# 2. Procyon — best at lambdas, anonymous inner classes, and synthetic-method handling
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
  procyon /workspace/artifacts/<artifact>/Foo.class \
    > /workspace/artifacts/<artifact>/Foo.procyon.java 2>&1

# 3. Vineflower — algorithmically distinct (the maintained Fernflower successor); pick this up where the tree decompilers above stumble
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
  vineflower /workspace/artifacts/<artifact>/Foo.class /workspace/artifacts/<artifact>/

# 4. Last resort — raw bytes
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
  strings /workspace/artifacts/<artifact>/Foo.class
```

Stop at the first decompiler that produces clean output (no fatal errors, no truncated method bodies, identifier names look sensible). Record which tool succeeded next to the class in the report. If all four fail, the class goes in "Unresolved" with the specific failure modes captured — that level of detail makes the gap reproducible for someone re-attempting the analysis later.

Also do a structural extraction in parallel — many findings come from `META-INF/` rather than from `.class` files, and unzip is fast:

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  'mkdir -p /workspace/extracted/<artifact> && \
   unzip -o /workspace/<input> -d /workspace/extracted/<artifact> > /dev/null && \
   ls /workspace/extracted/<artifact>/META-INF/ 2>/dev/null'
```

This populates the inputs for Phases 2 and 3 (manifest, services, embedded fat-jar dependencies, signed-JAR metadata).

---

## Phase 2 — Archive triage and dependency map

Before reading code, drain everything that is *declared* about the archive. These are the cheapest, highest-confidence facts in the whole analysis.

1. **`META-INF/MANIFEST.MF`** — read it directly. Look for:
   - `Main-Class:` → the entry point if this is an executable JAR. Phase 4 starts there.
   - `Start-Class:` → Spring Boot's *real* main class (`Main-Class:` is the launcher shim).
   - `Class-Path:` → external JAR dependencies expected on disk at runtime.
   - `Implementation-Version`, `Bundle-Version`, `Build-Jdk-Spec` → version and target JDK; useful for vuln baselining.
   - `Sealed:`, `Premain-Class:` (Java agents), `Agent-Class:` → unusual entry points.
2. **`META-INF/maven/*/pom.properties` and `pom.xml`** — when present, this is a *gift*: exact `groupId:artifactId:version` for every bundled dependency. Most fat-jars and Maven-built JARs ship these. Grep them out:
   ```bash
   MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
     "find /workspace/extracted/<artifact>/META-INF/maven/ -name pom.properties -exec cat {} \; 2>/dev/null"
   ```
   Cross-reference each `groupId:artifactId:version` against known-CVE databases later if the user asks for a vulnerability sweep.
3. **Spring Boot fat-jar?** — check for `BOOT-INF/lib/` and `BOOT-INF/classes/`. If present, the *application* code lives in `BOOT-INF/classes/`, and every JAR under `BOOT-INF/lib/` is a transitive dependency that was already decompiled by jadx into `workspace/output/<artifact>/sources/`. Note this in the report — readers often confuse "code I want to audit" with "code that came from open-source dependencies".
4. **Shadow / one-jar / capsule / launchable**: each has a different layout marker (`org/springframework/boot/loader/`, `com/simontuffs/onejar/`, `Capsule.class` at the root). Identify which packer was used; it tells the reader where to look for the real entry point.
5. **WAR / EAR**:
   - `WEB-INF/web.xml` → Servlet declarations (`<servlet-class>`, `<url-pattern>`), filters, listeners, security constraints.
   - `WEB-INF/classes/` → compiled application code.
   - `WEB-INF/lib/` → bundled JARs (each is a separate jadx target if you want depth).
   - `META-INF/application.xml` (EAR) → child modules.
6. **Signed JARs**: `META-INF/*.SF` / `*.RSA` / `*.DSA`. Note who signed it; if the user is auditing supply chain, this matters.
7. **Embedded native code**: `META-INF/native/`, `lib/`, or top-level `*.so` / `*.dll` / `*.dylib` resources. Set these aside for Phase 7.

Capture the dependency list and entry points to `workspace/artifacts/<artifact>/`:

```
workspace/artifacts/<artifact>/
├── manifest.txt        # MANIFEST.MF verbatim
├── deps.tsv            # one row per pom.properties: groupId\tartifactId\tversion
├── entry_points.txt    # Main-Class / Start-Class / Premain-Class / Servlets / etc.
└── packaging.txt       # "Spring Boot fat-jar" | "plain JAR" | "WAR" | "EAR" | "shadow uber-jar" | ...
```

These are the inputs subsequent phases cite, and the artifacts the report references in its "Source map" section.

---

## Phase 2.5 — Application fingerprint

Different frameworks put behavior in different places. Guessing wrong wastes the whole analysis. Fingerprint before branching.

```bash
S=workspace/output/<artifact>/sources

# Web frameworks
grep -rlE '@(RestController|Controller|RequestMapping|GetMapping|PostMapping|PutMapping|DeleteMapping|PatchMapping)\b' "$S" | head -5
grep -rlE '@(Path|GET|POST|PUT|DELETE)\b'                                                                              "$S" | head -5  # JAX-RS
grep -rlE 'extends HttpServlet|@WebServlet|implements Servlet\b'                                                       "$S" | head -5
grep -rlE 'class .*Verticle|io\.vertx\.'                                                                                "$S" | head -5

# CLI / batch / agent
grep -rnE 'public static void main\s*\(String' "$S" | head -10
grep -rlE 'implements Callable<Integer>|@Command\b|picocli'                                                              "$S" | head -5  # picocli CLIs
grep -rlE 'premain\s*\(String|java\.lang\.instrument'                                                                    "$S" | head -5  # Java agents

# Messaging / scheduled / listeners
grep -rlE '@(KafkaListener|JmsListener|RabbitListener|EventListener|Scheduled|Async)\b' "$S" | head -5

# Plugin / SPI
ls workspace/extracted/<artifact>/META-INF/services/ 2>/dev/null
```

Decision table:

| Dominant signal | Branch |
|---|---|
| `@RestController` / `@RequestMapping` / `@GetMapping` / Spring Boot dep in pom | **Phase 4a — Spring** |
| `@Path` / JAX-RS annotations / `javax.ws.rs` imports | **Phase 4b — JAX-RS** |
| `extends HttpServlet` / `@WebServlet` / `web.xml` mappings | **Phase 4c — Servlet/WAR** |
| `main` methods with no web framework | **Phase 4d — CLI / library** |
| `META-INF/services/` populated | **Phase 4e — SPI / plugins** (in addition to whichever above applies) |
| `Premain-Class:` in manifest | **Phase 4f — Java agent** (in addition) |

A real artifact is often more than one — a Spring Boot app with a CLI mode, a WAR with embedded SPI plugins, an agent that also exposes a JMX endpoint. Run every applicable branch and merge into the report.

---

## Phase 3 — Package and entry-point map

Before doing per-framework work, build the cheap birds-eye view. This is the navigational scaffold the rest of the analysis hangs off.

```bash
S=workspace/output/<artifact>/sources

# Top-level packages by file count (rough proxy for "where is the code")
find "$S" -name '*.java' | awk -F/ '{print $4"."$5}' | sort | uniq -c | sort -rn | head -20

# Public entry points: every main()
grep -rnE 'public static void main\s*\(String' "$S"

# Reflection roots — common starting points for plugin loaders, factories
grep -rnE 'Class\.forName\s*\(|ClassLoader\.getSystemClassLoader|URLClassLoader' "$S" | head -30
```

Cross-reference each `main(...)` with `Main-Class:` and `Start-Class:` from the manifest. Disagreement is informative: a JAR with three `main` methods but a manifest that only points at one tells you which two are dead code or test harnesses.

Annotate each entry point with one line in `workspace/artifacts/<artifact>/entry_points.txt`:

```
com.example.App.main             # Main-Class
com.example.AdminTool.main       # secondary CLI; not in manifest
com.example.boot.JarLauncher.main  # Spring Boot launcher shim (not the app)
```

The report's "Entry points" section is just this file lightly annotated.

---

## Phase 4a — Spring (`@RestController` / `@RequestMapping`)

This is the goldmine on Spring Boot apps. One pass finds every endpoint:

```bash
grep -rnE '@(GetMapping|PostMapping|PutMapping|DeleteMapping|PatchMapping|RequestMapping|FeignClient)\b' \
  workspace/output/<artifact>/sources/
```

For every controller, read the full file. Per method, extract:

| Field | Source |
|---|---|
| HTTP verb | The annotation (`@GetMapping` → GET, `@RequestMapping(method=…)` → as specified, no `method` → all verbs) |
| Path | Annotation `value`/`path` parameter; combine the *class-level* `@RequestMapping` prefix with the *method-level* path |
| Path variables | `@PathVariable` parameters |
| Query / form params | `@RequestParam` |
| Body | `@RequestBody` (note the type — its fields are documented in Phase 6) |
| Headers | `@RequestHeader` |
| Auth requirement | `@PreAuthorize`, `@Secured`, `@RolesAllowed`, or absence thereof; cross-reference with Spring Security config (next bullet) |
| Return type | Method signature; `ResponseEntity<T>`, `T`, or a reactive `Mono<T>` / `Flux<T>` |

Then find the security configuration:

```bash
grep -rnE 'extends WebSecurityConfigurerAdapter|SecurityFilterChain|HttpSecurity|@EnableWebSecurity|authorizeHttpRequests|antMatchers|requestMatchers|permitAll|hasRole|hasAuthority' \
  workspace/output/<artifact>/sources/
```

The path-pattern matchers there tell you which endpoints are public and which require auth. Endpoints listed as `permitAll()` or matching a permissive pattern (`/**`) deserve a callout in the report's "Security" section.

**`@FeignClient`** is the *outbound* equivalent — it's a Retrofit-like declaration of an HTTP service this app *calls*. Treat each `@FeignClient` interface like a Retrofit interface from `apk-find-api` Phase 3a: the methods document outbound API surface.

---

## Phase 4b — JAX-RS (`@Path` / `@GET` / `@POST`)

JAX-RS apps (RESTEasy, Jersey, Quarkus REST) declare endpoints with `javax.ws.rs.*` (Jakarta: `jakarta.ws.rs.*`) annotations. The discovery is parallel to Spring's:

```bash
grep -rnE '@Path\b|@(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\(' \
  workspace/output/<artifact>/sources/
```

Per method, the same fields apply, with these annotation differences:

| Concept | JAX-RS annotation |
|---|---|
| Path variable | `@PathParam` |
| Query param | `@QueryParam` |
| Form param | `@FormParam` |
| Header | `@HeaderParam` |
| Cookie | `@CookieParam` |
| Body | unannotated parameter (the first non-annotated param is the body) |

Class-level `@Path` and method-level `@Path` concatenate the same way Spring's do. Note that `@Produces` / `@Consumes` annotations document the content type contract.

Auth on JAX-RS is typically a `ContainerRequestFilter` (`@Provider` plus `filter(ContainerRequestContext)`); search:

```bash
grep -rnE 'implements ContainerRequestFilter|@Provider' workspace/output/<artifact>/sources/
```

Read the matching filter to see how auth is verified.

---

## Phase 4c — Servlet / WAR

Older or non-framework deployments declare endpoints either in `web.xml` or via `@WebServlet`. The discovery has two halves.

**Declarative (`WEB-INF/web.xml`)**:

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "grep -nE '<servlet-(name|class|mapping)|<url-pattern>|<filter-(name|class|mapping)|<listener-class>' \
     /workspace/extracted/<artifact>/WEB-INF/web.xml"
```

Every `<servlet-mapping>` ties a `<servlet-name>` to a `<url-pattern>`, and that name maps back to a `<servlet-class>`. The class is what you read.

**Annotation-driven (`@WebServlet`)**:

```bash
grep -rnE '@WebServlet|@WebFilter|@WebListener|extends HttpServlet\b' \
  workspace/output/<artifact>/sources/
```

For each Servlet class, the request handlers are `doGet`, `doPost`, `doPut`, `doDelete`, `service` (catch-all), etc. Read each method that's actually overridden — the method body is the endpoint logic. Parameter access is via `req.getParameter(...)`, `req.getHeader(...)`, `req.getInputStream()`; trace these to document the request shape.

Filters (`javax.servlet.Filter` / `jakarta.servlet.Filter`) are where auth, CORS, rate limiting, and input mangling typically live. Read every filter in the chain — they apply *before* the servlet sees the request.

JSPs sometimes carry behavior of their own. After unzip, look under `WEB-INF/jsp/` and the WAR root for `*.jsp`; read any that aren't trivially template HTML.

---

## Phase 4d — CLI / library (no web framework)

When the artifact is a CLI or a pure library, behavior fans out from the `main` method and the publicly-exported API:

1. Decompile and read every `main(...)` body. Trace argument parsing:
   - Plain `args[0]` indexing → DIY parser; document which positions mean what.
   - `picocli` → look for `@Command`, `@Option`, `@Parameters`. The annotations *are* the user-facing CLI doc.
   - Apache Commons CLI → `Options options = new Options(); options.addOption(...)`. Each `addOption` is a flag.
   - JCommander → `@Parameter(names=…)` on a parameter object.
   - `args4j` → `@Option(name=…)`.
2. From `main`, walk the call graph one or two levels deep — the meat is usually a `run()` or `execute()` method that fans out to the rest of the codebase.
3. For libraries (no `main`), the public surface is the set of `public` classes/methods that aren't shaded internals. Filter:
   ```bash
   grep -rnE '^public (final )?(class|interface|enum|@interface) ' workspace/output/<artifact>/sources/ \
     | grep -vE '/(internal|impl|shaded|relocated)/' | head -50
   ```
   This roughly approximates "what consumers can actually call".

For CLIs, the report should include a synthesized usage block that mirrors what the user would see if they ran `--help` (often the annotations or the `usage()` method give you exactly this).

---

## Phase 4e — SPI / plugins (`META-INF/services/`)

Java's Service Provider Interface is the standard way an app declares "load any class on the classpath that implements interface X". Each file under `META-INF/services/` is named after a fully-qualified interface name; its lines are fully-qualified implementation class names.

```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
  "for f in /workspace/extracted/<artifact>/META-INF/services/*; do
     echo '=== '$(basename \"\$f\")' ==='; cat \"\$f\"
   done 2>/dev/null"
```

For each declared interface, read the interface itself (it documents the contract) and every implementation listed (each is a *plugin*). Plugin systems are common attack-surface multipliers: a benign-looking app can load behavior from third-party JARs at runtime, and an audit that ignores the SPI misses that.

Document each `(interface, [implementations])` pair in the report's "Plugin / SPI surface" section.

---

## Phase 4f — Java agent (`Premain-Class:`)

If the manifest has `Premain-Class:` (loaded with `-javaagent:`) or `Agent-Class:` (loaded via `Attach API`), the JAR is a JVM agent. These are unusual and load-bearing — they run code with full instrumentation privileges before `main` even starts.

Read `premain(String, Instrumentation)` and `agentmain(String, Instrumentation)`. Document:

- What classes the agent transforms (look for `inst.addTransformer(...)`).
- Whether the transformation rewrites bytecode (ASM, Javassist, ByteBuddy).
- Anything the agent loads or executes unconditionally on startup.

Agents can be entirely benign (telemetry, profiling, hot-patching) or hostile (a "deobfuscator" agent that hides exfiltration). The decompiled body is the only honest answer.

---

## Phase 5 — Java-specific security sweep

Run these greps as a fixed pass over the decompiled tree. Each pattern catches a real, well-documented Java footgun, and naming them out is more useful than a generic "review for vulns".

```bash
S=workspace/output/<artifact>/sources

# 1. Unsafe deserialization sinks (the classic Java RCE family)
grep -rnE 'ObjectInputStream\b|readObject\s*\(|XMLDecoder\b|Yaml\(\)\.load|SnakeYaml|XStream\(\)|Hessian|Burlap|JdbcRowSetImpl' "$S"

# 2. JNDI / LDAP injection (Log4Shell-class)
grep -rnE 'InitialContext|InitialDirContext|lookup\s*\(|jndi:|ldap://|rmi://|JndiLookup|MessageLookup' "$S"

# 3. Reflection used to invoke arbitrary methods
grep -rnE 'Class\.forName|getDeclaredMethod|getMethod|\.invoke\(|setAccessible\s*\(\s*true' "$S"

# 4. Runtime command execution
grep -rnE 'Runtime\.getRuntime\(\)\.exec|ProcessBuilder|new ProcessBuilder' "$S"

# 5. Script engines (Nashorn, JRuby, Jython, Groovy, BeanShell, etc.)
grep -rnE 'ScriptEngineManager|getEngineByName|GroovyShell|GroovyClassLoader|BSFManager|JythonScriptEngine' "$S"

# 6. Spring SpEL injection
grep -rnE '@Value\s*\("#\{|SpelExpressionParser|StandardEvaluationContext|parseExpression\s*\(' "$S"

# 7. SQL string concatenation (vs prepared statements)
grep -rnE 'createStatement\(\)\.execute|"SELECT.*"\s*\+|"INSERT.*"\s*\+|"UPDATE.*"\s*\+' "$S"

# 8. SSRF-prone HTTP clients with user input
grep -rnE 'URL\s*\(|new URI\s*\(|HttpURLConnection|HttpClient\.newHttpClient|OkHttpClient' "$S"

# 9. Disabled TLS verification
grep -rnE 'TrustAllCerts|TrustManager.*checkServerTrusted.*\{?\s*\}|HostnameVerifier.*verify.*return true|setHostnameVerifier\s*\(\s*\(.*\)\s*->\s*true' "$S"

# 10. Hardcoded secrets
grep -rnE 'AKIA[A-Z0-9]{16}|AIza[0-9A-Za-z_-]{35}|ya29\.[A-Za-z0-9_-]+|sk_(live|test)_[0-9a-zA-Z]{24,}|xox[baprs]-[0-9A-Za-z-]+|-----BEGIN (RSA |EC )?PRIVATE KEY-----' "$S" workspace/extracted/<artifact>/

# 11. Weak crypto
grep -rnE 'getInstance\("(DES|RC4|MD5|SHA1)"|"DES/|"RC4/|MessageDigest\.getInstance\("MD5"\)|MessageDigest\.getInstance\("SHA-?1"\)' "$S"

# 12. Path traversal candidates
grep -rnE 'new File\s*\(.*\+|Paths\.get\s*\(.*\+|FileInputStream\s*\(.*\+' "$S"
```

For every hit that survives a quick read of the surrounding lines (some matches will be benign — `MD5` for non-crypto checksumming, `Runtime.exec` for a static literal command), record:

- The pattern that fired
- File and line
- A one-line "why this matters" (e.g. *"`readObject` on an attacker-controlled stream → RCE if any gadget class is on the classpath"*)
- Whether the input is reachable from a Phase 4 entry point (when feasible to determine; if not, label "reachability not verified")

Reachability matters because a `readObject` deep in a util class is far less alarming than the same call inside a `@PostMapping` handler.

---

## Phase 6 — Data models and request/response shapes

For every endpoint surfaced in Phase 4, the request and response types are usually plain Java classes (POJOs) — read them and tabulate fields. Pay attention to:

- `@JsonProperty` / `@SerializedName` / `@JsonAlias` — the *wire* field name, which can differ from the Java field name.
- `@JsonIgnore` — fields explicitly excluded from serialization.
- Lombok annotations (`@Data`, `@Value`, `@Getter`/`@Setter`) — generated accessors won't appear in the source; the field list *is* the public surface.
- Validation annotations (`@NotNull`, `@Size`, `@Pattern`, `@Min`, `@Max`) — they document the request contract more reliably than any external doc.

Document one table per type, parallel to the "Data models" section in `apk-find-api`.

---

## Phase 7 — Native / JNI handoff

Some Java libraries ship native code under `META-INF/native/`, `lib/`, or as top-level resources, and load them via `System.loadLibrary` / `System.load`. When this happens:

1. Identify the native loaders:
   ```bash
   grep -rnE 'System\.(loadLibrary|load)\s*\(' workspace/output/<artifact>/sources/
   ```
2. Extract the bundled `.so` / `.dll` / `.dylib`:
   ```bash
   MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" bash -c \
     'find /workspace/extracted/<artifact> -type f \( -name "*.so" -o -name "*.dll" -o -name "*.dylib" \)'
   ```
3. For each native binary the user wants opened, follow the project's `CLAUDE.md` idasql-over-HTTP pattern. Match Java `native` declarations (`native int foo(...)`) with the corresponding `Java_*` exported symbol in the binary; the JNI symbol-name mangling is deterministic (`Java_<package>_<class>_<method>`).
4. Kill any idasql HTTP server when done — the project enforces "one server per database".

This phase is opt-in unless the security sweep flagged the native loader as a vector.

---

## Phase 8 — Obfuscation triage

If Phase 4 returns surprisingly empty results on what the user described as a "real" app, suspect obfuscation. Static-only triage strategies:

- **Renamed identifiers (ProGuard, R8, Allatori)**: jadx's `--deobf` already gives stable pseudo-names, so this is mostly handled. The remaining symptom is package-flattening (everything ends up under `a.a.*`). Trust the structure (annotations, manifest entries, SPI files) over the names.
- **String encryption (Allatori, Stringer, ZKM)**: characteristic shape is many calls to a small set of static `String -> String` or `byte[] -> String` decoder methods. Identify the decoder and, for short literals, mentally evaluate it. Do not reach for runtime decoding — this container has no JVM execution facility wired up to do it safely.
- **Control-flow flattening / dispatcher-state machines**: jadx output looks like one giant `switch` over an `int state` variable. Read the cases by what they reference (string literals, called methods) rather than trying to recover the original CFG.
- **Reflection-only call sites**: `Class.forName(decoder("XYZ=="))` followed by `getMethod(decoder("ABC==")).invoke(...)`. Decode the strings to recover the dispatch target; if the decoder is too involved, list the call site under "Unresolved" with the decoder reference so a future pass can revisit.
- **Invokedynamic-heavy lambdas (typical of recent Kotlin/Scala)**: not obfuscation per se, but jadx may emit synthetic `lambda$foo$0` names; the lambda body is what you actually read.

Every endpoint or behavior you cannot resolve goes into a dedicated "Unresolved / obfuscated" section in the report. An honest gap is more useful than a guess.

---

## Phase 9 — Output

Write the report to `workspace/reports/<artifact>-java.md`. Use this template — handoff skills key off these section names:

```markdown
# Java Analysis: <artifact name>

> Static analysis only (neo-rev-lab Docker). No JVM execution, no traffic capture.
>
> - Input: `<artifact>` (<bytes> bytes, packaging: <plain JAR | Spring Boot fat-jar | shadow uber-jar | WAR | EAR | .class | .dex>)
> - Implementation-Version: <from manifest, or "unknown">
> - Target JDK: <from Build-Jdk-Spec, or "unknown">
> - Frameworks detected: <Spring | JAX-RS | Servlet | picocli | none>

## Summary
<3–5 bullets that stand alone if the rest goes unread.>

## Entry points
- <FQN.method>  — <Main-Class | Start-Class | Premain-Class | Servlet | @RestController | other>
- ...

## Dependencies
| groupId | artifactId | version | Source |
|---------|-----------|---------|--------|
| ... | ... | ... | META-INF/maven/.../pom.properties |

## Endpoints
### REST (<Spring | JAX-RS>)
| Method | Path | Auth | Request body | Response | Caller |
|--------|------|------|--------------|----------|--------|

### Servlet (web.xml + @WebServlet)
| URL pattern | Servlet class | Verbs handled | Filters in chain |
|-------------|---------------|---------------|------------------|

### Outbound (FeignClient / programmatic HTTP)
| Method | Target URL | Where called from |

## Plugin / SPI surface
| Interface | Implementations | File |

## CLI
<Synthesized usage block from picocli/commons-cli/etc., or "n/a">

## Java agent (`premain` / `agentmain`)
<What the agent does, what it transforms, or "n/a">

## Data models
### <TypeName>
| Field | Type | JSON name | Validation |

## Security findings
### High
- <pattern> at <file>:<line> — <why this matters> — <reachable from <entry point> | reachability not verified>
### Medium
### Informational

## Native code
<List of bundled .so/.dll/.dylib with their loader call sites, or "no bundled native code">

## Unresolved / obfuscated
- <FQN.class> — jadx/cfr/procyon/vineflower all failed (last attempted: <decompiler>; recovered literals: `strings` only)
- <reflection-only call sites with undecoded dispatch>
- <string-encrypted literals>

## Source map
- jadx decompile: `workspace/output/<artifact>/`
- Raw extraction: `workspace/extracted/<artifact>/`
- Per-pass artifacts: `workspace/artifacts/<artifact>/{manifest.txt, deps.tsv, entry_points.txt, packaging.txt}`
```

---

## Failure and recovery

- **jadx refuses an entire archive** (rare; usually a signing-related ZIP quirk) → `unzip` it manually, then point jadx at the extracted classes directory or at individual `.class` files. The CLI accepts both.
- **jadx skips a small number of classes** → expected. Walk the decompiler fallback ladder from Phase 1: extract the class with `unzip -p`, then try `cfr` → `procyon` → `vineflower`. Stop at the first one that produces clean output. Only after all four fail does the class go in "Unresolved" with `strings` literals captured.
- **Spring Boot fat-jar makes the decompiled tree huge** (thousands of dep files) → narrow grep paths to `BOOT-INF/classes/` (re-decompile that subdir alone if needed). Phase 5 patterns over the dependency tree are still useful for "is there a known-vulnerable class on the classpath", but stop confusing app code with library code in the report.
- **No web-framework annotations on a JAR the user described as a "service"** → it may use a less common framework (Vert.x route definitions, Micronaut compile-time annotations expanded into separate files, Helidon). Grep for `Route`, `route(...)`, `Router\.router\(`, `@Controller` (Micronaut), `Routing\.builder` (Helidon) before concluding "no endpoints".
- **String-encrypted JAR with no recoverable literals** → document what *is* recoverable (annotations, structural facts, native loaders) and label everything else "Unresolved (string encryption: <decoder method FQN>)".
- **Container missing or jadx broken** → stop; ask the user to launch the environment. Do not fabricate a report from partial state.

---

## Handoff patterns

- `java-analysis` → `apk-find-api`: when the user discovers the artifact is actually an APK, or when an APK's bundled JAR turns out to be more interesting than the rest of the app.
- `java-analysis` → `apk-compare-versions`: when the user has two versions of the same JAR/WAR and wants a delta — the patterns here compose with the diff phases there.
- `java-analysis` → `analysis` / `decompiler` / `xrefs`: when a JNI `.so` surfaces and needs deep native-side reading.
- `java-analysis` → `annotations`: when findings should be persisted into an IDA database for a bundled native library.
