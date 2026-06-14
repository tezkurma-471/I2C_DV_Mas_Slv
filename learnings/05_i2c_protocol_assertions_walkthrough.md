> **⚠️ 2026-06-10 AUDIT UPDATE — read this box before trusting the lesson below.**
> A deep audit + fix pass changed the code this walkthrough describes. Deltas for this file:
> - Failures now route through `uvm_pkg::uvm_report_error` — with $error they were INVISIBLE to UVM pass/fail and the regression grep.
> - A2 was deleted: `##[1:T_BUF]` is an existential window (true if the bus is high at ANY one cycle) — near-vacuous and subsumed by A7.
> - A8 gained the missing `##1` and now enforces a structural 2-cycle hold (UM10204 t_HD;DAT min is 0; the slave legally responds ~3 cycles after SCL falls through its synchronizers).
> - Phase tracking (in_data_phase/in_ack_phase) is cleared at STOP; the BFM was re-timed so A7/A8/A9 windows are now satisfiable (they were mathematically impossible for the old ~5 clk/bit driver).
> Full detail: [`19_audit_fixes_walkthrough.md`](./19_audit_fixes_walkthrough.md) and `docs/AUDIT_FIX_REPORT.md`.

# Lesson 05 — `i2c_protocol_assertions.sv` Deep Dive

**File under study:** `sva/i2c_protocol_assertions.sv` (~265 lines)
**Concepts covered:** SystemVerilog Assertions (SVA), properties, sequences, implication operators, repetition operators, `disable iff`, clock domain selection for assertions, cover properties, the `bind` directive, protocol-compliance assertion design
**Date:** 2026-05-17
**Big-brother prerequisite read:** Lesson 01 (`i2c_pkg.sv`) — this file imports `i2c_pkg::*` and the numeric meaning of `T_HD_STA`, `T_SCL_PERIOD`, `T_BUF`, `T_HD_DAT`, `T_SU_DAT`, `MAX_CLK_STRETCH` only makes sense if you remember the timing breakdown there.

---

## Table of Contents

