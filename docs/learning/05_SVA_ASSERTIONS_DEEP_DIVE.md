# 05 — SystemVerilog Assertions (SVA): A Complete Deep Dive

**Author**: Senior Verification Engineer  
**Target audience**: Intern — zero prior SVA knowledge assumed  
**Project context**: I2C Protocol DV — `sva/i2c_protocol_assertions.sv`  
**Date**: 2026-05-12

---

## Before You Read Anything Else

This document will teach you SystemVerilog Assertions from the ground up. By the end you will:

1. Understand WHY assertions exist and what problem they solve.
2. Read and write any SVA property from scratch.
3. Understand every single assertion in this I2C project — line by line.
4. Know what a tautological assertion is and how to detect one.
5. Write assertions that can actually FAIL (the only kind that matter).

We will use Bugs #11 and #12 from this project as a case study. Those were SVA bugs — not RTL bugs, not UVM bugs — the assertions themselves were broken. That is uncommon enough that most engineers never think about it. You will.

---

## Part 1: Why Assertions Exist

### 1.1 The Fundamental Problem with Simulation-Only Verification

When you write a UVM testbench, you write scoreboard checks. Something like:

```systemverilog
// In your scoreboard
if (observed_data !== expected_data) begin
  `uvm_error("SCOREBOARD", $sformatf("Data mismatch: got 0x%02h, expected 0x%02h",
                                      observed_data, expected_data))
