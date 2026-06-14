> **⚠️ 2026-06-10 AUDIT UPDATE — read this box before trusting the lesson below.**
> A deep audit + fix pass changed the code this walkthrough describes. Deltas for this file:
> - The scoreboard was REWRITTEN. The old write_actual path did `match_count++` for writes without comparing a single byte — write-data checking was DEAD; a DUT corrupting every write byte passed every write-only test.
> - New design: expected (driver) and actual (monitor) streams are QUEUED and matched pairwise in order (arrival-order independent); byte-for-byte data compare in BOTH directions; addr/dir/ACK consistency checks; shadow bank built from the MONITOR stream (the wire), not driver intent.
> - `check_phase` now flags unconsumed leftovers in either queue; `allow_bus_corruption` config knob exists solely for arbitration_lost_test (intentional wire corruption).
> Full detail: [`19_audit_fixes_walkthrough.md`](./19_audit_fixes_walkthrough.md) and `docs/AUDIT_FIX_REPORT.md`.

# Lesson 12 — `i2c_scoreboard.sv` Deep Dive

**File under study:** `uvm/i2c_scoreboard.sv` (~180 lines, 6 KB)
**Concepts covered:** UVM scoreboard architecture, `uvm_analysis_imp_decl` macro, multi-port subscription, reference model patterns (predictor / golden / in-line), in-order vs out-of-order matching, end-of-test queue draining, `check_phase` vs `report_phase`, `uvm_error` vs `uvm_fatal`, deterministic comparison, factory `create` vs `new`, common silent-pass bugs.
**Date:** 2026-05-17
**Project context:** I2C UVM environment — block-level DV for 7-bit I2C slave at address `7'h50`. This file is the **judge**: the component that decides whether a test PASSES or FAILS. Every other component (driver, monitor, sequence, agent) feeds data into this one, and this one alone gives the verdict.

---

## Table of Contents

