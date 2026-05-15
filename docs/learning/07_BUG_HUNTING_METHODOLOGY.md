# File 07 — Bug Hunting Methodology: How a Senior Engineer Thinks

> "Finding bugs is not luck. It is a repeatable process applied by someone who
>  understands the protocol, understands the data paths, and knows what
>  'wrong' looks like before it shows up in a waveform."
>
> — Every senior verification engineer who has spent three days chasing a one-line bug

---

## Who This File Is For

You have already seen WHAT the 15 bugs were. Now you need to understand HOW
a senior engineer would have found them — the thought process, the questions,
the order of investigation. This is the skill that separates a junior who can
run regressions from a senior who can debug anything.

Read this before your next interview. These patterns come up constantly.

---

## Part 1: The Senior Engineer Mindset — Six Rules

These are not abstract principles. They are battle-tested habits that directly
explain how every single bug in this project could have been caught faster.

---

### Rule 1: Protocol First, Code Second

Before you open a single RTL file, ask: "What does the protocol REQUIRE at this
moment in time?"

If you know the I2C specification well enough to simulate it in your head, then
violations jump off the screen. You do not need a simulation to catch many bugs
— you just need to trace through the protocol and ask "is the code doing this?"

**How this applies in this project:**

- I2C spec says: data bits 1-8 are clocked by SCL pulses 1-8. The 9th SCL
  pulse is the ACK clock. If you know this before looking at Bug #1, you
  immediately scan the shift register capture point and ask: "is this
  triggering on the 9th clock?" If yes — bug found in 30 seconds.

- I2C spec says: after a slave NACK, the master must not continue sending.
  If you know this before looking at Bug #4, you scan SLV_TX_ACK and ask:
  "does this state check sda_i?" If it does not — Bug #4 found.

- I2C spec says: clock stretching is a slave-controlled mechanism that must
  resume the paused operation, not restart from scratch. If you know this,
  you look at SLV_STRETCH's exit transition and ask: "where does it go?"
  If it goes to IDLE — Bug #3 found.

> **SENIOR ENGINEER TIP:** Build a mental checklist of protocol invariants.
> Write them down. For I2C: (1) SDA stable when SCL high, (2) ACK is 9th bit,
> (3) stretch must resume, (4) STOP only when SCL is high. Scan every state
> machine against this list before running a single simulation.

---

### Rule 2: Data Paths Are Everything

For every output signal in the RTL, trace it backward to its source. Then ask:
- Is there a path from the input to this output?
- Is there a path for EVERY scenario (write, read, stretch, NACK)?
- Is there a scenario where the path is broken?

This is how Bug #2 and Bug #10 were found. Both are "missing data path" bugs —
the path from input to output simply did not exist in the original code.

**The 3-question data path audit:**

```
Q1: Who WRITES this signal?
    (Search for all non-blocking assignments: "signal_name <=")

Q2: Who READS this signal?
    (Search for all uses on the right-hand side)

Q3: For every scenario where the reader expects data, does the writer run?
    (Trace through the FSM — can the write happen before the read?)
```

If Q3 has any "no" — you have a bug.

> **SENIOR ENGINEER TIP:** In large RTL, use grep to find all drivers of a
> signal: `grep -n "signal_name\s*<=" file.sv`. If you expect exactly one
> writer and find two — Bug #8 (multi-driver). If you expect at least one
> writer per scenario and find zero for one scenario — Bugs #2 and #10.

---

### Rule 3: Simulate 3 Cycles in Your Head

For every counter, timer, and state machine, manually simulate 3-5 clock cycles.
Write the register values down. Do not trust your intuition — write it out.

This technique catches off-by-one errors every time, without exception.

**Template for the 3-cycle simulation:**

```
Cycle 0 (reset): signal = RESET_VALUE
Cycle 1:         signal = ?  (apply the logic manually)
Cycle 2:         signal = ?
Cycle 3:         signal = ?
Expected behavior: fires at cycle N
Actual behavior:   fires at cycle ?
```

Bug #14 falls out of this immediately. Bug #9 (SCL stuck low) also falls out
when you apply this to the timer comparison branches.

> **SENIOR ENGINEER TIP:** Off-by-one errors almost always live in one of three
> places: (1) the initialization value of a counter, (2) the comparison
> operator (< vs <=), (3) the order of increment vs. compare. Check all three
> before declaring "the timer is correct."

---

### Rule 4: Check the Checkers

After you verify the DUT, verify the verification.

This sounds circular, but it is essential. Assertions and coverage are only
useful if they can actually FAIL or MISS. A passing assertion that is a
tautology gives you zero information. A coverage group that measures the wrong
signal gives you false confidence.

**The two verification audit questions:**

```
For every assertion:
  "If the DUT were broken in the worst possible way for this property,
   would this assertion still pass?"
  If YES — the assertion is useless (and possibly a tautology).

For every coverpoint:
  "Does this signal actually represent what the comment says?"
  "Can this coverpoint reach 100% even if the feature it guards is broken?"
  If YES — the coverpoint is wrong.
```

Bugs #11, #12, #13 all fall out of this audit.

> **SENIOR ENGINEER TIP:** After writing an assertion, immediately write a test
> that SHOULD violate it. If the violation does not fire the assertion, the
> assertion is wrong. This is called "assertion validation" and it is a
> required step in any serious DV flow.

---

### Rule 5: Ask "Can This Actually Fail?"

Closely related to Rule 4, but broader. Apply this to every check in the
testbench:

- Can the scoreboard actually flag a mismatch here?
- Can this assertion fire on a design that has this specific bug?
- If I break the DUT in this exact way, does any check catch it?

This forces you to think about the negative space — what bugs are NOT covered
by your current testbench.

**Example from this project:**

The original Bug #11 assertion was:
```systemverilog
(scl_samp == 1'b1 && sda_fall) |-> (scl_samp == 1'b1)
```

Can this fail? The antecedent requires `scl_samp == 1'b1`. The consequent
asserts `scl_samp == 1'b1`. Between the `|->` (same cycle implication) and the
clock edge, SCL cannot change. So: NO, this assertion can never fail. It is
checking that "if SCL is high, then SCL is high."

Ask "can this actually fail?" and you find the tautology in 10 seconds.

---

### Rule 6: Dead Code = Missing Logic (Or Worse, Wrong Logic)

If a branch of code is never reached during simulation, it is not necessarily
harmless. Ask:

- Was this branch SUPPOSED to be reached?
- If yes — the logic that triggers it is wrong (missing or wrong condition).
- If no — why is it there? Does the developer think it is being reached?

Dead code that the developer THINKS is active is a critical bug. The code does
nothing, but the developer assumes it does something, so they never write a test
for the alternative path.

Bug #15 is exactly this. The inner `if (start_cond)` check in `SLV_IDLE` was
meant to handle START detection, but the outer `if (start_cond)` guard above
the case statement made it unreachable. The developer may have believed the
inner check was the active one.

> **SENIOR ENGINEER TIP:** Enable code coverage in every regression run. Any
> branch that shows 0 hits after a full regression is suspicious. Either the
> testbench is missing a test case (test coverage gap), or the condition that
> triggers that branch can never be true (dead code bug). Always investigate.

---

## Part 2: The 5-Step Bug Investigation Process

When a test fails, or a waveform looks wrong, use these 5 steps in order.
Do not skip steps. Senior engineers seem to jump straight to the root cause
because they have internalized these steps — they run them automatically.

---

```
Step 1: "What does the failing test TELL me?"
        Read the error message. What signal? What value? What time?
        The error message always points to a symptom — not the root cause.
        Your job is to distinguish symptom from cause.

Step 2: "What signal is WRONG — when and by how much?"
        Open the waveform. Find the specific signal. Identify the first
        moment it is wrong. Wrong by 1 cycle? Wrong forever? Wrong once?
        The answer changes your investigation path.

Step 3: "Trace BACKWARD — who drives this signal?"
        Find all assignments to the wrong signal. Which always block?
        Which state? What conditions? You are looking for the last thing
        that touched the signal before it went wrong.

Step 4: "Trace FORWARD — where is this signal USED?"
        Understand what depends on the wrong signal. This tells you the
        scope of the damage — is this a contained error or does it cascade?

Step 5: "Isolate the ROOT CAUSE — not the symptom."
        The wrong output is a symptom. The wrong output is caused by a
        wrong intermediate value. That wrong intermediate value is caused
        by a wrong condition check. That wrong condition check is caused
        by a wrong design assumption. Keep asking "why is this wrong?"
        until you hit something that violates the protocol or RTL spec.
        That is the root cause.
```

---

## Part 3: Bug-by-Bug — The Finding Story

For each of the 15 bugs, here is exactly how a senior engineer would have found
it — what they look at first, what questions they ask, and where the insight
comes from.

---

### BUG #1: Shift Register Captures ACK Bit as Data