end
```

This checks what the data was at the end. Fine. But what about the protocol rules that governed HOW that data was transmitted? What if the design:

- Changed SDA while SCL was HIGH? (Protocol violation — but scoreboard might not catch it.)
- Held SCL LOW for 10 milliseconds? (Clock stretching abuse — scoreboard would just wait.)
- Drove X on the bus during ACK? (Simulation garbage — scoreboard might still pass.)

The scoreboard only checks the OUTCOME. It cannot check the BEHAVIOR along the way unless you write explicit monitor logic for every possible violation. That is thousands of lines of if-statements. And you will miss cases — because you can only check what you remembered to look for.

**This is the core problem: simulation-only verification is a bet that you thought of everything.**

### 1.2 Assertions: Baking Rules Into the Design

An assertion is a statement that says "this condition must ALWAYS be true." It is not a test. It is not a check in the scoreboard. It lives in the design (or bound to the design), and it fires automatically whenever the condition it monitors becomes relevant.

Think of it like a smoke detector. You do not manually check for smoke every 5 minutes. The detector runs continuously, and if smoke appears at any point — even at 3am while you are asleep — it fires.

Assertions are smoke detectors for your RTL.

```
Simulation check:       "Did the right data arrive at the end?"
Assertion:              "Was SDA ever changed while SCL was HIGH? At any point? Ever?"
```

The assertion does not need to be triggered. It does not need a test case. It runs on every clock cycle, for every transaction, in every test.

### 1.3 The Difference Between an Assertion and a Manual Simulation Check

| Property            | Manual check in monitor                   | SVA Assertion                        |
|---------------------|-------------------------------------------|--------------------------------------|
| Where it lives      | UVM monitor or scoreboard                 | Module or interface, bound to design |
| When it runs        | When monitor calls the check function     | Every clock cycle, automatically     |
| What it can express | Whatever you code explicitly              | Temporal sequences over time         |
| Missed cases        | Whatever you forgot to code               | None — property is evaluated always  |
| Visibility in waves | Hidden in UVM log                         | Visible as assertion pass/fail track |
| Formal verification | Cannot be used for formal                 | Can be proven mathematically         |

### 1.4 Two Flavors: Immediate vs Concurrent

**Immediate assertions** are procedural. They check a condition at a single point in time, inside an `always` block or task.

```systemverilog
// Immediate assertion — checks right now, in this procedural context
always @(posedge clk) begin
  if (in_data_phase) begin
    assert (sda !== 1'bx) else $error("SDA is X during data phase");
  end
end
```

This is useful but limited. It can only check what is true at the moment the `always` block runs. It cannot say "SCL was HIGH for 5 cycles after SDA fell."

**Concurrent assertions** are temporal. They run in parallel with the simulation, evaluating sequences of events across multiple clock cycles. These are the powerful ones.

```systemverilog
// Concurrent assertion — checks a temporal sequence
property p_sda_stable_during_scl_high;
  @(posedge clk)
  (scl == 1'b1) |-> $stable(sda);
endproperty

assert property (p_sda_stable_during_scl_high);
```

This runs on EVERY posedge clk. Every single one. You write it once and it guards the entire simulation.

### 1.5 Why Concurrent Assertions Are the Powerful Ones

Concurrent assertions understand TIME. I2C is a protocol — it is sequences of events over time. The rules are things like:

- "After SDA falls while SCL is high (START), SCL must fall within 10 clock cycles."
- "After SCL goes low, SDA must remain stable for at least 5 cycles before changing."
- "Clock stretching must not last more than 1000 clock cycles."

None of these can be expressed as a single-point check. They require tracking state over multiple cycles. Concurrent assertions do this natively using sequence operators like `##1` (next cycle) and implication operators like `|->`.

---

## Part 2: SVA Syntax From Zero

We will build the syntax incrementally. Every construct is illustrated with an I2C example.

### 2.1 The `property` Keyword

A property is a named temporal expression. Think of it as a reusable rule.

```systemverilog
property p_my_rule;
  // ... temporal expression goes here
endproperty
```

The property itself does nothing. It is a declaration. You must `assert` it to actually check it.

### 2.2 The `assert property` Statement

```systemverilog
assert property (p_my_rule)
  else $error("Rule p_my_rule was violated!");
```

The `else` clause runs when the property FAILS. This is where you put your error message.

You can also name the assertion label, which makes it easier to find in the waveform viewer:

```systemverilog
my_label: assert property (p_my_rule)
  else $error("Rule violated at time %t", $time);
```

In this project, every assertion is labeled: `assert_start`, `assert_sda_stable`, etc.

### 2.3 Clock Specification: `@(posedge clk)`

Concurrent assertions need a clock. Every `property` that will be used with `assert property` must be clocked.

```systemverilog
property p_with_clock;
  @(posedge clk)     // <-- evaluated on every rising edge of clk
  (some_signal == 1'b1) |-> (other_signal == 1'b0);
endproperty
```

The assertion "wakes up" at every posedge clk, samples all signals, and evaluates the temporal expression from that point.

You can also specify the clock in the `assert property` statement itself:

```systemverilog
assert property (@(posedge clk) p_my_rule);
```

If the clock is in both places, the one in the property takes precedence.

### 2.4 Disable iff: `disable iff (!rst_n)`

During reset, your design is in an undefined state. Signals are being initialized. An assertion that fires during reset will generate false failures — the protocol rules do not apply when the chip is being reset.

`disable iff` suspends the assertion when the condition is true:

```systemverilog
property p_sda_stable;
  @(posedge clk)
  disable iff (!rst_n)          // <-- suspended when rst_n is LOW
  (scl == 1'b1) |-> $stable(sda);
endproperty
```

When `rst_n` is 0 (active-low reset asserted), the property evaluation is suspended — no false failures.

> **TRAP**: Forgetting `disable iff (!rst_n)` is one of the most common SVA mistakes. At time zero, after reset is released, many signals are still 0. An assertion that expects SCL to be HIGH will fire immediately. You get 50 false failures before the first test even starts. Always include `disable iff` for reset.

### 2.5 The Implication Operator: `|->` vs `|=>`

This is the most important operator in SVA. It says "IF this happened, THEN this must also happen."

```
antecedent |-> consequent
```

**`|->` (overlapping implication)**:
- "If the antecedent is true at cycle N, the consequent must be true at cycle N (same cycle)."
- The consequent evaluation STARTS in the same cycle as the antecedent.

**`|=>` (non-overlapping implication)**:
- "If the antecedent is true at cycle N, the consequent must be true starting at cycle N+1."
- Equivalent to `|-> ##1`

```
  Cycle:   N    N+1   N+2
           |     |     |
  |->:   [antecedent][consequent starts here at N]
  |=>:   [antecedent]      [consequent starts here at N+1]
```

**When to use which**:
- Use `|->` when the consequence must be true IN THE SAME CYCLE as the trigger.
  Example: "If SCL is HIGH, then SDA must CURRENTLY be stable."
- Use `|=>` when the consequence applies to the NEXT cycle.
  Example: "If a write command is issued, then the ACK must arrive the next clock."

> **TRAP**: Off-by-one errors from using `|->` instead of `|=>` are subtle. If you write `(cmd_issued) |-> (ack_received)`, you are saying ACK must be in the SAME cycle as the command. If the protocol says ACK comes one cycle later, you need `(cmd_issued) |=> (ack_received)`.

### 2.6 Cycle Delays: `##1`, `##[1:5]`, `##[0:$]`

The `##` operator means "after exactly this many cycles."

**`##1`** — exactly 1 cycle later:

```systemverilog
(trigger) |-> ##1 (consequence);
// "If trigger at cycle N, consequence must be true at cycle N+1"
```

**`##[1:5]`** — somewhere between 1 and 5 cycles later:

```systemverilog
(trigger) |-> ##[1:5] (consequence);
// "If trigger at cycle N, consequence must be true at some cycle between N+1 and N+5"
```

This is a RANGE check. The tool tries every cycle in the range. The property passes if the consequence is true in ANY of those cycles.

**`##[0:$]`** — at some point in the future (0 to infinity):

```systemverilog
(trigger) |-> ##[0:$] (consequence);
// "If trigger at cycle N, consequence must EVENTUALLY become true"
```

The `$` means "unbounded." Use this when you need liveness: "something must eventually happen." Warning: in formal verification, unbounded ranges can be expensive.

**ASCII waveform example for `##[1:5]`**:

```
Cycles:  1    2    3    4    5    6    7    8
         |    |    |    |    |    |    |    |
trigger: 0    1    0    0    0    0    0    0
         |    |
         |    +-- trigger fires at cycle 2
         |         Property: trigger |-> ##[1:5] consequence
         |         Must see consequence between cycles 3 and 7

consequence may appear at:
  cycle 3: PASS (##1)
  cycle 4: PASS (##2)
  cycle 5: PASS (##3)
  cycle 6: PASS (##4)
  cycle 7: PASS (##5)
  cycle 8: FAIL (too late — window expired)
```

**I2C Example**: In A1, after a START condition, SCL must fall within `T_HD_STA + T_SCL_PERIOD` cycles. `T_HD_STA = 10`, `T_SCL_PERIOD = 500`, so SCL must fall within 510 cycles:

```systemverilog
(scl_samp == 1'b1 && sda_fall) |-> ##[1:510] (scl_samp == 1'b0);
```

### 2.7 `$stable(signal)`: What It Means

`$stable(signal)` is true if `signal` has the same value as it had at the PREVIOUS clock edge.

```
Cycle N-1: signal = 1
Cycle N  : signal = 1   → $stable(signal) is TRUE
Cycle N  : signal = 0   → $stable(signal) is FALSE (it changed)
```

**I2C use case**: SDA must not change while SCL is HIGH. We check this by asserting `$stable(sda_samp)` every clock cycle during which SCL is HIGH.

```systemverilog
(scl_samp == 1'b1) |-> $stable(sda_samp);
```

"If SCL is currently HIGH, then SDA must not have changed since the last clock edge."

> **MENTAL MODEL**: `$stable(x)` is not "x is a stable value." It means "x has not changed since the last evaluated clock edge." A signal stuck at X is also `$stable` — which is not what you want. For X/Z checking, use `$isunknown`.

### 2.8 `$rose(signal)` and `$fell(signal)`: Detecting Edges

`$rose(signal)` is true if `signal` was 0 at the previous clock edge and is 1 now (rising edge).

`$fell(signal)` is true if `signal` was 1 at the previous clock edge and is 0 now (falling edge).

```
Cycle:   1    2    3    4    5
signal:  0    0    1    1    0

$rose:        -    -    1    -    -     (true at cycle 3)
$fell:        -    -    -    -    1     (true at cycle 5)
```

Note: `$rose` and `$fell` are evaluated at the clock edge they are sampled. They look at the current vs previous value.

**I2C use case**: Detecting a START condition (SDA falls while SCL is HIGH):

```systemverilog
// Using $fell(sda_samp) — equivalent to sda_fall in this project
property p_start;
  @(posedge clk)
  ($fell(sda_samp) && scl_samp == 1'b1) |-> ##[1:510] $fell(scl_samp);
endproperty
```

In the actual project, `sda_fall` and `scl_fall` are precomputed logic signals derived from a 2-stage pipeline to avoid glitching. Using `$fell` directly on asynchronous bus wires can have metastability issues, which is why the project uses registered versions.

### 2.9 `$isunknown(signal)`: Detecting X/Z

`$isunknown(signal)` is true if ANY bit of `signal` is X or Z.

```systemverilog
$isunknown(sda_samp)   // true if sda_samp is 1'bx or 1'bz
$isunknown(data_bus)   // true if ANY bit of data_bus is X or Z
```

In simulation, X propagates. If a register is never initialized, it stays X. If two drivers fight, the wire becomes Z (or X in some resolvers). `$isunknown` catches these problems during active bus operation — before they corrupt your data.

**Why `$isunknown` matters for I2C**: The I2C bus is open-drain. If both master and slave try to drive SDA at the same time (a multi-driver conflict), the simulation resolver may put Z or X on the wire. A5 in this project catches exactly that.

---

## Part 3: Every Assertion in This Project — Line by Line

### Overview of A1–A6

| Label | Name | What it guards |
|-------|------|----------------|
| A1 | `assert_start` | SCL must fall after START within bounded time |
| A2 | `assert_stop` | Bus must stay free for T_BUF cycles after STOP |
| A3 | `assert_sda_stable` | SDA must not change while SCL is HIGH |
| A4 | `assert_ack_driven` | ACK/NACK bit must not be X/Z |
| A5 | `assert_clk_stretch` | SCL must not be held LOW beyond MAX_CLK_STRETCH |
| A6 | `assert_no_unknown` | No X/Z on bus during active transfer |

---

### A1: START Condition — SCL Must Fall After SDA

**The exact property code**:

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

**Translation to plain English**:

"At every rising edge of `clk`: IF SCL is currently HIGH AND SDA just fell (SDA was 1 last cycle, is 0 now), THEN within the next 1 to `T_HD_STA + T_SCL_PERIOD` cycles (= 510 cycles), SCL must go LOW."

**Why this matters for I2C correctness**:

The I2C START condition is defined as: SDA falls while SCL is HIGH. After the master asserts START, it must follow up by pulling SCL low to begin clocking data. If SCL never falls, the bus is frozen — no data bytes can be transmitted. This assertion catches a master that declares a START but then fails to pull SCL low (for example, a stuck FSM or a clock generation bug like Bug #9 in this project).

`T_HD_STA = 10` clock cycles: the START hold time — the master must hold SDA low for at least this long before pulling SCL low.  
`T_SCL_PERIOD = 500` clock cycles: one full SCL period — even in the worst case, SCL must have fallen within one full period.

**ASCII waveform — PASSING scenario**:

```
Cycle:  1    2    3    4    5    ... 50   51   52
        |    |    |    |    |         |    |    |
SCL:    1    1    1    1    1         1    0    0    <-- SCL falls at cycle 51
SDA:    1    1    0    0    0         0    0    0    <-- SDA fell at cycle 3 (sda_fall=1)

Trigger fires at cycle 3 (sda_fall=1, scl_samp=1).
Window: cycles 4 to 513.
SCL falls at cycle 51 — within window.
RESULT: PASS
```

**ASCII waveform — FAILING scenario**:

```
Cycle:  1    2    3    4    5    ... 513  514  515
        |    |    |    |    |         |    |    |
SCL:    1    1    1    1    1         1    1    1    <-- SCL NEVER falls
SDA:    1    1    0    0    0         0    0    0    <-- SDA fell at cycle 3

Trigger fires at cycle 3.
Window: cycles 4 to 513.
SCL never fell within that window.
RESULT: FAIL — "SCL did not fall after START within 510 cycles"
```

**How this assertion is triggered by a bug**:

Bug #9 in this project was "SCL Permanently LOW During TX." But imagine a bug where the master asserted START (pulled SDA low with SCL high) and then the FSM got stuck in the START state, never transitioning to the SCL-low phase. A1 would fire after 510 cycles with the exact error message pointing to the time of the original START condition.

---

### A2: STOP Condition — Bus Must Stay Free for T_BUF

**The exact property code**:

```systemverilog
property p_stop_cond;
  @(posedge clk)
  disable iff (!rst_n)
  (scl_samp == 1'b1 && sda_rise) |-> ##[1:T_BUF] (scl_samp == 1'b1 && sda_samp == 1'b1);
endproperty

assert_stop: assert property (p_stop_cond)
  else $error("I2C-SVA-A2: Bus not free for T_BUF=%0d cycles after STOP at time %t",
              T_BUF, $time);
```

**Translation to plain English**:

"IF SCL is HIGH AND SDA just rose (SDA transitioned 0->1 while SCL was HIGH — the STOP condition), THEN within the next 1 to T_BUF cycles (= 20 cycles), BOTH SCL and SDA must be HIGH simultaneously."

**Why this matters for I2C correctness**:

The STOP condition releases the bus. After STOP, the I2C spec requires the bus to remain free (both lines HIGH) for at least `T_BUF` before a new START is issued. This prevents the bus from looking like it has a new START condition immediately after the STOP. If a master immediately issues a new START (pulling SDA low) within T_BUF of STOP, another device on the bus might not have registered the STOP yet, causing it to misinterpret the new START as data.

`T_BUF = 20` clock cycles: the minimum bus-free time. At 50 MHz clock / 100 kHz I2C, this is 20 × 20 ns = 400 ns, which is slightly generous but safe.

**ASCII waveform — PASSING scenario**:

```
Cycle:  10   11   12   13   14   15   16   ... 35
        |    |    |    |    |    |    |         |
SCL:    1    1    1    1    1    1    1         1    <-- stays HIGH
SDA:    0    1    1    1    1    1    1         1    <-- rose at cycle 11 (STOP)

Trigger fires at cycle 11 (sda_rise=1, scl_samp=1).
Property: within cycles 12 to 31, both must be HIGH.
At cycle 12: SCL=1, SDA=1. PASS.
```

**ASCII waveform — FAILING scenario**:

```
Cycle:  10   11   12   13   14   15
        |    |    |    |    |    |
SCL:    1    1    1    1    1    1
SDA:    0    1    0    0    0    0    <-- SDA went LOW again at cycle 12 (new START too soon!)

Trigger fires at cycle 11.
Window: cycles 12 to 31.
At cycle 12: SDA = 0. Not (SCL=1 && SDA=1).
Window expires at cycle 31 — condition never satisfied.
RESULT: FAIL — "Bus not free for T_BUF=20 cycles after STOP"
```

**How this assertion is triggered by a bug**:

A master driver bug that issues back-to-back transactions without respecting T_BUF. For example, a burst mode that skips the inter-transaction gap. Without this assertion, the violation would be invisible — the scoreboard would check data, not timing.

---

### A3: SDA Stability During SCL High — The Most Important I2C Rule

**The exact property code**:

```systemverilog
property p_sda_stable_scl_high;
  @(posedge clk)
  disable iff (!rst_n)
  ((in_data_phase || in_ack_phase) && scl_samp == 1'b1
   && !start_cond_asserted && !stop_cond_asserted) |-> $stable(sda_samp);
endproperty

assert_sda_stable: assert property (p_sda_stable_scl_high)
  else $error("I2C-SVA-A3: SDA changed while SCL high at time %t", $time);
```

**Translation to plain English**:

"IF we are in a data or ACK transfer phase, AND SCL is currently HIGH, AND this cycle is NOT a START condition, AND this cycle is NOT a STOP condition — THEN SDA must not have changed since the last clock edge."

**Why this matters for I2C correctness**:

This is the FUNDAMENTAL I2C rule. SDA is only allowed to change when SCL is LOW. When SCL is HIGH, SDA must be completely stable — that is when the receiver samples the bit. If SDA changes while SCL is HIGH (and it is not an intentional START or STOP), the receiver sees a corrupted bit. Every data bit, every address bit, every ACK bit — all of them must be presented on SDA only during SCL HIGH periods and changed only during SCL LOW periods.

The exceptions (START and STOP) are built into the assertion: `!start_cond_asserted && !stop_cond_asserted`. START is defined as SDA falling while SCL is HIGH. STOP is SDA rising while SCL is HIGH. Without these exceptions, the assertion would fire every time you tried to generate a START or STOP condition.

The `in_data_phase || in_ack_phase` guard ensures we only check during active transfers. When the bus is idle (both lines HIGH), there is no need to enforce this rule.

**ASCII waveform — PASSING scenario**:

```
Cycle:  1    2    3    4    5    6    7    8
        |    |    |    |    |    |    |    |
SCL:    0    0    1    1    1    1    0    0
SDA:    X    0    0    0    0    0    1    1   <-- SDA changes ONLY when SCL=0
in_data_phase: 1   1   1   1   1   1   1   1

Cycle 3: SCL went HIGH. SDA=0. Assertion triggers.
  $stable(sda_samp)? Prev=0, Now=0. Yes. PASS.
Cycle 4: SCL=1. SDA=0. $stable? Yes. PASS.
Cycle 5: SCL=1. SDA=0. $stable? Yes. PASS.
Cycle 6: SCL=1. SDA=0. $stable? Yes. PASS.
Cycle 7: SCL went LOW. SDA changes to 1. Assertion does NOT fire (SCL is 0).
```

**ASCII waveform — FAILING scenario**:

```
Cycle:  1    2    3    4    5    6    7    8
        |    |    |    |    |    |    |    |
SCL:    0    0    1    1    1    1    0    0
SDA:    X    0    0    0    1    0    1    1   <-- SDA CHANGED at cycle 5 while SCL=1!
in_data_phase: 1   1   1   1   1   1   1   1

Cycle 5: SCL=1. Assertion triggers.
  $stable(sda_samp)? Prev=0, Now=1. NO.
RESULT: FAIL — "SDA changed while SCL high at time [cycle 5 time]"
```

**How this assertion is triggered by a bug**:

Any timing violation in the master controller's SDA drive logic. For example, if the `T_HD_DAT` hold time is violated — the master changes SDA too soon after SCL falls, and if the clock sampling in the assertion catches it while SCL is still high. Or if the data MUX logic has a glitch that briefly changes SDA. Without A3, these glitches would corrupt received bits silently.

---

### A4: ACK/NACK Bit Must Not Be X/Z

**The exact property code**:

```systemverilog
property p_ack_driven;
  @(posedge clk)
  disable iff (!rst_n)
  (in_ack_phase && scl_samp == 1'b1) |->
  (!$isunknown(sda_samp));
endproperty

assert_ack_driven: assert property (p_ack_driven)
  else $error("I2C-SVA-A4: ACK/NACK bit is X/Z at time %t", $time);
```

**Translation to plain English**:

"IF we are in the ACK phase (9th clock cycle) AND SCL is HIGH, THEN SDA must not be X or Z."

**Why this matters for I2C correctness**:

The ACK bit is critical. The slave drives SDA LOW for ACK, or releases it (HIGH) for NACK. If SDA is X or Z during the ACK clock, it means either: (a) no driver is driving it, or (b) multiple conflicting drivers. Both are RTL bugs. Bug #2 in this project was exactly this: the slave had no TX shift register and drove high-Z during read transactions. The ACK bit would have been Z, and A4 would have caught it.

**ASCII waveform — PASSING scenario**:

```
Cycle:  ...  45   46   47   48
             |    |    |    |
SCL:         0    1    1    0
SDA:         Z    0    0    Z   <-- slave drives SDA=0 (ACK) while SCL=1
in_ack_phase:1    1    1    0

Cycle 46: in_ack_phase=1, scl_samp=1.
  $isunknown(sda_samp)? sda_samp=0. No. !$isunknown = TRUE. PASS.
```

**ASCII waveform — FAILING scenario**:

```
Cycle:  ...  45   46   47   48
             |    |    |    |
SCL:         0    1    1    0
SDA:         Z    Z    Z    Z   <-- slave never drives SDA — it's floating!
in_ack_phase:1    1    1    0

Cycle 46: in_ack_phase=1, scl_samp=1.
  $isunknown(sda_samp)? sda_samp=1'bz. YES. !$isunknown = FALSE.
RESULT: FAIL — "ACK/NACK bit is X/Z"
```

---

### A5: Clock Stretch Bounded — The Slave Must Release SCL

**The exact property code**:

```systemverilog
logic [15:0] scl_low_counter;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    scl_low_counter <= 16'd0;
  end else begin
    if (scl_samp == 1'b0) begin
      scl_low_counter <= scl_low_counter + 1'b1;
    end else begin
      scl_low_counter <= 16'd0;
    end
  end
end

property p_clk_stretch_bounded;
  @(posedge clk)
  disable iff (!rst_n)
  (scl_samp == 1'b0) |-> (scl_low_counter < MAX_CLK_STRETCH);
endproperty

assert_clk_stretch: assert property (p_clk_stretch_bounded)
  else $error("I2C-SVA-A5: Clock stretch exceeded %0d cycles at time %t",
              MAX_CLK_STRETCH, $time);
```

**Translation to plain English**:

"Every clock cycle that SCL is LOW, the counter of how long SCL has been LOW must be less than MAX_CLK_STRETCH (= 1000 cycles). If SCL has been LOW for 1000 or more cycles, this assertion fails."

**Why this matters for I2C correctness**:

Clock stretching is a feature that allows an I2C slave to hold SCL LOW to buy time for slow processing. But it is supposed to be temporary. A slave bug (like Bug #3 in this project — stretch returning to idle) or a hung FSM could cause SCL to be held LOW indefinitely, freezing the entire I2C bus. No other device can communicate while SCL is stuck. This assertion gives the design a hard limit.

`MAX_CLK_STRETCH = 1000` clock cycles at 50 MHz = 20 microseconds. Any stretch longer than this is caught immediately.

Note the implementation detail: instead of `##[0:1000]` in the property (which would spawn 1000 pending threads per evaluation — a simulation performance disaster), the project uses a counter that is checked in a single-cycle property. This is the right way to write a "bounded-duration" assertion.

**ASCII waveform — PASSING scenario**:

```
Cycle:   1    2    3    4    5  ...  50   51   52
         |    |    |    |    |        |    |    |
SCL:     1    0    0    0    0  ...   0    1    1   <-- SCL low for 49 cycles, then rises
counter: 0    1    2    3    4  ...  49    0    0

At cycle 51: scl_samp=1. counter resets to 0.
At no point did counter reach 1000. PASS.
```

**ASCII waveform — FAILING scenario**:

```
Cycle:   1    2    ...  1000  1001  1002
         |    |          |     |     |
SCL:     0    0    ...   0     0     0    <-- SCL NEVER rises
counter: 1    2    ...  999  1000  1001

Cycle 1001: scl_samp=0. counter=1000. 
  Property checks: counter < MAX_CLK_STRETCH? 1000 < 1000? NO.
RESULT: FAIL — "Clock stretch exceeded 1000 cycles"
```

---

### A6: No Unknown Values on Bus During Active Transfer

**The exact property code**:

```systemverilog
property p_no_unknown_bus;
  @(posedge clk)
  disable iff (!rst_n)
  (in_data_phase || in_ack_phase) |-> (!$isunknown(sda_samp) && !$isunknown(scl_samp));
endproperty

assert_no_unknown: assert property (p_no_unknown_bus)
  else $error("I2C-SVA-A6: X/Z detected on bus during active transfer at time %t", $time);
```

**Translation to plain English**:

"IF we are in a data or ACK transfer phase, THEN BOTH sda_samp and scl_samp must be free of X and Z values."

**Why this matters for I2C correctness**:

This is a simulation health check. In real hardware, signals cannot be X or Z (they are always 0 or 1). In simulation, X means "uninitialized" and Z means "floating/high-impedance." If either bus line is X or Z during a live transfer:

- SCL being X means your clock generation logic has a bug or multi-driver conflict.
- SDA being X means the driver has uninitialized registers or a multi-driver conflict.
- Both being Z means the pull-up resistors have no competing driver — the bus is not being driven.

Note that A4 (ACK phase) and A6 (entire transfer) overlap for ACK cycles. A4 only checks SDA during ACK SCL high. A6 checks both signals during the entire transfer. They are complementary, not redundant.

**How this is triggered by a bug**:

Multi-driver conflicts. In the `i2c_if.sv` interface, both master and slave drive through open-drain logic. If both try to drive SDA=1'b0 (both pull-down active) simultaneously without a wired-AND resolver, the simulation might produce X. A6 would catch this immediately on the next clock cycle.

---

## Part 4: The Tautology Problem — Bugs #11 and #12

This is the most important section of this entire document. Read it carefully.

### 4.1 What Is a Tautological Assertion?

A tautology is a statement that is ALWAYS TRUE regardless of what the design does.

In logic: `A → A` is always true. "If it is raining, then it is raining." You learn nothing.

In SVA: if the antecedent IMPLIES the consequent by pure logic (not by design behavior), the assertion can never fail. It is syntactically an assertion. It compiles. The simulator runs it. It passes. But it tells you NOTHING about the correctness of your design.

> **MENTAL MODEL**: Think of a tautological assertion as a smoke detector with no battery. It is physically present. You can see it on the ceiling. But it will never alarm, even when the house is on fire.

### 4.2 Bug #11: The Original A1 Was a Tautology

The original A1 assertion (before the fix) was:

```systemverilog
// BROKEN — DO NOT USE — TAUTOLOGY
property p_start_cond_BAD;
  @(posedge clk)
  disable iff (!rst_n)
  (scl_samp == 1'b1 && sda_fall) |-> (scl_samp == 1'b1);
endproperty
```

Let us prove this is always true:

**Step 1**: When does the antecedent fire?
The antecedent fires when: `scl_samp == 1'b1` AND `sda_fall` is true.

**Step 2**: What is the consequent?
The consequent is: `scl_samp == 1'b1`

**Step 3**: Can the consequent ever be false when the antecedent is true?
The antecedent ALREADY REQUIRES that `scl_samp == 1'b1` is true. So when the antecedent is satisfied, `scl_samp` is guaranteed to be 1. The consequent (`scl_samp == 1'b1`) is PART OF THE ANTECEDENT.

**Conclusion**: This property says "IF SCL is HIGH (and SDA fell), THEN SCL is HIGH." That is logically equivalent to `True |-> True`. It can NEVER fail. It has ZERO verification value.

```
Proof by inspection:
  Antecedent: (scl_samp == 1 AND sda_fall)
  Consequent: (scl_samp == 1)
  
  For antecedent to be TRUE: scl_samp MUST be 1.
  For consequent to be FALSE: scl_samp MUST be 0.
  
  Both cannot hold simultaneously.
  Therefore: whenever antecedent is true, consequent is always true.
  QED: Tautology.
```

**What was this assertion supposed to check?**

Presumably, someone wanted to verify "SDA falls while SCL is HIGH = valid START condition." But the consequent just re-checks the same thing. The REAL check should be: "After START, does the master pull SCL LOW within the required time?" — which requires temporal reasoning.

**The fix (current A1)**:

```systemverilog
// CORRECT — meaningful temporal check
(scl_samp == 1'b1 && sda_fall) |-> ##[1:(T_HD_STA + T_SCL_PERIOD)] (scl_samp == 1'b0);
```

Now the consequent (`scl_samp == 1'b0`) CONTRADICTS the antecedent (`scl_samp == 1'b1`). For the consequent to be satisfied, SCL must eventually go LOW — something that was HIGH when the antecedent fired. This requires actual design behavior. This can FAIL if the design is broken.

### 4.3 Bug #12: The Original A2 Was a Tautology

The original A2 assertion (before the fix) was:

```systemverilog
// BROKEN — DO NOT USE — TAUTOLOGY
property p_stop_cond_BAD;
  @(posedge clk)
  disable iff (!rst_n)
  (scl_samp == 1'b1 && sda_rise) |-> (scl_samp == 1'b1 && sda_samp == 1'b1);
endproperty
```

Proof:

**Part 1**: `scl_samp == 1'b1` is in the antecedent. So the consequent's `scl_samp == 1'b1` is guaranteed.

**Part 2**: `sda_rise` is defined as `(sda_d == 1'b0 && sda_samp == 1'b1)`. So `sda_rise` being true IMPLIES `sda_samp == 1'b1`. The consequent's `sda_samp == 1'b1` is guaranteed by the `sda_rise` definition.

**Conclusion**: Both parts of the consequent are logically implied by the antecedent. This is also a tautology.

```
sda_rise definition: (sda_d == 0) AND (sda_samp == 1)
                                          ^^^^^^^^^^^ this is part of the definition
                                          
Antecedent: (scl_samp == 1) AND sda_rise
                                  = (scl_samp == 1) AND (sda_d == 0) AND (sda_samp == 1)

Consequent: (scl_samp == 1) AND (sda_samp == 1)
            ^^^^^^^^^^^^^^^       ^^^^^^^^^^^^^
            Same as antecedent    Implied by sda_rise in antecedent

Both consequent terms are subsets of the antecedent terms.
Tautology.
```

**The fix (current A2)**:

```systemverilog
// CORRECT — temporal check for bus-free period
(scl_samp == 1'b1 && sda_rise) |-> ##[1:T_BUF] (scl_samp == 1'b1 && sda_samp == 1'b1);
```

Adding `##[1:T_BUF]` makes this temporal. It says "at some point between 1 and 20 cycles in the FUTURE, both must be HIGH." Since `##[1:T_BUF]` means the consequent is evaluated in FUTURE cycles (not the current cycle), SDA could have fallen (new START) before T_BUF expires, making the property FALSE. Now it can fail.

### 4.4 How to Detect a Tautological Assertion — The Method

When reviewing an assertion, apply this 3-step test:

**Step 1**: Write out all terms in the antecedent as a set: `{A1, A2, A3, ...}`

**Step 2**: Write out all terms in the consequent as a set: `{C1, C2, C3, ...}`

**Step 3**: For each consequent term `Ci`, ask: "Is Ci logically implied by the antecedent set?"
- If Ci is directly in the antecedent: YES, implied.
- If Ci follows from definitions of antecedent terms: YES, implied.
- If Ci requires future or external behavior: NO, not implied.

**If ALL consequent terms are implied: TAUTOLOGY. Rewrite.**

**Step 4**: Ask the gold question: "What design behavior would cause this property to FAIL?"
If you cannot describe a specific, concrete design failure mode that this assertion would catch, it is either a tautology or a dead assertion (never fires). Both are useless.

---

## Part 5: How to Write Good Assertions — The Senior Process

This is the workflow a senior engineer uses. Follow these steps every time.

### Step 1: Start With the Protocol Spec

Open the spec (for I2C: NXP UM10204). Find the rule in plain English:

> "During the data transfer, the data on the SDA line must be stable during the HIGH period of the clock. The HIGH or LOW state of the data line can only change when the clock signal on the SCL line is LOW."

Annotate it:
- Trigger: "clock signal on SCL line is HIGH" (SCL transitions from LOW to HIGH and is currently HIGH)
- Rule: "data on SDA must be stable" (SDA must not change)
- Exception: START and STOP conditions are intentional SDA changes during SCL HIGH

### Step 2: Write the Temporal Property

Identify:
1. **TRIGGER** (antecedent): When does this rule apply?
   `(in_data_phase || in_ack_phase) && scl_samp == 1'b1 && !start_cond_asserted && !stop_cond_asserted`

2. **CONSEQUENCE** (what must be true): What must hold?
   `$stable(sda_samp)` — SDA has not changed since last clock

3. **Timing**: Same cycle (`|->`) or next cycle (`|=>`)?
   Same cycle — if SCL is HIGH right now, SDA must be stable right now.

Result:
```systemverilog
property p_sda_stable_scl_high;
  @(posedge clk)
  disable iff (!rst_n)
  ((in_data_phase || in_ack_phase) && scl_samp == 1'b1
   && !start_cond_asserted && !stop_cond_asserted) |-> $stable(sda_samp);
endproperty
```

### Step 3: Verify the Assertion Is NOT a Tautology

Apply the 3-step tautology test:
- Antecedent terms: `in_data_phase || in_ack_phase`, `scl_samp == 1'b1`, `!start_cond_asserted`, `!stop_cond_asserted`
- Consequent: `$stable(sda_samp)`

Is `$stable(sda_samp)` implied by the antecedent? NO. The antecedent says nothing about what SDA was in the previous cycle. A design could have SCL HIGH and SDA changing simultaneously. The assertion CAN fail.

Gold question: "What design behavior would cause this to fail?" → Any master or slave driver that changes SDA while SCL is HIGH (outside of START/STOP). Yes, concrete. Good assertion.

### Step 4: Write a Simulation Test That FAILS the Assertion

This is non-negotiable. If you cannot write a test that causes the assertion to fail, you do not know if the assertion works.

For A3 (SDA stability):

```systemverilog
// In a directed test or sequence:
task inject_sda_glitch_during_scl_high();
  // Pull SDA low to start driving it
  vif.sda_drv <= 1'b0;
  repeat(10) @(posedge clk);  // Let SCL go HIGH
  // While SCL is HIGH, glitch SDA — VIOLATION
  @(posedge clk);
  vif.sda_drv <= 1'b1;        // SDA changes while SCL is HIGH
  repeat(5) @(posedge clk);
  // Expect assertion A3 to fire here
endtask
```

Run this. Watch for the `$error` message from assert_sda_stable. If it fires: the assertion works. If it does not fire: check your `in_data_phase` guard — maybe the phase tracker is not enabled.

---

## Part 6: Assertion Severity and Reporting

### 6.1 The Three Keywords: `assert`, `assume`, `cover`

**`assert property`**: "This must be true. If it fails, it is a BUG."
- In simulation: failure generates an error message and may stop simulation.
- In formal: the tool tries to DISPROVE this. If it cannot, the property is proven.

```systemverilog
assert_sda_stable: assert property (p_sda_stable_scl_high)
  else $error("A3 failed at %t", $time);
```

**`assume property`**: "Treat this as an AXIOM. Trust me it will always be true."
- In simulation: also checked (behaves like assert).
- In formal: the tool uses this as a CONSTRAINT. It only explores states where this is true. Used to constrain inputs to valid protocol sequences.

```systemverilog
// Tell formal tools: SCL is only driven by the master
assume property (@(posedge clk) (scl_samp == 1'b0) |-> (master_scl_drive == 1'b0));
```

**`cover property`**: "Count how many times this scenario happens."
- Does NOT fail. Does NOT check anything.
- Counts how many times the property was satisfied.
- Used to verify that your test is actually exercising the scenario you intend.

```systemverilog
// Count START conditions observed
cov_start: cover property (@(posedge clk) disable iff(!rst_n)
  (scl_samp == 1'b1 && sda_fall));
```

### 6.2 Custom Failure Messages

Always include context in your `$error` message:

```systemverilog
assert_start: assert property (p_start_cond)
  else $error("I2C-SVA-A1: SCL did not fall after START within %0d cycles at time %t",
              T_HD_STA + T_SCL_PERIOD, $time);
```

The `%0d` prints the exact limit. The `%t` prints the simulation time in the native time unit. When you open the log file, you see exactly when and where the violation occurred.

You can also use `$display` in the failure block for additional debug info:

```systemverilog
assert_sda_stable: assert property (p_sda_stable_scl_high)
  else begin
    $error("I2C-SVA-A3: SDA changed while SCL high at time %t", $time);
    $display("  SDA previous: %b  SDA now: %b  SCL: %b", sda_d, sda_samp, scl_samp);
  end
```

### 6.3 Severity Levels

SystemVerilog provides four severity levels for the failure block:

| Keyword | Effect |
|---------|--------|
| `$info` | Prints message, simulation continues |
| `$warning` | Prints warning, simulation continues |
| `$error` | Prints error, simulation continues (but error count increases) |
| `$fatal` | Prints error, STOPS simulation immediately |

For protocol violations that corrupt all subsequent behavior (like SDA-during-SCL-HIGH), `$fatal` may be more appropriate. For soft violations where you want to collect all failures, use `$error`.

---

## Part 7: Assertion Coverage

### 7.1 What Is Assertion Coverage?

Assertion coverage answers: "Were my assertions actually exercised?"

There are two types:
1. **Attempt count**: How many times was the antecedent true? (How many times did the assertion "fire"?)
2. **Pass/fail count**: Of those attempts, how many passed? How many failed?

Most simulators (Cadence, Synopsys, Mentor) report assertion coverage automatically when you run with the right flags.

### 7.2 The Dead Assertion Problem

An assertion that NEVER FIRES is as useless as a tautological assertion.

Consider:

```systemverilog
property p_dead;
  @(posedge clk)
  (in_data_phase && scl_samp == 1'b1 && in_ack_phase) |-> $stable(sda_samp);
endproperty
```

`in_data_phase && in_ack_phase` can never be simultaneously true (they are mutually exclusive by design). This antecedent is always false. The assertion never fires. It never passes or fails. It is a dead assertion.

**How to detect dead assertions**:
Look at the assertion attempt count in your coverage report. If attempts = 0, the assertion is dead. Either:
1. The antecedent condition is logically impossible.
2. Your tests never drive the design into the state that triggers the antecedent.

In case 1: fix the assertion. In case 2: add tests.

### 7.3 The `cover property` Construct for Reachability

Before relying on an assertion, verify its antecedent is reachable:

```systemverilog
// Coverage point: verify we actually reach the ACK phase with SCL HIGH
cov_ack_phase_scl_high: cover property (
  @(posedge clk) disable iff (!rst_n)
  (in_ack_phase && scl_samp == 1'b1)
);
```

Run your tests. Check the coverage report. If this cover property has zero hits, then A4 (`assert_ack_driven`) can never fire — your test did not generate any ACK cycles with SCL HIGH. The assertion may look like it is passing (it is vacuously true), but it has verified nothing.

---

## Part 8: Formal Verification vs Simulation

### 8.1 How SVA Is Used in Simulation

In simulation:
- The testbench drives stimulus.
- The design runs for N clock cycles.
- Each assertion is evaluated on each clock edge it covers.
- If an assertion fails at any point, the error is logged.

Limitation: You only cover the states your testbench visits. If a bug only manifests in a state your testbench never reaches, simulation will not find it.

### 8.2 How SVA Is Used in Formal Verification

In formal model checking (tools: JasperGold, VC Formal, etc.):
- No testbench is needed.
- The tool mathematically explores ALL possible state sequences.
- It tries to find a counterexample that VIOLATES an `assert property`.
- If no counterexample exists: the property is PROVEN correct for all inputs and all time.

This is fundamentally different. Simulation says "we tried a lot and didn't find a bug." Formal says "we proved there is NO bug for this property."

### 8.3 The `assume` Keyword in Formal

Formal tools explore everything, including impossible inputs. If your protocol says "SCL is always driven by the master and never by the slave," you need to tell the formal tool to only explore scenarios where that is true:

```systemverilog
// Formal constraint: slave never drives SCL
assume property (@(posedge clk) disable iff(!rst_n)
  !(slave_scl_drive == 1'b0 && master_scl_drive == 1'b1));
```

Without this, the formal tool might find "counterexamples" that involve the slave illegally driving SCL — scenarios that cannot occur in practice. The `assume` narrows the explored state space to what is physically possible.

> **TRAP**: In simulation, `assume` behaves like `assert`. It also checks the assumed condition. This is useful — it validates your assumptions are not violated by the testbench.

### 8.4 Bounded vs Unbounded Model Checking

For properties with large bounds (like `##[0:1000]` in A5 if it were written that way), full formal verification would require exploring 1000-step sequences — computationally expensive. Bounded Model Checking (BMC) explores up to N steps. It proves "no violation in the first N cycles" rather than "no violation ever."

This is why A5 in this project was reimplemented with a counter and a single-cycle check. The counter encodes the temporal history as state, reducing the formal depth needed.

---

## Part 9: Common SVA Mistakes

### Mistake 1: Forgetting `disable iff (!rst_n)`

```systemverilog
// WRONG — fires at reset
property p_bad;
  @(posedge clk)
  (scl_samp == 1'b0) |-> (scl_low_counter < MAX_CLK_STRETCH);
endproperty
```

At time 0, SCL is probably 0 (default), and `scl_low_counter` is X. The assertion fires immediately with false failure.

Fix: always add `disable iff (!rst_n)`.

### Mistake 2: Using `|->` When You Need `|=>`

```systemverilog
// WRONG for one-cycle-delayed ACK
property p_ack_timing_wrong;
  @(posedge clk)
  (cmd_issued) |-> (ack_received);   // Same cycle — impossible if ACK is pipelined
endproperty
```

If `ack_received` is registered (appears one cycle after the command), this always fails because the command and ACK cannot be in the same cycle.

Fix: `(cmd_issued) |=> (ack_received);`

### Mistake 3: Writing the Wrong Edge

```systemverilog
// WRONG for I2C edge-triggered sampling
property p_wrong_edge;
  @(negedge clk)    // I2C data is sampled on posedge in this design
  ...
endproperty
```

All logic in this project samples on posedge. Using negedge gives you a half-cycle-offset view that does not match how the RTL samples signals.

### Mistake 4: Overlapping Properties That Contradict

```systemverilog
// Assertion 1: SDA must be HIGH during stop
assert property (stop_cond |-> (sda_samp == 1'b1));

// Assertion 2: SDA must ALWAYS be stable when SCL is high (without exception)
assert property ((scl_samp == 1'b1) |-> $stable(sda_samp));
```

Assertion 2, without the `!stop_cond_asserted` exclusion, will fire during every STOP condition (because SDA rises during STOP while SCL is HIGH — which is not stable, it is changing). The assertions contradict each other during the STOP event. Both fire. One passes. One fails. You chase a phantom bug.

This is exactly why A3 includes `!stop_cond_asserted` in its antecedent.

### Mistake 5: Not Checking If the Antecedent Is Ever True

Write a `cover property` for every `assert property` antecedent. Run your tests. Verify the cover count is non-zero. This confirms your assertions are actually being exercised.

---

## Part 10: Interview Questions — SVA

The following questions span entry level to senior. Work through each one.

---

**Q1**: What is the difference between `|->` and `|=>`?

`|->` (overlapping) evaluates the consequent starting in the SAME cycle as the antecedent. `|=>` (non-overlapping) evaluates the consequent starting in the NEXT cycle. `(A |=> B)` is exactly equivalent to `(A |-> ##1 B)`. Use `|->` for same-cycle relationships, `|=>` for one-cycle-later relationships.

---

**Q2**: What does `##[1:5]` mean in a property?

"At some clock cycle between 1 and 5 cycles after the current evaluation point." The property passes if the following expression is true in ANY of those cycles. If none of cycles 1 through 5 satisfy the expression, the property fails.

---

**Q3**: What is `disable iff` and when do you use it?

`disable iff (condition)` suspends the assertion when the condition is true. It is used to suppress assertion evaluation during reset or other invalid operational modes. Without it, assertions fire during reset and generate false failures. The `disable iff` condition is evaluated continuously (asynchronously) — unlike the rest of the property which is clocked.

---

**Q4**: What is a tautological assertion? Give an example.

A tautological assertion is one whose consequent is logically guaranteed by the antecedent, so the property can never fail regardless of design behavior. Example from this project:
```
(scl_samp == 1'b1 && sda_fall) |-> (scl_samp == 1'b1)
```
The antecedent requires `scl_samp == 1'b1`, so the consequent is trivially true. This provides zero verification value.

---

**Q5**: How do you verify that an assertion can actually fail?

Write a directed test (or directed UVM sequence) that intentionally violates the rule the assertion is checking. Run simulation with that test. Confirm the assertion fires with its error message. If the assertion does not fire, either the test is not triggering the antecedent, or the assertion is a tautology. Use `cover property` on the antecedent to confirm it fires.

---

**Q6**: What is `$stable()` and when is it useful?

`$stable(signal)` returns true if `signal` has not changed from the previous clock evaluation. It is useful for checking that a signal remains constant during a window when it must not change. In I2C, `$stable(sda_samp)` checks that SDA has not toggled since the last clock edge — used in A3 to verify SDA stability during SCL HIGH.

---

**Q7**: What is the difference between `assert`, `assume`, and `cover`?

- `assert property`: The property MUST be true. Violation = bug. In formal: proven or counterexample found.
- `assume property`: Treat as a constraint. In formal tools, the tool only explores states consistent with this constraint. In simulation, also checked.
- `cover property`: Counts how many times the scenario is observed. Does not fail. Used to verify scenarios are being exercised.

---

**Q8**: How would you write an assertion for "ACK must come within 9 SCL cycles of START"?

```systemverilog
property p_ack_within_9_clocks;
  @(posedge clk)
  disable iff (!rst_n)
  (start_cond_asserted) |-> ##[9*T_SCL_PERIOD : 10*T_SCL_PERIOD] (in_ack_phase && scl_samp == 1'b1);
endproperty
```

After the START condition, the master transmits 8 data bits (the address byte with R/W), then the 9th SCL clock is the ACK. At `T_SCL_PERIOD = 500` cycles per SCL clock, the ACK SCL HIGH should arrive around 9 × 500 = 4500 clock cycles after START.

---

**Q9**: What is assertion coverage and how is it different from functional coverage?

**Assertion coverage** measures how often each SVA property fires (attempts, passes, failures). It tells you if your assertions are being exercised by your tests.

**Functional coverage** (covergroups, coverpoints) measures if your tests have explored all specified scenarios in the design's input space. It tells you if your tests are comprehensive.

They are orthogonal. A test can have 100% functional coverage but dead assertions (assertion coverage = 0%). Both need to be at target before you can claim the design is fully verified.

---

**Q10**: How would you debug a failing assertion?

1. Note the time of failure from the `$error` message.
2. Open the waveform viewer. Go to that time.
3. Look at the assertion module signals: `sda_samp`, `scl_samp`, `in_data_phase`, `in_ack_phase`, `sda_fall`, etc.
4. Find the exact cycle where the antecedent fired and what the consequent evaluated to.
5. Trace back: who drove SDA to change? Why was SCL HIGH?
6. Identify the RTL module responsible and check its state machine.

---

**Q11**: What is the difference between immediate and concurrent assertions?

**Immediate assertions** execute inside procedural code (`always`, `initial`, tasks). They check a condition at a single instant. They cannot span multiple cycles.

**Concurrent assertions** run parallel to simulation, evaluated at every relevant clock edge. They can express temporal relationships across multiple cycles using `##`, `|->`, `$stable`, etc. They can be used with formal verification tools. They are the primary tool for protocol verification.

---

**Q12**: How does formal verification use SVA differently from simulation?

In simulation, assertions are checked on the specific stimulus driven by the testbench. Coverage depends on the quality of the tests.

In formal, the tool mathematically exhausts all possible input sequences and proves whether an `assert property` can ever be violated. No testbench is needed. The tool either finds a counterexample (proof of bug) or proves the property holds for all possible inputs (formal proof). `assume property` constraints limit the input space to legal protocol inputs. The result is a PROOF, not just "no bug found in our tests."

---

**Q13**: Write an assertion for "After STOP, SDA must remain HIGH for at least T_BUF cycles."

```systemverilog
property p_bus_free_after_stop;
  @(posedge clk)
  disable iff (!rst_n)
  // STOP: SDA rises while SCL is HIGH
  (scl_samp == 1'b1 && sda_rise) |->
  // SDA must remain HIGH for ALL of the next T_BUF cycles
  // Use a consecutive repetition operator:
  ##1 (sda_samp == 1'b1)[*T_BUF];
endproperty
```

The `[*N]` repetition means "N consecutive cycles where this is true." This is a STRONGER check than the project's A2, which only requires the condition to be true at SOME point within T_BUF.

---

**Q14**: What does `$rose(signal)` mean? How is it different from a plain edge detect?

`$rose(signal)` is true when `signal` has transitioned from 0 to 1 across the most recent clock edge. It samples `signal` at the previous clock edge (value was 0) and at the current clock edge (value is now 1).

A "plain edge detect" in RTL typically means comparing `signal` to a registered version: `signal && !signal_d`. The difference is that `$rose` is a built-in SVA sampled function — it uses the same sampling mechanism as the rest of the property, ensuring it is glitch-free and consistent with the assertion's clock.

In this project, `sda_fall` is implemented as a manual edge detect (`sda_d == 1'b1 && sda_samp == 1'b0`) rather than `$fell(sda)` on the raw wire, because the raw wire may have glitches before the registered pipeline filters them.

---

**Q15**: If an assertion never fires during simulation, is that good or bad?

It depends on WHY it never fired:
- **Good**: The design is correct and the rule was never violated. (But verify with `cover property` that the antecedent was actually tested.)
- **Bad**: The assertion is a tautology (antecedent implies consequent trivially — can never fail).
- **Bad**: The assertion is dead (antecedent is logically impossible or never triggered by the tests).

"Never fired" means zero attempts. In your coverage report, attempt count = 0. This always warrants investigation.

---

**Q16**: What are the timing parameters used in the assertions, and where are they defined?

They are defined in `/rtl/i2c_pkg.sv` as package parameters:
- `T_HD_STA = 10` — START hold time (10 clock cycles = 200 ns at 50 MHz)
- `T_SCL_PERIOD = 500` — SCL full period (10 microseconds at 50 MHz)
- `T_BUF = 20` — Bus free time after STOP (400 ns at 50 MHz)
- `MAX_CLK_STRETCH = 1000` — Maximum clock stretch duration

The assertion module imports the package: `import i2c_pkg::*;`

---

**Q17**: Why does the project use a counter register for A5 instead of `##[0:MAX_CLK_STRETCH]`?

If `MAX_CLK_STRETCH = 1000` and you write `(scl_samp == 1'b0) |-> ##[0:1000] (scl_samp == 1'b1)`, the simulator spawns a NEW pending evaluation thread every cycle that SCL is LOW. Each thread waits up to 1000 cycles. If SCL is LOW for 500 cycles, you have 500 active threads simultaneously. This destroys simulation performance.

The counter approach encodes the elapsed time as state in a register. Then the property is a simple single-cycle check: "is the counter below the limit?" — one evaluation per clock, no thread explosion.

---

**Q18**: In the assertion module, why are `sda_samp` and `sda_d` used instead of `sda` directly?

The raw `sda` wire is asynchronous — it can change at any time, including between clock edges, potentially causing glitches. By sampling through `sda_samp` (registered once) and then `sda_d` (registered again), the project creates a clean 2-stage synchronizer that:
1. Removes metastability issues from sampling an asynchronous signal.
2. Provides a clean registered version for edge detection (`sda_fall`, `sda_rise`).
3. Ensures assertions evaluate stable, glitch-free values.

---

**Q19**: What happens to a concurrent assertion during a reset if `disable iff` is present?

When `disable iff (!rst_n)` is included and `rst_n` goes LOW:
- All currently active assertion threads are immediately killed (vacuously abandoned).
- No new threads are started while `rst_n` is LOW.
- When `rst_n` goes HIGH, the assertion resumes evaluating normally from that point.

The `disable iff` condition is asynchronous — it is evaluated continuously, not just at clock edges. The moment `rst_n` falls, even mid-evaluation, all pending threads are terminated.

---

**Q20**: A junior engineer says: "My assertions all passed, so the design is verified." What is wrong with this reasoning?

Multiple things:
1. **Dead assertions**: If assertion attempt counts are zero, they verified nothing.
2. **Tautological assertions**: If the assertions can never fail by construction, they verified nothing.
3. **Assertion coverage gaps**: The assertions may not cover all protocol rules.
4. **Test coverage gaps**: The tests may not exercise all design states.
5. **Formal vs simulation**: Simulation only covers the states your tests visit; there may be bugs in untested states.

Correct reasoning: "My assertions all passed AND my `cover property` checks confirm antecedents fired with non-zero counts AND I applied the tautology test to each assertion AND my functional coverage closure targets are met."

---

## Appendix: Quick Reference — SVA Cheatsheet

```
Basics:
  property p_name; ... endproperty
  assert property (p_name) else $error("msg");
  assume property (p_name);
  cover property (p_name);

Clocking:
  @(posedge clk)         -- evaluate on rising edge
  @(negedge clk)         -- evaluate on falling edge

Reset:
  disable iff (!rst_n)   -- suspend when rst_n is LOW

Implication:
  A |-> B                -- if A now, then B starts now (overlapping)
  A |=> B                -- if A now, then B starts next cycle (non-overlapping)

Cycle Delays:
  ##1                    -- exactly 1 cycle later
  ##N                    -- exactly N cycles later
  ##[1:5]                -- between 1 and 5 cycles later
  ##[0:$]                -- at some future point (unbounded)

Sampled Value Functions:
  $stable(x)             -- x has not changed from previous clock edge
  $rose(x)               -- x was 0 at previous edge, is 1 now
  $fell(x)               -- x was 1 at previous edge, is 0 now
  $past(x)               -- value of x at previous clock edge
  $past(x, N)            -- value of x at N clock edges ago
  $isunknown(x)          -- x has any bit that is X or Z

Repetition:
  expr [*N]              -- expr is true for exactly N consecutive cycles
  expr [*1:5]            -- expr is true for 1 to 5 consecutive cycles
  expr [->N]             -- expr is true N times (not necessarily consecutive)

Severity (in failure block):
  $info("msg")           -- informational, continues
  $warning("msg")        -- warning, continues
  $error("msg")          -- error, continues
  $fatal("msg")          -- error, stops simulation

Format specifiers in $error/$display:
  %t                     -- simulation time
  %0d                    -- integer (no leading zeros)
  %b                     -- binary
  %h                     -- hex
```

---

## Final Thought: The Mindset

A testbench without assertions is like a safety inspector who only checks whether the building is still standing at the end of the day. The building can violate every code during construction, but if it happens to not collapse, the inspector gives a pass.

Assertions are continuous monitoring — they watch every wire, every cycle, and they apply the spec rules universally, not just when the scoreboard happens to sample the output.

But they only work if you write them correctly. A tautological assertion is worse than no assertion: it creates false confidence. An assertion that never fires is a safety inspector who never shows up.

Write assertions that CAN fail. Verify they DO fire. Confirm they PASS for correct behavior and FAIL for injected violations. That is the senior engineer workflow, and now it is yours.

---

## Part 11: SVA Sequences — Building Blocks for Complex Properties

### 11.1 The `sequence` Keyword vs the `property` Keyword

You have been writing `property` blocks throughout this document. A `property` is the complete rule — it contains an implication, a clock, and a disable condition.

A `sequence` is something smaller: it is a named temporal fragment that describes a pattern of signal behavior over time, without yet saying "this must be true." You build sequences like LEGO bricks, then combine them inside properties.

```systemverilog
// A sequence: just a pattern, no enforcement yet
sequence s_scl_falls_within_period;
  ##[1:T_SCL_PERIOD] (scl_samp == 1'b0);
endsequence

// A property: uses the sequence and enforces it
property p_start_uses_sequence;
  @(posedge clk) disable iff (!rst_n)
  (scl_samp == 1'b1 && sda_fall) |-> s_scl_falls_within_period;
endproperty
```

The key distinction:

| | `sequence` | `property` |
|---|---|---|
| Can be asserted directly | No | Yes |
| Can appear inside a property | Yes | Yes (nested) |
| Contains clock/disable | No | Yes |
| Describes pattern | Yes | Yes, plus rules |
| Reusable as a fragment | Yes | Less common |

Think of `sequence` as a subroutine and `property` as the main function that calls it.

### 11.2 Sequences as Reusable Protocol Fragments

The real power of sequences is reuse. An I2C full SCL cycle (LOW phase then HIGH phase) is a pattern that appears in every assertion involving SCL. Define it once:

```systemverilog
// One complete SCL cycle: SCL goes LOW for T_SCL_LOW cycles,
// then HIGH for T_SCL_HIGH cycles, then returns to LOW.
sequence scl_cycle;
  (scl_samp == 1'b0) ##[1:T_SCL_LOW]
  (scl_samp == 1'b1) ##[1:T_SCL_HIGH]
  (scl_samp == 1'b0);
endsequence
```

Now any property that needs to verify "one complete SCL cycle occurred" can reference `scl_cycle` directly, instead of copy-pasting the same temporal pattern.

Why this is valuable:
- If `T_SCL_LOW` or `T_SCL_HIGH` changes (e.g., you switch from Standard to Fast mode), you change the sequence in one place and all properties update automatically.
- The intent is documented in the sequence name — easier to read than raw `##[1:250]` in a property.
- Sequences can be shared across multiple assertion modules via a package or interface.

### 11.3 Using Sequences Inside Properties with `|->`

Sequences slot naturally into the antecedent and consequent positions of a property:

```systemverilog
// Sequence: SDA falls while SCL is HIGH (the START pattern)
sequence s_start_cond;
  (scl_samp == 1'b1) && sda_fall;
endsequence

// Sequence: SCL falls within bounded window
sequence s_scl_falls_bounded;
  ##[1:(T_HD_STA + T_SCL_PERIOD)] (scl_samp == 1'b0);
endsequence

// Property: after START, SCL must fall — uses both sequences
property p_start_with_sequences;
  @(posedge clk) disable iff (!rst_n)
  s_start_cond |-> s_scl_falls_bounded;
endproperty

assert_start_v2: assert property (p_start_with_sequences)
  else $error("I2C-SVA: SCL did not fall after START");
```

The `|->` here means: "if the pattern described by `s_start_cond` matches right now, then the pattern described by `s_scl_falls_bounded` must follow from this same cycle."

### 11.4 The `within` Operator — Containment

The `within` operator expresses that one sequence must occur INSIDE the window of another:

```
sequence_A within sequence_B
```

This means: sequence_A must start and end within the time span of sequence_B.

**I2C Example**: SDA must be stable throughout the HIGH phase of an SCL cycle. Model the SCL HIGH window as one sequence and the stability requirement as a contained sequence:

```systemverilog
// The SCL-high window: from when SCL rises until it falls
sequence s_scl_high_window;
  $rose(scl_samp) ##[1:T_SCL_HIGH] $fell(scl_samp);
endsequence

// SDA must be stable within that window
sequence s_sda_stable_window;
  $stable(sda_samp)[*1:T_SCL_HIGH];
endsequence

// Containment: SDA stability is contained within SCL-high window
property p_sda_stable_in_scl_high;
  @(posedge clk) disable iff (!rst_n)
  (in_data_phase || in_ack_phase) |->
  (s_sda_stable_window within s_scl_high_window);
endproperty
```

The `within` operator is less commonly needed for simple I2C checks, but becomes essential for bus protocols with overlapping phases, like AXI handshake windows or DDR read latency windows.

### 11.5 The `intersect` Operator — Parallel Sequences

The `intersect` operator requires TWO sequences to proceed simultaneously AND both end at the same time:

```
sequence_A intersect sequence_B
```

Both must start at the same point, proceed in parallel, and terminate at the same cycle.

**Example**: Verify that during a data byte transfer, BOTH the bit counter increments exactly 8 times AND the SCL runs exactly 8 cycles:

```systemverilog
sequence s_eight_scl_cycles;
  scl_cycle [*8];   // scl_cycle repeated exactly 8 times
endsequence

sequence s_eight_bit_counts;
  (bit_counter == 4'd0) ##[*] (bit_counter == 4'd7);
endsequence

// Both must complete at the same time — they must be synchronized
property p_data_byte_synchronized;
  @(posedge clk) disable iff (!rst_n)
  start_cond_asserted |=>
  (s_eight_scl_cycles intersect s_eight_bit_counts);
endproperty
```

If the bit counter falls out of sync with the SCL cycles (e.g., a counter reset bug), this property catches it because one sequence finishes before the other.

### 11.6 The `first_match` Operator — Greedy vs Non-Greedy

When a sequence can match in multiple ways (because of range operators like `##[1:5]`), `first_match` selects only the EARLIEST possible match:

```systemverilog
// Without first_match: tries all possible completion points
sequence s_flexible;
  (trigger) ##[1:5] (consequence);
endsequence

// With first_match: only the earliest cycle where consequence is true
sequence s_earliest;
  first_match((trigger) ##[1:5] (consequence));
endsequence
```

**When this matters**: In overlapping assertions where a sequence could be "extended" to match later, you may want to pin the match to the first valid completion point so the next sequence starts as early as possible. Without `first_match`, the evaluation engine may try multiple branches, increasing simulation cost.

For this I2C project, `first_match` is most relevant when writing a sequence for "the first SCL fall after a START condition" — you want the assertion engine to commit to the first observed SCL fall, not keep waiting for a later one.

---

## Part 12: Writing New Assertions for This Project

The existing A1–A6 cover the foundational I2C rules. Here are five additional assertions that add depth to the verification plan. Each one targets a gap not covered by the existing set.

### A7: Address Must Be Exactly 8 Bits (7-bit Address + R/W)

**The rule**: After a START condition, the master must transmit exactly 8 SCL pulses before the ACK cycle. Not 7, not 9 — exactly 8.

**The property**:

```systemverilog
property p_address_is_8_bits;
  @(posedge clk) disable iff (!rst_n)
  // After START, the bit counter must reach 7 (0-indexed, meaning 8 bits
  // have been clocked) before the in_ack_phase signal asserts.
  start_cond_asserted |=>
    ##[T_SCL_PERIOD*8 : T_SCL_PERIOD*9] (in_ack_phase && $rose(scl_samp));
endproperty

assert_addr_8_bits: assert property (p_address_is_8_bits)
  else $error("I2C-SVA-A7: ACK phase did not arrive after exactly 8 SCL pulses. Time: %t", $time);
```

**What this checks**:

In the existing assertion module, `bit_counter` increments from 0 to 7 across 8 SCL falling edges. When `bit_counter` hits 7 and SCL falls, `in_ack_phase` asserts. This assertion verifies that the transition from START to ACK takes exactly 8 SCL periods — meaning the master is not skipping bits (bit counter reset bug) or adding extra bits (counter not resetting after NACK).

**PASS scenario**:
```
START at cycle 0.
SCL cycle 1: bit_counter=0
SCL cycle 2: bit_counter=1
...
SCL cycle 8: bit_counter=7, in_ack_phase asserts.
Time to in_ack_phase: 8 * T_SCL_PERIOD = 4000 cycles.
Window [4000:4500] — cycle 4000 is in-range.
RESULT: PASS
```

**FAIL scenario**:
```
START at cycle 0.
Bug: bit_counter resets to 0 after bit 3 (counter width bug).
in_ack_phase asserts at cycle 4 * T_SCL_PERIOD = 2000 cycles.
Window [4000:4500] — cycle 2000 is before the window.
RESULT: FAIL — "ACK phase did not arrive after exactly 8 SCL pulses"
```

**When it fires**: A bit counter width bug (e.g., 2-bit counter that wraps at 4 instead of 8) would cause the ACK phase to arrive too early. A missing counter reset (ACK never comes) would cause it to arrive too late or not at all.

---

### A8: ACK/NACK Must Be a Valid Logic Level — Never X

**The rule**: After 8 data bits, the 9th SCL clock is the ACK clock. SDA during this clock must be either 0 (ACK) or 1 (NACK). It can NEVER be X or Z in a correctly functioning system.

**The property**:

```systemverilog
property p_ack_is_valid_level;
  @(posedge clk) disable iff (!rst_n)
  // When the 9th bit clock rises (ACK clock), SDA must be known
  (in_ack_phase && $rose(scl_samp)) |-> !$isunknown(sda_samp);
endproperty

assert_ack_valid: assert property (p_ack_is_valid_level)
  else $error("I2C-SVA-A8: ACK/NACK is X or Z on 9th SCL rise — undefined acknowledgement at time %t",
              $time);
```

**How this differs from A4**:

A4 checks `in_ack_phase && scl_samp == 1'b1` — any cycle during ACK where SCL is currently HIGH. A8 specifically triggers on `$rose(scl_samp)` during ACK — the exact rising edge of the 9th clock. This is the precise moment the receiver SAMPLES the ACK bit. An X at this exact moment is the worst case: the data has been sampled and the result is undefined. A4 catches it throughout SCL-high; A8 pins the check to the sampling instant for more targeted diagnostics.

**PASS scenario**:
```
in_ack_phase = 1. scl_samp: 0 -> 1 ($rose = true).
sda_samp = 0 (ACK driven by slave).
$isunknown(0) = false. !false = true.
RESULT: PASS
```

**FAIL scenario**:
```
in_ack_phase = 1. scl_samp: 0 -> 1 ($rose = true).
sda_samp = 1'bx (slave's ack_driver is uninitialized).
$isunknown(1'bx) = true. !true = false.
RESULT: FAIL — "ACK/NACK is X or Z on 9th SCL rise"
```

**When it fires**: Uninitialized slave ACK logic. Bug #2 in this project (slave had no TX shift register) would trigger this assertion on every read transaction.

---

### A9: STOP Cannot Immediately Follow START — At Least 9 SCL Pulses Required

**The rule**: A STOP condition (SDA rises while SCL is HIGH) is only valid after at least one complete data byte (8 bits + ACK = 9 SCL pulses) has been transferred. A STOP that arrives fewer than 9 SCL periods after a START is a protocol violation — no data could have been transferred.

**The property**:

```systemverilog
property p_stop_not_after_empty_start;
  @(posedge clk) disable iff (!rst_n)
  // If STOP arrives, at least 9 SCL periods must have elapsed since START
  // Equivalently: after START, STOP cannot come within 9 SCL periods
  start_cond_asserted |->
    ##[T_SCL_PERIOD*9 : $] !stop_cond_asserted [*1];
endproperty

assert_stop_after_data: assert property (p_stop_not_after_empty_start)
  else $error("I2C-SVA-A9: STOP arrived before 9 SCL pulses after START — empty transaction at time %t",
              $time);
```

**Alternative formulation** (easier to read, equivalent intent):

```systemverilog
property p_no_immediate_stop;
  @(posedge clk) disable iff (!rst_n)
  // START followed immediately by STOP (within 9 SCL periods) is illegal
  (start_cond_asserted) |->
    ##[1:T_SCL_PERIOD*9-1] !stop_cond_asserted;
endproperty
```

**When it fires**: A buggy master FSM that issues START then immediately issues STOP without clocking any data. This can happen when a command buffer underrun causes the master to abort the transaction before it begins. The STOP condition would be visible on the bus, but no data was transferred — downstream slaves would see a malformed transaction.

**PASS scenario**: START → 8 data bits (4000 cycles) → ACK (500 cycles) → STOP. STOP arrives after 4500+ cycles. No violation within the 4500-cycle exclusion window.

**FAIL scenario**: START → (bug: FSM jumps directly to STOP state) → STOP 5 cycles later. STOP arrived inside the exclusion window.

---

### A10: SDA Stable During SCL High — Using `$stable` Precisely

**The rule**: This is a tighter restatement of A3. The existing A3 uses `$stable(sda_samp)` which checks cycle-to-cycle stability. This new version explicitly uses `$past` to make the comparison visible and unambiguous in waveform debug.

**The property**:

```systemverilog
property p_sda_stable_scl_high_v2;
  @(posedge clk) disable iff (!rst_n)
  // When SCL is HIGH during a transfer (not START/STOP),
  // SDA must equal its value from the previous cycle exactly
  ((in_data_phase || in_ack_phase)
   && scl_samp == 1'b1
   && !start_cond_asserted
   && !stop_cond_asserted) |->
   (sda_samp === $past(sda_samp, 1));
endproperty

assert_sda_stable_v2: assert property (p_sda_stable_scl_high_v2)
  else $error("I2C-SVA-A10: SDA changed while SCL HIGH. Current=%b, Previous=%b at time %t",
              sda_samp, $past(sda_samp, 1), $time);
```

**Why this is better for debugging**:

The `$stable(x)` formulation is compact, but when it fires you only see that stability was violated — not what the values were. Using `sda_samp === $past(sda_samp, 1)` explicitly:
1. Makes the comparison structurally clear — you are comparing two specific sample points.
2. The `$error` message can print BOTH the current value and the previous value using `$past(sda_samp, 1)`, which is evaluated at assertion fire time and gives you the previous-cycle value in the log.
3. Uses `===` (case equality, 4-state) rather than `==` (logical equality, which treats X as possibly equal to anything in some contexts). This is strictly correct for simulation.

**Note**: A3 and A10 check the same protocol rule. In a real project you would choose one style. A10 is presented here to illustrate `$past` and `===` — skills used in more complex multi-cycle assertions.

---

### A11: Clock Stretch Release Must Be Within Bound — Cleaner Syntax

**The rule**: Restate A5 with a more readable structure that separates the "stretching is happening" detection from the "it is within bounds" check.

**The property** (cleaner restated version):

```systemverilog
// A dedicated logic signal: TRUE when slave is actively stretching SCL
logic slave_stretching;
assign slave_stretching = (scl_samp == 1'b0) && in_data_phase;

property p_stretch_within_bound;
  @(posedge clk) disable iff (!rst_n)
  // If the slave is stretching SCL, it must release within MAX_CLK_STRETCH
  // scl_low_counter is the same counter used by A5
  slave_stretching |-> (scl_low_counter < MAX_CLK_STRETCH);
endproperty

assert_stretch_bound: assert property (p_stretch_within_bound)
  else $error("I2C-SVA-A11: SCL held LOW for %0d cycles (limit=%0d) during data phase at time %t",
              scl_low_counter, MAX_CLK_STRETCH, $time);
```

**What is different from A5**:

A5 fires whenever SCL is LOW for too long — including during the master's own LOW phase between bits. A11 adds the `in_data_phase` guard: it only fires during active data transfer. This means:

- A5 catches global SCL-stuck situations (bus frozen before any transaction).
- A11 catches slave clock stretching violations during live data transfers specifically.

The error message also includes the actual counter value at fire time, so the log immediately tells you how long the stretch lasted — useful for tuning `MAX_CLK_STRETCH` if the value is too tight for your slave's processing speed.

**PASS scenario**:
```
in_data_phase = 1. scl_samp = 0 for 50 cycles (slave stretching).
scl_low_counter reaches 50, then SCL releases.
50 < 1000 = MAX_CLK_STRETCH. At no point did assertion fire.
RESULT: PASS
```

**FAIL scenario**:
```
in_data_phase = 1. scl_samp = 0 for 1001 cycles (slave hung).
scl_low_counter reaches 1000.
1000 < 1000? NO.
RESULT: FAIL — "SCL held LOW for 1000 cycles (limit=1000) during data phase"
```

---

## Part 13: The Assertion Debugging Checklist

An assertion failure is not the end of the debugging process — it is the beginning. Here is the systematic workflow to go from "assertion fired" to "bug found and fixed." This is the process a senior engineer runs every time, without shortcuts.

### Step 1: Read the Failure Message — Which Property? Which Cycle?

The first thing in your simulation log after a failure is the `$error` output. For this project it looks like:

```
ERROR: I2C-SVA-A3: SDA changed while SCL high at time 4237500 ps
```

Extract:
- **Which assertion**: A3 (`assert_sda_stable`)
- **Simulation time**: 4237500 ps

Do not guess. Do not start digging in RTL yet. Get the exact time first. If multiple assertions fired, list them in order. The FIRST one is often the root cause; subsequent ones may be cascading failures triggered by the same underlying bug.

### Step 2: Open the Waveform at the Failure Cycle

Convert the simulation time to a clock cycle number. If your clock period is 20 ns (50 MHz), then 4237500 ps / 20000 ps = cycle 211.875 — so look at cycle 211 or 212.

In your waveform viewer (Verdi, GTKWave, Questa Waveform):
- Navigate to the failure time.
- Add these signals to the view:
  - `clk`, `rst_n`
  - `scl_samp`, `sda_samp`, `scl_d`, `sda_d`
  - `sda_fall`, `sda_rise`, `scl_fall`
  - `in_data_phase`, `in_ack_phase`
  - `bit_counter`
  - `scl_low_counter` (for A5/A11)
  - The assertion label itself (most viewers show it as a track with PASS/FAIL markers)

Zoom to the ±5 cycle window around the failure. Look at the assertion track — it should show a red FAIL marker at the exact cycle.

### Step 3: Check — Is `rst_n` Asserted?

Before assuming the assertion caught a real bug, confirm reset is NOT active at the failure time. Look at the `rst_n` signal in the waveform. If `rst_n = 0` at the failure time, something is wrong with your `disable iff` — go check the assertion module's reset logic.

If `rst_n = 1` (reset is de-asserted, design is operating normally), proceed. The failure is real.

### Step 4: Check — Is `disable iff` Working Correctly?

Sometimes `disable iff` is structurally correct but the reset signal is named differently in the bound context vs the actual module. Confirm:

1. The assertion module's `rst_n` port is connected to the same net as the DUT's `rst_n`.
2. The `disable iff` condition (`!rst_n`) correctly evaluates to `1` during reset in your simulation.

Add `rst_n` to your waveform if it is not already there. At the failure cycle, it must be `1`. If it is `X`, your reset is not properly initialized — that is a separate bug to fix first.

### Step 5: Trace Backward — What Drove the Triggering Condition?

For each signal in the antecedent, trace backward in the waveform to understand WHY the antecedent fired at this cycle.

**Example for A3 failure** (`SDA changed while SCL HIGH`):
- Antecedent: `in_data_phase == 1`, `scl_samp == 1`, `!start_cond_asserted`, `!stop_cond_asserted`
- Consequent: `$stable(sda_samp)` — was FALSE

So SDA changed. Questions to answer:
- What was `sda_samp` at cycle N-1? (Use `$past(sda_samp, 1)` or look one cycle earlier.)
- What drove `sda_samp` to change? Trace to the module driving `sda`.
- Was SCL going HIGH at this exact cycle? Or was it already HIGH?

The goal: identify the specific RTL module and state machine state that caused SDA to change at the wrong time.

### Step 6: Trace Forward — What Was Supposed to Happen?

Understanding the intent helps you confirm it is a real bug (not a test stimulus error):

- According to the I2C spec, SDA should have stayed stable until SCL went LOW.
- How many cycles did SDA change too early? (This tells you whether it is a hold time violation or a complete driver bug.)
- Did SCL go LOW shortly after? Or was SCL HIGH for many cycles after the violation?

If SCL went LOW just 1 cycle after SDA changed, the violation is a hold-time (T_HD_DAT) issue — the master is changing SDA 1 cycle too early. If SCL stayed HIGH for 50 cycles after SDA changed, it is a more severe control logic bug.

### Step 7: Correlate With the Scoreboard

Cross-reference the assertion failure time with the scoreboard log:

- Did the scoreboard report a data mismatch near this time?
- Which transaction number was in progress?
- Did the slave return NACK at the same time the assertion fired?

If the scoreboard also flagged an error at the same transaction: the assertion caught the root cause of a real data corruption. The assertion fired first (at the violation) and the scoreboard caught the downstream effect (wrong data). You can now fix the root cause rather than chasing the symptom.

If the scoreboard showed no error: the protocol violation occurred but happened to not corrupt the final data in this run (lucky bit alignment). The assertion still caught a real protocol violation that could corrupt data in a different test scenario.

---

## Part 14: Assertion Reuse Across Projects

### 14.1 Why SVA Assertions Are Reusable Protocol Checkers

The assertions in `sva/i2c_protocol_assertions.sv` are not specific to this testbench's UVM structure or this particular I2C master implementation. They check the I2C protocol rules — rules defined by the NXP specification that apply to every I2C implementation everywhere.

This means these assertions can be reused in:
- A different I2C master DV project at the same company.
- An SoC integration testbench where you need to verify that a third-party I2C IP is compliant.
- A formal verification flow where you want to prove protocol compliance mathematically.
- An emulation platform where you need lightweight checkers instead of a full UVM environment.

The concept of packaging assertions for reuse is called a **Protocol Assertion IP** (PAIP) or sometimes a **Verification IP Assertion Layer**.

### 14.2 The Concept of a Protocol Assertion IP (PAIP)

A PAIP is a standalone SystemVerilog module (or interface) that:
1. Takes the protocol signals as inputs (in I2C's case: `clk`, `rst_n`, `scl`, `sda`).
2. Contains all the assertions for the protocol.
3. Is parameterized so timing and configuration can be tuned per instantiation.
4. Has no design logic — it is purely observational.
5. Can be bound to any DUT that implements the protocol.

The key insight is that the assertions live in a SEPARATE module from the DUT. You do not modify the DUT to add assertions. Instead, you instantiate the assertion module alongside the DUT or use the SVA `bind` directive to attach it non-invasively.

A mature PAIP also includes:
- Coverage points (`cover property`) for every protocol event.
- Formal constraint properties (`assume property`) for use in formal flows.
- Documentation header describing which spec sections each assertion covers.
- A parameter to enable/disable individual assertions (so you can selectively disable assertions during specific test phases).

### 14.3 Packaging the I2C Assertions as a Reusable Module

The existing `i2c_protocol_assertions.sv` is already structured as a PAIP. Here is how you would complete the packaging for full reusability:

```systemverilog
//=============================================================================
// File: i2c_protocol_assertions_paip.sv
// Description: Parameterized I2C Protocol Assertion IP
//              Reusable across any I2C master/slave implementation.
// Usage:
//   Instantiate alongside your DUT and connect the I2C signals.
//   Or use SVA bind: bind i2c_master i2c_protocol_assertions_paip #(...)
//     u_i2c_assertions (.clk(clk), .rst_n(rst_n), .scl(scl), .sda(sda));
//=============================================================================

module i2c_protocol_assertions_paip #(
  // Timing parameters — override for your clock frequency and I2C mode
  parameter int SLAVE_ADDR       = 7'h50,    // Target slave address (for logging)
  parameter int T_SCL_PERIOD     = 500,      // SCL full period in system clock cycles
  parameter int T_SCL_HIGH       = 250,      // SCL high time
  parameter int T_SCL_LOW        = 250,      // SCL low time
  parameter int T_HD_STA         = 10,       // START hold time
  parameter int T_BUF            = 20,       // Bus free time after STOP
  parameter int MAX_STRETCH      = 1000,     // Maximum clock stretch in cycles
  // Assertion enable flags — set to 0 to disable specific assertions
  parameter bit EN_A1_START      = 1,
  parameter bit EN_A2_STOP       = 1,
  parameter bit EN_A3_SDA_STABLE = 1,
  parameter bit EN_A4_ACK        = 1,
  parameter bit EN_A5_STRETCH    = 1,
  parameter bit EN_A6_UNKNOWN    = 1
) (
  input logic clk,
  input logic rst_n,
  inout wire  scl,
  inout wire  sda
);

  // ... all assertion logic from i2c_protocol_assertions.sv goes here,
  //     using the parameter names instead of i2c_pkg constants ...

  // Conditional assertion instantiation using generate blocks
  if (EN_A3_SDA_STABLE) begin : gen_a3
    assert_sda_stable: assert property (p_sda_stable_scl_high)
      else $error("[I2C-PAIP][Addr=0x%02h] A3: SDA changed while SCL HIGH at %t",
                  SLAVE_ADDR, $time);
  end

endmodule
```

The `generate if` blocks for each assertion allow users of the PAIP to disable specific checks. For example, in a test that intentionally injects SDA violations to verify error recovery, you would disable A3 to avoid false failures cluttering the log.

### 14.4 Parameters: `SLAVE_ADDR`, `MAX_STRETCH`, `T_SCL_PERIOD`

The three most important PAIP parameters and why each matters:

**`SLAVE_ADDR`** (7-bit I2C address): Used only in error messages. Including the slave address in every assertion failure message makes it immediately clear WHICH I2C device was involved in the violation when you have a multi-slave bus. Without it, you see "SDA violation at time X" but must manually decode the address from the waveform. With it, you see "[Addr=0x50] SDA violation at time X" — instantly actionable.

**`MAX_STRETCH`** (clock stretch bound, in system clock cycles): Different slaves have different processing speeds. A fast ADC might release SCL within 100 system cycles. A slow EEPROM might need 800. If you use `MAX_STRETCH = 1000` for the ADC project, the assertion is overly lenient. If you use `MAX_STRETCH = 100` for the EEPROM project, it fires false failures on every write. Parameterizing this allows you to tune the bound for the specific slave's datasheet specification.

**`T_SCL_PERIOD`** (SCL period, in system clock cycles): The I2C spec supports Standard (100 kHz), Fast (400 kHz), Fast-Plus (1 MHz), and High-Speed (3.4 MHz) modes. Each has different minimum and maximum timing requirements. At a 100 MHz system clock:
- Standard mode: T_SCL_PERIOD = 1000 (10 μs / 1 ns = 1000 cycles)
- Fast mode: T_SCL_PERIOD = 250 (2.5 μs / 1 ns = 250 cycles)
- Fast-Plus: T_SCL_PERIOD = 100

If T_SCL_PERIOD is hardcoded, your PAIP only works for one I2C speed. Parameterizing it makes the PAIP work across all I2C modes by overriding the parameter at instantiation.

### 14.5 Instantiating the Assertion Module in Any I2C Testbench

**Method 1: Direct Instantiation in the Testbench Top**

```systemverilog
// In your testbench top module (tb_top.sv)
module tb_top;

  // DUT
  i2c_master u_dut (
    .clk   (clk),
    .rst_n (rst_n),
    .scl   (scl_bus),
    .sda   (sda_bus)
  );

  // Protocol assertion IP — connected to same bus signals
  i2c_protocol_assertions_paip #(
    .SLAVE_ADDR   (7'h50),
    .T_SCL_PERIOD (500),       // Standard mode at 50 MHz
    .MAX_STRETCH  (1000)
  ) u_i2c_assertions (
    .clk   (clk),
    .rst_n (rst_n),
    .scl   (scl_bus),
    .sda   (sda_bus)
  );

endmodule
```

This is the simplest approach. The assertion module is instantiated next to the DUT and observes the same signals. No DUT modification required.

**Method 2: SVA Bind Directive (Non-Invasive)**

The `bind` directive attaches the assertion module to an existing module without modifying the existing module's source code. This is critical when the DUT source is locked (third-party IP, encrypted netlists, or a frozen release):

```systemverilog
// In a separate bind file (bind_i2c_assertions.sv)
// Syntax: bind <target_module> <assertion_module> #(...) <instance_name> (...);

bind i2c_master i2c_protocol_assertions_paip #(
  .SLAVE_ADDR   (7'h50),
  .T_SCL_PERIOD (500),
  .MAX_STRETCH  (1000)
) u_bound_assertions (
  .clk   (clk),      // 'clk' resolves to i2c_master's internal 'clk' port
  .rst_n (rst_n),
  .scl   (scl),
  .sda   (sda)
);
```

With `bind`, the assertion module is logically instantiated INSIDE every instance of `i2c_master` in the design hierarchy. If you have 4 I2C master instances in your SoC, all 4 automatically get the assertion coverage — without touching the DUT source files. This is the preferred industry approach for PAIP deployment.

**Method 3: Interface-Based Assertions**

For projects using SystemVerilog interfaces (as this project does with `i2c_if.sv`), assertions can live directly inside the interface:

```systemverilog
// In i2c_if.sv
interface i2c_if (input logic clk, input logic rst_n);
  wire scl;
  wire sda;

  // Assertions embedded in the interface
  // Any module connected to this interface automatically gets the checks
  property p_sda_stable;
    @(posedge clk) disable iff (!rst_n)
    (scl == 1'b1) |-> $stable(sda);
  endproperty

  assert_sda_stable: assert property (p_sda_stable)
    else $error("Interface assertion: SDA changed while SCL HIGH");

endinterface
```

This approach scales naturally: every interface instance gets the assertions automatically. The disadvantage is that assertions in interfaces cannot be as easily disabled or parameterized as in a dedicated module. Use this approach for lightweight, always-on checks; use the module approach for full PAIP capability.

---

## Part 15: The Three New Production Assertions — A7, A8, A9

### Why These Were Added
The original 6 assertions (A1-A6) cover the high-level protocol rules. But a senior engineer always asks:
- "Is the bus REALLY free after STOP, or just briefly?" (A2 has a gap — it only checks one cycle within T_BUF)
- "What if SDA changes RIGHT after SCL falls — within the hold window?" (A3 catches changes during SCL high, but not setup/hold violations at the edges)
- "What if SDA changes RIGHT before SCL rises?" (Setup time check)

A7, A8, A9 close these gaps. They are stricter, edge-window assertions.

### A7: Bus Must Be Free for FULL T_BUF After STOP

#### What it checks
After a STOP condition, both SDA and SCL must stay HIGH for the ENTIRE T_BUF window (not just at some point within it).

#### The exact property
```systemverilog
property p_bus_free_full_tbuf;
  @(posedge clk)
  disable iff (!rst_n)
  stop_cond_asserted |-> ##1 (sda_samp == 1'b1 && scl_samp == 1'b1)[*T_BUF];
endproperty

assert_bus_free_tbuf: assert property (p_bus_free_full_tbuf)
  else $error("I2C-SVA-A7: Bus did not remain free for full T_BUF=%0d cycles after STOP at time %t",
              T_BUF, $time);
```

#### Why it's needed (vs A2)
A2 says: "after STOP, at SOME cycle within T_BUF, the bus is free"
A7 says: "after STOP, at EVERY cycle within T_BUF, the bus stays free"

Imagine a slave that glitches during the bus-free window — drives SDA low briefly. A2 might still pass (if it happened to sample after the glitch). A7 catches it because EVERY cycle must be HIGH.

#### The `[*T_BUF]` operator
The `[*N]` operator is "consecutive repetition N times". It means the condition must hold for N CONSECUTIVE cycles.

```systemverilog
(sda_samp == 1'b1 && scl_samp == 1'b1)[*T_BUF]
```
This is true ONLY if the bus is HIGH at cycle 1, AND cycle 2, AND ... cycle T_BUF.

#### ASCII waveform — PASS scenario
```
cycle: STOP  +1   +2   +3   ...  +T_BUF
SDA:    ↑    H    H    H    ...    H    ✓ A7 PASSES
SCL:    H    H    H    H    ...    H
```

#### ASCII waveform — FAIL scenario (slave glitch)
```
cycle: STOP  +1   +2   +3   ...  +T_BUF
SDA:    ↑    H    L    H    ...    H    ✗ A7 FAILS at cycle +2
SCL:    H    H    H    H    ...    H
```

#### Interview question
"How is A7 different from A2?"
Answer: A2 is a "weak" temporal property — it only requires the bus to be free somewhere within the T_BUF window. A7 is "strong" — it requires the bus to be free for EVERY cycle of the window. The `[*N]` consecutive-repetition operator is what makes A7 strong.

---

### A8: SDA Must Hold Stable for T_HD_DAT After SCL Falls

#### What it checks
After SCL goes LOW, SDA must remain stable for at least T_HD_DAT cycles before being allowed to change.

#### Why it's needed
This is the I2C "hold time" requirement. Slow slaves sample SDA right after SCL falls, so if the master changes SDA too soon, the slave might capture the WRONG bit value.

#### The exact property
```systemverilog
property p_sda_hold_after_scl_fall;
  @(posedge clk)
  disable iff (!rst_n)
  ((in_data_phase || in_ack_phase) && scl_fall && !start_cond_asserted && !stop_cond_asserted)
    |-> $stable(sda_samp)[*T_HD_DAT];
endproperty

assert_sda_hold: assert property (p_sda_hold_after_scl_fall)
  else $error("I2C-SVA-A8: SDA changed within T_HD_DAT=%0d hold window after SCL fall at time %t",
              T_HD_DAT, $time);
```

#### Walk through what each part means
- `scl_fall` — SCL just transitioned from HIGH to LOW
- `(in_data_phase || in_ack_phase)` — we are in a data/ACK cycle, not START/STOP
- `|->` — IF the above is true, THEN
- `$stable(sda_samp)[*T_HD_DAT]` — sda_samp must remain unchanged for T_HD_DAT consecutive cycles

#### ASCII waveform — PASS
```
SCL:  ‾‾‾\___________   ← SCL falls
SDA:  XXXXXX________ ← SDA stable for T_HD_DAT cycles AFTER scl_fall
       ←─T_HD_DAT─→
                ↑
               OK to change SDA here
```

#### ASCII waveform — FAIL (master too eager)
```
SCL:  ‾‾‾\__________
SDA:  XX___YYY      ← SDA changed within T_HD_DAT! FAIL
       ←─T_HD_DAT─→
        ↑
       SDA changed too soon — A8 fails
```

#### Real bug this catches
A poorly-implemented master that changes SDA on the same clock cycle as SCL falling. Some slaves capture SDA on the LOW edge of SCL, and they'd capture the wrong bit.

---

### A9: SDA Must Be Stable for T_SU_DAT Before SCL Rises

#### What it checks
This is the I2C "setup time" requirement. Before SCL rises (where slaves sample SDA), SDA must have been stable for at least T_SU_DAT cycles.

#### The exact property
```systemverilog
property p_sda_setup_before_scl_rise;
  @(posedge clk)
  disable iff (!rst_n)
  ((in_data_phase || in_ack_phase) && scl_rise_a8 && !start_cond_asserted && !stop_cond_asserted)
    |-> ($past(sda_samp, T_SU_DAT) == sda_samp);
endproperty

assert_sda_setup: assert property (p_sda_setup_before_scl_rise)
  else $error("I2C-SVA-A9: SDA changed within T_SU_DAT=%0d setup window before SCL rise at time %t",
              T_SU_DAT, $time);
```

#### The `$past` function
`$past(signal, N)` returns the value of `signal` N clock cycles ago.

The property uses:
```systemverilog
$past(sda_samp, T_SU_DAT) == sda_samp
```
This says: "The value of sda_samp T_SU_DAT cycles ago must equal the current value." If SDA hasn't changed for T_SU_DAT cycles, this is true. If SDA changed within the window, this is false.

#### ASCII waveform — PASS
```
SCL:  ___________/‾‾‾   ← SCL rises
SDA:  ________XXXXXX  ← SDA stable for T_SU_DAT cycles BEFORE scl_rise
       ←T_SU_DAT→
                  ↑
            Slave samples here, gets correct bit
```

#### ASCII waveform — FAIL
```
SCL:  __________/‾‾‾
SDA:  XX___YYYY‾‾‾  ← SDA changed within T_SU_DAT window! FAIL
       ←T_SU_DAT→
              ↑
       Slave samples here, might get the wrong value
```

#### Why `$past` instead of `$stable[*N]`?
Both would work, but `$past` is more efficient — it just compares two values, no sequence machinery needed. `$stable[*N]` would need to track stability over a window. For setup-checks where you only care about "stable enough", `$past` is the idiomatic SystemVerilog choice.

---

### Comparing A3, A7, A8, A9 — The Complete SDA Protection

| Assertion | Window | Catches |
|-----------|--------|---------|
| A3 | SDA stable during SCL HIGH | Mid-bit corruption |
| A7 | Bus stable after STOP | Premature START / idle glitch |
| A8 | SDA hold T_HD_DAT after SCL fall | Master changing SDA too soon |
| A9 | SDA setup T_SU_DAT before SCL rise | Master changing SDA too late |

Together, these 4 assertions form a "ring of protection" around every SDA bit transition.

### How to write your OWN setup/hold assertion for a new signal

Step 1: Identify the trigger edge (e.g., `clk_rise`, `scl_fall`)
Step 2: Identify the data signal (e.g., `data_in`)
Step 3: Identify the timing parameter (e.g., `T_SETUP`)
Step 4: For hold: `trigger |-> $stable(data)[*T_HOLD]`
Step 5: For setup: `trigger |-> $past(data, T_SETUP) == data`

This pattern works for ANY signal protocol — not just I2C.

---

### 5 New Interview Questions on A7/A8/A9

**Q31**: What's the difference between A2 (stop_cond) and A7 (bus_free_full_tbuf)?
Answer: A2 only requires the bus to be free at SOME point in the T_BUF window. A7 requires the bus to be free at EVERY point in the window — much stricter. Detected via `[*N]` consecutive-repetition operator.

**Q32**: What does `$stable(sda_samp)[*5]` mean?
Answer: sda_samp must remain unchanged for 5 CONSECUTIVE cycles.

**Q33**: When would A8 fire that A3 wouldn't?
Answer: A3 only checks SDA stability during SCL HIGH. A8 fires when SDA changes within the HOLD window AFTER SCL has fallen LOW. This is a different protocol violation — early bit change after a falling clock edge.

**Q34**: Why does A9 use `$past` instead of `$stable[*N]`?
Answer: `$past` is more efficient for a setup check — you only need to compare the current value to the value N cycles ago. `$stable[*N]` would build sequence machinery, which is unnecessary overhead when you just want a point-in-time comparison.

**Q35**: If T_HD_DAT = 5 and SDA changes 3 cycles after SCL falls, does A8 fire?
Answer: Yes. The assertion requires stability for T_HD_DAT=5 cycles. If SDA changes at cycle 3 of the hold window, `$stable(sda_samp)[*5]` will fail at cycle 3.

---

*End of document — `05_SVA_ASSERTIONS_DEEP_DIVE.md`*  
*Project: i2c-protocol-dv | Author: Senior Verification Engineer | Date: 2026-05-12*

---

## Part 16: Production-Hardening Notes on A7, A8, A9 (Post-Closure Update)

This section was added after the project was extended with 3 new assertions
(A7 strengthens A2, A8 enforces hold time, A9 enforces setup time). It expands
on Part 15 with the EXACT code from `sva/i2c_protocol_assertions.sv` lines
210–265, the rationale for the strictness change, and the longer ASCII
waveforms that the production review identified as missing.

If you are reading this for the first time, skim Part 15 first — it gave the
introduction. This part gives the operational details: why the assertion was
written THIS exact way, what the simulator does on each cycle, and how to
debug a fail.

---

### A7 — Full Bus-Free Window After STOP (the exact production code)

#### The committed source (sva/i2c_protocol_assertions.sv:210–224)
```systemverilog
//=============================================================================
// A7: Bus must remain FREE (both lines HIGH) for the full T_BUF window after STOP.
// Stronger version of A2: A2 only checks the bus is HIGH at some point within
// T_BUF. A7 checks the bus stays HIGH for the WHOLE T_BUF window.
// Catches: premature START before bus recovery, slave glitches during idle.
//=============================================================================
property p_bus_free_full_tbuf;
  @(posedge clk)
  disable iff (!rst_n)
  stop_cond_asserted |-> ##1 (sda_samp == 1'b1 && scl_samp == 1'b1)[*T_BUF];
endproperty

assert_bus_free_tbuf: assert property (p_bus_free_full_tbuf)
  else $error("I2C-SVA-A7: Bus did not remain free for full T_BUF=%0d cycles after STOP at time %t",
              T_BUF, $time);
```

#### A2 vs A7 — read the difference twice
- **A2** says: *"After STOP, at SOME cycle within T_BUF, the bus is HIGH."*
  This is a "weak liveness" check — proves the bus eventually recovers.
- **A7** says: *"After STOP, at EVERY cycle within T_BUF, the bus stays HIGH."*
  This is a "strong safety" check — proves the bus stays clean.

A2 is *necessary*. A7 is *sufficient*. You want BOTH. Removing A2 hides the
case where the bus is permanently stuck LOW after STOP (you'd never trigger
A7's antecedent because we'd never reach STOP again). Removing A7 hides the
glitch-during-idle case. They protect different bug classes.

#### The `[*T_BUF]` consecutive-repetition operator — full breakdown
T_BUF is defined as 20 in `i2c_pkg.sv`. So the expression
`(sda_samp == 1'b1 && scl_samp == 1'b1)[*T_BUF]` expands to:

```
(SDA==1 && SCL==1) ##1
(SDA==1 && SCL==1) ##1
(SDA==1 && SCL==1) ##1
... 20 times total ...
(SDA==1 && SCL==1)
```

The simulator unrolls this into a sequence of 20 boolean checks separated by
`##1` (advance one cycle each). If ANY one of those 20 checks fails, the
property fails and the `$error` fires.

The `[*N]` syntax is the "consecutive repetition" operator. There is also
`[=N]` (non-consecutive — must hold N times eventually, with gaps) and `[->N]`
(goto repetition — must hold N times, ending exactly when we exit the
sequence). For setup/hold/window protection you almost always want `[*N]`
because you want CONTIGUOUS stability.

#### ASCII waveform — PASS (20 consecutive HIGH cycles)
```
cycle:    STOP   +1   +2   +3   +4   +5   ...  +18  +19  +20
SDA:       ↑     H    H    H    H    H    ...   H    H    H    ✓ PASS
SCL:       H     H    H    H    H    H    ...   H    H    H

A7:  stop_cond_asserted fires at "STOP" cycle. Then ##1 (skip 1 cycle).
     Then (SDA==1 && SCL==1)[*20] — the simulator checks cycles +1 through
     +20. All 20 cycles see HIGH+HIGH. The sequence passes. A7 PASSES.
```

#### ASCII waveform — FAIL (glitch midway)
```
cycle:    STOP   +1   +2   +3   +4   +5   ...  +18  +19  +20
SDA:       ↑     H    H    L    H    H    ...   H    H    H
SCL:       H     H    H    H    H    H    ...   H    H    H

                       ^
                  GLITCH! SDA momentarily LOW at cycle +3

A7:  At cycle +3, the boolean (SDA==1 && SCL==1) is FALSE. The [*20]
     consecutive-repetition sequence fails to advance. The property fails.
     $error("I2C-SVA-A7: Bus did not remain free...") fires.
```

#### Why this matters (bug class A7 catches)
- **Slave glitch during recovery**: A slow slave doesn't fully release SDA
  after STOP and pulls it down for a few cycles before letting go. Without
  A7, this corruption goes unnoticed until the next master tries to issue
  START and the start condition is malformed.
- **Premature competing master**: Another master sees the line briefly LOW
  during the bus-free window and infers a START condition. A7 catches the
  conditions that would mislead a peer master.
- **Pull-up failure**: If a board has a weak/missing pull-up, the bus may
  not actually return to HIGH within T_BUF. A7 catches "the bus didn't
  recover within the spec window" — which on real silicon would manifest
  as flaky multi-master operation.

---

### A8 — SDA Hold Time After SCL Fall (the exact production code)

#### The committed source (sva/i2c_protocol_assertions.sv:226–242)
```systemverilog
//=============================================================================
// A8: SDA Hold Time After SCL Falls (Glitch Window Check)
// I2C spec T_HD_DAT: SDA must remain stable for T_HD_DAT cycles after SCL
// falls before being allowed to change. This catches drivers that change
// SDA too early (before hold time), corrupting the next bit.
// Only enforced in data/ack phase (not during START/STOP transitions).
//=============================================================================
property p_sda_hold_after_scl_fall;
  @(posedge clk)
  disable iff (!rst_n)
  ((in_data_phase || in_ack_phase) && scl_fall && !start_cond_asserted && !stop_cond_asserted)
    |-> $stable(sda_samp)[*T_HD_DAT];
endproperty

assert_sda_hold: assert property (p_sda_hold_after_scl_fall)
  else $error("I2C-SVA-A8: SDA changed within T_HD_DAT=%0d hold window after SCL fall at time %t",
              T_HD_DAT, $time);
```

#### What T_HD_DAT actually means
T_HD_DAT = 5 cycles in `i2c_pkg.sv`. At a 50 MHz system clock this is
5 × 20 ns = 100 ns. The I2C standard mode hold time is 300 ns, but our
simulation timing is tightened to keep simulation runs short. The principle
is identical: SDA must not move IMMEDIATELY after SCL falls.

#### Why slow devices need this
After SCL transitions HIGH → LOW, the slave's input sample-flip-flop has a
hold-time requirement of its own. If the master changes SDA at the very
same edge that SCL falls, the slave's flip-flop sees a metastable input. By
holding SDA stable for at least T_HD_DAT cycles AFTER the falling edge, we
guarantee the slave's sample has settled before SDA moves.

#### The `$stable(sda_samp)[*T_HD_DAT]` syntax decoded
`$stable(expr)` is a built-in SVA function that returns 1 if `expr` has the
same value as it did one cycle ago, else 0. So:

```
$stable(sda_samp)[*5]
```
expands to:
```
$stable(sda_samp) ##1
$stable(sda_samp) ##1
$stable(sda_samp) ##1
$stable(sda_samp) ##1
$stable(sda_samp)
```
Each `$stable(sda_samp)` asks: did sda_samp change from the previous cycle?
If 5 consecutive cycles all answer "no, it didn't change", the sequence
passes. If any one answers "yes, it changed", the sequence fails.

#### ASCII waveform — PASS
```
cycle:           T-1   T    T+1   T+2   T+3   T+4   T+5
SCL:              H   ↓L     L     L     L     L     L
sda_samp:         X    X     X     X     X     X     Y    <- changes here, OK

A8 triggered at cycle T (scl_fall). Checks [*5] from T+1..T+5.
  T+1: sda_samp == X (was X) -> $stable = 1, OK
  T+2: sda_samp == X (was X) -> $stable = 1, OK
  T+3: sda_samp == X (was X) -> $stable = 1, OK
  T+4: sda_samp == X (was X) -> $stable = 1, OK
  T+5: sda_samp == X (was X) -> $stable = 1, OK   then T+6 sda goes Y, fine
A8 PASSES.
```

#### ASCII waveform — FAIL
```
cycle:           T-1   T    T+1   T+2   T+3   T+4   T+5
SCL:              H   ↓L     L     L     L     L     L
sda_samp:         X    X     X     X     Y     Y     Y    <- changed at T+3!

  T+1: $stable = 1, OK
  T+2: $stable = 1, OK
  T+3: sda_samp went X -> Y, $stable = 0, FAIL!
A8 FAILS. $error fires citing T_HD_DAT=5 violation.
```

#### Why this matters (bug class A8 catches)
- **Master changes SDA on falling SCL edge**: A naive RTL coder might
  assign `sda_o = next_bit` in the same `always_ff` block that toggles SCL.
  This creates a zero-delay race in real silicon. A8 catches it because
  sda_samp transitions on the exact same cycle as scl_fall.
- **Slow slave sampling**: Some I2C slaves use the *falling* SCL edge to
  latch the bit (less common, but spec-compliant). Without A8 a master
  could change SDA before such a slave finishes its sample.
- **Glitch from bus capacitance**: Heavy bus loading can delay SDA
  transitions; A8 ensures the master allows enough headroom for the bus
  to settle before changing.

---

### A9 — SDA Setup Time Before SCL Rise (the exact production code)

#### The committed source (sva/i2c_protocol_assertions.sv:244–263)
```systemverilog
//=============================================================================
// A9: SDA Setup Time Before SCL Rises (Glitch Window Check)
// I2C spec T_SU_DAT: SDA must be stable for at least T_SU_DAT cycles BEFORE
// SCL rises. The slave will sample sda_samp at the rising edge of SCL.
// If SDA changes within the setup window, the slave could sample the wrong
// value. We check: at the cycle of scl_rise, SDA must have been stable for
// the previous T_SU_DAT cycles. T_SU_DAT = 5 in i2c_pkg.sv, so we compare
// sda_samp against its value T_SU_DAT cycles in the past — if they match,
// SDA has been stable across that window.
//=============================================================================
property p_sda_setup_before_scl_rise;
  @(posedge clk)
  disable iff (!rst_n)
  ((in_data_phase || in_ack_phase) && scl_rise_a8 && !start_cond_asserted && !stop_cond_asserted)
    |-> ($past(sda_samp, T_SU_DAT) == sda_samp);
endproperty

assert_sda_setup: assert property (p_sda_setup_before_scl_rise)
  else $error("I2C-SVA-A9: SDA changed within T_SU_DAT=%0d setup window before SCL rise at time %t",
              T_SU_DAT, $time);
```

#### T_SU_DAT — the setup window
T_SU_DAT = 5 cycles. The slave samples sda_samp at the rising edge of SCL.
For the sample to be valid, sda_samp must have been at its current value
for at least the previous 5 cycles. If it changed within the setup window,
the slave's sample flip-flop sees a metastable input.

#### The `$past(sda_samp, T_SU_DAT) == sda_samp` trick — why it works
`$past(signal, N)` returns the value of `signal` from N cycles ago. So:

```
$past(sda_samp, 5) == sda_samp
```
asks: "Is the value of sda_samp 5 cycles ago equal to the current value?"

If sda_samp has been at its current value for at least 5 cycles, the
comparison is true. If sda_samp changed during the window, the comparison
is false (the value 5 cycles ago was the OLD value, not the current).

This is a clever, efficient check. The alternative `$stable(sda_samp)[*5]`
would unroll into a 5-cycle sequence, which requires extra simulator
machinery. A simple register lookup + equality is cheaper.

**Edge case**: if sda_samp toggled and then toggled back within 5 cycles,
`$past(s,5) == s` would PASS (because the value 5 cycles ago happens to
match by coincidence). The full `$stable(s)[*5]` would FAIL in that case
because it requires no change AT ALL across the window. For setup-time
checks we accept this — what matters for the slave's sample is the value
at the rising edge, and if it had been at the current value 5 cycles ago,
the slave's S/H flip-flop has had enough time to settle.

#### ASCII waveform — PASS
```
cycle:        T-5   T-4   T-3   T-2   T-1   T (scl_rise)
SCL:           L     L     L     L     L     ↑H
sda_samp:      X     X     X     X     X     X         ← stable for 5 cycles

A9 triggered at cycle T (scl_rise_a8).
  $past(sda_samp, 5) = sda_samp at T-5 = X
  sda_samp at T = X
  $past == sda_samp -> TRUE. A9 PASSES.
Slave samples X at cycle T. Correct value captured.
```

#### ASCII waveform — FAIL
```
cycle:        T-5   T-4   T-3   T-2   T-1   T (scl_rise)
SCL:           L     L     L     L     L     ↑H
sda_samp:      X     X     Y     Y     Y     Y         ← changed at T-3!

  $past(sda_samp, 5) = sda_samp at T-5 = X
  sda_samp at T = Y
  $past != sda_samp -> FALSE. A9 FAILS.
$error("I2C-SVA-A9: SDA changed within T_SU_DAT=5 setup window...") fires.
```

#### Why this matters (bug class A9 catches)
- **Setup-violation at the slave sampling point**: The slave's S/H
  flip-flop captures whatever is on SDA at the SCL rising edge. If SDA
  was still settling, the slave captures the wrong bit. A9 ensures the
  master gives the slave enough stable time before each sample point.
- **Combinational SDA driver**: If sda_o is driven by a `wire` (continuous
  assignment) from a fast counter, it might change just before SCL rises.
  A9 enforces that the SDA value at SCL_rise has been stable for the
  whole setup window.
- **Cross-domain races**: If sda_o and scl_o are driven from different
  clock domains (rare in this project, but possible in some platforms),
  they could phase-shift. A9 detects the case where SDA arrives "late".

---

### From 6 to 9 Assertions — Why We Added Three

The original assertion suite had 6 assertions (A1–A6) covering the
structural protocol rules. Adding A7, A8, A9 was a deliberate progression
from "structural correctness" to "timing-window correctness". Here is the
full assertion table with one-line purposes:

| Asrt | Type | Property | Catches |
|------|------|----------|---------|
| A1 | Structural | SDA-falls-while-SCL-HIGH ⇒ START condition | Bogus mid-bit transitions misclassified as START |
| A2 | Structural | After STOP, bus eventually HIGH within T_BUF | Bus permanently stuck LOW after STOP |
| A3 | Structural | SDA stable while SCL HIGH in data phase | Mid-bit SDA corruption (the I2C cardinal rule) |
| A4 | Structural | ACK happens on 9th bit | Missing or misaligned ACK cycle |
| A5 | Structural | Slave 7-bit address only — no 10-bit mode | Spec-out-of-scope addressing |
| A6 | Structural | After NACK, master issues STOP or rep-START | Stuck-state after NACK |
| **A7** | **Timing** | Bus HIGH for FULL T_BUF after STOP (strict) | Glitch during bus-free window |
| **A8** | **Timing** | SDA stable for T_HD_DAT after SCL fall | Early SDA change (hold violation) |
| **A9** | **Timing** | SDA stable for T_SU_DAT before SCL rise | Late SDA change (setup violation) |

#### The progression: structural → timing

**Structural assertions (A1–A6)** answer the question: *"Did the events
happen in the right order?"* These are typically expressed as
`event A |-> ##N event B` properties. They catch protocol-level bugs:
missing ACK, wrong direction bit, premature STOP, etc.

**Timing assertions (A7–A9)** answer the question: *"Did the events
happen with the right edge-relative spacing?"* These are typically
expressed as `event |-> $stable(...) [*N]` or `event |-> $past(...) == ...`
properties. They catch glitches, races, setup/hold violations, and other
edge-relative failures that the structural assertions can't see.

#### Bug-class coverage

- A1–A6 catch: protocol violations (missed ACK, wrong ordering, bad addr,
  illegal mode, stuck states). These are typically caught very early in
  simulation; a single sim run usually triggers them if broken.

- A7 catches: glitches during quiescence. Hard to find with structural
  asserts because the bus is supposed to be idle. Without A7, a slave
  driving a brief LOW during T_BUF could go unnoticed for weeks.

- A8 catches: hold violations. Without A8, a master changing SDA on the
  exact cycle of scl_fall would pass A3 (SDA was stable during SCL HIGH)
  but corrupt a slave that latches on the falling edge.

- A9 catches: setup violations. Without A9, a master that changes SDA
  one cycle before scl_rise would pass A3 (the new value IS stable during
  the SCL HIGH window that follows), but the slave's first sample at the
  rising edge could be metastable.

#### Why we did not add A10, A11, ...

The team considered additional assertions:

- **A10 candidate**: "ACK pulse SDA stays LOW for full SCL HIGH window".
  Decided: already covered by A3 (SDA stable during SCL HIGH) plus the
  scoreboard's ACK check.
- **A11 candidate**: "Stretch duration ≤ MAX_CLK_STRETCH". Decided:
  belongs in the controller's timeout logic; an assertion would duplicate
  the timeout signal.
- **A12 candidate**: "Rep-START preserves bus busy". Decided: already
  implicit in A1 (the rep-START is just a new START while busy).

The principle is **add an assertion when it catches a bug class no
existing assertion can catch**. Adding redundant assertions slows
simulation and creates maintenance burden when the assertion needs to be
adjusted for legitimate corner cases.

---

### Operator Reference Cards (added per Part 16 — for quick recall)

#### `[*N]` — Consecutive Repetition
```
P[*3]  ≡  P ##1 P ##1 P
```
Use when: "must hold for N consecutive cycles".

#### `[=N]` — Non-Consecutive Repetition
```
P[=2]  ≡  P holds 2 times eventually (with gaps allowed)
```
Use when: "must occur N times but timing is loose".

#### `[->N]` — Goto Repetition
```
P[->2] ≡  P holds 2 times, ending the cycle when N-th hold occurs
```
Use when: "fire on the Nth occurrence".

#### `$past(s, N)` — Lookback
Returns value of s from N cycles ago. Costs one register per cycle of
lookback. Use for setup checks.

#### `$stable(s)` — Edge Detector
Returns 1 if s did not change from the previous cycle. Compose with `[*N]`
for hold-window checks.

#### `$rose(s)` / `$fell(s)` — Edge Detection
Returns 1 only on the rising/falling cycle. Use for one-shot triggers.

---

## Part 17: EDA Playground Parity — A1/A2 Now Temporal in `if_sva.sv`

### The Problem: Silent Divergence Between Files

When BUGs #11 and #12 were fixed in `sva/i2c_protocol_assertions.sv`, A1 and
A2 became real temporal properties — they will actually fail if the protocol
is violated. But the EDA playground companion file `eda_playground/if_sva.sv`
was not updated at the same time. It continued to carry the old simplified
versions: tautological one-liners that could never fail, regardless of what
the bus was doing.

This is the danger of having two copies of the same specification. One copy
gets updated. The other copy doesn't. Nobody notices for a while because both
files "compile without errors." Tautological assertions are the worst kind of
error — they look like passing checks but they verify absolutely nothing.

### What the EDA Playground Was Checking (Before the Fix)

The old `if_sva.sv` A1 looked roughly like:

```systemverilog
// Old (tautological) — always evaluates to 1'b1
A1_start_cond: assert property (
  @(posedge clk) 1'b1
);
```

And similarly for A2. A simulator running these would report "A1 PASS" on
every cycle. That is meaningless — it is not checking the START condition timing
at all. Anyone experimenting on EDA Playground would see green assertion checks
while running a completely broken bus.

### What the Fixed A1 and A2 Now Check

**A1 — START Hold Time (temporal):**

After the SDA falling edge while SCL is HIGH (the START condition signature),
SCL must go LOW within `T_HD_STA + T_SCL_PERIOD` cycles. In this project,
that window is 10 + 500 = 510 cycles. The property is:

```systemverilog
A1_start_cond: assert property (
  @(posedge clk) disable iff (!rst_n)
  ($fell(sda) && scl) |-> ##[1:510] $fell(scl)
);
```

This is a true temporal property. If SCL never falls within 510 cycles after
SDA falls, the assertion fires a FAIL. The BFM always drives SCL low within a
few cycles of the START condition, so under normal operation this property
passes every time. But it WOULD catch a DUT that forgets to pull SCL low after
a START — exactly the class of bug it was written to guard against.

**A2 — Bus Free Time After STOP (temporal):**

After the SDA rising edge while SCL is HIGH (the STOP condition signature),
within `T_BUF` cycles (20 cycles in this design), there must be at least one
cycle where both SDA and SCL are HIGH. This ensures the bus is genuinely
released and catches any premature attempt to start a new transaction:

```systemverilog
A2_stop_cond: assert property (
  @(posedge clk) disable iff (!rst_n)
  ($rose(sda) && scl) |-> ##[0:20] (sda && scl)
);
```

After a STOP, the open-drain pull-ups immediately release both lines to HIGH.
The BFM satisfies this within one or two cycles. But a slave that holds SDA or
SCL LOW after STOP would trigger A2 — which is the bug it catches.

### Why These Windows Work With the BFM

A1's window of 510 cycles is intentionally generous. The BFM drives SCL low
within perhaps 2-5 cycles of issuing a START condition. So A1 has enormous
slack in normal operation. The point is NOT to check the exact timing — that
is what A7/A8/A9 do. A1 simply checks that SCL eventually falls after START.
If it never falls, you have a dead bus.

A2's window of 20 cycles (`T_BUF`) is tight but matches the bus-free-time
parameter. After STOP, pull-ups act within nanoseconds. 20 cycles at 50 MHz
is 400 ns — far more than any realistic pull-up recovery time. If SDA or SCL
is still LOW 20 cycles after STOP, something is actively holding the line down,
which is a genuine bus error.

### The Lesson: Always Verify EDA Playground Parity

Any time you fix an assertion in the production SVA file, immediately open the
EDA playground version and check whether it needs the same fix. One concrete
practice: add a comment at the top of `if_sva.sv` that says "This file must
remain in sync with `sva/i2c_protocol_assertions.sv` for assertions A1-A9."
Then make parity checks part of your bug-fix procedure, not an afterthought.

The rule of thumb: if an assertion compiles cleanly and you cannot construct a
testbench scenario that makes it FAIL, it is probably tautological. Test your
assertions the same way you test your DUT — try to break them.

---

*End of Part 16 — Production-Hardening Notes on A7, A8, A9*
