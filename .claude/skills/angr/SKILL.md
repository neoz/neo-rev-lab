---
name: angr
description: >
  Write angr Python scripts for symbolic execution, binary analysis, and constraint solving,
  and run them in the neo-rev-lab Docker container (angr pre-installed).
  Use this skill whenever the user asks to solve a CTF challenge with angr, write an angr solve script,
  perform symbolic execution on a binary, find inputs that reach a target address, crack a keygen or
  license check, do automated exploit generation (AEG), analyze malware behavior with angr, reverse
  engineer a binary using symbolic execution, find vulnerabilities via concolic testing, deobfuscate
  control flow flattening (CFF/OLLVM), recover original control flow from obfuscated binaries, or
  anything involving angr/claripy/SimProcedure. Also trigger when the user mentions "symbolic execution",
  "constraint solving for binaries", "find the flag", "solve crackme", "angr script",
  "control flow flattening", "CFF deobfuscation", or "OLLVM deobfuscation".
---

# angr Reverse Engineering & Symbolic Execution

This skill helps write correct, efficient angr scripts for reverse engineering, CTF solving, vulnerability discovery, and malware analysis. All patterns are derived from 45+ real-world solved challenges.

## Running angr Scripts in Docker

angr is pre-installed in the `neo-rev-lab` Docker container. Run angr scripts there using `docker exec`.

### Workflow

1. **Write the solve script** to a file (e.g., `solve.py`) in the `workspace/` directory (bind-mounted to `/workspace/` in the container).
2. **Discover the running container** and run the script:

```bash
CONTAINER=$(docker ps --filter ancestor=neo-rev-lab --format '{{.Names}}' | head -1)
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" python3 /workspace/solve.py
```

### Key Points

| Detail | Value |
|--------|-------|
| Container image | `neo-rev-lab` |
| angr install location | System Python (no virtualenv activation needed) |
| Workspace mount | Host `./workspace/` -> Container `/workspace/` |
| Binary + script location | Place both in `workspace/` so they are accessible at `/workspace/` inside the container |

### Platform Notes

**Windows (Git Bash / MSYS2):**
`MSYS_NO_PATHCONV=1` is required -- otherwise Unix-style paths (`/workspace/...`) get rewritten to Windows paths before reaching `docker.exe`.

```bash
CONTAINER=$(docker ps --filter ancestor=neo-rev-lab --format '{{.Names}}' | head -1)
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" python3 /workspace/solve.py
```

### Examples

**Basic run:**
```bash
CONTAINER=$(docker ps --filter ancestor=neo-rev-lab --format '{{.Names}}' | head -1)
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" python3 /workspace/solve.py
```

**Pass arguments to the script:**
```bash
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" python3 /workspace/solve.py --binary /workspace/challenge --find 0x401234
```

**Interactive debugging (drop into shell):**
```bash
MSYS_NO_PATHCONV=1 docker exec -it "$CONTAINER" bash
# Then inside container:
cd /workspace
python3 solve.py
```
Note: Do NOT use `-it` for non-interactive (scripted) runs -- it fails in environments without a TTY.

### Important Notes

- angr is installed in the system Python -- no virtualenv activation needed. Just run `python3` directly.
- The binary path in the solve script must use `/workspace/` paths (e.g., `/workspace/binary`, not a host path).
- If the binary needs specific libraries, place them in `workspace/` and use `ld_path=['/workspace/']` in the angr Project.
- For Windows PE binaries, angr in Docker (Linux) can still analyze them -- angr handles cross-platform analysis.

## Quick Decision: Which Pattern Do You Need?