**Symptom reported by test:**
The scoreboard logs show every received byte is wrong. Specifically, bit 0
of every received byte is always the ACK/NACK value, not the actual last
data bit. The data is consistently off in a patterned way.

**Step 1 — What does the test tell me?**
The scoreboard detected a data mismatch. The received value consistently
differs from what the master sent. The error is not random — it is
systematic. Systematic errors point to structural problems in the data path,
not timing issues.

**Step 2 — What signal is wrong and when?**
The bad value arrives as the complete received byte. That means the shift
register is wrong by the time it is committed to `latched_rx_byte` (or
in the original: directly sampled from `shift_reg`).

**Step 3 — Trace backward: who drives shift_reg?**
```systemverilog
// Original shift register logic:
if (scl_rise) begin
  shift_reg <= {shift_reg[6:0], sda_i};
end
```
This shifts on EVERY `scl_rise`, including the 9th clock (ACK clock).

**The key question a senior asks:**
"On which SCL rising edge does the data capture happen?"

**Step 4 — Mental simulation of shift_reg contents:**

```
SCL pulse:     1    2    3    4    5    6    7    8    9(ACK)
SDA value:    D7   D6   D5   D4   D3   D2   D1   D0   ACK
shift_reg:   [D7] [D7,D6] [D7..D5] ... [D7..D0] [D6..D0,ACK]
                                              ↑           ↑
                                   Correct capture    Wrong: ACK pollutes bit 0
```

After 8 SCL pulses, `shift_reg` = `{D7,D6,...,D1,D0}` — correct.
After 9th SCL pulse: `shift_reg` = `{D6,...,D1,D0,ACK}` — WRONG.

**Step 5 — Root cause:**
The capture happens on `scl_rise` without checking which clock number it is.
The 9th clock is the ACK clock, not a data clock. The fix is to latch the
byte BEFORE the 9th clock:

```systemverilog
// Correct: latch on the 8th SCL falling edge (before ACK clock)
if (state == SLV_RX && bit_cnt == 4'd7 && scl_rise) begin
  latched_rx_byte <= {shift_reg[6:0], sda_i};
end
```

> **SENIOR ENGINEER TIP:** Whenever data is "wrong by 1 bit" or "shifted by 1",
> the first place to look is the capture point. Is it one clock too late?
> One clock too early? Draw the waveform on paper for cycles 6-9 and the
> answer becomes obvious.

---

### BUG #2: Slave TX Mode Drove High-Z (No TX Shift Register)

**Symptom reported by test:**
Read transactions return 0xFF (all ones) or garbage. The master reads back
data, but it never matches what was previously written. The scoreboard
always fails on read comparisons.

**Step 1 — What does the test tell me?**
Read transactions are broken. Write transactions may be fine (this narrows
the search to the read data path). The master is probably clocking bits
correctly but the slave is not driving SDA during the read.

**Step 2 — What signal is wrong and when?**
Open the waveform. Look at SDA during the slave TX phase (after the slave
ACKs its address with R/W=1). SDA should be toggling as the slave drives
data bits. If SDA is 1'bZ (high) or stuck — the slave is not driving.

**Step 3 — Trace backward: who drives sda_o during SLV_TX state?**
```systemverilog
// Original SDA output logic:
SLV_TX: begin
  sda_o <= 1'b1;  // BUG: always releases! Never drives data!
end
```
Or perhaps the SLV_TX case is missing entirely from the always block.

**Step 4 — Trace forward: where is sda_o used?**
`sda_o` drives the open-drain SDA pin. If it is always 1'b1 (released), the
pull-up holds SDA high. The master reads 1'b1 for every bit — all ones.
That explains the 0xFF return value.

**Step 5 — Root cause:**
There is no TX shift register. The original slave had one shift register
(`shift_reg`) used for receiving. There was no mechanism to LOAD the
register from internal_regs and shift it OUT during SLV_TX. The hardware
path simply did not exist.

**The fix requires adding a new register:**
```systemverilog
logic [7:0] tx_shift_reg;

// Load when entering TX mode
if (state == SLV_ACK && addr_matched && rx_rw == 1'b1) begin
  tx_shift_reg <= internal_regs[reg_ptr];
end

// Shift out MSB-first on each SCL falling edge
if (state == SLV_TX && scl_fall) begin
  tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};
end

// Drive SDA from MSB of tx_shift_reg
SLV_TX: sda_o <= tx_shift_reg[7];
```

> **SENIOR ENGINEER TIP:** Any time a feature "always returns 0x00 or 0xFF",
> look for a missing data path. 0x00 means the register was never written
> (stays at reset). 0xFF means SDA was never driven (pull-up wins). These
> are structural gaps, not subtle timing bugs.

---

### BUG #3: Clock Stretch Returns to SLV_IDLE Instead of Previous State

**Symptom reported by test:**
After clock stretching, a read transaction that was in progress fails.
The slave appears to "forget" what it was doing and goes quiet. If you
watch the FSM state in the waveform, it returns to IDLE after the stretch
instead of continuing the read.

**Step 1 — What does the test tell me?**
Clock stretch functionality is broken. The stretch itself may work (SCL is
held low) but the recovery is wrong.

**Step 2 — What signal is wrong and when?**
The FSM `state` signal. After the stretch timer expires, `state` transitions
to `SLV_IDLE` instead of the state that was active before the stretch.

**Step 3 — Trace backward: who drives next_state in SLV_STRETCH?**
```systemverilog
// Original:
SLV_STRETCH: begin
  if (!stretch_active) begin
    next_state = SLV_IDLE;  // BUG: always goes to IDLE
  end
end
```

**The key question a senior asks:**
"What should the slave return to after a stretch? It must return to wherever
it was BEFORE the stretch happened." This requires storing that state.

**Step 4 — The saved_state pattern:**
This is a classic FSM pattern. When you enter a "service state" (stretch,
wait, pause), you must save where you came from so you can return.

```systemverilog
// In sequential always_ff:
if (stretch_active && state != SLV_STRETCH)
  saved_state <= state;  // Capture state BEFORE entering stretch

// In combinational next-state:
SLV_STRETCH: begin
  if (!stretch_active)
    next_state = saved_state;  // Return to saved state
end
```

**Step 5 — Root cause:**
The SLV_STRETCH state had no memory of where the FSM came from. The fix
introduces `saved_state` — a register that remembers the pre-stretch state.
This is a design pattern you should know by heart.

> **SENIOR ENGINEER TIP:** The saved_state pattern appears in interrupt
> handling, sleep modes, error recovery, and pause states. Any time a state
> machine needs to "temporarily leave and come back", save where you came from.
> The bug version always goes to IDLE — a red flag that the designer forgot
> state context is needed.

---

### BUG #4: TX_ACK State Does Not Check Master ACK/NACK

**Symptom reported by test:**
A read transaction with NACK termination (master reads one byte, sends NACK,
then STOP) causes the slave to keep driving SDA after the master's NACK.
The slave seems to be trying to send more data even after being told to stop.

**Step 1 — What does the test tell me?**
The slave does not respond correctly to master NACK. After the master sends
NACK on the 9th clock of a read byte, the slave should stop. Instead it
continues.

**Step 2 — What signal is wrong and when?**
The FSM state after SLV_TX_ACK. It should transition to SLV_IDLE (master
NACK = stop) or SLV_TX (master ACK = continue). But it always goes to SLV_TX.

**Step 3 — Trace backward: what drives next_state in SLV_TX_ACK?**
```systemverilog
// Original:
SLV_TX_ACK: begin
  if (scl_fall) begin
    next_state = SLV_TX;  // BUG: always continues, ignores sda_i
  end
end
```

**The protocol check:**
I2C rule: during the ACK clock cycle for a read byte, the MASTER drives SDA.
`sda_i == 0` means master ACK (please send more). `sda_i == 1` means master
NACK (I have enough, stop).

**Step 4 — Fix is one conditional:**
```systemverilog
SLV_TX_ACK: begin
  if (scl_fall) begin
    if (sda_i == 1'b0) next_state = SLV_TX;   // ACK: continue
    else               next_state = SLV_IDLE;  // NACK: stop
  end
end
```

**Step 5 — Root cause:**
The developer forgot to sample `sda_i` during SLV_TX_ACK. The transition
was unconditional. Protocol knowledge is the key — without knowing that the
master signals NACK by driving SDA high during the 9th clock, you would not
know what to check.

---

### BUG #5: False Clock Stretch During Idle

**Symptom reported by test:**
Occasionally, SCL appears to be held low even when no transaction is in
progress. If a second master is present, it cannot start a transaction because
it sees SCL low. If you watch the waveform, `stretch_active` asserts in IDLE.

**Step 1 — What does the test tell me?**
Spurious SCL hold during idle. Clock stretch logic is activating at the
wrong time.

**Step 2 — What signal is wrong and when?**
`stretch_active` is asserting when `state == SLV_IDLE`.