1. [Why This File Is The Most Interview-Relevant File In Your Project](#1-why-this-file-is-the-most-interview-relevant-file-in-your-project)
2. [60-Second Elevator Pitch](#2-60-second-elevator-pitch)
3. [SVA Fundamentals — The Refresher You Cannot Skip](#3-sva-fundamentals--the-refresher-you-cannot-skip)
4. [Architecture — How The SVA Module Attaches To The I2C DUT](#4-architecture--how-the-sva-module-attaches-to-the-i2c-dut)
5. [Module Header, Ports, and Sampling Pipeline](#5-module-header-ports-and-sampling-pipeline)
6. [Edge Detectors — `sda_fall`, `sda_rise`, `scl_fall`, `scl_rise_a8`](#6-edge-detectors)
7. [Bit Counter & Phase Tracker — The Helper FSM](#7-bit-counter--phase-tracker--the-helper-fsm)
8. [A1 — START Condition Must Be Followed By SCL Falling](#8-a1--start-condition-must-be-followed-by-scl-falling)
9. [A2 — Post-STOP Bus Recovery (Weak Form)](#9-a2--post-stop-bus-recovery-weak-form)
10. [A3 — SDA Stable While SCL High (Data Validity Window)](#10-a3--sda-stable-while-scl-high-data-validity-window)
11. [A4 — ACK/NACK Driven (No X/Z During 9th Bit)](#11-a4--ackack-driven-no-xz-during-9th-bit)
12. [A5 — Bounded Clock Stretching](#12-a5--bounded-clock-stretching)
13. [A6 — No Unknown Values During Active Transfer](#13-a6--no-unknown-values-during-active-transfer)
14. [A7 — Bus Free For The FULL T_BUF Window (Strong Form)](#14-a7--bus-free-for-the-full-t_buf-window-strong-form)
15. [A8 — SDA Hold Time After SCL Falls](#15-a8--sda-hold-time-after-scl-falls)
16. [A9 — SDA Setup Time Before SCL Rises](#16-a9--sda-setup-time-before-scl-rises)
17. [SVA Operator Deep Dive](#17-sva-operator-deep-dive)
18. [Clock-Stretching SVA — How To Allow Indefinite Stretch Safely](#18-clock-stretching-sva--how-to-allow-indefinite-stretch-safely)
19. [Cover Properties — The Neglected Sibling Of Assertions](#19-cover-properties--the-neglected-sibling-of-assertions)
20. [The `bind` Directive — Attaching SVA Without Touching RTL](#20-the-bind-directive--attaching-sva-without-touching-rtl)
21. [Quiz — 15 Questions](#21-quiz--15-questions)
22. [Quiz — Senior-Grade Answers](#22-quiz--senior-grade-answers)
23. [Key Takeaways](#23-key-takeaways)
24. [Action Items — Three New Assertions To Write](#24-action-items--three-new-assertions-to-write)
25. [Honest Self-Score Template](#25-honest-self-score-template)

---

## 1. Why This File Is The Most Interview-Relevant File In Your Project

Kushal — let me be brutally honest. You can fumble the UVM phasing question, you can blank on factory overrides, you can even get cold on scoreboard architecture and recover. But if you walk into an NVIDIA/Qualcomm/Intel/AMD DV interview and **cannot write a property on a whiteboard**, you will be filtered out before lunch.

SVA is the **single most-asked topic** in modern DV interviews. There are three reasons:

1. **It is cheap to ask and cheap to evaluate.** An interviewer can scribble "write me a property that says: after request goes high, grant must follow within 1–5 cycles" and immediately see if you understand `|->`, `##[1:5]`, and `disable iff`.
2. **It separates copy-paste UVM users from real DV engineers.** Anyone can wire up a sequence and a driver after a weekend tutorial. Writing a *correct* assertion forces you to understand the protocol, the clock domain, the X-propagation behavior, and the consequence of every operator.
3. **SVA bugs are some of the worst bugs in silicon.** A wrong assertion either **passes silently** (false negative — the bug ships) or **fires constantly** (false positive — engineers disable it and the bug ships). The `i2c_protocol_assertions.sv` file you are reading **had two tautologies (A1 and A2) that always passed** — they were Bug #11 and Bug #12 in your bug log. That is the most common SVA bug in the industry. Internalize it.

This walkthrough is long on purpose. Read it slowly. Re-read it weekly until it feels obvious.

---

## 2. 60-Second Elevator Pitch

When an interviewer asks: *"You said your I2C project has SVA. Walk me through it."*

> *"I wrote nine concurrent properties as a standalone SystemVerilog module that is instantiated alongside the DUT in `top_tb.sv` and sees the I2C bus through the same virtual interface the UVM monitor uses. The properties cover the three classes of I2C protocol rules: structural framing (START followed by SCL fall, STOP followed by T_BUF idle), data-validity windows (SDA stable while SCL is high, SDA hold/setup around SCL edges), and bus health (no X/Z, bounded clock stretch). The assertions are clocked on the 50 MHz system clock — not on SCL — because SCL is a DUT-generated signal that can stretch or glitch, so it cannot be trusted as the sampling clock for assertions about itself. Two earlier versions were tautologies that always passed; I caught that during a review pass and rewrote them as A1 and A2. The whole file is bound under a `disable iff (!rst_n)` clause so the assertions go quiet during reset."*

Memorize the **shape** of that paragraph, not the words. Notice it covers: where it lives, what it asserts (three categories), clock-domain rationale, reset handling, and one war story (the tautology).

---

## 3. SVA Fundamentals — The Refresher You Cannot Skip

### 3.1 Immediate vs Concurrent Assertions

There are exactly **two species** of SVA. You must be able to choose between them instantly.

| Feature | Immediate Assertion | Concurrent Assertion |
|---|---|---|
| Syntax | `assert (expr) else $error(...);` | `assert property (p_name) else $error(...);` |
| Where it lives | Inside a procedural block (`always`, `initial`, function, task) | Module body (or interface, program, clocking block, `bind`-target) |
| Sampling | Evaluates **at the instant it executes** — current values | Samples in the **Preponed region** at every clock tick of its clocking event |
| Time semantics | **Zero-time** check. No temporal operators allowed. | Spans multiple clock cycles via `##N`, `|->`, `[*N]`, etc. |
| Use case | Sanity checks at a specific code line: "this counter never wraps inside this `case` branch" | Protocol behavior: "after req, grant within 5 cycles" |
| Cost | Cheap. Like an `if` statement. | Heavier. Simulator maintains FSMs of active threads. |

**Mental model:** Immediate = `assert(...)` in C, fires when the program counter passes it. Concurrent = a permanent watchdog running in parallel, sampled at each clock edge.

**Every property in `i2c_protocol_assertions.sv` is concurrent.** They are declared at module scope with `@(posedge clk)` clocking events. That is correct — protocol rules are inherently temporal.

**Interview trap:** If asked "what is an assertion?", do not just say "assert property". Say:

> *"SystemVerilog has two — immediate and concurrent. Immediate is a procedural check evaluated at the moment the code executes, like an `if (x) else $error`. Concurrent is a temporal check declared at module scope, clocked, that runs in parallel with the design and can span many cycles. I use concurrent for protocol rules and immediate for sanity checks inside scoreboards."*

That single answer tells the interviewer you actually understand the distinction.

### 3.2 The Four Building Blocks

| Construct | One-line definition | Example |
|---|---|---|
| **Sequence** | A pattern of Boolean expressions over time. *No* implication. Composable. | `sequence s_handshake; req ##[1:3] gnt; endsequence` |
| **Property** | A sequence plus temporal operators (`\|->`, `\|=>`, `not`, `throughout`, etc.). Has truth value. | `property p; @(posedge clk) req \|-> ##[1:3] gnt; endproperty` |
| **Assert** | A directive that says "this property must hold; report failure." | `assert property (p) else $error(...);` |
| **Cover** | A directive that says "I want to see this sequence occur at least once." Reports coverage, not failure. | `cover property (p);` |
| **Assume** | A directive that says "treat this as an environmental constraint." Used in formal proof (and ignored by some simulators). | `assume property (p);` |

**Sequence vs property — the structural difference:**

- A **sequence** is just a temporal regular expression. It can match or not match starting from a given clock tick.
- A **property** is sequence + *logical* operators (implication, negation, "throughout", "until"). A property has a **truth value** at each evaluation point.

You cannot `assert` a raw sequence directly without an implication. The form `assert property (seq_name)` is shorthand that wraps the sequence in an implicit property — and the property is just `seq_name`. That works but is unusual.

**Why does this distinction matter?** Because sequences are **reusable building blocks**. If you write:

```systemverilog
sequence s_start_cond;
  scl_samp == 1'b1 && sda_fall;
endsequence
```

…you can now reuse `s_start_cond` in multiple properties: an A1-style property, a no-double-START property, a coverage property, etc. The author of `i2c_protocol_assertions.sv` did **not** factor sequences out — every condition is inlined. That is a refactor opportunity (see Action Items).

---

## 4. Architecture — How The SVA Module Attaches To The I2C DUT

Look at `tb/top_tb.sv` lines 57–62:

```systemverilog
i2c_protocol_assertions u_sva (
  .clk   (clk),
  .rst_n (rst_n),
  .scl   (i2c_bus_if.scl),
  .sda   (i2c_bus_if.sda)
);
```

**This is *not* a `bind` statement.** This is direct module instantiation. The SVA module is a normal SystemVerilog module that takes the I2C bus as inputs and runs its properties on whatever it sees.

```
+---------------------------+        +-----------------------------+
|   i2c_master_controller   |        |   i2c_slave_controller      |
|        (DUT, RTL)         |        |        (DUT, RTL)           |
+------------+--------------+        +--------------+--------------+
             |                                      |
             +-------------- SDA, SCL --------------+
                              ||
                  +-----------++-----------+
                  |   i2c_if (interface)   |
                  +-----------++-----------+
                              ||
        +---------------------++---------------------+
        |                                            |
        v                                            v
+------------------+                  +----------------------------+
|  UVM monitor     |                  |  i2c_protocol_assertions   |
|  (samples bus)   |                  |  (asserts protocol rules)  |
+------------------+                  +----------------------------+
```

**Two valid ways to attach SVA to a DUT — and you must know both:**

**Method A: Standalone module + interface (what this project does).**
- The SVA lives in its own module with explicit ports.
- It is instantiated in the testbench top alongside the DUT.
- It taps the same `i2c_if` interface the monitor uses.
- **Pro:** Trivial to enable/disable — just include or omit the instance.
- **Pro:** Works in tools that have flaky `bind` support.
- **Con:** Requires testbench-top edits to add. If the DUT instance changes, your wiring changes.

**Method B: `bind` directive (the industry-standard way).**
- The SVA lives in its own module.
- A `bind` statement attaches it to **internal scopes of the DUT** without modifying DUT RTL.
- The bound module can reach into the DUT's internal signals — useful for asserting on FSM states, FIFO occupancy, internal counters.
- **Pro:** Zero RTL changes. DUT owners do not need to know SVA was added.
- **Pro:** Can see internal signals — much stronger checks possible.
- **Con:** Some older tools have `bind` corner-case bugs (especially with parameters or hierarchical paths).

Both are valid. For an I2C DUT where the only protocol observables are the external SDA/SCL wires, Method A is fine. For a CPU pipeline where you need to see register-file writes or pipeline-stall signals, Method B is mandatory. Section 20 of this lesson goes deep on `bind`.

**Interview-grade answer to "how is your SVA attached?":**

> *"In this project, the SVA module is instantiated as a normal child of the testbench top and taps the I2C bus through the shared virtual interface. Since I2C is a fully external protocol, I do not need access to DUT internals. In a project where I needed to assert on internal RTL state — say, FIFO occupancy or pipeline stalls — I would use a `bind` directive, which attaches the assertion module to the DUT scope without modifying its RTL. `bind` is the cleaner approach for IP delivered as a black box."*

---

## 5. Module Header, Ports, and Sampling Pipeline

```systemverilog
module i2c_protocol_assertions (
  input logic  clk,
  input logic  rst_n,
  inout wire   scl,
  inout wire   sda
);
  import i2c_pkg::*;
```

**Three things to flag:**

1. **`clk` and `rst_n` are inputs.** This module is **clocked on the system clock**, not SCL. We will come back to *why* this is critical in Section 18.
2. **`scl` and `sda` are `inout wire`.** I2C is open-drain — both lines are wires shared by every driver on the bus. Declaring them as `wire` (not `logic`) is correct because `logic` cannot resolve multi-driver assignments; `wire` can.
3. **`import i2c_pkg::*`** pulls in all the timing constants (`T_HD_STA`, `T_BUF`, `T_HD_DAT`, `T_SU_DAT`, `T_SCL_PERIOD`, `MAX_CLK_STRETCH`). The assertions are parameterized through the package — change the package, change the assertion timing budget. Clean.

### The Two-Stage Sample Pipeline

```systemverilog
logic sda_samp, scl_samp;   // Stage 1 — sampled value
logic sda_d, scl_d;          // Stage 2 — delayed by one clock

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    sda_samp <= 1'b1;
    scl_samp <= 1'b1;
  end else begin
    sda_samp <= sda;
    scl_samp <= scl;
  end
end

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    sda_d <= 1'b1;
    scl_d <= 1'b1;
  end else begin
    sda_d <= sda_samp;
    scl_d <= scl_samp;
  end
end
```

**Why two stages?** Because edge detection in concurrent assertions is fragile if you compare a `wire` directly. The two-stage pipeline gives us:
- `sda_samp` — the bus value sampled at this clock tick.
- `sda_d` — the bus value sampled at the **previous** clock tick.
- `sda_d == 1 && sda_samp == 0` → SDA fell **between the previous and current clock tick** → edge detected.

Reset values are `1'b1` because I2C idle = bus pulled high by pull-up resistors. If reset values were 0, the SVA would falsely see a START condition the moment reset deasserted.

**Why not use SVA's built-in `$rose`/`$fell`?** You could. `$rose(sda)` is roughly equivalent to `sda_d == 0 && sda_samp == 1`. The author chose the explicit pipeline approach probably because (a) it is easier to debug in waveforms — you can plot `sda_samp` and `sda_d` directly, and (b) some older simulators have subtle bugs with `$rose`/`$fell` on `inout wire` signals.

**Interview trap:** *"Why do you sample the bus into a register before asserting on it?"* The answer is **synchronization and metastability isolation**. SDA and SCL are asynchronous to the system clock — they could change at any time. Sampling them into a flop establishes a deterministic sample point at the clock edge, which is exactly what the assertions need.

---

## 6. Edge Detectors

```systemverilog
assign sda_fall    = (sda_d == 1'b1 && sda_samp == 1'b0);
assign sda_rise    = (sda_d == 1'b0 && sda_samp == 1'b1);
assign scl_fall    = (sda_d == 1'b1 && scl_samp == 1'b0);
assign scl_rise_a8 = (scl_d == 1'b0 && scl_samp == 1'b1);
```

These four wires are the **alphabet of every assertion below**. Memorize them:

| Wire | Meaning | I2C semantics |
|---|---|---|
| `sda_fall` | SDA went 1→0 last cycle | When SCL is high, this is a **START condition** |
| `sda_rise` | SDA went 0→1 last cycle | When SCL is high, this is a **STOP condition** |
| `scl_fall` | SCL went 1→0 last cycle | End of a bit cell (data changes after this) |
| `scl_rise_a8` | SCL went 0→1 last cycle | Sample point for the current bit |

The two protocol-level signals built from these:

```systemverilog
assign start_cond_asserted = (scl_samp == 1'b1 && sda_fall);
assign stop_cond_asserted  = (scl_samp == 1'b1 && sda_rise);
```

**This is the I2C textbook definition.** A START is "SDA falls while SCL is high"; a STOP is "SDA rises while SCL is high." If you remember nothing else from I2C, remember this.

**Bug to look out for in interviews:** Some implementations check `sda_fall && scl_d == 1` instead of `scl_samp == 1`. That looks for "SCL was high last cycle AND SDA just fell" — almost the same, but slightly off by a delta. The implementation above uses `scl_samp == 1` (current value), which is the canonical sampling. Either works, but be consistent.

---

## 7. Bit Counter & Phase Tracker — The Helper FSM

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    bit_counter   <= 4'd0;
    in_data_phase <= 1'b0;
    in_ack_phase  <= 1'b0;
  end else begin
    if (start_cond_asserted) begin
      bit_counter   <= 4'd0;
      in_data_phase <= 1'b1;
      in_ack_phase  <= 1'b0;
    end else if (in_data_phase && scl_fall) begin
      bit_counter <= bit_counter + 1'b1;
      if (bit_counter == 4'd7) begin
        in_data_phase <= 1'b0;
        in_ack_phase  <= 1'b1;
      end
    end else if (in_ack_phase && scl_fall) begin
      in_ack_phase  <= 1'b0;
      in_data_phase <= 1'b1;
      bit_counter   <= 4'd0;
    end
  end
end
```

**This is an auxiliary state machine, NOT a property.** It exists only to give the properties context — *which phase of the I2C transaction are we in right now?*

State decoded:
- `in_data_phase` = currently transmitting one of the 8 data bits.
- `in_ack_phase` = currently in the 9th clock cycle where the receiver drives ACK/NACK.
- `bit_counter` = which bit we are on (0–7).

The FSM transitions:
- START → data phase, bit 0.
- Each SCL falling edge in data phase → next bit.
- After bit 7 (the 8th data bit) on SCL fall → enter ACK phase.
- After ACK phase SCL fall → back to data phase for next byte.

**Why is this needed?** Because most of the assertions only apply during data/ack phases. For example, A3 (SDA stable while SCL high) is **false** during a START or STOP condition by definition — START *is* SDA changing while SCL is high. Without the phase tracker, A3 would fire on every START. With it, we can write `(in_data_phase || in_ack_phase) |-> $stable(sda_samp)`.

**Interview-grade observation:** This is a classic SVA pattern — **build an auxiliary state machine in procedural code, then reference its state in properties.** Pure SVA cannot express "currently in the middle of a multi-cycle transaction" easily; an `always_ff` block can. Knowing when to drop into procedural code and when to stay in SVA is senior-engineer-level judgment.

**Subtle bug warning:** The FSM does not have a STOP transition. If a transaction ends with STOP, `in_data_phase` or `in_ack_phase` could remain stuck at 1 until the next START. Look at the logic: nothing clears these on `stop_cond_asserted`. That is a latent bug. Add to Action Items: fix the FSM to clear both phase flags on STOP.

---

## 8. A1 — START Condition Must Be Followed By SCL Falling

```systemverilog
property p_start_cond;
  @(posedge clk)
  disable iff (!rst_n)
  (scl_samp == 1'b1 && sda_fall) |-> ##[1:(T_HD_STA + T_SCL_PERIOD)] (scl_samp == 1'b0);
endproperty

assert_start: assert property (p_start_cond)
  else $error("I2C-SVA-A1: SCL did not fall after START within %0d cycles at time %t",
              T_HD_STA + T_SCL_PERIOD, $time);
```

### What it asserts

> "Whenever a START condition is detected (SDA falls while SCL is high), SCL must go low within `T_HD_STA + T_SCL_PERIOD` clock cycles."

Roughly: after START, the master must begin clocking. If SCL stays high forever, the master is broken.

### Why it matters protocol-wise

A START condition is supposed to be **immediately followed** by the master beginning to clock the address byte out. The first SCL falling edge after START is the transition from "START hold time" to "first data bit cell." If that fall never happens:
- The slave never sees clocking.
- The bus is locked in a permanent "START asserted but no clock" state.
- Any other master trying to grab the bus would see SCL high and assume the bus is free → collision.

### What bug it catches

- **Master FSM stuck after START.** If the master's state machine has a bug that asserts START but never advances to "send address" state, SCL stays high forever. A1 fires.
- **Glitch on SDA misinterpreted as START.** If a noise glitch causes `sda_fall` while SCL is high but the master never intends to start clocking, A1 catches the inconsistency.

### History — Bug #11

The comment header says:

> *Previous version was a tautology — antecedent included `scl_samp==1'b1` and the consequent re-checked it, so it always passed.*

The original buggy property was likely:

```systemverilog
(scl_samp == 1'b1 && sda_fall) |-> ##[1:N] (scl_samp == 1'b1);
//                                                          ^ should be 0, not 1
```

That property says "after START, SCL stays high within N cycles" — which is **trivially true** because SCL was already high (we just said so in the antecedent). The assertion would never fire, even when SCL stayed high forever.

**This is the #1 SVA bug class in industry.** A tautological assertion gives you false confidence — the green checkmark in your regression report is meaningless because the property is incapable of failing.

**Interview-grade answer when asked "what is the most common SVA bug?":**

> *"Tautological assertions — where the consequent is trivially implied by the antecedent, so the property always passes. The assertion looks fine in code review and reports zero failures in regression, but it is actually checking nothing. The defense is (a) write a cover property for the *failure* case and confirm it actually covers, and (b) deliberately inject a bug and confirm the assertion fires. If neither happens, the assertion is dead."*

---

## 9. A2 — Post-STOP Bus Recovery (Weak Form)

```systemverilog
property p_stop_cond;
  @(posedge clk)
  disable iff (!rst_n)
  (scl_samp == 1'b1 && sda_rise) |-> ##[1:T_BUF] (scl_samp == 1'b1 && sda_samp == 1'b1);
endproperty
```

### What it asserts

> "After a STOP condition, within `T_BUF` cycles, both SDA and SCL must be high (bus idle)."

### Why it matters protocol-wise

The I2C spec mandates a **minimum bus free time** between STOP and the next START. This gives time for:
- The slave to finish any post-transaction work (e.g., update its internal registers).
- The bus capacitance to fully recharge to the idle high level.
- Other masters to detect the bus is free before contending.

### What bug it catches

- **Master initiates next transaction too quickly** — if a master immediately drives START after STOP without waiting T_BUF, slow slaves on the bus may miss it.

### Why this is the "weak form" — A7 is the strong form

Read the operator carefully: `##[1:T_BUF]`. This is **"at some cycle between 1 and T_BUF, both lines are high."** It does **not** say "they are high for the entire window." A2 would pass even if the bus oscillated, as long as at *some single cycle* in the window both lines happen to be high.

That is why A7 exists — it uses `[*T_BUF]` (repetition) to require the bus to be high for **every cycle** of the window. We will dissect that in Section 14.

**Senior-engineer takeaway:** Always ask of a property — "could this pass while the buggy behavior still occurred?" If yes, you need a stronger property.

---

## 10. A3 — SDA Stable While SCL High (Data Validity Window)

```systemverilog
property p_sda_stable_scl_high;
  @(posedge clk)
  disable iff (!rst_n)
  ((in_data_phase || in_ack_phase) && scl_samp == 1'b1 && !start_cond_asserted && !stop_cond_asserted)
    |-> $stable(sda_samp);
endproperty
```

### What it asserts

> "During data or ACK phase, while SCL is high (and we are not currently in a START or STOP), SDA must not change."

This is the **fundamental I2C data validity rule**: data on SDA is only allowed to change while SCL is **low**. While SCL is **high**, SDA must hold its value because the receiver is sampling.

### Why the guards matter

Look at the antecedent — three guards:

1. **`in_data_phase || in_ack_phase`** — only inside a transaction (not during idle).
2. **`scl_samp == 1'b1`** — only when SCL is high (data is allowed to change when low).
3. **`!start_cond_asserted && !stop_cond_asserted`** — explicitly exclude START and STOP, which by definition violate this rule (they *are* SDA changing while SCL is high).

Without the START/STOP exclusion, the assertion would fire on every legitimate START or STOP. That is the cardinal sin of assertions — **fire on legal behavior**.

### `$stable(sda_samp)`

`$stable(x)` is a built-in SVA system function that returns true if `x` has the same value as it did at the previous sampling point. Equivalent to `x == $past(x, 1)`.

**Subtle:** `$stable` is evaluated **between consecutive clock samples**. So the assertion says "from the previous clock tick to this one, SDA did not change." It does not say "SDA is stable for the entire SCL-high period."

For the full SCL-high window stability, you would write something like:
```systemverilog
scl_rise_a8 |-> $stable(sda_samp)[*1:$] until_with scl_fall;
```
But that requires `until_with`, which not every tool supports cleanly. The single-tick check is the pragmatic choice.

### What bug it catches

- **Master drives data with wrong timing** — data changes while SCL high.
- **Glitch on SDA during sampling** — if noise causes SDA to briefly flip, the receiver could sample the wrong bit.
- **Two masters in collision** (in a multi-master world) — both driving SDA, causing toggles mid-bit.

---

## 11. A4 — ACK/NACK Driven (No X/Z During 9th Bit)

```systemverilog
property p_ack_driven;
  @(posedge clk)
  disable iff (!rst_n)
  (in_ack_phase && scl_samp == 1'b1) |-> (!$isunknown(sda_samp));
endproperty
```

### What it asserts

> "During the ACK phase, while SCL is high (the sample window for the ACK bit), SDA must be a known logic value — not X, not Z."

### Why it matters protocol-wise

The 9th bit of every I2C byte is the ACK/NACK. The **receiver** drives this:
- During an address byte: the addressed slave drives ACK (0) if present.
- During a data byte sent master→slave: the slave drives ACK (0) on success, releases (NACK = 1) on failure.
- During a data byte sent slave→master: the master drives ACK (0) to request another byte, NACK (1) to terminate.

If nobody drives the line during ACK, SDA is **floating Z** (held high by pull-up). If a simulator reports X (unknown), it means a driver started driving but with an undefined value — usually a reset/initialization bug.

### `$isunknown` semantics

`$isunknown(x)` returns true if any bit of `x` is X or Z. For a 1-bit signal like `sda_samp`, this catches the floating-or-uninitialized case.

### What bug it catches

- **Slave fails to drive ACK** — the slave's FSM is supposed to pull SDA low during ACK but never does → SDA stays Z → `$isunknown` fires.
- **X-propagation** — uninitialized register in the slave's ACK driver propagates X to SDA → `$isunknown` fires.

**Interview-grade note:** X-checks are some of the highest-value assertions you can write. They are cheap (a single `$isunknown`) but catch entire classes of initialization and reset bugs that functional tests miss.

---

## 12. A5 — Bounded Clock Stretching

```systemverilog
logic [15:0] scl_low_counter;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    scl_low_counter <= 16'd0;
  end else begin
    if (scl_samp == 1'b0) scl_low_counter <= scl_low_counter + 1'b1;
    else                  scl_low_counter <= 16'd0;
  end
end

property p_clk_stretch_bounded;
  @(posedge clk)
  disable iff (!rst_n)
  (scl_samp == 1'b0) |-> (scl_low_counter < MAX_CLK_STRETCH);
endproperty
```

### What it asserts

> "SCL must not stay low for more than `MAX_CLK_STRETCH` cycles."

### Why it matters protocol-wise

**Clock stretching** is an I2C feature where a slave that needs more processing time **holds SCL low** to pause the master. The master sees SCL not rising despite trying to release it, and waits. This is **legal** I2C behavior.

But unbounded clock stretching is a **bus hang**. If a buggy slave holds SCL low forever, the entire bus is dead and no other master can use it. Many production I2C systems include a watchdog timeout for exactly this reason.

### The clever implementation

Read the comment:

> *FIX: Uses the counter directly instead of `##[0:N]` sequence delay. This avoids spawning 1000 pending threads per assertion evaluation.*

Before the fix, the property was probably written as:

```systemverilog
(scl_samp == 1'b0) |-> ##[0:MAX_CLK_STRETCH] (scl_samp == 1'b1);  // BAD
```

This is functionally correct but **catastrophically expensive**. Every clock cycle where SCL is low, the simulator spawns a new thread for each possible match (1 cycle, 2 cycles, ... MAX_CLK_STRETCH cycles). If `MAX_CLK_STRETCH = 1000`, that is 1000 pending threads. Multiply by every cycle SCL is low → millions of threads → simulator dies.

The fix is to **count in procedural code** (cheap) and **assert a simple inequality on the count** in SVA (also cheap). This is a classic SVA performance pattern.

**Interview-grade answer when asked "how do you write a bounded-time assertion efficiently?":**

> *"For small bounds, `##[1:N]` is fine — the simulator only tracks a few threads. For large bounds, especially in the thousands of cycles, the thread explosion is a serious perf problem. The idiom is to build a counter in procedural code and assert on the counter's value. Same logical check, vastly cheaper."*

### What bug it catches

- **Slave clock-stretches forever** due to FSM deadlock.
- **Slow slave configuration bug** — slave is supposed to stretch for 100 cycles but configuration error makes it stretch for 100,000.

---

## 13. A6 — No Unknown Values During Active Transfer

```systemverilog
property p_no_unknown_bus;
  @(posedge clk)
  disable iff (!rst_n)
  (in_data_phase || in_ack_phase) |-> (!$isunknown(sda_samp) && !$isunknown(scl_samp));
endproperty
```

A blanket X/Z check on the whole bus during any active phase. Catches:
- Multi-driver bus conflicts (two drivers contending → simulator resolves to X).
- Uninitialized RTL registers driving the bus.
- Z-propagation from disabled tri-states.

This is the **safety net** assertion. Even if every other check passes, if X/Z appears on the bus, something is fundamentally broken and A6 catches it.

**Why is this an under-rated assertion class?** Because functional tests typically check **values** (was the data correct?) but ignore **X-propagation** (is the value valid at all?). A bug that makes a register transmit X is invisible to a scoreboard that does `if (rx_data == expected_data)` — because X != 1 returns false, the scoreboard logs a normal mismatch, not an X bug. An X-check assertion catches it at the source.

---

## 14. A7 — Bus Free For The FULL T_BUF Window (Strong Form)

```systemverilog
property p_bus_free_full_tbuf;
  @(posedge clk)
  disable iff (!rst_n)
  stop_cond_asserted |-> ##1 (sda_samp == 1'b1 && scl_samp == 1'b1)[*T_BUF];
endproperty
```

This is the **strong** version of A2.

### Operator breakdown

- `stop_cond_asserted |-> ##1 (...)` — implication followed by "one cycle later, the following expression must hold."
- `(sda_samp == 1'b1 && scl_samp == 1'b1)[*T_BUF]` — the consecutive repetition operator `[*N]` says **this Boolean must be true for N consecutive cycles**.

So the property reads: "Starting one cycle after STOP, both bus lines must be high for `T_BUF` consecutive cycles."

### A2 vs A7 — the difference in one diagram

```
A2 (##[1:T_BUF]): "At SOME cycle in window, bus is idle"

  STOP                                         T_BUF later
   |                                                |
   v                                                v
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |L|H|L|H|L|H|L|H|L|H|H|L|L|L|L|H|H|H|H|H|H|H|H|H| ← legal under A2!
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
                          ^
                          this single high cycle satisfies A2

A7 ([*T_BUF]): "EVERY cycle in window, bus is idle"

  STOP                                         T_BUF later
   |                                                |
   v                                                v
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |H|H|H|H|H|H|H|H|H|H|H|H|H|H|H|H|H|H|H|H|H|H|H|H| ← required by A7
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

A7 is what I2C *actually* requires. A2 was kept (probably) for backwards compatibility or as a sanity baseline. In a production-grade SVA suite, you would remove A2 once A7 is verified to work.

### What bug it catches

- **Slave glitches during idle** — slave releases the bus after STOP but momentarily pulls SDA low (e.g., a metastable register settling).
- **Premature new START** — master initiates next START within T_BUF.

---

## 15. A8 — SDA Hold Time After SCL Falls

```systemverilog
property p_sda_hold_after_scl_fall;
  @(posedge clk)
  disable iff (!rst_n)
  ((in_data_phase || in_ack_phase) && scl_fall && !start_cond_asserted && !stop_cond_asserted)
    |-> $stable(sda_samp)[*T_HD_DAT];
endproperty
```

### What it asserts

> "After SCL falls (in data/ack phase), SDA must remain stable for `T_HD_DAT` consecutive cycles."

This is the **data hold time** check. The I2C spec mandates a minimum hold time `t_HD;DAT` between SCL falling and SDA being allowed to change. The receiver samples on SCL rising edge; the sender holds SDA stable from SCL rise through SCL fall plus some margin.

### `$stable(...)[*N]`

Note the combination: `$stable(sda_samp)[*T_HD_DAT]`. This says "the `$stable` Boolean must be true for `T_HD_DAT` consecutive cycles." Equivalent to "SDA value at this cycle must equal SDA value at every cycle for the next T_HD_DAT cycles."

In `i2c_pkg.sv`, `T_HD_DAT = 5`. So after SCL fall, SDA must hold for 5 cycles (100 ns at 50 MHz). That is the scaled-down sim value — the real I2C spec requires 300 ns for Standard Mode. You should flag that in interviews.

### What bug it catches

- **Master changes SDA too early** after SCL fall, violating the hold time.
- **Glitch immediately after SCL fall** that could be mistaken for a new bit.

---

## 16. A9 — SDA Setup Time Before SCL Rises

```systemverilog
property p_sda_setup_before_scl_rise;
  @(posedge clk)
  disable iff (!rst_n)
  ((in_data_phase || in_ack_phase) && scl_rise_a8 && !start_cond_asserted && !stop_cond_asserted)
    |-> ($past(sda_samp, T_SU_DAT) == sda_samp);
endproperty
```

### What it asserts

> "At the cycle SCL rises (in data/ack phase), the value of SDA must equal the value it had `T_SU_DAT` cycles ago. I.e., SDA has been stable across the setup window leading up to SCL rise."

### `$past` deep dive

`$past(x, N)` returns the value of `x` `N` clock samples in the past. So `$past(sda_samp, 5)` returns what `sda_samp` was 5 clock ticks ago.

`$past(sda_samp, T_SU_DAT) == sda_samp` reads as: "current value of SDA matches its value T_SU_DAT cycles ago." If true, SDA has been stable. If false, SDA changed within the setup window — a violation.

**Subtle:** This check only verifies the **start and end** of the window are equal. SDA could in principle have toggled in the middle and toggled back. For T_SU_DAT = 5, that is unlikely but theoretically possible. A more robust check would be `$stable(sda_samp)[*T_SU_DAT]` evaluated *backwards*, but SVA doesn't have a natural backwards operator. Workaround: trigger the assertion T_SU_DAT cycles after SCL is stable-low and check stability forward to the SCL rise. That is more complex; the implementation took the pragmatic route.

### What bug it catches

- **Master changes SDA too close to SCL rise** — receiver may sample mid-transition, getting a corrupted bit.
- **Glitch in the setup window** that doesn't persist to the next clock but did briefly change SDA.

---

## 17. SVA Operator Deep Dive

This is the **operator reference** every interviewer expects you to know cold.

### 17.1 `##N` and `##[M:N]` — Cycle Delay

```systemverilog
a ##1 b      // a, then next cycle b
a ##5 b      // a, then 5 cycles later b
a ##[1:5] b  // a, then b within 1–5 cycles
a ##[0:$] b  // a, then b eventually (unbounded)
```

- `##0` means "same cycle." Rare and tricky.
- `##[M:N]` is a **range** — matches if `b` is true at *any* cycle in `[M..N]`.
- `##[1:$]` means "eventually" — the simulator keeps a pending thread alive forever.

**Performance trap:** Unbounded ranges (`##[0:$]`) and large bounds (`##[1:1000]`) spawn many pending evaluation threads. Use counters instead (see A5).

### 17.2 `|->` vs `|=>` — The Two Implication Operators

**The single most-asked SVA question in interviews.**

| Operator | Name | Meaning |
|---|---|---|
| `|->` | **Overlapping** implication | If antecedent matches at cycle T, consequent must hold **starting at cycle T** (same cycle). |
| `|=>` | **Non-overlapping** implication | If antecedent matches at cycle T, consequent must hold **starting at cycle T+1** (next cycle). |

**Example:**

```systemverilog
req |-> gnt;     // when req is high, gnt must ALSO be high on the SAME cycle
req |=> gnt;     // when req is high, gnt must be high on the NEXT cycle
```

**Equivalent rewrite:** `a |=> b` is logically identical to `a |-> ##1 b`. Use whichever is cleaner.

**Interview trap (most-asked SVA question):**

> *"You have `req |-> ##2 ack` and `req |=> ##1 ack`. Are they the same?"*

**Answer:** Yes — both say "ack must be high exactly 2 cycles after req." `|=>` shifts the consequent by 1 cycle, then `##1` shifts it by one more. Same logical behavior.

```systemverilog
req |-> ##2 ack;   // ack at T+2
req |=> ##1 ack;   // ack at (T+1)+1 = T+2
```

But this:

```systemverilog
req |-> ack;       // ack at T (overlapping)
req |=> ack;       // ack at T+1 (next cycle)
```

…are **different**. Watch out.

### 17.3 `[*N]`, `[*M:N]` — Consecutive Repetition

```systemverilog
a[*3]       // a is true for 3 CONSECUTIVE cycles
a[*1:5]     // a is true for 1 to 5 consecutive cycles
a[*0]       // matches an empty interval — rare special case
a[*0:$]     // a holds for any non-negative consecutive duration
```

Used in A7 and A8 of this file. Reads as "Boolean is true continuously for N ticks."

### 17.4 `[=N]` — Non-Consecutive Repetition

```systemverilog
a[=3]    // a happens 3 times TOTAL, NOT necessarily consecutively
```

**Use case:** "Three errors must have occurred at some point before timeout."

`a[=3]` does **not** care what happens between the occurrences. There can be arbitrary gaps.

### 17.5 `[->N]` — Goto Repetition

```systemverilog
a[->3]   // a happens 3 times, and the sequence ENDS exactly when a happens the 3rd time
```

The difference from `[=N]`: `[->N]` "ends on the last match," while `[=N]` may match later than the last occurrence.

**Concrete example:**

```systemverilog
req ##1 (busy[->3]) ##1 done;
```

Reads as: "after req, busy goes high 3 times, then **on the cycle right after busy's 3rd occurrence**, done must be high."

If we used `[=3]`, "done" could be required some time *after* the 3rd busy — the sequence would not anchor to the 3rd match.

### 17.6 `throughout` — Continuous Condition

```systemverilog
(reset_n) throughout (s_data_transfer);
```

Reads as: "reset_n must be true at every cycle of `s_data_transfer`." If reset deasserts in the middle, the sequence fails.

Useful for sequences that must complete without interruption.

### 17.7 `within` — Sequence Containment

```systemverilog
s1 within s2;
```

Reads as: "`s1` must match somewhere inside the window of `s2`." `s2` is the outer envelope; `s1` is the inner pattern.

### 17.8 `until` — One-sided Stop

```systemverilog
a until b;          // a is true at every cycle until b becomes true (b not required to hold AT the end)
a until_with b;     // a is true at every cycle including the cycle b becomes true
```

### 17.9 `intersect` — Both Sequences End Together

```systemverilog
s1 intersect s2;
```

Both `s1` and `s2` must match **starting at the same cycle AND ending at the same cycle**.

### 17.10 `and`, `or`

```systemverilog
s1 and s2;   // both must match starting from the same cycle (ends may differ)
s1 or s2;    // at least one matches
```

### 17.11 `not` — Negation (Properties Only)

```systemverilog
property p_no_double_start;
  start_cond_asserted |=> not (start_cond_asserted[->1] without stop_cond_asserted);
endproperty
```

`not` can only be applied at the property level, not the sequence level. This is one of SVA's quirks — you cannot say `not (a ##1 b)` as a raw sequence; wrap it in a property.

### 17.12 `first_match`

```systemverilog
first_match(req ##[1:10] gnt) |-> ack;
```

Without `first_match`, the sequence `req ##[1:10] gnt` could match at multiple offsets (1, 2, 3, ..., 10 cycles later). `first_match` says "lock to the earliest match only" — useful when you only care about the first occurrence.

### 17.13 Quick Reference Table

| Operator | Reads As | Where Used In This File |
|---|---|---|
| `##N` / `##[M:N]` | "N cycles later" / "between M and N cycles later" | A1, A2 |
| `\|->` | "implies, starting same cycle" | A1, A2, A3, A4, A5, A6, A8, A9 |
| `\|=>` | "implies, starting next cycle" | (not used — but should be considered for A7) |
| `[*N]` | "true for N consecutive cycles" | A7, A8 |
| `[*M:N]` | "true for M to N consecutive cycles" | — |
| `[=N]` | "happens N times total" | — |
| `[->N]` | "happens N times, sequence ends on last match" | — |
| `$past(x, N)` | "value of x N cycles ago" | A9 |
| `$stable(x)` | "x same as previous sample" | A3, A8 |
| `$rose(x)` / `$fell(x)` | "x rose / fell since last sample" | (implicit in edge detectors) |
| `$isunknown(x)` | "x has any X or Z bit" | A4, A6 |
| `disable iff (cond)` | "ignore assertion while cond" | every property |
| `throughout` | "Boolean holds at every cycle of sequence" | (not used) |
| `until` / `until_with` | "Boolean holds until other becomes true" | (not used) |
| `intersect` | "both sequences start and end together" | (not used) |
| `not` | "property does NOT match" | (not used) |
| `first_match` | "match only the earliest" | (not used) |

---

## 18. Clock-Stretching SVA — How To Allow Indefinite Stretch Safely

### The Problem

I2C explicitly allows a slave to **stretch the clock** by holding SCL low. This pauses the master indefinitely while the slave does internal work.

For SVA, this is awkward because:
- Most properties assume "after SCL low, SCL goes high within some bounded window."
- If you write `scl_fall |-> ##[1:N] scl_rise`, you forbid stretches longer than N.
- If you write `scl_fall |-> ##[1:$] scl_rise`, you allow unbounded stretch — but **spawn unbounded pending threads** in the simulator.

### The Solution Patterns

**Pattern 1: Counter + bounded inequality (used in A5).**

Build an `always_ff` counter that increments while SCL is low. Assert `counter < MAX_STRETCH`. Allows unbounded stretching up to your watchdog limit, with constant memory.

**Pattern 2: `disable iff` on a stretch-active signal.**

```systemverilog
property p_normal_op;
  @(posedge clk) disable iff (!rst_n || slave_stretching)
  scl_fall |-> ##[1:N] scl_rise;
endproperty
```

While the slave is actively stretching, the property is disabled. When the slave releases, the property re-arms.

**Pattern 3: Use the SCL itself as the clocking event (advanced).**

```systemverilog
property p_scl_based;
  @(posedge scl)  // sample on SCL rise, not system clk
  ...
endproperty
```

This decouples the assertion from clock-stretching entirely — the property only evaluates when SCL transitions. **But:** this requires SCL to be glitch-free and toggling, which is exactly what you cannot assume when you are verifying SCL.

**Pattern 4: Auxiliary "stretch-active" signal + `throughout`.**

```systemverilog
property p_data_transfer;
  start_cond_asserted |->
    (data_valid throughout (scl_fall[->8] ##1 ack_phase));
endproperty
```

`throughout` lets you express "data is valid for the whole transfer, regardless of how long stretching makes it."

### What This File Does

A5 (the stretch bound) uses Pattern 1. The other properties use `disable iff (!rst_n)` only — they do **not** disable on stretch, because their guards (`scl_samp == 1'b1`, `scl_fall`, etc.) implicitly handle the case where SCL is paused. For example, A3's antecedent `scl_samp == 1'b1 && ...` only fires when SCL is high; during a stretch SCL is low, so A3 silently doesn't trigger. Elegant.

**Interview-grade answer:**

> *"For clock stretching, I use a counter-based assertion to bound the maximum stretch and let the rest of the properties implicitly handle the pause by gating on SCL. I avoid unbounded `##[1:$]` patterns because they spawn pending threads that hurt simulator performance."*

---

## 19. Cover Properties — The Neglected Sibling Of Assertions

### `cover property` vs `covergroup`

| Feature | `cover property` | `covergroup` |
|---|---|---|
| Type | Temporal sequence | Value/cross-product |
| Sampling | At assertion clocking event | At sample event (function call or `@event`) |
| Reports | "Did this sequence occur?" | "Did each value bin get hit?" |
| Best for | "Did a START-WRITE-ACK-STOP sequence ever happen?" | "Did we test every address × R/W combo?" |

**They are complementary, not substitutes.**

- **Covergroup** measures **state-space coverage** — "every transaction variant."
- **Cover property** measures **scenario coverage** — "every interesting temporal pattern."

### Why This File Has Zero Cover Properties

Look — there is not a single `cover property` in `i2c_protocol_assertions.sv`. **That is a gap.** Every protocol assertion should be paired with at least one cover property to confirm:

1. The assertion actually had a chance to fire (i.e., the antecedent occurred).
2. Interesting temporal scenarios were exercised.

### What You Should Add

```systemverilog
// Confirm the antecedent of A1 (START detection) actually fires
cover_start_detected: cover property (
  @(posedge clk) disable iff (!rst_n) start_cond_asserted
);

// Confirm STOP-then-bus-free path actually runs
cover_stop_to_idle: cover property (
  @(posedge clk) disable iff (!rst_n)
  stop_cond_asserted ##1 (sda_samp == 1 && scl_samp == 1)[*T_BUF]
);

// Confirm a full byte-transfer scenario
cover_full_byte: cover property (
  @(posedge clk) disable iff (!rst_n)
  start_cond_asserted ##1 (scl_fall[->9]) ##1 stop_cond_asserted
);

// Confirm clock stretching has been exercised at least once
cover_stretch: cover property (
  @(posedge clk) disable iff (!rst_n)
  $rose(scl_samp == 0) ##1 (scl_samp == 0)[*100]
);
```

**Interview-grade observation:** Every senior DV engineer pairs assertions with cover properties. The assertion catches the bad case; the cover proves the good case was tested. Without cover, your assertions could be sleeping through every test and you would never know.

---

## 20. The `bind` Directive — Attaching SVA Without Touching RTL

This project uses **direct instantiation**, not `bind`. But you must know `bind` for interviews.

### Syntax

```systemverilog
bind <target_module_or_instance> <checker_module> <inst_name> (<port_connections>);
```

**Example — binding to a module type (every instance):**

```systemverilog
bind i2c_master_controller  i2c_protocol_assertions u_sva (
  .clk   (clk),
  .rst_n (rst_n),
  .scl   (scl_out),
  .sda   (sda_out)
);
```

This statement says: "for every instance of `i2c_master_controller` in the design, also instantiate `i2c_protocol_assertions` as a child named `u_sva`, with these port connections."

**Example — binding to a specific instance:**

```systemverilog
bind testbench_top.dut  i2c_protocol_assertions u_sva (...);
```

Binds only to that one instance.

### Why `bind` Is The Industry Standard

1. **Zero RTL touch.** The DUT RTL is unchanged. SVA can be added by a verification engineer without bothering the designer.
2. **Visible internals.** The bound module is **inside** the DUT hierarchy, so it can see internal signals via `i2c_master_controller.state_reg`. No need to route them out as ports.
3. **Easy enable/disable.** Comment out the `bind` statement and the SVA is gone.
4. **Multiple SVA suites on one DUT.** You can bind multiple checker modules to the same DUT — one for protocol, one for performance, one for coverage.

### Where To Put The `bind`

Best practice: a separate file like `sva/i2c_protocol_assertions_bind.sv` that contains only the `bind` statement. Then the file is added to the compile list **only when SVA is wanted**. This makes SVA an opt-in feature.

### Common `bind` Pitfalls

1. **Parameter propagation.** If the DUT is parameterized and the checker uses those parameters, you need `bind` with a parameter list — syntax is non-obvious.
2. **Port direction mismatches.** If the DUT's signal is `output` but the checker declares `input`, this works. But binding `inout` signals can be tricky in some tools.
3. **Generate blocks.** Binding inside a generate block requires hierarchical path care.
4. **Multiple-driver issues.** Bind targets cannot drive signals already driven by the DUT — checkers must be passive observers.

### When To Use Bind vs Direct Instantiation

| Scenario | Approach |
|---|---|
| External-protocol checking (I2C, SPI, AXI) — only need bus signals | Direct instantiation (this project) |
| Internal-FSM checking (CPU pipeline, memory controller) | `bind` |
| Black-box IP delivered by another team | `bind` (do not edit their RTL) |
| In-house RTL where you control everything | Either; `bind` still preferred for cleanliness |

**Interview-grade answer when asked "what is the bind directive?":**

> *"`bind` is a SystemVerilog feature that lets you attach a module as a child of another module or instance without modifying the parent's source. The classic use is connecting an SVA checker to a black-box DUT — the checker can reach internal signals and run properties on them, and removing or updating the checker requires no RTL change. It is the standard way modern DV teams add formal-style assertions to designs they didn't author."*

---

## 21. Quiz — 15 Questions

Cover the answers below. Take 30 minutes. Score yourself honestly.

1. **Immediate vs concurrent assertions** — give a one-sentence definition of each and a real I2C-project use case for each.

2. **`property` vs `sequence`** — what is the *structural* difference, and why does it matter for reusability?

3. **`|->` vs `|=>` (the most-asked SVA interview question)** — explain the difference. Then: are `req |-> ##2 ack` and `req |=> ##1 ack` equivalent? Show the math.

4. **`disable iff` clause** — what does it do, what condition belongs there for I2C, and what is the cost of forgetting it?

5. **Clock domain choice** — the SVA in this file is clocked on `posedge clk` (the system clock), not on `posedge scl`. Defend this choice. What would break if you used SCL?

6. **Repetition operators** — write three two-line examples showing the difference between `a[*3]`, `a[=3]`, and `a[->3]`.

7. **Cover property vs covergroup** — explain when you'd reach for each. Why does an SVA suite without cover properties make you nervous?

8. **`bind` directive** — explain the mechanism in two sentences and list two pitfalls.

9. **A3 says `(in_data_phase || in_ack_phase) && scl_samp == 1'b1 && !start_cond_asserted && !stop_cond_asserted |-> $stable(sda_samp)`.** Why are all four antecedent guards necessary? Remove each one and describe what false-fires you would see.

10. **Write a new assertion:** *"The address byte (first 8 bits after START) must not be `7'h00` followed by any direction bit — this is the I2C general-call reserved address."* Show the property with bit-counter integration.

11. **Write a new assertion:** *"No double-START condition without an intervening STOP."* (Repeated START — `Sr` — is allowed in I2C, but only after at least one ACK. For this question, treat any back-to-back START with no STOP between as a violation.)

12. **Write a new assertion:** *"The ACK bit (9th bit of every byte) must be 0 from the slave when the slave address matches."* Assume you have access to a signal `slave_addr_match` that is high when the addressed slave decoded its address.

13. **Debugging:** Your A1 assertion is failing on every transaction. You add `$display` statements and see that `start_cond_asserted` is firing twice — once at the real START, once one cycle later. What is the bug, and how do you fix it?

14. **Tautology detection:** Look at this property — `property p_x; @(posedge clk) (a == 1) |-> (a == 1 ##1 a == 1); endproperty`. Is this useful? What category of bug is this?

15. **Clock stretching:** Rewrite A5 (the stretch bound) using **only** SVA operators (no `always_ff` counter). Is your version better or worse than the procedural counter? Justify.

---

## 22. Quiz — Senior-Grade Answers

### Q1 — Immediate vs Concurrent

**Immediate:** A procedural check inside an `always`/`initial`/`function` block, evaluated at the instant control passes through it. Zero-time, no temporal operators.

**Concurrent:** A property declared at module scope, sampled at every clock tick of its clocking event, can span many cycles using temporal operators.

**Use case in this project:**

- **Immediate** — in the scoreboard, when comparing expected vs observed: `assert (exp == obs) else $error("mismatch")`. One-shot, in-flow check.
- **Concurrent** — every property in this SVA file. Protocol rules are inherently multi-cycle.

> **Interview-grade answer:**
> *"Immediate assertions are zero-time, procedural — they evaluate when the line of code executes, like an `if-else` check. Concurrent assertions are clocked, declared at module scope, and can span multiple cycles using SVA temporal operators. I use immediate in my UVM scoreboard to sanity-check predicted-vs-observed transactions, and concurrent in `i2c_protocol_assertions.sv` to enforce protocol rules like 'SDA stable while SCL high.'"*

---

### Q2 — Property vs Sequence

A **sequence** is a temporal pattern of Boolean expressions (e.g., `a ##1 b ##2 c`). It can match starting at any clock tick. No logical operators like implication.

A **property** is a sequence wrapped with logical operators (`|->`, `|=>`, `not`, `throughout`, `until`). It has a truth value at every clock tick.

**Why it matters for reusability:** Sequences are **composable atoms**. You can define one sequence and reference it from multiple properties — including assertions, cover properties, and other sequences. Properties are leaf-level checks; they are not meant to be reused inside other properties.

The current SVA file does **not** factor out sequences — every condition is inlined. A refactored version would have:

```systemverilog
sequence s_start; @(posedge clk) (scl_samp == 1 && sda_fall); endsequence
sequence s_stop;  @(posedge clk) (scl_samp == 1 && sda_rise); endsequence

property p_start_cond; s_start |-> ##[1:N] (scl_samp == 0); endproperty
property p_no_double_start; s_start |=> not (s_start[->1] without s_stop); endproperty
property p_post_stop_idle; s_stop |-> ##1 (bus_idle)[*T_BUF]; endproperty
```

Now `s_start` and `s_stop` are reused across three properties. Maintainability improves; if I2C's START detection changes (e.g., add metastability filtering), you change it in one place.

> **Interview-grade answer:**
> *"A sequence is a temporal regular expression — a pattern of Booleans over time, with no implication or negation. A property is built from sequences plus logical operators like implication and `throughout`, and has a truth value. The practical impact: sequences are reusable building blocks; properties are leaf checks. Good SVA design factors common temporal patterns into named sequences, then references them from many properties — same way good RTL factors common functions into modules."*

---

### Q3 — `|->` vs `|=>` (THE Interview Question)

**`|->` (overlapping):** If the antecedent matches at cycle T, the consequent must hold **starting at cycle T**, the same cycle.

**`|=>` (non-overlapping):** If the antecedent matches at cycle T, the consequent must hold **starting at cycle T+1**, the next cycle. Equivalent to `|-> ##1 ...`.

**Are `req |-> ##2 ack` and `req |=> ##1 ack` equivalent?** Yes.

```
req |-> ##2 ack:
   T:    req high
   T+0:  consequent starts here (because |->)
   T+0+2 = T+2:  ack must be high
   
req |=> ##1 ack:
   T:    req high
   T+1:  consequent starts here (because |=>)
   T+1+1 = T+2:  ack must be high
```

Both require `ack` at T+2. Identical behavior.

**The trap question:** `req |-> ack` vs `req |=> ack` — **these are different**.

```
req |-> ack:   req high AND ack high at THE SAME CYCLE
req |=> ack:   req high at T, ack high at T+1
```

**Interview-grade answer:**

> *"`|->` is overlapping implication — the consequent is evaluated at the same cycle as the antecedent match. `|=>` is non-overlapping — the consequent is evaluated one cycle later. They're related by `a |=> b` being identical to `a |-> ##1 b`. The most common bug I see is mixing them up in handshake assertions — writing `req |-> ack` when you mean `req |=> ack`, which would require `ack` on the same cycle as `req` instead of the cycle after. I always say it out loud — 'same cycle' or 'next cycle' — before deciding which arrow."*

---

### Q4 — `disable iff`

**What it does:** Suspends evaluation of the property whenever the condition is true. Any in-flight evaluation aborts; new evaluations don't start.

**For I2C:** The condition is `!rst_n` — active-low reset. While the design is being reset, the I2C signals are undefined/idle, the FSMs are not running, and any protocol-rule check would false-fire. `disable iff (!rst_n)` makes the assertions go quiet during reset.

**Cost of forgetting it:** During reset, your testbench drives signals to defaults — likely SDA/SCL high. As the design comes out of reset, every property whose antecedent matches a default condition (e.g., bus idle pattern) will start an evaluation thread. The evaluations will then fail because the rest of the protocol hasn't started yet. Result: dozens of false failures at simulation start, every regression run, drowning out real bugs.

**Other things you might disable on:**
- A transaction-abort signal — `disable iff (!rst_n || abort_pending)`.
- A scan-test mode — `disable iff (!rst_n || scan_mode)`.

> **Interview-grade answer:**
> *"`disable iff` is the SVA equivalent of a synchronous reset clause for assertions — when the condition is true, any in-flight evaluation aborts and no new evaluations begin. For this I2C project I gate on `!rst_n`. Without it, every assertion would fire spuriously while the design is being held in reset, because the bus signals are at their reset defaults and the protocol rules don't apply yet. In a project with abort or scan-mode signals, I'd add those to the `disable iff` clause too."*

---

### Q5 — Clock Domain Choice (clk vs SCL)

**Why `posedge clk` is right:**

1. **SCL is a DUT-generated output.** Using a signal you are verifying as your sampling clock creates a circular dependency. If SCL has bugs (glitches, missing edges, wrong frequency), your assertions fail to evaluate correctly because their own sampling clock is broken.
2. **SCL can stretch indefinitely.** During clock stretching, SCL stays low for an unbounded period. If your assertion clock is SCL, your assertions are paused during stretch — they cannot check whether the stretch itself is too long. A5 (stretch bound) becomes impossible.
3. **SCL is asynchronous to the testbench.** The UVM components run on the system clock. If SVA is on SCL, it lives in a different time domain — debugging becomes painful.
4. **System clock is always running.** You can always sample SDA, SCL, and DUT internals together at the system clock edge.

**What would break with `posedge scl`:**
- Stretch bound: impossible (assertion paused during stretch).
- X-checks on SCL: meaningless (X on SCL is your clock — undefined behavior).
- Reset-time evaluation: SCL may not toggle during reset, so `disable iff` may not even get a chance to deassert.

**There is one valid use of `posedge scl`:** for asserting on bit-level data validity from the receiver's point of view — "every SCL rising edge, SDA must be a known value." But even then, system-clock-based sampling with edge detection is usually cleaner.

> **Interview-grade answer:**
> *"The SVA is clocked on the system clock, not SCL, for three reasons. First, SCL is a signal we're verifying — using it as the sampling clock would create a circular dependency where bugs in SCL break the assertions checking SCL. Second, clock stretching legally pauses SCL, which would pause the assertion engine and make it impossible to bound the stretch. Third, the system clock is always running, giving us a stable sampling reference. I sample SDA and SCL into a two-stage pipeline on the system clock, derive edge events, and write all properties against that synchronous representation."*

---

### Q6 — Repetition Operators

```systemverilog
// [*N] — consecutive: a true for N cycles back-to-back
property p_consec;
  trigger |-> a[*3];   // a is true at cycles T, T+1, T+2
endproperty

// [=N] — non-consecutive: a true N times TOTAL, gaps allowed
property p_total;
  trigger |-> ##1 a[=3];   // a happens 3 times eventually, any spacing
endproperty

// [->N] — goto: a true N times, sequence ENDS on the Nth match
property p_goto;
  trigger |-> ##1 a[->3] ##1 b;   // b must be true the cycle AFTER a's 3rd occurrence
endproperty
```

**Concrete timing example (with `trigger` at T=0):**

| Cycle | `a` | `a[*3]` match? | `a[=3]` match? | `a[->3]` match? |
|---|---|---|---|---|
| 0 | 1 |  |  |  |
| 1 | 1 |  |  |  |
| 2 | 1 | YES (cycles 0–2) |  |  |
| 3 | 0 |  |  |  |
| 4 | 1 |  |  |  |
| 5 | 0 |  |  |  |
| 6 | 1 |  | YES (cycles 0, 4, 6, or later) | YES — ends at cycle 6 |
| 7 | 0 |  |  |  |

> **Interview-grade answer:**
> *"`[*N]` is consecutive — N back-to-back true cycles. `[=N]` is non-consecutive count — N true occurrences total with arbitrary gaps. `[->N]` is goto — N occurrences where the sequence ends precisely on the Nth match. The classic interview confusion is `[=3]` vs `[->3]`; both count 3 occurrences, but `[->3]` anchors the sequence end-time to the last match while `[=3]` does not. I use `[*N]` for hold/setup windows, `[->N]` for 'wait for N events then do X,' and `[=N]` rarely — usually for coverage."*

---

### Q7 — Cover Property vs Covergroup

**Covergroup:** Sample-based, value/cross coverage. You define bins for variable values, sample at a chosen event, and the simulator reports which bins were hit. Best for: "did we test every address × R/W combo? Every command opcode? Every data length?"

**Cover property:** Temporal-pattern coverage. You define a sequence and the simulator reports whether that sequence was observed. Best for: "did a START-then-STOP within 2 cycles ever happen? Did the bus go through full IDLE-START-WRITE-ACK-WRITE-ACK-STOP-IDLE?"

**Why an SVA suite without cover is scary:**

1. **You can't tell if your antecedents fire.** If the antecedent of A1 never happens in regression, A1 trivially passes — but you haven't checked anything. A cover property on the antecedent proves it happened.
2. **Scenario gaps are invisible.** You may have written a great assertion for "no double START without STOP," but never exercised back-to-back STARTs in any test. Cover would expose that.
3. **Coverage closure is incomplete.** Code/toggle/branch coverage measures *that you ran* the RTL; functional covergroups measure *value combinations*; cover properties measure *temporal scenarios*. Without all three, you have holes.

> **Interview-grade answer:**
> *"They're complementary. Covergroups are value-space coverage — every address, every opcode, every length. Cover properties are scenario coverage — every temporal pattern of interest like START-WRITE-NACK-STOP. A regression with high covergroup numbers and zero cover properties is suspect — you've tested all the values but maybe never the sequences that stress the FSM transitions. Industry best practice is to write a cover property for every assertion's antecedent, to prove the assertion got exercised."*

---

### Q8 — `bind` Directive

**Mechanism:** `bind` attaches an instance of one module as a child of another module — at every instance of the target, or at one specific instance — without modifying the target's source. The bound module appears in the hierarchy as if it were originally a child, can connect to the target's ports and reach its internal signals, and is a passive observer (cannot drive signals already driven).

**Two pitfalls:**

1. **Parameter propagation.** If the target is parameterized and the bound module needs those parameters, the `bind` statement needs explicit parameter binding — syntax is non-obvious and varies by tool.
2. **Multiple-driver issues.** The bound module cannot drive signals already driven by the target. If your checker tries to drive a debug signal, you get an X.

Other gotchas: bind inside generate blocks, bind to instances that don't exist (typo), bind direction mismatches on `inout` ports.

> **Interview-grade answer:**
> *"`bind` is a SystemVerilog directive that attaches a child module to a target without modifying the target's source. You write `bind target_mod checker_mod inst_name (port_list);` and the elaborator inserts the checker as a child of every instance of `target_mod`. The classic use is attaching SVA to a black-box DUT — the checker can reach internal signals via the bind hierarchy and run properties on them, and removing it requires zero RTL change. The main pitfalls are parameter propagation and accidentally trying to drive signals from the bound module. It's the standard industry approach for protocol checkers in projects where you don't own the DUT source."*

---

### Q9 — A3 Antecedent Guards

A3:
```systemverilog
(in_data_phase || in_ack_phase) && scl_samp == 1'b1 && !start_cond_asserted && !stop_cond_asserted
  |-> $stable(sda_samp);
```

**Remove `in_data_phase || in_ack_phase`:** During idle, both SDA and SCL are high (pulled up). `scl_samp == 1` is true, but SDA might glitch or toggle due to other test activity. `$stable` would fail on legitimate idle behavior.

**Remove `scl_samp == 1'b1`:** While SCL is low, data is explicitly allowed to change. The assertion would fire on every legal data transition between bits.

**Remove `!start_cond_asserted`:** A START condition is, by definition, SDA falling while SCL is high. `$stable(sda_samp)` is **false** at the cycle of a START. So the assertion would fire on every START — a legal event.

**Remove `!stop_cond_asserted`:** Same as START — a STOP is SDA rising while SCL is high. The assertion would fire on every STOP.

All four guards are necessary. Removing any one produces a flood of false failures.

> **Interview-grade answer:**
> *"Each guard handles one category of legal SDA change. `in_data_phase || in_ack_phase` excludes bus-idle activity. `scl_samp == 1'b1` is the actual rule trigger — data must hold when SCL is high. The `!start_cond_asserted` and `!stop_cond_asserted` guards explicitly exempt START and STOP, which legally violate the rule because they ARE SDA changes while SCL is high. Drop any one and the assertion floods with false failures. This pattern — antecedent inclusion guards plus exception exclusion guards — is the canonical way to write an SVA condition for any 'mostly stable except in these specific cases' rule."*

---

### Q10 — General-Call Address Assertion

I2C general call is `0000_0000` (7-bit address `0x00` with W bit `0` → 8-bit byte `0x00`). The reserved range `0000_xxx` is special; the explicit general-call byte is `8'h00`. We want to flag whenever the first 8 bits after START form `8'h00`.

**Approach:** Capture address-byte bits into a shift register driven by SCL rising edges within the first 8 bits of the post-START phase. Assert that the captured byte at the 8th SCL rise is not `8'h00`.

```systemverilog
// Auxiliary: capture address byte
logic [7:0] addr_byte;
logic       addr_capture_active;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    addr_byte           <= 8'h00;
    addr_capture_active <= 1'b0;
  end else if (start_cond_asserted) begin
    addr_capture_active <= 1'b1;
    addr_byte           <= 8'h00;
  end else if (addr_capture_active && scl_rise_a8 && bit_counter <= 4'd7) begin
    addr_byte <= {addr_byte[6:0], sda_samp};
    if (bit_counter == 4'd7) addr_capture_active <= 1'b0;
  end
end

property p_no_general_call_reserved;
  @(posedge clk) disable iff (!rst_n)
  (addr_capture_active && bit_counter == 4'd7 && scl_fall)
    |-> (addr_byte != 8'h00);
endproperty

assert_no_general_call: assert property (p_no_general_call_reserved)
  else $error("I2C-SVA-A10: General-call reserved address 0x00 used at time %t", $time);
```

**Caveat:** General call is a *legal* I2C feature for broadcast; some projects explicitly use it. This assertion should only be enabled when your test plan declares "general call not used."

---

### Q11 — No Double-START Without Intervening STOP

```systemverilog
property p_no_double_start;
  @(posedge clk) disable iff (!rst_n)
  start_cond_asserted |=>
    (!start_cond_asserted) throughout (stop_cond_asserted[->1]);
endproperty

assert_no_double_start: assert property (p_no_double_start)
  else $error("I2C-SVA-A11: Second START before STOP at time %t", $time);
```

**How it reads:** After a START, until the next STOP happens, another START must not occur. `throughout` ensures the no-START condition holds across the entire window leading up to the next STOP.

**Caveat about repeated START (Sr):** I2C allows repeated START *without* an intervening STOP — this is a legitimate operation (`Sr`). So this assertion is too strict for general I2C; it's only valid if your spec says repeated START is disallowed. A more accurate version would check the specific timing pattern of `Sr` and only flag illegal cases.

---

### Q12 — Slave Drives ACK When Addressed

```systemverilog
property p_slave_acks_address;
  @(posedge clk) disable iff (!rst_n)
  (in_ack_phase && scl_samp == 1'b1 && slave_addr_match)
    |-> (sda_samp == 1'b0);
endproperty

assert_slave_acks: assert property (p_slave_acks_address)
  else $error("I2C-SVA-A12: Slave failed to ACK during address phase at time %t", $time);
```

**Subtlety:** The `slave_addr_match` signal must be valid at exactly the right cycle — when SCL is high during the 9th bit. This requires careful timing of the match-detection logic, which is why the assertion would normally `bind` into the slave RTL where the internal `addr_match` signal is directly visible. From the external bus side, you would derive `slave_addr_match` by capturing the address-byte shift register and comparing to the configured slave address.

---

### Q13 — Debugging Double-Fire on `start_cond_asserted`

If `start_cond_asserted` fires twice — once at the real START and once one cycle later — the bug is in the **edge detector**.

`start_cond_asserted = (scl_samp == 1'b1 && sda_fall)`.
`sda_fall = (sda_d == 1'b1 && sda_samp == 1'b0)`.

This detector is true for **exactly one clock cycle** — the cycle after SDA went from 1 to 0. If you see two cycles of `start_cond_asserted`, possible causes:

1. **`sda` signal glitching.** The bus is bouncing — going 1→0→1→0 over 2–3 cycles. Each 1→0 transition fires `sda_fall`. Fix: add hysteresis or debounce, e.g., require SDA to be stable-low for 2 cycles before declaring a fall.

2. **Sampling pipeline mis-clocked.** If `sda_samp` and `sda_d` have a phase mismatch with the `scl_samp` used in the comparison, `start_cond_asserted` may fire on the wrong cycle. Check that all sampling registers use the same `posedge clk`.

3. **Combinational hazard on `sda_fall`.** Since `sda_fall` is an `assign` (combinational), it can briefly glitch during the clock edge if `sda_d` and `sda_samp` update in different deltas. Fix: make `sda_fall` a registered signal driven from the same `always_ff`.

> **Interview-grade answer:**
> *"I'd suspect the edge detector first. The pattern of double-fire one cycle apart suggests either a bus glitch or a sampling-pipeline issue. I'd dump the waveform of `sda_samp`, `sda_d`, and the raw bus signal, then check whether the bus actually bounced or whether the two-stage pipeline is misaligned. If the raw bus bounced, the fix is debounce — require SDA stable-low for two cycles. If the pipeline is misaligned, the fix is to register `sda_fall` itself so it's guaranteed clean."*

---

### Q14 — Tautology Detection

```systemverilog
property p_x;
  @(posedge clk) (a == 1) |-> (a == 1 ##1 a == 1);
endproperty
```

This is a tautology if `a` is held constant high while the property evaluates, but it's not a pure tautology — the consequent requires `a == 1` to also be true the cycle after.

Let's think harder. The antecedent says `a == 1` at cycle T. The consequent requires `a == 1` at T AND `a == 1` at T+1. So the property is checking: "if `a` is high at T, then `a` must remain high at T+1." That's a *real* check — `a` must hold steady for at least one more cycle after being high.

Not a tautology — but the property is still odd. The `a == 1` in the consequent at cycle T is *redundant* (already given by the antecedent). A cleaner equivalent:

```systemverilog
(a == 1) |=> (a == 1);   // if a high at T, a must be high at T+1
```

**The bug category being tested:** *Tautology-by-redundancy*. The first `a == 1` in the consequent does nothing. The property still works (checks T+1), but a code reviewer might see "antecedent matches consequent → tautology" and miss the real check. The lesson: SVA code review must trace the actual cycle-by-cycle obligations, not just pattern-match on similar expressions.

**Classic real tautology:**

```systemverilog
(a == 1) |-> (a == 1);   // pure tautology — always passes
(scl_samp == 1 && sda_fall) |-> ##[1:N] (scl_samp == 1);  // ALSO tautology if scl unchanged
```

The second was the original A1 bug. The consequent re-asserts what's already in the antecedent over a window where SCL was supposed to stay constant — vacuous truth.

> **Interview-grade answer:**
> *"Tautological assertions are the most dangerous SVA bug because they pass regression silently while checking nothing. The defense is mandatory: write a cover property for the failure case and confirm it actually covers, and deliberately inject a known bug to confirm the assertion fires. If neither happens during sanity testing, the assertion is dead code. In code review, I always trace the cycle-by-cycle obligations rather than pattern-matching the expressions — the second A1 in the file was a tautology because its consequent restated the antecedent's SCL-high condition over a window where SCL didn't have to change."*

---

### Q15 — Pure-SVA Stretch Bound

```systemverilog
property p_stretch_pure_sva;
  @(posedge clk) disable iff (!rst_n)
  $fell(scl_samp) |-> ##[1:MAX_CLK_STRETCH] $rose(scl_samp);
endproperty
```

**Worse than the counter approach.** Three reasons:

1. **Thread explosion.** `##[1:MAX_CLK_STRETCH]` spawns up to `MAX_CLK_STRETCH` pending evaluation threads per SCL fall — if MAX is 1000 and SCL falls 10,000 times in a long test, that's 10 million transient threads.
2. **No counter visibility.** With the procedural counter, you can dump `scl_low_counter` to a waveform and immediately see "stretching now at 800 cycles, approaching limit." The pure-SVA version is opaque.
3. **Error message is weak.** The counter approach can print the exact stretch duration; the pure-SVA approach just says "scl didn't rise within window."

**The counter+inequality approach wins on:** simulator perf, debuggability, error-message quality. Use it.

> **Interview-grade answer:**
> *"Pure SVA works but doesn't scale — `##[1:N]` for large N causes thread explosion in the simulator's evaluation engine. The counter-plus-inequality pattern is the industry idiom: build a procedural counter in `always_ff` that increments while the signal is in the watched state, then assert a simple `counter < LIMIT` in SVA. Same logical check, constant-memory per evaluation, easy to debug from waveforms, and the error message can report the exact violation duration. I use this pattern any time the bound is more than a few dozen cycles."*

---

## 23. Key Takeaways

### Conceptual

1. **Concurrent properties are temporal regular expressions over clock cycles.** Master `##N`, `|->`, `|=>`, `[*N]`, `[=N]`, `[->N]` and you have 80% of SVA.

2. **`|->` vs `|=>` is THE interview question.** Same cycle vs next cycle. `a |=> b` ≡ `a |-> ##1 b`. Drill it.

3. **Tautologies are the #1 SVA bug.** Always pair an assertion with a cover property on the antecedent. Always inject a fault to confirm the assertion fires.

4. **Clock domain matters.** Sample on the system clock, not on a signal you are verifying. Build edge detectors via a two-stage pipeline.

5. **`disable iff (!rst_n)`** belongs on every protocol property. Without it, reset-time false fires drown out real bugs.

6. **Phase guards prevent false fires.** Every protocol assertion needs `(in_data_phase || in_ack_phase)` plus START/STOP exclusion, because legitimate START/STOP transitions break the rule by design.

7. **Procedural helpers + SVA checks > pure SVA** for large bounds. Build a counter in `always_ff`, assert the inequality. Avoid thread explosion.

8. **`bind` is the industry-standard attachment mechanism.** Even though this project uses direct instantiation, you must be able to explain `bind` and write a bind statement on a whiteboard.

9. **Cover properties are not optional.** Every assertion suite without cover is suspect. Cover the antecedent, cover the success path, cover the corner scenarios.

10. **X-checks are cheap, high-value.** `$isunknown` on critical bus signals catches initialization and multi-driver bugs that functional tests miss.

### Career-Critical

- **You will be asked to write a property on a whiteboard.** Practice from cold. Three patterns to know without thinking: request-grant handshake, bounded response time, no-double-event-without-clear.

- **You will be asked the `|->` vs `|=>` trap.** Answer "same cycle vs next cycle" and immediately show the equivalence `a |=> b ≡ a |-> ##1 b`.

- **You will be asked about tautologies.** Tell the story of A1 and A2 in this file — original tautology, how it was caught, what the fix was.

- **You will be asked about clock-stretching SVA.** Counter pattern. Quote the perf reason.

- **You will be asked about `bind`.** Even if your project doesn't use it.

### Honest Project Gaps

The current `i2c_protocol_assertions.sv` file is **competent but incomplete**:

- Zero cover properties — must add.
- Sequences not factored — refactor opportunity.
- Phase FSM doesn't clear on STOP — latent bug.
- No assertions on address-byte format, repeated START, slave-side ACK behavior.
- Hardcoded scaled-down timing — should be parameterized by I2C mode (Standard/Fast).

Document these honestly in your project README. Saying "I built it, here are the things I'd improve" is **stronger** in interviews than pretending it's perfect.

---

## 24. Action Items — Three New SVA Properties To Write

These are **deliverables** Kushal should add to deepen the assertion suite. Each is concrete and bounded.

### Action 1 — Address-Byte Format Assertion

**Rule:** The first 8 bits transmitted after START must form a valid I2C address byte (7-bit address + 1-bit R/W). The reserved address bytes `8'h00` (general call), `8'b1111_xxxx` (high-speed master code, 10-bit addressing reserved range), must be flagged unless explicitly used.

**Why it matters:** Catches buggy master FSMs that transmit `8'hFF` or other reserved values, which would either be silently dropped by all slaves (mysterious "no ACK" failures) or interpreted as a high-speed mode entry (subtle protocol corruption).

**Skeleton** (build on the address-byte capture from Q10):
```systemverilog
property p_addr_byte_valid;
  @(posedge clk) disable iff (!rst_n)
  (addr_capture_active && bit_counter == 4'd7 && scl_fall)
    |-> ((addr_byte[7:1] != 7'b0000_000) && (addr_byte[7:4] != 4'b1111));
endproperty
```

**Effort:** 2 hours. Includes the auxiliary address-byte shift register.

---

### Action 2 — No Repeated-START Without Address Resend Assertion

**Rule:** A repeated START (Sr — START without preceding STOP) is legal, **but** the bus protocol requires the master to follow Sr with a new 8-bit address byte (not raw data). This catches masters that issue Sr and then resume data transmission as if Sr never happened.

**Why it matters:** Slaves transitioning into "stop-listening" mode based on incorrect Sr handling is a real silicon bug class — addressed slaves think they're done when they shouldn't.

**Skeleton:**
```systemverilog
// Distinguish first-START from repeated-START using a transaction-active flag
logic txn_active;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)                           txn_active <= 1'b0;
  else if (start_cond_asserted)         txn_active <= 1'b1;
  else if (stop_cond_asserted)          txn_active <= 1'b0;
end

// Detect repeated START: start_cond_asserted while txn_active was already 1
wire repeated_start = start_cond_asserted && txn_active;

// After repeated START, next 8 bits must form a valid address byte
property p_sr_followed_by_addr;
  @(posedge clk) disable iff (!rst_n)
  repeated_start |=> (addr_capture_active throughout (scl_fall[->8]));
endproperty
```

**Effort:** 4 hours. Requires correct Sr detection and address-byte capture.

---

### Action 3 — Cover Property Pack For Every Existing Assertion

**Rule:** For each of A1–A9, add a `cover property` on the antecedent confirming the trigger actually occurred during regression. Plus a few scenario covers for full byte transactions, clock-stretch events, and Sr.

**Why it matters:** This is the single highest-ROI addition. It transforms the SVA suite from "we ran assertions but don't know if they fired" to "we ran assertions, here is exactly which ones got exercised and how many times." Mandatory for any production-grade DV environment.

**Skeleton:**
```systemverilog
cover_a1_trigger: cover property (
  @(posedge clk) disable iff (!rst_n) (scl_samp == 1'b1 && sda_fall)
);

cover_a2_trigger: cover property (
  @(posedge clk) disable iff (!rst_n) (scl_samp == 1'b1 && sda_rise)
);

cover_a3_trigger: cover property (
  @(posedge clk) disable iff (!rst_n)
  (in_data_phase || in_ack_phase) && scl_samp == 1'b1
);

cover_a5_trigger: cover property (
  @(posedge clk) disable iff (!rst_n) (scl_low_counter > 100)
);

cover_full_byte: cover property (
  @(posedge clk) disable iff (!rst_n)
  start_cond_asserted ##1 scl_fall[->9] ##1 stop_cond_asserted
);

cover_stretch_event: cover property (
  @(posedge clk) disable iff (!rst_n)
  $fell(scl_samp) ##1 (scl_low_counter > 50)
);

cover_repeated_start: cover property (
  @(posedge clk) disable iff (!rst_n) repeated_start
);
```

**Effort:** 1 day. Add the covers, run regression, document which scenarios are hit / missed in a coverage report appendix.

---

## 25. Honest Self-Score Template

After working through this lesson, fill in your honest scores. Be brutal. The point is to find gaps you can plug.

| Area | Self-Score (0–100) | Status | Plan |
|---|---|---|---|
| Immediate vs concurrent — definitions and use cases | | | |
| Property vs sequence structural difference | | | |
| `\|->` vs `\|=>` — can I show the math `a \|=> b ≡ a \|-> ##1 b`? | | | |
| `disable iff` purpose and what to put in it | | | |
| Clock domain selection rationale (clk not SCL) | | | |
| Two-stage sampling pipeline reason | | | |
| Edge detector construction (`sda_fall`, `sda_rise`, `scl_fall`) | | | |
| Phase tracker FSM purpose and the latent STOP bug | | | |
| A1 history (tautology, fix, lesson) | | | |
| A2 vs A7 — weak vs strong form distinction | | | |
| A3 four-guard rationale | | | |
| A4 — `$isunknown` and why X-checks are cheap-but-valuable | | | |
| A5 — counter+inequality vs `##[1:$]` and the thread-explosion reason | | | |
| A6 — bus X-check as safety net | | | |
| A7 — `[*N]` consecutive repetition operator semantics | | | |
| A8 — `$stable(x)[*N]` for hold-time check | | | |
| A9 — `$past(x, N)` for setup-time check, including the caveat about toggle-and-return | | | |
| Operator reference — can I recite `##N`, `\|->`, `\|=>`, `[*N]`, `[=N]`, `[->N]`, `throughout`, `within`, `until`, `intersect`, `and`, `or`, `not`, `first_match`? | | | |
| Clock-stretching SVA patterns (counter, disable iff, throughout) | | | |
| Cover property vs covergroup — when each, why both | | | |
| `bind` directive — mechanism, two pitfalls, when to prefer over direct instantiation | | | |
| Can I write a brand-new property on a whiteboard for a protocol rule I've never seen? | | | |
| Can I diagnose a tautology by tracing cycle obligations? | | | |
| Quiz score (out of 15) | | | |

### Scoring Targets For DV Interviews

- **0–40 per area:** You have gaps. Re-read the section and redo the related quiz question.
- **40–70:** You can recognize but can't yet generate. Practice writing properties without looking.
- **70–90:** You can pass a phone screen. For onsite, push to 90+ on the top 8 areas (the bolded ones in Key Takeaways).
- **90–100:** You can teach this. Now write the three Action Item assertions and you've got a senior-DV-quality SVA suite.

### Re-Read Schedule

- **+3 days:** Redo quiz cold, no answer-peek. Target 12/15.
- **+1 week:** Implement Action Item 1 (address-byte format).
- **+2 weeks:** Implement Action Item 2 (Sr handling) and Action Item 3 (cover property pack).
- **+1 month:** Run all assertions against your full regression. Report which ones fire (real bugs uncovered) and which ones never trigger (gaps in your test plan).

You own SVA by the end of this. Not before.
