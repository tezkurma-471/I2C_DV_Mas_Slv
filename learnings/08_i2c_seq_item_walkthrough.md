> **⚠️ 2026-06-10 AUDIT UPDATE — read this box before trusting the lesson below.**
> A deep audit + fix pass changed the code this walkthrough describes. Deltas for this file:
> - `addr_ack`, `byte_ack[]` and `ack_received` are now populated by the DRIVER too (it used to sample ACK into a local and throw it away) — the expected stream finally carries real ACK results.
> Full detail: [`19_audit_fixes_walkthrough.md`](./19_audit_fixes_walkthrough.md) and `docs/AUDIT_FIX_REPORT.md`.

# Lesson 08 — `i2c_seq_item.sv` Deep Dive

**File under study:** `uvm/i2c_seq_item.sv` (~150 lines)
**Concepts covered:** UVM sequence item, factory registration, `rand`/`randc`, constraints (hard/soft), `uvm_field_*` macros vs manual `do_copy`/`do_compare`/`do_print`, `convert2string`, `pre_randomize`/`post_randomize`, transaction abstraction
**Date:** 2026-05-17

---

## Table of Contents

1. [Architecture — Where the `seq_item` Lives in UVM](#1-architecture--where-the-seq_item-lives-in-uvm)
2. [The 60-Second Elevator Pitch](#2-the-60-second-elevator-pitch)
3. [Class Definition Walkthrough](#3-class-definition-walkthrough)
4. [Fields — `rand`, `randc`, Plain, and Static](#4-fields--rand-randc-plain-and-static)
5. [Constraints — Solver Semantics, Precedence, Soft vs Hard](#5-constraints--solver-semantics-precedence-soft-vs-hard)
6. [UVM Field Macros — What They Auto-Generate](#6-uvm-field-macros--what-they-auto-generate)
7. [`do_copy` / `do_compare` / `do_print` — When to Override Manually](#7-do_copy--do_compare--do_print--when-to-override-manually)
8. [`convert2string` — Log-Friendly Formatting](#8-convert2string--log-friendly-formatting)
9. [`pre_randomize` and `post_randomize` — Hooks Around the Solver](#9-pre_randomize-and-post_randomize--hooks-around-the-solver)
10. [Quiz — 12 Questions](#10-quiz--12-questions)
11. [Quiz — Answers & Deep Explanations](#11-quiz--answers--deep-explanations)
12. [Key Takeaways](#12-key-takeaways)
13. [Action Items](#13-action-items)
14. [Honest Self-Score Template](#14-honest-self-score-template)

---

## 1. Architecture — Where the `seq_item` Lives in UVM

Before reading a single line, internalize this: **the sequence item is the atom of every UVM
testbench**. Every other UVM component either **produces it, transports it, drives it, observes
it, or scores it**. If you understand the seq_item, the rest of UVM is wiring.

```
                            +------------------+
                            |  i2c_sequence    |   1. Sequence creates seq_items
                            |  (extends        |      via uvm_do / `uvm_create.
                            |   uvm_sequence)  |      Randomizes them.
                            +--------+---------+
                                     |
                  start_item() / finish_item()  (handshake)
                                     |
                                     v
                            +------------------+
                            |  i2c_sequencer   |   2. Sequencer arbitrates between
                            | (uvm_sequencer)  |      multiple sequences and hands
                            +--------+---------+      the item to the driver.
                                     |
                       seq_item_port.get_next_item()
                                     |
                                     v
   +----------------------+   +------------------+    +---------------------+
   |   i2c_monitor        |   |  i2c_driver      |    |   DUT (i2c_slave)   |
   |  (uvm_monitor)       |<--| (uvm_driver)     |--->|                     |
   |  Reconstructs        |   |  Pin-wiggles the |    |  SCL / SDA pins     |
   |  seq_items from pins |   |  bus per item    |    |                     |
   +----------+-----------+   +------------------+    +---------------------+
              |
              | analysis_port.write(item)
              v
   +----------------------+
   |   i2c_scoreboard     |   3. Scoreboard compares the monitor's
   |   (uvm_scoreboard)   |      observed item vs the driver's expected
   +----------------------+      item using do_compare().
```

### The seq_item's five lives

| Stage | Who touches it | What they do |
|---|---|---|
| Birth | Sequence | `type_id::create()`, then `randomize()` |
| Transport | Sequencer | Arbitration & flow control |
| Stimulus | Driver | Reads fields, wiggles pins |
| Observation | Monitor | Builds a fresh seq_item from pin activity |
| Verdict | Scoreboard | `do_compare()` between expected (from seq) and observed (from monitor) |

**Critical insight:** A seq_item is **NOT** a component. It is a `uvm_object`. It has no phases,
no run-time, no analysis port. It's a passive data carrier — like a `struct` with metadata.

---

## 2. The 60-Second Elevator Pitch

When an interviewer asks *"What is a UVM sequence item?"* — say this:

> *"A `uvm_sequence_item` is the transaction-level abstraction of a single protocol action.
> It extends `uvm_object`, is registered with the factory via `` `uvm_object_utils ``, and
> contains the fields that describe the transaction — for I2C that's `addr`, `dir`, `data[]`,
> START/STOP flags, and ACK status. Sequences create and randomize them; drivers consume them
> via the sequencer; monitors reconstruct them from bus pins; the scoreboard compares expected
> versus observed using `do_compare()`. It is the single source of truth for what a 'transaction'
> means in the testbench."*

Memorize the **shape**: extends → factory → fields → produced by sequence → driven by driver →
reconstructed by monitor → compared by scoreboard.

---

## 3. Class Definition Walkthrough

```systemverilog
class i2c_seq_item extends uvm_sequence_item;

  `uvm_object_utils(i2c_seq_item)
```

### Line 12 — `extends uvm_sequence_item`

Why `uvm_sequence_item` and not `uvm_object` directly? Because `uvm_sequence_item` adds
**sequence-aware metadata**: a `transaction_id`, a `sequence_id`, parent-sequence pointers,
and the `get_full_name()` chain that links the item back to its originating sequence.
This metadata is what enables UVM's hierarchical reporting (`uvm_info` knows which sequence
produced the item) and analysis-port correlation.

If you extend `uvm_object` directly, your data still works — but you lose all sequence
correlation. **`uvm_sequence_item` is the ONLY correct base for items that flow through a
sequencer-driver pipe.**

### Line 14 — `` `uvm_object_utils(i2c_seq_item) ``

This macro expands to four things you would otherwise write by hand:

```systemverilog
typedef uvm_object_registry#(i2c_seq_item, "i2c_seq_item") type_id;
static function i2c_seq_item type_id_create(string name, uvm_component parent);
  ...
endfunction
virtual function uvm_object_wrapper get_object_type();
  return type_id::get();
endfunction
virtual function string get_type_name();
  return "i2c_seq_item";
endfunction
```

Translation: it **registers the class with the UVM factory** under the string key
`"i2c_seq_item"` and gives you a `type_id::create()` static method. The factory now knows
how to construct this class by name — which is exactly what enables **factory overrides**:

```systemverilog
// In a test:
i2c_seq_item::type_id::set_type_override(i2c_corrupt_item::type_id::get());
// Now EVERY i2c_seq_item::type_id::create() returns an i2c_corrupt_item instead.
```

This is the polymorphism trick that lets you swap transaction types **without touching the
sequence code**. Junior engineers don't realize how powerful this is.

#### Why `uvm_object_utils` and NOT `uvm_component_utils`?

| Macro | For | Why |
|---|---|---|
| `` `uvm_object_utils `` | Items, configs, RAL fields, any **data** | Lifetime is short, created on demand, no phases |
| `` `uvm_component_utils `` | Driver, monitor, agent, env, scoreboard | Lifetime spans the whole sim, has phases (build/connect/run), exists in the hierarchy |

**Interview trap:** People mistakenly use `uvm_component_utils` for a seq_item because they
copy-paste from a driver. The factory will still register it, but `create()` calls will demand
a `parent` argument that doesn't make sense for a transaction. **Wrong macro = wrong base
class semantics.** Always: object for data, component for behavior.

---

## 4. Fields — `rand`, `randc`, Plain, and Static

### The fields in this class

```systemverilog
rand logic [6:0]  addr;       // 7-bit slave address
rand i2c_dir_e    dir;        // READ or WRITE
rand bit [7:0]    data [$];   // Data payload (queue)
rand int          num_data;   // Number of bytes

rand bit          start_cond;
rand bit          stop_cond;
rand bit          rep_start;

i2c_status_e      status;     // Non-rand — set by driver/monitor
bit               ack_received;
bit               addr_ack;
bit               byte_ack [$];

rand bit          inject_nack;
rand bit          inject_timeout;

int               num_rep_starts;
bit               stretch_seen;
```

### `rand` — random on every `.randomize()` call

A `rand` field gets a **fresh random value every time** you call `randomize()` on the object.
The solver may pick the same value twice in a row — that's fine; it's stateless.

### `randc` — cyclic random, no repeats until cycle exhausts

A `randc` field guarantees that **all possible values are produced once before any value
repeats**. For a 3-bit `randc bit [2:0]`, the solver will hand you all 8 values (in random
order) before any one repeats.

**Cost:** the solver must track the "already-used" set per object → memory + slower solving.
**Restriction:** `randc` only works on `bit`/`logic` of width ≤ 8 (some tools allow up to 16).
You **cannot** declare `randc int` or `randc i2c_dir_e` directly — too many states.

**Why none of the fields here are `randc`:**

- `addr` is 7 bits — eligible for `randc` (128 values). But for I2C, you typically want
  weighted distributions (specific slave addresses appear more often), not strict cycling.
- `dir` is an enum — randc on enums is tool-dependent and brittle.
- `data` is a queue — randc on queues is not supported.
- `start_cond`, `stop_cond`, `rep_start` are 1-bit — `randc` would just alternate 0/1, which
  is exactly what you usually do **not** want for protocol stress.

#### When `randc` IS the right call

- A scoreboard hash key that must cover all values uniformly (e.g., FIFO entry IDs).
- A small enum where you want guaranteed coverage of every state (e.g., bus phases).
- DV scenario IDs in a directed-sequence pool.

### Plain (no `rand`) — set by code, not the solver

```systemverilog
i2c_status_e  status;
bit           ack_received;
bit           addr_ack;
```

These are **monitor-populated**. The driver/monitor writes them after the bus transaction
completes. If they were `rand`, calling `randomize()` would wipe them out — disastrous when
the scoreboard tries to read the observed status.

**Pattern:** Inputs to the DUT → `rand`. Outputs/observations → plain.

### `static` — would mean "shared across all instances"

There are no `static` fields here, and there shouldn't be. A `static` field on a seq_item
means **every transaction shares the same memory location** for that field. That breaks the
fundamental contract that each transaction is independent.

**Legitimate use of `static` on a seq_item:** a class-wide ID counter:

```systemverilog
static int unsigned global_txn_id;
int unsigned         my_txn_id;

function new(string name = "");
  super.new(name);
  my_txn_id = global_txn_id++;   // Each instance gets a unique ID
endfunction
```

But the **per-transaction data must never be static**.

---

## 5. Constraints — Solver Semantics, Precedence, Soft vs Hard

### The five constraints in this class

```systemverilog
constraint valid_addr_c { ... }       // Reject reserved addresses
constraint data_size_c { ... }        // num_data ∈ [1,32], data.size() == num_data
constraint default_trans_c { ... }    // Default: standalone START..STOP transaction
constraint valid_protocol_c { ... }   // Must have START or REP_START, not both
constraint default_errors_c { ... }   // Default: no error injection
```

### How the constraint solver actually works

When you call `item.randomize()`, the solver:

1. Collects all **active** constraints (active means: not turned off via `constraint_mode(0)`).
2. Builds a **constraint satisfaction problem (CSP)** over all `rand` fields.
3. Picks a **random solution** that satisfies all constraints simultaneously.
4. If the system is unsatisfiable, returns `0` (and your test fails).

**Critical correction to a common misconception:** The solver does **NOT** evaluate
constraints "top to bottom". It treats the whole set as a system of equations. A constraint
at the bottom of the file can influence a value computed at the top.

### Solving order — implementation vs visible

Within a single solution, the solver uses **`solve...before`** statements to control which
field is picked first when fields are correlated:

```systemverilog
constraint solve_order_c {
  solve num_data before data;   // Pick size first, then content
}
```

The I2C seq_item uses `data.size() == num_data` — but **omits** an explicit `solve...before`.
Most simulators implicitly solve `num_data` first because `data.size()` depends on it, but
this is **fragile**. On some tool versions, the solver picks `data` randomly first (creating
some random-sized queue), then tries to satisfy `num_data == data.size()` → it works, but
the distribution of `num_data` is **NOT** uniform over [1, 32]. It's biased toward whatever
the queue size defaulted to.

**Fix you should propose:** add `solve num_data before data;` explicitly.

### Hard vs soft constraints

| Type | Syntax | Behavior |
|---|---|---|
| Hard | `addr != 7'h00;` | Solver MUST satisfy; failure = error |
| Soft | `soft start_cond == 1;` | Solver TRIES; can be overridden externally |

**Soft constraint mechanics:** A soft constraint has lower precedence than any hard constraint
or any external `randomize()-with` clause. If a sequence does:

```systemverilog
item.randomize() with { start_cond == 0; };
```

A `soft start_cond == 1;` inside the class is **silently overridden** by the sequence's
`with`-clause (which is hard). No error. The soft default is just "what you want if nobody
says otherwise".

**This file uses HARD constraints for defaults** (`start_cond == 1;` with no `soft`). That
means any sequence that tries `randomize() with { start_cond == 0; }` will get a
**constraint failure**.

**Senior fix:** the four default constraints (`default_trans_c`, `default_errors_c`) should
be `soft`. Otherwise, error-injection tests need to first call
`item.default_errors_c.constraint_mode(0);` — clunky and error-prone.

### `constraint_mode()` — turning constraints on/off

```systemverilog
item.valid_addr_c.constraint_mode(0);   // Disable this constraint
item.constraint_mode(0);                // Disable ALL constraints on item
```

Useful for **negative tests**: deliberately inject reserved addresses (`7'h00`) to verify
the DUT rejects them. **Interview-grade move:** mention `constraint_mode` as the alternative
to `soft` constraints when you want fine-grained, per-test override.

### `valid_protocol_c` — boolean algebra in constraints

```systemverilog
constraint valid_protocol_c {
  start_cond || rep_start;     // At least one
  !(start_cond && rep_start);  // Not both
}
```

This is **logical XOR**: exactly one of the two must be 1. Could be written as:

```systemverilog
start_cond ^ rep_start == 1;
```

Both forms are correct; the explicit form is more readable. The two statements inside one
`constraint` block are **AND-ed together** — every statement must be satisfied.

### Where does the seed come from?

Every randomization is deterministic given a seed. SystemVerilog's `srandom()` sets the seed
of an object's local RNG:

```systemverilog
item.srandom(42);     // From now on, item.randomize() picks values deterministically
```

If you don't set a seed, the simulator's global seed (often `+ntb_random_seed=...` from the
command line) is used. Each object has its **own RNG context**, so randomizing one item
doesn't affect another's sequence.

**Reproducibility rule:** When debugging a failing test, capture the seed from the simulator
log and rerun with that exact seed. Bugs that depend on randomization are otherwise impossible
to reproduce.

---

## 6. UVM Field Macros — What They Auto-Generate

This file does **NOT** use `` `uvm_field_*`` macros. It implements `do_copy`, `do_compare`,
`do_print`, and `convert2string` manually. Let's first understand what the macros WOULD do,
then justify the manual choice.

### The macros — what they look like

If we used field macros, we'd add this inside the class:

```systemverilog
`uvm_object_utils_begin(i2c_seq_item)
  `uvm_field_int    (addr,        UVM_ALL_ON)
  `uvm_field_enum   (i2c_dir_e, dir, UVM_ALL_ON)
  `uvm_field_queue_int(data,      UVM_ALL_ON)
  `uvm_field_int    (num_data,    UVM_ALL_ON)
  `uvm_field_int    (start_cond,  UVM_ALL_ON)
  `uvm_field_int    (stop_cond,   UVM_ALL_ON)
  `uvm_field_int    (rep_start,   UVM_ALL_ON)
  `uvm_field_enum   (i2c_status_e, status, UVM_ALL_ON | UVM_NOCOMPARE)
  `uvm_field_int    (addr_ack,    UVM_ALL_ON)
  `uvm_field_queue_int(byte_ack,  UVM_ALL_ON | UVM_NOCOMPARE)
`uvm_object_utils_end
```

### What each macro auto-generates

| Method | Purpose | Generated body |
|---|---|---|
| `do_copy` | Deep-copy fields from rhs to this | Iterates registered fields, assigns each |
| `do_compare` | Field-by-field equality | Returns 1 iff all fields equal |
| `do_print` | Pretty-print via `uvm_printer` | Calls `printer.print_*` per field |
| `convert2string` | One-line string repr | Returns concatenated `name=value` pairs |
| `do_pack` / `do_unpack` | Bit-level serialization | Streams fields into/out of a `uvm_packer` |
| `do_record` | Waveform recording | Sends fields to the simulator's transaction DB |

### The flags — what they mean

| Flag | Effect |
|---|---|
| `UVM_ALL_ON` | Enable in all operations |
| `UVM_DEFAULT` | Same as `UVM_ALL_ON` in modern UVM |
| `UVM_NOCOMPARE` | Skip in `do_compare` (e.g., status fields that monitor sets) |
| `UVM_NOPRINT` | Skip in `do_print` (e.g., huge arrays) |
| `UVM_NOPACK` | Skip in pack/unpack |
| `UVM_NOCOPY` | Skip in copy (rare) |
| `UVM_HEX` / `UVM_BIN` / `UVM_DEC` | Print radix |

**Critical:** `UVM_NOCOMPARE` is what you'd use on `status`, `addr_ack`, `byte_ack` because
those are **monitor-populated outputs** — the scoreboard compares EXPECTED vs OBSERVED and
the EXPECTED item doesn't have these filled in.

### Pros of using macros

- **Less boilerplate.** One line per field, not five.
- **Consistent semantics.** Pack/unpack, record, and print all behave the same way.
- **Auto-updates.** Add a field → just add one macro line. Manual code requires editing
  four methods.

### Cons (why this project skipped them)

1. **Performance.** Field macros use reflection-style dispatch internally (`uvm_field_op` in
   UVM 1.2+). Every operation walks a registered-field table. For a sim that creates millions
   of seq_items, this overhead is **measurable** — Synopsys VCS reports 10–30% sim time spent
   in field-macro code on heavy testbenches.
2. **Debugging difficulty.** When a comparison fails, the macros print `field X differs:
   0x42 vs 0x43` — but they don't give you a stack trace or context. Manual `do_compare`
   lets you add `uvm_error` with custom messages.
3. **No conditional logic.** Want to compare `data[]` only if `dir == DIR_WRITE`? Macros
   can't express that. Manual code can.
4. **Compile-time bloat.** Macros expand to hundreds of lines per class. Slows compilation,
   uglifies error messages.

**Industry trend:** **Mixed approach.** Use macros for **simple data items** (registers, configs)
and manual methods for **rich items with conditional semantics** (protocol transactions).
This I2C file leans manual — defensible choice.

---

## 7. `do_copy` / `do_compare` / `do_print` — When to Override Manually

### The contract

UVM defines a Template Method pattern:

```
copy()    → calls do_copy()    ← YOU override this
compare() → calls do_compare() ← YOU override this
print()   → calls do_print()   ← YOU override this
```

Users always call `item1.copy(item2)` (or `compare`, `print`). The framework dispatches to
`do_copy(item2)`, where you implement the per-class logic. **Never override `copy()` itself.**

### `do_copy` walkthrough

```systemverilog
virtual function void do_copy(uvm_object rhs);
  i2c_seq_item item;
  super.do_copy(rhs);
  if (!$cast(item, rhs)) return;
  addr           = item.addr;
  dir            = item.dir;
  data           = item.data;          // Queue assignment = deep copy
  ...
endfunction
```

Five things going on:

1. **`super.do_copy(rhs)`** — copies parent-class fields (`uvm_sequence_item` has
   `m_sequence_id`, etc.). **Never skip this.** Skipping it breaks UVM internal bookkeeping.
2. **`$cast(item, rhs)`** — runtime type check. If `rhs` isn't an `i2c_seq_item`, `$cast`
   returns 0 and we silently bail. **Defensive:** if `$cast` fails, that's a bug in the
   caller, and you'd ideally `uvm_error` it instead of silent return.
3. **Field-by-field assignment** — copies each field. For queues (`data`, `byte_ack`),
   SV's `=` operator on dynamic arrays/queues is a **deep copy** (allocates new memory).
4. **Plain assignment for enums, bits, ints** — value semantics, no aliasing.
5. **No copy of `num_rep_starts` and `stretch_seen` in older versions** — this file copies
   them correctly. Older versions of this seq_item likely had a bug where these were missed,
   causing scoreboard false negatives. **(Bug-hunt opportunity: check git history.)**

#### Why "deep copy matters"

Shallow copy on a queue would copy the **handle**, leaving two seq_items pointing to the
same underlying data buffer. Modify one → the other changes silently → scoreboard sees
phantom mismatches. **In UVM, all copies must be deep.** This is exactly what the field
macros guarantee — and what your manual `do_copy` MUST guarantee too.

### `do_compare` walkthrough

```systemverilog
virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
  i2c_seq_item item;
  if (!$cast(item, rhs)) return 0;
  return (super.do_compare(rhs, comparer) &&
          (addr == item.addr) &&
          (dir  == item.dir) &&
          (data == item.data) &&
          (num_data == item.num_data) &&
          (addr_ack == item.addr_ack) &&
          (rep_start == item.rep_start));
endfunction
```

**Critical observations:**

1. **Returns a `bit`** — 1 = match, 0 = mismatch.
2. **Uses `&&` chain** — short-circuits on first mismatch. Efficient but you lose info about
   WHICH field mismatched. Better pattern:

   ```systemverilog
   bit ok = 1;
   if (addr != item.addr) begin
     `uvm_error("CMP", $sformatf("addr mismatch: exp=%0h obs=%0h", addr, item.addr))
     ok = 0;
   end
   // ... repeat for each field
   return ok;
   ```

3. **`uvm_comparer` argument is IGNORED** — the comparer is a UVM utility that can do
   miscompare reporting, policy decisions (compare with mask), and recursion control.
   Real-world code passes it to `comparer.compare_field()` etc. This file ignores it,
   which is functionally OK but loses UVM's standardized miscompare messages.
4. **Skips `data` comparison when `dir == DIR_READ`?** — NO, this file compares `data`
   unconditionally. **Bug potential:** for a READ transaction, the driver-side seq_item
   has `data == empty` (nothing to drive) but the monitor-side seq_item has `data ==
   [bytes received from slave]`. Comparing them naively will always mismatch.

   **Likely fix already in scoreboard:** scoreboard probably only compares specific fields,
   not by calling `expected.compare(observed)`. **Check the scoreboard to confirm.**

### Why override manually (the case for this file)

This seq_item has **fields the comparison should ignore**: `status`, `ack_received`,
`byte_ack`, `inject_nack`, `inject_timeout`, `num_rep_starts`, `stretch_seen`. These are
either monitor-observed (not part of "what was the transaction") or driver-injection knobs
(not relevant to the comparison).

Manual `do_compare` lets you cherry-pick. Field macros would require `UVM_NOCOMPARE` on
each of those — more typing, but more declarative.

### `do_print` walkthrough

```systemverilog
virtual function void do_print(uvm_printer printer);
  printer.print_string("addr",     $sformatf("0x%02x", addr));
  printer.print_string("dir",      dir.name());
  printer.print_int   ("num_data", num_data,   $bits(num_data));
  printer.print_int   ("start_cond", start_cond, $bits(start_cond));
  ...
endfunction
```

- **`printer.print_string`** for things you want pre-formatted (e.g., hex addresses).
- **`printer.print_int`** with `$bits(...)` to print bit-width metadata.
- **`dir.name()`** — converts enum to its string label ("DIR_WRITE" not "1").

**`do_print` is called by `item.print()`** when a user wants the multi-line table view.
**`convert2string`** is for the one-line `uvm_info` view. They serve different audiences.

---

## 8. `convert2string` — Log-Friendly Formatting

```systemverilog
virtual function string convert2string();
  string s;
  s = $sformatf("I2C: addr=0x%02x dir=%s num_data=%0d ",
                addr, dir.name(), num_data);
  if (start_cond) s = {s, "[START]" };
  if (rep_start)  s = {s, "[REP_START]"};
  if (stop_cond)  s = {s, "[STOP]" };
  s = {s, $sformatf(" addr_ack=%0b reps=%0d stretch=%0b",
                    addr_ack, num_rep_starts, stretch_seen)};
  return s;
endfunction
```

### Why this is good

- **One-line output** — fits in a single log line, easy to grep.
- **Hex address** (`%02x`) — matches I2C convention.
- **Conditional flags** in brackets — `[START]`, `[STOP]` — readable at a glance.
- **Decimal byte counts** (`%0d`) — natural for humans.
- **Includes monitor fields** (`addr_ack`, `reps`, `stretch`) — visible in trace logs.

### Sample output

```
I2C: addr=0x50 dir=DIR_WRITE num_data=3 [START][STOP] addr_ack=1 reps=0 stretch=0
I2C: addr=0x68 dir=DIR_READ  num_data=1 [REP_START]   addr_ack=1 reps=2 stretch=1
```

### Use it everywhere

```systemverilog
`uvm_info("DRV", $sformatf("Sending %s", item.convert2string()), UVM_MEDIUM)
```

**Interview tip:** When asked "how did you debug your tests?" — say *"I made sure every
transaction printed through `convert2string` so the simulation log was a complete protocol
trace. grep on the log gave me a per-bus history without re-running with waveforms."*

### What `convert2string` does NOT do

- It does **not** include sensitive internal state like `inject_nack` (intentionally — these
  are driver knobs, not protocol fields).
- It does **not** print `data[]` content. For a 32-byte payload that would explode log size.
  **Improvement opportunity:** add a `verbose` mode that includes data.

---

## 9. `pre_randomize` and `post_randomize` — Hooks Around the Solver

These are **callbacks** the solver invokes around `randomize()`:

```
your_code.randomize()
   │
   ├─ pre_randomize()        ← YOU can override
   ├─ <solver runs>          ← Picks values for rand fields
   └─ post_randomize()       ← YOU can override
```

### `post_randomize` in this file

```systemverilog
function void post_randomize();
  foreach (data[i]) begin
    if ($isunknown(data[i]))
      data[i] = $urandom_range(0, 255);
  end
endfunction
```

**What it does:** After the solver picks values, walks the `data` queue and replaces any
unknown (X/Z) bits with a random 0..255 value.

**Why is this needed if `data` is `bit [7:0]`?** It shouldn't be — `bit` is 2-state, never X/Z.
But notice the original code had a comment: *"FIX: use 2-state 'bit' to prevent X/Z from
randomization"*. This implies an earlier version used `logic [7:0]` (4-state), and the
solver could legally pick X/Z. The fix migrated to `bit`. The `post_randomize` is now
**defensive code** — belt and suspenders.

**Senior engineer reaction:** "If you're sure `data` is 2-state, `post_randomize` is dead
code. Either delete it or change `data` back to `logic` and rely on `post_randomize` to
sanitize." Don't mix paranoia and confidence.

### Legitimate `post_randomize` use cases

1. **Calculate derived fields.** E.g., compute a CRC over the random data:

   ```systemverilog
   function void post_randomize();
     crc = compute_crc(data);
   endfunction
   ```

2. **Apply post-hoc constraints that the solver can't express.** E.g., enforce a constraint
   that requires multiple `randomize()` calls.

3. **Skew distributions.** Pick from a uniform random, then bias toward boundary values:

   ```systemverilog
   function void post_randomize();
     if ($urandom_range(0, 9) < 2)  // 20% of the time
       addr = 7'h7E;  // Boundary case
   endfunction
   ```

4. **Convert randomized "intent" into "form".** E.g., `rand bit large_burst;` →
   `post_randomize` picks `num_data = $urandom_range(16, 32)` if large_burst is set.

### `pre_randomize` use cases (not in this file)

1. **Snapshot state before randomization.** E.g., save the current `data` so you can
   restore on error.
2. **Adjust constraint modes based on test phase.** E.g., disable error injection during
   warmup.
3. **Compute constraints from external state.** E.g., read a config object and set a
   variable that hard constraints reference.

**Caveat:** `pre_randomize` runs **before** the solver — so you can't read random fields
inside it (they're not yet picked). It's for **setup**, not result inspection.

---

## 10. Quiz — 12 Questions

Cover the answers section before reading further. Goal: 9/12 correct.

1. **Why does a sequence item extend `uvm_sequence_item` and not `uvm_object` directly?**
   What metadata do you gain?

2. **You see `` `uvm_object_utils(i2c_seq_item) `` in the file. A junior engineer pastes
   `` `uvm_component_utils(i2c_seq_item) `` instead. The factory still registers the class.
   What goes wrong?**

3. **Explain the difference between `rand` and `randc` for an 8-bit field. Give one scenario
   where you would prefer `randc` even though it's slower.**

4. **Why does the I2C seq_item factory-register via `` `uvm_object_utils ``? What three
   capabilities does that macro give us beyond plain `extends`?**

5. **A coworker proposes using `` `uvm_field_int(addr, UVM_ALL_ON) `` instead of the manual
   `do_copy`/`do_compare`/`do_print`. Name three specific things the macro auto-generates,
   and two specific reasons NOT to use it here.**

6. **The manual `do_compare` in this file compares `addr`, `dir`, `data`, `num_data`,
   `addr_ack`, `rep_start` — but NOT `status` or `byte_ack`. Why? What's the verification
   principle?**

7. **Explain how a soft constraint differs from a hard constraint, both syntactically and
   semantically. In this file, are the default constraints (`default_trans_c`,
   `default_errors_c`) soft or hard? What's the consequence for a negative test that wants
   to set `inject_nack == 1`?**

8. **Describe one realistic scenario where you would override `pre_randomize()`. Why does
   it have to be `pre_` and not `post_`?**

9. **The `post_randomize()` in this file walks `data[]` and replaces X/Z values. But `data`
   is declared `bit [7:0]` (2-state). Is the post_randomize dead code, defensive code, or
   something else? Defend your answer.**

10. **Transaction granularity: I2C bus activity is, at the protocol level, a chain of
    primitive actions (START, address byte, data byte, STOP). Why does this seq_item
    represent a WHOLE transaction (addr + data[] + START/STOP flags) rather than ONE
    primitive per item?**

11. **Why does "deep copy" matter for a UVM seq_item that contains a queue (`data [$]`)?
    What goes wrong if `do_copy` accidentally does a shallow copy of the queue?**

12. **The solver order question: this file has `constraint data_size_c { num_data >= 1;
    num_data <= 32; data.size() == num_data; }`. Without an explicit `solve num_data
    before data;`, is the distribution of `num_data` guaranteed to be uniform over [1, 32]?
    Why or why not?**

---

## 11. Quiz — Answers & Deep Explanations

### Q1 — Why extend `uvm_sequence_item`?

`uvm_sequence_item` is a subclass of `uvm_object` that adds:

- `m_sequence_id`, `m_transaction_id` — IDs that correlate the item to the originating
  sequence and uniquely identify the transaction.
- `set_id_info()` / `get_id_info()` — for relating responses back to requests.
- `print_id_info()` — included in default print output.
- A parent-sequence pointer accessible via `get_sequencer()` / `get_parent_sequence()`.

**Why you need this:** when the driver gets an item, it must know **which sequence sent it**
so it can send responses back via `item_done(rsp)` and so analysis/debug traces are
hierarchical. If you extended `uvm_object` directly, the sequencer wouldn't have the hooks
to track this correlation, and you'd get warnings like *"item has no sequence_id"*.

**Interview-grade answer:**

> *"`uvm_sequence_item` adds the sequence/transaction ID metadata and parent-sequence hooks
> that the sequencer-driver pipeline relies on. Extending `uvm_object` directly works for
> simple data carriers like configs, but for items flowing through a sequencer, you MUST
> extend `uvm_sequence_item` so the framework can correlate the item to its sequence,
> route responses back, and produce hierarchical debug messages."*

---

### Q2 — `uvm_component_utils` on a seq_item — what breaks?

The factory will still register it under the same string name, but the class now inherits
**component semantics**:

1. **`type_id::create()` now requires a `parent` argument.** Sequences would call
   `i2c_seq_item::type_id::create("item", this)` — but `this` (the sequence) isn't a
   `uvm_component`. Compile error or runtime confusion.
2. **The class is treated as a component** by the framework. UVM phasing tries to run
   build/connect/run_phase on every component. If you accidentally created items as components,
   they'd appear in the UVM topology dump, get a `get_full_name()` path, and consume memory
   for the whole sim.
3. **Cloning breaks.** `uvm_object::clone()` returns a `uvm_object`. Component clone semantics
   are undefined for things created as components but used as transient data.

**Interview trap:** the simulator may not give you a clear error — you'll just see weird
behavior, double prints, or missing items. **This is one of the most common UVM beginner
bugs.**

**Interview-grade answer:**

> *"`uvm_component_utils` is for things that live for the whole simulation and have phases —
> drivers, monitors, scoreboards. A seq_item is a transient data object, created and destroyed
> per transaction. Using the wrong macro changes the factory creation signature to require a
> parent component, breaks transient lifecycle semantics, and produces topology dumps
> polluted with transactions. The factory may still register the class, but every downstream
> use is wrong."*

---

### Q3 — `rand` vs `randc`

- **`rand`** picks a value uniformly at random from the legal value space (subject to
  constraints) on **every** call to `randomize()`. Consecutive calls can return the same value.
- **`randc`** picks values cyclically: all legal values appear once before any repeats.
  Per object, the simulator maintains a "permutation pool" of unused values.

**Cost:** `randc` requires storing the used-set per object. For a small field (3–8 bits)
it's negligible. For larger fields, simulators forbid `randc` outright (typical limit: 8 bits).

**Performance:** `randc` has roughly 2–3× the per-call cost of `rand` because of the
bookkeeping. In a tight loop generating millions of items, this matters.

**When `randc` is the right choice:**

> *"In a hash-table coverage scenario where I'm filling a 64-entry table and want every
> entry index touched at least once with no manual tracking, `randc bit [5:0] idx` does the
> bookkeeping for me. With `rand`, I'd need extra coverpoints and manual rejection sampling."*

**Anti-pattern:** Using `randc` on a 1-bit flag. It just toggles 0/1/0/1 — completely
predictable. Either keep it `rand` for true randomness or just hardcode a deterministic
sequence.

---

### Q4 — What `uvm_object_utils` gives us

Beyond `class extends uvm_sequence_item`, the macro provides:

1. **Factory registration.** Creates a `type_id` typedef and registers the class with the
   UVM factory under the string key. This enables `type_id::create()` calls.
2. **Factory override support.** Now any code can call
   `set_type_override_by_type(i2c_seq_item::get_type(), i2c_corrupt_item::get_type())` to
   substitute a subclass everywhere.
3. **Type introspection.** `get_type_name()` and `get_object_type()` let UVM print the
   actual runtime type of an object, even when you only have a base-class handle.

**Bonus:** with the `_begin`/`_end` form, you also get auto-generated `do_copy`, `do_compare`,
`do_print`, `do_pack`, `do_unpack`, `do_record`, `convert2string` (if you add field macros
inside).

**Interview-grade answer:**

> *"`uvm_object_utils` registers the class with the UVM factory and emits the `type_id`
> machinery. Three concrete capabilities follow: first, `type_id::create()` for factory-based
> construction; second, factory overrides — I can swap a corrupt seq_item subclass into every
> sequence without editing sequence code; third, runtime type introspection via
> `get_type_name()`. Without this macro, the class is just an extends — none of the factory
> polymorphism works."*

---

### Q5 — `uvm_field_int(addr, UVM_ALL_ON)` — what it generates and why we skip it

**Generated** for each field:

1. **`do_copy`** entry — `this.addr = rhs.addr;`
2. **`do_compare`** entry — `return (this.addr == rhs.addr);` (combined with other fields).
3. **`do_print`** entry — `printer.print_field("addr", this.addr, $bits(addr), UVM_HEX);`
4. **`do_pack`** entry — `packer.pack_field_int(this.addr, $bits(addr));`
5. **`do_record`** entry — sends to waveform DB.
6. **`convert2string`** entry — adds `addr=0x42` to the output.

**Reasons to skip here:**

1. **Conditional comparison.** This seq_item should NOT compare `data[]` on a READ
   transaction (driver-side `data` is empty). Macros can't express this — manual code can.
2. **Performance.** Field-macro dispatch uses an internal `uvm_field_op` policy and walks
   a registered-field table at runtime. For high-throughput sims, this is measurable
   overhead. Manual methods compile to direct assignments — faster.
3. **Custom miscompare messages.** Manual `do_compare` can emit `uvm_error` with rich context
   ("addr mismatch in transaction id=42: expected 0x50, got 0x51"). Macros emit generic
   miscompare diagnostics that are harder to grep.
4. **Excluding monitor-set fields.** You'd need `UVM_NOCOMPARE | UVM_NOPACK` on `status`,
   `byte_ack`, `addr_ack`, etc. The flag soup gets ugly fast.

**Interview-grade answer:**

> *"The field macros are great for simple data items where every field participates in copy,
> compare, print, and pack identically. For a protocol transaction with output fields, dir-
> dependent semantics, and custom miscompare messages, the macros either can't express what
> we need or do so with so many `UVM_NO*` flags that the manual implementation is clearer.
> Plus, field macros add measurable runtime overhead via their reflection-style dispatch —
> non-trivial when a sim generates millions of items."*

---

### Q6 — Why `do_compare` skips `status`, `byte_ack` etc.

The scoreboard receives two seq_items:

- **Expected** — built by the sequence/predictor BEFORE the bus transaction runs. Contains
  the *intent*: addr, dir, data to be written. Fields like `status`, `ack_received`,
  `byte_ack` are at their constructor defaults (zero/IDLE).
- **Observed** — built by the monitor AFTER the bus transaction. Reconstructed from pin
  activity. Contains the *outcome*: same addr/dir/data (if the bus is healthy), plus
  filled-in `status`, `ack_received`, `byte_ack`.

If you compare those status fields directly, **every test fails** — expected has them zero,
observed has them populated. You'd be comparing intent vs reality on fields that exist
ONLY in reality.

**Verification principle:** **Compare only what the predictor knows.** Monitor-only fields
either go into a separate "observation report" or get checked by **scoreboard-side
assertions**, not by `do_compare`.

**Interview-grade answer:**

> *"In UVM scoreboarding, the expected item is built by a predictor with foreknowledge of
> the stimulus, and the observed item is reconstructed by the monitor from the DUT outputs.
> Only fields the predictor knows about are valid for direct comparison — anything the
> monitor adds (status, ACK timestamps, stretch_seen) is observation-only. Comparing those
> would trigger false negatives because the predictor leaves them at construction defaults.
> The right pattern is to compare the protocol intent in `do_compare` and check observation
> fields with separate scoreboard assertions or coverage points."*

---

### Q7 — Soft vs hard constraints, and this file's defaults

**Syntactic difference:**

```systemverilog
constraint hard_c  { start_cond == 1; }       // Hard — must be satisfied
constraint soft_c  { soft start_cond == 1; }  // Soft — overridable
```

**Semantic difference:**

- **Hard constraints** are absolute requirements. The solver MUST find a solution satisfying
  them. If unsatisfiable, `randomize()` returns 0.
- **Soft constraints** have lower priority. They're satisfied **only if no hard constraint
  or external `with` clause overrides them**. If a sequence says
  `randomize() with { start_cond == 0; }`, the soft default is silently dropped — no error.

**Soft constraint resolution order** (high to low priority):

1. External constraints (`randomize() with { ... }`)
2. Class-internal hard constraints
3. Class-internal soft constraints

**This file uses HARD defaults.** Consequence: if a negative test does
`item.randomize() with { inject_nack == 1; };`, you get a **constraint failure** because
`default_errors_c { inject_nack == 0; }` conflicts.

To fix that, the test must do one of:

```systemverilog
item.default_errors_c.constraint_mode(0);   // Disable the constraint, then randomize
item.randomize() with { inject_nack == 1; };
```

OR — refactor `default_errors_c` to use `soft`:

```systemverilog
constraint default_errors_c {
  soft inject_nack    == 0;
  soft inject_timeout == 0;
}
```

Now `randomize() with { inject_nack == 1; }` Just Works.

**Interview-grade answer:**

> *"Hard constraints are unconditional — the solver must satisfy them or fail. Soft
> constraints act as defaults that any external `with` clause or higher-priority constraint
> can silently override. In this file, the default constraints are hard, so a negative test
> that flips `inject_nack` would hit a constraint failure unless it first calls
> `constraint_mode(0)`. The cleaner pattern is to mark default-style constraints as `soft`,
> which lets test code override them just by passing a `with` clause — no special setup
> required. I'd refactor this as a small improvement."*

---

### Q8 — When `pre_randomize` is the only correct hook

**Scenario: Constraint depends on external state captured BEFORE randomization.**

Suppose your seq_item has a `rand int delay;` field, and you want `delay` to be larger when
the DUT's internal FIFO is near-full. The FIFO depth is a value living in a `uvm_config_db`
or a parent agent. You must read it BEFORE the solver picks `delay`, because constraints
that reference `delay` need to know the FIFO state at randomize-time.

```systemverilog
function void pre_randomize();
  uvm_config_db#(int)::get(null, "*", "fifo_level", current_fifo_level);
  if (current_fifo_level > 8)
    delay_range_c.constraint_mode(1);  // Activate "large delay" mode
  else
    delay_range_c.constraint_mode(0);
endfunction
```

**Why pre, not post:**

- `pre_randomize` runs **before** the solver picks values. You can adjust `constraint_mode`,
  set non-rand fields, or capture state that constraints reference.
- `post_randomize` runs **after** the solver. By then, `delay` is already picked — your
  decision happens too late.

**Other valid pre_randomize uses:**
- Save a "before" snapshot for rollback on error.
- Initialize non-rand fields that hard constraints reference.
- Log randomization context for debug ("about to randomize at sim time T").

**Interview-grade answer:**

> *"`pre_randomize` is the only correct hook when you need to read external state and let
> that state influence the solver — for instance, adjusting `constraint_mode` based on
> testbench context, or initializing a non-rand field that a constraint references. By the
> time `post_randomize` fires, the solver has already committed values, so anything that
> needs to feed INTO solving must go in pre. A common anti-pattern is using pre for
> bookkeeping that doesn't affect solving — that's just clutter; post would be cleaner."*

---

### Q9 — Is the `post_randomize` dead code?

**Defensive code** is the right answer.

`bit [7:0] data [$]` is a 2-state type — the solver cannot produce X or Z values for it.
`$isunknown(data[i])` will always return 0. So functionally, the `foreach` body never
executes.

**But:** the comment in the file says *"FIX: use 2-state 'bit' to prevent X/Z from
randomization"* — implying the type used to be `logic [7:0]` (4-state), where the solver
COULD pick X/Z if a constraint allowed it. The `post_randomize` was the safety net for
that case.

Now that the type is `bit`, the post_randomize is **dead code in steady state** but
**load-bearing safety code** if anyone ever reverts the type to `logic`.

**Three honest choices:**

1. **Delete it.** The type is `bit`; the check is impossible to fail. Dead code rots.
2. **Keep it with an updated comment.** "Defensive: re-sanitize if data ever becomes 4-state."
3. **Migrate to `logic` and lean on `post_randomize`** for the X/Z scrub.

**Senior answer:** *delete it*. Dead code is technical debt. If you ever change the type
back, you'll add the post_randomize back too — that's the right time to write it.

**Interview-grade answer:**

> *"It's defensive code that's currently unreachable because `data` is 2-state. The comment
> reveals it was a remediation for an earlier 4-state version where the solver could pick
> X/Z. Today, `$isunknown` on a `bit` is always 0, so the loop never executes. I'd delete
> it as dead code — keeping unreachable safety nets confuses future readers. If anyone
> reverts to `logic`, they should re-introduce the sanitization deliberately, not rely on
> dormant code surviving a refactor."*

---

### Q10 — Why transaction-level granularity, not primitive-level?

If we modeled at the **primitive level**, each seq_item would represent ONE bus action:
START, send byte, ACK/NACK, STOP. A simple write of "address + 3 bytes" would require 6 items:
START, addr_byte, data1, data2, data3, STOP.

**Pros of primitive granularity:**

- Maximum flexibility — sequences can build any unusual scenario byte-by-byte.
- Direct mapping to wire activity — monitor reports exactly what it saw.

**Cons (the big ones):**

1. **Test code becomes verbose.** Every test writes 5–10 items for a basic transaction.
   Writing 100 directed tests becomes drudgery.
2. **No transaction-level coverage.** "Coverage on burst length" requires reassembling
   primitives into bursts. Painful.
3. **Scoreboard complexity.** Comparing "expected sequence of 6 primitives" vs "observed
   sequence of 6 primitives" requires alignment logic. Comparing "expected 3-byte write
   to 0x50" vs "observed 3-byte write to 0x50" is one line.
4. **Reuse across protocols.** Other protocols (AXI, SPI, UART) are also modeled at the
   "transaction" level (read/write of N bytes). Keeping I2C consistent helps engineers
   moving between agents.

**Counter-argument:** for **fault injection at primitive granularity** (drop one byte, NACK
a specific data byte), you need a way to express that. This file's solution: keep transaction-
level granularity but add **per-byte tracking arrays** (`byte_ack [$]`) and **injection
knobs** (`inject_nack`, `inject_timeout`). Best of both worlds.

**Interview-grade answer:**

> *"Granularity should match the abstraction level the testbench reasons about. I2C tests
> typically care about 'write 3 bytes to 0x50' — not 'six primitive items in a row'.
> Transaction-level keeps test code concise, makes scoreboarding straightforward, and
> matches the per-burst coverage points DV plans usually contain. To preserve fault-
> injection at sub-transaction granularity, we add per-byte tracking arrays and injection
> flags inside the transaction. That's what this seq_item does — high-level intent with
> low-level controls embedded."*

---

### Q11 — Why deep copy matters

A shallow copy of `data [$]` copies the **handle** to the underlying queue storage. Two
seq_items now share the same memory:

```systemverilog
i2c_seq_item a, b;
a = new();
a.data = {8'h11, 8'h22, 8'h33};
b = new();
b.data = a.data;          // ← Shallow assignment (handle copy)
b.data[0] = 8'hFF;
// SystemVerilog queue semantics: 'b.data = a.data' is actually deep copy.
// BUT in some types (class handles, associative arrays) it isn't.
```

**Crucially, SV's queue assignment IS deep-copy semantics** — so `data = item.data;` in
this file is safe. **But for class handles** (e.g., a `child_obj` field inside the seq_item),
`=` is shallow — both items point to the same child. Modify one, the other changes.

**What goes wrong with shallow copy:**

1. **Scoreboard false negatives.** Expected and observed items share storage. Monitor
   writes observed `data[]` → expected `data[]` changes too → compare always succeeds even
   for buggy DUTs.
2. **Scoreboard false positives.** A sequence mutates an item after dispatching to the
   driver. The driver-side copy sees the mutation → bus activity differs from what the
   predictor recorded.
3. **Race conditions.** Two threads operate on the same shared data → undefined.

**The rule:** **Every seq_item field that holds a handle (class, dynamic array, associative
array, queue of class) MUST be deep-copied in `do_copy`**. For value types (`int`, `bit`,
fixed-size arrays), `=` is already deep.

**Interview-grade answer:**

> *"In UVM, the scoreboard holds expected and observed items in parallel, and sequences
> may keep references to items after dispatch. Any aliasing — two items sharing a backing
> store — causes silent data corruption: the monitor's writes leak into the expected item,
> or the sequence's late edits modify the in-flight transaction. Deep copy guarantees each
> item owns its data exclusively. SystemVerilog gives deep semantics to queues and dynamic
> arrays of value types automatically, but class handles inside the item — and queues of
> classes — require explicit `clone()` calls. Field macros handle this for you;
> hand-written `do_copy` must remember it."*

---

### Q12 — Solver order and `num_data` distribution

**The constraint:**

```systemverilog
constraint data_size_c {
  num_data >= 1;
  num_data <= 32;
  data.size() == num_data;
}
```

**The question:** without `solve num_data before data;`, is `num_data` uniform over [1, 32]?

**Answer: No, not guaranteed.** Without an explicit solve order, the simulator picks an
implementation-defined order. Common implementations:

- **VCS** typically picks scalar fields before array sizes when dependencies allow, giving
  approximately uniform `num_data`.
- **Questa** historically picks `data.size()` first via an internal heuristic, then
  constrains `num_data` to match. The distribution of `data.size()` depends on the queue's
  default capacity policy — often heavily biased toward small sizes.

**Result:** test runs that look uniform on one tool may show **heavy small-burst skew** on
another. This is a **non-portable randomization bias** — a classic source of "passes on VCS,
fails on Questa" pain.

**Fix:**

```systemverilog
constraint data_size_c {
  solve num_data before data;
  num_data >= 1;
  num_data <= 32;
  data.size() == num_data;
}
```

Now `num_data` is picked uniformly in [1, 32], then `data` is sized accordingly — across
all simulators.

**Verification by coverage:** add a coverpoint on `num_data` with bins for [1, 8, 16, 24, 32]
and check histogram uniformity. If you see 80% of items have `num_data == 1`, your solve
order is the bug.

**Interview-grade answer:**

> *"Without an explicit `solve...before`, SystemVerilog leaves solving order
> implementation-defined. The constraint `data.size() == num_data` creates a dependency
> chain that some tools resolve by picking `data.size()` first — and queue size defaults
> can bias the result heavily toward small sizes. The fix is one line: `solve num_data
> before data;`. I'd verify with a coverpoint that `num_data` actually hits its full range
> uniformly. This is exactly the kind of latent bias that produces 'fewer bugs found than
> expected' in long random regressions — the test ran for hours but only exercised tiny
> bursts."*

---

## 12. Key Takeaways

### Conceptual

1. **The seq_item is the testbench's atom.** Every UVM component touches it; understand it
   first, the rest follows.
2. **Extend `uvm_sequence_item`, not `uvm_object`.** You need the sequence/transaction
   correlation metadata.
3. **Use `uvm_object_utils` for items, `uvm_component_utils` for components.** Macros encode
   lifetime semantics, not just factory registration.
4. **Rand vs randc is about coverage shape, not just speed.** `randc` for uniqueness; `rand`
   for distribution flexibility.
5. **Constraint solver is a CSP, not a script.** Order matters via `solve...before`, not
   textual order.
6. **Soft constraints are overridable defaults.** Use them for sequence-friendly knobs.
7. **Manual `do_copy`/`do_compare` beats macros when you need conditional logic or custom
   miscompare reporting.** Otherwise, macros are faster to write.
8. **Compare only what the predictor knows.** Monitor-set fields go into scoreboard
   assertions, not `do_compare`.
9. **Deep copy is non-negotiable for handles.** Queues of values are deep by default; class
   handles inside items must be cloned.
10. **`pre_randomize` for solver setup, `post_randomize` for derived fields and sanitization.**
    Pick the right hook based on whether the data is available yet.

### Career-critical

- **`uvm_object_utils` vs `uvm_component_utils` is a screening question.** Get it wrong → out.
- **Soft constraints + `constraint_mode` is mid-level DV knowledge.** Demonstrating fluency
  separates you from "knows UVM enough to copy-paste".
- **Solver order + uniformity bias** is a senior topic that almost no fresher knows. Bringing
  it up unprompted in an interview is a positive signal.
- **Knowing when NOT to use field macros** shows you understand the trade-offs, not just the
  syntax.

---

## 13. Action Items

### Re-study schedule
- [ ] Re-read this entire file once a week for the next 4 weeks.
- [ ] Re-take the quiz **without looking at answers** in 3 days. Aim for 9/12 correct.
- [ ] Re-take after 1 week without notes. Aim for 11/12.

### Code fixes to propose (small, high-impact)

1. **Add solve order to `data_size_c`:**
   ```systemverilog
   constraint data_size_c {
     solve num_data before data;
     num_data inside {[1:32]};
     data.size() == num_data;
   }
   ```
   Justification: deterministic and portable `num_data` distribution.

2. **Make default constraints `soft`:**
   ```systemverilog
   constraint default_trans_c {
     soft start_cond == 1;
     soft stop_cond  == 1;
     soft rep_start  == 0;
   }
   constraint default_errors_c {
     soft inject_nack    == 0;
     soft inject_timeout == 0;
   }
   ```
   Justification: error-injection tests don't need `constraint_mode(0)` boilerplate.

3. **Delete (or update the comment on) `post_randomize`** to reflect that it's now defensive
   for a 2-state `bit` queue.

### NEW constraints to ADD (suggest these in code review)

#### Constraint A — Realistic burst-length distribution

```systemverilog
constraint burst_dist_c {
  num_data dist {
    1        := 30,   // Single-byte writes are most common
    [2:4]    := 40,   // Small bursts (e.g., register writes)
    [5:16]   := 25,   // Medium bursts (e.g., FIFO fills)
    [17:32]  := 5     // Large bursts (rare)
  };
}
```

Justification: uniform `num_data` over [1, 32] is unrealistic for real systems. Real I2C
traffic is heavily small-burst-biased. A distribution constraint gives more functional
coverage on the common case while still hitting boundaries.

#### Constraint B — Mutually exclusive error injection

```systemverilog
constraint single_error_c {
  !(inject_nack && inject_timeout);   // At most one error per transaction
}
```

Justification: simultaneous NACK + timeout is ambiguous — does the slave NACK first then
stretch, or does it stretch the SCL until timeout? Reduce ambiguity by enforcing single-
fault injection per transaction. Multi-fault tests should be opt-in via a separate sequence.

#### Constraint C — Read-vs-write data sanity

```systemverilog
constraint read_data_sanity_c {
  (dir == DIR_READ) -> (data.size() == 0);
  (dir == DIR_WRITE) -> (data.size() == num_data);
}
```

Justification: on a READ transaction, the driver doesn't drive data — the slave does.
The seq_item's `data[]` field is meaningful only for WRITE on the stimulus side. Enforcing
this prevents bogus comparisons in the scoreboard and clarifies intent.

(Or, as an alternative, rename `data` to `write_data` and add a separate `read_data` field
populated by the monitor — making the asymmetry explicit in the data model itself.)

### Stretch projects

- [ ] **Build a `i2c_corrupt_seq_item` subclass** that extends `i2c_seq_item` and adds
      constraint overrides for invalid protocol states (reserved address, no START, etc.).
      Demonstrate factory override in a directed negative test.
- [ ] **Add a `convert2string` "verbose" mode** that includes `data[]` content (truncated
      to first/last 4 bytes for long bursts).
- [ ] **Profile field-macro vs manual overhead.** Pick a heavy regression test, compare
      sim wall-clock with and without the field macros. Report the delta. This is real
      DV engineering work and great resume material.

---

## 14. Honest Self-Score Template

Fill this out NOW, after reading. Re-fill in 3 days. Re-fill in 1 week.

| Topic | Now (5/17) | +3 days | +1 week | Notes |
|---|---|---|---|---|
| `uvm_sequence_item` vs `uvm_object` |  |  |  | Metadata for sequence correlation |
| `uvm_object_utils` vs `uvm_component_utils` |  |  |  | Object = data, Component = behavior |
| Factory `type_id::create()` mechanism |  |  |  | Enables polymorphism/overrides |
| `rand` vs `randc` semantics & cost |  |  |  | Cyclic + bookkeeping cost |
| Constraint solver as CSP |  |  |  | Not top-to-bottom; uses `solve...before` |
| Soft vs hard constraints |  |  |  | Soft = overridable default |
| `constraint_mode(0)` usage |  |  |  | Per-test constraint disable |
| `uvm_field_*` macros — what they generate |  |  |  | copy/compare/print/pack/record |
| Manual `do_compare` reasons |  |  |  | Conditional, custom messages |
| Deep vs shallow copy |  |  |  | Queues of values OK; class handles NOT |
| `pre_randomize` use cases |  |  |  | Setup BEFORE solver |
| `post_randomize` use cases |  |  |  | Derived fields, distribution skew |
| `convert2string` for logs |  |  |  | One-line, grep-friendly |
| Transaction granularity rationale |  |  |  | High-level intent + low-level knobs |
| Solver order portability bug |  |  |  | `solve num_data before data;` |
| Scoreboard expected vs observed |  |  |  | Compare only predictor-known fields |

### Score legend

- 0% / blank — never heard of it
- 25% — heard of it, can't explain
- 50% — can explain but not confidently
- 75% — can explain and give one example
- 100% — can explain, give examples, AND identify common bugs/anti-patterns

### Target after 1 week

At least 75% on every row. Anything still at 50% or below → re-read the corresponding
section and re-do the quiz question. Anything still at 0% after a week → you're avoiding it,
which is the strongest signal it's important. Schedule a focused 30-minute drill on it.

---

**End of Lesson 08.**

Next file to study: `i2c_sequence.sv` — how sequences PRODUCE these seq_items, and how
`uvm_do_with` / `start_item` / `finish_item` work. The seq_item is the noun; the sequence
is the verb.