**Step 3 — Trace backward: what causes stretch_active to assert?**
```systemverilog
// Original activation condition:
if (stretch_en && !stretch_active) begin  // BUG: missing active_int check
  stretch_active <= 1'b1;
end
```

**The question a senior asks:**
"Should clock stretch ever activate when the slave is not participating in
a transaction?" Answer: NO. Clock stretching is only meaningful during an
active transaction. During idle, driving SCL low is a protocol violation.

**Step 4 — Fix adds the transaction guard:**
```systemverilog
if (stretch_en_rise && !stretch_active && active_int) begin
  stretch_active <= 1'b1;
end
```

`active_int` is only set when the slave has successfully ACK'd its own address.
This ensures stretch only activates during a real transaction.

---

### BUG #6: No force_data_nack Test Hook

**Symptom:** Not a functional bug in the DUT — a gap in the testbench.
There was no way to make the slave send a data NACK.

**How a senior finds this:**
During test planning, write a list of every I2C scenario the master must
handle. "Data NACK from slave" is on that list. Then ask: "Is there a way
to trigger this in the testbench?" If no — the testbench is incomplete.

**The fix** is adding `force_data_nack` as a port and using it in SLV_RX_ACK:
```systemverilog
SLV_RX_ACK: begin
  sda_o <= (active_int && !force_data_nack) ? 1'b0 : 1'b1;
end
```

This is a "test hook" — a small input added specifically to enable test
injection. Senior engineers always ask: "What behaviors in the DUT can I
not trigger through normal stimulus?" Those are the places where test hooks
are needed.

---

### BUG #7: Slave Agent Config_db Override Failed

**Symptom reported by test:**
Tests that set the slave agent to UVM_ACTIVE do not work. The slave agent
behaves as passive — it does not drive any stimulus even though the test
configured it to be active.

**Step 1 — What does the test tell me?**
UVM configuration is not reaching the slave agent correctly.

**Step 2 — Trace the config_db chain:**
```
Test:        uvm_config_db::set(this, "env.slave_agent", "is_active", UVM_ACTIVE)
Environment: uvm_config_db::set(this, "slave_agent",    "is_active", UVM_PASSIVE)
```

**The key question:**
"Which set wins when both the test and the env set the same path?"
Answer: UVM config_db uses "most specific path wins" — the env's path
`"slave_agent"` (relative to env context) is more specific than the test's
`"env.slave_agent"` (absolute). The env's set overwrites the test's.

**Step 3 — The fix: check-before-set:**
```systemverilog
// In env build_phase:
if (!uvm_config_db#(uvm_active_passive_enum)::get(
      this, "slave_agent", "is_active", slave_is_active)) begin
  // Only set default if test did not already set it
  uvm_config_db#(uvm_active_passive_enum)::set(
      this, "slave_agent", "is_active", UVM_PASSIVE);
end
```

The env tries to GET first. If the test already set a value, the GET succeeds
and the env skips its own set. If the test did not set it, the GET fails and
the env provides the default.

> **SENIOR ENGINEER TIP:** The config_db "check-before-set" pattern is the
> correct way to implement defaults that tests can override. Never blindly
> set a config_db value in a component that is supposed to accept test
> overrides — always check first.

---

### BUG #8: Multi-Driver on next_state in Master Controller

**Symptom:**
Synthesis tool reports: "ERROR: Multiple drivers on signal 'next_state'"
or EDA simulator prints X values on next_state.

**Step 1 — What does the error tell me?**
`next_state` has two always blocks driving it simultaneously. This is
illegal in synthesizable RTL.

**Step 2 — Find all drivers using grep:**
```bash
grep -n "next_state\s*<=" i2c_master_controller.sv
grep -n "next_state\s*=" i2c_master_controller.sv
```

This immediately shows assignments in TWO always blocks — one `always_ff`
and one `always_comb`.

**Step 3 — Why is this a problem?**

In synthesizable SystemVerilog, a signal must have exactly one driver.
If both `always_ff` and `always_comb` drive `next_state`:
- The synthesizer does not know which block "wins"
- In simulation, the last assignment in evaluation order wins — which is
  nondeterministic and tool-dependent
- Real hardware cannot have two combinational networks driving the same wire
  without a conflict (short circuit if they drive different values)

**Step 4 — The correct two-always-block FSM pattern:**
```systemverilog
// always_ff: ONLY handles state registration
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) state <= STATE_IDLE;
  else        state <= next_state;  // Read next_state, do NOT write it here
end

// always_comb: ONLY drives next_state
always_comb begin
  next_state = state;  // Default: hold
  case (state)
    // ... all transitions here ...
  endcase
end
```

The `always_ff` reads `next_state` (RHS of `<=`) and writes `state`.
The `always_comb` reads `state` and writes `next_state`.
No signal is driven by more than one block.

> **SENIOR ENGINEER TIP:** The two-always-block FSM style is the industry
> standard precisely because it makes this rule easy to follow. `always_ff`
> owns registered signals. `always_comb` owns combinational signals. They
> never cross this boundary.

---

### BUG #9: SCL Permanently LOW During TX in Master Controller

**Symptom reported by test:**
No I2C transactions complete. SCL is stuck low after the START condition.
The bus appears frozen. The waveform shows SCL = 0 continuously.

**Step 1 — What does the test tell me?**
SCL is stuck low. The master timer is probably running but the SCL output
logic is wrong.

**Step 2 — What signal is wrong and when?**
`scl_o` is 0 throughout STATE_TX_BIT. It should toggle between 0 and 1
based on the timer.

**Step 3 — Trace backward: what drives scl_o in STATE_TX_BIT?**

Look at the original buggy code:
```systemverilog
// BUGGY:
STATE_TX_BIT: begin
  if (!timer_expired) begin
    scl_o <= 1'b0;  // BUG: should hold current phase, but drives 0
  end else begin
    scl_o <= 1'b0;  // BUG: should drive opposite phase, but also drives 0
  end
end
```

Both branches drive `scl_o <= 1'b0`. SCL can never go high.

**Step 4 — Manual timer simulation:**

```
T=0:   timer=0,   timer_expired=0, scl_o => 1'b0 (low phase, correct start)
T=1:   timer=1,   timer_expired=0, scl_o => 1'b0 (still low, but should stay low)
...
T=249: timer=249, timer_expired=0, scl_o => 1'b0
T=250: timer=250, timer_expired=1, scl_o => 1'b0  ← BUG: should go HIGH here
T=251: timer=251, timer_expired=0, scl_o => 1'b0  ← BUG: stays low
...
```

The timer expires at T=250, which should toggle SCL to high, but both branches
drive low. SCL never rises.

**Step 5 — Root cause:**
Wrong assignment in the `timer_expired` branch. The fix tracks a `current_phase`
signal and uses it to drive SCL correctly:

```systemverilog
STATE_TX_BIT: begin
  if (timer < T_SCL_LOW)       scl_o <= 1'b0;  // Low phase
  else if (timer < T_SCL_LOW + T_SCL_HIGH)
                               scl_o <= 1'b1;  // High phase
  else                         scl_o <= 1'b0;  // Back to low
end
```

> **SENIOR ENGINEER TIP:** When a periodic signal is stuck at a fixed value,
> immediately look at ALL branches of the condition that controls it. If
> EVERY branch drives the same value — that's your bug. It does not matter
> which branch executes; the result is always the same.

---

### BUG #10: reg_data_buf Never Updated After RX — The Classic Data Path Gap

**Symptom reported by test:**
After a read transaction, the CPU reads REG_DATA and gets 0x00. Every time.
The scoreboard comparison fails: expected 0xA5, got 0x00.

**Step 1 — What does the test tell me?**
CPU read returns 0x00 always. This is a classic "register never updated" symptom.
Not random — always zero. Zero is the reset value of `reg_data_buf`.

**Step 2 — Trace forward from the received bits:**

```
I2C bus → sda_i → shift_reg (via shift-in on scl_rise in STATE_RX_BIT) → ???
```

Where does `shift_reg` go after receiving all 8 bits?

**Step 3 — Search for all places that write reg_data_buf:**
```bash
grep -n "reg_data_buf\s*<=" i2c_master_controller.sv
```

Original result:
```
Line 143: reg_data_buf <= cpu_wdata;  // CPU writes to the register
```

Only one hit. The CPU can write `reg_data_buf`. But there is NO line where
the RTL writes `reg_data_buf` after receiving data from the I2C bus.

**Step 4 — The complete data path audit:**
```
CPU writes cmd=CMD_READ to REG_CMD
FSM moves to STATE_RX_BIT
shift_reg shifts in bits [D7..D0] on scl_rise
FSM transitions to STATE_ACK_SEND when bit_cnt == 7
--- HERE IS THE GAP ---
shift_reg has the correct received byte
reg_data_buf still = 0x00 (reset value, never updated)
CPU reads REG_DATA → gets 0x00
```

