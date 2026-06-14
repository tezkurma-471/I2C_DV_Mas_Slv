> **⚠️ 2026-06-10 AUDIT UPDATE — read this box before trusting the lesson below.**
> A deep audit + fix pass changed the code this walkthrough describes. Deltas for this file:
> - New `STATE_BYTE_HOLD`: after every ACKed byte the master now HOLDS SCL low and waits for the next CPU command. The old ACK→IDLE path released the bus mid-transaction (implicit STOP) — multi-byte writes were impossible.
> - STOP is now 3-phase (STOP_1/2/3) and repeated START falls SDA while SCL is already high — the old code toggled both lines on the same edge, so Sr literally never appeared on the wire (found by the new `make smoke` test).
> - SCL/SDA inputs go through 2-flop synchronizers; the arbitration check compares a 2-cycle-DELAYED copy of sda_o against the synced input.
> - The bit timer FREEZES while `scl_o==1 && scl_i==0` (slave stretching) — previously a stretching slave made ACK_WAIT time out and read as NACK.
> - `stretch_cnt` counts only slave-held-low cycles; IDLE only accepts CMD_START; REG_DATA writes can no longer clobber the shifter mid-byte.
> Full detail: [`19_audit_fixes_walkthrough.md`](./19_audit_fixes_walkthrough.md) and `docs/AUDIT_FIX_REPORT.md`.

# Lesson 03 — `i2c_master_controller.sv` Deep Dive

**File under study:** `rtl/i2c_master_controller.sv` (566 lines)
**Concepts covered:** Two-process FSM coding style, always_ff vs always_comb, open-drain bus modelling, clock dividers, shift registers (MSB-first), edge detection, clock stretching, arbitration loss, APB-like CSR map, sticky status flags, BUG #10 root cause
**Date:** 2026-05-17
**Status:** This is the BEATING HEART of the master design. If you understand this file, you understand 70% of any I2C/SPI/UART master controller you'll ever read.

---

## Table of Contents