| Scenario | Pattern | Jump to |
|----------|---------|---------|
| Binary reads from stdin | Basic Find/Avoid | Pattern 1 |
| Binary takes command-line args | Symbolic Arguments | Pattern 2 |
| Want to analyze a single function | Blank State or Callable | Pattern 3 / 4 |
| Binary reads from a file | File System Simulation | Pattern 6 |
| Finding exploitable crashes | Unconstrained Detection | Pattern 7 |
| Binary has complex/slow functions | Custom Hooks | Pattern 5 |
| Need ROP chain generation | CFG + ROP Analysis | Pattern 10 |
| Solving byte-by-byte (iterative) | Iterative Solving | Pattern 8 |
| **Windows PE binary** | **Blank State (skip CRT)** | **Pattern 3 / 11** |
| Deobfuscate control flow flattening | CFF Recovery via Symbolic Exec | Pattern 12 |

## Pattern 1: Basic Find/Avoid (stdin input)

The most common pattern. Binary reads input from stdin, you want to find input that reaches a "success" path while avoiding "failure" paths.

```python
import angr
import claripy

def solve():
    p = angr.Project('./binary', auto_load_libs=False)
    state = p.factory.entry_state()
    sm = p.factory.simulation_manager(state)
    sm.explore(find=0x401234, avoid=0x401300)

    if sm.found:
        found = sm.found[0]
        solution = found.posix.dumps(0)  # file descriptor 0 = stdin
        print(f"Solution: {solution}")
        return solution
    else:
        print("No solution found")
        return None

if __name__ == '__main__':
    solve()
```

**find/avoid can accept:**
- A single address: `find=0x401234`
- A list of addresses: `find=[0x401234, 0x401240]`
- A function: `find=lambda s: b"Success" in s.posix.dumps(1)` (check stdout)
- Same applies to `avoid`

