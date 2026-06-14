> **⚠️ 2026-06-10 AUDIT UPDATE — read this box before trusting the lesson below.**
> A deep audit + fix pass changed the code this walkthrough describes. Deltas for this file:
> - `i2c_random_seq` / `i2c_stress_seq` now produce repeated-START chains in ~25% of iterations via `i2c_base_seq::do_rep_chain()` — `default_trans_c` (start=1/stop=1/rep=0) previously made rep-START unreachable from constrained-random.
> - `i2c_clock_stretch_seq.stretch_cycles` was removed (it was randomized and silently ignored — the slave ctrl sequence owns the duration); slave stretch range is now 200-400 cycles.
> Full detail: [`19_audit_fixes_walkthrough.md`](./19_audit_fixes_walkthrough.md) and `docs/AUDIT_FIX_REPORT.md`.

# Lesson 15 — `i2c_sequences.sv` Deep Dive

**File under study:** `uvm/i2c_sequences.sv` (~678 lines, 19 KB — the biggest UVM file in the project)
**Concepts covered:** `uvm_sequence`, `uvm_sequence_item`, `body()`, `start_item`/`finish_item` handshake,
inline randomization with `randomize() with { … }`, sequence layering, lifecycle hooks (`pre_body`,
`post_body`, `pre_start`, `post_start`), `` `uvm_do`` macros vs explicit handshake, virtual sequences,
sequencer arbitration (`lock`, `grab`, `priority`), `p_sequencer` access, multi-item I2C scenarios
(repeated-START, arbitration loss, clock stretching, NACK injection)
**Date:** 2026-05-17

---

## Table of Contents

1. [Where Sequences Fit in the UVM Architecture](#1-where-sequences-fit-in-the-uvm-architecture)
2. [60-Second Elevator Pitch](#2-60-second-elevator-pitch)
3. [The Fundamental Distinction — Sequence vs `seq_item`](#3-the-fundamental-distinction--sequence-vs-seq_item)
4. [The Base Sequence — `i2c_base_seq`](#4-the-base-sequence--i2c_base_seq)
5. [`body()` — The Heart of Every Sequence](#5-body--the-heart-of-every-sequence)
6. [`start_item` / `finish_item` — The Handshake With the Sequencer](#6-start_item--finish_item--the-handshake-with-the-sequencer)
7. [Inline Randomization — `randomize() with { … }`](#7-inline-randomization--randomize-with---)
8. [The `local::` Scope Resolution Trick](#8-the-local-scope-resolution-trick)
9. [`` `uvm_do`` Macros — What They Expand To](#9-uvm_do-macros--what-they-expand-to)
10. [Lifecycle Hooks — `pre_body`, `post_body`, `pre_start`, `post_start`](#10-lifecycle-hooks--pre_body-post_body-pre_start-post_start)
11. [Sequence Walkthroughs — One by One](#11-sequence-walkthroughs--one-by-one)
    - 11.1 `i2c_single_write_seq`
    - 11.2 `i2c_single_read_seq`
    - 11.3 `i2c_burst_write_seq` / `i2c_burst_read_seq`
    - 11.4 `i2c_write_read_seq`
    - 11.5 `i2c_rep_start_seq`
    - 11.6 `i2c_nack_addr_seq`
    - 11.7 `i2c_clock_stretch_seq`
    - 11.8 `i2c_data_nack_seq`
    - 11.9 `i2c_bus_free_seq`
    - 11.10 `i2c_random_seq`
    - 11.11 `i2c_stress_seq`
    - 11.12 `i2c_addr_sweep_seq`
    - 11.13 `i2c_data_pattern_seq`
    - 11.14 `i2c_slave_force_nack_seq` (different `req` type!)
    - 11.15 `i2c_slave_stretch_ctrl_seq`
    - 11.16 `i2c_sequential_seq`
    - 11.17 `arb_lost_sequence`
    - 11.18 `deep_rep_start_sequence` — the multi-segment masterpiece
12. [Sequence Layering — Parent Calls Child](#12-sequence-layering--parent-calls-child)
13. [Virtual Sequences and `p_sequencer`](#13-virtual-sequences-and-p_sequencer)
14. [Sequencer Arbitration — `lock`, `grab`, `priority`, `wait_for_grant`](#14-sequencer-arbitration--lock-grab-priority-wait_for_grant)
15. [Sequence IDs and Tracking](#15-sequence-ids-and-tracking)
16. [Common Bugs and Interview Traps](#16-common-bugs-and-interview-traps)
17. [Quiz — 20 Questions](#17-quiz--20-questions)
18. [Quiz Answers — Senior-Grade With Interview-Grade Callouts](#18-quiz-answers--senior-grade-with-interview-grade-callouts)
19. [Key Takeaways](#19-key-takeaways)
20. [Action Items — 3 New Sequences to Build](#20-action-items--3-new-sequences-to-build)
21. [Honest Self-Score Template](#21-honest-self-score-template)

---

## 1. Where Sequences Fit in the UVM Architecture

Before any line of code, internalize this diagram. If you cannot draw it on a whiteboard, do not move on.

```
+--------------------+    .start(sqr)    +-------------------+
|  uvm_test          |  ───────────────►  |   uvm_sequence    |
|  (run_phase)       |                    |   (i2c_*_seq)     |
+--------------------+                    +-------------------+
                                                  │
                                          start_item(req)
                                          randomize()
                                          finish_item(req)
                                                  │
                                                  ▼
                                  +-------------------------+
                                  |  uvm_sequencer #(item)  |
                                  |  (i2c_sequencer)        |
                                  +-------------------------+
                                                  │  TLM port
                                                  ▼
                                  +-------------------------+
                                  |  uvm_driver #(item)     |
                                  |  (i2c_driver)           |
                                  +-------------------------+
                                                  │  pin wiggling
                                                  ▼
                                            +----------+
                                            |   DUT    |
                                            +----------+
```

### The mental model in one sentence

A **sequence** is a *recipe* that produces *one or more* **sequence items**; the **sequencer** is a
*waiter* that carries each item to the **driver**, which physically drives the DUT pins.

### Why three things and not one?

Beginners ask: *"Why can't the test just call `driver.drive_byte(0xA5)` directly?"*

Because of **reuse and abstraction**:

| Layer | What changes if the protocol changes | What stays the same |
|---|---|---|
| Sequence (recipe) | Maybe (e.g. add new scenario) | Mostly stable |
| Sequence item (data class) | Yes — fields evolve | Class identity |
| Sequencer (mailbox/arbiter) | **No** — provided by UVM | Always the same |
| Driver (pin wiggler) | Yes — protocol-specific | Interface methods |

A test you wrote on day 1 of the project should still run on day 365 — because the test only knows
about the sequence library, not the driver. That's separation of concerns.

---

## 2. 60-Second Elevator Pitch

When an interviewer asks *"How does stimulus get generated in your I2C UVM environment?"*, say this:

> *"My test selects one of ~18 sequences from the library — for example `i2c_burst_write_seq` for a
> multi-byte write or `deep_rep_start_sequence` for a 4-segment repeated-START chain. The test calls
> `seq.start(env.agent.sequencer)`, which invokes the sequence's `body()` task. Inside `body()`, I
> create one or more `i2c_seq_item` objects, call `start_item` to request sequencer access, randomize
> the item with inline constraints (`randomize() with { addr == 7'h50; dir == DIR_WRITE; … }`), then
> call `finish_item` to hand the item to the driver. The driver wiggles SDA/SCL according to the item
> fields. For error-injection scenarios like arbitration loss or clock stretching, I also start a
> companion slave-control sequence on the slave-side ctrl sequencer to pre-configure the slave's
> behavior — that's a virtual-sequence-style coordination."*

That paragraph hits ~10 UVM terms an interviewer will scribble down as "knows what they're doing."

---

## 3. The Fundamental Distinction — Sequence vs `seq_item`

This is the *most common conceptual confusion* I see in fresher interviews. Get it surgically clear.

### `uvm_sequence_item` — a data object

- A class extending `uvm_sequence_item`.
- Holds **fields** describing a single transaction: `addr`, `data[]`, `dir`, `start_cond`, etc.
- Has **constraints** to keep the fields legal.
- Lives **once per transaction**.
- It is **passive** — it doesn't *do* anything. It's a struct on steroids.

### `uvm_sequence` — an active task-driven object

- A class extending `uvm_sequence #(REQ)` parameterized by the item type.
- Contains a `body()` task that **creates, randomizes, and sends** zero-to-N seq_items.
- Lives **once per scenario**.
- It is **active** — it executes a recipe over time.

### The analogy that cements it forever

| In a restaurant | In UVM |
|---|---|
| The recipe ("Margherita Pizza") | A sequence (`i2c_burst_write_seq`) |
| Each pizza you actually make | A sequence item (`i2c_seq_item`) |
| The waiter who carries orders | The sequencer (`uvm_sequencer`) |
| The chef who cooks at the stove | The driver (`uvm_driver`) |
| The diner who eats it | The DUT |

**You can run the same recipe many times to make many pizzas. You can run the same sequence many
times to generate many items.**

### In the code — exact line evidence

From line 12 of `i2c_sequences.sv`:

```systemverilog
class i2c_base_seq extends uvm_sequence #(i2c_seq_item);
```

The `#(i2c_seq_item)` parameterization is the **type contract**: this sequence promises to produce
items of type `i2c_seq_item`. The sequencer this sequence runs on must also be
`uvm_sequencer #(i2c_seq_item)` — types must match end-to-end, or compile fails.

> **Interview-grade answer:**
>
> *"A `uvm_sequence_item` is a passive data object describing one transaction — addresses, data,
> control bits. A `uvm_sequence` is an active object whose `body()` task generates one or more such
> items and sends them through `start_item`/`finish_item` to the sequencer. The sequence is the
> recipe; the item is the dish. Both inherit from `uvm_object`, neither is a component — they're
> transient and not part of the static testbench hierarchy."*

---

## 4. The Base Sequence — `i2c_base_seq`

Lines 12-20 of the file:

```systemverilog
class i2c_base_seq extends uvm_sequence #(i2c_seq_item);

  `uvm_object_utils(i2c_base_seq)

  function new(string name = "i2c_base_seq");
    super.new(name);
  endfunction

endclass : i2c_base_seq
```

### Why have a base class at all?

In this project, `i2c_base_seq` is **almost empty** — it adds nothing to `uvm_sequence` beyond a
factory registration. That's fine for now, but the *intent* of a base sequence is critical:

1. **Single registration point** for shared utilities (`pre_body`, error handlers, common config).
2. **Type alias** — child sequences inherit the `REQ = i2c_seq_item` parameterization so they don't
   have to repeat `extends uvm_sequence #(i2c_seq_item)` everywhere.
3. **Polymorphism** — code that wants "any I2C sequence" can hold an `i2c_base_seq` handle and start
   it without knowing the concrete subtype. Tests and virtual sequences exploit this.
4. **Future hook point** — when you eventually need `objection.raise()` / `drop()` or a default
   `report_id`, you add it once here and every child inherits it.

### `` `uvm_object_utils`` — what this macro really does

Expands into roughly:

```systemverilog
typedef uvm_object_registry#(i2c_base_seq, "i2c_base_seq") type_id;
static function type_id get_type();
  return type_id::get();
endfunction
virtual function uvm_object_wrapper get_object_type();
  return type_id::get();
endfunction
virtual function string get_type_name();
  return "i2c_base_seq";
endfunction
```

The key effect: the class is registered in the **UVM factory** under the string name
`"i2c_base_seq"`. Without this, `i2c_base_seq::type_id::create(...)` would fail at runtime, and
factory overrides (e.g. swapping in a debug variant) would be impossible.

### Why `function new(string name = ...) ; super.new(name); endfunction`

Three things to know:

- **Sequences are `uvm_object` descendants**, not `uvm_component`. So the constructor takes only a
  `name`, **never a parent**. Beginners always type `function new(string name, uvm_component parent)`
  for a sequence — that's a `uvm_component` constructor. Wrong inheritance branch.
- **Calling `super.new(name)` is mandatory.** Forgetting it is a compile error in UVM 1.2.
- The default value `"i2c_base_seq"` makes it easy to construct anonymously
  (`i2c_base_seq::type_id::create()` with no arg).

> **Interview-grade answer:**
>
> *"A UVM sequence inherits from `uvm_sequence`, which inherits from `uvm_object` — not
> `uvm_component`. So its constructor takes only a `name`, never a `parent`. That's because
> sequences are transient: they're not part of the static testbench hierarchy, they're created and
> destroyed during the run phase. The `` `uvm_object_utils`` macro registers the class with the
> factory so it can be created by string name and overridden later."*

---

## 5. `body()` — The Heart of Every Sequence

### What is `body()`?

`body()` is the **entry point** of a sequence. It's a virtual task defined in `uvm_sequence` that
child classes override to describe the stimulus recipe.

```systemverilog
virtual task body();
  // your stimulus recipe goes here
endtask
```

It is **not** called directly by user code. It is invoked indirectly when an external piece of code
calls `seq.start(some_sequencer)`. UVM's `start()` does the bookkeeping (sequencer setup,
`pre_start`, `pre_body`, etc.) and then calls `body()`.

### Call flow (skip ahead to §10 for the full lifecycle)

```
user code: seq.start(sqr);
            │
            ▼
   uvm_sequence_base::start(sqr)
            │
            ▼
   pre_start()          ← user hook
   pre_body()           ← user hook (if not nested)
   body()               ← your code
   post_body()          ← user hook (if not nested)
   post_start()         ← user hook
```

### Why is it a `task` and not a `function`?

Because stimulus generation **consumes simulation time**. `start_item` blocks until the sequencer
grants access; `finish_item` blocks until the driver is done. SystemVerilog requires that any code
which can consume time live inside a `task`, not a `function`. So `body()` *must* be a task.

If you accidentally write `virtual function void body();` (using `function`), the compile may even
succeed (because the base class declares it as task — your override is a different signature) but
the override will not happen and your stimulus will silently never run. Classic interview trap.

> **Interview-grade answer:**
>
> *"`body()` is the override hook called by `start()` after the lifecycle pre-hooks run. It's a
> `task` because sequence-to-driver handoff blocks on the sequencer, which consumes simulation
> time. Beginners sometimes write it as a `function` — that compiles but does not override the
> base method, leaving `body()` empty and the test silently passes with no stimulus."*

---

## 6. `start_item` / `finish_item` — The Handshake With the Sequencer

This is the **canonical pattern** that appears in almost every sequence in the file. Look at line
35-48 (`i2c_single_write_seq.body()`):

```systemverilog
task body();
  i2c_seq_item item = i2c_seq_item::type_id::create("single_write_item");
  start_item(item);
  if (!item.randomize() with {
    addr       == local::addr;
    dir        == DIR_WRITE;
    num_data   == 1;
    data[0]    == local::data;
    start_cond == 1;
    stop_cond  == 1;
    rep_start  == 0;
  }) `uvm_fatal("SEQ", "Randomization failed in i2c_single_write_seq")
  finish_item(item);
endtask
```

Five lines. Memorize them. They are 80% of UVM stimulus generation.

### Step-by-step semantics

| Step | Code | What happens under the hood |
|---|---|---|
| 1. Create | `i2c_seq_item::type_id::create(...)` | Factory allocates a fresh item object |
| 2. Request | `start_item(item)` | Sequence sends `wait_for_grant` request; **blocks** until sequencer grants |
| 3. Randomize | `item.randomize() with { ... }` | Fields are computed legally |
| 4. Finish | `finish_item(item)` | Item put on TLM `seq_item_export`; driver calls `get_next_item`; blocks until `item_done` |

The **two blocking points** are why `body()` must be a task.

### Why is randomization between `start_item` and `finish_item`?

Because of **late randomization**. The sequencer might have arbitrated between multiple sequences
and decided which gets to go next. By randomizing AFTER the grant, your item reflects the actual
moment-in-time conditions, including any `pre_do` callbacks the driver might run on the sequencer
(rare in modern code, but the architecture allows it).

If you randomize *before* `start_item`, the constraints might be stale by the time the driver picks
up the item. For deterministic single-sequence tests this rarely matters. For multi-sequence
environments with priority/arbitration, it matters a lot.

### Five-step pattern, in words

> "Create the item, ask the sequencer for the floor, randomize the values, hand the item over."

### A diagram of one handshake cycle

```
SEQUENCE                           SEQUENCER                       DRIVER
   │                                  │                              │
   │ start_item(req) ─── wait_for_grant ──►                          │
   │                                  │                              │
   │                                  │     (arbitration logic)      │
   │                                  │                              │
   │ ◄────────── grant ───────────────│                              │
   │                                  │                              │
   │ req.randomize() with {...}       │                              │
   │                                  │                              │
   │ finish_item(req) ────► send_request                             │
   │                                  │                              │
   │                                  │ ◄── get_next_item() ─────────│
   │                                  │                              │
   │                                  │     ───► req                 │
   │                                  │                              │
   │                                  │                  (drive pins) │
   │                                  │                              │
   │                                  │ ◄── item_done() ─────────────│
   │                                  │                              │
   │ ◄──── finish_item returns ───────│                              │
   │                                  │                              │
```

### The number-one beginner bug

**Forgetting to set the sequencer before calling `start_item`.**

If you do:

```systemverilog
my_seq seq = my_seq::type_id::create("seq");
seq.body();   // ❌ WRONG — body() bypasses sequencer setup
```

You'll crash at `start_item` with a null pointer dereference, because `start_item` reaches into
`m_sequencer` to call `wait_for_grant`, and `m_sequencer` was never set.

**Correct invocation:**

```systemverilog
my_seq seq = my_seq::type_id::create("seq");
seq.start(env.agent.sequencer);  // start() sets m_sequencer for you
```

Or, if you're starting from inside another sequence (sub-sequence):

```systemverilog
child_seq sub = child_seq::type_id::create("sub");
sub.start(m_sequencer);  // pass through the parent's sequencer
```

> **Interview-grade answer:**
>
> *"`start_item` and `finish_item` are the two-phase handshake between a sequence and a sequencer.
> `start_item` issues `wait_for_grant` and blocks until the sequencer arbitrates and grants the
> sequence floor. Then you randomize the item — late randomization lets you reflect any
> just-before-driver state. `finish_item` puts the item on the TLM export and blocks until the
> driver calls `item_done`. Both must be inside a task because they consume simulation time. The
> most common bug is calling `body()` directly instead of `start()` — that leaves `m_sequencer`
> null and crashes the first `start_item`."*

---

## 7. Inline Randomization — `randomize() with { … }`

Every non-trivial sequence in this file uses **inline constraints** to pin down item fields.
Example from line 38-46:

```systemverilog
if (!item.randomize() with {
  addr       == local::addr;
  dir        == DIR_WRITE;
  num_data   == 1;
  data[0]    == local::data;
  start_cond == 1;
  stop_cond  == 1;
  rep_start  == 0;
}) `uvm_fatal("SEQ", "Randomization failed in i2c_single_write_seq")
```

### Anatomy

- `item.randomize()` triggers the constraint solver on the **rand** fields of `item`.
- The `with { … }` block **adds extra constraints** that exist only for this call.
- These extra constraints are AND-ed with the class's existing constraints.
- The return is a `bit` — **1 if solver succeeded, 0 if no legal solution exists**.

### Why the `if (!item.randomize() with { … })` pattern?

Three reasons:

1. **Randomization can fail.** If the constraints conflict (e.g., `data == 8'hA5; data == 8'h5A;`),
   the solver gives up and returns 0. You *must* check this. Silent failure leaves the item with
   stale or default values, and you debug for hours.
2. **`` `uvm_fatal`` halts the simulation.** Sequence failures are usually unrecoverable in this
   codebase. Using `uvm_fatal` makes debugging easier — it stops at the failure point.
3. **Some sequences use `` `uvm_warning`` + `continue`** instead (e.g., `i2c_addr_sweep_seq` at
   line 416). That's a softer policy — *try the next address even if this one fails*. Choose the
   policy that matches your scenario.

### The `local::` prefix on the right-hand side

Look closely at line 39: `addr == local::addr;`

This is **scope resolution**, and it's *not optional* — it's defensive and necessary. I cover this
in detail in §8 because it's a frequent interview pitfall.

### Hierarchical constraints get AND-ed

The item class probably has class-level constraints like `default_trans_c` (referenced at line
620: `seg0.default_trans_c.constraint_mode(0);`). These are **always-on** unless you turn them off
with `constraint_mode(0)`.

`deep_rep_start_sequence` (line 605) disables `default_trans_c` per-item because that constraint
hard-codes `start_cond=1; stop_cond=1; rep_start=0`, which doesn't fit middle segments of a
repeated-START chain.

> **Interview-grade answer:**
>
> *"The `randomize() with { … }` block adds inline constraints to whatever the class already has.
> The randomization call returns 0 on infeasibility, which we always check with `if (!…)` followed
> by `` `uvm_fatal`` — silent randomization failure is a top-five debug-time sink. When inline
> constraints conflict with class constraints, use `constraint_mode(0)` to disable specific
> class-level constraints before randomizing, as `deep_rep_start_sequence` does to allow
> non-default values of `start_cond` and `stop_cond` in middle segments."*

---

## 8. The `local::` Scope Resolution Trick

### The problem

Inside `randomize() with { … }`, identifiers on either side of `==` can refer to *either* a field
of the item being randomized *or* a local variable of the surrounding sequence. SystemVerilog's
default lookup rule is:

> *"In a `with` block, an identifier on either side first resolves to a field of the randomized
> object, then to the enclosing scope."*

This is called **field-of-object priority**. It's convenient when you want `addr == 0x50` to refer
to the item's `addr`. It's **catastrophic** when both the sequence and the item have fields of the
same name.

### Concrete scenario

The sequence `i2c_single_write_seq` (line 26-27) declares:

```systemverilog
rand logic [6:0] addr;
rand logic [7:0] data;
```

And the item `i2c_seq_item` also has `addr` and `data`. When you write:

```systemverilog
if (!item.randomize() with {
  addr == addr;       // ← which addr is which?
})
```

Both `addr`s resolve to the item's `addr`. The constraint becomes `addr == addr` — a tautology that
permits **any** value. Your carefully randomized sequence-level `addr` is ignored. You think you're
driving address 0x50 but the solver picks 0x37.

### The fix: `local::`

```systemverilog
if (!item.randomize() with {
  addr == local::addr;   // ← right-hand side resolves to sequence scope
})
```

`local::name` explicitly says *"this identifier is in the enclosing local scope (the sequence), not
a field of the randomized object."* This pins down the lookup and removes ambiguity.

You see `local::addr`, `local::data`, `local::burst_len`, `local::stretch_cycles`, `local::wrong_addr`
throughout the file. Every sequence author who's been burned by this bug writes `local::` by
reflex. You should too.

### Alternative: name the sequence fields differently

If you name the sequence field `m_addr` instead of `addr`, no shadowing happens:

```systemverilog
rand logic [6:0] m_addr;
…
if (!item.randomize() with { addr == m_addr; })   // unambiguous
```

This is the cleaner naming convention but requires discipline. Most codebases use `local::` and
keep names identical for readability.

> **Interview-grade answer:**
>
> *"Inside `randomize() with`, unqualified names resolve to fields of the randomized object first.
> If the sequence and the item have a field with the same name — like `addr` — the inline
> constraint `addr == addr` is a self-tautology and your sequence-side value is silently dropped.
> The fix is `local::addr`, which forces the right-hand side to resolve in the enclosing sequence
> scope. This bug is invisible at compile time; it produces wrong addresses at runtime and
> burns a half-day of debug. Every sequence in our project uses `local::` defensively."*

---

## 9. `` `uvm_do`` Macros — What They Expand To

You will see code in legacy testbenches (or on EDA Playground tutorials) that looks like:

```systemverilog
task body();
  `uvm_do(req)
endtask
```

or

```systemverilog
task body();
  `uvm_do_with(req, { addr == 7'h50; })
endtask
```

These are **macros**. Let me expand them.

### `` `uvm_do(req)``

Roughly expands to:

```systemverilog
begin
  req = i2c_seq_item::type_id::create("req");
  start_item(req);
  if (!req.randomize())
    `uvm_warning("RNDFLD", "randomize failed")
  finish_item(req);
end
```

### `` `uvm_do_with(req, { CONSTR })``

Expands to the same thing but with `req.randomize() with { CONSTR }`.

### `` `uvm_create(req)`` + `` `uvm_send(req)``

A 2-step version that lets you do extra setup between create and send:

```systemverilog
`uvm_create(req)            // → req = i2c_seq_item::type_id::create("req");
// hand-set fields here, no randomize
`uvm_send(req)              // → start_item(req); finish_item(req);
```

### Why this file does NOT use `` `uvm_do`` macros

Look at the entire `i2c_sequences.sv`: **zero** `` `uvm_do`` macros. Every sequence writes
`create + start_item + randomize + finish_item` explicitly. This is **modern UVM style** for
three reasons:

1. **Visibility.** A future reader sees exactly what happens, no macro magic to chase.
2. **Error handling.** The explicit form lets you write `if (!item.randomize()) `uvm_fatal(...)`,
   which is louder than the macro's silent `` `uvm_warning``.
3. **Debugger-friendly.** Step-into in a waveform debugger works; macros sometimes don't expand
   well in tool output.

### When you SHOULD know the macros

- **Legacy code.** Lots of working UVM out there uses them. You will read them.
- **Verification IP (VIP) vendor docs.** Cadence/Synopsys examples often use macros.
- **Interview gotcha.** "Walk me through what `` `uvm_do`` does." Senior interviewers test if you
  can read macros, not just write modern code.

### Modern equivalent — what this file uses

```systemverilog
i2c_seq_item req = i2c_seq_item::type_id::create("req");
start_item(req);
if (!req.randomize() with { … }) `uvm_fatal(...)
finish_item(req);
```

Five lines instead of one. But the five lines are *grep-able*, *debuggable*, and *teachable*. Worth
the verbosity.

> **Interview-grade answer:**
>
> *"`` `uvm_do(req)``, `` `uvm_do_with(req, {…})``, `` `uvm_create``, and `` `uvm_send`` are
> compatibility macros that wrap the create-randomize-send handshake. Modern UVM style — what our
> project uses — writes the handshake explicitly: factory create, `start_item`, `randomize() with`
> wrapped in a failure check, then `finish_item`. The explicit form is more readable, lets us
> escalate randomization failures to `` `uvm_fatal``, and is debugger-friendly. The macros are
> still common in legacy code and vendor VIP, so I read them but rarely write them."*

---

## 10. Lifecycle Hooks — `pre_body`, `post_body`, `pre_start`, `post_start`

When `seq.start(sqr)` runs, UVM walks the following hooks. None of the sequences in this file
override them — they all just override `body()`. But you need to know they exist because:

- **Interview question** ("In what order are sequence callbacks invoked?").
- **Real usage** — when you add UVM objections or pre-test setup, you'll need them.

### Full execution order during `start()`

```
seq.start(sqr, parent_sequence, priority, call_pre_post)
   │
   ▼
1. set m_sequencer = sqr
2. pre_start()                ← always called
3. pre_body()                 ← ONLY if (call_pre_post && parent_sequence == null)
4. body()                     ← your override
5. post_body()                ← ONLY if (call_pre_post && parent_sequence == null)
6. post_start()               ← always called
```

### Why the "ONLY if parent_sequence is null" trick on pre_body/post_body?

Because when a **parent sequence** starts a **child sequence**, you usually don't want the child's
`pre_body`/`post_body` to fire (those are typically used to raise/drop objections, and the parent
already handled that for the whole hierarchy). Only the **top-level** sequence gets pre_body/
post_body called.

`pre_start` and `post_start`, by contrast, **always** fire — they're for setup that must happen
regardless of nesting (like recording the start time of this sequence in a tracker).

### Typical pre_body usage

```systemverilog
task pre_body();
  if (starting_phase != null)
    starting_phase.raise_objection(this);
endtask

task post_body();
  if (starting_phase != null)
    starting_phase.drop_objection(this);
endtask
```

This is the **canonical objection pattern** for sequences run as `default_sequence` for a phase
(set via `uvm_config_db`). Without raising the objection, the phase ends before your sequence
finishes — your stimulus is truncated.

In **this codebase**, the test class raises objections directly in `run_phase`, so the sequences
themselves don't need to. Either pattern is valid; you must know which one your environment uses.

### `pre_do` / `mid_do` / `post_do` — even deeper hooks

These fire on **each individual item**, between `start_item` and `finish_item`, on the sequencer:

```
start_item(item)
  → pre_do(is_item=1)        (sequence override hook)
  → mid_do(item)             (sequence override hook)
finish_item(item)
  → post_do(item)            (sequence override hook)
```

Almost no project uses these. They're rare. Mention them only if asked.

> **Interview-grade answer:**
>
> *"`start()` invokes `pre_start`, then conditionally `pre_body`, then `body`, then conditionally
> `post_body`, then `post_start`. The pre_body/post_body conditional fires only when this sequence
> is the top-level — i.e., parent is null — so nested child sequences don't double-raise
> objections. The typical objection pattern lives in pre_body/post_body, while logging and timing
> belong in pre_start/post_start. There are also per-item hooks — pre_do, mid_do, post_do — that
> fire between start_item and finish_item, but they're rarely used in modern projects."*

---

## 11. Sequence Walkthroughs — One by One

Now we go through every sequence class in the file. I'll give each one a snapshot, the scenario
it tests, and the gotchas.

### 11.1 `i2c_single_write_seq` (lines 22-50)

```systemverilog
class i2c_single_write_seq extends i2c_base_seq;
  `uvm_object_utils(i2c_single_write_seq)
  rand logic [6:0] addr;
  rand logic [7:0] data;
  constraint default_addr_c { addr == 7'h50; }
  ...
  task body();
    i2c_seq_item item = i2c_seq_item::type_id::create("single_write_item");
    start_item(item);
    if (!item.randomize() with {
      addr == local::addr; dir == DIR_WRITE; num_data == 1;
      data[0] == local::data; start_cond == 1; stop_cond == 1; rep_start == 0;
    }) `uvm_fatal(...)
    finish_item(item);
  endtask
endclass
```

**Scenario:** One START, one address byte (write), one data byte, one STOP. The simplest legal I2C
transaction.

**On the wire:**
```
S | 0x50 W | A | D | A | P
```
(`S`=START, `0x50 W`=slave address with W bit=0, `A`=ACK from slave, `D`=one data byte,
`P`=STOP)

**Why `addr` and `data` are `rand` even though `default_addr_c` pins addr to 0x50:**
- The fields are randomized at the sequence level (in case the test layer randomizes the sequence
  before starting).
- `default_addr_c` is overridable — a test can call `seq.default_addr_c.constraint_mode(0)` and
  pick a different address.

**Gotcha:** `data` is declared `rand` but has no class-level constraint, so on randomization of the
sequence itself, `data` is uniformly random. Then it's pinned to `data[0] == local::data` in the
inline constraint. **Net effect:** `data` is random at sequence-randomize time, then locked at
item-randomize time. If your test calls `seq.randomize()` and then `seq.start(sqr)`, `data` is
random. If your test sets `seq.data = 8'hA5` directly and calls `seq.start(sqr)`, `data` is fixed.
Both flows work.

### 11.2 `i2c_single_read_seq` (lines 52-78)

Symmetric to `i2c_single_write_seq` but with `dir == DIR_READ`.

**On the wire:**
```
S | 0x50 R | A | D | NA | P
```
(`R`=read bit; the master receives one byte, then sends **NACK** to terminate — this is standard
I2C: the last byte read is always NACK-ed by the master to tell the slave "stop sending.")

**Note:** This sequence doesn't expose the NACK-after-last-byte logic explicitly — that's baked
into the driver/master controller based on the item's `num_data` count. The sequence only describes
*what* to do, not *how*.

### 11.3 `i2c_burst_write_seq` / `i2c_burst_read_seq` (lines 80-138)

```systemverilog
rand int burst_len;
constraint burst_len_c { burst_len inside {[1:32]}; }
```

**Scenario:** Multi-byte transfer in one I2C transaction (one START, one address, N data bytes,
one STOP). `burst_len` randomizes 1-32 bytes.

**On the wire (write):**
```
S | 0x50 W | A | D0 | A | D1 | A | … | DN-1 | A | P
```

**Why `burst_len inside {[1:32]}`:** A reasonable practical cap — most I2C peripherals (EEPROMs,
sensors) accept page writes of 16/32 bytes. Going beyond becomes pathological and the slave NACKs.
For coverage, you'd want at least one test with `burst_len = 1` (smallest), `burst_len = 32`
(largest), and random in between.

**Interview pitfall:** "Why 32?" Don't say "arbitrary." Say *"matches typical EEPROM page size; can
parameterize for larger devices."*

### 11.4 `i2c_write_read_seq` (lines 140-182)

Two **separate** transactions back-to-back, with a `#200` time gap between them.

```systemverilog
task body();
  // Write transaction (full S … P)
  …
  finish_item(wr_item);

  #200;   // ← bus idle gap

  // Read transaction (full S … P)
  …
  finish_item(rd_item);
endtask
```

**Scenario:** Write a byte, wait, read it back. The `#200` makes the bus idle long enough that
the slave/monitor sees two distinct transactions, not a repeated-START.

**Why this is NOT a repeated-START:** Each transaction has its own `start_cond=1` and
`stop_cond=1`. There's a STOP between them. `rep_start_seq` (next) is what does the real
rep-start.

**Gotcha:** `#200` is in **time units** — depends on `timeunit/timeprecision` set in the package
or testbench top. Usually 1 ns precision, so `#200` ≈ 200 ns ≈ 10 system clocks at 50 MHz. Tiny
idle gap. The slave should be fine with it (I2C bus-free time per spec is t_BUF ≥ 4.7 µs in
Standard Mode — this `#200` violates spec but might pass in simulation). **Worth flagging in a
code review.**

### 11.5 `i2c_rep_start_seq` (lines 184-224)

The repeated-START scenario.

```systemverilog
wr_item: start_cond == 1, stop_cond == 0, rep_start == 0;   // first segment, no STOP
rd_item: start_cond == 0, stop_cond == 1, rep_start == 1;   // second segment, REP_START, STOP
```

**Scenario:** Write to the slave, then *without releasing the bus*, issue a REP_START and read.

**On the wire:**
```
S | 0x50 W | A | D | A | Sr | 0x50 R | A | D | NA | P
```
`Sr` = repeated START.

**Why repeated-START exists in I2C:** Two reasons.

1. **Atomicity.** The master never lets go of the bus between write-phase and read-phase. Other
   masters cannot interrupt. Critical for "write register address, then read register data"
   patterns common in EEPROMs and sensors.
2. **Direction change.** I2C's address byte has the R/W bit baked in. To switch from writing to
   reading the same slave, you must re-send the address byte with R bit flipped — and the
   re-sending is preceded by REP_START (not full STOP+START).

**Coverage note:** This sequence hits the **2-segment** rep-start case. `deep_rep_start_sequence`
(11.18) hits the **4-segment** case for coverage point CG11.

### 11.6 `i2c_nack_addr_seq` (lines 226-252)

**Scenario:** Address a slave that *doesn't exist* — expect a NACK on the address byte.

```systemverilog
rand logic [6:0] wrong_addr;
constraint wrong_addr_c { wrong_addr inside {[7'h08:7'h77]}; wrong_addr != 7'h50; }
```

The constraint excludes:
- **Reserved addresses** below 0x08 and above 0x77 (per NXP I2C spec).
- **The DUT address** 0x50, because we want a *guaranteed NACK*.

**Wire behavior:** Master sends `S | wrong_addr W | NA | P` (master sees NACK, immediately
issues STOP). The DUT-side monitor should observe no transaction starting (no slave with that
address responded). The scoreboard checks "no expected transaction reached the slave."

**Verification value:** Ensures the master correctly detects address-NACK and aborts. If the master
ignored the NACK and tried to send data anyway, you have a protocol-violation bug.

### 11.7 `i2c_clock_stretch_seq` (lines 254-284)

**Scenario:** Write a byte while the slave performs *clock stretching* — holding SCL low to pause
the master mid-transaction.

```systemverilog
rand logic [15:0] stretch_cycles;
constraint stretch_cycles_c { stretch_cycles inside {[16'd50 : 16'd200]}; }
```

**Important gotcha:** This sequence on its own does **nothing special on the master side** — the
master sequence is just a standard write. The clock-stretching behavior comes from a **separate
slave-control sequence** (`i2c_slave_stretch_ctrl_seq`, §11.15) that pre-configures the slave
to stretch.

So the *real* scenario is a **virtual sequence** that:
1. Starts `i2c_slave_stretch_ctrl_seq` on the slave ctrl sequencer to enable stretching.
2. Then starts `i2c_clock_stretch_seq` on the master sequencer to drive the write.

The `stretch_cycles` field of this sequence is **unused inside `body()`** — the value isn't
passed to the slave (since the slave-side sequence is started separately). This is a **latent
bug or a coupling gap** worth flagging in code review.

**Better design:** Either (a) remove `stretch_cycles` from this sequence since it doesn't drive
anything, or (b) make this a true virtual sequence that also starts the slave ctrl sequence.

### 11.8 `i2c_data_nack_seq` (lines 286-314)

**Scenario:** Write a byte; the slave NACK-s the data byte (not the address).

Like the clock-stretch sequence, this is **a write sequence on the master side**. The actual
NACK behavior comes from `i2c_slave_force_nack_seq` (§11.14) which arms the slave to NACK.

**Wire behavior:** `S | 0x50 W | A | D | NA | P` — slave ACKs the address but NACKs the data.

**Master expected behavior:** On data NACK, the master should issue STOP (don't keep transmitting
into a slave that's refused).

### 11.9 `i2c_bus_free_seq` (lines 316-344)

Looks identical to `i2c_single_write_seq`. What's different?

The name *suggests* this is for testing **bus-free time** (t_BUF, the minimum idle time between
STOP and next START). But there's no special `#delay` or timing constraint in `body()`. The
sequence body is plain.

**Interpretation:** The bus-free behavior is enforced by the **master controller's internal
counters**, not the sequence. The sequence simply runs a normal write; the master controller
ensures t_BUF is honored before issuing the next START. The test harness might run this sequence
back-to-back-to-back to *exercise* the t_BUF logic.

**Honest assessment:** This sequence appears redundant with `i2c_single_write_seq`. The test
intent is captured in the *name* but not in the *code*. **Code review comment:** add a comment
explaining what this sequence is meant to verify, or merge it with `i2c_single_write_seq`.

### 11.10 `i2c_random_seq` (lines 346-370)

```systemverilog
rand int num_txns;
constraint num_txns_c { num_txns inside {[20:100]}; }

task body();
  for (int i = 0; i < num_txns; i++) begin
    i2c_seq_item item = i2c_seq_item::type_id::create(...);
    start_item(item);
    if (!item.randomize()) begin
      `uvm_error(...)
      continue;
    end
    finish_item(item);
  end
endtask
```

**Scenario:** 20-100 fully-random transactions. Lets the item's own class constraints pick
addr/data/dir/start/stop/rep_start.

**Why `continue` on randomize failure instead of `` `uvm_fatal``?**
Because in random regression, occasional infeasible randomizations are expected (e.g., the
combination `rep_start=1 with no prior start_cond=1` may be unsolvable in the current state).
We don't want one failed item to halt a 100-txn run. We log it as `` `uvm_error`` (counts
toward test failures but doesn't crash) and move on.

**This is the workhorse coverage-driven sequence.** Most random regression runs use this.

### 11.11 `i2c_stress_seq` (lines 372-394)

Same shape as `i2c_random_seq`, but `num_txns = 1000` (fixed, not random).

**Scenario:** Long-duration soak test. Used in nightly regression to hammer the DUT for
thousands of transactions and catch state-machine bugs that only appear after many state
transitions.

**Why fixed 1000 instead of `rand`:** Predictability. Regression-time budget is tighter when
the count is known.

**Interview note:** A senior would also add a *time budget* (`forever begin … #1us; end` with a
test-level timeout) instead of a fixed count, because "1000 transactions" doesn't directly map
to wall-clock simulation time.

### 11.12 `i2c_addr_sweep_seq` (lines 396-423)

```systemverilog
for (int a = 8; a <= 16'h77; a++) begin
  ...
  if (!item.randomize() with {
    addr == a[6:0]; dir == DIR_WRITE; …
  }) begin
    `uvm_warning(...)
    continue;
  end
  ...
end
```

**Scenario:** Address sweep over the valid I2C 7-bit address range (0x08 to 0x77). For each
address, run a write transaction.

**Why 0x08 to 0x77:** Skips reserved addresses (per NXP I2C-bus specification UM10204):
- 0x00-0x07: reserved (general call, CBUS, etc.)
- 0x78-0x7F: reserved (10-bit addressing, high-speed master code)

**Why warning instead of fatal on rand failure:** Same reasoning — sweep should continue
past one bad address. Use `` `uvm_warning`` because failure here is mild (just skip an addr).

**Coverage value:** Hits the `addr_cg` coverpoint with bins covering low/mid/high address ranges.

**Bug spot:** Loop variable `a` is declared `int` (32 bits, signed). At `a == 16'h77` it's fine.
The line `addr == a[6:0]` slices the lower 7 bits — safe. But if `a` ever rolls over (it
can't here, bounded by `a <= 16'h77`), behavior would be undefined. Defensive coding: declare
`a` as `logic [6:0]` from the start. Minor stylistic improvement.

### 11.13 `i2c_data_pattern_seq` (lines 425-474)

Pushes 20 specific 8-bit patterns into a queue, then writes each as a 1-byte transaction.

**Patterns covered:**
| Pattern | Purpose |
|---|---|
| 0x00, 0xFF | All zeros / all ones — extreme corner cases |
| 0xAA, 0x55 | Alternating bits — toggles SDA every bit, stress for setup/hold |
| 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80 | Walking 1s — exercises each bit position individually |
| 0xFE, 0xFD, 0xFB, 0xF7, 0xEF, 0xDF, 0xBF, 0x7F | Walking 0s — each bit zero in turn |

**This is classic directed coverage stimulus.** Random tests might miss specific bit patterns;
walking-1s and walking-0s guarantee each bit is exercised. Standard practice for verifying serial
data paths.

**Interview-grade comment:** *"The walking-1s and walking-0s patterns are inherited from
hardware-test methodology (memory testing, JTAG boundary scan). They efficiently exercise each
bit independently and catch stuck-at faults that random patterns may not."*

### 11.14 `i2c_slave_force_nack_seq` (lines 476-496)

**This is the first sequence that produces a DIFFERENT item type.**

```systemverilog
class i2c_slave_force_nack_seq extends uvm_sequence #(i2c_slave_ctrl_item);
```

Note `#(i2c_slave_ctrl_item)`, **not** `#(i2c_seq_item)`. So this sequence runs on the **slave
control sequencer**, not the master sequencer.

**Scenario:** Arm the slave so its driver will NACK the next data byte.

```systemverilog
ctrl.force_nack_off_c.constraint_mode(0);    // disable the default "don't force nack" rule
if (!ctrl.randomize() with {
  stretch_en      == 1'b0;
  stretch_cycles  == 16'd0;
  force_data_nack == 1'b1;
}) ...
```

**Why disable `force_nack_off_c`:** The slave ctrl item has a default constraint that says
"don't force NACK" (so normal sequences don't accidentally inject NACKs). To override, we
disable that constraint before randomizing.

**Pairing with master-side sequence:** A test that wants "force data NACK" would:
1. Start `i2c_slave_force_nack_seq` on slave ctrl sequencer.
2. Start `i2c_data_nack_seq` (or any write seq) on master sequencer.

The orchestration belongs in a **virtual sequence** (which this file doesn't define — see Action
Items).

### 11.15 `i2c_slave_stretch_ctrl_seq` (lines 498-524)

Similar to `i2c_slave_force_nack_seq` but configures clock stretching.

```systemverilog
rand logic [15:0] stretch_cycles;
constraint stretch_cycles_c { stretch_cycles inside {[16'd50 : 16'd200]}; }

task body();
  ...
  ctrl.stretch_en_off_c.constraint_mode(0);
  if (!ctrl.randomize() with {
    stretch_en      == 1'b1;
    stretch_cycles  == local::stretch_cycles;
    force_data_nack == 1'b0;
  }) ...
endtask
```

Note the `local::stretch_cycles` — same scope-resolution defensiveness as the master sequences.

**Pair with master `i2c_clock_stretch_seq`** in a virtual sequence to get the full scenario.

### 11.16 `i2c_sequential_seq` (lines 526-553)

```systemverilog
for (int i = 0; i < num_txns; i++) begin
  ...
  if (!item.randomize() with {
    addr == local::addr;
    dir  == ((i % 2 == 0) ? DIR_WRITE : DIR_READ);
    ...
  }) ...
end
```

**Scenario:** 5 transactions, alternating write/read/write/read/write.

**Why interesting:** Tests that the DUT correctly transitions between consecutive read and write
transactions. Each is a full S…P, no rep-start.

**Coverage hit:** Likely the `dir_alternation` coverpoint or similar.

### 11.17 `arb_lost_sequence` (lines 562-586)

**This sequence does NOT extend `i2c_base_seq`** — it extends `uvm_sequence #(i2c_seq_item)`
directly. Slight inconsistency in style; functionally identical.

**Scenario:** Master tries to write 0xAA; another master (simulated by slave driver in
"compete mode") pulls SDA low at a bit where this master expects high → arbitration loss.

```systemverilog
data[0] == 8'hAA;  // pattern that will lose at the chosen bit
```

`0xAA = 1010_1010` — a `1` bit appears at MSB. If the competing master tries to send `0x00`
(all zeros), then at the very first bit, this master would drive SDA high but observe SDA low
(competing master pulls down). Per I2C spec, the master that observes SDA != its drive loses
arbitration and must immediately stop driving.

**Expected DUT behavior:** Master detects mismatch at STATE_TX_BIT, asserts `arb_lost`, aborts
transaction cleanly **without issuing STOP** (the winning master still owns the bus).

**Comment in the file (line 558-561):**
> *"The master under test should detect arb_lost during STATE_TX_BIT and abort the transaction
> cleanly without producing a STOP."*

This is the **most architectural** sequence in the file — it tests bus-level behavior, not just
the master's solo state machine.

### 11.18 `deep_rep_start_sequence` — the multi-segment masterpiece (lines 605-675)

The largest and most interesting sequence in the file. Walk through every line carefully.

```systemverilog
class deep_rep_start_sequence extends i2c_base_seq;
  `uvm_object_utils(deep_rep_start_sequence)
  logic [6:0] addr = 7'h50;
  ...
  task body();
    i2c_seq_item seg0, seg1, seg2, seg3;

    // Segment 0: fresh START, write, no STOP
    seg0 = i2c_seq_item::type_id::create("seg0");
    seg0.default_trans_c.constraint_mode(0);    // ← KEY LINE
    start_item(seg0);
    if (!seg0.randomize() with {
      addr == local::addr; dir == DIR_WRITE; num_data == 1;
      start_cond == 1; stop_cond == 0; rep_start == 0;
    }) ...
    finish_item(seg0);

    // Segment 1: REP_START, write, no STOP
    seg1 = i2c_seq_item::type_id::create("seg1");
    seg1.default_trans_c.constraint_mode(0);
    start_item(seg1);
    if (!seg1.randomize() with {
      addr == local::addr; dir == DIR_WRITE; num_data == 1;
      start_cond == 0; stop_cond == 0; rep_start == 1;
    }) ...
    finish_item(seg1);

    // Segment 2: REP_START, write, no STOP
    // ... similar to seg1

    // Segment 3: REP_START, read, STOP
    seg3 = i2c_seq_item::type_id::create("seg3");
    seg3.default_trans_c.constraint_mode(0);
    start_item(seg3);
    if (!seg3.randomize() with {
      addr == local::addr; dir == DIR_READ; num_data == 1;
      start_cond == 0; stop_cond == 1; rep_start == 1;
    }) ...
    finish_item(seg3);
  endtask
endclass
```

**Scenario:** 4-segment repeated-START chain.

**On the wire:**
```
S | 0x50 W | A | D | A
Sr | 0x50 W | A | D | A
Sr | 0x50 W | A | D | A
Sr | 0x50 R | A | D | NA | P
```

That's one START at the very beginning, three repeated-STARTs in the middle, and one STOP at the
very end. The DUT's `chain_depth` counter should hit 0, 1, 2, and 3 — covering the
`i2c_rep_depth_cg` coverpoint with bins `no_rep`, `one_rep`, `two_rep`, `deep_rep`.

**Why `constraint_mode(0)` on `default_trans_c`:**

The item class likely has:
```systemverilog
constraint default_trans_c {
  start_cond == 1;
  stop_cond  == 1;
  rep_start  == 0;
}
```

This is a class-level **soft-default** for typical transactions. For middle segments of a
rep-start chain, we need `start_cond=0`, `stop_cond=0`, `rep_start=1` — which **conflicts** with
the default. Solver can't satisfy both → randomization fails.

Disabling `default_trans_c` per-item via `constraint_mode(0)` removes the conflict. After that,
the inline `with` constraints pin everything down.

**Coverage value (from the comment block lines 588-604):**

| Cover Group | What it hits |
|---|---|
| CG11 (`i2c_rep_depth_cg`) | Bins 0, 1, 2, 3 — full depth coverage |
| CG14 (RepStart × Dir) | WR→WR→WR→RD pattern after rep-start |
| CG16 (Protocol × Dir) | `no_stop+write`, `has_stop+read` cells |

**One-test coverage closure** — this is exactly the kind of sequence senior verification engineers
write *after* analyzing a coverage hole. It's directed-randomized, surgical, and documented.

> **Interview-grade comment:**
>
> *"`deep_rep_start_sequence` is an example of coverage-closure stimulus. After random regression
> hit a wall at ~92% functional coverage, I analyzed the holes and found the `i2c_rep_depth_cg`
> bin `deep_rep` (depth ≥ 3) was unhit. This sequence drives a 4-segment chain in a single run,
> closing that bin plus two related coverage groups. The trick is disabling the item's
> `default_trans_c` constraint with `constraint_mode(0)`, because that default pins start_cond/
> stop_cond to values that conflict with middle-segment rep-start."*

---

## 12. Sequence Layering — Parent Calls Child

None of the sequences in this file currently start child sequences. But the pattern is
foundational, and you'll be asked about it. Here's how it works.

### Pattern: parent starts child

```systemverilog
class my_compound_seq extends i2c_base_seq;
  `uvm_object_utils(my_compound_seq)
  function new(string name = "my_compound_seq"); super.new(name); endfunction

  task body();
    i2c_single_write_seq child_wr;
    i2c_single_read_seq  child_rd;

    child_wr = i2c_single_write_seq::type_id::create("child_wr");
    child_wr.data = 8'hA5;
    child_wr.start(m_sequencer, this);    // ← starts child ON SAME sequencer

    #1us;

    child_rd = i2c_single_read_seq::type_id::create("child_rd");
    child_rd.start(m_sequencer, this);    // ← parent is `this`
  endtask
endclass
```

### Key API: `seq.start(sequencer, parent_sequence, priority, call_pre_post)`

| Arg | Meaning |
|---|---|
| `sequencer` | Which sequencer to run on (usually `m_sequencer` to inherit parent's) |
| `parent_sequence` | Pointer to parent — defaults to `null` |
| `priority` | Sequencer arbitration priority (default = -1, which means inherit) |
| `call_pre_post` | If 1, call pre_body/post_body. If 0, skip them (use for nested seqs) |

When `parent_sequence != null`, UVM **skips pre_body/post_body** in the child by default (since
parent has the floor). This prevents double-objection patterns.

### Why layer sequences?

- **Reusability** — write the smallest meaningful sequence once; compose larger scenarios from it.
- **Abstraction** — a "boot sequence" might call `init_seq`, `config_seq`, `verify_seq` in order;
  each is independent and reusable.
- **Test readability** — `body()` of the parent reads like a test scenario in English.

### What this file is missing

Look at the I2C sequence library again. We have:
- `i2c_clock_stretch_seq` (master side)
- `i2c_slave_stretch_ctrl_seq` (slave side)

These two together form one scenario. **Right now there's nothing that starts both.** The test
must do it. A **virtual sequence** would cleanly layer them:

```systemverilog
class clock_stretch_scenario_vseq extends uvm_sequence;
  `uvm_object_utils(clock_stretch_scenario_vseq)
  i2c_sequencer            master_sqr;
  i2c_slave_ctrl_sequencer slave_sqr;

  task body();
    i2c_slave_stretch_ctrl_seq slave_cfg;
    i2c_clock_stretch_seq      master_drv;

    fork
      begin
        slave_cfg = i2c_slave_stretch_ctrl_seq::type_id::create("slave_cfg");
        slave_cfg.start(slave_sqr, this);
      end
      begin
        #50;   // let slave config land
        master_drv = i2c_clock_stretch_seq::type_id::create("master_drv");
        master_drv.start(master_sqr, this);
      end
    join
  endtask
endclass
```

This is exactly the **action item** for you: create the virtual-sequence layer to compose
existing low-level sequences.

> **Interview-grade answer:**
>
> *"Sequence layering means a parent sequence's `body()` instantiates and starts child sequences
> via `child.start(sequencer, this)`. Passing `this` as parent tells UVM this is a nested call, so
> child pre_body/post_body are skipped — typically meaning the child doesn't try to raise its own
> objections; the parent's objection covers the entire hierarchy. This is the standard reuse
> pattern: small sequences as building blocks, larger sequences composing them, and at the top a
> virtual sequence coordinating multiple sequencers. Our project lacks a virtual sequence layer
> right now — that's an easy upgrade I'm planning."*

---

## 13. Virtual Sequences and `p_sequencer`

### What's a virtual sequence?

A sequence that **starts other sequences on multiple different sequencers**. It doesn't produce
seq_items itself — it orchestrates.

```systemverilog
class my_vseq extends uvm_sequence;     // ← no #(...) — it doesn't send items
  `uvm_object_utils(my_vseq)
  ...
  task body();
    seq_on_master.start(env.master_sqr, this);
    seq_on_slave.start(env.slave_sqr,  this);
  endtask
endclass
```

### Where does it get the sequencer handles from?

Two patterns:

**Pattern A — config_db handles:**
```systemverilog
task body();
  uvm_config_db#(i2c_sequencer)::get(null, get_full_name(), "master_sqr", master_sqr);
  ...
endtask
```

**Pattern B — `p_sequencer` typed to a virtual sequencer:**

The standard pattern. Define a *virtual sequencer* that holds handles to all real sequencers,
then the virtual sequence accesses them via `p_sequencer`.

```systemverilog
class i2c_virtual_sequencer extends uvm_sequencer;
  i2c_sequencer            master_sqr;
  i2c_slave_ctrl_sequencer slave_sqr;
endclass

class my_vseq extends uvm_sequence;
  `uvm_object_utils(my_vseq)
  `uvm_declare_p_sequencer(i2c_virtual_sequencer)  // ← THIS

  task body();
    seq_master.start(p_sequencer.master_sqr, this);
    seq_slave .start(p_sequencer.slave_sqr,  this);
  endtask
endclass
```

### `p_sequencer` vs `m_sequencer`

| Symbol | Type | When useful |
|---|---|---|
| `m_sequencer` | `uvm_sequencer_base` (generic) | Always available, generic type |
| `p_sequencer` | The exact sequencer type | Only after `` `uvm_declare_p_sequencer`` macro |

`m_sequencer` is the **untyped** handle. To call methods or access fields specific to your custom
sequencer, you'd have to cast. `p_sequencer` is the **typed** handle — pre-cast for you by the
macro. Much cleaner.

### `` `uvm_declare_p_sequencer(MY_SEQR_TYPE)`` — what it expands to

```systemverilog
MY_SEQR_TYPE p_sequencer;
virtual function void pre_do(bit is_item);
  if (m_sequencer != null && !$cast(p_sequencer, m_sequencer))
    `uvm_fatal("CASTFL", "Failed to cast m_sequencer to p_sequencer type")
endfunction
```

It declares the typed handle and adds a `pre_do` hook that performs the cast on each item.

### When is `p_sequencer` *required*?

When the sequence needs to:
- Access a config object held in the sequencer.
- Call a custom method on the sequencer (e.g., `m_sequencer.lookup_address(0x50)`).
- Resolve a handle to another sequencer (in virtual-sequence pattern).

For simple sequences that just send items, you never need `p_sequencer`. `m_sequencer` is fine.

> **Interview-grade answer:**
>
> *"`p_sequencer` is the typed handle to the sequence's sequencer, declared by the
> `` `uvm_declare_p_sequencer(TYPE)`` macro. It auto-casts from `m_sequencer` in pre_do. We need
> it when the sequence accesses fields specific to a custom sequencer subtype — typical in
> virtual-sequence patterns where the virtual sequencer holds handles to all real sequencers.
> A virtual sequence parameterized with `` `uvm_declare_p_sequencer(my_vsqr)`` can write
> `p_sequencer.master_sqr` without casting. For plain sequences that only send items, `m_sequencer`
> is enough."*

---

## 14. Sequencer Arbitration — `lock`, `grab`, `priority`, `wait_for_grant`

When **multiple sequences run on the same sequencer concurrently**, UVM has to decide which one
gets to send the next item. This is **sequencer arbitration**. None of the sequences in this file
exercise it (they all run solo), but you must know the mechanism.

### The arbitration cycle

```
sequence A calls start_item(itemA);   // queued
sequence B calls start_item(itemB);   // queued
                                       │
                                       ▼
                       sequencer's arbitration policy picks ONE
                                       │
                       ▼ grant ◄────── the winner
                       │
                       wait_for_grant returns in winner
                       │
                       winner randomizes, calls finish_item
                       │
                       driver consumes the item
                       │
                       next cycle of arbitration
```

### Arbitration policies (`set_arbitration`)

| Policy | Behavior |
|---|---|
| `SEQ_ARB_FIFO` | First come, first served (default) |
| `SEQ_ARB_WEIGHTED` | Random selection weighted by sequence priority |
| `SEQ_ARB_RANDOM` | Random selection, equal weight |
| `SEQ_ARB_STRICT_FIFO` | Strict FIFO regardless of priority |
| `SEQ_ARB_STRICT_RANDOM` | Strict random regardless of priority |
| `SEQ_ARB_USER` | User-defined function decides |

Set via:
```systemverilog
env.agent.sequencer.set_arbitration(SEQ_ARB_WEIGHTED);
```

### Priority

When you call `seq.start(sqr, parent, priority)`, you can specify priority. Higher = preferred
under weighted arbitration. Default is -1 (no priority).

### `lock` — exclusive access (no preemption)

```systemverilog
task body();
  m_sequencer.lock(this);      // ← block other sequences
  ...send items exclusively...
  m_sequencer.unlock(this);    // ← release
endtask
```

Or non-blocking:
```systemverilog
if (m_sequencer.is_locked() == 0)
  m_sequencer.lock(this);
```

**`lock` queues behind existing pending sequences.** It doesn't kick anyone out — it waits its
turn, then takes exclusive ownership until you call `unlock`.

### `grab` — immediate exclusive access (preempts)

```systemverilog
task body();
  m_sequencer.grab(this);     // ← preempts other sequences
  ...
  m_sequencer.ungrab(this);   // ← release
endtask
```

**`grab` jumps the queue.** Even if other sequences have requested the floor, `grab` cuts in
front of them. Use sparingly — it can starve other sequences.

### `wait_for_grant`

The low-level API that `start_item` calls under the hood:
```systemverilog
m_sequencer.wait_for_grant(this);
// ...we now have the floor; randomize and send item
m_sequencer.send_request(this, item);
m_sequencer.wait_for_item_done();
```

`start_item` does the first two steps; `finish_item` does the third.

### When would you use these in I2C?

- **`lock` example:** During a critical config phase, lock the sequencer so random background
  traffic doesn't sneak in.
- **`grab` example:** Inject an emergency abort sequence regardless of pending work.
- **Priority example:** Run a high-priority error-injection sequence interleaved with a
  low-priority random traffic sequence.

> **Interview-grade answer:**
>
> *"Sequencer arbitration is the policy UVM uses when multiple sequences contend for the same
> sequencer. Default is FIFO; you can switch to weighted, random, or user-defined via
> `set_arbitration`. Each sequence has a priority (default -1) used by the weighted policy.
> Two extra controls exist: `lock` for cooperative exclusive access (waits in line, then owns
> the sequencer until `unlock`), and `grab` for preemptive access (jumps the queue). Under the
> hood, `start_item` is a wrapper around `wait_for_grant` + `send_request` + `wait_for_item_done`.
> We don't currently use `lock`/`grab` in our I2C project, but I'd reach for `lock` to protect a
> config phase from background random traffic."*

---

## 15. Sequence IDs and Tracking

Every sequence gets a unique ID assigned by the sequencer when it starts. Used for tracking and
debugging.

### `get_sequence_id()`

```systemverilog
task body();
  `uvm_info("SEQ", $sformatf("My sequence id is %0d", get_sequence_id()), UVM_LOW)
endtask
```

### Items inherit their parent sequence's ID

`item.get_sequence_id()` returns the same ID as the sequence that created it. Useful for
correlating waveform events to source sequence in regression dashboards.

### `set_response_queue_depth()` / response_queue

A sequence can receive responses from the driver via `get_response(rsp)`. Each response goes into
an internal queue sized by `set_response_queue_depth(N)`. Default 8. Going past depth raises an
error.

Not used in this file (sequences are fire-and-forget on the I2C driver), but interview-relevant.

---

## 16. Common Bugs and Interview Traps

### Bug 1 — Calling `body()` directly

```systemverilog
seq.body();   // ❌ WRONG
seq.start(sqr);  // ✅ RIGHT
```

`body()` does not set `m_sequencer`, so the first `start_item` inside dereferences null.

### Bug 2 — Forgetting `local::` and shadowing item fields

Covered in §8. The constraint becomes a tautology, your sequence-level value is ignored.

### Bug 3 — Writing `function` instead of `task` for `body()`

```systemverilog
virtual function void body();   // ❌ does not override the base task
  ...
endfunction
```

Silent failure: stimulus never runs, test passes empty.

### Bug 4 — Forgetting to randomize the item, then it has stale `X`s

```systemverilog
item = i2c_seq_item::type_id::create(...);
start_item(item);
// forgot randomize
finish_item(item);    // item.addr is X, slave NACKs garbage
```

`uvm_do` macros prevent this; explicit code requires discipline.

### Bug 5 — Forgetting `super.new(name)` in constructor

Compile error in UVM 1.2: `super.new must be called`.

### Bug 6 — Forgetting `` `uvm_object_utils``

Runtime error: `type_id::create` returns null. Then constructor crashes.

### Bug 7 — Item's class-level constraints conflict with inline `with`

Solver fails silently → randomize returns 0 → if you forget the `if (!…)` check, your item has
stale or default values, you debug for hours. **Always wrap randomize in failure check.**

### Bug 8 — Reusing the same item handle across iterations

```systemverilog
i2c_seq_item item;
for (int i = 0; i < N; i++) begin
  start_item(item);   // item is still the previous one — fields stale
  ...
end
```

Solve: create a fresh item each iteration. Look at `i2c_random_seq` (line 360) — it creates the
item inside the loop. Correct.

### Bug 9 — Starting a sequence on the wrong sequencer

If `seq` is parameterized `#(i2c_seq_item)` but you `start(env.slave_ctrl_sqr)`, the type mismatch
might compile (depends on hierarchy) but explode at runtime when the driver gets a wrong-typed
item.

### Bug 10 — Running multiple sequences without arbitration in mind

Two sequences both call `start_item` at time 0 — only one wins, the other waits. If you expected
parallel item generation, you'd be confused. Use `fork`-`join` and accept that arbitration is
serial.

---

## 17. Quiz — 20 Questions

Cover the answer section below. Aim for 18/20 to feel solid before interviews.

1. **What is the fundamental difference between a `uvm_sequence` and a `uvm_sequence_item`?**
   Explain in terms of what they do and what state they hold.

2. **What is the *entry point* of a sequence, and what method actually calls it?**
   Why must it be a `task` and not a `function`?

3. **Walk me through what happens between `start_item(item)` and `finish_item(item)` —
   the full handshake with the sequencer and driver.**

4. **In `randomize() with { addr == addr; }`, both `addr`s resolve to the item's `addr`,
   not the sequence's. Why? How do you fix it?**

5. **What does `` `uvm_do(req)`` expand to? Why does modern UVM code prefer the explicit
   form?**

6. **List the lifecycle hooks called by `seq.start(sqr)` in order.**

7. **Why does UVM skip `pre_body`/`post_body` when a parent sequence is non-null,
   but always run `pre_start`/`post_start`?**

8. **Explain `randomize() with { ... }` — what's the return value, what happens if
   constraints conflict, how do you handle failure?**

9. **In a virtual sequence, what's the difference between `m_sequencer` and `p_sequencer`?
   When do you need each?**

10. **Describe the difference between `lock`/`unlock` and `grab`/`ungrab` on a sequencer.
    When would you use each?**

11. **What is `wait_for_grant`? Why is it normally hidden behind `start_item`?**

12. **Why does the project use `local::addr` inside `randomize() with` constraints? What's
    the actual SystemVerilog rule being defended against?**

13. **The `deep_rep_start_sequence` calls `seg0.default_trans_c.constraint_mode(0)` before
    randomizing. Why? What would happen without it?**

14. **You write a sequence whose body is:**
    ```systemverilog
    task body();
      i2c_seq_item item;
      start_item(item);
      finish_item(item);
    endtask
    ```
    **What goes wrong, and at what stage (compile/elab/runtime)?**

15. **A `uvm_sequence` extends `uvm_object`, not `uvm_component`. What's the practical
    consequence for the constructor signature?**

16. **In a multi-master I2C scenario you want to test arbitration loss. Walk me through
    how `arb_lost_sequence` in this file is designed to exercise that — particularly
    why the data byte 0xAA was chosen.**

17. **Design a sequence — in pseudocode or English — that performs a 'page write then
    verify' to an EEPROM: 16-byte write at address 0x50, then 16-byte read at the same
    address, comparing to expected data.**

18. **Design a sequence for the scenario 'master attempts to write to a slave that NACKs
    the address.' How does that interact with the master FSM?**

19. **Design a sequence to exercise clock stretching on the slave side and verify the
    master correctly holds off transmission. Identify which existing sequences need to
    be combined and what's missing.**

20. **You see a sequence in the regression log with `[SEQ] Randomization failed in
    i2c_burst_write_seq` followed by `[UVM_FATAL]`. The constraint is
    `burst_len inside {[1:32]}` and the item class has its own constraint
    `num_data <= 16`. Diagnose the bug.**

---

## 18. Quiz Answers — Senior-Grade With Interview-Grade Callouts

### Q1 — Sequence vs sequence item

A **sequence item** is a passive data object (extends `uvm_sequence_item`, ultimately
`uvm_object`). It holds **fields** describing one transaction (`addr`, `data`, `dir`, control
bits) and **constraints** keeping those fields legal. It does not consume time and does not call
the sequencer.

A **sequence** is an active task-driven object (extends `uvm_sequence #(REQ)`). Its `body()`
task creates one or more seq_items, blocks on the sequencer to send them, and consumes simulation
time. It encapsulates a *scenario* or *recipe*.

Analogy: item = pizza, sequence = recipe, sequencer = waiter, driver = chef.

> **Interview-grade answer:**
>
> *"The sequence item is passive data — fields and constraints describing one transaction. The
> sequence is active code — a `body()` task that builds and sends items through the
> sequencer-driver handshake. Both derive from `uvm_object` so neither is in the static
> testbench hierarchy; they're transient. The sequence is the recipe, the item is the dish."*

---

### Q2 — Entry point of a sequence

The entry point is the **`body()` task**, defined virtual in `uvm_sequence` and overridden by
the child. It is **never called directly by user code**. Instead user code calls
`seq.start(some_sequencer)`, which sets `m_sequencer`, runs `pre_start`, conditionally runs
`pre_body`, then calls `body()`, then `post_body`, then `post_start`.

`body()` **must** be a task because:
- `start_item` blocks on the sequencer (`wait_for_grant`).
- `finish_item` blocks on the driver (`item_done`).
- Both consume simulation time. SV requires time-consuming code to live in tasks.

Writing `function void body()` does not override the base task — it creates a separate, never-called
method. The override is silently lost.

> **Interview-grade answer:**
>
> *"`body()` is the entry-point virtual task. `start()` invokes it after lifecycle pre-hooks. It
> must be a `task`, not a `function`, because `start_item` and `finish_item` block on the
> sequencer and driver — they consume time. A common bug is writing `function void body()`, which
> compiles but doesn't override the base task — your stimulus silently never runs."*

---

### Q3 — The `start_item` / `finish_item` handshake

Between the two calls, this is what happens:

1. `start_item(item)`:
   - Calls `m_sequencer.wait_for_grant(this, priority)` internally.
   - Blocks the calling task until the sequencer's arbitration grants this sequence the floor.
   - If `pre_do`, `mid_do` hooks are defined, they fire here.

2. **User code** then calls `item.randomize() with { … }` — late randomization, so the item
   reflects current state.

3. `finish_item(item)`:
   - Calls `m_sequencer.send_request(this, item)` — pushes item onto the export.
   - Driver's `seq_item_port.get_next_item(req)` returns this item.
   - Driver wiggles pins, then calls `seq_item_port.item_done()`.
   - `finish_item` returns when `item_done` is observed.

The sequence is **blocked** during both — that's why `body()` is a task.

> **Interview-grade answer:**
>
> *"`start_item` issues `wait_for_grant` to the sequencer and blocks until arbitration grants the
> floor. Then I randomize the item, so the item reflects state at the moment of being sent.
> `finish_item` invokes `send_request` and blocks until the driver calls `item_done`. Both
> internally suspend the calling task, which is why `body()` must be a task. The pattern lets the
> sequence and driver pipeline cleanly without a shared mailbox."*

---

### Q4 — Identifier shadowing in `randomize() with`

Inside `randomize() with { … }`, unqualified identifiers resolve in this order:
1. Field of the randomized object (highest priority).
2. Enclosing scope (the sequence's locals).

So `addr == addr;` resolves *both* sides to the item's `addr` → the constraint becomes
`item.addr == item.addr`, a tautology, permitting any value. The sequence's `addr` is silently
ignored.

**Fix:** Use `local::addr` on the right-hand side:
```systemverilog
addr == local::addr;
```
`local::name` forces the lookup into the sequence's enclosing scope, not the item.

Alternative: name the sequence field differently (e.g., `m_addr`) so there's no shadowing.

This is a runtime-invisible bug — addresses come out wrong but simulation continues.

> **Interview-grade answer:**
>
> *"In `randomize() with`, identifiers default to fields of the randomized object. When the
> sequence and item share a name like `addr`, the constraint becomes a tautology and the
> sequence's value is silently dropped. Defensive fix is `local::addr` on the right-hand side,
> which scopes the lookup to the sequence. Every sequence in our project uses `local::` because
> this bug burned us once and we made it the standard."*

---

### Q5 — `` `uvm_do`` expansion

`` `uvm_do(req)`` roughly expands to:
```systemverilog
begin
  req = REQ_TYPE::type_id::create("req");
  start_item(req);
  if (!req.randomize()) `uvm_warning("RNDFLD", "rand failed")
  finish_item(req);
end
```

`` `uvm_do_with(req, { CONSTR })`` does the same but with `req.randomize() with { CONSTR }`.

Modern UVM prefers the explicit form because:
- Readability — no macro magic to chase.
- Error escalation — explicit `if (!…)` can `uvm_fatal` instead of warn.
- Debugger compatibility — step-into works; macros sometimes expand awkwardly in tools.
- Reusable patterns — easy to inject pre-set fields between create and finish.

The macros remain common in legacy code and vendor VIPs. You should read them but rarely write them.

> **Interview-grade answer:**
>
> *"`` `uvm_do`` wraps create-randomize-send into one macro call. Modern style — what our project
> uses — writes the four steps out explicitly, because we want randomization failures to be
> `uvm_fatal` not `uvm_warning`, and we want the code to be debugger-friendly. Macros are still
> common in legacy and vendor code, so I read them but write the explicit form."*

---

### Q6 — Lifecycle order

```
seq.start(sqr, parent, priority, call_pre_post)
  ├── set m_sequencer = sqr
  ├── pre_start()                          (always)
  ├── if (call_pre_post && parent == null) pre_body()
  ├── body()
  ├── if (call_pre_post && parent == null) post_body()
  └── post_start()                         (always)
```

Per-item hooks `pre_do`, `mid_do`, `post_do` fire between `start_item` and the actual driver
handoff inside `finish_item`. Rarely used.

> **Interview-grade answer:**
>
> *"`start()` runs pre_start always, then pre_body only if this is a top-level sequence (parent
> null and call_pre_post=1), then body, then post_body under the same condition, then post_start
> always. Per-item hooks pre_do/mid_do/post_do exist but are rarely used. The conditional
> pre_body/post_body prevents nested children from double-raising objections."*

---

### Q7 — Why nested children skip pre_body/post_body

Because the canonical use of pre_body/post_body is **raising and dropping UVM objections** to keep
the run phase alive. If a parent sequence has already raised the objection for the whole
hierarchy, the child re-raising would create stacked objections, and the child dropping early
might prematurely end the phase if reference counting is off.

`pre_start`/`post_start`, by contrast, run **every time** — they're for sequence-instance setup
(logging, time tracking) that doesn't depend on hierarchy.

> **Interview-grade answer:**
>
> *"pre_body/post_body are the objection-raising hooks. When a parent has already raised the
> objection for the entire nested sequence tree, the children re-raising would risk
> double-counting or premature drops. So UVM skips pre_body/post_body when parent_sequence is
> non-null and call_pre_post is on. pre_start/post_start always run because they're for
> per-instance setup like tracking, not for objections."*

---

### Q8 — `randomize() with` return value

Returns a `bit`:
- `1` if the constraint solver found a legal solution for all rand fields.
- `0` if no legal assignment exists.

On failure, the rand fields retain their pre-randomization values (or `X` if never assigned).
**Simulation does NOT halt** — you must check the return value.

Conventions in this codebase:
- Critical scenarios: wrap in `if (!item.randomize() with { … }) `uvm_fatal(...)`.
- Sweeps where individual failures are tolerable: use `` `uvm_warning`` + `continue`.

Never call `randomize()` without checking the return. That's how silent failures bury themselves.

> **Interview-grade answer:**
>
> *"`randomize() with` returns 0 on solver infeasibility, leaving rand fields with stale values.
> Silent — no halt. Every randomize call must be wrapped in a failure check; in our project we
> escalate to `uvm_fatal` for critical sequences and `uvm_warning` for sweeps where one bad
> address is okay. Forgetting the check is a top-five debug-time sink."*

---

### Q9 — `m_sequencer` vs `p_sequencer`

| Aspect | `m_sequencer` | `p_sequencer` |
|---|---|---|
| Type | `uvm_sequencer_base` (generic base) | Your specific sequencer class |
| Availability | Always, set by `start()` | Only after `` `uvm_declare_p_sequencer(T)`` |
| Use case | Plain item-sending sequences | When you need typed sequencer fields/methods |

`p_sequencer` is the auto-cast typed handle. The `` `uvm_declare_p_sequencer(MY_SQR)`` macro
injects a pre_do hook that performs the cast on each item.

Need `p_sequencer` when:
- Calling custom sequencer methods (`m_sequencer.compute_next_addr()` would require cast otherwise).
- Reading config objects stored on the sequencer.
- In a virtual sequence: accessing the virtual sequencer's handles to real sequencers
  (`p_sequencer.master_sqr`).

> **Interview-grade answer:**
>
> *"`m_sequencer` is the generic-typed handle, always available. `p_sequencer` is the
> specific-typed handle, declared via `` `uvm_declare_p_sequencer(TYPE)`` which auto-casts on each
> item. Use `p_sequencer` whenever the sequence needs to access custom sequencer fields or
> methods — typical in virtual sequences where a virtual sequencer holds handles to multiple real
> sequencers."*

---

### Q10 — `lock`/`unlock` vs `grab`/`ungrab`

Both give **exclusive sequencer ownership** — no other sequence can send items until released.

Difference:
- **`lock`** is cooperative. It waits in the FIFO queue behind any pending sequences. Once at the
  head, it takes ownership.
- **`grab`** is preemptive. It jumps to the head of the queue, even past pending sequences.

`grab` can **starve** other sequences. Use only for emergency / interrupt-style stimulus.

```systemverilog
m_sequencer.lock(this);    // wait my turn, then own it
m_sequencer.grab(this);    // own it now, screw the others
```

> **Interview-grade answer:**
>
> *"Both give exclusive sequencer access. `lock` is polite — it queues normally and takes
> ownership when its turn comes. `grab` is aggressive — it preempts pending sequences and takes
> ownership immediately. Use `lock` for config phases that shouldn't be interleaved with random
> traffic. Use `grab` sparingly for emergency aborts or interrupts. Grab can starve other
> sequences, so it's a last resort."*

---

### Q11 — `wait_for_grant`

The low-level sequencer API that **blocks the calling sequence until the sequencer grants it the
floor**. Internally implements the arbitration policy — picks the next sequence from the queue
based on FIFO/weighted/random/etc., and unblocks that one's call.

It's hidden behind `start_item` for ergonomics: `start_item` calls `wait_for_grant`, then returns,
so the user-facing code is:

```systemverilog
start_item(item);        // wait_for_grant + pre_do hooks
randomize();
finish_item(item);       // send_request + wait_for_item_done
```

You'd call `wait_for_grant` directly only if you need finer control — e.g., performing some
sequencer-side operation between grant and randomize.

> **Interview-grade answer:**
>
> *"`wait_for_grant` is the low-level arbitration API on the sequencer. It blocks the calling
> sequence until the sequencer's arbitration policy picks it as the next-to-go. `start_item`
> wraps it so users get a clean three-call pattern. You'd call `wait_for_grant` directly only
> when you need to do something between grant and randomize that the standard pattern doesn't
> support — uncommon in modern code."*

---

### Q12 — `local::addr` and the SV rule it defends

The defended rule:

> *"Inside `randomize() with { … }`, an unqualified identifier resolves first to a field of the
> randomized object, then to enclosing scopes."*

When the sequence and item share a field name, the unqualified name shadows the sequence's
local. The constraint becomes a tautology and the sequence-side value is silently lost.

`local::name` forces resolution into the **enclosing local scope** (the sequence), bypassing
the field-of-object preference.

> **Interview-grade answer:**
>
> *"`local::addr` overrides SV's field-of-object name resolution priority inside `randomize()
> with`. Without it, when the sequence and item both have a field called `addr`, the constraint
> `addr == addr` self-resolves to the item's field on both sides — a tautology. With `local::`,
> the right-hand side scopes to the sequence. Defensive coding — every sequence we write uses
> `local::` by reflex."*

---

### Q13 — `constraint_mode(0)` on `default_trans_c`

`constraint_mode(0)` **disables** the named class-level constraint for this specific object
instance. Subsequent `randomize()` calls won't apply that constraint.

In `deep_rep_start_sequence`, the item's `default_trans_c` likely pins `start_cond=1`,
`stop_cond=1`, `rep_start=0` — the typical "complete I2C transaction" pattern. But middle
segments of a rep-start chain need `start_cond=0`, `stop_cond=0`, `rep_start=1`, which conflicts
with the default. Solver fails.

Disabling `default_trans_c` per-item via `constraint_mode(0)` lets the inline `with { … }`
override those fields freely.

If you didn't disable it: `randomize()` returns 0 → `` `uvm_fatal``  → simulation halts. Hence
the explicit disabling.

> **Interview-grade answer:**
>
> *"`default_trans_c` is a class-level constraint on the item that pins start_cond=1, stop_cond=1,
> rep_start=0 — sensible defaults for one-shot transactions. In a rep-start chain, middle
> segments need exactly the opposite. So we disable `default_trans_c` per-item with
> `constraint_mode(0)` before randomizing, then let the inline `with` constraints set the
> non-default values. Without disabling, the solver hits an UNSAT instance and fails."*

---

### Q14 — `start_item(item)` with uninitialized handle

```systemverilog
i2c_seq_item item;       // ← null handle
start_item(item);        // ← passes null
```

**Stage:** Runtime. **Symptom:** Null pointer dereference inside `start_item` when it tries to
access `item.print_config_settings()` or any item method. Simulator crashes with "Null object
access" at the line of `start_item`.

**Fix:** Always `item = i2c_seq_item::type_id::create("name");` before `start_item`.

A second issue if you didn't create-then-randomize: even if you patch the create, `item` fields
are unrandomized (all `X`). Driver wiggles `X`s onto SDA, slave sees garbage.

> **Interview-grade answer:**
>
> *"Compile passes — the handle is declared, not dereferenced. Elaboration passes — handles are
> null-initialized by default. At runtime, the first method access inside `start_item` hits a
> null pointer and the simulator halts. The fix is always `item = TYPE::type_id::create(name)`
> before `start_item`. Beyond that, even if I patch the null, I must remember to randomize
> before `finish_item` or the driver gets `X` fields."*

---

### Q15 — Constructor signature

A `uvm_sequence` extends `uvm_object`. `uvm_object`'s constructor takes one argument: `string
name`. There is **no parent** — sequences are transient and not part of the static hierarchy.

```systemverilog
function new(string name = "default");   // ✅ correct
  super.new(name);
endfunction
```

Compare to a `uvm_component`:
```systemverilog
function new(string name, uvm_component parent);   // ← components only
  super.new(name, parent);
endfunction
```

Putting `uvm_component parent` in a sequence's constructor is a common beginner mistake — it
compiles only if your `super.new` chain matches, but the registry expects the object signature.

> **Interview-grade answer:**
>
> *"Sequences extend `uvm_object`, not `uvm_component`. So the constructor takes only a name —
> no parent. That's a deliberate design: sequences are transient, created during run_phase, not
> part of the static testbench tree. Beginners often write `function new(string name,
> uvm_component parent)` for a sequence — that's the component signature, wrong inheritance
> branch, and the factory registration breaks."*

---

### Q16 — `arb_lost_sequence` and 0xAA

The scenario: this master tries to write while another master also drives the bus. I2C
arbitration says the master that drives a `1` when another is driving `0` loses (because the
bus is wired-AND, so `0` wins).

`0xAA = 1010_1010`. The bit positions 7, 5, 3, 1 are `1`. The competing master pulled-low by
the slave driver in `compete_mode` is driving `0`. At the first `1` bit this master tries to
send, it'll observe SDA = 0 (the competing master holds it low). Mismatch → arb_lost detected.

Why 0xAA and not 0xFF? Both lose. But 0xAA loses **at bit 7 (the very first data bit)**, which
exercises early-stage arbitration detection. 0xFF would also lose at bit 7 but doesn't toggle
to verify the *non-driving* state behavior. 0xAA's mixed pattern stresses both transmit and
release semantics.

The DUT must:
1. Detect SDA-mismatch during STATE_TX_BIT.
2. Assert `arb_lost` status.
3. Stop driving SDA and SCL immediately.
4. **Not** issue STOP (the winning master still owns the bus).

> **Interview-grade answer:**
>
> *"`arb_lost_sequence` drives a write where the data byte 0xAA has a `1` at bit 7. A competing
> master (simulated by the slave driver in compete_mode) holds SDA low. Since I2C is wired-AND,
> our master sees SDA=0 when it drove `1` — that's arbitration loss. The DUT must detect this
> in STATE_TX_BIT, assert arb_lost, stop driving, and not issue a STOP (the winning master
> still owns the bus). 0xAA was chosen because its pattern toggles, exercising both transmit
> and release behavior during arbitration; 0xFF would also lose but doesn't show the toggle."*

---

### Q17 — Design 'page write then verify' sequence

Pseudocode design:

```systemverilog
class i2c_page_write_verify_seq extends i2c_base_seq;
  `uvm_object_utils(i2c_page_write_verify_seq)
  logic [6:0] addr = 7'h50;
  rand logic [7:0] wr_data[16];

  task body();
    i2c_seq_item wr_item, rd_item;

    // Phase 1: 16-byte page write
    wr_item = i2c_seq_item::type_id::create("page_write");
    start_item(wr_item);
    if (!wr_item.randomize() with {
      addr      == local::addr;
      dir       == DIR_WRITE;
      num_data  == 16;
      foreach (data[i]) data[i] == local::wr_data[i];
      start_cond == 1; stop_cond == 1; rep_start == 0;
    }) `uvm_fatal("SEQ", "page_write rand failed")
    finish_item(wr_item);

    // Wait for EEPROM internal write cycle (~5 ms in real device,
    // shorten for sim) — bus-free time
    #500;

    // Phase 2: 16-byte page read
    rd_item = i2c_seq_item::type_id::create("page_read");
    start_item(rd_item);
    if (!rd_item.randomize() with {
      addr      == local::addr;
      dir       == DIR_READ;
      num_data  == 16;
      start_cond == 1; stop_cond == 1; rep_start == 0;
    }) `uvm_fatal("SEQ", "page_read rand failed")
    finish_item(rd_item);

    // Comparison happens in the scoreboard, not here — the sequence
    // only generates stimulus. The scoreboard's ref-model knows
    // wr_data was written and compares read response.
  endtask
endclass
```

Key points:
- Stimulus only — comparison lives in scoreboard.
- `#500` simulates write-cycle settling (real EEPROMs need ~5 ms, shortened for sim).
- Page is one START–STOP (single transaction), not 16 separate transactions.
- Could be enhanced to use repeated-START between write and read (no STOP gap), but page-write
  pattern typically requires the gap for internal NV write cycle.

> **Interview-grade answer:**
>
> *"I'd write a sequence that generates two items: a 16-byte page-write with stop_cond=1, then a
> delay to allow the EEPROM internal write cycle, then a 16-byte page-read also with
> start_cond=1, stop_cond=1. The data values come from a sequence-level rand array so the
> scoreboard can pre-populate its expected reference model with what we'll be writing. The
> sequence itself does not compare — that's the scoreboard's job. In a real EEPROM, the write
> cycle is ~5 ms; in sim we'd shorten to maybe 1 µs and document it. Repeated-START between
> write and read would skip the bus-free gap, but EEPROMs typically need it for internal NVM
> programming, so we use STOP-then-START."*

---

### Q18 — Address-NACK sequence design

Already implemented as `i2c_nack_addr_seq` (§11.6). Walkthrough:

- Pick a non-DUT address in the valid range [0x08, 0x77].
- Drive a write with that address.
- Master sends `S | wrong_addr W | …`.
- The DUT slave (at 0x50) doesn't recognize the address — does not pull SDA low for ACK.
- Master observes high SDA on the 9th bit (the ACK slot) — that's NACK.
- Master's expected behavior: **immediately issue STOP**, set status = STS_NACK, raise IRQ.

The master FSM must transition `TX_ADDR → DETECT_ACK → STOP` on NACK. Bugs to catch:
- Master ignores NACK and continues sending data (protocol violation).
- Master keeps SDA low after NACK (bus hang).
- Master fails to set STS_NACK status (silent failure to CPU).

Coverage: hits the `address_nack` coverpoint and the `master_fsm_nack_path` transition coverage.

> **Interview-grade answer:**
>
> *"`i2c_nack_addr_seq` picks a valid 7-bit address that's not the DUT's (0x50). The master
> sends start + addr + W; no slave answers; master sees SDA high at the ACK slot — NACK detected.
> The FSM must transition TX_ADDR → DETECT_ACK → STOP, set STS_NACK status, and release the
> bus. Verification looks for three potential bugs: ignoring NACK and continuing, leaving SDA
> low after NACK, or failing to set the status register. The scoreboard expects 'no transaction
> reached slave' and the slave monitor verifies that. Coverage closes the `address_nack` bin."*

---

### Q19 — Clock-stretch scenario design

Existing low-level pieces:
- `i2c_clock_stretch_seq` (master side — just runs a write).
- `i2c_slave_stretch_ctrl_seq` (slave side — arms slave to stretch).

What's missing: a **virtual sequence** that runs both on their respective sequencers.

Design:

```systemverilog
class clock_stretch_vseq extends uvm_sequence;
  `uvm_object_utils(clock_stretch_vseq)
  `uvm_declare_p_sequencer(i2c_virtual_sequencer)
  rand logic [15:0] stretch_cycles;
  constraint stretch_c { stretch_cycles inside {[50:200]}; }

  task body();
    i2c_slave_stretch_ctrl_seq slave_cfg;
    i2c_clock_stretch_seq      master_drv;

    // Step 1: configure slave to stretch
    slave_cfg = i2c_slave_stretch_ctrl_seq::type_id::create("slave_cfg");
    if (!slave_cfg.randomize() with { stretch_cycles == local::stretch_cycles; })
      `uvm_fatal(...)
    slave_cfg.start(p_sequencer.slave_ctrl_sqr, this);

    // Step 2: small delay to ensure config landed
    #100;

    // Step 3: drive master transaction
    master_drv = i2c_clock_stretch_seq::type_id::create("master_drv");
    master_drv.start(p_sequencer.master_sqr, this);
  endtask
endclass
```

Master expected behavior:
- After sending an ACK clock, slave pulls SCL low for N cycles.
- Master detects SCL is being held low — does not advance its bit counter.
- Master waits indefinitely (or until timeout) for SCL to release.
- Once SCL releases, master continues.

Verification: the monitor measures the SCL low time; scoreboard compares to expected
`stretch_cycles`. Also verify the master doesn't time out prematurely (assuming no timeout
register is configured to fire).

> **Interview-grade answer:**
>
> *"The current sequence library has two halves of the scenario — `i2c_slave_stretch_ctrl_seq`
> on the slave control sequencer and `i2c_clock_stretch_seq` on the master sequencer — but
> nothing that runs both. The missing piece is a virtual sequence parameterized via
> `` `uvm_declare_p_sequencer`` that owns both real sequencer handles. It starts the slave
> config first, delays briefly, then starts the master transaction. The DUT master must hold
> off when SCL is pulled low, resume when released, and not time out spuriously. The monitor
> measures SCL low time and the scoreboard compares to the programmed stretch_cycles."*

---

### Q20 — Constraint conflict diagnosis

Setup:
- Sequence inline: `burst_len inside {[1:32]}`.
- Item class constraint: `num_data <= 16`.
- Sequence body: `num_data == local::burst_len`.

When sequence-level `burst_len` randomizes to a value in `[17:32]`, the inline constraint forces
`num_data == 17` (e.g.), but the item's `num_data <= 16` says no. **Conflict** → solver fails →
`uvm_fatal`.

**Fix options:**
1. Tighten sequence constraint: `burst_len inside {[1:16]}`.
2. Loosen item constraint (if the architecture supports >16): widen `num_data <= 32`.
3. Disable item constraint per-item: `item.num_data_c.constraint_mode(0);` before randomize.
4. Document the conflict and clamp at sequence level: `num_data == (burst_len > 16) ? 16 : burst_len`.

**Real bug:** The sequence author probably didn't check the item's class-level constraints when
they wrote the inline. **Lesson:** when you write inline constraints, read the item's class
constraints first to ensure no conflict.

> **Interview-grade answer:**
>
> *"The sequence-level `burst_len` can hit 17-32, which the item's class constraint `num_data <=
> 16` rejects. The solver finds no feasible assignment and randomize returns 0 →
> `uvm_fatal`. Three fixes: tighten the sequence to `inside {[1:16]}`, widen the item's class
> constraint if architectural limit allows, or disable the item's constraint per-item with
> `constraint_mode(0)`. The author probably wrote the inline constraint without checking the
> item's class constraints — defensive code review catches this. In general, when you write
> sequence inline constraints, you must understand what the item already constrains, or you'll
> hit unsolvable instances."*

---

## 19. Key Takeaways

### Conceptual

1. **Sequence ≠ sequence item.** Sequence is a recipe (active task); item is a transaction (passive
   data). Both extend `uvm_object`, not `uvm_component` — they're transient.

2. **`body()` is the entry point.** Always called via `seq.start(sqr)`, never directly. Must be
   a `task` because the sequencer/driver handshake consumes time.

3. **`start_item` + randomize + `finish_item` is THE pattern.** Five lines, 80% of UVM stimulus.

4. **Modern UVM avoids `` `uvm_do`` macros.** Explicit code is readable, debuggable, and lets
   you escalate randomization failures to fatal.

5. **`local::` defends against name shadowing in `randomize() with`.** Use it religiously.

6. **`constraint_mode(0)` disables class constraints per-instance.** Needed when inline
   constraints conflict with defaults (e.g., `deep_rep_start_sequence`).

7. **`p_sequencer` is the typed handle.** Use `` `uvm_declare_p_sequencer(T)`` to get one when
   you need typed sequencer access — typical for virtual sequences.

8. **`lock` is cooperative; `grab` is preemptive.** Both give exclusive access. Use `grab` only
   for emergencies.

9. **Sequence layering enables reuse.** Parent calls `child.start(sqr, this)`. The `this`
   prevents double-objection by skipping child pre_body/post_body.

10. **Randomization failure is silent.** Always wrap in `if (!item.randomize() with { … })`
    failure check.

### I2C-specific

11. **Single-write / single-read** are the building blocks.
12. **Burst** = one START, one address, N data bytes, one STOP.
13. **Repeated-START** = no STOP between phases; direction change without releasing bus.
14. **Deep rep-start** (4+ segments) is a real coverage closure target.
15. **Clock stretching and force-NACK** require BOTH a slave control sequence AND a master
    sequence — a virtual sequence layer is missing in this codebase.
16. **Address NACK** verifies master's NACK-detection-then-STOP path.
17. **Walking-1s / walking-0s** patterns are inherited from memory test methodology and catch
    stuck-bit faults that random data misses.
18. **Arbitration loss** requires a competing master (simulated by slave in compete_mode); the
    DUT must detect SDA mismatch in TX_BIT and abort without STOP.

### Career-critical

- **Sequences are 60% of what a DV engineer writes day to day.** Mastery here is non-negotiable.
- **Interview questions hit the same 5 topics repeatedly:** body() entry, start_item/finish_item,
  randomize() with, local::, and virtual sequences. Memorize cold.
- **The bugs in §16 are real and have all happened to me.** You will see them.

---

## 20. Action Items — 3 New Sequences to Build

Below are three NEW sequences that should be added to the library. Each fills a real gap in the
current coverage / reuse story.

### Action Item 1 — `i2c_clock_stretch_vseq` (virtual sequence)

**Problem solved:** Currently `i2c_clock_stretch_seq` (master) and `i2c_slave_stretch_ctrl_seq`
(slave) exist as separate halves. Tests must coordinate them manually. A virtual sequence
captures the coordination once.

**Spec:**
- Extends `uvm_sequence` (no `#(...)` — virtual sequence).
- Uses `` `uvm_declare_p_sequencer(i2c_virtual_sequencer)``.
- Body: start slave-config, delay, start master-write.
- Randomize `stretch_cycles` at the virtual level; pass to both child sequences.

**Code skeleton:**
```systemverilog
class i2c_clock_stretch_vseq extends uvm_sequence;
  `uvm_object_utils(i2c_clock_stretch_vseq)
  `uvm_declare_p_sequencer(i2c_virtual_sequencer)

  rand logic [15:0] stretch_cycles;
  constraint stretch_c { stretch_cycles inside {[50:200]}; }

  function new(string name = "i2c_clock_stretch_vseq");
    super.new(name);
  endfunction

  task body();
    i2c_slave_stretch_ctrl_seq slave_cfg;
    i2c_clock_stretch_seq      master_drv;

    slave_cfg = i2c_slave_stretch_ctrl_seq::type_id::create("slave_cfg");
    if (!slave_cfg.randomize() with { stretch_cycles == local::stretch_cycles; })
      `uvm_fatal("VSEQ", "slave cfg rand failed")
    slave_cfg.start(p_sequencer.slave_ctrl_sqr, this);

    #100;

    master_drv = i2c_clock_stretch_seq::type_id::create("master_drv");
    if (!master_drv.randomize() with { stretch_cycles == local::stretch_cycles; })
      `uvm_fatal("VSEQ", "master drv rand failed")
    master_drv.start(p_sequencer.master_sqr, this);
  endtask
endclass
```

**Coverage gain:** Closes the "clock stretching" cross-coverage cell properly with deterministic
stretch_cycles values, not just random.

---

### Action Item 2 — `i2c_back_to_back_rep_start_random_seq`

**Problem solved:** `i2c_rep_start_seq` is hard-coded to 2 segments (W then R). `deep_rep_start_sequence`
is hard-coded to 4 segments (W-W-W-R). Real coverage wants random chains of length 2-8 with
random direction at each segment.

**Spec:**
- Random chain length: `rand int chain_len; constraint c { chain_len inside {[2:8]}; }`.
- Loop: first segment has `start_cond=1`; middle segments have `rep_start=1`; last has
  `stop_cond=1`.
- Direction per segment: random.
- Disable `default_trans_c` on each item.

**Code skeleton:**
```systemverilog
class i2c_back_to_back_rep_start_random_seq extends i2c_base_seq;
  `uvm_object_utils(i2c_back_to_back_rep_start_random_seq)

  rand int chain_len;
  logic [6:0] addr = 7'h50;
  constraint chain_len_c { chain_len inside {[2:8]}; }

  function new(string name = "i2c_back_to_back_rep_start_random_seq");
    super.new(name);
  endfunction

  task body();
    for (int i = 0; i < chain_len; i++) begin
      i2c_seq_item seg;
      bit is_first = (i == 0);
      bit is_last  = (i == chain_len - 1);
      seg = i2c_seq_item::type_id::create($sformatf("seg_%0d", i));
      seg.default_trans_c.constraint_mode(0);
      start_item(seg);
      if (!seg.randomize() with {
        addr       == local::addr;
        num_data   == 1;
        start_cond == is_first;
        stop_cond  == is_last;
        rep_start  == !is_first;
      }) `uvm_fatal("SEQ", $sformatf("seg_%0d rand failed", i))
      finish_item(seg);
    end
  endtask
endclass
```

**Coverage gain:** Hits the `chain_depth` coverpoint across all bins, exercises every
`direction × position` cross cell, finds bugs in `chain_depth` counter overflow.

---

### Action Item 3 — `i2c_register_walk_seq` (RAL-friendly)

**Problem solved:** The DUT has a CSR register map (REG_CTRL, REG_CMD, REG_STATUS, REG_DATA,
REG_ADDR, REG_IRQ_EN, REG_IRQ_ST). No sequence currently does a register walk to verify each
register's read/write/RO/W1C semantics. This is a high-ROI test that catches CSR-decode bugs
that nothing else catches.

**Spec:**
- For each register in the map:
  - Read default value, log.
  - Write a known pattern (0xFFFFFFFF or 0xA5A5A5A5).
  - Read back, compare.
  - For RO registers, expect read-back of last-driven status, not the write.
  - For W1C registers, expect the bit to clear after write of 1.
- Use `i2c_seq_item` to drive register accesses via the I2C interface (or APB if your CSR has
  APB; the project might support both).

**Code skeleton (assuming I2C-side CSR access — write/read via burst):**
```systemverilog
class i2c_register_walk_seq extends i2c_base_seq;
  `uvm_object_utils(i2c_register_walk_seq)
  logic [6:0] addr = 7'h50;

  // List of CSR offsets and their semantics
  typedef struct {
    logic [2:0] offset;
    string      name;
    bit         is_ro;
  } reg_desc_t;

  reg_desc_t regs[$] = '{
    '{3'h0, "CTRL",   0},
    '{3'h1, "CMD",    0},
    '{3'h2, "STATUS", 1},   // RO
    '{3'h3, "DATA",   0},
    '{3'h4, "ADDR",   0},
    '{3'h5, "IRQ_EN", 0},
    '{3'h6, "IRQ_ST", 1}    // W1C — special, but treat as RO for read-back compare
  };

  function new(string name = "i2c_register_walk_seq");
    super.new(name);
  endfunction

  task body();
    foreach (regs[i]) begin
      i2c_seq_item wr, rd;
      logic [7:0] pattern = 8'hA5;

      // WRITE phase
      wr = i2c_seq_item::type_id::create($sformatf("wr_%s", regs[i].name));
      start_item(wr);
      if (!wr.randomize() with {
        addr == local::addr; dir == DIR_WRITE; num_data == 2;
        data[0] == 8'(regs[i].offset);   // first data byte = register offset
        data[1] == pattern;              // second data byte = value
        start_cond == 1; stop_cond == 1; rep_start == 0;
      }) `uvm_fatal("SEQ", "reg write rand failed")
      finish_item(wr);

      #200;

      // READ phase
      rd = i2c_seq_item::type_id::create($sformatf("rd_%s", regs[i].name));
      start_item(rd);
      if (!rd.randomize() with {
        addr == local::addr; dir == DIR_READ; num_data == 1;
        start_cond == 1; stop_cond == 1; rep_start == 0;
      }) `uvm_fatal("SEQ", "reg read rand failed")
      finish_item(rd);

      `uvm_info("REGWALK", $sformatf("Register %s @ offset 0x%0h: write=0x%02h, ro=%0d",
        regs[i].name, regs[i].offset, pattern, regs[i].is_ro), UVM_LOW)
    end
  endtask
endclass
```

**Coverage gain:** Closes the `csr_access_cg` coverpoint with bins per register. Catches
common CSR bugs: wrong reset values, decode aliasing (write to REG_X lands in REG_Y), missing
W1C semantics.

**Stretch goal:** This is exactly the workload that **UVM RAL (Register Abstraction Layer)** is
designed for. The above is a manual register walk; the *correct long-term answer* is to define
a `uvm_reg_block` mirror of the CSR map and use `reg.write(...)` / `reg.read(...)` with
automatic mirror checking. That's a 2-week internship deliverable that no other fresher will
have. **Highest-ROI upgrade to your project.**

---

## 21. Honest Self-Score Template

Fill this out after re-reading this lesson once. Be brutally honest with yourself.

| Area | Score (0/25/50/75/100) | Status | Notes |
|---|---|---|---|
| Sequence vs item distinction | __ | __ | |
| `body()` as entry point | __ | __ | |
| `start_item`/`finish_item` handshake details | __ | __ | |
| `randomize() with { … }` syntax | __ | __ | |
| `local::` scope resolution | __ | __ | |
| `` `uvm_do`` macros (read them, write modern) | __ | __ | |
| Lifecycle order (pre/post _start, _body) | __ | __ | |
| Why nested children skip pre_body/post_body | __ | __ | |
| `m_sequencer` vs `p_sequencer` | __ | __ | |
| `lock`/`unlock` vs `grab`/`ungrab` | __ | __ | |
| `wait_for_grant` mechanic | __ | __ | |
| `constraint_mode(0)` when defaults conflict | __ | __ | |
| Sequence layering — `child.start(sqr, this)` | __ | __ | |
| Virtual sequence pattern | __ | __ | |
| Randomization failure handling (`uvm_fatal` vs `uvm_warning` vs `continue`) | __ | __ | |
| Reading the existing 18 sequences in this file | __ | __ | |
| Designing a new sequence from a scenario description | __ | __ | |
| Top 10 bugs in §16 — can you spot each? | __ | __ | |

### Scoring guide

- **0** — Never heard of it.
- **25** — Heard of it, can't explain.
- **50** — Can explain on paper, would stumble in interview.
- **75** — Confident, can defend in interview.
- **100** — Could teach it to a junior.

### Action — re-take this self-score in 1 week

If any item is below 75, that's your **focus area** for the next study cycle. Don't move on to
the next lesson until the average is above 75. Sequences are the most-tested UVM topic in
fresher interviews at NVIDIA/Qualcomm/Intel/AMD — gaps here are immediate disqualifiers.

### Final reminder

You will be **asked to write a sequence on a whiteboard** in your interview. Practice writing
the canonical 5-line pattern (`create / start_item / randomize / finish_item`) from memory
**without looking**. Do it 10 times this week. The pattern should be automatic — like writing
your name.

```systemverilog
task body();
  i2c_seq_item item = i2c_seq_item::type_id::create("item");
  start_item(item);
  if (!item.randomize() with { /* constraints */ })
    `uvm_fatal("SEQ", "rand failed")
  finish_item(item);
endtask
```

Memorize. Internalize. Reflex.

---