1. [Where the Master Controller Fits — Architectural View](#1-where-the-master-controller-fits--architectural-view)
2. [The 60-Second Elevator Pitch](#2-the-60-second-elevator-pitch)
3. [CPU-Side Interface — APB-like CSR Walkthrough](#3-cpu-side-interface--apb-like-csr-walkthrough)
4. [SCL Generation — Clock Divider Deep Dive](#4-scl-generation--clock-divider-deep-dive)
5. [Main FSM — State-by-State Deep Dive](#5-main-fsm--state-by-state-deep-dive)
6. [SDA Driving Logic — When to Pull, When to Release](#6-sda-driving-logic--when-to-pull-when-to-release)
7. [Clock Stretching Detection](#7-clock-stretching-detection)
8. [Timeout & Error Handling](#8-timeout--error-handling)
9. [Shift Register & Data Buffer — BUG #10 Deep Explanation](#9-shift-register--data-buffer--bug-10-deep-explanation)
10. [Arbitration Loss Detection (T13)](#10-arbitration-loss-detection-t13)
11. [Reset & Initialization Behavior](#11-reset--initialization-behavior)
12. [Status & Interrupt Logic](#12-status--interrupt-logic)
13. [Quiz — 20 Questions](#13-quiz--20-questions)
14. [Quiz Answers — Senior-Engineer Grade](#14-quiz-answers--senior-engineer-grade)
15. [Key Takeaways](#15-key-takeaways)
16. [Action Items](#16-action-items)
17. [Honest Self-Score Template](#17-honest-self-score-template)

---

## 1. Where the Master Controller Fits — Architectural View

The master controller is the **brain** of the I2C master IP. The thin `i2c_master.sv` wrapper
just passes pins through; this file decides *when* to pull SDA low, *when* to toggle SCL,
and *what* to put on the bus.

```
+--------------------------------------------------------------+
|                    HOST CPU (e.g. Cortex-M)                  |
|     writes REG_CMD = CMD_START / CMD_WRITE / CMD_STOP...     |
+----------------------+---------------------------------------+
                       | APB-like 8-bit register bus
                       | cpu_addr[2:0], cpu_wr, cpu_wdata[7:0]
                       v
+--------------------------------------------------------------+
|              i2c_master_controller.sv  (this file)            |
|                                                              |
|  +-----------+   +----------+   +-----------+   +---------+  |
|  | CSR Block | → | Main FSM | → | Shift Reg | → | IO Pads |  |
|  | (regs)    |   | (11-st)  |   | (8-bit)   |   |open-dr.|   |
|  +-----------+   +----------+   +-----------+   +---------+  |
|        ↑              ↑              ↑              |       |
|        |              |              |              v       |
|        |        +----------+   +----------+    SDA / SCL    |
|        |        | Timer /  |   | Edge     |    (wired-AND)  |
|        |        | SCL Gen  |   | Detector |                 |
|        |        +----------+   +----------+                 |
+--------------------------------------------------------------+
                       |
                       v SDA, SCL (open-drain, pulled up to VDD)
                +------------------+
                | I2C SLAVE DUT    |  ← The actual thing being verified
                |   addr 7'h50     |
                +------------------+
```

### ASCII FSM Diagram (11 States)

```
                   cmd_valid=CMD_START
       +---------------------------------------+
       |                                       v
       |    +----------+ timer    +----------+ timer    +-----------+
       |    | START_1  |--------->| START_2  |--------->|  TX_BIT   |<--+
       |    +----------+          +----------+          +-----------+   |
       |        ^                                          |bit_cnt<7   |
       |        |                                          |timer       |
       |        |    cmd_valid=CMD_REP_START              +------------+
       |        |    +------------+ timer  +------------+ |
       |        +----| REP_START_1|------->| REP_START_2|<+
       |             +------------+        +------------+ bit_cnt==7
       |                                                  |
       |        cmd_valid=                                v
       |        CMD_READ_*    +----------+ bit<7   +-----------+
       |        +------------>|  RX_BIT  |-------->| ACK_WAIT  |
       |        |             +----------+         +-----------+
+----------+    |                  | bit==7             |
|   IDLE   |----+                  v                    | ACK -> IDLE
|          |               +------------+               | NACK-> STOP_1
+----------+               |  ACK_SEND  |--------+      |
   ^   ^                   +------------+        |      v
   |   |                                         |   +----------+
   |   |  cmd_valid=CMD_STOP                     |   |  STOP_1  |
   |   +-----------------------------------------+   +----------+
   |                                                      | timer
   |   timeout / arb_lost (escape hatch)                  v
   +<-------------------------------------+         +----------+
                                          |         |  STOP_2  |
                                          +<--------+----------+
                                                       timer
```

**Note the structural trick:** every "two-phase" primitive (START, STOP, REP_START) uses two
states (`_1` and `_2`) so the FSM can express **"hold this bus configuration for one SCL
half-period, then change."** This is a common embedded-protocol coding pattern — when timing
requires *"setup, hold, then transition,"* split into two states.

---

## 2. The 60-Second Elevator Pitch

When the NVIDIA/Qualcomm/Intel interviewer says *"Walk me through the master controller,"* **say this:**

> *"The master controller is an 11-state finite state machine that generates I2C bus primitives —
> START, STOP, byte transmit, byte receive, ACK, NACK, and repeated START. It exposes an APB-like
> register interface to the host CPU with seven registers: CTRL, CMD, STATUS, DATA, ADDR, IRQ_EN,
> IRQ_ST. The CPU writes a 4-bit command into REG_CMD, which generates a one-cycle `cmd_valid`
> pulse that triggers the FSM out of IDLE. The FSM drives open-drain SDA and SCL by asserting LOW
> through tri-state buffers and releasing to high-Z for HIGH. SCL is generated by a free-running
> clock divider with T_SCL_PERIOD = 500 system clocks for 100 kHz Standard Mode at 50 MHz clock.
> The design uses a two-process FSM coding style — one `always_ff` for state register and outputs,
> one `always_comb` for next-state logic — which is industry-standard practice. It also has
> arbitration loss detection, clock stretch timeout, and a sticky ACK/NACK status flag. During
> verification I found 15 bugs, including a critical one — BUG #10 — where the received data byte
> was never copied from the internal shift register to the CPU-visible REG_DATA register, so the
> CPU always saw 0x00 on reads."*

Memorize the **shape**, not the words.

---

## 3. CPU-Side Interface — APB-like CSR Walkthrough

### The Port List (lines 13-37)

```systemverilog
input  logic [2:0]  cpu_addr;     // 8-register address space
input  logic        cpu_wr;       // 1 = write, 0 = read
input  logic [7:0]  cpu_wdata;
output logic [7:0]  cpu_rdata;
output logic        cpu_irq;
```

**Why this is "APB-like" and not real APB:** Real APB has `psel`, `penable`, `pready`, `pslverr`,
two-phase setup/access cycles. This is a simplified single-cycle write/read interface — basically
a memory-mapped register file with no flow control.

**Interview-grade answer:**

> *"The CPU-side interface is APB-like in spirit — a memory-mapped 8-bit register file with a
> 3-bit address space — but lacks the formal APB handshake signals (psel/penable/pready). A
> production-grade IP would wrap this in a proper APB or AXI4-Lite slave bridge so it integrates
> cleanly into an SoC fabric."*

### The Write Logic (lines 133-167)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    reg_data_buf <= 8'h00;
    reg_addr     <= 8'h00;
    ...
    cmd_valid    <= 1'b0;
  end else begin
    if (cpu_wr) begin
      case (cpu_addr)
        REG_DATA:    reg_data_buf <= cpu_wdata;
        REG_ADDR:    reg_addr     <= cpu_wdata;
        REG_CTRL:    reg_ctrl     <= cpu_wdata;
        REG_CMD:     reg_cmd      <= cpu_wdata;
        REG_IRQ_EN:  reg_irq_en   <= cpu_wdata;
        default:     ;
      endcase
    end

    // FIX BUG #10
    if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND) begin
      reg_data_buf <= shift_reg;
    end

    if (cpu_wr && (cpu_addr == REG_CMD)) begin
      cmd_valid <= 1'b1;
    end else begin
      cmd_valid <= 1'b0;
    end
  end
end
```

#### Three Things Happening in One always_ff Block

| Behavior | Lines | Purpose |
|---|---|---|
| 1. CPU register write decode | 142-151 | Standard write-to-register mux |
| 2. RX→ACK data capture (BUG #10 fix) | 156-158 | Forwards shift_reg into CPU-visible REG_DATA |
| 3. cmd_valid pulse generation | 161-165 | One-cycle strobe when REG_CMD is written |

**Interview trap:** The interviewer asks: *"In your write block you have both a CPU write to
REG_DATA AND a BUG #10 path that also writes reg_data_buf. What if they collide in the same
cycle?"*

**Correct answer:** The BUG #10 path is **below** the CPU case statement → in non-blocking
assignment semantics, the **last write in the same block wins**. So if the CPU were to write
REG_DATA during the exact cycle of an RX→ACK transition, the BUG #10 fix would clobber it.

**Is that a real bug?** No — because the CPU should never write REG_DATA during a transaction;
the FSM is using it. This is a "thou shalt not poke me while I'm busy" software contract.
But a defensive design would gate the CPU write with `state == STATE_IDLE`.

> ⚠️ **Add to your "future improvements" list:** Gate `cpu_wr` to read-only registers when
> `busy` is asserted, to make the IP robust against misbehaving software.

### cmd_valid — Edge or Level?

```systemverilog
if (cpu_wr && (cpu_addr == REG_CMD)) begin
  cmd_valid <= 1'b1;
end else begin
  cmd_valid <= 1'b0;
end
```

This generates a **one-cycle pulse** synchronous to the clock — `cmd_valid` is HIGH only on
the cycle after `cpu_wr=1` to REG_CMD. It is **not** an edge of `reg_cmd` itself.

**Why this matters:** If the FSM used `reg_cmd != CMD_NOP` (level) as its trigger, then after
the first command, `reg_cmd` would still hold (say) `CMD_START`, and the FSM would re-enter
STATE_START forever. The pulse-trigger gives the FSM a clean one-shot.

**Interview-grade answer:**

> *"The FSM is triggered by a one-cycle `cmd_valid` strobe asserted when the CPU writes
> REG_CMD. The command itself stays latched in `reg_cmd` so the FSM can read it across multiple
> cycles, but the strobe ensures each CPU write triggers exactly one FSM transaction. This is a
> standard 'fire-and-forget' command interface."*

### The Read Mux (lines 170-180)

```systemverilog
always_comb begin
  case (cpu_addr)
    REG_CTRL:   cpu_rdata = reg_ctrl;
    REG_STATUS: cpu_rdata = reg_status;
    REG_DATA:   cpu_rdata = reg_data_buf;
    REG_ADDR:   cpu_rdata = reg_addr;
    REG_IRQ_EN: cpu_rdata = reg_irq_en;
    REG_IRQ_ST: cpu_rdata = reg_status;  // ← interesting!
    default:    cpu_rdata = 8'h00;
  endcase
end
```

**Spot the quirk:** `REG_STATUS` and `REG_IRQ_ST` both read `reg_status`. The intent was
probably for `REG_IRQ_ST` to be a separate latched interrupt-status register, but it's been
shortcut to the same source. **A real chip would have a separate IRQ status register that
the CPU clears by writing 1 to bits — a common "W1C" (write-1-to-clear) pattern.**

> ⚠️ **Interview trap:** *"Walk me through how interrupts are cleared in your design."*
> Honest answer: *"They aren't cleared explicitly — the design reads back the live status. A
> production-grade design would have a W1C interrupt status register so the CPU can acknowledge
> and clear pending interrupts atomically."*

### Enum Cast (line 183)

```systemverilog
assign current_cmd = i2c_cmd_e'(reg_cmd[3:0]);
```

**What's happening:** `reg_cmd` is `logic [7:0]` but the command enum is 4 bits. We slice the
lower 4 bits and **cast** them to the enum type with `i2c_cmd_e'(...)`.

**Synthesis implication:** Casts to enum are zero-cost — they're just type-system bookkeeping.
The 8-to-4 truncation **drops** the upper 4 bits of `reg_cmd`. These could be used in future for
flags (burst-length, IRQ-on-done, etc.) — see Lesson 01 Q3.

**Interview gotcha:** *"What happens if I write `CMD_RESERVED = 4'hF` into REG_CMD — a value not
in the enum?"* Answer: The cast succeeds (SV does not error on out-of-range enum casts; it just
holds the raw bits), and the case statement in next_state hits the `default:` arm → FSM stays
in IDLE. **This is safe-by-default behavior**, but a paranoid design would assert in this case.

---

## 4. SCL Generation — Clock Divider Deep Dive

This is the most-asked area in I2C interviews. Internalize it.

### The Math (recap from Lesson 01)

| Quantity | Value | Source |
|---|---|---|
| System clock | 50 MHz (20 ns period) | Project-wide param `CLK_FREQ_MHZ` |
| Target SCL | 100 kHz (10 µs period) | I2C Standard Mode (NXP UM10204) |
| Ticks per SCL period | 10 µs / 20 ns = **500** | `T_SCL_PERIOD` |
| Ticks per SCL half | **250** | `T_SCL_HIGH`, `T_SCL_LOW` |

### The Timer (lines 190-208)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    timer         <= '0;
    timer_expired <= 1'b0;
  end else if (timer_clr) begin
    timer         <= '0;
    timer_expired <= 1'b0;
  end else begin
    if (timer == T_SCL_PERIOD - 1) begin
      timer         <= '0;
      timer_expired <= 1'b1;
    end else begin
      timer         <= timer + 1'b1;
      timer_expired <= 1'b0;
    end
  end
end

assign timer_clr = (state != next_state);
```

#### Anatomy

- **`timer`** — a free-running counter from 0 to T_SCL_PERIOD-1 (499 in our case), 9 bits wide
  via `$clog2(T_SCL_PERIOD)`.
- **`timer_expired`** — registered pulse for one cycle when timer wraps. **This is the FSM's
  "tick" signal** — every state advancement is gated on `timer_done` (= `timer_expired`).
- **`timer_clr`** — auto-cleared on **any** state transition. Combinational from `(state != next_state)`.

**Why auto-clear on state change?** When the FSM enters a new state, you want the SCL window to
start at t=0 from the new state's perspective. Otherwise a state lasting only 50 ticks would
leave the timer at 50 going into the next state, throwing off SCL timing.

**Critical-path question (interview):** Is `timer_clr` combinational from `state != next_state`?
**Yes** — and that means the timer's reset path has the FSM's combinational depth in it. On
a small design at 50 MHz this is fine. At 1 GHz it would need a registered version.

### SCL Driving (lines 229-265)

```systemverilog
case (state)
  STATE_IDLE:         scl_o <= 1'b1;          // Released = HIGH
  STATE_START_1:      scl_o <= 1'b1;          // SCL still HIGH while SDA falls
  STATE_START_2:      scl_o <= 1'b0;          // SCL drops AFTER START
  STATE_TX_BIT: begin
    if (timer < T_SCL_LOW)                  scl_o <= 1'b0;  // setup window
    else if (timer < T_SCL_LOW + T_SCL_HIGH) scl_o <= 1'b1;  // sample window
    else                                     scl_o <= 1'b0;
  end
  ...
endcase
```

#### The Three Phases of an SCL Cycle

```
timer:       0          T_SCL_LOW=250         T_SCL_LOW+T_SCL_HIGH=500
             |               |                          |
             v               v                          v
SCL:    LOW (setup) | HIGH (sample) | (residual LOW until state exits)
SDA:    [bit valid here, master changes during LOW, slave samples during HIGH]
```

**The three phases:**
1. **SCL LOW (setup window):** master may change SDA. Bit must be stable by end of this phase.
2. **SCL HIGH (sample window):** slave samples SDA. Master MUST NOT change SDA here, or you've
   generated a stray START/STOP.
3. **Residual LOW:** brief tail until the FSM advances to the next bit / state.

**Interview gotcha:** *"What's t_HD;DAT (data hold time) in your design?"* Answer: It's the time
between SCL falling and SDA changing — in our FSM, SDA is registered to the **next** state
transition's clock edge, so t_HD;DAT ≈ 0 within one system clock (20 ns). The I2C spec
requires t_HD;DAT ≥ 0 (no minimum hold for Standard Mode receiver), so we're spec-compliant.

### Senior-Engineer Thought Process: Why a Free-Running Timer Instead of Per-State Counters?

You could have written separate counters per state (`start_cnt`, `tx_cnt`, ...) but that's
wasteful. The free-running timer is shared across all states and reset on transitions. This
saves area and gives a uniform timing primitive across the FSM.

**Trade-off:** All states must complete within T_SCL_PERIOD ticks. If you ever wanted a state
that lasts longer than one SCL period, you'd need a separate cycle counter. The current design
is fine because every state IS one SCL phase or less.

---

## 5. Main FSM — State-by-State Deep Dive

### Coding Style: Two-Process FSM

This file uses the **textbook two-process FSM coding style:**

| Block | Type | Purpose | Lines |
|---|---|---|---|
| `state <= next_state` | `always_ff` | State register + output flops | 327-361 |
| `next_state = ...` | `always_comb` | Pure combinational next-state | 367-481 |

**Why two-process is standard:**
1. **Lint clean** — `always_ff` enforces flop semantics; `always_comb` enforces full assignment
   (no latches). Tools like Spyglass and Verilator flag violations.
2. **Synthesis predictable** — the synthesizer knows exactly which signals are flopped vs
   combinational. No guessing about implicit storage.
3. **Reviewable** — combinational next-state is one block you can stare at to understand
   transitions, separate from the timing/reset behavior.

**One-process style (single `always_ff` driving both state and next-state) is older Verilog
practice and discouraged in modern SystemVerilog RTL.** Mentor Graphics, Synopsys, and most
companies' RTL coding guides explicitly recommend two-process.

**Interview-grade answer:**

> *"The FSM is implemented in the two-process coding style — one `always_ff` block for the state
> register and registered outputs, one `always_comb` block for pure combinational next-state
> logic. This is the industry-standard style. It produces predictable synthesis, is lint-clean,
> and separates the 'what state am I in' question from the 'what state should I go to' question.
> An alternative three-process style further separates output decoding, but I find two-process
> is the right balance for protocol FSMs of this size."*

### STATE_IDLE (lines 379-393)

```systemverilog
STATE_IDLE: begin
  if (cmd_valid) begin
    case (current_cmd)
      CMD_START:    next_state = STATE_START_1;
      CMD_WRITE:    next_state = STATE_TX_BIT;
      CMD_READ_ACK: next_state = STATE_RX_BIT;
      CMD_READ_NACK:next_state = STATE_RX_BIT;
      CMD_STOP:     next_state = STATE_STOP_1;
      CMD_REP_START:next_state = STATE_REP_START_1;
      default:      next_state = STATE_IDLE;
    endcase
  end else begin
    next_state = STATE_IDLE;
  end
end
```

**What's interesting:**
- `CMD_READ_ACK` and `CMD_READ_NACK` both go to `STATE_RX_BIT`. The differentiation happens
  later — in `STATE_ACK_SEND`, where `current_cmd` is inspected to decide ACK vs NACK output.
- `CMD_NOP` and `CMD_ABORT` are NOT handled — they hit the `default` arm and stay in IDLE.
  CMD_NOP doing nothing is correct. CMD_ABORT being a silent no-op **is a bug worth flagging:**
  if the CPU issues CMD_ABORT during a transaction, the FSM should jump to STATE_STOP_1.

> ⚠️ **Bug-hunt finding:** `CMD_ABORT` is declared in the enum but unimplemented in the FSM.
> This is a feature gap — the spec promises CMD_ABORT but the design ignores it. Document or
> implement.

### STATE_START_1 → STATE_START_2 (lines 398-399)

```systemverilog
STATE_START_1: next_state = timer_done ? STATE_START_2 : STATE_START_1;
STATE_START_2: next_state = timer_done ? STATE_TX_BIT  : STATE_START_2;
```

**Why two states for one START?**

The I2C START condition is **"SDA falls while SCL is HIGH"**:

```
SDA: --------\___________
SCL: ---------------\_____
              ^      ^
              t=t0   t=t0 + T_SU;STA
              SDA falls  SCL falls (now in LOW phase for bit 1)
```

- **STATE_START_1:** SCL = 1, SDA = 0 → the falling edge of SDA happened here. Hold this for
  one SCL period to satisfy setup time T_SU;STA.
- **STATE_START_2:** SCL = 0, SDA = 0 → pull SCL low. Hold for hold time T_HD;STA.
- After STATE_START_2 → jump to STATE_TX_BIT (slave address byte is transmitted).

**Interview gotcha:** *"What's the difference between START_1 and START_2 timing-wise?"*

Answer: STATE_START_1 enforces **setup time T_SU;STA** (SDA must be low for ≥ 4.7 µs before
SCL falls in Standard Mode). STATE_START_2 enforces **hold time T_HD;STA** (≥ 4 µs in Standard
Mode). In this design both states wait T_SCL_PERIOD (10 µs), which **exceeds** spec — safe but
slightly wasteful.

**Note transition into STATE_START_2:** SDA is already 0 (from STATE_START_1), so the only
output change is SCL going from 1→0. This is the actual START condition signaling complete.

### STATE_TX_BIT (lines 408-420)

```systemverilog
STATE_TX_BIT: begin
  if (arb_lost_reg) begin
    next_state = STATE_IDLE;
  end else if (timer_done) begin
    if (bit_cnt == 3'd7) begin
      next_state = STATE_ACK_WAIT;
    end else begin
      next_state = STATE_TX_BIT;
    end
  end else begin
    next_state = STATE_TX_BIT;
  end
end
```

**Operational flow:**
1. We re-enter STATE_TX_BIT 8 times — once per data bit, MSB first.
2. Each entry: timer counts T_SCL_PERIOD ticks → bit goes out → bit_cnt increments.
3. After bit_cnt=7 → next state is STATE_ACK_WAIT (9th SCL cycle for ACK).
4. Arbitration escape: if `arb_lost_reg` is latched → abandon, return to IDLE.

**Bit ordering — MSB first:**

```systemverilog
sda_o <= shift_reg[7];   // ← drives MSB onto SDA
```

```systemverilog
// In shift register block:
shift_reg <= {shift_reg[6:0], 1'b0}; // shift left after each bit
```

**Why MSB first?** I2C spec mandates it. The first byte after START contains the 7-bit slave
address {A6, A5, A4, A3, A2, A1, A0, R/W} — and A6 must come out first so the slave decodes
its address before R/W arrives.

**Interview gotcha:** *"In your shift-out, what bit ends up driven LAST on SDA?"*

Answer: After 7 left-shifts, bit 7 of shift_reg holds what was originally bit 0 — so the LSB of
the original byte. Order on the wire: bit[7], bit[6], ..., bit[0]. **MSB first, LSB last.**

### STATE_RX_BIT (lines 445-455)

```systemverilog
STATE_RX_BIT: begin
  if (timer_done) begin
    if (bit_cnt == 3'd7) begin
      next_state = STATE_ACK_SEND;
    end else begin
      next_state = STATE_RX_BIT;
    end
  end else begin
    next_state = STATE_RX_BIT;
  end
end
```

**Operational flow:**
1. Re-enter 8 times.
2. Each entry: on SCL rising edge inside this state, sample SDA into shift_reg[0]. After 8
   bits, shift_reg holds the received byte in original order (received-MSB at bit[7]).
3. After bit_cnt=7 → transition to STATE_ACK_SEND (master drives the ACK bit).

**Shift-in logic (line 311):**

```systemverilog
shift_reg <= {shift_reg[6:0], sda_i};   // shift left, MSB lost, sda_i fills LSB
```

**Why this works:** First received bit (MSB) lands in LSB after one shift. After 8 shifts, it
has been pushed up to bit[7]. Last received bit (LSB) lands in bit[0]. Final shift_reg matches
the byte's natural bit ordering.

> 🎯 **The bug-hunt that became BUG #10:** at this exact transition (STATE_RX_BIT →
> STATE_ACK_SEND, bit 7 captured), the byte must be moved from shift_reg into reg_data_buf so
> the CPU can read it. See Section 9 for the deep explanation.

### STATE_ACK_WAIT (lines 427-439)

```systemverilog
STATE_ACK_WAIT: begin
  if (arb_lost_reg) begin
    next_state = STATE_IDLE;
  end else if (timer_done) begin
    if (ack_received) begin
      next_state = STATE_IDLE;        // ACK → command done
    end else begin
      next_state = STATE_STOP_1;      // NACK → auto-abort with STOP
    end
  end else begin
    next_state = STATE_ACK_WAIT;
  end
end
```

**This is the 9th SCL cycle after STATE_TX_BIT.** Master releases SDA (drives `sda_o = 1`,
i.e. open-drain releases) and samples sda_i on SCL rising. The slave is supposed to pull SDA
low to ACK; if it doesn't, NACK.

**Auto-STOP on NACK — design choice:**

This FSM auto-transitions to STATE_STOP_1 on NACK. This is **convenient for verification** —
you don't need a separate CMD_STOP from the CPU. But it's **opinionated** — a real chip might
let the CPU decide what to do on NACK (try again? Send a different address?).

**Interview-grade answer:**

> *"After transmitting a byte, the FSM enters STATE_ACK_WAIT for the 9th SCL cycle. It releases
> SDA to high-Z so the slave can pull it low for ACK. On the rising edge of SCL, the FSM
> registers sda_i into ack_received. If ack was 0 (ACK), the transaction completes and FSM
> returns to IDLE. If 1 (NACK), the FSM auto-transitions to STATE_STOP_1 to release the bus
> cleanly. This auto-STOP-on-NACK behavior is a design choice — some IPs let the CPU decide
> the next action, but here we prioritize safe bus release."*

### STATE_ACK_SEND (lines 461-463)

```systemverilog
STATE_ACK_SEND: begin
  next_state = timer_done ? STATE_IDLE : STATE_ACK_SEND;
end
```

**Master drives the 9th SCL cycle to ACK/NACK the received byte:**

```systemverilog
// from sda_o always_ff block
STATE_ACK_SEND: begin
  if (current_cmd == CMD_READ_NACK)
    sda_o <= 1'b1;       // NACK — "no more data, slave"
  else
    sda_o <= 1'b0;       // ACK — "send me another byte"
end
```

**Why does the master ever send NACK?** When the master is the *receiver* (reading from slave),
sending NACK signals "this was the last byte I wanted." The slave then releases SDA, and the
master can issue STOP cleanly. **If the master ACKed every byte forever, the slave would keep
streaming and never release.**

**Interview gotcha:** *"In an I2C read of N bytes, when do you NACK?"*

Answer: **On the final byte only.** Bytes 1..N-1 are ACKed (CMD_READ_ACK), byte N is NACKed
(CMD_READ_NACK). The CPU is responsible for issuing the right sequence.

### STATE_STOP_1 → STATE_STOP_2 (lines 468-469)

```systemverilog
STATE_STOP_1: next_state = timer_done ? STATE_STOP_2 : STATE_STOP_1;
STATE_STOP_2: next_state = timer_done ? STATE_IDLE   : STATE_STOP_2;
```

**The STOP condition is "SDA rises while SCL is HIGH":**

```
SCL: _______________/-------
SDA: __________/-----------
                ^
                Both states must establish: SCL=1, then SDA rises
```

- **STATE_STOP_1:** SCL=0, SDA=0 → setup. Pre-condition SDA must be low before we raise it.
- **STATE_STOP_2:** SCL=1, SDA rises from 0→1 → STOP condition signaled.

Then back to IDLE.

### STATE_REP_START_1 → STATE_REP_START_2 (lines 474-475)

```systemverilog
STATE_REP_START_1: next_state = timer_done ? STATE_REP_START_2 : STATE_REP_START_1;
STATE_REP_START_2: next_state = timer_done ? STATE_TX_BIT      : STATE_REP_START_2;
```

**Repeated START (Sr) is structurally the same as START, but issued without a preceding STOP:**

```
SDA: ...prev byte data.../-----\____ (Sr happens here)
SCL: ___________________/-----------
                              ^
                              SDA falls while SCL is HIGH (after being raised)
```

- **STATE_REP_START_1:** SCL=1, SDA=1 (released). Re-raise SDA so we have something to fall from.
- **STATE_REP_START_2:** SCL=0, SDA=0. SCL drops, ready for next byte.

**Why Sr?** Sr is used to **change direction** mid-transaction without releasing the bus.
Classic use case: "Write register address, then immediately read register value" — `START →
write addr+W → write reg_addr → Sr → write addr+R → read data → STOP`.

**Without Sr you'd need STOP + START, which (a) releases the bus to other masters, and (b) is
slower.** Sr is more efficient and atomic.

### The Timeout Escape Hatch (lines 372-374)

```systemverilog
if (timeout) begin
  next_state = STATE_IDLE;
end else begin
  case (state)
    ...
  endcase
end
```

This `if-else` at the top of `always_comb` is an **unconditional escape:** if `timeout` is
asserted (clock-stretched too long), force next_state to IDLE regardless of which state we're
in. This is a defensive design pattern — bus-level errors override FSM logic.

**Symmetric counterpart for arb_lost** is inside individual states (TX_BIT and ACK_WAIT). A
cleaner design might pull arb_lost into the top-level escape too:

```systemverilog
if (timeout || arb_lost_reg) next_state = STATE_IDLE;
```

> 🎯 **Refactor suggestion:** unify timeout and arb_lost escapes at the top of the FSM.

---

## 6. SDA Driving Logic — When to Pull, When to Release

The SDA output logic (lines 271-295) is a state-keyed mux:

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    sda_o <= 1'b1;
  end else begin
    case (state)
      STATE_IDLE:       sda_o <= 1'b1;          // released
      STATE_START_1:    sda_o <= 1'b0;          // SDA falls (START)
      STATE_START_2:    sda_o <= 1'b0;          // hold low
      STATE_TX_BIT:     sda_o <= shift_reg[7];  // MSB out
      STATE_ACK_WAIT:   sda_o <= 1'b1;          // release for slave ACK
      STATE_ACK_SEND:   /* see below */
      STATE_STOP_1:     sda_o <= 1'b0;          // hold low pre-rise
      STATE_STOP_2:     sda_o <= 1'b1;          // SDA rises (STOP)
      ...
    endcase
  end
end
```

### Open-Drain Semantics (lines 52-55)

```systemverilog
assign sda = (sda_o == 1'b0) ? 1'b0 : 1'bz;
assign scl = (scl_o == 1'b0) ? 1'b0 : 1'bz;
```

This **models** the open-drain pad. In silicon, the pad is a single NMOS pull-down; the `1'bz`
in simulation represents "released, pull-up resistor wins."

**Why open-drain on I2C?**
1. **Multiple masters/slaves can drive the bus** — anyone pulling low wins (wired-AND).
2. **Slave can hold SCL low** for clock stretching without contention.
3. **No driver conflicts** — even if two devices both think it's their turn, the bus just
   stays low. No CMOS short-circuit current.

**Interview gotcha:** *"What happens if `sda_o` is 1'b0 in your design but the slave is also
pulling SDA low?"*

Answer: Both are pulling → bus is low → no contention. In simulation, `(0) ? 1'b0 : 1'bz` from
our side combined with whatever the slave drives still resolves to 0. **This is the wired-AND
property.**

### The Hand-off at STATE_ACK_WAIT

```systemverilog
STATE_ACK_WAIT: sda_o <= 1'b1;           // release
```

**This is the critical line for ACK reception.** Master MUST release SDA in STATE_ACK_WAIT, or
the slave can't pull it low. If `sda_o` were 0 here, both master and slave would see SDA=0 and
the master would incorrectly conclude "ACK received" every time, even if the slave is absent.

**This is one of the classic "silent failures" in I2C IPs.** Verify it with a "no slave
present" test — the master must read NACK because nobody pulls SDA low.

### The Hand-off at STATE_ACK_SEND

```systemverilog
STATE_ACK_SEND: begin
  if (current_cmd == CMD_READ_NACK)
    sda_o <= 1'b1;       // NACK
  else
    sda_o <= 1'b0;       // ACK
end
```

This is the *master-side* ACK — only used when the master is the receiver. Note: it reads
`current_cmd`, which is registered in `reg_cmd`. So the FSM behavior on this state depends on
what command launched the transaction — `CMD_READ_ACK` → ACK, `CMD_READ_NACK` → NACK.

**Senior-engineer thought process:** This works only because `reg_cmd` is **latched**, not
pulsed. If `current_cmd` were derived from a one-cycle pulse, by the time we reach STATE_ACK_SEND
the command would be gone. The level-latched register is essential here. **The pulse is
`cmd_valid`; the value is `reg_cmd`. Don't confuse them.**

---

## 7. Clock Stretching Detection

I2C slaves are allowed to hold SCL low to slow down the master ("I'm not ready, give me time").
The master MUST detect this and pause SCL generation.

### The Mechanism (lines 213-223)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    stretch_cnt <= '0;
  end else if (scl_i == 1'b0 && state != STATE_IDLE) begin
    stretch_cnt <= stretch_cnt + 1'b1;
  end else begin
    stretch_cnt <= '0;
  end
end

assign timeout = (stretch_cnt >= MAX_CLK_STRETCH);
```

**Behavior:**
- Anytime SCL is LOW (either we drove it or the slave is stretching), `stretch_cnt` increments.
- The moment SCL rises, the counter clears.
- If the counter reaches `MAX_CLK_STRETCH` → assert `timeout` → FSM escapes to IDLE.

> ⚠️ **Subtle issue worth flagging:** This counter increments **whenever SCL is low**, even
> during normal SCL LOW phases that we drove! In a normal SCL period, SCL is low for T_SCL_LOW
> = 250 ticks. So `MAX_CLK_STRETCH` must be **larger than T_SCL_LOW**, or you'd timeout on
> every normal bit. Verify this in the package — and add a comment to that effect.

**Interview-grade answer:**

> *"Clock stretching is detected by monitoring sda_i — sorry, scl_i — and incrementing a
> counter whenever SCL is low and the FSM is not in IDLE. The counter resets when SCL rises.
> If the counter exceeds MAX_CLK_STRETCH, a timeout is asserted and the FSM aborts to IDLE.
> A subtlety in the current design is that the counter also increments during normal SCL LOW
> phases, so MAX_CLK_STRETCH must be greater than T_SCL_LOW (250 ticks) to avoid false
> timeouts. A cleaner implementation would gate the counter on 'SCL low AND we're not driving
> it' — i.e., distinguish slave-driven LOW from master-driven LOW. That would require sampling
> scl_o vs scl_i."*

> 🎯 **Refactor suggestion:** the stretch counter should only count when **the master has
> released SCL but slave is holding it low**, i.e. `scl_o == 1 && scl_i == 0`. Right now it
> counts master-driven LOW too, which inflates the count and risks false timeouts.

### Why Standalone "Pause SCL on Stretch" Logic Isn't Implemented

A fully spec-compliant master would also **pause** SCL generation when it detects the slave
holding SCL low — it should not advance to the SCL HIGH phase until SCL is actually high. This
design does NOT do that explicitly; SCL is driven open-drain, so even if the master "drives"
high, the slave can still hold it down. The master's timer continues, though, which could
de-sync SCL phases.

**A more rigorous fix:** gate `timer` advancement on `scl_i == scl_o` (i.e. only count when bus
matches our intent). This is left as a future refactor.

---

## 8. Timeout & Error Handling

### Outputs

| Signal | Asserted When | Lifetime |
|---|---|---|
| `timeout` | `stretch_cnt >= MAX_CLK_STRETCH` | Combinational from counter |
| `bus_error` | On timeout, set sticky in FSM block | Until next IDLE |
| `arb_lost` | On TX_BIT, sda_o=1 but sda_i=0 | Sticky until IDLE |
| `nack` | On ACK_WAIT timer-expired, ack_received=0 | Sticky until next cmd |
| `ack` | On ACK_WAIT timer-expired, ack_received=1 | Sticky until next cmd |
| `done` | One-cycle pulse at STATE_STOP_2 → IDLE | One cycle |
| `busy` | `next_state != STATE_IDLE` | Continuous |

### Pulse vs Level — Why It Matters

```systemverilog
done <= (state == STATE_STOP_2 && next_state == STATE_IDLE);
```

`done` is a **one-cycle pulse** asserted at the exact transition out of STATE_STOP_2 to IDLE.
This is appropriate for interrupt triggering — interrupts are typically edge-sensitive at the
CPU side, so a pulse is enough.

But for status registers, **sticky** is better — the CPU might not check immediately. Hence
ack/nack are sticky (cleared on next command), while `done` is pulsed (for IRQ).

> 🎯 **Common interview gotcha:** *"Why is `done` pulsed but `ack` sticky?"*
> Answer: `done` is an IRQ trigger → edge is what matters. `ack` is a status the CPU may poll
> long after the fact → level is what matters. **The choice between pulse and level is about
> who consumes the signal and when.**

### The Cleanup at New Command (lines 352-357)

```systemverilog
end else if (state == STATE_IDLE && cmd_valid) begin
  ack       <= 1'b0;
  nack      <= 1'b0;
  bus_error <= 1'b0;
end
```

This is the **clear-on-new-command** behavior. When the CPU issues a new command, stale status
flags are cleared so they reflect only the current transaction. **This is essential** — without
it, a fresh command would see leftover ACK from the previous transaction and mislead the CPU.

---

## 9. Shift Register & Data Buffer — BUG #10 Deep Explanation

### The Shift Register Block (lines 301-318)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    shift_reg <= 8'h00;
  end else begin
    if (cpu_wr && (cpu_addr == REG_DATA)) begin
      shift_reg <= cpu_wdata;                    // CPU loads byte for TX
    end
    else if (state == STATE_RX_BIT && scl_rise) begin
      shift_reg <= {shift_reg[6:0], sda_i};      // shift in on SCL rising
    end
    else if (state == STATE_TX_BIT && timer_expired) begin
      shift_reg <= {shift_reg[6:0], 1'b0};       // shift out (advance bit)
    end
  end
end
```

**Three drivers for shift_reg (all in same `always_ff`, so OK):**
1. CPU write — primes the register with TX data.
2. RX shift-in — fills shift_reg with received bits.
3. TX shift-out — advances to the next bit to drive on SDA.

### BUG #10 — The Critical Receive Bug

#### Symptom
After every read transaction, the CPU reads back **0x00** from REG_DATA instead of the byte the
slave sent.

#### Root Cause

`shift_reg` is an **internal register**, not visible to the CPU. The CPU reads `reg_data_buf`
via the read mux (`REG_DATA → reg_data_buf`). The shift register held the right byte at the end
of RX, but **nothing ever copied it into reg_data_buf**. So `reg_data_buf` stayed at its last
written value — and if it was never CPU-written before the read, it stayed at the reset value
0x00.

#### The Fix (lines 153-158)

```systemverilog
// FIX BUG #10: Capture received byte into reg_data_buf when RX completes.
if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND) begin
  reg_data_buf <= shift_reg;
end
```

#### Why Specifically at `STATE_RX_BIT && next_state == STATE_ACK_SEND`?

This is the **exact cycle** when:
- The 8th (and last) bit has been shifted into shift_reg → it holds the complete byte.
- The FSM is about to leave STATE_RX_BIT for STATE_ACK_SEND → shift_reg won't be modified again.

If you captured **earlier** (e.g., on any `state == STATE_RX_BIT && scl_rise`), you'd get
partial bytes during shifting. If you captured **later** (e.g., on entering STATE_ACK_SEND),
the FSM has already left RX_BIT and shift_reg might get overwritten by a subsequent CPU write
to REG_DATA before you see it.

**The transition cycle is the only safe window.** This is a **classic edge-triggered capture
pattern** — capture on the exact clock edge when the state changes.

#### How Verification Caught It

The scoreboard sees the slave transmit `byte=0x42` on the bus. The CPU then reads REG_DATA and
gets `0x00`. The scoreboard reports mismatch → bug ticket → investigation → fix.

**Lesson for interviews:** This is a *coverage-by-checker* bug — the testbench doesn't need a
specific test for "receive data integrity"; the scoreboard catches it on any read transaction.
**Good scoreboards find bugs you didn't write tests for.**

#### Interview-Grade Articulation

> *"BUG #10 was a data-path bug. The receive shift register, `shift_reg`, was correctly capturing
> bits from SDA on SCL rising edges, but it was never forwarded to the CPU-visible register
> `reg_data_buf`. So the CPU always read 0x00 after a slave-read transaction. The fix is a
> one-line edge capture in the host-interface always_ff block: when the state transitions from
> STATE_RX_BIT to STATE_ACK_SEND — i.e., the exact cycle when the 8th bit has been shifted in
> and before the FSM moves on — copy shift_reg into reg_data_buf. The scoreboard caught this
> because it checks observed CPU reads against expected slave-transmitted bytes; any test that
> did a read uncovered the bug."*

#### Why Not a Separate "Forward" Block?

You could refactor this into its own dedicated always_ff:

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)
    reg_data_buf <= 8'h00;
  else if (cpu_wr && cpu_addr == REG_DATA)
    reg_data_buf <= cpu_wdata;
  else if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND)
    reg_data_buf <= shift_reg;
end
```

But that's a stylistic choice. The current implementation embeds the BUG #10 fix in the host
interface block, which is acceptable as long as you write a comment (which the code does).

---

## 10. Arbitration Loss Detection (T13)

### The Mechanism (lines 519-531)

```systemverilog
logic arb_lost_reg;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    arb_lost_reg <= 1'b0;
  end else if (state == STATE_IDLE) begin
    arb_lost_reg <= 1'b0;
  end else if ((state == STATE_TX_BIT) && (sda_o == 1'b1) && (sda_i == 1'b0) && (scl_i == 1'b1)) begin
    arb_lost_reg <= 1'b1;
  end
end

assign arb_lost = arb_lost_reg;
```

**The detection condition:**
> *"We're transmitting (STATE_TX_BIT), we're driving high (sda_o=1, i.e. released), but the bus
> is low (sda_i=0), and SCL is HIGH so the bit is valid on the bus."*

Translation: **someone else is also transmitting and pulled SDA low — we lost.**

**Why `scl_i == 1`?** Bits are only valid on the bus when SCL is HIGH (sample window). During
SCL LOW phases, SDA changes are expected and not a contention.

### Why "Release the Bus on Arb Loss" (Don't Send STOP)

```systemverilog
STATE_TX_BIT: begin
  if (arb_lost_reg) begin
    next_state = STATE_IDLE;   // go to IDLE, NOT STOP
  end
  ...
end
```

This is **multi-master courtesy.** The winning master is in the middle of *their* transaction.
If we drove a STOP, we'd corrupt their bus state (premature STOP) and break their transfer.
The correct behavior is **silently release** — return to IDLE without touching the bus.

**Interview gotcha:** *"Why don't you issue STOP when you detect arbitration loss?"*

Answer: *"In multi-master I2C, arbitration loss means another master is actively transmitting.
Issuing STOP would prematurely terminate their transaction, corrupting both their data and the
bus state. The polite behavior is to silently abandon — release SDA and SCL, return to IDLE,
and either retry later or signal the CPU via the arb_lost flag. This is one of the protocol's
multi-master coexistence rules."*

### Caveat: Single-Master Test Setup

The current testbench is single-master, so `arb_lost` should never fire in practice. **This is
dead code from a coverage standpoint.** As with `STS_ARB_LOST` (Lesson 01 Q7), document it as
out-of-scope.

---

## 11. Reset & Initialization Behavior

### Reset Strategy: Async-Asserted, Sync-Released

Every `always_ff` in this file uses:

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    ...   // reset values
  end else begin
    ...
  end
end
```

**This is asynchronous-reset, synchronous-release if you add a reset synchronizer at the top
level.** Pure async reset is risky on release (metastability if rst_n deasserts near a clock
edge), so the standard pattern is:
- Async assert (so reset works even when clock is dead)
- Sync release (so de-assertion is glitch-free)

The synchronizer is typically in a top-level wrapper or in the test bench, not in this file.

### Reset Values — Are They Safe?

| Signal | Reset Value | Why |
|---|---|---|
| `state` | `STATE_IDLE` | Safe-by-default; no bus activity |
| `sda_o` | `1'b1` | **Released** — won't pull SDA low during reset |
| `scl_o` | `1'b1` | **Released** — won't pull SCL low during reset |
| `reg_*` | `8'h00` | Clean slate |
| `cmd_valid` | `1'b0` | No spurious command |
| `bit_cnt` | `3'd0` | Start at bit 0 |
| `shift_reg` | `8'h00` | Empty |
| `ack_received` | `1'b0` | No stale ACK |
| `arb_lost_reg` | `1'b0` | No stale arb loss |
| `cpu_irq` | `1'b0` | No spurious IRQ |

**The critical resets are `sda_o = 1` and `scl_o = 1`.** If they reset to 0, the master would
hold the bus low during reset, blocking the entire I2C bus. The current design correctly
releases.

**Interview-grade answer:**

> *"All flops are async-reset to safe values. The two most critical resets are sda_o and scl_o,
> both reset to 1 — meaning the master releases both lines, allowing the bus pull-ups to bring
> them high. If they reset to 0, the master would block the entire bus during reset, which is
> a catastrophic bug. The FSM resets to STATE_IDLE so no spurious bus activity starts."*

### Async-Reset Synthesis Implication

Async reset → on most FPGAs and ASICs, the reset goes to a dedicated reset pin on the flop,
which is **always available** regardless of clock. This is the safest reset strategy for
peripheral IPs.

**Trade-off:** Async-reset flops are slightly larger than sync-reset flops in some libraries.
Sync-reset is preferred in DSP / high-density blocks where area dominates.

---

## 12. Status & Interrupt Logic

### Status Register Update (lines 536-549)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    reg_status <= 8'h00;
  end else begin
    case (state)
      STATE_IDLE:                                reg_status <= STS_IDLE;
      STATE_TX_BIT, STATE_RX_BIT, STATE_ACK_WAIT: reg_status <= STS_BUSY;
      STATE_STOP_2:                              reg_status <= STS_DONE;
      default:                                   reg_status <= reg_status;
    endcase
    if (arb_lost_reg) reg_status <= STS_ARB_LOST;
  end
end
```

**Note the structure:**
1. State decoding into status (IDLE/BUSY/DONE).
2. An **override** at the bottom: if `arb_lost_reg` → STS_ARB_LOST takes priority.

This is the **last-assignment-wins** pattern in nonblocking semantics — the override is below
the case so it wins if both conditions match.

**Interview gotcha:** *"What's reg_status if `arb_lost_reg=1` while state=STATE_IDLE?"*

Answer: `STS_ARB_LOST`. The override unconditionally fires whenever arb_lost is high.

**But wait** — the line above said `STS_IDLE` if state is IDLE. Doesn't that race?

No — both are non-blocking. The case sets it to STS_IDLE; the override below clobbers it. Final
value: STS_ARB_LOST.

### IRQ Output (lines 552-562)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    cpu_irq <= 1'b0;
  end else begin
    cpu_irq <= |({reg_irq_en[0] & done,
                  reg_irq_en[1] & ack,
                  reg_irq_en[2] & nack,
                  reg_irq_en[3] & timeout,
                  reg_irq_en[4] & bus_error});
  end
end
```

**A 5-bit mask-and-reduce-OR**: each event (done/ack/nack/timeout/bus_error) is gated by its
corresponding IRQ_EN bit. Any unmasked event fires the IRQ.

This is **registered** — cpu_irq is the OR'd value flopped by one cycle. **Why register?**
- Glitch-free output (no combinational glitches reach the CPU interrupt controller).
- Predictable timing for static timing analysis.

The IRQ stays high as long as any source is asserted (level-triggered) and goes low when all
sources are clear. The CPU handles edge detection at its end.

> ⚠️ **Subtle gap:** there's no explicit "clear IRQ by writing 1" mechanism. The IRQ tracks
> the underlying signal, so when `done` pulses for one cycle, `cpu_irq` pulses for one cycle
> too (plus one cycle of register delay). For sticky events like `ack` and `nack`, the IRQ
> stays asserted until the next command clears them. A production-grade IP would have an
> explicit IRQ-clear register.

---

## 13. Quiz — 20 Questions

Cover the answer section before reading further. Target: 17/20 correct.

1. **What FSM coding style does this file use — one-process, two-process, or three-process?
   Justify with specific line references.**

2. **Why is T_SCL_PERIOD = 500 in this design? What would change for Fast Mode (400 kHz)?**

3. **In STATE_TX_BIT, which bit of `shift_reg` is driven onto SDA? Why? After one bit, what
   bit lives in shift_reg[7]?**

4. **Walk me through BUG #10. What was the symptom, root cause, and why does the fix capture
   on the `STATE_RX_BIT → STATE_ACK_SEND` transition specifically?**

5. **The CPU writes to REG_CMD. What signals does this trigger inside the FSM? Is the FSM
   triggered by an edge or by a level on `reg_cmd`?**

6. **Why does the master release SDA in STATE_ACK_WAIT? What would happen if it didn't?**

7. **When does the master *send* NACK vs ACK? Walk me through the logic in STATE_ACK_SEND.**

8. **Explain the clock stretch counter. What value must `MAX_CLK_STRETCH` be greater than, and
   why? What's the design weakness in the current implementation?**

9. **The escape `if (timeout) next_state = STATE_IDLE;` is at the top of `always_comb`. Why
   is it placed there instead of inside each case arm?**

10. **On arbitration loss, why does the FSM go to STATE_IDLE instead of STATE_STOP_1?**

11. **What is `cmd_valid` and why is it pulsed for one cycle only? What would break if it were
    level-held?**

12. **Both REG_STATUS and REG_IRQ_ST in the read mux return `reg_status`. Is this a bug?
    What's the right industry-grade behavior?**

13. **`sda_o` and `scl_o` reset to `1'b1`. Why is `1'b1` the safe reset value, and what would
    go wrong if they reset to `1'b0`?**

14. **What happens if the CPU writes REG_CMD = `4'hF` (an undefined enum value)? Trace through
    the FSM behavior.**

15. **In STATE_RX_BIT, on which event is sda_i sampled into shift_reg? Why that event and not
    a different one?**

16. **In STATE_TX_BIT, sda_o is assigned `shift_reg[7]` (the MSB). The shift register left-shifts
    by 1 on `timer_expired`. Walk through what bit reaches sda_o during cycles 0, 1, 2, ..., 7
    if the original byte loaded was 8'b1010_1100.**

17. **Suppose the CPU writes REG_CMD = CMD_STOP while the FSM is in STATE_TX_BIT (mid-transaction).
    What happens? Is this safe?**

18. **`done` is a one-cycle pulse, but `ack`/`nack` are sticky until the next command. Why
    different lifetimes? Which is appropriate for which consumer?**

19. **The arbitration loss check is: `(sda_o == 1'b1) && (sda_i == 1'b0) && (scl_i == 1'b1)`.
    What happens if you removed the `scl_i == 1'b1` term? Walk through a specific
    false-positive scenario.**

20. **Critical path question: which signal/path in this design is likely the longest combinational
    path? What might you do to improve it if you needed to run at 500 MHz instead of 50 MHz?**

---

## 14. Quiz Answers — Senior-Engineer Grade

### Q1 — FSM Coding Style

**Senior-engineer answer:**
This is a **two-process FSM** in textbook style:

- **`always_ff` block at lines 327-361:** drives `state <= next_state`, plus a few registered
  outputs (`busy`, `done`, `ack`, `nack`, `bus_error`).
- **`always_comb` block at lines 367-481:** purely computes `next_state` from `state` and inputs.

**Why two-process?**
1. Synthesis-predictable — `always_ff` enforces flop semantics; `always_comb` enforces no latches.
2. Lint-friendly — tools like Spyglass flag mixing of sequential and combinational logic.
3. Readable — "what state am I in" (sequential) is separate from "where do I go next"
   (combinational).

**Interview-grade answer:**

> *"It's a two-process FSM. One `always_ff` block drives the state register and a handful of
> registered outputs; one `always_comb` block computes next_state. This is the industry-standard
> style — it produces predictable synthesis, separates the storage from the logic, and is the
> default recommendation in most companies' RTL coding guides. An alternative three-process
> style further isolates output decoding into a separate combinational block, which is useful
> for very large FSMs; two-process is the sweet spot for protocol FSMs of this size."*

---

### Q2 — T_SCL_PERIOD = 500, Fast Mode Changes

**Math recap (Lesson 01):**
- 50 MHz / 100 kHz = 500 ticks per SCL period.
- 500 / 2 = 250 ticks per half (symmetric in Standard Mode).

**Fast Mode (400 kHz):**
- 50 MHz / 400 kHz = 125 ticks per SCL period.
- BUT: I2C spec requires asymmetric high/low in Fast Mode.
  - t_HIGH ≥ 0.6 µs → ≥ 30 ticks.
  - t_LOW ≥ 1.3 µs → ≥ 65 ticks.
  - Total 95 ticks minimum; pad up to 125 to hit 400 kHz exactly.

**Interview-grade answer:**

> *"T_SCL_PERIOD = 500 because 50 MHz / 100 kHz = 500. For Fast Mode at 400 kHz, the math gives
> 125 ticks per period, but the I2C spec mandates asymmetric high/low timing — t_HIGH ≥ 0.6 µs
> and t_LOW ≥ 1.3 µs. So T_SCL_HIGH would shrink to about 30 and T_SCL_LOW to about 95. The
> current design assumes symmetric half-periods, which works for Standard Mode but breaks for
> Fast Mode. A multi-mode IP needs separate parameters per mode."*

---

### Q3 — Bit Driving in STATE_TX_BIT

**Line 279:** `sda_o <= shift_reg[7];`

**The MSB of shift_reg goes to SDA.** This implements I2C's MSB-first byte order.

After one left-shift (`shift_reg <= {shift_reg[6:0], 1'b0}`), the original bit 6 has moved into
position 7. So in cycle 1, shift_reg[7] = original byte's bit 6. **Each cycle, the next-lower
original bit climbs to position 7 and gets driven.**

If original byte = 8'b1010_1100:
- Cycle 0: drive bit[7] = 1.
- Cycle 1: drive bit[6] = 0.
- Cycle 2: drive bit[5] = 1.
- ... (etc.)
- Cycle 7: drive bit[0] = 0.

**Interview-grade answer:**

> *"In STATE_TX_BIT, the MSB of the shift register (shift_reg[7]) is driven onto SDA — I2C
> mandates MSB-first transmission. After each bit completes (timer_expired), the shift register
> left-shifts by one position, so the original bit 6 now occupies bit 7 and gets driven next.
> After 8 left-shifts, the original LSB has been driven last, completing the byte in correct
> MSB-first order."*

---

### Q4 — BUG #10 Deep Dive

**Symptom:** CPU reads REG_DATA after a slave-read transaction and gets `0x00` instead of the
byte the slave sent.

**Root cause:** Two separate registers:
- `shift_reg` — internal, used by FSM for receive-shifting. CPU never sees it directly.
- `reg_data_buf` — the CPU-visible REG_DATA register.

The receive path filled `shift_reg` correctly, but nothing copied `shift_reg` into
`reg_data_buf`. So `reg_data_buf` stayed at its reset value 0x00 (or whatever the CPU last
wrote).

**Fix (lines 156-158):**
```systemverilog
if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND) begin
  reg_data_buf <= shift_reg;
end
```

**Why this exact transition?**
- We need the byte to be **complete** in shift_reg → after the 8th bit, which is exactly when
  `bit_cnt==7` and `next_state` is forced to STATE_ACK_SEND.
- We need to capture **before** shift_reg is reused — once we leave STATE_RX_BIT, the next CPU
  write to REG_DATA could overwrite shift_reg.
- The transition cycle (state still STATE_RX_BIT, next_state already STATE_ACK_SEND) is the
  one cycle where both conditions hold.

**Interview-grade answer:**

> *"BUG #10 was a data-path completeness bug. The receive shift register `shift_reg` was
> correctly collecting bits from SDA on SCL rising edges during STATE_RX_BIT, but it was never
> forwarded to the CPU-visible register `reg_data_buf`, so the CPU always read back 0x00 (the
> reset value of reg_data_buf) on read transactions. The fix is a one-line edge capture in the
> host-interface always_ff block: when the FSM transitions from STATE_RX_BIT to STATE_ACK_SEND
> — the exact cycle after the 8th bit has been shifted in — copy shift_reg into reg_data_buf.
> The scoreboard caught it because every read transaction failed the data-integrity check."*

**Why this is a great interview story:**
1. It's a real bug found and fixed by you.
2. It shows you understand the FSM timing in detail (the "exact cycle" framing).
3. It shows scoreboard-driven verification.
4. It demonstrates the difference between internal vs CPU-visible registers — a fundamental
   IP design concept.

---

### Q5 — CPU REG_CMD Write Effect

When CPU writes REG_CMD:
1. **`reg_cmd <= cpu_wdata`** (line 147) — the command value is latched into `reg_cmd` and
   stays there until the next CPU write. **Level-held.**
2. **`cmd_valid <= 1'b1`** (line 162) — a one-cycle pulse is asserted.

The FSM uses `cmd_valid` (pulse) as the **trigger** to leave IDLE, and `current_cmd` (level,
derived from `reg_cmd[3:0]`) as the **value** that decides which state to enter.

**Edge or level?** Triggered by an **edge-equivalent pulse** (`cmd_valid`), value taken from
**level-held register** (`reg_cmd`).

**Why this matters:** If the FSM used the level of `reg_cmd != 0` as its trigger, then after
completing the first transaction, `reg_cmd` would still hold (say) CMD_START, and the FSM
would re-enter STATE_START forever.

**Interview-grade answer:**

> *"CPU writes to REG_CMD have two effects: the value is latched into reg_cmd permanently
> until the next write, and a one-cycle cmd_valid pulse is asserted. The FSM is triggered by
> the pulse — that's what gets it out of IDLE — but the value of the command is read from the
> latched reg_cmd. This separation lets the FSM act once per command write while still being
> able to read the command value across multiple cycles. If we used a level trigger on reg_cmd,
> the FSM would loop forever on the same command after the first transaction."*

---

### Q6 — Why Release SDA in STATE_ACK_WAIT

**STATE_ACK_WAIT is the 9th SCL cycle after master TX.** During this cycle the slave is
expected to drive SDA low to ACK (or leave it high for NACK).

```systemverilog
STATE_ACK_WAIT: sda_o <= 1'b1;   // release
```

`sda_o = 1` means the master's open-drain output is released → bus rises to high-Z. The slave
can now pull it low (ACK) or leave it high (NACK).

**If the master DIDN'T release SDA:**
- `sda_o = 0` → master holds SDA low → slave's pull-down has no effect (wired-AND).
- Master then samples sda_i = 0 → falsely concludes "slave ACKed."
- **Every transaction would appear successful**, even with no slave on the bus.

**This is the textbook "silent failure" mode** — the master would seem to work in lab but fail
in the field.

**Interview-grade answer:**

> *"In STATE_ACK_WAIT, the master must release SDA — drive sda_o to 1, which on an open-drain
> bus means high-Z — so the slave can pull SDA low to ACK. If the master kept driving SDA low,
> the wired-AND nature of the bus would mean the master always sees SDA=0 regardless of slave
> behavior, and falsely concludes 'ACK received' on every transaction. This would mask all NACK
> errors, including the catastrophic 'no slave at this address' case. Releasing SDA in
> ACK_WAIT is a textbook I2C master correctness requirement."*

---

### Q7 — ACK vs NACK Selection in STATE_ACK_SEND

```systemverilog
STATE_ACK_SEND: begin
  if (current_cmd == CMD_READ_NACK)
    sda_o <= 1'b1;       // NACK
  else
    sda_o <= 1'b0;       // ACK
end
```

`current_cmd` is the latched command, derived from `reg_cmd[3:0]`.

- If the CPU issued **CMD_READ_NACK** → master drives SDA high (NACK), telling the slave "this
  was the last byte."
- If the CPU issued **CMD_READ_ACK** → master drives SDA low (ACK), telling the slave "send
  another byte."

**Multi-byte read pattern:**
- Bytes 1..N-1: CMD_READ_ACK each time → master ACKs.
- Byte N: CMD_READ_NACK → master NACKs.
- Then CMD_STOP.

**Interview-grade answer:**

> *"In STATE_ACK_SEND, the master decides ACK vs NACK based on which read command the CPU
> originally issued. CMD_READ_NACK causes the master to drive SDA high (NACK), signaling 'this
> was the last byte I wanted' so the slave releases SDA. CMD_READ_ACK causes the master to drive
> SDA low (ACK), signaling 'send me another byte.' For a multi-byte read of N bytes, the CPU
> issues CMD_READ_ACK for bytes 1 through N-1 and CMD_READ_NACK for byte N. The slave uses this
> as the protocol cue to end the burst."*

---

### Q8 — Clock Stretch Counter Analysis

**Counter logic:**
```systemverilog
end else if (scl_i == 1'b0 && state != STATE_IDLE) begin
  stretch_cnt <= stretch_cnt + 1'b1;
end else begin
  stretch_cnt <= '0;
end
```

The counter counts **any** SCL-low cycle when FSM is active — including normal SCL LOW phases
that the master itself drove (T_SCL_LOW = 250 ticks per bit).

**MAX_CLK_STRETCH must be > 250** (T_SCL_LOW), otherwise every normal bit triggers a false
timeout.

**Design weakness:** The counter doesn't distinguish "we drove SCL low" from "slave is holding
SCL low." A cleaner implementation:

```systemverilog
end else if (scl_o == 1'b1 && scl_i == 1'b0 && state != STATE_IDLE) begin
  stretch_cnt <= stretch_cnt + 1'b1;
```

This only counts "we tried to release SCL but the slave is still holding it down" — the actual
stretch event.

**Interview-grade answer:**

> *"The clock stretch counter increments any cycle SCL is low while the FSM is non-idle. It
> resets when SCL rises. If the count exceeds MAX_CLK_STRETCH, the timeout signal asserts and
> the FSM aborts to IDLE. The current implementation has a design weakness: it counts
> master-driven SCL LOW phases too, which means MAX_CLK_STRETCH must be larger than T_SCL_LOW
> (250 ticks) to avoid false timeouts during normal operation. A more rigorous design would
> compare scl_o vs scl_i — only count when we released SCL but the bus stays low — which
> distinguishes slave stretching from master driving."*

---

### Q9 — Why Timeout Escape Is at Top of `always_comb`

```systemverilog
always_comb begin
  next_state = state;
  if (timeout) begin
    next_state = STATE_IDLE;
  end else begin
    case (state) ... endcase
  end
end
```

**Reason:** The escape is **state-independent**. No matter what state we're in, if timeout
fires we want to abort. Putting it in each case arm would mean repeating the same code 11
times — error-prone and verbose.

This is the **priority encoding** pattern: bigger-priority conditions go above the default
case. Same shape as:

```systemverilog
if (urgent_reset) next = RESET;
else if (high_prio_event) next = HIGH_PRIO_STATE;
else case (state) ... endcase
```

**Senior-engineer thought process:** Identify global escape conditions (timeout, error, reset)
and pull them out of per-state logic. Keeps per-state logic readable, ensures consistent
escape behavior.

**Interview-grade answer:**

> *"The timeout escape is at the top of the always_comb because it's state-independent — no
> matter which state we're in, a timeout should abort to IDLE. Placing it above the case
> statement gives it priority and avoids duplicating the check in 11 different case arms. This
> is the priority-encoding pattern: high-priority escapes go above, normal state logic goes
> below. As a refinement, I'd unify timeout with arb_lost in the same escape since both should
> abort the FSM."*

---

### Q10 — Why Go to IDLE (Not STOP) on Arbitration Loss

**The arbitration scenario:**
- Two masters start transmitting simultaneously.
- Both think they own the bus.
- One pulls SDA low when the other expected high → wired-AND → loser detects mismatch.

**The winner is in the middle of THEIR transaction.** Their FSM state, their bit_cnt, their
data — all in flight. If the loser fires a STOP, that STOP corrupts the winner's bus state
prematurely.

**Correct behavior:** Loser **silently releases** — sets sda_o, scl_o back to released, returns
to IDLE. The winner continues uninterrupted.

This is **bus etiquette** in multi-master I2C.

**Interview-grade answer:**

> *"When the FSM detects arbitration loss in STATE_TX_BIT, it transitions to IDLE rather than
> STOP. The reason is multi-master bus etiquette: the winning master is mid-transaction, and
> firing a STOP would prematurely terminate their transfer, corrupting both their data and the
> bus state. The polite — and protocol-correct — behavior is to silently abandon the
> transaction by releasing SDA and SCL and going back to IDLE. The CPU is informed via the
> arb_lost flag, and software can decide whether to retry later. Sending STOP would be a
> protocol violation."*

---

### Q11 — Why `cmd_valid` Is Pulsed

```systemverilog
if (cpu_wr && (cpu_addr == REG_CMD)) cmd_valid <= 1'b1;
else                                  cmd_valid <= 1'b0;
```

**Pulse semantics:** `cmd_valid` is HIGH for exactly one cycle after the CPU writes REG_CMD.

**Why pulse vs level?**

If `cmd_valid` were level-held (e.g., asserted whenever `reg_cmd != CMD_NOP`), the FSM would
loop forever — after completing a command, `reg_cmd` still holds the same value, so the FSM
would re-trigger and re-execute.

The pulse gives the FSM a **fire-once** trigger. Each CPU write to REG_CMD generates exactly
one transaction.

**Interview-grade answer:**

> *"cmd_valid is a one-cycle pulse generated on the cycle the CPU writes REG_CMD. The FSM uses
> this pulse as a fire-once trigger to leave IDLE. If we used a level signal — say, reg_cmd
> being non-NOP — the FSM would re-trigger every cycle after completing a command, because
> reg_cmd stays latched. The pulse decouples 'when to act' from 'what value to use,' which lets
> the FSM read the latched reg_cmd value across multiple cycles without re-triggering."*

---

### Q12 — REG_STATUS and REG_IRQ_ST Both Return reg_status

```systemverilog
REG_STATUS: cpu_rdata = reg_status;
REG_IRQ_ST: cpu_rdata = reg_status;   // ← duplicate
```

**Is this a bug?** Technically not — both addresses return live status, which is "functional."
But it's a **design oversight.**

**Industry-grade behavior:** A separate IRQ-status register that's **sticky** and **W1C**
(write-1-to-clear). Reading REG_STATUS gives live state; reading REG_IRQ_ST gives latched
events that have fired since the CPU last cleared them.

**Why W1C?** The CPU needs an atomic way to acknowledge "I saw this interrupt; clear it" so
the IRQ deasserts. Without W1C, the CPU has to clear by writing 0 to specific bits, but if
another event fires between the read and the write, you lose it (read-modify-write race).

**Interview-grade answer:**

> *"It's not strictly a bug, but it's a design oversight. A production-grade I2C IP would have
> REG_STATUS reflect live state and REG_IRQ_ST be a separate latched, sticky register storing
> events that have fired since last cleared. The IRQ-status register should be write-1-to-clear
> so the CPU can atomically acknowledge interrupts without race conditions. The current
> implementation shortcuts both addresses to the same source, which means the CPU has no clean
> way to acknowledge specific events."*

---

### Q13 — Why `sda_o` and `scl_o` Reset to `1'b1`

**Open-drain semantics:**
- `1'b0` → master actively pulls bus low.
- `1'b1` → master releases bus (high-Z, pull-up wins).

If reset values were `1'b0`:
- During reset, master holds SDA and SCL low.
- **The entire I2C bus is blocked** — no other device can communicate.
- Any other device on the bus that's mid-transaction sees a broken bus.

Resetting to `1'b1` ensures **the master is invisible on the bus** until it has a command to
execute. Clean, polite, and safe.

**Interview-grade answer:**

> *"sda_o and scl_o reset to 1'b1 because on an open-drain bus, 1 means 'released' and 0 means
> 'actively pulled low.' Resetting to 1 keeps the master invisible on the bus during reset,
> letting pull-up resistors hold both lines high. If they reset to 0, the master would hold
> the bus low throughout reset, blocking every other device on the bus and potentially
> corrupting any ongoing transactions of other masters. Safe-by-default is to release."*

---

### Q14 — CPU Writes 4'hF to REG_CMD

`current_cmd = i2c_cmd_e'(reg_cmd[3:0]) = i2c_cmd_e'(4'hF)`. 4'hF is not in the enum.

**SystemVerilog cast behavior:** the cast succeeds — SV does not check enum range at runtime
unless you do an explicit assertion. `current_cmd` holds the raw 4'hF bits but is typed as
`i2c_cmd_e`.

**In the case statement:**
```systemverilog
case (current_cmd)
  CMD_START:    next_state = STATE_START_1;
  ...
  default:      next_state = STATE_IDLE;
endcase
```

4'hF doesn't match any specific case → hits `default` → next_state stays IDLE.

**But `cmd_valid` still pulsed.** So the FSM "consumes" the invalid command silently and
returns to IDLE. **Safe-by-default behavior.**

**Defensive improvement:** Assert in simulation:
```systemverilog
assert property (@(posedge clk) cmd_valid |-> current_cmd inside {CMD_START, CMD_STOP, ...});
```

Or set a `bus_error` flag on undefined command.

**Interview-grade answer:**

> *"Writing 4'hF to REG_CMD triggers the cmd_valid pulse normally, but the cast `i2c_cmd_e'(4'hF)`
> produces a value not matched by any specific case arm in the FSM. It falls through to the
> default, which keeps next_state at IDLE. The FSM effectively swallows the invalid command and
> stays idle — safe-by-default behavior. A defensive improvement would be a SystemVerilog
> assertion or a bus_error flag triggered on undefined commands, so verification catches
> software bugs that write garbage to the command register."*

---

### Q15 — RX Sampling on SCL Rising Edge

```systemverilog
else if (state == STATE_RX_BIT && scl_rise) begin
  shift_reg <= {shift_reg[6:0], sda_i};
end
```

**Why `scl_rise`?** I2C specifies that **data is valid on SDA while SCL is HIGH**, and the
receiver samples in the SCL HIGH window. The rising edge of SCL is the conventional sampling
point — at that moment SDA is guaranteed stable per the spec's setup-time requirements.

**Why not `scl_fall`?** The falling edge is when the transmitter is **about to change** SDA
for the next bit. Sampling on fall would race the transmitter's data change → unreliable.

**Why not `timer_expired`?** The master's internal timer might not align with the actual SCL
edge if the slave is clock-stretching. Using `scl_rise` makes sampling bus-driven and immune
to internal timer drift.

**Interview-grade answer:**

> *"RX sampling uses scl_rise — the rising edge of the SCL line — because I2C specifies that
> SDA is valid while SCL is HIGH, and the rising edge of SCL is the conventional sampling
> point. Sampling on the falling edge would race the transmitter's data change. Using an
> internal timer instead would also be wrong because if the slave is clock-stretching, the
> actual SCL rising edge happens later than the master's expected time. Sampling on the bus
> edge makes the receiver immune to internal timer drift."*

---

### Q16 — Bit-by-Bit Trace for 8'b1010_1100

Initial: `shift_reg = 8'b1010_1100` (positions [7:0] = 1,0,1,0,1,1,0,0).

| Cycle | shift_reg before shift | sda_o = shift_reg[7] | shift_reg after shift |
|---|---|---|---|
| 0 | 10101100 | **1** | 01011000 |
| 1 | 01011000 | **0** | 10110000 |
| 2 | 10110000 | **1** | 01100000 |
| 3 | 01100000 | **0** | 11000000 |
| 4 | 11000000 | **1** | 10000000 |
| 5 | 10000000 | **1** | 00000000 |
| 6 | 00000000 | **0** | 00000000 |
| 7 | 00000000 | **0** | 00000000 |

**Bits transmitted on SDA, in order:** 1, 0, 1, 0, 1, 1, 0, 0 — exactly the original byte
MSB-first.

After all 8 shifts, shift_reg is 8'b0000_0000 (consumed the byte).

**Interview-grade answer:**

> *"Starting with shift_reg = 8'b1010_1100, in cycle 0 sda_o = shift_reg[7] = 1, then the
> register left-shifts to 8'b0101_1000. In cycle 1 sda_o = 0, shift_reg becomes 8'b1011_0000.
> Continuing, the bits driven on SDA are 1, 0, 1, 0, 1, 1, 0, 0 — exactly the original byte in
> MSB-first order. After 8 cycles, shift_reg is 8'b0000_0000, having been completely consumed."*

---

### Q17 — CMD_STOP During TX_BIT (Mid-Transaction)

**Scenario:** FSM is in STATE_TX_BIT, bit 5 of the address has been transmitted, and the CPU
suddenly writes REG_CMD = CMD_STOP.

**What happens:**
1. `reg_cmd <= CMD_STOP` and `cmd_valid <= 1'b1` for one cycle.
2. The FSM in STATE_TX_BIT does NOT check `cmd_valid` — only STATE_IDLE does (see line 380).
3. The FSM continues transmitting bits 5, 6, 7, transitions to STATE_ACK_WAIT, completes the
   byte, returns to IDLE.
4. By the time IDLE is reached, `cmd_valid` has long deasserted (it was a 1-cycle pulse). So
   STATE_IDLE does NOT see `cmd_valid=1`.
5. **The CMD_STOP write is silently dropped.**

**Is this safe?** Bus-wise yes — no garbage on the bus. Software-wise it's confusing — the CPU
expected a STOP and got silence. The CPU would need to re-issue CMD_STOP after observing busy=0.

**Better behavior:** Either
- (a) Buffer the command — latch one pending command at a time; process on return to IDLE.
- (b) Error response — set a flag when CMD writes happen while busy=1, so software knows it
  was dropped.

**Interview-grade answer:**

> *"If the CPU writes CMD_STOP while the FSM is in STATE_TX_BIT, the cmd_valid pulse fires for
> one cycle, but only STATE_IDLE checks cmd_valid in this implementation. So mid-transaction
> CMD writes are silently dropped — the FSM continues its current transaction to completion
> and returns to IDLE, by which time cmd_valid has deasserted. Bus-wise this is safe — no
> garbage on the bus — but software-wise it's misleading; the CPU thinks the STOP is queued.
> A better implementation would either buffer one pending command for processing on return to
> IDLE, or set an error flag visible to software so the CPU knows the write was dropped."*

---

### Q18 — Pulse vs Sticky Output Lifetimes

| Signal | Lifetime | Consumer | Why |
|---|---|---|---|
| `done` | one-cycle pulse | IRQ controller, software polling | Marks transaction completion — an event, not a state |
| `ack`, `nack` | sticky until next cmd | Software status check | Reports the outcome of the just-completed transaction — needs to persist for software to poll |
| `busy` | continuous level | Software polling | Reflects live FSM state — must be a level |
| `bus_error`, `arb_lost` | sticky until next cmd / IDLE | Error reporting | Errors must persist until software acknowledges |

**Principle:** Choose pulse vs level based on the consumer.
- **Edge-sensitive consumer (IRQ controller):** pulse is sufficient.
- **Polling consumer (software reading CSR):** sticky/level is necessary, because the software
  might not check immediately.

**Interview-grade answer:**

> *"The choice between pulse and level depends on who consumes the signal and when. `done` is a
> one-cycle pulse because its primary consumer is the IRQ controller, which is edge-triggered
> and only needs to see the event once. `ack` and `nack` are sticky because the consumer is
> CPU software polling REG_STATUS, which may read at any arbitrary time after the transaction
> completes — the value must persist long enough for the software to see it. `busy` is a
> continuous level because it represents live FSM state. The rule of thumb: edge-sensitive
> consumers can take pulses; polling consumers need sticky."*

---

### Q19 — Removing `scl_i == 1'b1` from Arb-Lost Check

```systemverilog
// Without scl_i == 1'b1:
else if ((state == STATE_TX_BIT) && (sda_o == 1'b1) && (sda_i == 1'b0)) begin
  arb_lost_reg <= 1'b1;
end
```

**False-positive scenario:** During the SCL LOW phase of a normal TX, the master may have
released SDA (driving 1) for the next bit's setup. But the *previous* bit's data might still
be transitioning on the bus — specifically, if the previous bit was a 0 (we drove low), then
SDA is just starting to rise toward 1 as we release. **During this transition, sda_i could
still be sampled as 0 even though we just started driving 1.**

Or more clearly: between two consecutive TX bits, when SCL is LOW, SDA can legitimately be
in transition or held low — that's not arbitration loss, that's normal protocol.

**With `scl_i == 1'b1`:** we only check during the SCL HIGH window when SDA must be stable
and at the value we intend. This is the only valid time to compare.

**Without it:** any SCL LOW phase where the bus happens to be low (because someone driving)
counts as arb loss → false trigger → master abandons valid transactions.

**Interview-grade answer:**

> *"Removing the scl_i == 1'b1 term would generate false arbitration loss triggers during
> normal SCL LOW phases. Specifically, between two consecutive TX bits when SCL is low, the
> bus is in transition — the previous bit's value may still be settling, the slave may be in
> a clock-stretch window, or our own SDA may be ramping. None of those mean arbitration loss.
> The bit value is only meaningful in the SCL HIGH sample window, which is exactly when the
> arbitration comparison is valid. Removing that guard turns every normal LOW phase into a
> potential false abort, breaking the master."*

---

### Q20 — Critical Path & 500 MHz Scaling

**Likely critical path candidates:**

1. **Next-state combinational logic** — the entire `always_comb` block. Including the
   `if (timeout)` check, the case statement, and per-arm decisions. Roughly 11 mux levels
   plus the timer compare.

2. **`timer_clr = (state != next_state)`** — combinational from state to clear input. Then the
   timer's mux input depends on this clear. This path includes the next-state logic plus the
   timer's clear chain.

3. **The shift_reg path:** `sda_i → shift_reg[0] → shift_reg[6:0] (combinational shift in
   non-blocking)` — actually fine because it's flopped. But the SDA-to-shift-reg sample path
   involves edge detection (`scl_rise`) which has 1 cycle of latency.

**The dominant path is likely the next-state logic feeding back into the FSM register through
several muxes.** At 50 MHz (20 ns period), this is comfortable. At 500 MHz (2 ns) it would be
the first thing to optimize.

**Optimization strategies for 500 MHz:**

1. **Pipeline the FSM** — split next-state computation across two cycles. Decoder pipeline stage
   followed by transition stage. Adds 1 cycle of latency but halves combinational depth.

2. **Precompute timer_done and timer_clr** as registered outputs of a dedicated timer block, so
   they have a full cycle to propagate.

3. **Move escape conditions (timeout, arb_lost) into a separate flopped "abort" signal** that
   feeds an OR gate near the state register input.

4. **Reduce next-state mux fanout** — group similar states (e.g. START_1/2, STOP_1/2, REP_*_1/2
   could share counters/decoders). Less mux levels = shorter critical path.

5. **Retiming** — let synthesizer pull flops backward through combinational logic. This is
   often the easiest first step in modern tools (Synopsys retime, Innovus retiming).

**Interview-grade answer:**

> *"The critical path is almost certainly through the next-state combinational logic — the
> entire always_comb block, including the timeout escape, the case statement, and the
> per-state transitions. At 50 MHz this is comfortable, but at 500 MHz the 2 ns period would
> force aggressive optimization. My approach would be: first try retiming to let the
> synthesizer balance the logic across the state-register flops; if that's insufficient,
> pipeline the next-state computation into two stages, accepting one extra cycle of latency.
> A third option is to flatten the state encoding to one-hot, which reduces mux depth at the
> cost of area. The trade-off is between area, latency, and timing closure — typical design
> space for high-frequency FSMs."*

---

## 15. Key Takeaways

### Conceptual

1. **Two-process FSM is the standard.** One `always_ff` for state and registered outputs, one
   `always_comb` for next-state. Industry recommendation.

2. **Open-drain semantics flip your intuition.** `1'b0` actively pulls down; `1'b1` releases.
   Reset to `1'b1` for safety.

3. **MSB-first transmission** is mandated by I2C spec. Use left-shift with `sda_o = shift_reg[7]`.

4. **The pulse vs level choice depends on the consumer.** IRQ → pulse. Polling status → sticky.
   Live state → continuous level.

5. **cmd_valid is a one-cycle pulse, reg_cmd is the latched value.** Pulse = trigger; level =
   data. Don't confuse them.

6. **Sample RX on the bus edge, not the internal timer.** scl_rise gives slave-stretch immunity.

7. **The BUG #10 pattern — internal vs CPU-visible registers.** Always trace data from the bus
   to the CPU read-back path. Missing forwards are common bugs.

8. **Arbitration loss → release the bus, don't STOP.** Multi-master etiquette.

9. **Two-state primitives (START_1/2, STOP_1/2)** express timing: one state for setup, one for
   the transition. Standard pattern for any protocol with setup-then-act timing.

10. **Top-level escapes for global conditions (timeout) reduce code duplication** and ensure
    consistent abort behavior.

### Bugs / Issues Worth Tracking

| Item | Severity | Status |
|---|---|---|
| BUG #10 — RX data not forwarded to reg_data_buf | High | Fixed |
| CMD_ABORT not implemented | Medium | Open feature gap |
| CMD writes during busy silently dropped | Medium | Open — needs latch-or-error |
| Stretch counter doesn't distinguish self-driven LOW | Low | Open — works if MAX_CLK_STRETCH > 250 |
| REG_STATUS and REG_IRQ_ST aliased | Low | Open — needs W1C IRQ status reg |
| arb_lost escape not unified with timeout | Low | Style refactor |
| No assert on undefined CMD value | Low | Open — verification helper |

### Career-critical

1. You will be asked **the two-process FSM question** in nearly every interview. Have the
   reasoning memorized.
2. **MSB-first transmission with shift-left** is core knowledge for I2C/SPI/UART. Trace it on
   paper before the interview.
3. **BUG #10 is your strongest interview story** — it shows you found a real bug, understood
   the root cause, and applied the fix at the exact correct timing point. Practice telling it
   in under 90 seconds.
4. **Open-drain reset values** — interviewers love trick questions about reset to 0 vs 1 on
   bus IO.
5. **Pulse vs level** is a fundamental DV concept that distinguishes seniors from juniors.

---

## 16. Action Items

- [ ] Re-do the 20-question quiz cold in 3 days. Target ≥17/20.
- [ ] Draw the FSM diagram **from memory** on a whiteboard. Time yourself — target under 4 minutes.
- [ ] Practice the BUG #10 narrative out loud (90 seconds). Record yourself. Listen back.
- [ ] Walk through the bit-trace exercise (Q16) on paper for 3 random bytes. Mental fluency.
- [ ] **(Stretch)** Refactor stretch_cnt to only count slave-driven LOW (scl_o=1, scl_i=0).
      Submit as a Pull Request to the project.
- [ ] **(Stretch)** Implement CMD_ABORT — the FSM should transition to STATE_STOP_1 on receipt.
- [ ] **(Stretch)** Add SystemVerilog assertions: invalid CMD, CMD-during-busy, ACK during
      ACK_WAIT only.
- [ ] When you reach UVM RAL training, design a register block for this CSR map with W1C on
      IRQ status. Apply it as a refactor.
- [ ] Read NXP UM10204 sections 3.1 (START/STOP), 3.1.6 (Repeated START), 3.1.9 (clock
      stretching). One page each, fold in your understanding.

---

## 17. Honest Self-Score Template

Fill in honestly. Re-evaluate weekly.

| Area | Score | Notes |
|---|---|---|
| Two-process FSM coding style | __% | Can I write the skeleton from scratch? |
| FSM diagram from memory | __% | Did I include all 11 states and arb-lost/timeout escapes? |
| SCL generation math (T_SCL_PERIOD = 500) | __% | Without looking? |
| MSB-first shift register direction | __% | Bit-trace exercise without notes? |
| BUG #10 narrative (90 sec articulation) | __% | Recorded and listened back? |
| Open-drain reset value reasoning | __% | Can I explain why sda_o resets to 1, not 0? |
| Pulse vs sticky output choice | __% | Can I justify each output's lifetime? |
| Clock stretch counter design weakness | __% | Did I identify the false-trigger issue? |
| Arbitration loss → IDLE (not STOP) rationale | __% | Multi-master etiquette? |
| cmd_valid pulse vs reg_cmd level distinction | __% | Why both exist? |
| Critical path analysis | __% | Can I name the longest combinational path? |
| Reading the always_comb FSM block at speed | __% | Can I trace any state transition in < 30 sec? |

### Suggested Rubric

- **0%:** Heard for the first time. Reread the section.
- **30%:** Recall the concept but not the details. Reread + quiz once.
- **60%:** Can explain it under no pressure. Practice with a friend / camera.
- **80%:** Can explain it cold under interview pressure. Move on.
- **100%:** Could teach this section to someone else from scratch. Mastered.

---

**End of Lesson 03.** Next file: `i2c_slave_controller.sv` — the slave-side FSM, addressed
decoding, clock stretching as a slave, address-match detection. Different style, different
challenges. See you there.