1. [Scoreboard's Role in UVM — Why This File Decides Everything](#1-scoreboards-role-in-uvm--why-this-file-decides-everything)
2. [60-Second Elevator Pitch](#2-60-second-elevator-pitch)
3. [Class Definition Walkthrough — `uvm_component_utils`, Analysis Imps](#3-class-definition-walkthrough--uvm_component_utils-analysis-imps)
4. [The `uvm_analysis_imp_decl` Macro — How Multi-Port Subscription Works](#4-the-uvm_analysis_imp_decl-macro--how-multi-port-subscription-works)
5. [Reference Model — In-Line Algorithm vs Separate Predictor](#5-reference-model--in-line-algorithm-vs-separate-predictor)
6. [Comparison Logic — Address-Based, In-Order, By-Time-Ordering](#6-comparison-logic--address-based-in-order-by-time-ordering)
7. [Mismatch Reporting — `uvm_error` vs `uvm_fatal`](#7-mismatch-reporting--uvm_error-vs-uvm_fatal)
8. [End-of-Test Check — `check_phase` and `report_phase`](#8-end-of-test-check--check_phase-and-report_phase)
9. [Queue Management — Draining, Leftovers, Silent-Pass Bugs](#9-queue-management--draining-leftovers-silent-pass-bugs)
10. [Quiz — 12 Questions](#10-quiz--12-questions)
11. [Quiz — Answers & Deep Explanations](#11-quiz--answers--deep-explanations)
12. [Key Takeaways](#12-key-takeaways)
13. [Action Items](#13-action-items)
14. [Honest Self-Score Template](#14-honest-self-score-template)

---

## 1. Scoreboard's Role in UVM — Why This File Decides Everything

### The Big Picture First

Before zooming in, anchor on **where** the scoreboard sits in the UVM testbench hierarchy:

```
                            +-----------------+
                            |      test       |
                            +-----------------+
                                    |
                            +-----------------+
                            |       env       |
                            +-----------------+
                                /  |  |  \
                +-------------+   |  |   +-------------+
                |   agent     |   |  |   | virt_seqr   |
                | (master)    |   |  |   +-------------+
                +-------------+   |  |
                  /    |    \     |  |
              seqr  driver  mon   |  |
                              \   |  |
                               \  |  |
                          analysis_port
                               \  |  |
                                \ |  |
                          +-----------------+
                          |    SCOREBOARD   |  ← THIS FILE
                          +-----------------+
                                |
                          +-----------------+
                          |    coverage     |
                          +-----------------+
```

The scoreboard sits **at the leaves of the env**, parallel to the coverage collector. It receives broadcasts from the monitor (and optionally from the predictor or sequence layer) and produces the test verdict.

### The Courtroom Analogy

Picture a UVM environment as a **courtroom**:

| Role in courtroom | UVM component | What it does |
|---|---|---|
| Prosecutor | Sequence + Driver | Generates stimulus, drives DUT inputs |
| Witnesses | Monitors | Observe what happened on the bus (without interfering) |
| Court reporter | Coverage collector | Records what was observed for later statistics |
| **Judge** | **Scoreboard** | **Decides: did the DUT behave correctly?** |

Every other component is either generating stimulus or passively observing. **Only the scoreboard makes the binary decision: PASS or FAIL.** If the scoreboard is missing, broken, or silently swallows errors, your test reports green — and bugs ship to silicon. The scoreboard is the highest-value component in a UVM environment, and consequently the place where the most catastrophic verification bugs hide.

### Two Information Streams

A scoreboard always has at least two inputs:

```
                +-----------------+
   EXPECTED --->|                 |
   stream       |   SCOREBOARD    |---> PASS / FAIL
                |   (compare)     |
   ACTUAL  --->|                 |
   stream       +-----------------+
```

1. **Expected stream** — what the DUT *should* do, derived from the stimulus.
2. **Actual stream** — what the DUT *actually* did, captured by the monitor.

The two streams must converge inside the scoreboard. If they diverge → bug.

### Where Does "Expected" Come From?

This is the deepest question in DV. Three common patterns:

| Pattern | Description | When to use |
|---|---|---|
| **Predictor / golden model** | A separate class (often `uvm_subscriber`) that consumes input sequences and produces expected outputs | Complex DUTs (CPUs, NoC, AXI fabrics) |
| **In-line algorithm** | Expected behavior is computed inline inside the scoreboard's `write_*` callback | Simple stateful DUTs (FIFOs, I2C slaves, simple registers) |
| **Reference C/C++ model** | DPI-linked external golden model in C | Algorithmic blocks (DSP, crypto, codecs) |

Our I2C scoreboard uses the **in-line algorithm** pattern. The `write_expected()` and `write_actual()` callbacks both contain the prediction + comparison logic. For an I2C slave with a tiny 8-byte register bank, this is the right call — a separate predictor class would be over-engineering.

### Why the Scoreboard is "The Component Where Bugs Are Caught"

A bug discovered in the **DUT** is a verification win. A bug discovered in the **scoreboard** is a verification disaster — because every test that ran through that scoreboard up to that moment gave you false confidence. This is why senior engineers spend disproportionate time reviewing scoreboard code.

> **Interview-grade answer:**
> *"The scoreboard is the one component that decides pass or fail in a UVM environment. Every other component is either generating stimulus or passively observing. A bug in the driver causes a test failure; a bug in the scoreboard causes silent test PASS while the DUT misbehaves. That's why I treat scoreboard code with the same rigor as the DUT itself."*

### Three Properties Every Scoreboard MUST Have

Memorize this list. Drop it into interviews verbatim.

1. **Passive.** Never drives signals onto the bus. Only observes via analysis ports.
2. **Deterministic.** Same input streams → same verdict. No randomness, no race conditions.
3. **Complete.** End-of-test checks include (a) zero errors, (b) at least one actual transaction received, (c) expected count matches actual count.

A scoreboard missing ANY of these three properties is broken. The bar is that simple, and that high.

### The Scoreboard Failure Modes Hall of Shame

Real bugs from real teams:

| Failure mode | Symptom | Consequence |
|---|---|---|
| Missing `actual_count > 0` check | Test passes with disconnected monitor | Months of false-green regression |
| `uvm_fatal` on first mismatch | Only one bug found per run | Slow bug discovery rate |
| Non-`automatic` task with shared state | Intermittent pass/fail on same seed | Loss of reproducibility |
| Scoreboard drives signals | X-contention on bus | Real DUT bug masked |
| No factory registration | Cannot override in tests | Brittle env code |
| Drives 100% match without comparing | Phantom green tests | Silicon escapes |

Every one of these has shipped to silicon in some company's history. Don't let your name attach to the next one.

---

## 2. 60-Second Elevator Pitch

When an interviewer asks: *"Tell me about your scoreboard,"* answer like this:

> *"My I2C scoreboard is a `uvm_scoreboard`-derived class with two `analysis_imp` ports — one for expected transactions from the sequence/predictor side, one for actual transactions from the monitor. It uses an in-line reference model: an 8-entry shadow register bank that mirrors the DUT's internal state. On every expected write to address 0x50, it updates the shadow bank starting from index 0 (the DUT resets its `reg_ptr` to 0 on each address match). On every actual read, it compares the observed data against the shadow bank, indexed by a fresh read pointer. Address ACK/NACK is also checked: only address 0x50 should be ACKed; any other address must be NACKed. End-of-test sanity checks live in `report_phase` — if actual count is zero, or actual != expected, or any error occurred, the test fails with `uvm_error`. The whole component is passive — it never drives anything onto the bus."*

That's roughly 30 seconds spoken. Memorize the **shape**: ports, reference model type, what it checks, end-of-test policy.

### Alternate Versions for Different Audiences

For a **hardware design engineer** interviewer (less UVM, more DUT-focused):

> *"The scoreboard tracks an 8-byte shadow register bank that mirrors the DUT's internal state. When the master sequence issues a write, the scoreboard predicts the new register contents. When a read fires, the scoreboard compares the observed bytes against the shadow. It also verifies that only the configured slave address gets ACKed; all other addresses must NACK. At end-of-test it confirms transaction counts match and no errors fired."*

For a **lead / staff** interviewer (architecture-focused):

> *"I used an in-line state-based reference model rather than a separate predictor class because the DUT is small — an 8-byte register file with a wrapping pointer. The trade-off: simpler code but tighter coupling between expected-stream ordering and the scoreboard's correctness. For a more complex protocol, I'd refactor to a separate `uvm_subscriber` predictor with its own analysis port, then have the scoreboard pure-compare two transaction streams. The current implementation handles the I2C complexity envelope correctly."*

Pick the version that matches the room.

---

## 3. Class Definition Walkthrough — `uvm_component_utils`, Analysis Imps

### Lines 9–13 — Include Guard and Imp Declarations

```systemverilog
`ifndef I2C_SCOREBOARD_SV
`define I2C_SCOREBOARD_SV

`uvm_analysis_imp_decl(_expected)
`uvm_analysis_imp_decl(_actual)
```

Two things are happening **outside** the class:

1. **Include guard** — standard C-style protection against double-`` `include``. Covered in detail in Lesson 01.
2. **`uvm_analysis_imp_decl(_expected)`** and **`uvm_analysis_imp_decl(_actual)`** — these macros are how UVM solves "I need to subscribe to TWO different analysis ports inside ONE class."

We'll dissect the macro mechanics in Section 4. For now: these two lines manufacture two new parameterized types: `uvm_analysis_imp_expected` and `uvm_analysis_imp_actual`. Each routes `write()` calls to a differently-named callback (`write_expected()` and `write_actual()`).

> **Interview trap:** The macros must be at **file scope**, not inside the class. Putting them inside the class is a compile error. Putting them inside the class and then declaring the imps inside too is a junior mistake.

### Line 15 — Inheritance

```systemverilog
class i2c_scoreboard extends uvm_scoreboard;
```

**Why inherit from `uvm_scoreboard`, not `uvm_component`?**

Functionally, `uvm_scoreboard` is a thin alias of `uvm_component`. It adds nothing behaviorally. But it serves **two important purposes**:

1. **Self-documentation.** When another engineer reads `class foo extends uvm_scoreboard`, they instantly know this class is a comparison/checking component.
2. **Phasing semantics.** `uvm_scoreboard` is conventionally treated as a passive component — no `run_phase` activity, only callbacks. Tools and reviewers expect that.

> **Interview-grade answer:**
> *"`uvm_scoreboard` extends `uvm_component` and adds no methods, but it documents intent. A code reviewer immediately knows the class is a checker and expects it to be passive. It's similar to how `uvm_driver` and `uvm_monitor` are also thin wrappers — UVM uses them to communicate role through type."*

### Line 17 — Factory Registration

```systemverilog
`uvm_component_utils(i2c_scoreboard)
```

This macro does **three** things:
1. Registers the class with the UVM factory.
2. Implements `get_type_name()` so log messages show the class name.
3. Implements `create()` so the test/env can use `i2c_scoreboard::type_id::create("sb", this)` instead of `new()`.

**Why factory create vs new?** Covered in detail in Q12 of the quiz. Short version: factory creation allows **type override** — a test can substitute `i2c_scoreboard_v2` everywhere `i2c_scoreboard` was created, without modifying the env code. This is the entire selling point of UVM factory.

### Lines 19–20 — The Analysis Imp Ports

```systemverilog
uvm_analysis_imp_expected #(i2c_seq_item, i2c_scoreboard) expected_export;
uvm_analysis_imp_actual   #(i2c_seq_item, i2c_scoreboard) actual_export;
```

Two parameterized handles:
- **Type parameter 1** — `i2c_seq_item` — the transaction type that will be passed to `write()`.
- **Type parameter 2** — `i2c_scoreboard` — *who owns this imp*. UVM needs to know which class's callback to invoke.

> **Interview trap (very common):** Why are these called `expected_export` and `actual_export` if they're `imp` types?
>
> *"Naming is convention, not enforced by UVM. Some teams use `_imp` suffix, others use `_export`. The actual type is `uvm_analysis_imp_*` — an imp, not an export. The name is just a string. In my code I'd recommend `_imp` for consistency, but in this file the previous engineer chose `_export`. The distinction between `analysis_imp` and `analysis_export` is structural — see Q2."*

### Lines 22–28 — State Variables

```systemverilog
logic [7:0] ref_reg_bank [0:7];   // shadow copy of DUT register bank
int         shadow_ptr;            // mirrors DUT's reg_ptr

int expected_count;
int actual_count;
int error_count;
int match_count;
```

Two categories:
- **Reference model state** (`ref_reg_bank`, `shadow_ptr`) — mirrors the DUT's internal storage. This IS the reference model.
- **Bookkeeping** (`expected_count`, `actual_count`, `error_count`, `match_count`) — used at end of test for the verdict.

Note: there are **no transaction queues** in this scoreboard. This is unusual and worth noting. Most scoreboards have `i2c_seq_item expected_q[$]` and a matching actual queue. This one uses an alternative pattern: the reference model is **state-based**, not queue-based. Implications are covered in Section 6.

### Lines 30–32 — Constructor

```systemverilog
function new(string name = "i2c_scoreboard", uvm_component parent = null);
  super.new(name, parent);
endfunction
```

Standard UVM constructor — name and parent. Nothing else. State initialization happens in `build_phase` (next).

> **Interview trap:** Why initialize counters in `build_phase` and not in `new()`?
>
> *"`build_phase` is where UVM expects component construction to complete — it runs AFTER `new()` but BEFORE simulation starts. Initializing state in `build_phase` keeps `new()` minimal and avoids surprising behavior when subclasses extend the constructor. It's also where the analysis imp handles MUST be created since they need `this` as parent."*

### Lines 34–45 — `build_phase`

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  expected_export = new("expected_export", this);
  actual_export   = new("actual_export",   this);
  for (int i = 0; i < 8; i++)
    ref_reg_bank[i] = 8'h00;
  shadow_ptr     = 0;
  expected_count = 0;
  actual_count   = 0;
  error_count    = 0;
  match_count    = 0;
endfunction
```

Three things:
1. **`super.build_phase(phase)`** — call the parent. Always. Missing this can break factory overrides and config_db lookups in some scenarios.
2. **Imp construction** — `new()` is correct here, NOT `create()`. The analysis imps are *part* of this scoreboard's identity, not factory-overridable types.
3. **State reset** — counters and reference model zeroed.

Why initialize `ref_reg_bank` to all zeros? Because the DUT's reg bank also resets to zero. The shadow model must match the DUT's reset state.

> **Critical bug pattern to watch for:** if the DUT initializes its registers to some non-zero pattern (say `0xFF`) after reset, but the scoreboard initializes the shadow to `0x00`, the first read transaction will produce a spurious mismatch. **Always cross-check the DUT's reset behavior against the reference model's reset state.**

### A Note on `build_phase` Ordering

UVM phases run **top-down** for `build_phase`. That means:

```
test.build_phase
  └── env.build_phase
        ├── master_agent.build_phase
        │     ├── sequencer.build_phase
        │     ├── driver.build_phase
        │     └── monitor.build_phase
        ├── scoreboard.build_phase    ← runs AFTER env.build_phase begins
        │                               but BEFORE env.connect_phase
        └── coverage.build_phase
```

So when scoreboard's `build_phase` runs, the env hasn't finished building yet. **Critical implication:** do NOT try to access `env.monitor.something` from inside scoreboard's `build_phase` — those handles may not exist yet. Save such cross-component lookups for `connect_phase` or `end_of_elaboration_phase`.

### `super.build_phase` — When Skipping is a Trap

You see this everywhere:

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);   // ← Always call super
  // ... your code
endfunction
```

What does `uvm_scoreboard::build_phase` actually do? Almost nothing — it inherits from `uvm_component::build_phase`, which itself does almost nothing for non-test classes. But:

- For `uvm_test`-derived classes, `super.build_phase` reads from the `uvm_config_db` for component overrides. Skipping it breaks config_db pulls.
- For factory overrides, certain bookkeeping runs in the base. Skipping it can silently disable overrides.
- Future UVM versions may add behavior. Always calling super future-proofs your code.

**Rule:** Always call `super.<phase>(phase)` at the top of every phase you override. Cost: zero. Benefit: forward compatibility and override safety.

---

## 4. The `uvm_analysis_imp_decl` Macro — How Multi-Port Subscription Works

This is the **most important UVM mechanic** in this entire file. Get this wrong and you cannot subscribe to two analysis ports in one class.

### The Problem Being Solved

A normal `uvm_analysis_imp` requires the parent class to implement a method called **exactly `write()`**:

```systemverilog
class my_subscriber extends uvm_component;
  uvm_analysis_imp #(my_txn, my_subscriber) ap_imp;
  virtual function void write(my_txn t);   // ← Must be named "write"
    // ...
  endfunction
endclass
```

But what if I want to subscribe to **two** different analysis ports from **one** class? I'd need two methods named `write()`, which is impossible — SystemVerilog forbids method overloading by parameter type.

### The Macro Solution

`` `uvm_analysis_imp_decl(_expected)`` generates a new class type `uvm_analysis_imp_expected` whose `write()` callback is renamed to `write_expected()`. Same for `_actual`. Now we can have two imps in one class, each forwarding to a uniquely-named callback:

```systemverilog
uvm_analysis_imp_expected #(i2c_seq_item, i2c_scoreboard) expected_export;
uvm_analysis_imp_actual   #(i2c_seq_item, i2c_scoreboard) actual_export;

virtual function void write_expected(i2c_seq_item item);   // ← Distinct names
  // ...
endfunction

virtual function void write_actual(i2c_seq_item item);     // ← No conflict
  // ...
endfunction
```

### What the Macro Actually Expands To

Conceptually, `` `uvm_analysis_imp_decl(_expected)`` expands to something like:

```systemverilog
class uvm_analysis_imp_expected #(type T = int, type IMP = int)
  extends uvm_port_base #(uvm_tlm_if_base #(T, T));

  IMP m_imp;

  function new(string name, IMP imp);
    super.new(name, UVM_IMPLEMENTATION, 1, 1);
    m_imp = imp;
  endfunction

  virtual function void write(input T t);
    m_imp.write_expected(t);   // ← The suffix-prepended callback name
  endfunction
endclass
```

The key trick: the macro's argument **`_expected`** becomes both (a) part of the new type name `uvm_analysis_imp_expected` and (b) the suffix on the forwarded callback `write_expected`.

> **Interview-grade answer:**
> *"`uvm_analysis_imp_decl` is a SystemVerilog macro that creates a new analysis_imp type whose `write()` method forwards to a uniquely-named callback. It solves the problem of subscribing to multiple analysis ports in a single component — without it, you can only have one analysis imp per class because all of them would need a method literally named `write()`. The argument to the macro becomes both the type-name suffix and the callback-name suffix. So `uvm_analysis_imp_decl(_actual)` produces `uvm_analysis_imp_actual` whose write forwards to `write_actual`."*

### `analysis_imp` vs `analysis_export` — The Real Distinction

This is the #1 confused topic for fresh UVM engineers. Here's the truth:

| Port type | Purpose | Where it lives | Has impl? |
|---|---|---|---|
| **`uvm_analysis_port`** | Source of transactions; producer side | Monitor, predictor | No (port broadcasts) |
| **`uvm_analysis_imp`** | Endpoint with built-in `write()` impl | Scoreboard, subscriber | YES |
| **`uvm_analysis_export`** | Passthrough — forwards to a downstream imp | Hierarchical envs (env → agent → scoreboard) | No (forwards) |

In our scoreboard, the handle is **`uvm_analysis_imp_expected`** (imp), but we named the variable `expected_export`. The name is misleading. It's still an imp — the actual `write()` is implemented right inside the scoreboard class.

You would use a real `uvm_analysis_export` if, for instance, the scoreboard were buried inside a sub-environment, and the parent environment wanted to expose a port that internally forwards to the scoreboard's imp. We don't need that complexity here.

### Visual: TLM Connection Topology

```
Producer side                            Consumer side
============                             ==============

  +-----------+                            +-----------+
  | monitor   |                            | scoreboard|
  |           |    .connect()              |           |
  | ap -------+--------------------------->+-> imp     |
  +-----------+                            +-----------+

This is the SIMPLE case — direct port-to-imp.


  +-----------+    +------------+    +-----------+
  | monitor   |    | sub_env    |    | scoreboard|
  | ap -------+--->| ap_export -+--->+-> imp     |
  +-----------+    +------------+    +-----------+

This is the HIERARCHICAL case — export forwards through layers.
```

In our scoreboard, we're in the simple case. `monitor.ap.connect(scoreboard.actual_export)` — but where actual_export is an imp despite the name.

### The Macro's Hidden Costs

Three subtle costs of `uvm_analysis_imp_decl` to know about:

1. **Compile-time only.** The macro expands during preprocessing. If you make a typo (`uvm_analysis_imp_decl(_actaul)` instead of `_actual`), you'll get unrelated errors elsewhere where `actual_export` is used — frustrating to debug.

2. **Naming pollution.** Each macro invocation creates a new global class type. Don't go overboard — five or six per project is reasonable; thirty is a code smell.

3. **Documentation overhead.** Other engineers reading your code need to find the macro to understand what `write_expected()` is called by. Always put the macros directly above the class that uses them.

### Alternatives to the Macro

What if you don't want to use `uvm_analysis_imp_decl`? Three alternatives:

**Alternative 1 — `uvm_subscriber`-based aggregator classes:**

Create a small subscriber per stream that holds a back-pointer to the scoreboard:

```systemverilog
class expected_subscriber extends uvm_subscriber#(i2c_seq_item);
  i2c_scoreboard sb;
  function void write(i2c_seq_item t);
    sb.process_expected(t);
  endfunction
endclass
```

**Alternative 2 — TLM FIFO + run_phase polling:**

```systemverilog
uvm_tlm_analysis_fifo #(i2c_seq_item) expected_fifo;
task run_phase(uvm_phase phase);
  forever begin
    i2c_seq_item t;
    expected_fifo.get(t);
    process_expected(t);
  end
endtask
```

**Alternative 3 — Combined transaction type:**

If both expected and actual share a common parent type, one analysis_imp with a discriminator field works.

**But:** the `uvm_analysis_imp_decl` macro is the standard, idiomatic, fastest approach. Use alternatives only when there's a clear architectural reason.

---

## 5. Reference Model — In-Line Algorithm vs Separate Predictor

### What This Scoreboard's Reference Model Looks Like

The reference model is **two state variables and one update rule**:

```systemverilog
logic [7:0] ref_reg_bank [0:7];   // mirrors DUT's reg_bank
int         shadow_ptr;            // mirrors DUT's reg_ptr
```

The update rule lives inside `write_expected()`:

```systemverilog
if (item.dir == DIR_WRITE && item.addr == 7'h50) begin
  shadow_ptr = 0;  // Reset: DUT does reg_ptr <= 0 in SLV_ACK
  foreach (item.data[i]) begin
    ref_reg_bank[shadow_ptr % 8] = item.data[i];
    shadow_ptr++;
  end
end
```

**What this is saying:**
- On every expected WRITE transaction to slave 0x50:
  - Reset shadow_ptr to 0 (mirrors DUT behavior on `SLV_ACK` state)
  - For each data byte, store it at `ref_reg_bank[shadow_ptr % 8]`, then increment.
- On all other transactions (READs, writes to other addresses): the reference model does NOT mutate. The shadow bank persists.

This is a **state-based** reference model: the reference state evolves as expected transactions arrive. The model isn't a separate predictor class; it's just three lines of logic inside the callback.

### Why the `% 8` Modulo?

The DUT's `reg_ptr` is a 3-bit counter that wraps. If the master writes 10 bytes, the DUT writes bytes 0–7, then **bytes 8 and 9 wrap back to register addresses 0 and 1**. The `% 8` keeps the shadow consistent with this wrap behavior. Miss this detail and your scoreboard will assert a spurious mismatch on the 9th byte of any long write.

> **This is exactly the kind of bug the comment in the file is warning you about.** The original author had to discover this through debugging — note the `// FIX:` comments at lines 53–57, 119. Senior engineers leave these breadcrumbs deliberately.

### Three Reference Model Patterns You Should Know

#### Pattern 1 — In-Line Algorithm (this file)

```
Expected stream → scoreboard.write_expected() → updates state inline
Actual stream   → scoreboard.write_actual()   → compares against state
```

**Use when:** DUT is small, stateful, and the comparison logic is straightforward.

**Pro:** Single file, easy to read, no extra connections.
**Con:** Doesn't scale. If you add three more checks, this callback becomes unreadable.

#### Pattern 2 — Separate Predictor Class

```
                                +-------------+
Expected stream → predictor →   |  scoreboard |   (only compares)
Actual stream   → ----------→   +-------------+
```

The predictor consumes input transactions and emits expected outputs to its own analysis port. The scoreboard merely receives both streams and compares.

**Use when:** Prediction logic is complex (e.g., AXI fabric routing, CPU instruction emulation).

**Pro:** Separation of concerns. Predictor is unit-testable independently.
**Con:** More plumbing, more files, harder to debug data flow.

#### Pattern 3 — DPI-Linked C/C++ Reference

```
Expected stream → DPI call to C model → returns expected output
Actual stream   → scoreboard          → compares
```

**Use when:** A reference implementation already exists in C (DSP filters, crypto, ML kernels).

**Pro:** Reuses existing high-fidelity model.
**Con:** Build complexity, DPI debugging, data marshalling overhead.

### Which Pattern is "Right" for I2C?

For this DUT (8-register I2C slave), **pattern 1 is correct**. The prediction is three lines of logic. Adding a separate predictor class would be over-engineering. For AXI XBar or NoC verification, pattern 2 becomes necessary.

> **Interview-grade answer:**
> *"I chose an in-line reference model because the DUT is a stateful but very small block — an 8-byte register file with a wrapping pointer. The predictor logic is three lines, so factoring it into a separate class would add ceremony without insight. If the DUT had complex routing or transformation logic, I'd use a separate `uvm_subscriber`-based predictor that emits expected transactions on its own analysis port, which the scoreboard then compares against the actual stream."*

### Reference Model Failure Modes

Reference models, like DUTs, can have bugs. Watch for:

1. **Reset-state mismatch** (already mentioned) — shadow doesn't match DUT power-up state.

2. **Pointer skew.** Our DUT resets `reg_ptr` on `SLV_ACK` (every new address match). The shadow must mirror this exactly. The comment at line 53–57 of the source file documents that the previous engineer caught this bug:
   ```
   // FIX: Do NOT reset shadow_ptr to 0 — it persists across transactions
   //      just like the DUT's reg_ptr auto-increments continuously.
   //      The DUT resets reg_ptr to 0 in SLV_ACK when address matches,
   //      so we must reset here too on EACH new transaction to addr 0x50.
   ```
   Read this and feel the weight — that comment was earned through hours of debug.

3. **Address-decoding asymmetry.** If the DUT checks `addr == 7'h50` but the scoreboard checks `addr == 8'h50`, the bit-widths cause silent truncation/extension and the comparison always matches (or never matches). Width hygiene matters.

4. **Wrap-around edge cases.** If the shadow uses `int` but the DUT uses 3 bits, a write of 9 bytes will see scoreboard at index 9 while DUT is at index 1 — only because the `% 8` modulo was missing.

5. **Read-while-write race.** If the DUT supports a write that updates a register while a read is in progress on the same register, the scoreboard's timing must match. (Our DUT doesn't have this, but AXI fabrics do.)

> **Interview trap — "Have you ever had a bug in your reference model?"**
>
> Don't lie. Say: *"Yes — early on, I had the shadow pointer not resetting on each new address transaction. The DUT resets its internal pointer on every `SLV_ACK`, but my shadow was monotonically increasing. The bug manifested as a phantom mismatch on the second transaction of every test. I fixed it by reading the DUT FSM carefully and aligning the shadow's pointer semantics. The fix is captured in inline comments so the next engineer doesn't repeat the mistake."*
>
> This answer demonstrates honest debug experience — far more valuable than claiming perfection.

### When to Promote to a Separate Predictor

Signs your in-line model is outgrowing its container:

- `write_expected()` exceeds 50 lines.
- More than three distinct DUT behaviors must be predicted (different opcodes, modes, etc.).
- The model has internal state that affects multiple checks.
- You want to unit-test the predictor independently.
- Multiple scoreboards in the same env need the same prediction.

When two or more signs appear, refactor.

---

## 6. Comparison Logic — Address-Based, In-Order, By-Time-Ordering

### What `write_actual()` Does

```systemverilog
virtual function void write_actual(i2c_seq_item item);
  actual_count++;
  check_address_ack(item);
  check_data_integrity(item);
endfunction
```

Two distinct checks: address ACK behavior and data integrity. Let's dissect each.

### Check 1 — Address ACK / NACK Verification

```systemverilog
virtual function void check_address_ack(i2c_seq_item item);
  bit expected_ack = (item.addr == 7'h50) ? 1'b1 : 1'b0;
  if (item.addr_ack !== expected_ack) begin
    `uvm_error(...)
    error_count++;
  end else begin
    match_count++;
  end
endfunction
```

**What this is verifying:** I2C protocol semantics demand:
- If the address byte's 7-bit field matches a slave's configured address → slave drives ACK (`SDA = 0` on the 9th clock).
- Otherwise → slave releases SDA, the master sees a NACK (`SDA = 1`).

Our DUT is configured for `7'h50`. So the scoreboard says: only `addr == 0x50` should produce ACK; everything else MUST produce NACK. The `!==` (case-equality) is used instead of `!=` to catch X/Z values explicitly — important if the monitor returns 1'bx due to a sampling error.

> **Interview trap — why `!==` and not `!=`?**
>
> *"`!=` returns X when either operand is X. So `if (X != 1)` evaluates to X, which is falsy — meaning a corrupted signal could silently fail to trigger the check. `!==` is the 4-state strict inequality: it returns 1 if the values differ in any of 0/1/X/Z. For scoreboard comparisons that must catch X-propagation, `!==` is the safe choice."*

### Check 2 — Data Integrity (Reads vs Writes)

```systemverilog
virtual function void check_data_integrity(i2c_seq_item item);
  if (item.addr != 7'h50) begin
    if (item.num_data > 0 && item.addr_ack) begin
      `uvm_error("DATA from NACK'd address ... — should have no data")
      error_count++;
    end
    return;
  end

  if (!item.addr_ack) return;

  foreach (item.data[i]) begin
    if ($isunknown(item.data[i])) begin
      `uvm_error("DATA byte = X/Z ...")
      error_count++;
      return;
    end
  end

  if (item.dir == DIR_WRITE) begin
    match_count++;
  end else if (item.dir == DIR_READ) begin
    int rd_ptr = 0;
    foreach (item.data[i]) begin
      logic [7:0] expected_val = ref_reg_bank[rd_ptr % 8];
      if (item.data[i] !== expected_val) begin
        `uvm_error("READ MISMATCH ...")
        error_count++;
      end else begin
        match_count++;
      end
      rd_ptr++;
    end
  end
endfunction
```

Walk through the **decision tree**:

1. **Non-target address?** Should never have data bytes. If `num_data > 0 && addr_ack`, that's a protocol violation. Note: `addr_ack` shouldn't even be 1 for a non-target address — so this is a double-check.
2. **Target address but NACKed?** No data to check. Return silently.
3. **Any X/Z in the data?** Fatal-grade error. Return immediately.
4. **WRITE direction?** We already updated the shadow bank in `write_expected()`. Here we just count a match (the bytes themselves were verified at the protocol level by the monitor).
5. **READ direction?** Compare each byte against `ref_reg_bank[rd_ptr % 8]`. Each mismatch is an error.

### In-Order vs Out-of-Order Matching — Why I2C is Easy

For I2C, **transactions are strictly in-order on a single bus**. The master issues one transaction at a time, and the slave responds. There is no possibility of transaction reordering. So our scoreboard does **simple in-order matching**.

Contrast with AXI:
- AXI allows **out-of-order completions** if the slave supports it (`AxID` based reordering).
- An AXI scoreboard must match responses by `RID`/`BID`, not by arrival order.
- This typically requires per-ID queues: `axi_resp_q[ID][$]`.

For your AXI XBar TB project, the scoreboard architecture is fundamentally different from this I2C scoreboard. **Don't reuse this pattern blindly across protocols.**

> **Interview trap — "How would you modify this scoreboard for an out-of-order protocol like AXI?"**
>
> *"For AXI, transactions can complete out of order based on their ID field. The scoreboard would maintain a hash or queue indexed by transaction ID: `expected_q[ID][$]`. On a response arrival, I'd pop from `expected_q[response.id]` and compare. For same-ID transactions, ordering is preserved per AXI spec, so per-ID queues give in-order semantics within an ID. I2C has no such requirement — it's a single-master, single-slave-at-a-time bus, so a state-based model without queues works fine."*

### What "By-Time-Ordering" Means

If you DID use queues, the comparison would happen by time order: pop the oldest expected, pop the oldest actual, compare. Mismatch → error. Missing → end-of-test error.

Our scoreboard doesn't use queues — instead, comparison is **immediate on arrival**. The reference state is queried at the moment an actual transaction arrives. This eliminates the need for queue management but introduces a constraint: **the expected stream MUST arrive before the actual stream**. If a write to register 5 arrives on the actual port before the expected port has updated the shadow, a subsequent read of register 5 will compare against stale data.

In our environment, this ordering is guaranteed because the master sequence publishes the expected transaction *before* the driver starts driving the bus. If you reversed that ordering, the scoreboard would silently produce wrong answers. **This is a brittle assumption worth documenting.**

### Address ACK Check — A Closer Look

Re-read this snippet carefully:

```systemverilog
bit expected_ack = (item.addr == 7'h50) ? 1'b1 : 1'b0;
if (item.addr_ack !== expected_ack) begin
  `uvm_error(...)
```

Three subtle points:

1. **Hardcoded slave address.** `7'h50` is repeated in multiple places. If the DUT is reconfigured to a different address, you must update the scoreboard too. **Better practice:** pull this from `cfg.slave_addr` or import from `i2c_pkg`. The hardcoded value is a maintenance hazard.

2. **No support for multiple slave addresses.** A real bus can have multiple slaves at different addresses. This scoreboard assumes one DUT at `0x50`. For a multi-slave test, the check becomes `expected_ack = (item.addr inside cfg.valid_addrs)`.

3. **No general-call address handling.** The I2C spec defines `7'h00` as a "general call" address that all slaves should ACK. Our scoreboard treats it as a NACK. If general-call support is added to the DUT, this check breaks.

> **Interview opportunity:** When asked "what would you improve in this scoreboard?", mention these three points. Demonstrates protocol depth.

### Data Integrity Check — The X-Propagation Defense

```systemverilog
foreach (item.data[i]) begin
  if ($isunknown(item.data[i])) begin
    `uvm_error("DATA byte[%0d] = X/Z ...")
    error_count++;
    return;
  end
end
```

`$isunknown()` returns 1 if **any bit** of its argument is X or Z. This is your X-propagation tripwire. Without this check, a value of `8'hX` would compare-equal to nothing and silently fail (or worse, compare-equal to itself if you used `==` instead of `===`).

**Common cause of X propagation:**
- Reset deasserted while a register was mid-update.
- Tri-state bus contention not resolved cleanly.
- Driver releasing SDA before sampling completes.
- Uninitialized RAM cell being read before being written.

A scoreboard that doesn't `$isunknown()`-check data bytes is leaking X-propagation bugs into silicon. **Always include this check.**

> **Interview trap — "Why use `$isunknown` instead of just comparing with `===`?"**
>
> *"`===` would catch X-comparison failures only when the expected value is known. If both expected and actual happen to be X — for example, the scoreboard hasn't yet predicted a value and the DUT also returns X — they'd compare equal and pass silently. `$isunknown` explicitly fails on any X/Z, which is what we want: X is never a valid DUT output in normal operation."*

### A Catalog of Real I2C Scoreboard Mismatches

From the 15 bugs caught on this project, the scoreboard surfaced these top patterns:

| Bug type | Caught by | Severity |
|---|---|---|
| Wrong byte returned on read | `READ MISMATCH` in `check_data_integrity` | uvm_error |
| ACK on wrong address | `ADDR_ACK MISMATCH` in `check_address_ack` | uvm_error |
| Missing transaction | `count != actual_count` in `report_phase` | uvm_error |
| X on data bus mid-transaction | `$isunknown` check | uvm_error |
| Pointer not resetting on new address | Shadow pointer divergence → READ MISMATCH | uvm_error |
| Wrap-around off-by-one | First byte after wrap miscompares | uvm_error |

Memorize at least two of these for the "what bugs did you find?" interview question.

---

## 7. Mismatch Reporting — `uvm_error` vs `uvm_fatal`

### The Severity Ladder

UVM provides four reporting severities:

| Macro | Behavior | When to use |
|---|---|---|
| `uvm_info` | Logged at the requested verbosity | Diagnostic / progress messages |
| `uvm_warning` | Logged; non-fatal | Recoverable anomaly worth noting |
| `uvm_error` | Logged; increments error count; test FAILS at end | Comparison mismatch, protocol violation |
| `uvm_fatal` | Logged; **immediately calls `$finish`** | Unrecoverable: corrupt internal state, infinite loop |

### What This Scoreboard Uses

Look at every reporting call in the file — they all use `uvm_error` or `uvm_info`. Never `uvm_fatal`. Why?

**Because a single mismatch is not an unrecoverable condition.** We want to:
1. Log the mismatch.
2. Increment `error_count`.
3. **Keep running** so we can catch more bugs in the same simulation.

Killing the simulation on the first mismatch (which `uvm_fatal` would do) is **counterproductive** in a regression. You want one simulation to surface as many failures as possible, then you fix them all before the next run.

### When Would `uvm_fatal` Be Justified?

Three legitimate cases:
1. **Configuration error** — e.g., `if (cfg == null) uvm_fatal(...)`. Test cannot proceed.
2. **Hung state machine** — e.g., a watchdog timer fires and you detect the DUT has stopped responding entirely. Continuing is meaningless.
3. **Corrupt scoreboard state** — e.g., reference model invariant violated (`assert(shadow_ptr < 256)`). Continuing would produce garbage comparisons.

For a comparison mismatch? **Always `uvm_error`.** Make the test fail at end, not crash it mid-stream.

> **Interview-grade answer:**
> *"I use `uvm_error` for any DUT misbehavior I detect — mismatch, NACK on the wrong cycle, unexpected data. Each error increments a counter and the test fails at end-of-test. I reserve `uvm_fatal` for unrecoverable conditions — a null configuration, a hung DUT, or corrupted scoreboard state. The principle is: one simulation should expose as many bugs as possible. Killing simulation on first error converts a productive regression into a one-bug-at-a-time grind."*

### A Common Junior Mistake

```systemverilog
// JUNIOR — overly dramatic
if (item.data[i] !== expected_val) begin
  `uvm_fatal("READ MISMATCH", "ABORT")    // ← Kills simulation
end
```

vs

```systemverilog
// SENIOR — logs and continues
if (item.data[i] !== expected_val) begin
  `uvm_error("READ MISMATCH", $sformatf(...))
  error_count++;
end
```

Reviewers WILL catch this in real PRs.

---

## 8. End-of-Test Check — `check_phase` and `report_phase`

### Where the Final Verdict Lives

The file uses `report_phase` for the final verdict:

```systemverilog
virtual function void report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info(get_type_name(), $sformatf("...SCOREBOARD REPORT..."), UVM_LOW)

  if (error_count > 0) begin
    `uvm_error("SCOREBOARD FAILED: %0d errors detected.")
  end else if (actual_count == 0) begin
    `uvm_error("SCOREBOARD FAILED: No actual transactions received!")
  end else if (actual_count != expected_count) begin
    `uvm_error("SCOREBOARD FAILED: Expected %0d but got %0d actual transactions.")
  end else begin
    `uvm_info("SCOREBOARD PASSED: All transactions matched.")
  end
endfunction
```

Three failure modes are checked:
1. **Any errors during the test?** → fail.
2. **Zero actual transactions?** → fail. (Critical — see below.)
3. **Expected count != actual count?** → fail.

### The "Silent Pass" Bug Pattern

**This is THE bug pattern that ends DV engineers' careers.** Consider:

```systemverilog
// BUG — the silent pass
virtual function void report_phase(uvm_phase phase);
  if (error_count > 0) begin
    `uvm_error("FAILED")
  end
endfunction
```

If the monitor was misconfigured and never connected, `actual_count == 0`. No `write_actual()` is ever called. No errors are ever flagged. **The test passes silently.** Months later, someone discovers the entire test suite was meaningless.

Our scoreboard's defense: explicitly check `actual_count == 0` and `actual_count != expected_count`. This catches the silent-pass case.

> **Interview-grade answer:**
> *"A scoreboard that only checks `if (errors > 0)` is dangerous because a misconfigured environment can produce zero transactions and zero errors — the test passes vacuously. Every scoreboard I write has at least three end-of-test checks: (1) any errors flagged, (2) at least one actual transaction was received, (3) expected count equals actual count. The last one specifically catches missed-transaction bugs where the DUT skipped a response and the monitor never saw it."*

### `check_phase` vs `report_phase` — Why This File Uses `report_phase`

UVM provides two phases at the end of simulation:

| Phase | Purpose | Timing |
|---|---|---|
| `extract_phase` | Pull final data from DUT/registers | After all run_phase completes |
| `check_phase` | Compare extracted data, drain queues, post final pass/fail | After extract |
| `report_phase` | Print summary reports | After check |

**By convention:** `check_phase` is where checking happens; `report_phase` is where you print.

**This file uses `report_phase` for both checking AND reporting** — a minor convention violation. Not wrong, but unconventional. A cleaner split:

```systemverilog
virtual function void check_phase(uvm_phase phase);
  super.check_phase(phase);
  if (actual_count == 0)
    `uvm_error("No transactions received")
  if (actual_count != expected_count)
    `uvm_error("Count mismatch")
endfunction

virtual function void report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info("SUMMARY", $sformatf(...), UVM_LOW)
endfunction
```

> **Interview note:** Don't ding the original code for this — it works correctly. But if asked "how would you improve this scoreboard," moving checks to `check_phase` is a valid answer that shows you know UVM phase semantics.

---

## 9. Queue Management — Draining, Leftovers, Silent-Pass Bugs

### Why This Scoreboard Has No Queues

As noted in Section 5, the reference model is state-based, not queue-based. The shadow register bank IS the model state. There are no `i2c_seq_item expected_q[$]` arrays.

**Implication:** there is nothing to drain at end of test. The `report_phase` check on `actual_count == expected_count` is the closest equivalent of a "queue empty" check.

### When You WOULD Have Queues

If you used a queue-based scoreboard:

```systemverilog
i2c_seq_item expected_q[$];
i2c_seq_item actual_q[$];

virtual function void write_expected(i2c_seq_item item);
  expected_q.push_back(item);
endfunction

virtual function void write_actual(i2c_seq_item item);
  actual_q.push_back(item);
  // attempt to drain by matching pairs:
  while (expected_q.size() > 0 && actual_q.size() > 0) begin
    compare(expected_q.pop_front(), actual_q.pop_front());
  end
endfunction
```

Then `check_phase` MUST verify both queues are empty:

```systemverilog
virtual function void check_phase(uvm_phase phase);
  if (expected_q.size() != 0) `uvm_error("Unmatched expected transactions")
  if (actual_q.size() != 0)   `uvm_error("Unmatched actual transactions")
endfunction
```

**Forgetting this drain check is the second-most-common scoreboard bug** (after the silent-pass bug from Section 8).

### Why Queues at All?

Use queues when:
- Expected and actual streams arrive out of sync (one can lead the other significantly).
- Reordering is possible (AXI with multiple outstanding IDs).
- You want to support pipelined comparison (e.g., scoreboard runs `compare()` task in a forked thread).

For I2C, none of these apply. State-based is fine.

> **Interview-grade answer:**
> *"This scoreboard uses a state-based reference model instead of explicit transaction queues. The shadow register bank IS the model — comparison happens immediately on actual transaction arrival. This avoids queue management entirely but requires that expected updates arrive before the corresponding actual transaction. For an out-of-order or asynchronous protocol I'd use per-ID queues and a `check_phase` drain check. For I2C's strictly in-order single-master nature, state-based is cleaner."*

### Drainage as a Bug Source

A queue that's not drained at end of test means there were expected events that never produced an actual response — a missed transaction. This is a **silent loss-of-data bug** in the DUT. Catching it requires the drain check; without it, the test passes.

Drainage failures often surface as:
- DUT hangs and never completes the last transaction (your simulation timeouts kick in elsewhere, but the scoreboard wouldn't catch this).
- Off-by-one in transaction counting.
- Last transaction dropped due to reset-pending or back-pressure.

### Patterns for Robust Queue-Based Comparison

If you ever convert this scoreboard to queue-based, here's the canonical pattern:

```systemverilog
class queued_scoreboard extends uvm_scoreboard;
  i2c_seq_item expected_q[$];
  i2c_seq_item actual_q[$];

  virtual function void write_expected(i2c_seq_item t);
    expected_q.push_back(t);
    try_match();
  endfunction

  virtual function void write_actual(i2c_seq_item t);
    actual_q.push_back(t);
    try_match();
  endfunction

  virtual function void try_match();
    while (expected_q.size() > 0 && actual_q.size() > 0) begin
      i2c_seq_item e = expected_q.pop_front();
      i2c_seq_item a = actual_q.pop_front();
      if (!e.compare(a)) begin
        `uvm_error("MISMATCH", $sformatf("expected=%s actual=%s",
                   e.sprint(), a.sprint()))
      end
    end
  endfunction

  virtual function void check_phase(uvm_phase phase);
    if (expected_q.size() != 0)
      `uvm_error("DRAIN", $sformatf("%0d expected unmatched", expected_q.size()))
    if (actual_q.size() != 0)
      `uvm_error("DRAIN", $sformatf("%0d actual unmatched", actual_q.size()))
  endfunction
endclass
```

Three nuances:

1. **`try_match()` is called from both callbacks.** Either side can complete a pair.
2. **`compare()` is called on the transaction object.** Implement it in your `i2c_seq_item` class using `uvm_object::compare`. This handles printing both sides for free.
3. **The drain check uses size(), not count.** Direct queue introspection — bulletproof.

### When Queues Must be ID-Indexed (AXI Style)

For AXI, where ordering is per-ID:

```systemverilog
i2c_seq_item expected_q[bit[ID_W-1:0]][$];
// queue PER ID

virtual function void write_actual(i2c_seq_item t);
  if (expected_q[t.id].size() == 0) begin
    `uvm_error("ORPHAN", $sformatf("response with no matching expected for id=%0d", t.id))
    return;
  end
  i2c_seq_item e = expected_q[t.id].pop_front();
  if (!e.compare(t)) `uvm_error("MISMATCH", ...)
endfunction

virtual function void check_phase(uvm_phase phase);
  foreach (expected_q[id]) begin
    if (expected_q[id].size() > 0)
      `uvm_error("DRAIN", $sformatf("id=%0d has %0d unmatched",
                                    id, expected_q[id].size()))
  end
endfunction
```

This is the **per-ID queue pattern**. Memorize it for AXI/AHB/AHB-Lite scoreboards.

---

## 10. Quiz — 12 Questions

Test yourself by covering the answer section before reading further. Aim for at least 9/12 to consider yourself interview-ready on this material.

1. **What is the scoreboard's role in a UVM environment?** Why is it called the "judge"? What happens if it's missing or silently buggy?

2. **What's the difference between `uvm_analysis_imp` and `uvm_analysis_export`?** When would you use each? Why is the variable in our file named `expected_export` if it's actually an imp?

3. **Compare the three reference model patterns: predictor, golden model, in-line algorithm.** Which one does our scoreboard use and why?

4. **I2C is a strictly in-order protocol. How would you modify this scoreboard for an out-of-order protocol like AXI?** Be specific about data structures.

5. **The `report_phase` checks `actual_count == expected_count`. Why is this check necessary? What bug pattern does it catch?**

6. **When should you use `uvm_error` and when `uvm_fatal`?** Give two specific examples for each.

7. **Walk through how `write_actual()` gets called when the monitor sends a transaction.** What's the chain from monitor → scoreboard? Be precise about the macro mechanics.

8. **Define "deterministic comparison" in scoreboard context.** Why is non-determinism a verification disaster? Give one example of a non-deterministic scoreboard.

9. **When should the scoreboard SKIP comparison and not flag an error?** Name at least three scenarios.

10. **Why must the scoreboard be passive — i.e., never drive anything onto the bus?** What goes wrong if it does?

11. **How does the scoreboard interact with the coverage collector?** Should the scoreboard sample coverage? Should they share data?

12. **What's the difference between `i2c_scoreboard::type_id::create("sb", this)` and `new("sb", this)`?** When does the difference matter?

---

## 11. Quiz — Answers & Deep Explanations

### Q1 — Scoreboard's Role

**Senior-engineer answer:**

The scoreboard is the **sole component that decides pass or fail** in a UVM environment. It receives two streams — expected behavior (derived from stimulus) and actual behavior (captured by monitors) — and determines whether they match. Every other component is either generating stimulus (sequence, driver) or passively observing (monitor, coverage collector). The scoreboard alone produces the verdict.

If the scoreboard is missing or silently buggy:
- A broken **driver** causes the test to FAIL noisily (driver assertions, monitor sees garbage).
- A broken **monitor** causes coverage holes (visible in reports).
- A broken **scoreboard** causes silent PASS — the test reports green while the DUT misbehaves.

This is why senior engineers spend disproportionate time reviewing scoreboard code. **A bug in the DUT is a verification win; a bug in the scoreboard is a verification disaster.**

> **Interview-grade answer:**
> *"The scoreboard is the judge of the testbench. It compares expected vs actual behavior and decides PASS or FAIL. It's the only component whose correctness directly determines whether bugs ship. If it silently swallows errors, every test that ran through it gave false confidence. That's why I treat scoreboard code with the same review rigor as the DUT itself."*

---

### Q2 — `analysis_imp` vs `analysis_export`

**Concise answer:**

| Type | Has `write()` impl? | Typical owner | Purpose |
|---|---|---|---|
| `uvm_analysis_port` | No (broadcasts) | Monitor, predictor | Publishes transactions |
| `uvm_analysis_imp` | YES (implemented by parent class) | Scoreboard, subscriber | Receives + acts on transactions |
| `uvm_analysis_export` | No (forwards to a downstream imp) | Hierarchical envs | Passthrough for nested connections |

**An imp is an endpoint.** The class that owns the imp must implement `write()` (or the suffixed variant like `write_expected`). When the source port calls `write()`, the imp invokes the owner's callback.

**An export is a passthrough.** Use it when an analysis port from deep inside a sub-environment needs to be exposed at the parent env level. Example:

```
agent.monitor.ap → agent.ap_export → env.ap_export → scoreboard.imp
```

Each `export` is just a forwarding hop. Only the final `imp` actually has logic.

**The naming in our file (`expected_export` for an imp) is misleading.** It's a leftover convention from some teams that name all ports with `_export` suffix regardless of type. The variable's *type* is `uvm_analysis_imp_expected`, so it's an imp. The name is just a string.

> **Interview-grade answer:**
> *"An `analysis_imp` is an endpoint with a built-in `write()` implementation provided by the owning class. An `analysis_export` is a passthrough that forwards to a downstream imp — used in hierarchical environments where the actual subscriber is nested deep. In our scoreboard, the variable is named `expected_export` but its type is `uvm_analysis_imp_expected`. The name is a team convention, not a UVM requirement. Functionally it's still an imp."*

---

### Q3 — Three Reference Model Patterns

**Pattern 1 — In-line algorithm.** Reference behavior is computed inside the scoreboard's `write_*` callbacks. State lives as scoreboard member variables. Used for small stateful DUTs.

**Pattern 2 — Separate predictor.** A separate `uvm_subscriber`-based class consumes stimulus and emits expected transactions on its own analysis port. The scoreboard merely receives both expected and actual streams and compares. Used for complex DUTs (CPUs, fabrics, NoCs).

**Pattern 3 — DPI/golden model.** A C/C++ reference model is linked via DPI-C; the scoreboard invokes it to compute expected outputs. Used for algorithmic blocks where a reference implementation already exists (DSP, crypto).

**Our scoreboard uses Pattern 1** because the DUT is a tiny 8-register I2C slave. The prediction logic is three lines. A separate predictor class would add ceremony without insight.

> **Interview-grade answer:**
> *"For an 8-byte register-file I2C slave, an in-line model is correct — the prediction is a wrapping counter and a write to a shadow array. For an AXI fabric I'd use a separate predictor class that consumes master-side transactions and emits expected slave-side transactions on its own analysis port. For something like a DCT or AES block, I'd DPI-link a C reference. The pattern matches the complexity of the prediction logic."*

---

### Q4 — Adapting for Out-of-Order Protocols

**For AXI:**

Key changes:
1. **Per-ID queues.** Replace state-based comparison with `i2c_seq_item expected_q[bit[ID_W-1:0]][$]`.
2. **Match by ID.** On `write_actual()`, look up by `item.id`, pop the oldest expected with that ID, compare.
3. **Outstanding tracking.** Maintain `outstanding_count[id]` to enforce per-ID ordering rules.
4. **Drain check in `check_phase`.** Iterate all IDs, verify `expected_q[i].size() == 0`.

```systemverilog
i2c_seq_item expected_q [bit[3:0]] [$];   // per-ID queue

virtual function void write_actual(i2c_seq_item item);
  i2c_seq_item exp_item;
  if (expected_q[item.id].size() == 0) begin
    `uvm_error("Unexpected response", $sformatf("id=%0d", item.id))
    return;
  end
  exp_item = expected_q[item.id].pop_front();
  compare(exp_item, item);
endfunction
```

**Plus:** for AXI write responses (BRESP) vs read data (RDATA), you'd have separate ports and queues for each channel.

> **Interview-grade answer:**
> *"AXI permits out-of-order completion based on the transaction ID, but within the same ID, ordering is preserved. So I'd structure the scoreboard with per-ID queues. On each actual response, I'd index into `expected_q[id]`, pop the oldest, and compare. The end-of-test check then iterates all IDs and verifies each queue is empty. For full AXI you'd have separate queues per channel — read data, write data, write response — and possibly cross-channel ordering checks for write data vs write address."*

---

### Q5 — Why `actual_count == expected_count` Matters

**This check catches the silent-pass bug:**

If the monitor is misconfigured and never connected to the bus, `write_actual()` is never called. `actual_count` stays 0. No errors are flagged inside the callbacks (none run). The naive end-of-test check `if (error_count > 0)` reports PASS.

**The count mismatch check defends against this:**
- If `expected_count > 0 && actual_count == 0` → monitor is broken, fail.
- If `expected_count > actual_count` → DUT missed some transactions, fail.
- If `expected_count < actual_count` → DUT produced spurious transactions, fail.

In our file, the explicit `actual_count == 0` check handles the worst case, and the `expected_count != actual_count` check handles the general miscount.

> **Interview-grade answer:**
> *"This check defends against the silent-pass bug — the most dangerous bug class in verification. If the monitor is disconnected, `write_actual` is never called, no errors fire, and a test that should fail reports green. Three end-of-test checks I always include: (1) `error_count == 0`, (2) `actual_count > 0`, (3) `actual_count == expected_count`. Together they catch missing data, disconnected monitors, and miscounts."*

---

### Q6 — `uvm_error` vs `uvm_fatal`

**Use `uvm_error` for:**
- DUT misbehavior (mismatch, protocol violation, unexpected NACK).
- Recoverable scoreboard anomalies (unknown data bytes, address out of range).

Each `uvm_error` increments the global error counter; the test fails at end-of-test. **Simulation continues**, so you can catch more bugs in the same run.

**Use `uvm_fatal` for:**
- Configuration errors that prevent test execution (`if (cfg == null) uvm_fatal(...)`).
- Hung state machines detected by watchdog (continuing is meaningless).
- Corrupted scoreboard invariants (e.g., shadow_ptr exceeds physical bounds).

`uvm_fatal` calls `$finish` immediately. Use sparingly — every `uvm_fatal` cuts off opportunities to find further bugs in the same simulation.

**Two examples each:**

| Severity | Example 1 | Example 2 |
|---|---|---|
| `uvm_error` | "Read mismatch at reg[3]" | "Unexpected NACK on byte 5" |
| `uvm_fatal` | "Config object is null" | "Watchdog timer fired; DUT hung" |

> **Interview-grade answer:**
> *"`uvm_error` flags a DUT failure but allows simulation to continue — I want one simulation to surface as many bugs as possible. `uvm_fatal` ends simulation immediately and is reserved for environment failures: null config, corrupt scoreboard state, watchdog hang. A junior engineer often uses `uvm_fatal` for mismatches — that's wrong, because it turns a productive regression into a one-bug-at-a-time hunt."*

---

### Q7 — The `write_actual` Call Chain

Walk through end-to-end:

1. **Monitor samples the bus** during `run_phase`. It builds an `i2c_seq_item` and calls `analysis_port.write(item)`.

2. **Analysis port broadcasts.** `uvm_analysis_port.write(t)` iterates all connected subscribers and calls each one's `write()`.

3. **The connection.** Earlier, in `env.connect_phase`, someone wrote:
   ```systemverilog
   monitor.ap.connect(scoreboard.actual_export);
   ```
   So the scoreboard's `actual_export` is one of the connected subscribers.

4. **The imp forwards.** `scoreboard.actual_export.write(t)` is invoked. Because `actual_export` is of type `uvm_analysis_imp_actual`, its `write()` is the macro-generated forwarder:
   ```systemverilog
   virtual function void write(input T t);
     m_imp.write_actual(t);  // m_imp == the scoreboard
   endfunction
   ```

5. **The scoreboard callback runs.** `i2c_scoreboard.write_actual(item)` finally executes — checks address ACK, data integrity, etc.

**The whole chain is fully synchronous:** the monitor's `write()` call doesn't return until the scoreboard's check is done. There's no scheduling, no delta cycle delay. This is important — it means scoreboard mismatches are detected at the same simulation time as the monitor sample.

> **Interview-grade answer:**
> *"The monitor calls `ap.write(item)`. The analysis port iterates its subscribers and invokes each one's `write()`. The scoreboard's `actual_export` is a `uvm_analysis_imp_actual` — its `write()` is generated by the `uvm_analysis_imp_decl` macro and forwards to the parent's `write_actual()`. All synchronous, all in the same delta cycle as the monitor sample. The macro is what makes multi-port subscription possible because SystemVerilog doesn't allow method overloading by parameter type."*

---

### Q8 — Deterministic Comparison

**Definition:** A scoreboard is **deterministic** if, given the same input streams (expected and actual), it always produces the same verdict regardless of:
- Simulation timing jitter.
- Random seeds in the comparison logic itself.
- Order of `write_*` callback invocation (when they're commutative).

**Non-determinism is a verification disaster** because:
- A bug may show only on some seeds and "disappear" on others.
- Regression results become noisy — pass/fail flips between identical runs.
- Reproducing failures becomes impossible.

**Example of a non-deterministic scoreboard:**

```systemverilog
virtual function void write_actual(i2c_seq_item item);
  if ($urandom_range(100) < 5)   // randomly skip 5% of checks
    return;
  // ... compare
endfunction
```

Don't laugh — this exact pattern shows up in junior code that's trying to "soak-test." A scoreboard MUST be deterministic.

**Subtler non-determinism:**

```systemverilog
// Assumes expected and actual arrive in a specific order:
virtual function void write_actual(i2c_seq_item item);
  compare(item, ref_reg_bank[shadow_ptr]);  // ← What if expected hasn't arrived yet?
endfunction
```

If `write_expected()` hasn't run yet when `write_actual()` arrives, the comparison uses stale state. The bug exists, but only manifests under certain timing.

> **Interview-grade answer:**
> *"A deterministic scoreboard always produces the same verdict for the same input streams. Non-determinism — randomness in the check logic, dependence on callback invocation order, races between expected and actual — destroys regression confidence because the same bug appears or disappears between runs. Any randomness in the scoreboard is a bug. The scoreboard should only use simulation-time-resolved data and pure comparison logic."*

---

### Q9 — When to Skip Scoring

At least three legitimate scenarios:

**1. During reset.** When `rst_n == 0`, the DUT's state is undefined. Any transaction observed during reset should be ignored, not flagged.

```systemverilog
virtual function void write_actual(i2c_seq_item item);
  if (!cfg.vif.rst_n) return;   // skip during reset
  // ... normal check
endfunction
```

**2. During configuration / setup phase.** Some DUTs require a programming sequence (clock dividers, address registers) before they're ready. Scoring shouldn't begin until config is complete. Often gated by a `cfg.enable_scoring` bit set after init.

**3. For X/Z values when explicitly allowed.** A read from an unwritten register might legitimately return X. The scoreboard should skip integrity checks for such cases (or compare against the known unknown).

**4. Bonus — for protocol-violation tests.** If your test is INTENTIONALLY injecting protocol errors (to verify the DUT's error-handling FSM), the scoreboard should suspend normal checks and instead verify the DUT's error response.

**The mechanism:** every scoreboard should expose an `enable_scoring` bit, settable via configuration, that gates all comparison logic.

> **Interview-grade answer:**
> *"Three cases — during reset, during DUT configuration before scoring should start, and during intentional error-injection tests. I always include an `enable_scoring` bit in the scoreboard configuration that can be toggled by the sequence. Without this, error-injection tests fail spuriously because the scoreboard sees the intentional bad behavior as a bug."*

---

### Q10 — Why the Scoreboard Must Be Passive

The scoreboard MUST NEVER drive signals onto the bus or interact with the DUT outside its `write_*` callbacks. Reasons:

**1. Separation of concerns.** Drivers stimulate; monitors observe; scoreboards judge. Mixing roles makes the testbench unreadable and unmaintainable.

**2. Determinism.** If the scoreboard could drive, its actions would affect future observations, creating feedback loops that destroy reproducibility.

**3. Race conditions.** Driving from the scoreboard happens at unpredictable simulation times (whenever an analysis port broadcast fires). Driving the bus from such a context creates protocol violations.

**4. False positives.** If the scoreboard "fixes" a DUT bug by driving the right value, the bug never surfaces. Verification mission compromised.

**What goes wrong specifically:**
- Multi-driver contention on the bus (X-propagation).
- Scoreboard accidentally drives during the DUT's response window → masks a missing-response bug.
- Test results become non-reproducible.

> **Interview-grade answer:**
> *"A scoreboard that drives the bus is no longer a scoreboard — it's a driver wearing a checker's hat. The roles must be separated: driver stimulates, monitor observes, scoreboard judges. If the scoreboard drives, it creates X-contention with the actual driver, masks bugs by overriding DUT outputs, and destroys reproducibility. Passive observation is a hard invariant — `assert(scoreboard.drives_nothing)`."*

---

### Q11 — Scoreboard and Coverage Interaction

**Direct interaction: usually none.**

The scoreboard and coverage collector are **independent subscribers** to the monitor's analysis port:

```
                  +--- scoreboard.actual_export
monitor.ap -------+
                  +--- coverage.analysis_export
```

Both receive the same stream. Both work in parallel. Neither knows about the other.

**Should scoreboard sample coverage?** Generally NO. Mixing roles creates the same problems as in Q10.

**Should they share data?** Almost never. The scoreboard's pass/fail logic and the coverage collector's bin updates serve different purposes. If they shared a queue, a fix in one could break the other.

**One legitimate interaction:** "guarded coverage" — coverage collection only on transactions that PASSED the scoreboard's check. This is sometimes useful to ensure you're not counting buggy behavior in your coverage report. But it's an advanced pattern and adds coupling — most teams keep coverage and scoreboards entirely independent.

> **Interview-grade answer:**
> *"Scoreboard and coverage collector are independent subscribers to the same monitor analysis port. They run in parallel and don't share state. The scoreboard decides pass/fail; the coverage collector measures stimulus diversity. Coupling them — like only sampling coverage on passing transactions — is sometimes done for guarded coverage, but it adds tight coupling and most teams keep them separate."*

---

### Q12 — `type_id::create` vs `new`

**`new("sb", this)`:**
- Directly invokes the constructor.
- Always returns an instance of `i2c_scoreboard`.
- Cannot be overridden by the test.

**`i2c_scoreboard::type_id::create("sb", this)`:**
- Goes through the UVM factory.
- The factory checks: "Has anyone registered an override for `i2c_scoreboard`?"
- If yes, returns an instance of the OVERRIDE type (e.g., `i2c_scoreboard_v2`).
- If no, returns an instance of `i2c_scoreboard`.

**Why the difference matters:**

Imagine you're adding a new feature and want a temporary, more-verbose scoreboard for one specific test. With factory:

```systemverilog
class my_test extends base_test;
  virtual function void build_phase(uvm_phase phase);
    set_type_override_by_type(i2c_scoreboard::get_type(),
                              i2c_scoreboard_v2::get_type());
    super.build_phase(phase);   // env builds; factory returns v2 instead
  endfunction
endclass
```

The env code is **unchanged**. The override is local to one test.

**Without factory** (using `new`), you'd have to edit the env class to instantiate the new scoreboard — invasive change, breaks other tests.

**When does the difference matter?**
- When you ever want to swap implementations without editing common code.
- When inheritance is in play and tests need different specializations.

**Rule:** in UVM, **always use factory `create()`** for components and sequences. Reserve `new()` for purely-local helper objects with no factory registration.

> **Interview-grade answer:**
> *"`new` directly invokes the constructor and always returns the exact class. `type_id::create` goes through the UVM factory, which checks for type or instance overrides registered by the test. The factory enables tests to substitute different implementations without modifying common environment code — this is the killer feature of UVM. I use `type_id::create` for every component and sequence, and `new` only for purely local helper objects that don't need factory registration. The analysis imps in this file use `new` because the scoreboard owns them — they're not factory-overridable."*

---

## 12. Key Takeaways

### Conceptual

1. **The scoreboard is the judge — the sole component that decides pass or fail.** Every other component is either stimulus or observation. Verify scoreboard correctness with the same rigor as the DUT.

2. **`uvm_analysis_imp_decl` is the macro that enables multi-port subscription.** It generates a new analysis_imp type whose `write()` forwards to a uniquely-named callback. Without it, you cannot have two analysis subscribers in one class.

3. **`analysis_imp` is an endpoint; `analysis_export` is a passthrough.** Variable names like `_export` don't change the type. Always look at the type, not the name.

4. **Reference model patterns: in-line, predictor, golden.** Pick the pattern that matches the prediction complexity, not the one that looks fanciest.

5. **In-order matching is fine for I2C; out-of-order requires per-ID queues.** Don't reuse this scoreboard's pattern for AXI.

6. **`uvm_error` for DUT misbehavior; `uvm_fatal` for environment failures.** Reserve `uvm_fatal` for unrecoverable conditions.

7. **The silent-pass bug is the most dangerous bug class in verification.** Defend with `actual_count > 0` and `actual_count == expected_count` checks at end of test.

8. **`check_phase` is for checks; `report_phase` is for reports.** Convention, not enforced, but reviewers expect it.

9. **A queue-based scoreboard MUST drain queues in `check_phase`.** Otherwise missed transactions go undetected.

10. **Deterministic comparison is non-negotiable.** Any randomness in the scoreboard is a bug.

11. **Scoreboard must be passive — never drive.** Driving from a scoreboard creates X-contention, false positives, and destroys reproducibility.

12. **`type_id::create` enables factory override; `new` does not.** Always use factory for components and sequences.

### Career-critical

- **The macro `uvm_analysis_imp_decl` will be asked about in NVIDIA/Qualcomm interviews.** Memorize what it expands to and why it exists.
- **The "silent pass" defense (count checks) separates juniors from seniors.** Mention it unprompted in interviews.
- **Knowing in-order vs out-of-order matching shows protocol depth.** Frame answers protocol-by-protocol.
- **Articulating the in-line vs predictor reference model trade-off** demonstrates architectural thinking — interviewers love it.

### Honest Self-Score Template (2026-05-17)

| Area | Score | Status |
|---|---|---|
| Scoreboard role / judge analogy | __% | __ |
| `uvm_analysis_imp_decl` macro mechanics | __% | __ |
| `analysis_imp` vs `analysis_export` | __% | __ |
| Three reference model patterns | __% | __ |
| In-order vs out-of-order matching | __% | __ |
| `uvm_error` vs `uvm_fatal` discipline | __% | __ |
| Silent-pass bug defense | __% | __ |
| `check_phase` vs `report_phase` convention | __% | __ |
| Queue drainage | __% | __ |
| Deterministic comparison principle | __% | __ |
| Scoreboard passivity | __% | __ |
| Factory `create` vs `new` | __% | __ |

Fill this out HONESTLY after taking the quiz without notes. Anything below 70% — re-read the relevant section.

---

## 13. Action Items

### Immediate (this week)

- [ ] Re-do the quiz from Section 10 **without looking at answers** in 3 days. Target 9/12.
- [ ] Add **transaction timeout** logic: if `actual_count` hasn't increased in N simulation ticks, raise an error. Currently the scoreboard relies on global watchdog timers elsewhere — making this local makes failures easier to localize.
- [ ] **Statistics tracking improvements:**
  - Track per-address transaction counts: `int per_addr_count[7'h00:7'h7F]`.
  - Track per-direction counts (read vs write breakdown).
  - Print histogram in `report_phase`.

### Short-term (this month)

- [ ] **Refactor checking into `check_phase`** and keep `report_phase` purely for reporting. Cleaner UVM phase semantics.
- [ ] **Add an `enable_scoring` configuration bit** to support intentional error-injection tests.
- [ ] **Add a coverage callback for matched transactions** — sample functional coverage only on transactions that passed scoreboard checks. (Optional, advanced.)
- [ ] **Document the ordering assumption explicitly** in a comment: "This scoreboard requires `write_expected()` to be called before `write_actual()` for any related transaction pair. Violating this ordering produces non-deterministic results."

### Long-term (this quarter)

- [ ] **Implement a queue-based variant** of this scoreboard for comparison and learning. Even if I2C doesn't need it, the exercise builds skills you'll need for AXI/AHB.
- [ ] **Build a predictor-class variant** that emits expected transactions on its own analysis port; have the scoreboard subscribe to BOTH the monitor and the predictor. This refactor mirrors what large UVM environments do.
- [ ] **For AXI XBar TB project:** apply per-ID queue pattern from Q4. Document the contrast with this I2C scoreboard.

### Stretch — Internship-grade deliverables

- [ ] Propose to faculty: write a coverage-driven random regression that intentionally NACKs the slave address; verify scoreboard correctly fails the test. **This is a sanity check ON the scoreboard itself** — a "test the tester" exercise.
- [ ] Convert this scoreboard's reference model into a standalone SystemC golden model linked via DPI. Demonstrate equivalent behavior. Massive resume signal.

---

## 14. Honest Self-Score Template

Print this section, fill it out, and tape it inside your notebook. Re-evaluate weekly.

```
LESSON 12 — SCOREBOARD MASTERY CHECKLIST
========================================

Date taken: __________
Re-evaluation 1 week later: __________
Re-evaluation 1 month later: __________

CONCEPTUAL — circle one for each:

  [ ] Can explain why the scoreboard is "the judge" in <60 seconds?      Y / N
  [ ] Can describe what `uvm_analysis_imp_decl` does WITHOUT notes?      Y / N
  [ ] Can distinguish `analysis_imp` from `analysis_export`?             Y / N
  [ ] Can list all three reference model patterns and pick correctly?    Y / N
  [ ] Can describe the silent-pass bug and its defense?                  Y / N
  [ ] Can explain `uvm_error` vs `uvm_fatal` with examples?              Y / N
  [ ] Can walk through the monitor → scoreboard call chain?              Y / N
  [ ] Can explain deterministic comparison and why it matters?           Y / N
  [ ] Can list at least 3 scenarios for skipping scoring?                Y / N
  [ ] Can defend "scoreboard must be passive" with specifics?            Y / N
  [ ] Can describe scoreboard / coverage interaction policy?             Y / N
  [ ] Can explain factory `create` vs `new`?                             Y / N

QUIZ SCORE:  ____ / 12

INTERVIEW READINESS:
  9 or more: ready for NVIDIA/Qualcomm scoreboard questions
  6–8:        re-read Sections 4, 8, 9 before any interview
  Below 6:    full re-read required

ACTION ITEMS COMPLETED:
  Immediate:  ____ / 5
  Short-term: ____ / 4
  Long-term:  ____ / 3
  Stretch:    ____ / 2

NOTES — what surprised me / where I was weak:
________________________________________________________
________________________________________________________
________________________________________________________
________________________________________________________
```

---

## Closing — Brutal Honesty Section

Kushal, the scoreboard is **the file that separates the fresher who built a UVM environment from the fresher who built a working UVM environment**. Everybody can write a sequence and a driver. Most can write a monitor. The scoreboard is where 90% of candidates trip up because:

1. They don't understand `uvm_analysis_imp_decl` and try to put multiple `write()` methods in one class. Compile error. Interview over.

2. They never check `actual_count > 0` at end of test. The interviewer asks "what if the monitor was disconnected?" — silence. Interview over.

3. They claim "I have a scoreboard" but on inspection it's just printing transactions, not comparing anything. Pull-up question reveals the truth. Interview over.

4. They use `uvm_fatal` on every mismatch and don't see why that's a problem. Indicates one-bug-at-a-time mindset. Senior interviewer dings them.

If you walk into an interview having internalized this file — particularly sections 4 (macro mechanics), 5 (reference model patterns), and 8 (silent-pass defense) — **you will be in the top 10% of fresh candidates on scoreboard knowledge.** That's a measurable, achievable career advantage.

Your 15-bug count on this I2C project is strong. The next question an interviewer will ask is: **"How did your scoreboard catch them?"** Have an answer for that. Walk through one specific bug — what mismatch fired, which `uvm_error` printed, why the in-line reference model surfaced it.

You're 70% of the way there. The remaining 30% is repetition and articulation. Re-do the quiz next week. Score yourself honestly. Fill out the self-score template. Don't lie to yourself — the interviewer won't.

See you in Lesson 13.

---

## Appendix A — Cheat Sheet for Whiteboard Interviews

When asked to **whiteboard a scoreboard** at NVIDIA/Qualcomm/Intel, here's the skeleton to draw from memory:

```systemverilog
`uvm_analysis_imp_decl(_exp)
`uvm_analysis_imp_decl(_act)

class my_sb extends uvm_scoreboard;
  `uvm_component_utils(my_sb)

  uvm_analysis_imp_exp #(txn_t, my_sb) exp_imp;
  uvm_analysis_imp_act #(txn_t, my_sb) act_imp;

  txn_t expected_q[$];
  int n_exp, n_act, n_err, n_ok;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    exp_imp = new("exp_imp", this);
    act_imp = new("act_imp", this);
  endfunction

  virtual function void write_exp(txn_t t);
    expected_q.push_back(t);
    n_exp++;
  endfunction

  virtual function void write_act(txn_t t);
    txn_t e;
    n_act++;
    if (expected_q.size() == 0) begin
      `uvm_error("ORPHAN", "actual with no expected")
      n_err++;
      return;
    end
    e = expected_q.pop_front();
    if (!e.compare(t)) begin
      `uvm_error("MISMATCH", $sformatf("exp=%s act=%s", e.sprint(), t.sprint()))
      n_err++;
    end else begin
      n_ok++;
    end
  endfunction

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (n_act == 0)
      `uvm_error("EMPTY", "no actuals received")
    if (expected_q.size() != 0)
      `uvm_error("DRAIN", $sformatf("%0d unmatched expected", expected_q.size()))
    if (n_err > 0)
      `uvm_error("FAIL", $sformatf("%0d errors", n_err))
  endfunction
endclass
```

Practice writing this from scratch in under 10 minutes. The first time, look at this template. The fifth time, write it from memory. The tenth time, you'll do it in the interview without thinking.

---

## Appendix B — Common Interview Variations

### Variation 1 — "How do you handle reset mid-test?"

Answer: expose a `enable_scoring` bit; sequence asserts it after reset deassertion; clears it before reset assertion. Inside `write_*`, gate all comparison on `if (!enable_scoring) return;`. Drain queues on reset assertion to clear stale expected/actual.

### Variation 2 — "How do you scoreboard a clock-domain-crossing FIFO?"

Answer: separate analysis ports for write side (TX domain) and read side (RX domain). Push expected on write, pop expected on read. Compare in `write_actual_rx`. End-of-test drain check on the FIFO.

### Variation 3 — "Your scoreboard runs slow in regression — how to speed it up?"

Answer: avoid `sprintf` formatting in hot paths (the formatting happens even when the error doesn't fire). Use lazy evaluation via the `uvm_info` verbosity threshold. Profile with QuestaSim's solver profiler. Move heavyweight `assoc_array` accesses to less-frequent code paths.

### Variation 4 — "How do you debug a scoreboard mismatch?"

Answer:
1. Enable `UVM_HIGH` verbosity to log every expected and actual transaction.
2. Dump both queues on first mismatch.
3. Bisect — narrow the failing test sequence.
4. Cross-reference monitor sample with waveform at the mismatch time.
5. Verify the reference model's prediction logic by hand for the failing transaction.
6. If the reference model has a bug, fix it; if the DUT has the bug, file it.

### Variation 5 — "How do you handle out-of-order responses?"

Answer: per-ID queues, indexed by transaction ID. Detailed in Q4 of the quiz.

### Variation 6 — "What if expected and actual streams can race?"

Answer: this is a scoreboard architecture flaw, not a feature. Fix the architecture: use queues so order of arrival doesn't matter, or enforce ordering through phasing in the env. Don't try to "fix" the race in the scoreboard with `#1` delays — that's a band-aid that hides bugs.

### Variation 7 — "How do you cover that the scoreboard itself works?"

Answer: write **negative tests** — sequences that intentionally inject errors. Verify the scoreboard correctly fails. This is "testing the tester" and is gold for interview answers. NVIDIA explicitly looks for this in their DV interviews.

---

## Appendix C — Glossary Quick-Reference

| Term | Definition |
|---|---|
| Analysis port | TLM port for broadcasting transactions to multiple subscribers |
| Analysis imp | Endpoint port with built-in `write()` impl |
| Analysis export | Passthrough port forwarding to a downstream imp |
| Scoreboard | UVM component that compares expected vs actual |
| Predictor | Separate class that generates expected transactions |
| Golden model | Reference implementation, often external (C/C++/SystemC) |
| In-line model | Reference logic implemented inside scoreboard callbacks |
| `check_phase` | UVM phase for end-of-test consistency checks |
| `report_phase` | UVM phase for printing summary information |
| Drain check | Verifying queues are empty at end of test |
| Silent pass | Test reports PASS while DUT is buggy |
| Determinism | Same input → same output, regardless of timing |
| Passive | Component that observes but doesn't drive |
| Factory override | UVM mechanism to swap types via test config |
| `uvm_analysis_imp_decl` | Macro creating uniquely-named analysis imp types |
| TLM | Transaction Level Modeling — abstraction layer above pin-level |
| ACK / NACK | I2C acknowledge / not-acknowledge on the 9th clock |
| Shadow register | Scoreboard-side copy mirroring DUT internal state |

---

## Appendix D — Recommended Reading Order

If this is your first scoreboard, read in this order:

1. **This file** — get the I2C-specific perspective.
2. **UVM 1.2 Class Reference** — `uvm_scoreboard`, `uvm_analysis_imp`, `uvm_analysis_port` entries.
3. **Accellera UVM 1.2 User's Guide** — Chapter on analysis components.
4. **"The UVM Primer" by Ray Salemi** — practical scoreboard examples.
5. **NVIDIA / Synopsys VIP documentation** — see how production-grade scoreboards are structured (when accessible).

After this, attempt the action items in Section 13. By the time you finish them, you'll have working knowledge that exceeds 95% of fresh DV applicants.