The path from `shift_reg` to `reg_data_buf` simply does not exist.

**Step 5 — The fix:**
```systemverilog
// Add to host interface always_ff:
if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND) begin
  reg_data_buf <= shift_reg;  // Forward received byte to CPU-visible register
end
```

This fires exactly once — at the transition from STATE_RX_BIT to STATE_ACK_SEND
(i.e., after all 8 bits are received). The timing is perfect.

> **SENIOR ENGINEER TIP:** This is THE most common class of RTL bug in memory-mapped
> register designs: the receive data path is written to an internal shift register
> but never forwarded to the CPU-visible register. Always trace the COMPLETE path:
> wire → shift_reg → status_reg → CPU register. Any gap in this chain is a bug.

---

### BUG #11: A1 SVA Is a Tautology

**Symptom reported during assertion audit:**
A1 assertion passes on every simulation run, including runs where the START
condition handling was known to be broken. An assertion that always passes when
the DUT is broken is worthless.

**Original assertion:**
```systemverilog
property p_start_cond;
  @(posedge clk)
  (scl_samp == 1'b1 && sda_fall) |-> (scl_samp == 1'b1);
endproperty
```

**The formal logic proof that this is a tautology:**

Step 1: The `|->` is a same-cycle (overlapping) implication.
        "If A then in this same cycle, B must be true."

Step 2: A (antecedent) = `(scl_samp == 1'b1 && sda_fall)`
        This is true only when `scl_samp == 1'b1`.

Step 3: B (consequent) = `(scl_samp == 1'b1)`
        This is what B requires.

Step 4: IF A is true, THEN `scl_samp == 1'b1` is already established by A.
        So B (`scl_samp == 1'b1`) is guaranteed to be true whenever A is true.

Step 5: The implication is `A → (something already in A)`.
        This is always true. It is a tautology.

**How to recognize a tautology by inspection:**
Look at the consequent. If it is a SUBSET of the antecedent conditions,
the implication is always true. B cannot be false if it was already required
for A to be true.

**The fix — check something NOT already implied by the antecedent:**
```systemverilog
// After START (SCL high, SDA falls), SCL must fall within T_HD_STA+T_SCL_PERIOD cycles
(scl_samp == 1'b1 && sda_fall) |-> ##[1:(T_HD_STA + T_SCL_PERIOD)] (scl_samp == 1'b0);
```

Now the consequent (`scl_samp == 1'b0`) contradicts the antecedent
(`scl_samp == 1'b1`). This assertion CAN fail if SCL never goes low after START.

> **SENIOR ENGINEER TIP:** For every assertion you write, spend 30 seconds on
> this test: "If the antecedent is true, is the consequent AUTOMATICALLY true
> without any DUT action?" If yes — you wrote a tautology. The consequent must
> require something the DUT has to actively DO, not something already guaranteed
> by the antecedent.

---

### BUG #12: A2 SVA Is a Tautology

**Original assertion:**
```systemverilog
(scl_samp == 1'b1 && sda_rise) |-> (scl_samp == 1'b1 && sda_samp == 1'b1);
```

**The formal logic proof:**

- `sda_rise` is defined as: `sda_d == 0 && sda_samp == 1`
  So `sda_rise == 1` IMPLIES `sda_samp == 1'b1`.
- The antecedent includes `sda_rise` AND `scl_samp == 1'b1`.
- The consequent requires `sda_samp == 1'b1` AND `scl_samp == 1'b1`.
- Both consequent conditions are already guaranteed by the antecedent.
- Therefore the consequent is always true when the antecedent is true.
- Tautology.

**The fix:**
```systemverilog
// After STOP, bus must remain free for T_BUF cycles
(scl_samp == 1'b1 && sda_rise) |-> ##[1:T_BUF] (scl_samp == 1'b1 && sda_samp == 1'b1);
```

Now the `##[1:T_BUF]` means: IN THE NEXT T_BUF CYCLES, this must remain true.
This can fail if a new START appears too soon after STOP.

---

### BUG #13: i2c_reg_ptr_cg Covers Wrong Signal

**Symptom during coverage review:**
The "Register Access" covergroup hits 100% after just a few random transactions.
This is suspicious — 100% coverage trivially suggests the coverpoint is not
actually measuring anything meaningful.

**Step 1 — What is this covergroup supposed to measure?**
The comment says "Register Access" — which register (0-7) is being accessed.

**Step 2 — What is it actually measuring?**
```systemverilog
cp_reg: coverpoint item.data[0] {   // BUG
  bins low_val  = {[8'h00:8'h3F]};
  bins mid_val  = {[8'h40:8'hBF]};
  bins high_val = {[8'hC0:8'hFF]};
}
```

`item.data[0]` is the FIRST DATA BYTE VALUE (0-255), not the register index.

**Step 3 — Does the measured signal relate to the goal?**
NO. The first data byte value (which ranges 0-255) has nothing to do with
which internal register (0-7) is being accessed. Any random transaction
sends data with some value — 100% coverage of this coverpoint tells you
nothing about whether all 8 registers were accessed.

**Step 4 — What SHOULD be measured?**
The number of data bytes per transaction (`item.num_data`) determines how
many registers are touched (starting from reg_ptr=0). Covering this gives
meaningful information: were all 8 registers ever written in one burst?

**The fix:**
```systemverilog
cp_reg: coverpoint item.num_data {
  bins single_reg   = {1};
  bins partial_bank = {[2:4]};
  bins more_than_half = {[5:7]};
  bins full_bank    = {8};
  bins multi_wrap   = {[9:32]};
}
```

> **SENIOR ENGINEER TIP:** "100% coverage achieved trivially" is a red flag,
> not a celebration. Ask: "What would I have to do to NOT hit this bin?" If
> the answer is "nothing — any transaction hits it" — the bin is meaningless.
> Every bin should require a SPECIFIC, non-trivial scenario to hit.

---

### BUG #14: Stretch Timer Off-by-One

**Symptom reported by test:**
When `stretch_cycles=10` is requested, the actual stretch lasts 11 clock
cycles. The timing is consistently off by 1.

**Step 1 — What does the test tell me?**
Off-by-one in timing. The stretch is 1 cycle longer than requested.

**Step 2 — Simulate the timer manually (Rule 3 applied):**

Original: timer initialized to 0, check is `timer >= stretch_cycles`.

```
Activation: stretch_active=1, timer <= 0
Cycle 1:    timer=0. Check: 0 >= 10? No. timer <= 1.  [1 cycle elapsed]
Cycle 2:    timer=1. Check: 1 >= 10? No. timer <= 2.  [2 cycles elapsed]
...
Cycle 10:   timer=9. Check: 9 >= 10? No. timer <= 10. [10 cycles elapsed]
Cycle 11:   timer=10. Check: 10 >= 10? YES. Deactivate. [11 cycles elapsed]
```

Elapsed cycles = 11, but we requested 10. Off by one.

**Step 3 — Why?**
Timer starts at 0. It reaches value N at cycle N+1 (it takes one cycle to
count from 0 to 1). So the check `timer >= N` fires at cycle N+1, not cycle N.

**Step 4 — Fix: initialize timer to 1:**
```
Activation: stretch_active=1, timer <= 1
Cycle 1:    timer=1. Check: 1 >= 10? No. timer <= 2.  [1 cycle elapsed]
Cycle 2:    timer=2. Check: 2 >= 10? No. timer <= 3.  [2 cycles elapsed]
...
Cycle 9:    timer=9. Check: 9 >= 10? No. timer <= 10. [9 cycles elapsed]
Cycle 10:   timer=10. Check: 10 >= 10? YES. Deactivate. [10 cycles elapsed]
```

Now exactly 10 cycles elapsed. Correct.

> **SENIOR ENGINEER TIP:** The off-by-one error in counters almost always
> comes down to "does the timer VALUE equal the count, or does it equal
> count-minus-one?" A timer that starts at 0 and compares >= N fires after
> N+1 cycles. A timer that starts at 1 and compares >= N fires after N cycles.
> Decide which you want, then initialize accordingly.

---

### BUG #15: Dead Code in SLV_IDLE Case

**Symptom found by code review or code coverage:**
Code coverage shows 0 hits on the `if (start_cond)` branch inside the
`SLV_IDLE` case. The branch is never executed.

**Step 1 — Why is it never reached?**

Look at the FSM always_comb structure:
```systemverilog
always_comb begin
  if (start_cond) begin          // <-- OUTER GUARD checked first
    next_state = SLV_START;
  end else if (stop_cond) begin
    next_state = SLV_IDLE;
  end else begin
    case (state)
      SLV_IDLE: begin
        if (start_cond) begin    // <-- INNER CHECK: can never be true here!
          next_state = SLV_START;
        end else begin
          next_state = SLV_IDLE;
        end
      end
    endcase
  end
end
```