**Using stdout matching** (when you don't know exact addresses):
```python
sm.explore(
    find=lambda s: b"Correct" in s.posix.dumps(1),
    avoid=lambda s: b"Wrong" in s.posix.dumps(1)
)
```

## Pattern 2: Symbolic Arguments (argv input)

When the binary takes input as command-line arguments.

```python
import angr
import claripy

def solve():
    p = angr.Project('./binary', auto_load_libs=False)

    # Create symbolic argument (e.g., 20 bytes max)
    arg_len = 20
    argv1 = claripy.BVS('argv1', 8 * arg_len)

    state = p.factory.entry_state(args=['./binary', argv1])

    # Constrain to printable ASCII (important for realistic solutions)
    for byte in argv1.chop(8):
        state.solver.add(byte >= 0x20)
        state.solver.add(byte <= 0x7e)

    sm = p.factory.simulation_manager(state)
    sm.explore(find=0x401234, avoid=0x401300)

    if sm.found:
        solution = sm.found[0].solver.eval(argv1, cast_to=bytes)
        print(f"Solution: {solution}")
        return solution

if __name__ == '__main__':
    solve()
```

**Multiple arguments:**
```python
argv1 = claripy.BVS('argv1', 8 * 10)
argv2 = claripy.BVS('argv2', 8 * 10)
state = p.factory.entry_state(args=['./binary', argv1, argv2])
```

## Pattern 3: Blank State (start at specific address)

Skip initialization and start execution at a specific function or address. Useful for analyzing individual functions or bypassing complex setup.

```python
import angr
import claripy

def solve():
    p = angr.Project('./binary', auto_load_libs=False)

    # Start at the function we want to analyze
    state = p.factory.blank_state(addr=0x401100)

    # Set up symbolic input in memory
    input_len = 32
    sym_input = claripy.BVS('input', 8 * input_len)
    input_addr = 0x600000  # pick an unused memory region
    state.memory.store(input_addr, sym_input)

    # Set up registers as the function expects them
    # Linux x86-64 (System V ABI): rdi, rsi, rdx, rcx, r8, r9
    state.regs.rdi = input_addr      # first arg
    state.regs.rsi = input_len       # second arg
    # Windows x86-64 (Microsoft ABI): rcx, rdx, r8, r9
    # state.regs.rcx = input_addr    # first arg (Windows)
    # state.regs.rdx = input_len     # second arg (Windows)
    # Set up a valid stack
    state.regs.rbp = state.regs.rsp

    sm = p.factory.simulation_manager(state)
    sm.explore(find=0x401200, avoid=0x401250)

    if sm.found:
        solution = sm.found[0].solver.eval(sym_input, cast_to=bytes)
        print(f"Solution: {solution}")

if __name__ == '__main__':
    solve()
```

## Pattern 4: Callable (function-level analysis)

Treat a binary function like a Python function. Great for testing individual functions or reversing hash/crypto routines.

```python
import angr
import claripy

def solve():
    p = angr.Project('./binary', auto_load_libs=False)

    # Call a function directly
    func = p.factory.callable(0x401100)
    result = func(0x41, 0x42)  # pass concrete args

    # Or with symbolic args
    sym_arg = claripy.BVS('arg', 32)
    func2 = p.factory.callable(0x401100)
    result2 = func2(sym_arg)

    # Access the result state for constraint solving
    result_state = func2.result_state
    result_state.solver.add(result2 == 0x12345678)

    if result_state.satisfiable():
        answer = result_state.solver.eval(sym_arg)
        print(f"Input that produces 0x12345678: {answer:#x}")

if __name__ == '__main__':
    solve()
```

## Pattern 5: Custom Hooks / SimProcedures

Replace functions (library or custom) with your own implementations. Essential when angr's built-in models are incomplete or too slow.

```python
import angr

class MyStrcmp(angr.SimProcedure):
    def run(self, s1, s2):
        # Simple: just return 0 (match) to skip comparison
        return 0

class SkipFunction(angr.SimProcedure):
    def run(self):
        # Skip a function entirely, return 0
        return 0

class CustomCheck(angr.SimProcedure):
    def run(self, buf, length):
        # Access state for symbolic operations
        data = self.state.memory.load(buf, length)
        # Add constraints directly
        self.state.solver.add(data == 0x4141414141414141)
        return 1

def solve():
    p = angr.Project('./binary', auto_load_libs=False)

    # Hook by symbol name
    p.hook_symbol('strcmp', MyStrcmp())

    # Hook by address (length = number of bytes to skip)
    p.hook(0x401500, SkipFunction(), length=5)

    # Use built-in SimProcedures
    p.hook_symbol('printf', angr.SIM_PROCEDURES['libc']['printf']())

    state = p.factory.entry_state()
    sm = p.factory.simulation_manager(state)
    sm.explore(find=0x401234)
```

**Inline hooks** (quick and simple):
```python
@p.hook(0x401234, length=5)
def my_hook(state):
    state.regs.eax = 1  # force return value
```

## Pattern 6: File System Simulation

When the binary reads from a file (license files, config files, etc.).

```python
import angr
import claripy

def solve():
    p = angr.Project('./binary', auto_load_libs=False)
    state = p.factory.entry_state()

    # Create symbolic file content
    file_size = 64
    sym_content = claripy.BVS('file_content', 8 * file_size)

    # Create and insert the simulated file
    sim_file = angr.storage.file.SimFile('license.dat', content=sym_content, size=file_size)
    state.fs.insert('license.dat', sim_file)

    sm = p.factory.simulation_manager(state)
    sm.explore(find=0x401234, avoid=0x401300)

    if sm.found:
        solution = sm.found[0].solver.eval(sym_content, cast_to=bytes)
        print(f"License content: {solution}")

if __name__ == '__main__':
    solve()
```

## Pattern 7: Unconstrained State Detection (AEG / Exploit Finding)

Find inputs that cause the instruction pointer to become symbolic (controllable by attacker).

```python
import angr
import claripy

def solve():
    p = angr.Project('./binary', auto_load_libs=False)

    # Need symbolic write addresses for heap/stack overflow detection
    state = p.factory.entry_state(
        add_options={
            angr.options.SYMBOLIC_WRITE_ADDRESSES,
            angr.options.ZERO_FILL_UNCONSTRAINED_MEMORY,
        }
    )

    sm = p.factory.simulation_manager(state, save_unconstrained=True)

    # Step until we find an unconstrained (exploitable) state
    while not sm.unconstrained and sm.active:
        sm.step()

    if sm.unconstrained:
        crash = sm.unconstrained[0]
        print("Found exploitable state!")

        if crash.regs.pc.symbolic:
            # Constrain IP to desired target (e.g., win function)
            target = 0x401234
            crash.add_constraints(crash.regs.pc == target)

            if crash.satisfiable():
                exploit_input = crash.posix.dumps(0)
                print(f"Exploit payload: {exploit_input}")

if __name__ == '__main__':
    solve()
```

## Pattern 8: Iterative Byte-by-Byte Solving

For challenges with complex constraints where full symbolic execution is too slow. Solve one character at a time.

```python
import angr
import claripy
import string

def solve():
    p = angr.Project('./binary', auto_load_libs=False)
    flag = ''

    for position in range(flag_length):
        for candidate in string.printable:
            test_input = flag + candidate + '\x00' * (flag_length - position - 1)
            state = p.factory.entry_state(
                stdin=angr.SimFile(name='stdin', content=test_input.encode())
            )
            sm = p.factory.simulation_manager(state)
            sm.explore(find=check_addr, avoid=fail_addr)

            if sm.found:
                flag += candidate
                print(f"Found char {position}: {candidate} -> {flag}")
                break

    print(f"Flag: {flag}")

if __name__ == '__main__':
    solve()
```

## Pattern 9: Custom Exploration Techniques

Control how angr explores the state space. Useful for filtering out unproductive paths or implementing custom search strategies.

```python
import angr

class AvoidLibc(angr.exploration_techniques.ExplorationTechnique):
    """Drop states that wander into libc."""
    def filter(self, simgr, state, **kwargs):
        if state.addr < 0x400000 or state.addr > 0x500000:
            return 'avoided'
        return simgr.filter(state, **kwargs)

class DepthLimiter(angr.exploration_techniques.ExplorationTechnique):
    """Limit exploration depth to prevent path explosion."""
    def __init__(self, max_depth=1000):
        super().__init__()
        self.max_depth = max_depth

    def filter(self, simgr, state, **kwargs):
        if state.history.block_count > self.max_depth:
            return 'avoided'
        return simgr.filter(state, **kwargs)

def solve():
    p = angr.Project('./binary', auto_load_libs=False)
    state = p.factory.entry_state()
    sm = p.factory.simulation_manager(state)

    sm.use_technique(AvoidLibc())
    sm.use_technique(angr.exploration_techniques.DFS())  # built-in DFS
    sm.explore(find=0x401234)
```

**Built-in techniques:**
- `DFS()` - depth-first search (less memory)
- `LengthLimiter(max_length=N)` - limit path length
- `Explorer(find=addr, avoid=addr)` - same as explore()
- `Veritesting()` - merge similar states (can speed up dramatically)
- `Oppologist()` - handle unsupported instructions

## Pattern 10: CFG and ROP Analysis

Build control flow graphs and find ROP gadgets.

```python
import angr

def analyze():
    p = angr.Project('./binary', auto_load_libs=False)

    # Build CFG
    cfg = p.analyses.CFGFast()
    print(f"Functions found: {len(cfg.kb.functions)}")

    # Iterate functions
    for addr, func in cfg.kb.functions.items():
        print(f"  {func.name} @ {addr:#x}")

    # ROP gadget analysis (using angrop)
    rop = p.analyses.ROP()
    rop.find_gadgets()

    # Build a ROP chain
    chain = rop.set_regs(rdi=0x401234)
    chain.print_payload_code()

if __name__ == '__main__':
    analyze()
```

## Pattern 11: Windows PE Binary (blank_state + inline hooks)

Windows PE binaries have heavy CRT initialization that causes angr to get lost when using `entry_state`. The proven approach: use `blank_state` to start directly at the validation function, and use **inline hooks** (not SimProcedures) for library calls.

**Why blank_state is required for Windows PE:**
- `entry_state` enters MSVC CRT init (`__scrt_common_main_seh`, `_initterm`, etc.) which pulls in dozens of Windows API calls (`FlsAlloc`, `TlsAlloc`, `GetModuleHandleW`, etc.)
- angr cannot resolve these DLLs (`kernel32.dll`, `api-ms-win-*`) in its Linux Docker environment
- The CRT init creates massive state explosion before even reaching `main`

**Why inline hooks instead of SimProcedures:**
- With `blank_state`, the stack has no valid return address
- SimProcedure hooks (both built-in like `angr.SIM_PROCEDURES['libc']['strlen']()` and custom `angr.SimProcedure` subclasses) execute a `ret` instruction, popping an unconstrained value from the stack as the return address
- This causes `"Exit state has over 256 possible solutions. Likely unconstrained; skipping."` and exploration fails
- Inline hooks (`@p.hook(addr, length=N)`) simply set register values and skip bytes in-place -- no call/return overhead

**Critical: Choosing the correct find address:**
- The decompiler may show `return (exprA) && (exprB)` with a single address annotation
- In assembly, this compiles to a chain of conditional jumps. The annotated address is often a `jz`/`jnz` for just one condition, NOT the success path
- Always check the **disassembly** to find the exact instruction that sets the success return value (e.g., `mov [rsp+var], 1`)
- Use that `mov` instruction address as `find`, and all `mov [rsp+var], 0` addresses as `avoid`

```python
import angr
import claripy

def solve():
    p = angr.Project('./challenge.exe', auto_load_libs=False)

    # Create symbolic input
    flag_len = 14
    sym_flag = claripy.BVS('flag', 8 * flag_len)

    # Start directly at the validation function (skip CRT)
    state = p.factory.blank_state(addr=0x140001000)

    # Place symbolic input in memory
    flag_addr = 0x200000  # unused region
    state.memory.store(flag_addr, sym_flag)
    state.memory.store(flag_addr + flag_len, claripy.BVV(0, 8))  # null terminator

    # Windows x64 calling convention: first arg in rcx
    state.regs.rcx = flag_addr

    # Constrain to printable ASCII
    for i in range(flag_len):
        byte = sym_flag.get_byte(i)
        state.solver.add(byte >= 0x20)
        state.solver.add(byte <= 0x7e)

    # INLINE hook for library calls (do NOT use SimProcedure with blank_state)
    # Hook "call strlen" at its address, skip 5 bytes (size of call instruction)
    @p.hook(0x14000100e, length=5)
    def strlen_hook(state):
        state.regs.rax = claripy.BVV(flag_len, 64)

    sm = p.factory.simulation_manager(state)

    # find = address of "mov [rsp+var_4], 1" (success, from disassembly)
    # avoid = ALL addresses of "mov [rsp+var_4], 0" (every failure path)
    sm.explore(
        find=0x1400011FF,   # exact success instruction
        avoid=[0x14000101d, 0x140001083, 0x1400010a2, 0x140001120,
               0x140001142, 0x140001160, 0x140001182, 0x1400011a4, 0x1400011f2]
    )

    if sm.found:
        solution = sm.found[0].solver.eval(sym_flag, cast_to=bytes)
        print(f"Flag: {solution.decode()}")

if __name__ == '__main__':
    solve()
```

## Pattern 12: Control Flow Flattening (CFF) Deobfuscation

Recover original control flow from binaries obfuscated with CFF (OLLVM, Tigress, etc.). CFF replaces normal branches with a dispatcher/switch that routes execution through state variables.

**How CFF works:** Each original basic block (OBB) gets a state ID. A central dispatcher reads the state variable and jumps to the corresponding OBB. After each OBB executes, it sets the next state value and jumps back to the dispatcher. This flattens the CFG into a star topology.

**Strategy:** Use symbolic execution to discover the state machine -- map each state value to its OBB, then find successor states (with conditions) by executing through the dispatcher.

```python
import angr
import claripy
from queue import Queue

def deobfuscate_cff(binary_path, func_addr, dispatcher_addr, state_reg='eax'):
    """
    Recover original control flow from a CFF-obfuscated function.

    Args:
        binary_path: Path to the binary
        func_addr: Entry address of the obfuscated function
        dispatcher_addr: Address of the dispatcher/switch block
        state_reg: Register holding the state variable (commonly eax)
    """
    p = angr.Project(binary_path, auto_load_libs=False)

    # Step 1: Find the initial state value at the dispatcher
    init_state = p.factory.call_state(addr=func_addr)
    init_state.options.add(angr.options.CALLLESS)
    sm = p.factory.simulation_manager(init_state)

    # Run until we reach the dispatcher
    while sm.active and sm.active[0].addr != dispatcher_addr:
        sm.step()

    dispatcher_state = sm.active[0].copy()
    initial_state_val = dispatcher_state.solver.eval_one(
        getattr(dispatcher_state.regs, state_reg)
    )

    # Step 2: Build the state table via BFS
    state_table = {}  # state_val -> (obb_addr, [(next_state, flags), ...])
    visited = set()
    queue = Queue()
    queue.put(initial_state_val)

    while not queue.empty():
        state_val = queue.get()
        if state_val in visited:
            continue
        visited.add(state_val)

        # Map state value -> OBB address
        obb_state, obb_addr = find_obb(p, dispatcher_state, dispatcher_addr,
                                        state_val, state_reg)
        if obb_state is None:
            continue

        # Execute OBB and find successor state values
        next_states = find_next_states(p, obb_state, dispatcher_addr, state_reg)
        state_table[state_val] = (obb_addr, next_states)

        for next_val, _ in next_states:
            if next_val not in visited:
                queue.put(next_val)

    return state_table


def find_obb(project, dispatcher_state, dispatcher_addr, state_val, state_reg):
    """Set state register and step through dispatcher to find the target OBB."""
    state = dispatcher_state.copy()
    setattr(state.regs, state_reg,
            state.solver.BVV(state_val, getattr(state.regs, state_reg).size()))
    sm = project.factory.simulation_manager(state)

    for _ in range(200):  # safety limit
        sm.step()
        if not sm.active:
            return None, None
        addr = sm.active[0].addr
        # OBB reached when we leave the dispatcher region
        if addr != dispatcher_addr:
            return sm.active[0].copy(), addr

    return None, None


def find_next_states(project, obb_state, dispatcher_addr, state_reg):
    """Execute from OBB until dispatcher is reached; extract next state values."""
    sm = project.factory.simulation_manager(obb_state)

    for _ in range(500):  # safety limit
        sm.step()
        if not sm.active:
            return []
        if sm.active[0].addr == dispatcher_addr:
            break

    final_state = sm.active[0]
    reg = getattr(final_state.regs, state_reg)

    # Get possible next state values (1 = unconditional, 2+ = conditional)
    next_vals = final_state.solver.eval_upto(reg, 8)

    results = []
    for val in next_vals:
        # For conditional branches, also extract flag state
        flags_vals = final_state.solver.eval_upto(
            final_state.regs.flags, 2,
            extra_constraints=[reg == val]
        )
        flags = flags_vals[0] if flags_vals else None
        results.append((val, flags))

    return results
```

**Interpreting the state table:**
- Single successor: unconditional jump (`jmp next_obb`)
- Two successors with different flags: conditional branch (`jz`/`jnz` based on flag diff)

**Flag extraction for patching:**
```python
class Flags:
    """Extract x86 flags from EFLAGS register value."""
    def __init__(self, register):
        self.CF = bool(register & 0x0001)
        self.PF = bool(register & 0x0004)
        self.AF = bool(register & 0x0010)
        self.ZF = bool(register & 0x0040)
        self.SF = bool(register & 0x0080)
        self.OF = bool(register & 0x0800)
```

**Key requirements before starting:**
1. Identify the dispatcher address (block receiving the most back-edges)
2. Identify which register/variable holds the state (often `eax` or a stack variable)
3. Use `CALLLESS` option to skip function calls within OBBs
4. Set safety limits on stepping to avoid infinite loops

See `references/advanced-patterns.md` for binary patching implementation, IDA Python patching script (cmov-to-Jcc mapping, flag-based routing, NOP dispatcher), and complete standalone deobfuscation script.

---

## Constraint Patterns Reference

Common constraint patterns for `claripy`:

```python
import claripy

sym = claripy.BVS('input', 8 * length)

# Printable ASCII
for byte in sym.chop(8):
    state.solver.add(byte >= 0x20)
    state.solver.add(byte <= 0x7e)

# Alphanumeric only
for c in sym.chop(8):
    is_digit = claripy.And(c >= ord('0'), c <= ord('9'))
    is_lower = claripy.And(c >= ord('a'), c <= ord('z'))
    is_upper = claripy.And(c >= ord('A'), c <= ord('Z'))
    state.solver.add(claripy.Or(is_digit, is_lower, is_upper))

# Known prefix (e.g., "FLAG{")
prefix = b"FLAG{"
for i, ch in enumerate(prefix):
    state.solver.add(sym.get_byte(i) == ch)

# Known suffix (e.g., "}")
state.solver.add(sym.get_byte(length - 1) == ord('}'))

# Exact length with null terminator
state.solver.add(sym.get_byte(actual_len) == 0)
```

## Performance & Optimization

### State Options

```python
# Fast concrete execution (10-100x speedup for concrete-heavy code)
state = p.factory.entry_state(add_options=angr.options.unicorn)

# Defer constraint solving (faster exploration, may find more paths)
state = p.factory.entry_state(add_options={angr.options.LAZY_SOLVES})

# Zero-fill uninitialized memory (prevents spurious symbolic reads)
state = p.factory.entry_state(
    add_options={angr.options.ZERO_FILL_UNCONSTRAINED_MEMORY}
)

# Combine multiple options
state = p.factory.entry_state(
    add_options=angr.options.unicorn | {angr.options.LAZY_SOLVES}
)
```

### Solver Timeout

```python
# For hard crypto/hash challenges, increase solver timeout
state.solver._solver.timeout = 300000  # milliseconds
```

### Reducing State Explosion

1. **Use `avoid` aggressively** - add error handlers, logging functions, irrelevant branches
2. **Hook slow functions** - replace complex library calls with simple SimProcedures
3. **Use Veritesting** - `sm.use_technique(angr.exploration_techniques.Veritesting())`
4. **Limit path depth** - avoid infinite loops with custom technique or `LengthLimiter`
5. **Start from a later point** - use `blank_state` to skip initialization

### AST Depth Management

For challenges where constraint trees grow explosively:

```python
# Replace deep symbolic expressions with fresh symbols
if val.symbolic and val.depth > 100:
    replacement = claripy.BVS('simplified', len(val))
    state.solver.add(replacement == val)
    state.registers.store(reg_name, replacement)
```

## Architecture & Loading

```python
# Standard ELF/PE (auto-detected)
p = angr.Project('./binary', auto_load_libs=False)

# Raw binary / firmware blob
p = angr.Project('./firmware.bin', main_opts={
    'backend': 'blob',
    'arch': 'ARM',
    'base_addr': 0x08000000,
    'entry_point': 0x08000000,
})

# With specific libraries
p = angr.Project('./binary', ld_path=['./libs/'])

# Force architecture
p = angr.Project('./binary', arch='MIPS32')
```

**Supported architectures:** x86, x86-64 (AMD64), ARM, ARM64 (AArch64), MIPS, MIPS64, PowerPC, PowerPC64, SPARC, S390X.

## Output Extraction

```python
found = sm.found[0]

# stdin that led to this state
stdin_data = found.posix.dumps(0)

# stdout produced by this state
stdout_data = found.posix.dumps(1)

# Solve a symbolic variable to concrete bytes
concrete = found.solver.eval(sym_var, cast_to=bytes)

# Get multiple possible solutions
solutions = found.solver.eval_upto(sym_var, 10, cast_to=bytes)

# Read memory at an address
mem_val = found.memory.load(addr, size)
concrete_mem = found.solver.eval(mem_val, cast_to=bytes)

# Check if a value is concrete or symbolic
if found.solver.symbolic(found.regs.rax):
    print("RAX is symbolic")
```

## Debugging angr Scripts

```python
import logging

# Enable angr debug logging
logging.getLogger('angr.manager').setLevel(logging.DEBUG)
logging.getLogger('angr.engines').setLevel(logging.INFO)

# Inspect state at found point
found = sm.found[0]
print("stdout:", found.posix.dumps(1))
print("IP:", found.regs.rip)
print("Constraints:", len(found.solver.constraints))

# Check active/deadended/errored stash counts during exploration
print(f"Active: {len(sm.active)}, Dead: {len(sm.deadended)}, Err: {len(sm.errored)}")

# Step through manually for debugging
sm = p.factory.simulation_manager(state)
for i in range(100):
    sm.step()
    print(f"Step {i}: {len(sm.active)} active, addrs: {[hex(s.addr) for s in sm.active[:5]]}")
    if sm.found:
        break
```

## Common Pitfalls

1. **Forgetting `auto_load_libs=False`** - loading shared libraries creates massive state space; disable unless you specifically need library internals.

2. **Input size mismatch** - if the symbolic input is shorter than what the binary reads, angr will create additional unconstrained symbolic bytes. If longer, extra bytes are ignored. Match the expected input size.

3. **Missing `avoid` addresses** - without avoid, angr explores every reachable path. Always identify failure/error paths and add them to avoid.

4. **State explosion in loops** - loops with symbolic conditions create exponential paths. Hook the loop or use Veritesting.

5. **Wrong calling convention** - when using `blank_state`, set up registers according to the binary's architecture and calling convention (x86-64: rdi, rsi, rdx, rcx, r8, r9; x86: stack-based; ARM: r0-r3).

6. **Symbolic pointers** - by default angr concretizes symbolic pointers. Enable `SYMBOLIC_WRITE_ADDRESSES` only when looking for memory corruption bugs.

7. **Windows PE + entry_state = lost in CRT** - Windows PE binaries have massive CRT initialization (`__scrt_common_main_seh`, `_initterm`, etc.) that pulls in unresolvable DLLs (`kernel32.dll`, `api-ms-win-*`). angr gets lost exploring CRT code and never reaches `main`. **Always use `blank_state`** targeting the validation function directly for Windows PE. See Pattern 11.

8. **SimProcedure hooks corrupt stack in blank_state** - `blank_state` has no valid return address on the stack. SimProcedure hooks (both built-in like `angr.SIM_PROCEDURES['libc']['strlen']()` and custom `angr.SimProcedure` subclasses) execute a `ret`, popping unconstrained memory as the return address. This produces `"Exit state has over 256 possible solutions. Likely unconstrained; skipping."` and kills exploration. **Use inline hooks** (`@p.hook(addr, length=N)`) instead, which set registers in-place without call/return overhead.

9. **Decompiler find addresses miss final conditions** - The decompiler may annotate `return (exprA) && (exprB)` at a single address, but in assembly this is a chain of conditional jumps. That address is often a `jz`/`jnz` for just one sub-condition, reached regardless of whether all conditions are met. **Always verify find/avoid addresses against the disassembly.** Look for the exact `mov [var], 1` (success) vs `mov [var], 0` (failure) instructions. Using the wrong find address produces solutions that satisfy only some constraints.

## Advanced: For detailed patterns and more examples

Read `references/advanced-patterns.md` for:
- Multi-stage solving (e.g., binary bomb with multiple phases)
- Execution trace guidance
- Java/Android analysis
- State merging strategies
- Veritesting configuration
- CFF deobfuscation: binary patching, IDA integration, complete standalone script
