# Advanced angr Patterns

## Table of Contents
1. [Multi-Stage Solving (Binary Bomb)](#multi-stage-solving)
2. [Execution Trace Guidance](#execution-trace-guidance)
3. [State Merging & Veritesting](#state-merging)
4. [Java and Android Analysis](#java-android)
5. [Symbolic Stdin with SimFile](#symbolic-stdin)
6. [Multi-Binary / Shared Library Analysis](#multi-binary)
7. [Self-Modifying Code / Packing](#self-modifying)
8. [Batch Constraint Solving](#batch-solving)
9. [Control Flow Flattening Deobfuscation](#cff-deobfuscation)

---

## Multi-Stage Solving (Binary Bomb) {#multi-stage-solving}

When a binary has multiple sequential checks (like CMU's binary bomb), solve each phase independently using state snapshots.

```python
import angr
import claripy

def solve_bomb():
    p = angr.Project('./bomb', auto_load_libs=False)

    # Phase 1: solve first check
    state1 = p.factory.entry_state()
    sm1 = p.factory.simulation_manager(state1)
    sm1.explore(find=phase1_end, avoid=explode_addr)

    if not sm1.found:
        print("Phase 1 failed")
        return

    phase1_state = sm1.found[0]
    phase1_answer = phase1_state.posix.dumps(0)
    print(f"Phase 1: {phase1_answer}")

    # Phase 2: continue from phase 1's solved state
    # The state already has the correct stdin for phase 1
    sm2 = p.factory.simulation_manager(phase1_state)
    sm2.explore(find=phase2_end, avoid=explode_addr)

    if sm2.found:
        phase2_answer = sm2.found[0].posix.dumps(0)
        print(f"Phase 1+2 input: {phase2_answer}")
```

**Alternative: blank_state per phase** (more reliable for complex binaries):

```python
def solve_phase(p, func_addr, end_addr, fail_addr, input_type='memory'):
    state = p.factory.blank_state(addr=func_addr)

    if input_type == 'memory':
        sym = claripy.BVS('phase_input', 8 * 64)
        buf_addr = 0x600000
        state.memory.store(buf_addr, sym)
        state.regs.rdi = buf_addr
    elif input_type == 'register':
        sym = claripy.BVS('phase_input', 32)
        state.regs.edi = sym

    sm = p.factory.simulation_manager(state)
    sm.explore(find=end_addr, avoid=fail_addr)

    if sm.found:
        return sm.found[0].solver.eval(sym, cast_to=bytes)
    return None
```

---

## Execution Trace Guidance {#execution-trace-guidance}

When you have an execution trace (from dynamic analysis), use it to guide symbolic execution along the correct path.

```python
import angr

def solve_with_trace(binary_path, trace_addrs):
    """
    trace_addrs: list of instruction addresses from a concrete execution trace
    """
    p = angr.Project(binary_path, auto_load_libs=False)
    state = p.factory.entry_state()

    trace_idx = 0
    while trace_idx < len(trace_addrs):
        target = trace_addrs[trace_idx]

        # Get all successors for current state
        succs = p.factory.successors(state, num_inst=1)

        # Find the successor matching the trace
        matched = False
        for succ in succs.successors:
            if succ.addr == target:
                state = succ
                matched = True
                break

        if not matched:
            print(f"Trace diverged at {state.addr:#x}, expected {target:#x}")
            break

        trace_idx += 1

    # Now state has followed the trace with symbolic constraints
    solution = state.posix.dumps(0)
    print(f"Input following trace: {solution}")
```

---

## State Merging & Veritesting {#state-merging}

Veritesting automatically merges states at convergence points, dramatically reducing path explosion for certain binary patterns.

```python
import angr

def solve_with_veritesting():
    p = angr.Project('./binary', auto_load_libs=False)
    state = p.factory.entry_state()
    sm = p.factory.simulation_manager(state)

    # Enable Veritesting
    sm.use_technique(angr.exploration_techniques.Veritesting())
    sm.explore(find=0x401234, avoid=0x401300)
```

**When Veritesting helps:**
- Binaries with many if/else branches on input bytes (common in CTF)
- Switch statements
- Character-by-character validation loops

**When it hurts:**
- Binaries with complex memory operations at merge points
- When merged constraints become too complex for the solver

**Manual merge points** (when Veritesting is too aggressive):

```python
class MergeAt(angr.exploration_techniques.ExplorationTechnique):
    def __init__(self, merge_addr):
        super().__init__()
        self.merge_addr = merge_addr

    def step(self, simgr, stash='active', **kwargs):
        simgr = simgr.step(stash=stash, **kwargs)
        # Move states at merge point to a holding stash
        simgr.move(from_stash='active', to_stash='merge',
                   filter_func=lambda s: s.addr == self.merge_addr)
        # When enough states accumulate, merge them
        if len(simgr.stashes.get('merge', [])) >= 2:
            merged = simgr.merge(stash='merge')
            simgr.move(from_stash='merge', to_stash='active')
        return simgr
```

---

## Java and Android Analysis {#java-android}

angr can analyze Java bytecode via the Soot frontend and Android APKs.

```python
import angr

# Java JAR file
p = angr.Project('./challenge.jar')
state = p.factory.entry_state()
sm = p.factory.simulation_manager(state)
sm.explore()

# Check deadended states for results
for s in sm.deadended:
    stdout = s.posix.dumps(1)
    if b"flag" in stdout.lower():
        print(f"Found: {stdout}")

# Android ARM binary (extracted from APK)
p = angr.Project('./libnative.so',
    auto_load_libs=False,
    main_opts={'arch': 'ARMEL', 'base_addr': 0x0}
)
```

---

## Symbolic Stdin with SimFile {#symbolic-stdin}

More control over stdin than the default:

```python
import angr
import claripy

def solve():
    p = angr.Project('./binary', auto_load_libs=False)

    # Create symbolic stdin content
    stdin_len = 100
    sym_stdin = claripy.BVS('stdin', 8 * stdin_len)

    # Method 1: via entry_state stdin parameter
    state = p.factory.entry_state(
        stdin=angr.SimFile(name='stdin', content=sym_stdin, size=stdin_len)
    )

    # Method 2: full_init_state for binaries that need dynamic linker
    state = p.factory.full_init_state(
        stdin=angr.SimFile(name='stdin', content=sym_stdin, size=stdin_len)
    )

    sm = p.factory.simulation_manager(state)
    sm.explore(find=0x401234)

    if sm.found:
        solution = sm.found[0].solver.eval(sym_stdin, cast_to=bytes)
        print(f"Solution: {solution}")
```

---

## Multi-Binary / Shared Library Analysis {#multi-binary}

Analyze binaries with their libraries:

```python
import angr

# Load with specific library search paths
p = angr.Project('./binary',
    auto_load_libs=True,
    ld_path=['./extracted_libs/'],
    use_system_libs=False
)

# Or selectively load libraries
p = angr.Project('./binary',
    auto_load_libs=False,
    force_load_libs=['./libcrypto.so']
)

# Find symbols across loaded objects
for obj in p.loader.all_objects:
    print(f"Object: {obj.binary_basename}")
    for sym in obj.symbols:
        if not sym.is_import and sym.is_function:
            print(f"  {sym.name} @ {sym.rebased_addr:#x}")
```

---

## Self-Modifying Code / Packing {#self-modifying}

For packed or self-modifying binaries, use unicorn mode for concrete unpacking, then switch to symbolic analysis:

```python
import angr

def solve_packed():
    p = angr.Project('./packed_binary', auto_load_libs=False)

    # Phase 1: concrete execution to unpack (unicorn mode)
    unpack_state = p.factory.entry_state(
        add_options=angr.options.unicorn
    )
    sm = p.factory.simulation_manager(unpack_state)
    sm.explore(find=oep_addr)  # original entry point after unpacking

    if not sm.found:
        print("Failed to reach OEP")
        return

    unpacked_state = sm.found[0]

    # Phase 2: symbolic execution from unpacked state
    unpacked_state.options.discard(angr.options.UNICORN)
    sm2 = p.factory.simulation_manager(unpacked_state)
    sm2.explore(find=success_addr, avoid=fail_addr)
```

---

## Batch Constraint Solving {#batch-solving}

When you need to extract multiple values from a solved state:

```python
def extract_solution(found_state, variables):
    """Extract multiple symbolic variables from a found state."""
    results = {}
    for name, sym_var in variables.items():
        if found_state.solver.symbolic(sym_var):
            results[name] = found_state.solver.eval(sym_var, cast_to=bytes)
        else:
            # Already concrete
            results[name] = found_state.solver.eval(sym_var, cast_to=bytes)
    return results

# Usage
variables = {
    'username': sym_user,
    'password': sym_pass,
    'serial': sym_serial,
}
solution = extract_solution(sm.found[0], variables)
for k, v in solution.items():
    print(f"{k}: {v}")
```

## Control Flow Flattening (CFF) Deobfuscation {#cff-deobfuscation}

Detailed guide for using angr to recover original control flow from CFF-obfuscated binaries (OLLVM, Tigress, custom obfuscators). Based on techniques from openanalysis.net research.

### Understanding CFF Structure

**Before CFF (normal flow):**
```
block_A -> block_B (if cond) -> block_D
                   (else)    -> block_C -> block_D
```

**After CFF (flattened):**
```
                    +-> OBB_A (sets state=2) -+
                    |                          |
entry -> dispatcher +-> OBB_B (sets state=3) -+-> back to dispatcher
                    |                          |
                    +-> OBB_C (sets state=4) -+
                    |                          |
                    +-> OBB_D (exit)          |
```

Key components:
- **Dispatcher**: Central switch/jump table that reads a state variable and routes to the correct OBB
- **State variable**: Register or stack variable (often `eax`, `var_XX`) holding the current state ID
- **Original Basic Blocks (OBBs)**: The actual code, each ending by setting the next state value and jumping to dispatcher
- **Conditional OBBs**: Set different next-state values based on a condition (e.g., `cmov` instructions)

### Step-by-Step Recovery Algorithm

#### Step 1: Identify CFF Components

Use CFG analysis or manual inspection to find:

```python
import angr

def identify_cff_components(binary_path, func_addr):
    """Use CFG to find the dispatcher (block with most incoming edges)."""
    p = angr.Project(binary_path, auto_load_libs=False)
    cfg = p.analyses.CFGFast(regions=[(func_addr, func_addr + 0x1000)])

    # The dispatcher is typically the node with the most predecessors
    max_preds = 0
    dispatcher = None
    for node in cfg.graph.nodes():
        preds = list(cfg.graph.predecessors(node))
        if len(preds) > max_preds:
            max_preds = len(preds)
            dispatcher = node.addr

    print(f"Likely dispatcher at {dispatcher:#x} ({max_preds} predecessors)")
    return dispatcher
```

#### Step 2: Find Initial State Value

```python
def get_initial_state(project, func_addr, dispatcher_addr, state_reg='eax'):
    """Execute from function entry to dispatcher to get initial state value."""
    state = project.factory.call_state(addr=func_addr)
    state.options.add(angr.options.CALLLESS)
    sm = project.factory.simulation_manager(state)

    # Step until reaching dispatcher
    step_count = 0
    while sm.active and sm.active[0].addr != dispatcher_addr:
        sm.step()
        step_count += 1
        if step_count > 500:
            raise RuntimeError("Failed to reach dispatcher from function entry")

    dispatcher_state = sm.active[0].copy()
    reg_val = getattr(dispatcher_state.regs, state_reg)
    initial_val = dispatcher_state.solver.eval_one(reg_val)
    print(f"Initial state value: {initial_val:#x}")
    return dispatcher_state, initial_val
```

#### Step 3: Map State Values to OBBs

```python
def map_state_to_obb(project, dispatcher_state, state_val, state_reg='eax'):
    """
    From the dispatcher, set the state register and step to find which OBB
    this state value routes to.
    """
    state = dispatcher_state.copy()
    reg = getattr(state.regs, state_reg)
    setattr(state.regs, state_reg, state.solver.BVV(state_val, reg.size()))
    sm = project.factory.simulation_manager(state)

    for _ in range(200):
        sm.step()
        if not sm.active:
            return None, None
        # Check if we left the dispatcher region
        current = sm.active[0]
        if current.addr != dispatcher_state.addr:
            return current.copy(), current.addr

    return None, None
```

#### Step 4: Find Successor States (Next State Discovery)

This is the critical step -- execute the OBB and find what state value(s) it sets before returning to the dispatcher.

```python
def find_successors(project, obb_state, dispatcher_addr, state_reg='eax'):
    """
    Execute from an OBB until the dispatcher is reached again.
    Extract possible next state values and their associated conditions.

    Returns: list of (state_value, flags_value) tuples
      - Single entry = unconditional successor
      - Multiple entries = conditional branch (different flags determine which)
    """
    sm = project.factory.simulation_manager(obb_state)

    for _ in range(500):
        sm.step()
        if not sm.active:
            return []
        if sm.active[0].addr == dispatcher_addr:
            break
    else:
        return []  # never reached dispatcher

    final = sm.active[0]
    reg = getattr(final.regs, state_reg)

    # Enumerate possible next-state values
    possible_values = final.solver.eval_upto(reg, 8)

    successors = []
    for val in possible_values:
        # For each possible state value, check what flag conditions lead to it
        flag_vals = final.solver.eval_upto(
            final.regs.flags, 2,
            extra_constraints=[reg == val]
        )
        flags = flag_vals[0] if flag_vals else None
        successors.append((val, flags))

    return successors
```

#### Step 5: Full BFS State Machine Recovery

```python
from queue import Queue

def recover_state_machine(project, func_addr, dispatcher_addr, state_reg='eax'):
    """
    Complete state machine recovery via BFS.

    Returns: dict mapping state_value -> (obb_addr, [(next_state, flags), ...])
    """
    dispatcher_state, initial_val = get_initial_state(
        project, func_addr, dispatcher_addr, state_reg
    )

    state_table = {}
    visited = set()
    queue = Queue()
    queue.put(initial_val)

    while not queue.empty():
        state_val = queue.get()
        if state_val in visited:
            continue
        visited.add(state_val)

        # Map this state value to its OBB
        obb_state, obb_addr = map_state_to_obb(
            project, dispatcher_state, state_val, state_reg
        )
        if obb_state is None:
            print(f"  State {state_val:#x}: dead state (no OBB found)")
            continue

        # Find successor states
        successors = find_successors(project, obb_state, dispatcher_addr, state_reg)
        state_table[state_val] = (obb_addr, successors)

        succ_type = "unconditional" if len(successors) == 1 else "conditional"
        succ_str = ", ".join(f"{v:#x}" for v, _ in successors)
        print(f"  State {state_val:#x} -> OBB {obb_addr:#x} ({succ_type}: {succ_str})")

        # Enqueue undiscovered successor states
        for next_val, _ in successors:
            if next_val not in visited:
                queue.put(next_val)

    return state_table
```

### Binary Patching (IDA / standalone)

After recovering the state table, patch the binary to replace dispatcher jumps with direct jumps.
Based on techniques from [OALABS research](https://research.openanalysis.net/angr/symbolic%20execution/deobfuscation/research/2022/03/26/angr_notes.html).

#### Flag Extraction

```python
class Flags:
    """Parse x86 EFLAGS register into individual flag bits."""
    def __init__(self, register):
        self.CF = bool(register & 0x0001)   # Carry Flag
        self.PF = bool(register & 0x0004)   # Parity Flag
        self.AF = bool(register & 0x0010)   # Auxiliary Carry Flag
        self.ZF = bool(register & 0x0040)   # Zero Flag
        self.SF = bool(register & 0x0080)   # Sign Flag
        self.TF = bool(register & 0x0100)   # Trap Flag
        self.IF = bool(register & 0x0200)   # Interrupt Enable Flag
        self.DF = bool(register & 0x0400)   # Direction Flag
        self.OF = bool(register & 0x0800)   # Overflow Flag

    def infer_condition(self, other):
        """Compare two flag states to infer the branch condition type."""
        if self.ZF != other.ZF:
            return 'jz' if self.ZF else 'jnz'
        if self.SF != other.SF:
            return 'js' if self.SF else 'jns'
        if self.CF != other.CF:
            return 'jb' if self.CF else 'jae'
        if (self.SF ^ self.OF) != (other.SF ^ other.OF):
            return 'jl' if (self.SF ^ self.OF) else 'jge'
        return None
```

#### CMov-to-Jcc Mapping

CFF obfuscators use `cmov` instructions to select the next state value based on conditions. The patching script must detect which `cmov` variant is used and emit the corresponding `Jcc` instruction:

| cmov instruction | Condition | Jcc opcode bytes | Flag check |
|-----------------|-----------|-----------------|------------|
| `cmovz` / `cmove` | ZF=1 | `0x0F 0x84` (JZ) | `f.ZF == True` |
| `cmovnz` / `cmovne` | ZF=0 | `0x0F 0x85` (JNZ) | `f.ZF == False` |
| `cmovb` / `cmovc` | CF=1 | `0x0F 0x82` (JB) | `f.CF == True` |
| `cmovae` / `cmovnc` | CF=0 | `0x0F 0x83` (JAE) | `f.CF == False` |
| `cmovbe` | CF=1 or ZF=1 | `0x0F 0x86` (JBE) | `f.CF or f.ZF` |
| `cmova` | CF=0 and ZF=0 | `0x0F 0x87` (JA) | `not f.CF and not f.ZF` |
| `cmovs` | SF=1 | `0x0F 0x88` (JS) | `f.SF == True` |
| `cmovns` | SF=0 | `0x0F 0x89` (JNS) | `f.SF == False` |
| `cmovl` | SF!=OF | `0x0F 0x8C` (JL) | `f.SF != f.OF` |
| `cmovge` | SF==OF | `0x0F 0x8D` (JGE) | `f.SF == f.OF` |
| `cmovle` | ZF=1 or SF!=OF | `0x0F 0x8E` (JLE) | `f.ZF or (f.SF != f.OF)` |
| `cmovg` | ZF=0 and SF==OF | `0x0F 0x8F` (JG) | `not f.ZF and (f.SF == f.OF)` |

#### Patching with struct (standalone)

```python
import struct

def patch_unconditional(binary_data, patch_offset, target_addr, patch_addr):
    """
    Replace bytes at patch_offset with: jmp rel32 to target_addr.
    patch_addr = virtual address of the patch location.
    """
    rel = target_addr - (patch_addr + 5)
    jmp = b'\xe9' + struct.pack('<i', rel)
    return binary_data[:patch_offset] + jmp + binary_data[patch_offset + 5:]


def patch_conditional(binary_data, patch_offset, cond_target, uncond_target,
                      patch_addr, condition='jnz'):
    """
    Replace bytes at patch_offset with:
      Jcc rel32 to cond_target     (6 bytes)
      jmp rel32 to uncond_target   (5 bytes)
    """
    # Conditional jump opcodes (near jump, 0F 8x)
    JCC_OPCODES = {
        'jo':  0x80, 'jno': 0x81, 'jb':  0x82, 'jae': 0x83,
        'jz':  0x84, 'jnz': 0x85, 'jbe': 0x86, 'ja':  0x87,
        'js':  0x88, 'jns': 0x89, 'jp':  0x8A, 'jnp': 0x8B,
        'jl':  0x8C, 'jge': 0x8D, 'jle': 0x8E, 'jg':  0x8F,
    }

    # Jcc rel32 (6 bytes)
    jcc_opcode = JCC_OPCODES.get(condition, 0x85)  # default jnz
    cond_rel = cond_target - (patch_addr + 6)
    jcc = b'\x0f' + bytes([jcc_opcode]) + struct.pack('<i', cond_rel)

    # jmp rel32 (5 bytes, immediately after Jcc)
    uncond_rel = uncond_target - (patch_addr + 6 + 5)
    jmp = b'\xe9' + struct.pack('<i', uncond_rel)

    patch = jcc + jmp
    return binary_data[:patch_offset] + patch + binary_data[patch_offset + 11:]
```

#### Patching with IDA Python - Complete Script

This is the core IDA Python patching script based on the OALABS CFF deobfuscation research.
It iterates through recovered OBBs, detects `cmov` instructions to determine branch conditions,
and patches dispatcher jumps with direct jumps to successor OBBs.

```python
import ida_bytes
import idc
import struct

# CMov instruction -> (Jcc opcode bytes, flag check function)
# The flag check returns True when the cmov condition IS satisfied
CMOV_TO_JCC = {
    'cmovz':   (b'\x0F\x84', lambda f: f.ZF),
    'cmove':   (b'\x0F\x84', lambda f: f.ZF),
    'cmovnz':  (b'\x0F\x85', lambda f: not f.ZF),
    'cmovne':  (b'\x0F\x85', lambda f: not f.ZF),
    'cmovb':   (b'\x0F\x82', lambda f: f.CF),
    'cmovc':   (b'\x0F\x82', lambda f: f.CF),
    'cmovae':  (b'\x0F\x83', lambda f: not f.CF),
    'cmovnc':  (b'\x0F\x83', lambda f: not f.CF),
    'cmovbe':  (b'\x0F\x86', lambda f: f.CF or f.ZF),
    'cmova':   (b'\x0F\x87', lambda f: not f.CF and not f.ZF),
    'cmovs':   (b'\x0F\x88', lambda f: f.SF),
    'cmovns':  (b'\x0F\x89', lambda f: not f.SF),
    'cmovl':   (b'\x0F\x8C', lambda f: f.SF != f.OF),
    'cmovge':  (b'\x0F\x8D', lambda f: f.SF == f.OF),
    'cmovle':  (b'\x0F\x8E', lambda f: f.ZF or (f.SF != f.OF)),
    'cmovg':   (b'\x0F\x8F', lambda f: not f.ZF and (f.SF == f.OF)),
}


class Flags:
    """Parse x86 EFLAGS register into individual flag bits."""
    def __init__(self, register):
        self.CF = bool(register & 0x0001)
        self.PF = bool(register & 0x0004)
        self.AF = bool(register & 0x0010)
        self.ZF = bool(register & 0x0040)
        self.SF = bool(register & 0x0080)
        self.TF = bool(register & 0x0100)
        self.IF = bool(register & 0x0200)
        self.DF = bool(register & 0x0400)
        self.OF = bool(register & 0x0800)


def patch_cff_obbs(state_table, orig_code_bb):
    """
    Patch each OBB to replace dispatcher jumps with direct jumps.

    Args:
        state_table: dict from recover_state_machine()
            {state_val: (obb_addr, [(next_state_val, flags_val), ...])}
        orig_code_bb: list of OBB start addresses to patch
    """
    for obb_addr in orig_code_bb:
        # Find which state maps to this OBB
        for state_val, state_info in state_table.items():
            if obb_addr != state_info[0]:
                continue

            successors = state_info[1]

            if len(successors) == 0:
                # End state (return/exit) - no patching needed
                break

            elif len(successors) == 1:
                # --- Unconditional jump ---
                next_state_val = successors[0][0]
                next_obb_addr = state_table[next_state_val][0]

                # Walk forward to find the final 'jmp' (back to dispatcher)
                ptr = obb_addr
                while idc.print_insn_mnem(ptr) != 'jmp':
                    ptr = idc.next_head(ptr)

                # Patch: jmp rel32 to next OBB (5 bytes)
                jmp_rel = next_obb_addr - (ptr + 5)
                patch = b'\xe9' + struct.pack('<i', jmp_rel)
                ida_bytes.patch_bytes(ptr, patch)
                print(f"[UNCOND] {obb_addr:#x}: jmp {next_obb_addr:#x}")
                break

            else:
                # --- Conditional jump ---
                # Scan OBB for cmov instruction to determine branch type
                ptr = obb_addr
                jcc_opcode = None
                cond_check = None
                cond_jmp_addr = None
                uncond_jmp_addr = None

                while idc.print_insn_mnem(ptr) != 'jmp':
                    mnem = idc.print_insn_mnem(ptr)

                    if mnem in CMOV_TO_JCC:
                        jcc_opcode, cond_check = CMOV_TO_JCC[mnem]

                        # Use saved flags to determine which successor
                        # satisfies the cmov condition
                        s1_val, s1_flags = successors[0]
                        s2_val, s2_flags = successors[1]
                        f = Flags(s1_flags)

                        if cond_check(f):
                            # Successor 1 satisfies the cmov condition
                            cond_jmp_addr = state_table[s1_val][0]
                            uncond_jmp_addr = state_table[s2_val][0]
                        else:
                            # Successor 2 satisfies the cmov condition
                            cond_jmp_addr = state_table[s2_val][0]
                            uncond_jmp_addr = state_table[s1_val][0]

                    ptr = idc.next_head(ptr)

                if jcc_opcode is None:
                    print(f"[WARN] {obb_addr:#x}: no cmov found, skipping")
                    break

                # ptr is now at the 'jmp' instruction (dispatcher jump)
                # Patch: Jcc rel32 (6 bytes) + jmp rel32 (5 bytes)

                # Conditional jump
                cond_rel = cond_jmp_addr - (ptr + 6)
                patch_cond = jcc_opcode + struct.pack('<i', cond_rel)
                ida_bytes.patch_bytes(ptr, patch_cond)
                ptr += 6

                # Unconditional fallthrough jump
                uncond_rel = uncond_jmp_addr - (ptr + 5)
                patch_uncond = b'\xe9' + struct.pack('<i', uncond_rel)
                ida_bytes.patch_bytes(ptr, patch_uncond)

                print(f"[COND] {obb_addr:#x}: "
                      f"Jcc {cond_jmp_addr:#x}, jmp {uncond_jmp_addr:#x}")
                break


def nop_dispatcher_region(dispatcher_addr, dispatcher_end):
    """
    NOP out the dispatcher code so it does not confuse the decompiler.
    Call this after patching all OBBs.
    """
    size = dispatcher_end - dispatcher_addr
    ida_bytes.patch_bytes(dispatcher_addr, b'\x90' * size)
    print(f"[NOP] Dispatcher {dispatcher_addr:#x}-{dispatcher_end:#x} "
          f"({size} bytes)")
```

**Usage in IDA Python console:**

```python
# After running angr recovery script to get state_table:
# state_table = {0x1234: (0x401100, [(0x5678, 0x246)]), ...}

# Collect all OBB addresses
orig_code_bb = [info[0] for info in state_table.values()]

# Apply patches
patch_cff_obbs(state_table, orig_code_bb)

# Optionally NOP the dispatcher
nop_dispatcher_region(0x401050, 0x401090)

# Reanalyze the function in IDA
idc.del_func(func_start)
idc.add_func(func_start)
```

#### Simplified IDA Patching (Minimal Version)

For quick patching when you already know the OBB layout:

```python
import ida_bytes
import idc
import struct

def patch_obb_ida(state_table, obb_end_addrs):
    """
    Patch each OBB's final jump-to-dispatcher with direct jumps.

    state_table: from recover_state_machine()
    obb_end_addrs: dict mapping state_val -> address of the final jmp instruction
    """
    for state_val, (obb_addr, successors) in state_table.items():
        if state_val not in obb_end_addrs:
            continue

        patch_addr = obb_end_addrs[state_val]

        if len(successors) == 1:
            # Unconditional: single successor
            next_state_val = successors[0][0]
            next_obb_addr = state_table[next_state_val][0]
            rel = next_obb_addr - (patch_addr + 5)
            patch = b'\xe9' + struct.pack('<i', rel)
            ida_bytes.patch_bytes(patch_addr, patch)
            print(f"Patched {patch_addr:#x}: jmp {next_obb_addr:#x}")

        elif len(successors) == 2:
            # Conditional: two successors with different flag conditions
            s1_val, s1_flags = successors[0]
            s2_val, s2_flags = successors[1]

            flags1 = Flags(s1_flags) if s1_flags is not None else None
            flags2 = Flags(s2_flags) if s2_flags is not None else None

            # Determine which successor is the conditional target
            if flags1 and not flags1.ZF:
                # ZF=0 means the condition was true for jnz
                cond_target = state_table[s1_val][0]
                uncond_target = state_table[s2_val][0]
            else:
                cond_target = state_table[s2_val][0]
                uncond_target = state_table[s1_val][0]

            # Patch: Jcc rel32 (6 bytes) + jmp rel32 (5 bytes)
            cond_rel = cond_target - (patch_addr + 6)
            jcc = b'\x0f\x85' + struct.pack('<i', cond_rel)  # jnz

            uncond_rel = uncond_target - (patch_addr + 6 + 5)
            jmp = b'\xe9' + struct.pack('<i', uncond_rel)

            ida_bytes.patch_bytes(patch_addr, jcc + jmp)
            print(f"Patched {patch_addr:#x}: jnz {cond_target:#x}, jmp {uncond_target:#x}")
```

### Complete Standalone CFF Deobfuscation Script

```python
#!/usr/bin/env python3
"""
CFF Deobfuscation via angr symbolic execution.
Recovers original control flow from flattened binaries (OLLVM, Tigress, etc.).

Usage:
    python3 deflat.py --binary ./obfuscated --func 0x401000 --dispatcher 0x401050
"""

import angr
import claripy
import struct
import argparse
from queue import Queue


class X86Flags:
    def __init__(self, eflags):
        self.CF = bool(eflags & 0x0001)
        self.PF = bool(eflags & 0x0004)
        self.AF = bool(eflags & 0x0010)
        self.ZF = bool(eflags & 0x0040)
        self.SF = bool(eflags & 0x0080)
        self.OF = bool(eflags & 0x0800)


def recover_cff(binary_path, func_addr, dispatcher_addr, state_reg='eax',
                max_step=500):
    p = angr.Project(binary_path, auto_load_libs=False)

    # Find initial state at dispatcher
    state = p.factory.call_state(addr=func_addr)
    state.options.add(angr.options.CALLLESS)
    sm = p.factory.simulation_manager(state)

    for _ in range(max_step):
        if sm.active and sm.active[0].addr == dispatcher_addr:
            break
        sm.step()
    else:
        print("[-] Could not reach dispatcher from function entry")
        return None

    disp_state = sm.active[0].copy()
    reg = getattr(disp_state.regs, state_reg)
    init_val = disp_state.solver.eval_one(reg)
    print(f"[+] Initial state: {init_val:#x}")

    # BFS to recover all states
    table = {}
    visited = set()
    q = Queue()
    q.put(init_val)

    while not q.empty():
        sv = q.get()
        if sv in visited:
            continue
        visited.add(sv)

        # Find OBB for this state value
        s = disp_state.copy()
        setattr(s.regs, state_reg, s.solver.BVV(sv, reg.size()))
        sm = p.factory.simulation_manager(s)
        obb_addr = None
        obb_state = None
        for _ in range(200):
            sm.step()
            if not sm.active:
                break
            if sm.active[0].addr != dispatcher_addr:
                obb_addr = sm.active[0].addr
                obb_state = sm.active[0].copy()
                break

        if obb_state is None:
            print(f"  [-] State {sv:#x}: dead")
            continue

        # Execute OBB to find next states
        sm2 = p.factory.simulation_manager(obb_state)
        reached = False
        for _ in range(max_step):
            sm2.step()
            if not sm2.active:
                break
            if sm2.active[0].addr == dispatcher_addr:
                reached = True
                break

        succs = []
        if reached:
            final = sm2.active[0]
            next_reg = getattr(final.regs, state_reg)
            for nv in final.solver.eval_upto(next_reg, 8):
                fv = final.solver.eval_upto(
                    final.regs.flags, 2,
                    extra_constraints=[next_reg == nv]
                )
                succs.append((nv, fv[0] if fv else None))

        table[sv] = (obb_addr, succs)
        kind = "uncond" if len(succs) == 1 else f"cond({len(succs)})"
        print(f"  [+] {sv:#x} -> {obb_addr:#x} [{kind}]"
              f" -> {[hex(v) for v, _ in succs]}")

        for nv, _ in succs:
            if nv not in visited:
                q.put(nv)

    print(f"\n[+] Recovered {len(table)} states")
    return table


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='CFF Deobfuscation via angr')
    parser.add_argument('--binary', required=True, help='Path to binary')
    parser.add_argument('--func', required=True, help='Function entry address (hex)')
    parser.add_argument('--dispatcher', required=True, help='Dispatcher address (hex)')
    parser.add_argument('--reg', default='eax', help='State register (default: eax)')
    args = parser.parse_args()

    table = recover_cff(
        args.binary,
        int(args.func, 16),
        int(args.dispatcher, 16),
        args.reg
    )
```

### Common Pitfalls

1. **Wrong dispatcher address**: The dispatcher is not always the function entry. Look for the block with the most incoming edges in the CFG.

2. **State variable not in a register**: Some obfuscators use stack variables instead of registers. You may need to read from `state.memory.load(state.regs.rbp - offset, 4)` instead of `state.regs.eax`.

3. **Nested dispatchers**: Some obfuscators use multiple levels of dispatching. Run the recovery recursively if the "OBBs" themselves contain another dispatcher pattern.

4. **Opaque predicates**: CFF may include bogus conditional branches with always-true/false predicates. These show up as single-successor conditional blocks. Ignore the flags and treat as unconditional.

5. **CALLLESS may skip important code**: If OBBs contain function calls whose return values affect the state variable, remove `CALLLESS` and hook specific functions instead.

6. **Large binaries**: Increase Docker memory (`-m 8g`) and set solver timeout (`state.solver._solver.timeout = 300000`).

---

## Complete Solve Script Template

A production-ready template combining best practices:

```python
#!/usr/bin/env python3
"""angr solve script for [CHALLENGE_NAME]."""

import angr
import claripy
import logging
import sys

# Adjust logging (uncomment for debug)
# logging.getLogger('angr').setLevel(logging.DEBUG)

BINARY = './challenge'

# Addresses (update from disassembly)
SUCCESS_ADDR = None  # Address of success/win path
FAIL_ADDR = None     # Address of failure/lose path (or list)

def solve():
    p = angr.Project(BINARY, auto_load_libs=False)

    # --- Choose your setup ---

    # Option A: stdin input
    state = p.factory.entry_state(
        add_options={angr.options.LAZY_SOLVES}
    )

    # Option B: argv input
    # INPUT_LEN = 32
    # sym_input = claripy.BVS('input', 8 * INPUT_LEN)
    # state = p.factory.entry_state(args=[BINARY, sym_input])
    # for byte in sym_input.chop(8):
    #     state.solver.add(byte >= 0x20)
    #     state.solver.add(byte <= 0x7e)

    # Option C: blank state
    # state = p.factory.blank_state(addr=FUNC_ADDR)

    # --- Hooks (if needed) ---
    # p.hook(ADDR, angr.SIM_PROCEDURES['libc']['strlen'](), length=5)

    # --- Explore ---
    sm = p.factory.simulation_manager(state)

    if SUCCESS_ADDR and FAIL_ADDR:
        sm.explore(find=SUCCESS_ADDR, avoid=FAIL_ADDR)
    elif SUCCESS_ADDR:
        sm.explore(find=SUCCESS_ADDR)
    else:
        # Use stdout matching
        sm.explore(
            find=lambda s: b"correct" in s.posix.dumps(1).lower(),
            avoid=lambda s: b"wrong" in s.posix.dumps(1).lower()
        )

    # --- Extract solution ---
    if sm.found:
        found = sm.found[0]
        print("[+] Solution found!")
        print(f"    stdin:  {found.posix.dumps(0)}")
        print(f"    stdout: {found.posix.dumps(1)}")
        # If using symbolic argv:
        # print(f"    input: {found.solver.eval(sym_input, cast_to=bytes)}")
        return True
    else:
        print("[-] No solution found")
        print(f"    Active: {len(sm.active)}")
        print(f"    Deadended: {len(sm.deadended)}")
        print(f"    Errored: {len(sm.errored)}")
        return False

if __name__ == '__main__':
    solve()
```