**Step 2 — Control flow analysis:**
To reach the `case (state)` block, we must have passed the outer
`else begin` — meaning `start_cond` was FALSE at the top. Inside the
`SLV_IDLE` case, `start_cond` is re-checked. But `start_cond` is a
combinational signal — it cannot change between the outer check and the
inner check (same clock cycle). If `start_cond` was false at the outer
guard, it is still false at the inner check. The inner `if (start_cond)`
can never be true.

**Step 3 — Why is this dangerous?**
If the developer believes the inner check IS working, they may:
- Assume START is being handled in SLV_IDLE
- Not write a test for START detection
- Have a false sense of coverage

The outer guard is actually handling START correctly. The inner check
is dead — it should either be removed or the developer should acknowledge
that the outer guard is the active handler.

**The fix:**
```systemverilog
SLV_IDLE: begin
  next_state = SLV_IDLE;  // Only reachable path: no start, no stop, stay idle
end
```

> **SENIOR ENGINEER TIP:** Dead code is found by code coverage. Any branch
> with 0 hits after a complete regression is a red flag. It is either: (1) a
> test coverage gap (the condition was never created — add a test), or (2) the
> condition is structurally impossible (dead code — remove or redesign). Never
> ignore 0-hit branches.

---

## Part 4: Bug Pattern Recognition — The Short Reference

After enough debugging, you start recognizing the PATTERN before you find
the specific bug. This table is your cheat sheet.

```
+---------------------------------+---------------------------+-----------------------------------+
| Pattern                         | Common Symptom            | First Place to Look               |
+---------------------------------+---------------------------+-----------------------------------+
| ACK bit captured as data        | Last bit of every byte    | Shift reg capture event:          |
|                                 | is always wrong           | which SCL clock triggers latch?   |
+---------------------------------+---------------------------+-----------------------------------+
| Missing TX data path            | Read returns 0xFF always  | sda_o assignment in TX state:     |
|                                 | (SDA never driven)        | is there a TX shift reg at all?   |
+---------------------------------+---------------------------+-----------------------------------+
| Missing RX-to-CPU data path     | Read returns 0x00 always  | Trace shift_reg forward: does it  |
|                                 | (register stays at reset) | ever reach the CPU register?      |
+---------------------------------+---------------------------+-----------------------------------+
| State machine wrong return      | Feature broken after a    | saved_state pattern: does the     |
|                                 | service state (stretch,   | service state save and restore?   |
|                                 | pause, wait)              |                                   |
+---------------------------------+---------------------------+-----------------------------------+
| Counter off-by-one              | Duration wrong by 1 cycle | Simulate 3 cycles manually:       |
|                                 | (N+1 or N-1)              | init value + compare operator     |
+---------------------------------+---------------------------+-----------------------------------+
| Multi-driver on signal          | Synthesis error, X values | grep all assignments to the       |
|                                 | in simulation             | signal across ALL always blocks   |
+---------------------------------+---------------------------+-----------------------------------+
| Both timer branches same value  | Signal stuck at one value | Look at EVERY branch of the       |
|                                 | (never toggles)           | condition — are any identical?    |
+---------------------------------+---------------------------+-----------------------------------+
| Tautological assertion          | Assertion never fails,    | Check if consequent is already    |
|                                 | even when DUT is broken   | guaranteed by the antecedent      |
+---------------------------------+---------------------------+-----------------------------------+
| Wrong coverage signal           | 100% coverage trivially,  | Does the measured signal actually |
|                                 | after just a few tests    | relate to the intended goal?      |
+---------------------------------+---------------------------+-----------------------------------+
| Missing protocol check in state | Protocol violation        | For each TX/RX state, check:      |
|                                 | ignored (NACK not seen,   | does this state read sda_i for    |
|                                 | ACK not verified)         | the expected protocol response?   |
+---------------------------------+---------------------------+-----------------------------------+
| Config_db override failing      | Test config not applied,  | Check set order and path          |
|                                 | env default always wins   | specificity; use check-before-set |
+---------------------------------+---------------------------+-----------------------------------+
| Dead code (unreachable branch)  | 0% code coverage on branch| Control flow analysis: can the    |
|                                 | feature not testable      | condition EVER be true here?      |
+---------------------------------+---------------------------+-----------------------------------+
```

---

## Part 5: Tools for Bug Hunting

These are the practical tools you use every day. Knowing WHAT to look for
in each tool is the skill.

---

### 1. Waveform Viewer

**What to look for:**
- `X` (unknown) values — these signal a multi-driver conflict, uninitialized
  register, or failed clock domain crossing
- `Z` (high-impedance) on a driven signal — the driver is releasing when it
  should be driving
- Signal stuck at a constant value — should it be toggling? If yes, trace back.
- Timing: does the signal change at the right clock edge? One edge early or
  late matters for setup/hold

**How to use it efficiently:**
- Start from the failing output and work backward
- Add intermediate signals to the waveform (shift_reg, state, bit_cnt)
- Zoom to the first moment a signal is wrong — not the moment you notice it

---

### 2. Simulation Log

**What to look for:**
- `$error` messages from SVA assertions (format: "I2C-SVA-Ax: ...")
- UVM `[MISMATCH]` messages from the scoreboard
- UVM `[ERROR]` messages from components
- Timing of the first error relative to the start of the transaction

**How to use it efficiently:**
- Search for the first error — subsequent errors are often cascades from the first
- Note the simulation time — go to that time in the waveform

---

### 3. Code Coverage

**What to look for:**
- 0% hit branches — potential dead code or test coverage gaps
- 100% statement coverage with 0% branch coverage — possible tautological conditions
- Unreachable states in FSM coverage — is the FSM ever getting to those states?

**How to use it:**
```bash
# After simulation, view coverage report
vcover report -details coverage.ucdb
# Look for: Branch coverage: hit X of Y (Z %)
# Then drill into 0-hit branches
```

---

### 4. Formal Tools (JasperGold, Questa Formal)

**What to look for:**
- Assertion failures with counterexample waveforms (the tool proves your
  assertion CAN fail and shows you HOW)
- Proof of unreachability — the tool can tell you if a state/condition
  is dead code
- Tautology detection — some formal tools flag assertions that are trivially
  true

**When to use formal vs simulation:**
- Simulation: "Does this bug exist in the random test I ran?"
- Formal: "CAN this bug EVER exist, regardless of what test I run?"
- Formal is definitive; simulation only tests what you stimulated

---

### 5. The Grep Technique — Find All Drivers

This is the single most useful command for diagnosing multi-driver and
missing-driver bugs:

```bash
# Find all places that WRITE to a signal (non-blocking or blocking assign):
grep -n "signal_name\s*<=" rtl_file.sv
grep -n "signal_name\s*=" rtl_file.sv

# Find all places that READ a signal:
grep -n "signal_name" rtl_file.sv
```

If you find 2+ always blocks writing the same signal — Bug #8 pattern.
If you find 0 writes in a scenario where writes are expected — Bug #2/#10 pattern.

---

### 6. The 3-Cycle Simulation Technique — Counter Debugging

Apply this to any counter, timer, or bit counter you are debugging:

```
Step 1: Write down the counter's initial value (after reset or load)
Step 2: Write down the condition that increments it
Step 3: Write down the condition that fires (comparison)
Step 4: Manually simulate cycles 1, 2, 3, and N-1, N, N+1
Step 5: Check: does the counter fire at exactly cycle N?
        If it fires at N-1: comparison is <=, should be <
        If it fires at N+1: initialization is 0, should be 1
```

This technique caught Bug #14 in under 2 minutes of manual analysis.

---

## Summary: The Bug Hunter's Mindset in One Page

```
Before touching the code:
  1. Know the protocol cold — what SHOULD happen at each moment?
  2. Have a mental model of every data path

When a test fails:
  1. Read the error message — what is wrong?
  2. Find the first wrong signal in the waveform
  3. Trace backward to the driver
  4. Trace forward to the impact
  5. Distinguish symptom from root cause

Proactive bug finding (before tests fail):
  1. Grep for all drivers of every output signal
  2. Run the 3-cycle simulation on every counter
  3. Audit every assertion for tautology
  4. Audit every coverpoint for meaningfulness
  5. Check code coverage for 0-hit branches

The golden questions:
  "Can this signal ever be wrong?"        → find the edge cases
  "What happens after this error state?"  → check state machine recovery
  "Who writes this and when?"             → trace the data path
  "Does this check actually check anything?" → validate the validator
```

---

## Part 6: The Regression Triage Mindset — When 50 Tests Fail Overnight

You come in Monday morning. The overnight regression has 50 failures. Your
first instinct is to panic. Do not. Fifty failures almost never mean fifty
bugs. In practice, two or three root causes account for the majority of
failures in any regression run. The skill is clustering and triaging —
figuring out what is actually broken before you touch a single line of code.

---

### Step 1: Cluster the Failures Before Doing Anything

Do NOT open a waveform for the first failure you see. First, look at the big
picture across all 50 failures and answer these diagnostic questions:

**Do all failures share the same error message?**

If yes — this is almost certainly ONE root cause. The same assertion, the same
scoreboard mismatch string, or the same timeout message appearing in 50 tests
means one broken thing is causing 50 cascades. Fix that one thing first.

If no — group the failures by error message. You might have three groups of
15-10-5 failures. Each group is likely one root cause.

**Do failures affect one feature or one module?**

If all 50 failing tests involve clock stretching, and all your passing tests
do not use clock stretching — the clock stretch logic is broken. You do not
need to look at any other module. This happened in this project: before Bug
#3 was fixed, every clock_stretch_test failed and every other test passed.

**Are failures random across unrelated tests?**

If write_test, read_test, stretch_test, nack_test all fail with different
error messages at random times — this is the signature of a timing or seed
issue. The bug is nondeterministic. Fix the seed first (use a fixed seed),
then reproduce deterministically before investigating further.

**Diagnostic question to always ask:**
"What changed since the last time the regression passed?"

If the regression was clean on Friday and broken on Monday — something was
committed over the weekend. Start with the commit log before touching any RTL.

---

### Step 2: Find the Smallest Reproducing Case

Once you know which group of failures to investigate, resist the urge to debug
the full simulation. A 50,000-cycle simulation with 10 transactions is hard to
debug. The same bug in 500 cycles with 1 transaction is trivial.

**The reduction procedure:**
1. Pick the simplest failing test in the group
2. Run it in isolation (not as part of a batch)
3. If it uses randomization, fix the seed first: `+UVM_TESTNAME=write_read_test +ntb_random_seed=0`
4. Confirm it still fails with the fixed seed
5. Now you have a deterministic reproducer

**Why this matters:**
A deterministic reproducer means:
- The same bug appears every run
- You can add signals to the waveform and re-run to see them
- You can add `$display` statements and re-run to trace values
- You can iterate a fix in seconds instead of minutes

Without a deterministic reproducer, you are debugging a ghost.

---

### Step 3: Apply the 5-Step Investigation Process

Now that you have one small, deterministic failing test, apply the 5-step
process from Part 2. This is where the actual root cause analysis happens.

The clustering (Step 1) and reproduction (Step 2) only get you to the right
starting point. The 5-step process gets you to the answer.

---

### Step 4: Check if a Recent Commit Caused This

Before assuming the RTL has always been broken, check the commit history.
Many "regression failures" are regressions introduced by a recent change.

```bash
# See what was committed since last Friday (when regression was clean)
git log --since="last Friday" --oneline

# See exactly what changed in a specific commit
git show <commit-hash>

# Find the exact commit that broke things (binary search through history)
git bisect start
git bisect bad          # current state is broken
git bisect good <hash>  # known good state (last clean regression)
# git bisect runs the regression automatically and narrows to the breaking commit
```

**How to match commit to failure:**

Look at what the commit changed. Then ask: "Does this change EXPLAIN the
symptoms I am seeing?"

If a commit changed the stretch timer initialization and all stretch tests
are failing — that is the bug. If a commit changed the SDA output mux and
all read tests are failing — that is the bug.

This cross-reference between commit diffs and failure symptoms is often enough
to identify the bug without opening a single waveform.

---

### Step 5: Fix One Bug, Re-run, Verify the Count Drops

This rule is critical and is violated constantly by impatient engineers:

**Never fix multiple things simultaneously.**

If you find three suspicious things and change all three, then re-run and
see only 20 failures (down from 50) — you do not know which of the three
fixes actually worked. You have no idea if your other two changes are
correct, safe, or even necessary.

The correct process:
```
Fix one thing → re-run the reduced reproducer → verify it passes
                → re-run the full regression → verify count drops
                → document what you fixed and why
                → only then move to the next suspected bug
```

This is slower in the short term and dramatically faster in the long term.
When you know exactly what each fix does, you can be confident in your
changes, write a meaningful commit message, and explain the fix to your team.

---

### The Regression Triage Cheat Sheet

```
50 failures? Ask these in order:
  □ Same error message across many tests?  → ONE root cause, fix it first
  □ All failures in one feature/module?    → That module is broken
  □ Random failures across everything?     → Timing/seed issue, fix seed first
  □ Were tests passing before?             → git log to find the breaking commit
  □ Have a deterministic reproducer?       → Fix seed, run in isolation first
  □ Fixed something?                       → Re-run regression BEFORE touching anything else
```

---

## Part 7: The Art of Minimal Reproducibility

The most valuable skill a senior debug engineer has is not writing assertions
or coverage. It is taking a failing test and reducing it to the smallest
possible case that still fails. This skill is what separates someone who
spends three days on a bug from someone who spends three hours.

---

### Why Minimal Reproduction Matters

Consider two scenarios:

**Scenario A:** Your failing test is a burst read of 8 bytes with clock
stretching, repeated START, and random data. The simulation runs 50,000
cycles. The scoreboard flags a mismatch at cycle 47,832. You have to find
what went wrong somewhere in those 47,832 cycles.

**Scenario B:** You have reduced the same bug to a single-byte read, no
stretching, no repeated START, fixed data 0xAA. The simulation runs 800
cycles. The scoreboard flags a mismatch at cycle 634. You have to find what
went wrong in those 634 cycles.

Same bug. Same root cause. The first takes days to debug. The second takes
an hour. The difference is the reduction.

---

### The I2C Reduction Procedure

Apply these reductions IN ORDER, checking after each one whether the bug
still appears. Stop reducing when one step makes the bug disappear — that
step tells you something important about the bug's nature.

**Reduction 1: Replace burst with single byte**

If your test writes 8 bytes and fails, try writing 1 byte. Does it still
fail? If yes — the bug is not about burst length. If no — the bug appears
only after multiple bytes, which points to register pointer logic, byte
counter wrap, or state machine state after the first ACK.

**Reduction 2: Remove clock stretching**

If your test uses clock stretching and fails, disable it. Does it still
fail? If yes — the bug is unrelated to stretching. If no — the bug is in
the stretch or stretch-recovery path (Bug #3 pattern).

**Reduction 3: Remove repeated START**

If your test uses repeated START (write-then-read in one transaction) and
fails, try separate START-STOP transactions. Does it still fail? If yes —
the bug is not in repeated START handling. If no — look at how the master
or slave handles the repeated START transition.

**Reduction 4: Fix the data value**

If your test uses random data and fails, fix the data to 0xAA (alternating
bits: 10101010). This pattern exercises both 0 and 1 bits, is easy to
recognize in a waveform, and eliminates randomness as a factor. If the bug
disappears with 0xAA but appears with other values — the bug is data-dependent
(check for specific bit patterns that expose timing or setup issues).

**Reduction 5: Remove all randomization**

Fix everything: the slave address, the register address, the data value,
the number of bytes. Run with `+ntb_random_seed=0`. If the bug disappears —
it is seed-dependent (a race condition or timing bug that only appears with
specific stimulus ordering). This is harder to debug but at least you know
what kind of bug it is.

**Reduction 6: Shorten timeouts and fail fast**

If your testbench has 10,000-cycle timeouts, shorten them to 200 cycles.
A bug that causes a timeout at cycle 9,987 will now fail at cycle 200. The
simulation is 50x shorter. You reach the bug immediately instead of waiting
for the timeout.

---

### What to Do When You Have the Minimal Case

Document it. Immediately. Before you do anything else.

The minimal reproduction case goes directly into the bug report:

```
Reproducer: Run write_read_test with +ntb_random_seed=0
            Test writes 0xAA to slave address 0x50, register 0
            Then reads back — scoreboard reports mismatch
            Simulation time of failure: ~634ns
            This reproduces 100% of the time with this seed
```

This documentation serves three purposes:
1. You can hand it to a colleague and they can reproduce the bug immediately
2. After your fix, you run this exact reproducer to verify the fix works
3. It becomes the regression test that prevents this bug from returning

---

### The Reduction Mindset: Binary Search for the Bug

If you have a 10,000-cycle failing simulation and a 800-cycle passing
simulation (before the feature that triggers the bug), the bug's trigger
lives somewhere in between. Think of reduction as binary search:

```
Test with 4 bytes: fails?   Yes → try 2 bytes
Test with 2 bytes: fails?   Yes → try 1 byte
Test with 1 byte:  fails?   Yes → the bug is in single-byte path
                            No  → the bug needs at least 2 bytes (boundary condition)
```

Each reduction halves the search space. After 3-4 reductions, you have a
minimal case that is trivial to analyze.

---

## Part 8: Code Review Techniques — Finding Bugs Before Simulation

The cheapest time to find a bug is during code review — before a single
simulation is run. A bug found in code review costs nothing. The same bug
found after a week of simulation debugging costs days of engineering time.

Good engineers find bugs in code review. This is a skill, and like all
skills it is learned by applying a systematic checklist.

---

### The I2C Project Code Review Checklist

Go through this checklist for every RTL file before approving it:

```
□ Every always_ff has a matching always_comb for next_state
  (two-always-block pattern — one writer per signal)

□ Every shift register: identify the CAPTURE EVENT
  - Which SCL edge triggers the shift? (posedge? negedge?)
  - Which clock NUMBER triggers the latch? (8th? 9th?)
  - Does the capture event correspond to valid data, or the ACK bit?

□ Every counter: check initialization, compare, and reset
  - What is the initial value? (0 or 1?)
  - What is the compare operator? (> or >=? < or <=?)
  - What happens at reset vs. at state transition?

□ Every state machine: STOP and error in EVERY state
  - Can a STOP condition arrive in any state? Does every state handle it?
  - Can a repeated START arrive in any state? Does every state handle it?
  - Is there a default case? What does it do?

□ Every test hook: verify it does not affect normal operation
  - When the hook input is de-asserted (0), does the DUT behave normally?
  - Is the hook input properly guarded by active_int or similar?

□ Every assertion: apply the tautology test
  - Does the consequent contain any condition already in the antecedent?
  - If yes — rewrite the consequent to check something the DUT must DO

□ Every coverage point: verify the signal relates to the goal
  - Read the comment describing what the coverpoint measures
  - Confirm the measured signal actually represents that concept
  - Ask: "Can this reach 100% even if the feature is broken?"
```

---

### Applying the Checklist: Which Bugs It Would Have Caught

Walk through the checklist and see which of the 15 bugs it catches IN CODE
REVIEW, before any simulation is run.

**"Every shift register: check the capture event"**

Applying this to `i2c_slave_controller.sv` in the original code:

The shift register shifts on every `scl_rise`. Ask: "Does this include
the ACK clock?" Count the SCL pulses: 8 data bits + 1 ACK = 9. The shift
register shifts on ALL 9. The latch captures after the 9th shift. The ACK
bit is in bit 0. This is Bug #1 — found in code review.

**"Every always_ff: does next_state appear in more than one block?"**

Applying this to the original `i2c_master_controller.sv`:

Scan for `next_state <=` in `always_ff` blocks. Find one in the sequential
block. Scan for `next_state =` in `always_comb` blocks. Find another.
Two drivers. This is Bug #8 — found in code review.

**"Every state machine: check STOP/error in EVERY state"**

Applying this to `SLV_TX_ACK` in the original slave controller:

Check: does `SLV_TX_ACK` look at `sda_i` to determine ACK vs NACK? Original
code: no, it always transitions to `SLV_TX`. Protocol says: the master drives
SDA during this clock, HIGH = NACK. Missing check. This is Bug #4 — found
in code review.

**"Every test hook: verify normal operation unaffected"**

Applying this to `SLV_RX_ACK` before `force_data_nack` was added:

Ask: "Is there any way to make the slave send a data NACK?" No. The ACK
is hardwired. This is Bug #6 — the missing test hook — found in code review.

**"Every assertion: apply the tautology test"**

Applying this to A1 assertion `(scl_samp == 1'b1 && sda_fall) |-> (scl_samp == 1'b1)`:

Consequent = `scl_samp == 1'b1`. Antecedent includes `scl_samp == 1'b1`.
Consequent is a subset of antecedent. Tautology. This is Bug #11 — found
in code review.

Applying this to A2 assertion `(scl_samp == 1'b1 && sda_rise) |-> (scl_samp == 1'b1 && sda_samp == 1'b1)`:

`sda_rise` is defined as the rising edge of SDA, so `sda_samp == 1'b1` is
implied by the antecedent. `scl_samp == 1'b1` is in the antecedent directly.
Both consequent conditions are in the antecedent. Tautology. Bug #12 — found
in code review.

**"Every coverage point: verify the signal relates to the goal"**

Applying this to `i2c_reg_ptr_cg`:

Comment says "Register Access". Signal measured: `item.data[0]`. Ask: does
the first data byte value (0-255) represent which register is being accessed?
No — register access is determined by address and byte count, not data value.
This is Bug #13 — found in code review.

**"Every counter: check initialization, compare, and reset"**

Applying this to the stretch timer:

Initial value: 0. Compare: `>= stretch_cycles`. Manually simulate 1 cycle:
timer starts at 0, increments to 1 on cycle 1. At cycle N, timer = N. Check
`N >= stretch_cycles` fires when timer = stretch_cycles, which is after
stretch_cycles+1 cycles (0 → 1 → ... → stretch_cycles). Off by one.
This is Bug #14 — found in code review.

**"Every state machine: dead code check"**

Applying this to `SLV_IDLE` case with the outer `if (start_cond)` guard:

Ask: "Can `start_cond` be true inside the case block?" The case block is
inside an `else` branch that requires `start_cond == 0`. So no — the inner
check is dead. This is Bug #15 — found in code review.

---

### The Summary: 7 Bugs That Code Review Would Have Caught

Bugs #1, #4, #6, #8, #11, #12, #13, #14, #15 — nine of the fifteen bugs
in this project — are directly catchable by the code review checklist above.
No simulation required. No waveform. Just reading the code carefully with
the right questions in mind.

This is why code review is not bureaucracy. It is engineering.

---

## Part 9: Writing a Bug Report — What Makes a Good One

A bug report is a communication tool. It tells the person reading it:
- What is wrong
- Why it is wrong
- How to reproduce it
- How it was fixed
- How to verify the fix

A bad bug report wastes everyone's time. A good bug report is self-contained.

---

### Bad Bug Report vs. Good Bug Report

**Bad:**
```
Test fails. SDA is wrong after read transaction.
```

This tells you nothing. Which test? When does SDA go wrong? Wrong how?
What was expected? This report cannot be reproduced, triaged, or assigned.

**Good — using Bug #10 as the example:**

```
Title: reg_data_buf never updated after RX — CPU reads 0x00 instead of received byte

Severity: Critical
Affected tests: write_read_test, burst_read_test (all read transaction tests)
Reproducer: Run write_read_test with +ntb_random_seed=0 — fails 100% of the time

Symptom:
  After a read transaction completes, the CPU reads REG_DATA (address 0x02)
  and receives 0x00 instead of the byte that was received from the I2C bus.
  This occurs on EVERY read transaction regardless of the data written.
  Example: master writes 0xA5 to slave, then reads back — scoreboard reports
  expected 0xA5, got 0x00.

Root Cause:
  Signal trace: cpu_rdata ← reg_data_buf ← [MISSING LINK] ← shift_reg
  
  The shift_reg is correctly assembled during STATE_RX_BIT. On each SCL
  rising edge, shift_reg shifts in sda_i: shift_reg <= {shift_reg[6:0], sda_i}.
  After 8 SCL pulses, shift_reg contains the correct received byte.
  
  However, reg_data_buf is only updated by the CPU write path:
    if (cpu_wr && cpu_addr == REG_DATA) reg_data_buf <= cpu_wdata;
  
  There is no code path that writes reg_data_buf from shift_reg after an
  RX transaction completes. The link from shift_reg to reg_data_buf was
  missing entirely. reg_data_buf stays at its reset value (0x00) for
  the lifetime of the simulation.

Fix Applied:
  In the host interface always_ff block, added:
    if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND) begin
      reg_data_buf <= shift_reg;
    end
  
  This fires exactly once per received byte — at the transition from
  STATE_RX_BIT to STATE_ACK_SEND (after all 8 bits are received, before
  the master sends ACK/NACK). The timing ensures the complete byte is
  captured before any further state transitions.

Verification:
  write_read_test passes: scoreboard confirms cpu_rdata == expected_data
  burst_read_test passes: all 8 bytes in a burst read correctly returned
  Added explicit scoreboard check comparing cpu_rdata to the byte that
  was transmitted by the master — check fires correctly on mismatch.
```

---

### The Anatomy of a Good Bug Report

Every field in the template above serves a purpose:

**Title:** One sentence that describes the problem precisely. Must be specific
enough that someone reading only the title understands what is broken.
"SDA is wrong" is not a title. "reg_data_buf never updated after RX" is a title.

**Severity:** Tells the reader how urgent this is. Critical means the entire
feature is broken. Major means an important path is broken. Minor means edge
cases are affected. Feature means the DUT works but testability is limited.

**Affected tests:** Tells the reader the scope. If 2 tests fail — targeted
regression is easy. If 20 tests fail — something fundamental is broken.

**Reproducer:** The exact command or seed that makes the bug appear 100% of
the time. Without this, the reader cannot verify the bug or verify the fix.

**Symptom:** What the user (test, scoreboard, assertion) observes. This is
NOT the root cause — it is the observable failure. Described in concrete,
measurable terms: signal name, expected value, actual value, simulation time.

**Root Cause:** The chain of logic from the symptom back to the first wrong
thing. Written as a signal trace when possible. Shows the reader that the
author understands WHY the bug exists, not just that it exists.

**Fix:** Exactly what was changed and why. Include the code. Explain the
timing of when it fires. If the fix has any subtlety (like the `&&
next_state == STATE_ACK_SEND` condition), explain it.

**Verification:** How you confirmed the fix works. Not just "tests pass" —
name the specific tests and what they check. If you added a new scoreboard
check, describe it.

---

## Part 10: Debugging with Assertions — The Feedback Loop

Assertions are not just a verification checklist item. They are a debugging
acceleration tool. Used correctly, they cut debug time by 10x or more.

---

### The Difference Assertions Make

**Without assertions:**

A simulation runs for 10,000 cycles. A full I2C write-read burst transaction
completes. The scoreboard compares the final read data to the written data and
reports a mismatch at cycle 10,000. You know the output is wrong. You have
no idea when it first went wrong. You have to open the 10,000-cycle waveform
and work backward — potentially thousands of cycles.

**With assertions:**

The A3 assertion checks that SDA is stable whenever SCL is high. If anything
causes SDA to change while SCL is high — the assertion fires immediately, at
the exact clock cycle where the violation occurs. You get:

```
ERROR: [I2C-SVA-A3] SDA changed while SCL high at time 354ns
```

You go to time 354ns in the waveform. You see exactly what SDA was doing and
what caused it to change. Debug time: 10 minutes instead of 3 days.

---

### How A3 Would Have Caught Bug #1 Immediately

Bug #1 is: the shift register captures the ACK bit as the 8th data bit.

The root cause is that the shift register shifts on the 9th SCL rising edge
(the ACK clock) just like it shifts on data clocks 1-8.

What does this look like in terms of SDA behavior?

During the ACK clock (9th SCL pulse):
- SCL goes HIGH
- The slave releases SDA (to let the master drive ACK/NACK)
- SDA was LOW (last data bit driven by master) and transitions to HIGH or Z

SDA CHANGED while SCL was HIGH. That is exactly what A3 checks.

If A3 were present and correctly written, it would fire at the ACK clock,
at the exact moment the problematic SDA transition occurred. The assertion
message would point you directly to cycle 9 of every transaction — the ACK
clock — and the investigation would take minutes instead of hours.

Without A3, the bug only manifests as a data mismatch in the scoreboard at
the end of the transaction, potentially hundreds of cycles after the root cause.

**Lesson:** Write assertions BEFORE you write tests. They are free debugging.
Every cycle you spend writing an assertion at the start of the project saves
ten cycles of debugging later.

---

### The Assertion-First Development Approach

The correct order of work in a DV project:

```
1. Write RTL (or receive RTL for review)
2. Write SVA assertions for every protocol invariant
3. Write tests
4. Run tests — assertions fire immediately when invariants are violated
5. Debug with the assertion's fire time as the starting point
```

Most engineers do steps 3-5 without step 2. Then when tests fail, they have
no early indication of where the problem is. Adding assertions after a test
fails is too late — you are debugging backward.

The I2C protocol has clear, finite invariants that can be written as assertions:

```
A1: After START, SCL must fall within T_HD_STA + T_SCL_PERIOD
A2: After STOP, bus must remain free for T_BUF cycles
A3: SDA must not change while SCL is high (data stability)
A4: On the 9th SCL pulse (ACK), sda_o from the slave should reflect ACK/NACK
A5: After address ACK, the FSM must not stay in IDLE
A6: The stretch timer must deactivate within stretch_cycles + 1 cycles
```

Each of these catches a specific class of bug, immediately, at the exact
moment of violation.

---

## Part 11: The Senior Engineer's Self-Review Checklist

Before submitting any RTL code for review, a senior engineer reviews their
own code against this checklist. The goal is to catch your own bugs before
anyone else sees them. Every item on this list corresponds to a bug class
that has appeared in real silicon or real tapeouts.

---

### For Every New Signal

```
□ Is it reset? To what value?
  Ask: if rst_n asserts for one cycle at t=0 and deasserts,
  what is the signal's value at t=1? Is that value safe?
  An uninitialized signal in simulation may show X.
  An uninitialized signal in silicon may hold any value —
  and that value may corrupt your state machine immediately.

□ Is it written in exactly ONE always block?
  Search for all "<= signal_name" and "= signal_name" on the LEFT side.
  Count the always blocks that contain these. If count > 1 — multi-driver.
  Bug #8 in this project is exactly this error.

□ Is it read in a way that respects timing?
  If signal A is written in always_ff block X, and signal B reads signal A
  in the same always_ff block X — does B see the NEW value (combinational
  read-after-write) or the OLD value (registered)?
  In always_ff, the old value is read. The new value appears at the NEXT
  clock edge. This is the source of "pipeline delay" bugs.
```

---

### For Every New State Machine State

```
□ Is there a valid transition for EVERY possible input combination?
  List all asynchronous conditions that can arrive in any state:
  - start_cond (asynchronous, master-driven)
  - stop_cond (asynchronous, master-driven)
  - timeout (asynchronous, counter-driven)
  - bus_error (asynchronous)
  Does EVERY state have an explicit or default handler for each of these?
  In this project, many original states had no handler for stop_cond —
  which means a STOP in the wrong state would leave the FSM stuck.

□ Can the state machine get stuck in this state?
  Ask: "If I enter this state and hold all inputs constant, will I ever
  leave?" If the exit condition depends on an external event (scl_fall,
  timer_expired, sda_i change) — what if that event never comes?
  A robust FSM has a timeout escape from every "waiting" state.

□ Is the state reachable?
  After writing the state, identify exactly which transitions lead to it.
  If no transition leads to it (or all transitions to it are inside dead
  code paths), the state is unreachable. Run code coverage to confirm.
```

---

### For Every New Counter or Timer

```
□ What is the initial value?
  0 or 1? The choice determines whether a "count to N" comparison with
  ">= N" fires after N or N+1 cycles. Decide consciously, not by default.
  The standard pattern: start at 0, compare "> N-1" (equivalent to ">= N").
  The alternative: start at 1, compare ">= N". Both are correct. Both are
  common. Mixing them produces Bug #14.

□ What is the terminal condition?
  Write it out explicitly: "timer should fire after exactly N cycles."
  Then verify: "timer starts at value X. Compare is OP against Y.
  It fires at cycle X + (Y - X) via the OP relation." Match this to N.
  If it does not match — the counter is wrong.

□ What happens if it wraps?
  Saturating counter: stops at max value (safe — compare always true)
  Rolling counter: wraps to 0 and continues (dangerous — compare may
  not fire if the expected value is skipped in the wrap)
  For timing-critical counters, use saturating arithmetic or add a check
  for the wrap case.
```

---

### For Every New Assertion

```
□ Apply the antecedent. Does the consequent HAVE to be true?
  This is the tautology test from Part 3. Write the antecedent conditions
  on a piece of paper. Then check every term in the consequent: is it
  already guaranteed by the antecedent? If every consequent term is
  guaranteed by the antecedent — tautology. Rewrite the consequent.

□ Can I write a simulation that fails this assertion?
  This is assertion validation. After writing an assertion, think of the
  DUT behavior that would VIOLATE it. Then write a test (or a directed
  stimulus) that produces that behavior. Run the simulation. If the
  assertion fires — it is working. If it does not fire — either your
  test did not produce the violation, or the assertion is wrong.
  Do not skip this step. It is the only way to know your assertion works.

□ Is the timing window correct?
  Same-cycle implication (|->): consequent must be true in the SAME cycle
  as the antecedent. Use this for combinational relationships.
  Non-overlapping (|=>): consequent must be true in the NEXT cycle.
  Use this for registered outputs.
  Ranged delay (##[1:N]): consequent must be true within N cycles.
  Use this for timing bounds (bus setup, hold times, stretches).
  The wrong timing operator makes a correct-looking assertion fire at the
  wrong time — or never fire.
```

---

### The Complete Self-Review Ritual

Before you commit any RTL:

```
1. For every signal in the diff:
   - Grep for all writers
   - Confirm reset value
   - Confirm single-block ownership

2. For every state added or modified:
   - Trace every input that can arrive
   - Confirm the transition for each input
   - Confirm no states are unreachable

3. For every counter added or modified:
   - Write out: start value, terminal condition, expected cycle count
   - Manually simulate 3 cycles and the terminal cycle

4. For every assertion added:
   - Apply the tautology test
   - Describe the simulation that would fail it

5. Run the reduced reproducer test before committing:
   - If you have a known bug's reproducer — confirm it still passes
   - If you are adding a new feature — confirm a basic test passes
```

This ritual takes 15-30 minutes for a typical RTL change. It saves days.

---

*This file is part of the I2C Protocol DV learning series. Next: 08_INTERVIEW_QUESTIONS.md*
