# 02 — RTL Master Controller Deep Dive
## A Senior Engineer's Complete Guide to Reading and Understanding RTL

**File:** `rtl/i2c_master_controller.sv`  
**Package:** `rtl/i2c_pkg.sv`  
**Bugs Reference:** `docs/BUG_REPORT.md`  
**Author:** Senior Verification Engineer (written for intern mentorship)  
**Last Updated:** 2026-05-12

---

> **HOW TO USE THIS DOCUMENT**
>
> Read this document with the RTL file open side-by-side. Every time you see
> a line number reference (e.g., "line 51"), go look at the actual code. This
> document is designed to teach you HOW to think, not just WHAT to know.
> The thinking process is shown explicitly with "First I look at...",
> "Then I ask myself...", "This tells me..." patterns throughout.

---

## Table of Contents

1. [Part 1: How to Read RTL Like a Senior Engineer](#part-1)
2. [Part 2: Port-by-Port Analysis](#part-2)
3. [Part 3: Parameters and Timing](#part-3)
4. [Part 4: The 11-State FSM — Every State Explained](#part-4)
5. [Part 5: The Timer and Clock Generation Logic](#part-5)
6. [Part 6: The Shift Register — Data Transmission](#part-6)
7. [Part 7: The CPU Interface](#part-7)
8. [Part 8: Bug #8 and #9 Deep Dive — Critical RTL Bugs](#part-8)
9. [Part 9: Non-Blocking Assignment Trap](#part-9)
10. [Part 10: Interview Questions — Master Controller](#part-10)

---

<a name="part-1"></a>
## Part 1: How to Read RTL Like a Senior Engineer

### 1.1 The Mindset: You Are a Detective

When a senior engineer opens an RTL file, they are not just reading code — they
are building a mental model of a physical circuit. Every `always_ff` is a
collection of flip-flops. Every `assign` is a wire. Every `if/case` is a
multiplexer. Keep this translation running in your head constantly.

The very first thing I do when I open any RTL file is scan for three things
in this exact order:

```
STEP 1: Read the module header comment  (lines 1-8)
STEP 2: Read the port list              (lines 13-36)
STEP 3: Find the FSM typedef            (lines 76-88)
```

Why this order? Because it answers: "What IS this thing, what does it CONNECT
to, and what are its MODES OF OPERATION?" Everything else is implementation
detail.

---

### 1.2 The 5-Question Framework

Before reading a single line of implementation code, force yourself to answer
these five questions. Write them down. You will fill in answers as you read.

```
+----------------------------------------------------------+
|  THE 5 QUESTIONS FOR ANY RTL MODULE                      |
+----------------------------------------------------------+
|                                                          |
|  Q1: What does this module DO?                           |
|      (What physical action does it perform?)             |
|                                                          |
|  Q2: What are its INPUTS?                                |
|      (Who drives each input? From where?)                |
|                                                          |
|  Q3: What drives its OUTPUTS?                            |
|      (Which internal signals create each output?)        |
|                                                          |
|  Q4: What can go WRONG?                                  |
|      (Timing violations? Protocol errors? Bus errors?)   |
|                                                          |
|  Q5: How does it RESET?                                  |
|      (Active high? Active low? Sync? Async?)             |
|                                                          |
+----------------------------------------------------------+
```

For the `i2c_master_controller`, let us fill this in right now:

**Q1: What does it DO?**
It is a byte-level I2C master. It talks to slave devices on the I2C bus. It
generates START conditions, transmits 8-bit bytes MSB-first, waits for ACK,
receives bytes from slaves, sends ACK/NACK, and generates STOP conditions.

**Q2: What are its INPUTS?**
- `clk`, `rst_n` — system clock and reset from board-level
- `cpu_addr[2:0]`, `cpu_wr`, `cpu_wdata[7:0]` — commands from a CPU
- `scl`, `sda` — bidirectional I2C bus lines (also outputs via tri-state)

**Q3: What drives its OUTPUTS?**
- `scl`, `sda` — driven by `scl_o` and `sda_o` via tri-state assignments
- `cpu_rdata[7:0]` — driven by a `always_comb` read-mux from internal registers
- `busy`, `done`, `ack`, `nack`, `timeout`, `bus_error` — driven by the FSM state register

**Q4: What can go WRONG?**
- SCL stuck low (clock stretch timeout)
- NACK from slave (slave rejected the byte)
- Bus error (protocol violation or arbitration lost)
- Incorrect timer causing SCL to never go high (Bug #9!)

**Q5: How does it RESET?**
Active-low asynchronous reset: `rst_n`. When `rst_n=0`, all flip-flops go to
safe known states. `scl_o <= 1`, `sda_o <= 1` (bus released), `state <= IDLE`.

---

### 1.3 How to Identify the Two-Always-Block FSM Pattern

The two-always-block FSM is the gold standard for synthesizable RTL. Here is
why it exists and how to spot it.

**WHAT TO LOOK FOR:**

```systemverilog
// Block 1: Sequential — registers state
always_ff @(posedge clk or negedge rst_n) begin
    state <= next_state;   // <-- just registers the combinational result
end

// Block 2: Combinational — computes next state
always_comb begin
    next_state = state;    // <-- default to hold
    case (state)
        ...
    endcase
end
```

**WHY TWO BLOCKS?**

In a ONE-block FSM, you put both state registration and next-state logic in the
`always_ff`. This works but has a critical problem: it becomes impossible to
separate the "current state" from the "next state" concept. You get feedback
loops where a signal reads and writes in the same block, which confuses both
synthesis tools and human readers.

With TWO blocks:
1. The `always_comb` block computes `next_state` purely from `state` and inputs. It is PURELY COMBINATIONAL — no memory, no clock.
2. The `always_ff` block is a simple D flip-flop: `state <= next_state`. At the clock edge, the computed next state becomes the current state.

This separation also helps avoid Bug #8 in this project — see Part 8.

> **SENIOR ENGINEER TIP:**
> When you see a signal named `next_<something>`, you are looking at a
> two-always-block FSM. The `next_*` signals are the combinational outputs
> that get registered on the next clock edge. If you ever see `next_state`
> being written in an `always_ff` block (other than being registered), that
> is a red flag — it means two blocks are fighting over the same signal, which
> is Bug #8.

---

### 1.4 The Quick Scan Checklist

When you open any RTL file, run through this in 5 minutes:

```
[ ] 1. Read the header comment — understand the intent
[ ] 2. Note the reset polarity (rst_n = active low)
[ ] 3. Count the always blocks — each is a separate piece of hardware
[ ] 4. Find the typedef enum — that is your FSM state list
[ ] 5. Identify all tri-state (inout) signals — they need special handling
[ ] 6. Note any `$clog2()` — that tells you counters sized to parameters
[ ] 7. Find the "default" assignments in always_comb — missing defaults = latches
[ ] 8. Check if non-blocking (<=) vs blocking (=) are used correctly
```

Let us apply this to the master controller right now. Looking at line 76:

```systemverilog
typedef enum logic [4:0] {
    STATE_IDLE,       // 5-bit encoded states
    STATE_START_1,
    STATE_START_2,
    STATE_TX_BIT,
    STATE_RX_BIT,
    STATE_ACK_WAIT,
    STATE_ACK_SEND,
    STATE_STOP_1,
    STATE_STOP_2,
    STATE_REP_START_1,
    STATE_REP_START_2
} state_e;
```

**Eleven states.** This is a moderately complex FSM. I immediately draw a mental
picture: IDLE → START → TX bits → ACK → (STOP or continue). The dual `_1/_2`
suffix on START, STOP, and REP_START tells me each condition takes TWO clock
phases — this is physically meaningful because START/STOP conditions require
specific SDA/SCL timing sequences.

---

<a name="part-2"></a>
## Part 2: Port-by-Port Analysis

### 2.1 The System-Level Picture

Before analyzing ports, draw where this module lives in the system:

```
         +------------------+              +------------------+
         |    CPU / ARM     |              |   I2C SLAVE      |
         |  (or testbench)  |              |  DEVICE          |
         +------------------+              +------------------+
                  |                                |
     cpu_addr[2:0]|  cpu_wr                       |
     cpu_wdata[7:0|] cpu_rdata[7:0]               |
         cpu_irq  |                                |
                  |                                |
         +--------|-------------------------------|---------+
         |        v    i2c_master_controller       v        |
         |  +----------+   +-----------+    +----------+   |
         |  | Host CPU |   |           |    |  I2C Bus |   |
         |  | Register |   |    FSM    |    | tri-state|   |
         |  | Interface|   | (11 state)|    |  drivers |   |
         |  +----------+   +-----------+    +----------+   |
         |        |              |               |         |
         |   reg_cmd       next_state        scl_o/sda_o   |
         |   reg_data      timer_done        scl_i/sda_i   |
         |   reg_status    bit_cnt           scl/sda (wire)|
         |                                                   |
         +---------------------------------------------------+
                                                |
                                          SDA --+-- SDA     (open-drain bus)
                                          SCL --+-- SCL
                                                |
                                          [pull-up R] [pull-up R]
                                                |
                                               VCC (3.3V or 5V)
```

The master is the bridge between the CPU world (synchronous, parallel,
register-based) and the I2C world (serial, two-wire, open-drain).

---

### 2.2 Port Group 1: System Signals

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | input | 1 bit | System clock. All flip-flops trigger on posedge. |
| `rst_n` | input | 1 bit | Active-LOW async reset. When 0, all FFs go to safe state. |

**Why active-low?** Most digital designs use active-low reset because it is
what FPGA and ASIC standard-cell libraries provide natively. The `_n` suffix is
the convention: "n" = "negative" (active low). When `rst_n = 0`, reset is
ACTIVE.

> **SENIOR ENGINEER TIP:**
> In your testbench, always apply reset for at least 2-3 clock cycles.
> Asynchronous reset means the FF immediately goes to reset state when
> `rst_n` falls — it does NOT wait for a clock edge. But releasing reset
> IS synchronous to the next clock edge in good designs. Always release
> reset with a full cycle margin.

---

### 2.3 Port Group 2: Host CPU Interface (APB-like)

```
CPU Side:
  cpu_addr[2:0]  ─────────────> Which register to access (7 registers)
  cpu_wr         ─────────────> 1=write, 0=read
  cpu_wdata[7:0] ─────────────> Data CPU is writing to register
  cpu_rdata[7:0] <─────────────  Data master sends back to CPU
  cpu_irq        <─────────────  Interrupt: "Hey CPU, something happened!"
```

**Every port explained:**

**`cpu_addr[2:0]`** (3 bits = 8 possible addresses, 7 used):
This is a simple register-map address bus. The CPU puts a 3-bit address here
to say WHICH register it wants to read or write. The mapping comes from
`i2c_pkg.sv`:
```
REG_CTRL   = 3'h0  -> Control: enable, mode selection
REG_CMD    = 3'h1  -> Command: write CMD_START, CMD_WRITE, etc.
REG_STATUS = 3'h2  -> Status: read-only, shows IDLE/BUSY/DONE
REG_DATA   = 3'h3  -> Data: write TX data here, read RX data here
REG_ADDR   = 3'h4  -> Address: I2C slave 7-bit address + R/W bit
REG_IRQ_EN = 3'h5  -> Interrupt Enable: which events trigger cpu_irq
REG_IRQ_ST = 3'h6  -> Interrupt Status: read to see what fired
```

**`cpu_wr`** (1 bit):
When HIGH (1), the CPU is WRITING to the register at `cpu_addr`.
When LOW (0), the CPU is READING. This is combinationally decoded — the read
mux at line 169 uses `cpu_addr` directly to compute `cpu_rdata` regardless
of `cpu_wr`.

**`cpu_wdata[7:0]`** (8 bits):
The data the CPU wants to write. Only relevant when `cpu_wr=1`.

**`cpu_rdata[7:0]`** (8 bits):
The master presents the register contents here. Driven by a pure `always_comb`
block at line 169. Notice: this is NOT registered — it is pure combinational
logic. This means it responds in zero clock cycles (same cycle as `cpu_addr`
changes). This is correct for an APB-like interface.

**`cpu_irq`** (1 bit):
Interrupt output. When HIGH, the master is telling the CPU "wake up, I need
your attention." The specific event (done, ack, nack, timeout, bus_error) is
controlled by `REG_IRQ_EN`. See the IRQ logic at line 517.

---

### 2.4 Port Group 3: I2C Bus Interface

```
I2C Bus (Open-Drain, Wired-AND topology):
  scl  <-----> SDA clock line (both master drives and reads)
  sda  <-----> SDA data line  (both master drives and reads)
```

These are `inout wire` — bidirectional! This is unusual and important.

**Why `inout`?** On a real I2C bus, both master and slave can drive SDA. The
slave drives SDA during data reads and ACK phases. The master drives SDA during
writes. Since both can drive, the bus uses open-drain: any device pulling LOW
wins (wired-AND). The pull-up resistor (on the PCB) ensures the line goes HIGH
when nobody is pulling it down.

**The tri-state assignments (lines 51-54):**
```systemverilog
assign sda = (sda_o == 1'b0) ? 1'b0 : 1'bz;   // line 51
assign scl = (scl_o == 1'b0) ? 1'b0 : 1'bz;   // line 52
assign sda_i = sda;                              // line 53
assign scl_i = scl;                              // line 54
```

Read line 51 carefully. When `sda_o = 0`, we drive `sda = 0` (pull LOW).
When `sda_o = 1`, we drive `sda = z` (high-impedance, release). The
pull-up resistor on the PCB then pulls it to VCC (HIGH).

Why do we read back `sda_i = sda` (line 53)? Because we need to OBSERVE what
is actually on the bus. During ACK phase, the slave pulls SDA LOW. We released
SDA (driving 'z') but we need to see if the slave is pulling it down. By reading
`sda_i`, we can tell: "I released the bus — is someone else pulling it down?"

> **SENIOR ENGINEER TIP:**
> The bidirectional tri-state pattern is one of the trickiest things in RTL.
> In simulation, `1'bz` in a `wire` correctly models the floating line.
> In synthesis, it maps to a tri-state buffer cell in the I/O ring. If you
> ever see `1'bz` inside an `always` block or in any logic that is NOT on
> the I/O boundary, that is a red flag — tri-state is only valid at I/O pads.

---

### 2.5 Port Group 4: Status and Control Outputs

| Port | Width | Driver | Meaning |
|------|-------|--------|---------|
| `busy` | 1 | `always_ff` state machine | HIGH while in any non-IDLE state |
| `done` | 1 | `always_ff` state machine | HIGH for exactly ONE clock cycle when STOP completes |
| `ack` | 1 | `always_ff` state machine | HIGH when slave sent ACK (SDA=0 on 9th SCL) |
| `nack` | 1 | `always_ff` state machine | HIGH when slave sent NACK (SDA=1 on 9th SCL) |
| `timeout` | 1 | combinational | HIGH when SCL held low > MAX_CLK_STRETCH cycles |
| `bus_error` | 1 | `always_ff` state machine | HIGH on protocol violation (timeout) |

**Important design choices:**

`done` is a ONE-CYCLE pulse (line 342):
```systemverilog
done <= (state == STATE_STOP_2 && next_state == STATE_IDLE);
```
This is TRUE only for exactly one clock cycle — the cycle when STOP_2 transitions
to IDLE. The CPU must either latch this or use the `cpu_irq` mechanism.

`ack` and `nack` are STICKY (persist until next command starts, line 344-355).
This gives the CPU time to poll the status register and see the result.

`timeout` is COMBINATIONAL (line 222):
```systemverilog
assign timeout = (stretch_cnt >= MAX_CLK_STRETCH);
```
This means it can go high asynchronously relative to the clock. The FSM checks
it in the `always_comb` block as an escape hatch.

---

<a name="part-3"></a>
## Part 3: Parameters and Timing

### 3.1 All Parameters from i2c_pkg.sv

The package defines ALL timing constants for the entire design. First, read
the system clock assumption at line 27:

```systemverilog
parameter int CLK_FREQ_MHZ = 50;  // 50 MHz system clock
```

**This one number drives all the timing calculations.** If you have a different
clock, you change THIS parameter and everything else follows.

---

### 3.2 The Critical Formula: 100 kHz from 50 MHz

**The goal:** I2C Standard Mode = 100 kHz SCL
**The constraint:** System clock = 50 MHz

```
System clock period = 1 / 50 MHz = 20 nanoseconds per tick

I2C SCL period = 1 / 100 kHz = 10,000 nanoseconds = 10 microseconds

Number of clock ticks per SCL period = 10,000 ns / 20 ns = 500 ticks
```

This gives us `T_SCL_PERIOD = 500` at line 31 of `i2c_pkg.sv`:

```systemverilog
parameter int T_SCL_PERIOD = 500;  // 10 us / 20 ns = 500 clocks
parameter int T_SCL_HIGH   = 250;  // SCL high time (approx 5 us = 50% duty cycle)
parameter int T_SCL_LOW    = 250;  // SCL low time  (approx 5 us = 50% duty cycle)
```

Note: `T_SCL_HIGH + T_SCL_LOW = 250 + 250 = 500 = T_SCL_PERIOD`. The duty
cycle is exactly 50%. I2C Standard Mode spec requires minimum 4.7 us LOW and
4.0 us HIGH — at 50 MHz, our 250 ticks × 20 ns = 5 us comfortably meets both.

**The `$clog2` trick for timer width (line 111):**
```systemverilog
logic [$clog2(T_SCL_PERIOD)-1:0] timer;
```
`$clog2(500) = 9` because 2^9 = 512 ≥ 500. So the timer is 9 bits wide.
This is exactly wide enough to count from 0 to 499. A senior engineer always
uses `$clog2` rather than hard-coding bit widths — if you change `T_SCL_PERIOD`,
the timer automatically resizes.

---

### 3.3 Complete Parameter Table

| Parameter | Value | Formula | Physical Meaning |
|-----------|-------|---------|-----------------|
| `CLK_FREQ_MHZ` | 50 | — | 50 MHz system clock, 20 ns per tick |
| `T_SCL_PERIOD` | 500 | 10 us / 20 ns | One complete SCL cycle |
| `T_SCL_HIGH` | 250 | 5 us / 20 ns | SCL stays HIGH for 250 ticks |
| `T_SCL_LOW` | 250 | 5 us / 20 ns | SCL stays LOW for 250 ticks |
| `T_SU_STA` | 10 | 200 ns | Start setup: SDA must fall 200 ns before SCL falls |
| `T_HD_STA` | 10 | 200 ns | Start hold: SDA stays low 200 ns after SCL falls |
| `T_SU_STO` | 10 | 200 ns | Stop setup: SDA must stay low 200 ns before SCL rises |
| `T_HD_DAT` | 5 | 100 ns | Data must be stable 100 ns after SCL falls |
| `T_SU_DAT` | 5 | 100 ns | Data must be set up 100 ns before SCL rises |
| `T_BUF` | 20 | 400 ns | Bus free time between STOP and next START |
| `MAX_CLK_STRETCH` | 1000 | 20 us | Maximum wait for slave clock stretch |
| `DATA_WIDTH` | 8 | — | I2C byte is 8 bits |
| `ADDR_WIDTH` | 7 | — | I2C address is 7 bits |

---

### 3.4 How Timer Counters Work in RTL (Step-by-Step)

The timer block at lines 189-207 is the heartbeat of the whole design. Let us
walk through it manually for 3 clock cycles:

**Setup:** `T_SCL_PERIOD = 500`, so the timer counts 0 → 499 then wraps.

```
Cycle 0 (Reset):
  rst_n = 0
  timer <= 0
  timer_expired <= 0

Cycle 1 (timer_clr = 0, timer is not at 499):
  timer:         0 → 1
  timer_expired: 0 → 0

Cycle 2:
  timer:         1 → 2
  timer_expired: 0 → 0

... (497 more cycles) ...

Cycle 499:
  timer reaches 498 → checks: is 498 == 499? No
  timer:         498 → 499
  timer_expired: 0 → 0

Cycle 500:
  timer = 499, checks: is 499 == T_SCL_PERIOD - 1 = 499? YES!
  timer:         499 → 0   (wraps back)
  timer_expired: 0 → 1     (fires the expiry flag!)

Cycle 501:
  timer_clr fires because state changes (timer_clr = state != next_state)
  timer:         0  → 0   (cleared)
  timer_expired: 1  → 0   (cleared)
```

**The key insight:** `timer_expired` is HIGH for exactly ONE clock cycle.
The FSM in `always_comb` samples `timer_done` (which is just `timer_expired`,
aliased at line 324) and decides to transition. This is the trigger for ALL
state transitions in the FSM.

---

<a name="part-4"></a>
## Part 4: The 11-State FSM — Every State Explained

### 4.1 State Transition Overview

```
                    cmd_valid
                    CMD_START
          +---------+  |
          |  IDLE   |--+
          +---------+
            |  ^  ^
   CMD_WRITE|  |  |CMD_STOP connects here too
   CMD_READ |  |  +------------------------------------------+
            |  |                                             |
     +------v---------+                                      |
     |   START_1      | SDA falls while SCL high             |
     | (SDA=0, SCL=1) |                                      |
     +----------------+                                      |
            | timer_done                                     |
     +------v---------+                                      |
     |   START_2      | SCL pulled LOW, hold SDA low         |
     | (SDA=0, SCL=0) |                                      |
     +----------------+                                      |
            | timer_done                                     |
     +------v---------+     bit_cnt==7                       |
     |    TX_BIT      |---> ACK_WAIT --> (ACK) --> IDLE      |
     | (Shift 8 bits) |           |                          |
     +----------------+           +-> (NACK) -> STOP_1       |
            ^ timer_done                         |            |
            | (bit_cnt<7)                +-------v--------+  |
            |                           |     STOP_1     |  |
     +------v---------+     bit_cnt==7  |  (SDA=0,SCL=0) |  |
     |    RX_BIT      |---> ACK_SEND   +----------------+  |
     | (Sample 8 bits)|                        | timer_done  |
     +----------------+                +-------v--------+  |
            | timer_done (bit_cnt<7)   |     STOP_2     |--+
            +------------------------> |  (SDA=1,SCL=1) |
                                       +----------------+
                                               | timer_done
                                           +---v-----+
                                           |  IDLE   |
                                           +---------+

     REP_START path:
     CMD_REP_START: IDLE --> REP_START_1 --> REP_START_2 --> TX_BIT
```

---

### 4.2 STATE_IDLE

**What is happening on the I2C bus?**
Nothing. SDA = HIGH, SCL = HIGH. The bus is free. Any device can claim it.

**Entry conditions:**
- Power-on reset
- After STOP_2 timer expires
- After ACK_WAIT if ACK received and command complete
- After timeout (escape hatch)

**What the state DOES:**
```systemverilog
// Line 234: SCL stays high (released)
STATE_IDLE: scl_o <= 1'b1;

// Line 275: SDA stays high (released)
STATE_IDLE: sda_o <= 1'b1;

// Line 509: Status register set to STS_IDLE
STATE_IDLE: reg_status <= STS_IDLE;
```

It waits. When `cmd_valid` goes HIGH (CPU wrote to REG_CMD), it decodes
`current_cmd` and transitions to the appropriate state.

**Exit conditions:**
```systemverilog
// Lines 378-391
STATE_IDLE: begin
  if (cmd_valid) begin
    case (current_cmd)
      CMD_START:    next_state = STATE_START_1;
      CMD_WRITE:    next_state = STATE_TX_BIT;
      CMD_READ_ACK: next_state = STATE_RX_BIT;
      CMD_STOP:     next_state = STATE_STOP_1;
      CMD_REP_START:next_state = STATE_REP_START_1;
    endcase
  end
end
```

**SDA/SCL waveform:**
```
SCL: ──────────────────────────────
SDA: ──────────────────────────────
      ^ IDLE state (both high, bus free)
```

**Possible BUG here:** What if `cmd_valid` pulses for more than one cycle?
The `cmd_valid` signal is designed to be a one-cycle pulse (line 160-164).
But if the CPU writes REG_CMD while the master is BUSY (not in IDLE), the
command is latched in `reg_cmd` but `cmd_valid` is generated only when the
CPU writes. The FSM only checks `cmd_valid` in IDLE, so commands written
while BUSY are captured in `reg_cmd` and will fire when the master returns
to IDLE. This is a design choice (implicit command queue of depth 1).

---

### 4.3 STATE_START_1

**What is happening on the I2C bus?**
This is the START condition. By I2C spec, START = SDA falls while SCL is HIGH.
START_1 is the first half: we pull SDA LOW while keeping SCL HIGH.

**Entry conditions:** From IDLE when `cmd_valid` and `current_cmd == CMD_START`

**What the state DOES:**
```systemverilog
STATE_START_1: scl_o <= 1'b1;   // SCL stays HIGH
STATE_START_1: sda_o <= 1'b0;   // SDA FALLS (this IS the START condition)
```

The timer runs for T_SCL_PERIOD ticks. This gives the SDA fall time for all
devices on the bus to recognize the START condition.

**Exit condition:** `timer_done` fires → go to START_2

**SDA/SCL waveform:**
```
SCL: ────────────────────────────────────────────
SDA: ─────────────\__________________________
                   ^ SDA falls (START condition detected by all slaves)
      [  START_1  ][  START_2  ][  TX_BIT ...  ]
```

---

### 4.4 STATE_START_2

**What is happening on the I2C bus?**
After the START condition is established, we must pull SCL LOW to prepare for
data transmission. Data can only change on the bus when SCL is LOW.

**Entry conditions:** From START_1 after timer expires

**What the state DOES:**
```systemverilog
STATE_START_2: scl_o <= 1'b0;   // SCL pulled LOW
STATE_START_2: sda_o <= 1'b0;   // SDA stays LOW
```

Now both SCL and SDA are LOW. This is the "hold" phase after the START
condition. It meets the `T_HD_STA` (Start Hold Time) requirement.

**Exit condition:** `timer_done` fires → go to TX_BIT (ready to send the
address byte)

**SDA/SCL waveform:**
```
SCL: ─────────\___________________________
SDA: ─────\___________________________
            [S] [START_1][  START_2  ][TX_BIT begins...]
```

> **SENIOR ENGINEER TIP:**
> Why two states for START instead of one? Because each state controls SDA
> and SCL independently, and the protocol requires a specific SEQUENCE:
> (1) SDA goes low FIRST while SCL is high, (2) THEN SCL goes low.
> You cannot do both in one state because a state is a single clock cycle
> of behavior. The two-state approach cleanly separates these two moments.

---

### 4.5 STATE_TX_BIT

**What is happening on the I2C bus?**
The master is transmitting data bits. For each bit, SCL pulses HIGH to let
the slave sample the data on SDA.

**Entry conditions:** From START_2, IDLE (CMD_WRITE), REP_START_2, or from
itself (looping for 8 bits when bit_cnt < 7)

**What the state DOES:**

SDA output:
```systemverilog
STATE_TX_BIT: sda_o <= shift_reg[7];   // MSB first!
```

SCL generation (the heart of the clock divider):
```systemverilog
STATE_TX_BIT: begin
  if (timer < T_SCL_LOW)
    scl_o <= 1'b0;                          // LOW phase: 0 to 249
  else if (timer < T_SCL_LOW + T_SCL_HIGH)
    scl_o <= 1'b1;                          // HIGH phase: 250 to 499
  else
    scl_o <= 1'b0;                          // (never reached: wraps at 499)
end
```

Bit counter increments when `timer_done`:
```systemverilog
// Line 495
if ((state == STATE_TX_BIT) && timer_done)
    bit_cnt <= bit_cnt + 1;
```

Shift register advances when `timer_done`:
```systemverilog
// Line 313
else if (state == STATE_TX_BIT && timer_expired)
    shift_reg <= {shift_reg[6:0], 1'b0};  // Shift left, insert 0 at LSB
```

**Exit conditions:**
```systemverilog
STATE_TX_BIT: begin
  if (timer_done) begin
    if (bit_cnt == 3'd7)     // After bit 7 (8th bit, 0-indexed)
      next_state = STATE_ACK_WAIT;
    else
      next_state = STATE_TX_BIT;  // Stay, but timer_clr will reset timer
  end
end
```

**SDA/SCL waveform for one bit (bit value = 1):**
```
        |<--- T_SCL_LOW = 250 ticks -->|<-- T_SCL_HIGH = 250 ticks -->|
SCL:    |______________________________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|____
SDA:         ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
(bit=1)       ^ Data stable during LOW      ^ Slave samples here (SCL high)
```

**Bug that could exist here:** Bug #9. If the timer comparison were wrong (e.g.,
both branches drove `scl_o <= 0`), SCL would NEVER go high. The slave samples
data on the SCL rising edge, so a stuck-low SCL means the slave never sees any
bits. The bus appears stuck. See Part 8 for the full story.

---

### 4.6 STATE_ACK_WAIT

**What is happening on the I2C bus?**
After 8 data bits, it is the slave's turn to ACK. The master releases SDA
(pulls HIGH via resistor), and the slave pulls SDA LOW to ACK. The master
watches for this on the 9th SCL pulse.

**Entry conditions:** From TX_BIT after bit_cnt == 7

**What the state DOES:**
```systemverilog
STATE_ACK_WAIT: sda_o <= 1'b1;   // RELEASE SDA — let slave drive it
STATE_ACK_WAIT: scl_o <= (timer < T_SCL_LOW) ? 1'b0 : 1'b1;  // 9th clock
```

The ACK is sampled in a dedicated register (lines 476-484):
```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)
    ack_received <= 1'b0;
  else if (state == STATE_ACK_WAIT && scl_rise)
    ack_received <= (sda_i == 1'b0);   // ACK = slave pulled SDA LOW
  else if (state != STATE_ACK_WAIT)
    ack_received <= 1'b0;              // Clear when leaving state
end
```

**Why sample on `scl_rise` and not on `timer_done`?**
Because the slave drives SDA relative to its own clock. The I2C spec says data
is valid on the RISING EDGE of SCL. By using the detected SCL rising edge
(`scl_rise`), we are robust to any clock stretching the slave might do. Timer-
based sampling would be fragile.

**SDA/SCL waveform:**
```
SCL:     ____|‾‾‾‾‾‾‾‾‾|____
SDA:     Z‾‾‾‾‾\_______‾‾‾‾  <- Slave pulls LOW (ACK)
                 ^
                 Sample here (on scl_rise): sda_i=0 → ack_received=1
```

**Exit conditions:**
```systemverilog
STATE_ACK_WAIT: begin
  if (timer_done) begin
    if (ack_received)  next_state = STATE_IDLE;   // ACK: transaction done
    else               next_state = STATE_STOP_1; // NACK: abort with STOP
  end
end
```

---

### 4.7 STATE_RX_BIT

**What is happening on the I2C bus?**
The master is RECEIVING data. The slave drives SDA with each data bit. The
master generates SCL and samples SDA on each SCL rising edge.

**Entry conditions:** From IDLE when `cmd_valid` and `current_cmd` is
`CMD_READ_ACK` or `CMD_READ_NACK`

**What the state DOES:**

SDA output:
```systemverilog
// Not explicitly set in SDA logic — falls through to default:
default: sda_o <= 1'b1;   // Master releases SDA during RX
```

SCL generation: identical to TX_BIT (master still drives SCL in I2C):
```systemverilog
STATE_RX_BIT: begin
  if (timer < T_SCL_LOW)        scl_o <= 1'b0;
  else if (timer < T_SCL_LOW + T_SCL_HIGH) scl_o <= 1'b1;
  else                          scl_o <= 1'b0;
end
```

Bit sampling in the shift register (line 309):
```systemverilog
else if (state == STATE_RX_BIT && scl_rise) begin
  shift_reg <= {shift_reg[6:0], sda_i};   // MSB arrives first → shift left
end
```

**SDA/SCL waveform for receiving byte 0xA5 (binary 10100101):**
```
Bit#:  7    6    5    4    3    2    1    0
SDA:  ‾‾\_ /‾\ /‾\ /__  /‾\ /__ /‾\ /__
SCL:  __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|__
       ^  ^  ^  ^  ^  ^  ^  ^
       Sample each rising edge → shift_reg captures 10100101 = 0xA5
```

**Exit conditions:** After 8 bits (bit_cnt == 7 and timer_done), go to
ACK_SEND.

**The Bug #10 connection:** After RX_BIT completes, `shift_reg` holds the
received byte. But the CPU reads data from `reg_data_buf` — NOT from
`shift_reg`. Originally, there was no path from `shift_reg` to `reg_data_buf`
after an RX operation. The fix (lines 155-157) captures the byte at exactly
the moment of transition:
```systemverilog
if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND) begin
  reg_data_buf <= shift_reg;   // FIX BUG #10: forward received byte to CPU
end
```

---

### 4.8 STATE_ACK_SEND

**What is happening on the I2C bus?**
After receiving 8 bits, the master sends ACK (LOW) to tell the slave "keep
sending" or NACK (HIGH) to say "that's the last byte I want."

**Entry conditions:** From RX_BIT after bit_cnt == 7

**What the state DOES:**
```systemverilog
STATE_ACK_SEND: begin
  if (current_cmd == CMD_READ_NACK)
    sda_o <= 1'b1;   // NACK: release SDA, pull-up drives HIGH
  else
    sda_o <= 1'b0;   // ACK: pull SDA LOW
end
STATE_ACK_SEND: scl_o <= (timer < T_SCL_LOW) ? 1'b0 : 1'b1;
```

**Exit condition:** `timer_done` → STATE_IDLE

**SDA/SCL waveform (ACK case — CMD_READ_ACK):**
```
                  9th SCL pulse (master drives ACK)
SCL:     _________|‾‾‾‾‾‾‾‾‾|_________
SDA:         ____‾_____________  <- master drives LOW (ACK)
                              ^ Slave sees ACK, prepares next byte
```

---

### 4.9 STATE_STOP_1

**What is happening on the I2C bus?**
Beginning the STOP condition. By I2C spec, STOP = SDA rises while SCL is HIGH.
So STOP_1 is the setup: drive SDA LOW while SCL is LOW (preparing for the
SDA rise in STOP_2).

**Entry conditions:** From ACK_WAIT when NACK received, or from IDLE on
CMD_STOP

**What the state DOES:**
```systemverilog
STATE_STOP_1: scl_o <= 1'b0;   // SCL LOW
STATE_STOP_1: sda_o <= 1'b0;   // SDA LOW (setup for STOP)
```

**Exit condition:** `timer_done` → STATE_STOP_2

---

### 4.10 STATE_STOP_2

**What is happening on the I2C bus?**
The actual STOP condition. SCL goes HIGH, then SDA goes HIGH. All slaves
see this as "transaction over, bus is free."

**Entry conditions:** From STOP_1 after timer expires

**What the state DOES:**
```systemverilog
STATE_STOP_2: scl_o <= 1'b1;   // SCL HIGH
STATE_STOP_2: sda_o <= 1'b1;   // SDA rises for STOP condition
```

**Exit condition:** `timer_done` → STATE_IDLE

**Done pulse generation:**
```systemverilog
done <= (state == STATE_STOP_2 && next_state == STATE_IDLE);
```

**SDA/SCL waveform for STOP:**
```
        [STOP_1]  [  STOP_2  ]  [IDLE]
SCL:  ___________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
SDA:  __________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
                ^ SDA rises while SCL is high = STOP condition
```

> **SENIOR ENGINEER TIP:**
> Status register update on STOP_2 (line 511):
> `STATE_STOP_2: reg_status <= STS_DONE;`
> The CPU polling REG_STATUS will see DONE at this point. After one more
> timer expiry, the FSM goes to IDLE and status becomes STS_IDLE. The CPU
> has one full T_SCL_PERIOD window (500 clocks = 10 us) to read STS_DONE.

---

### 4.11 STATE_REP_START_1 and STATE_REP_START_2

**What is happening on the I2C bus?**
A Repeated START (Sr) allows the master to send a new address byte WITHOUT
releasing the bus with a STOP condition. This is used for read-after-write
sequences (common in register-based I2C devices: "write register address,
then read register value").

**REP_START_1:** Raise SDA HIGH while SCL is also HIGH (like returning to IDLE,
but without the STOP condition — no SDA LOW-to-HIGH with SCL HIGH pattern).

**REP_START_2:** Pull SCL LOW again. Now we are back in the same state as
after a normal START, ready to send a new address byte.

```systemverilog
STATE_REP_START_1: scl_o <= 1'b1;   // SCL high
STATE_REP_START_1: sda_o <= 1'b1;   // SDA high (like releasing)

STATE_REP_START_2: scl_o <= 1'b0;   // SCL low
STATE_REP_START_2: sda_o <= 1'b0;   // SDA falls (the Sr condition)
```

**Exit:** REP_START_2 → TX_BIT (send new address)

**SDA/SCL waveform:**
```
  [Last data bit or ACK][REP_START_1][REP_START_2][New address TX...]
SCL: ‾‾‾|_______________|‾‾‾‾‾‾‾‾‾‾|_____________|‾‾|__|‾‾|__|‾‾|__
SDA: (any)              ‾‾‾‾‾‾‾‾‾‾‾\______________|  | 7-bit addr |
                        ^ SDA rises  ^ SDA falls   = Repeated START (Sr)
                          (REP_START_1)
```

---

<a name="part-5"></a>
## Part 5: The Timer and Clock Generation Logic

### 5.1 Overview: The Timer Is the Heartbeat

Everything in the master runs off the timer. Without a functioning timer, the
FSM never advances. This is why Bug #9 (SCL stuck LOW) was so devastating — even
though the timer itself was fine, the RESULT (SCL waveform) was wrong, which
meant the slave never sampled data.

---

### 5.2 The Timer Block (Lines 189-207)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    timer         <= '0;           // Reset to 0
    timer_expired <= 1'b0;         // No expiry on reset
  end else if (timer_clr) begin
    timer         <= '0;           // Clear on state transition
    timer_expired <= 1'b0;
  end else begin
    if (timer == T_SCL_PERIOD - 1) begin  // Has it counted to 499?
      timer         <= '0;           // YES: wrap back to 0
      timer_expired <= 1'b1;         // YES: signal expiry
    end else begin
      timer         <= timer + 1'b1; // NO: keep counting
      timer_expired <= 1'b0;
    end
  end
end
```

The clear signal (line 207):
```systemverilog
assign timer_clr = (state != next_state);
```

This is elegant: whenever the FSM changes state, the timer resets. So each
state gets a fresh T_SCL_PERIOD worth of time. States that need longer timing
simply stay in themselves and let the timer expire multiple times (like
STATE_TX_BIT which loops 8 times).

---

### 5.3 How SCL Is Generated (Lines 228-264)

The SCL generation block reads the timer and produces a square wave. Here is
the key section for TX_BIT:

```systemverilog
STATE_TX_BIT: begin
  if (timer < T_SCL_LOW)                      // 0 to 249: SCL LOW
    scl_o <= 1'b0;
  else if (timer < T_SCL_LOW + T_SCL_HIGH)    // 250 to 499: SCL HIGH
    scl_o <= 1'b1;
  else                                         // 500+: never reached
    scl_o <= 1'b0;
end
```

Let us trace through one complete bit cycle manually:

```
Timer Tick  | timer value | SCL output | What's happening
------------|-------------|------------|------------------
0           |     0       |     0      | Start of bit, SCL LOW
1           |     1       |     0      | SCL LOW
...         |   ...       |     0      | SCL LOW
249         |   249       |     0      | Last tick of LOW phase
250         |   250       |     1      | SCL rises! Slave will sample SDA
251         |   251       |     1      | SCL HIGH, data stable
...         |   ...       |     1      | SCL HIGH
499         |   499       |     1      | timer==T_SCL_PERIOD-1 → timer_expired!
500         |     0       |     0      | Timer wrapped, SCL falls, next bit
```

This generates a perfect 50% duty cycle 100 kHz clock.

---

### 5.4 What Goes Wrong: Bug #9 — SCL Stuck LOW

According to BUG_REPORT.md, the original code drove `scl_o <= 1'b0` in BOTH
branches of the timer comparison. The effect:

```
BUGGY CODE (what it looked like before the fix):
STATE_TX_BIT: begin
  if (!timer_expired)
    scl_o <= 1'b0;   // During LOW phase: correct
  else
    scl_o <= 1'b0;   // During HIGH phase: WRONG! Should be 1'b1
end
```

Result on the waveform:
```
SCL (buggy):  _____________________________________ (permanently LOW)
SDA:          ‾‾‾\______/‾‾\______/‾\______/‾‾‾‾ (data shifts, nobody cares)
```

The slave waits for SCL to go HIGH to sample data. SCL never goes HIGH. The
slave sees... nothing. The bus appears frozen. In simulation, you would see the
master state machine advancing (TX_BIT → TX_BIT → ... → ACK_WAIT) but no
actual data transfer occurring. The slave stays silent.

**How does a verification engineer find this bug?**
1. Write a test that performs a WRITE transaction
2. Check that SCL has the correct frequency (100 kHz)
3. The assertion `assert property (@(posedge clk) state==STATE_TX_BIT |-> ##[1:500] scl_o == 1'b1)` would fire immediately
4. Or look at the waveform: SCL stuck LOW in TX_BIT is immediately obvious

---

<a name="part-6"></a>
## Part 6: The Shift Register — Data Transmission

### 6.1 What Is a Shift Register?

A shift register is a chain of flip-flops where data moves left or right by
one position every clock cycle. It converts between parallel data (8 bits at
once) and serial data (1 bit at a time).

```
Parallel data: [b7][b6][b5][b4][b3][b2][b1][b0] = 0xA5 = 10100101

After 1 shift left: [b6][b5][b4][b3][b2][b1][b0][0]
After 2 shifts:     [b5][b4][b3][b2][b1][b0][ 0][0]
...
After 8 shifts:     [ 0][ 0][ 0][ 0][ 0][ 0][ 0][0]  (all bits transmitted)
```

The bit on the bus at any moment is `shift_reg[7]` — the MSB. As bits are
transmitted, the register shifts left, promoting the next bit to position [7].

---

### 6.2 TX: Shifting Out Bits MSB-First

The shift register logic for transmission (lines 312-315):

```systemverilog
else if (state == STATE_TX_BIT && timer_expired) begin
  shift_reg <= {shift_reg[6:0], 1'b0};  // Shift left, fill 0 at LSB
end
```

And the SDA output reads the MSB (line 278):
```systemverilog
STATE_TX_BIT: sda_o <= shift_reg[7];
```

Trace for byte 0xA5 = 8'b10100101:

```
Initial:  shift_reg = 10100101  →  SDA drives bit 7 = 1
After shift 1: shift_reg = 01001010  →  SDA drives bit 7 = 0
After shift 2: shift_reg = 10010100  →  SDA drives bit 7 = 1
After shift 3: shift_reg = 00101000  →  SDA drives bit 7 = 0
After shift 4: shift_reg = 01010000  →  SDA drives bit 7 = 0
After shift 5: shift_reg = 10100000  →  SDA drives bit 7 = 1
After shift 6: shift_reg = 01000000  →  SDA drives bit 7 = 0
After shift 7: shift_reg = 10000000  →  SDA drives bit 7 = 1
(8th bit transmitted, now go to ACK_WAIT)
```

Bus sequence: 1, 0, 1, 0, 0, 1, 0, 1 = 0xA5 (MSB first). Correct!

---

### 6.3 RX: Shifting In Bits MSB-First

During reception (lines 309-311):

```systemverilog
else if (state == STATE_RX_BIT && scl_rise) begin
  shift_reg <= {shift_reg[6:0], sda_i};  // Shift left, MSB arrives first
end
```

Wait — we shift LEFT and put new data in the LSB position (sda_i goes to [0]).
But the first bit received is the MSB of the data byte. How does this work?

After receiving all 8 bits of byte 0xA5 (1,0,1,0,0,1,0,1 on the bus):

```
Start:    shift_reg = 00000000
After bit 7 (MSB=1): shift_reg = 00000001
After bit 6 (0):     shift_reg = 00000010
After bit 5 (1):     shift_reg = 00000101
After bit 4 (0):     shift_reg = 00001010
After bit 3 (0):     shift_reg = 00010100
After bit 2 (1):     shift_reg = 00101001
After bit 1 (0):     shift_reg = 01010010
After bit 0 (LSB=1): shift_reg = 10100101  ← This is 0xA5! Correct!
```

The math works because each new bit pushes previous bits one position to the
left. After 8 bits, they are in the correct MSB-to-LSB order.

---

### 6.4 The Bit Counter

The 3-bit counter `bit_cnt` tracks which bit we are on (lines 108, 489-499):

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)
    bit_cnt <= 3'd0;
  else begin
    if (next_state != state)
      bit_cnt <= 3'd0;   // Reset on ANY state transition
    else if ((state == STATE_TX_BIT || state == STATE_RX_BIT) && timer_done)
      bit_cnt <= bit_cnt + 1'b1;
  end
end
```

The counter goes: 0, 1, 2, 3, 4, 5, 6, 7, then the FSM checks:

```systemverilog
if (bit_cnt == 3'd7) → go to ACK phase
else                 → stay in TX_BIT/RX_BIT (bit_cnt will increment to next)
```

After incrementing to 7, on the NEXT `timer_done`, the FSM exits. So the
bit_cnt sequence is: 0→1→2→3→4→5→6→7→(exit to ACK). That is 8 bits total.

> **SENIOR ENGINEER TIP:**
> Note that bit_cnt starts at 0 (the MSB). Bit 0 in the counter corresponds
> to bit 7 in the data byte (MSB first). This is a common source of off-by-one
> confusion. When bit_cnt == 7, we have transmitted the 8th bit (the LSB of
> the data). The next ACK phase is bit 9 of the I2C transaction.

---

### 6.5 Bug #10: The Missing Data Path — shift_reg Never Reaches CPU

**The problem setup:**
CPU does: WRITE REG_DATA with 0x3F → WRITE REG_CMD with CMD_WRITE → (waits)
→ READ REG_DATA expecting to get back some received byte

But wait — for a WRITE operation, the CPU wrote 0x3F into `reg_data_buf`.
The shift register loads it (line 305):
```systemverilog
if (cpu_wr && (cpu_addr == REG_DATA))
  shift_reg <= cpu_wdata;
```

That works fine for TX. Now for RX:

CPU does: WRITE REG_CMD with CMD_READ_ACK → (waits for done) → READ REG_DATA

Without the fix, the flow was:
1. SCL clocking in bits → shift_reg accumulates received byte
2. bit_cnt reaches 7 → FSM exits to ACK_SEND
3. CPU reads REG_DATA → reads `reg_data_buf`
4. `reg_data_buf` was LAST WRITTEN by the CPU (when it originally set up TX data)
5. CPU gets the old TX value, NOT the received byte!

The fix adds a bridge at the exact moment of the state transition:
```systemverilog
if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND) begin
  reg_data_buf <= shift_reg;   // Capture received byte for CPU
end
```

**Why check `next_state` instead of just waiting?**
Because the shift register is still being used. We want to capture it at the
LAST moment before the state changes. The condition `state == RX_BIT && next_state == ACK_SEND` is TRUE for exactly one clock cycle — the cycle when
bit_cnt == 7 and timer_done fires. At that point, shift_reg[7:0] contains
the fully received byte. Perfect timing.

**How did we spot this bug in the testbench?**
The scoreboard compared expected vs. received data:
```
SCOREBOARD: Expected RX byte = 0xA5
SCOREBOARD: Actual RX byte   = 0x3F  (the old TX data!)
ERROR: Data mismatch on read transaction!
```

The "0x3F" is the giveaway — it is whatever the CPU last wrote for TX,
which proves that `reg_data_buf` was never updated from the RX shift register.

---

<a name="part-7"></a>
## Part 7: The CPU Interface (Host Interface)

### 7.1 How the CPU Controls the Master

The master exposes a simple register map. Think of it as a tiny set of hardware
controls that any processor can write to. Here is the typical sequence a CPU
follows to perform an I2C WRITE transaction to slave address 0x50:

```
Step 1: CPU writes REG_ADDR = (0x50 << 1) | 0   // Address + Write bit
Step 2: CPU writes REG_DATA = 0xAB               // Data byte to send
Step 3: CPU writes REG_CMD  = CMD_START (0x01)   // Generate START
Step 4: Wait for busy = 0 or poll REG_STATUS
Step 5: CPU writes REG_CMD  = CMD_WRITE (0x03)   // Send REG_ADDR byte
Step 6: Wait for ack output or poll REG_STATUS
Step 7: CPU writes REG_DATA = 0xAB               // Load data
Step 8: CPU writes REG_CMD  = CMD_WRITE (0x03)   // Send data byte
Step 9: CPU writes REG_CMD  = CMD_STOP  (0x02)   // Generate STOP
Step 10: Wait for done pulse or cpu_irq
```

---

### 7.2 The Register Write Block (Lines 132-166)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    reg_data_buf <= 8'h00;   // All registers initialize to 0
    ...
    cmd_valid    <= 1'b0;
  end else begin
    if (cpu_wr) begin
      case (cpu_addr)
        REG_DATA:   reg_data_buf <= cpu_wdata;   // Store TX data
        REG_ADDR:   reg_addr     <= cpu_wdata;   // Store slave address
        REG_CTRL:   reg_ctrl     <= cpu_wdata;   // Control settings
        REG_CMD:    reg_cmd      <= cpu_wdata;   // Command to execute
        REG_IRQ_EN: reg_irq_en   <= cpu_wdata;   // IRQ enables
        default:    ;
      endcase
    end
    ...
    if (cpu_wr && (cpu_addr == REG_CMD))
      cmd_valid <= 1'b1;   // ONE-CYCLE pulse when CMD is written
    else
      cmd_valid <= 1'b0;
  end
end
```

**The `cmd_valid` pulse mechanism is critical.**
When CPU writes `REG_CMD`, `cmd_valid` goes HIGH for exactly ONE clock cycle.
The FSM in `always_comb` sees this and computes `next_state = STATE_START_1`
(or whatever the command requires). On the next clock edge, the `always_ff`
registers this as `state <= next_state`. The command has fired.

Notice also the RX data capture at lines 155-157 (Bug #10 fix):
```systemverilog
if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND) begin
  reg_data_buf <= shift_reg;   // Override CPU's write with RX data
end
```

This is in the SAME `always_ff` block as the CPU write logic. Both can write
`reg_data_buf`. In SystemVerilog, the LAST assignment in an `always` block
wins. Since the `if (state == STATE_RX_BIT && ...)` check comes AFTER the
`if (cpu_wr)` block, the RX capture takes priority when both happen
simultaneously (which would be a strange edge case anyway).

---

### 7.3 The Register Read Block (Lines 169-179)

```systemverilog
always_comb begin
  case (cpu_addr)
    REG_CTRL:   cpu_rdata = reg_ctrl;
    REG_STATUS: cpu_rdata = reg_status;
    REG_DATA:   cpu_rdata = reg_data_buf;
    REG_ADDR:   cpu_rdata = reg_addr;
    REG_IRQ_EN: cpu_rdata = reg_irq_en;
    REG_IRQ_ST: cpu_rdata = reg_status;    // Both read from reg_status
    default:    cpu_rdata = 8'h00;
  endcase
end
```

This is pure combinational logic. It responds to `cpu_addr` immediately —
no clock delay. This means:
- CPU puts `cpu_addr` on the bus
- Same clock cycle: `cpu_rdata` reflects the register content
- CPU's synchronous read flop captures `cpu_rdata` on the next edge

Notice `REG_IRQ_ST` also reads `reg_status`. Normally interrupt status registers
are "read-to-clear" (W1C). This implementation just reads the same value as
status, which is simpler but less flexible.

---

### 7.4 Why Non-Blocking Assignment (<=) Matters Here

In the `always_ff` block, ALL assignments use `<=` (non-blocking). This is
the fundamental rule of synchronous RTL: in `always_ff`, ALWAYS use `<=`.

**What `<=` means (simplified):**
1. ALL right-hand sides (RHS) are evaluated using the CURRENT values
2. ALL left-hand sides (LHS) are updated SIMULTANEOUSLY at the clock edge

**Concrete example from this RTL:**
Imagine at time T, `state = STATE_TX_BIT` and `timer_expired = 1`:

```systemverilog
// In the sequential state machine block:
state <= next_state;   // RHS reads next_state (computed by always_comb)
busy  <= (next_state != STATE_IDLE);  // RHS reads next_state
done  <= (state == STATE_STOP_2 && next_state == STATE_IDLE);  // reads BOTH
```

With non-blocking:
- `state`, `busy`, `done` are all evaluated BEFORE any of them update
- They all update together at the end of the clock edge
- `done` correctly reads the OLD value of `state` (STATE_TX_BIT, not
  whatever `state` might become)

If you used blocking (`=`):
```systemverilog
state = next_state;    // state is NOW STATE_ACK_WAIT (updated immediately!)
done  = (state == STATE_STOP_2 && next_state == STATE_IDLE);  // reads NEW state!
```
`done` would see `state == STATE_ACK_WAIT` instead of `STATE_TX_BIT`. Completely wrong.

> **SENIOR ENGINEER TIP:**
> The rule is absolute. Memorize it:
> - `always_ff` block? → Use `<=` (non-blocking) for ALL assignments
> - `always_comb` block? → Use `=` (blocking) for ALL assignments
> - NEVER mix them in the same block
> - NEVER use `<=` in `always_comb` (creates latches or synthesis mismatch)
> - NEVER use `=` in `always_ff` (causes simulation/synthesis mismatch)

---

<a name="part-8"></a>
## Part 8: Bug #8 and #9 Deep Dive — Critical RTL Bugs

### 8.1 Bug #8: Multi-Driver on `next_state`

**What is a multi-driver?**

In digital circuits, a wire can only have ONE driver. If two outputs are
connected to the same wire, the stronger one wins — but in RTL, two always
blocks driving the same signal creates an ILLEGAL situation that prevents
synthesis and causes simulation X (unknown) values.

**How Bug #8 happened:**

Before the fix, the RTL had something like this:

```systemverilog
// BUGGY: next_state driven in the sequential always_ff block
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)
    state <= STATE_IDLE;
  else begin
    state      <= next_state;      // Correct
    next_state <= STATE_IDLE;      // WRONG: driving next_state here too!
    // ... other assignments that set next_state based on conditions
  end
end

// ALSO WRONG: next_state also driven in always_comb
always_comb begin
  next_state = state;             // Multi-driver conflict!
  case (state)
    ...
  endcase
end
```

**Why is this illegal in SystemVerilog synthesis?**

The `always_ff` block creates FLIP-FLOPS for every signal it drives with `<=`.
The `always_comb` block creates COMBINATIONAL LOGIC for every signal it drives
with `=`. If both drive `next_state`:

- `always_ff` creates a flip-flop for `next_state` (clocked)
- `always_comb` creates combinational logic for `next_state` (not clocked)
- The synthesis tool cannot connect BOTH outputs to the same wire
- Result: synthesis error "multiple drivers on net next_state"

In simulation, SystemVerilog resolves multi-driver conflicts using 4-state
logic resolution: if one driver says '0' and another says '1', the result is
'X' (unknown). The FSM would immediately go X and stay there. Simulation would
fail catastrophically.

**The fix:**

Remove ALL `next_state` assignments from the `always_ff` block. The `always_ff`
only does `state <= next_state`. All next-state logic lives exclusively in the
`always_comb` block. See the fixed code at lines 326-360 (sequential) and
366-473 (combinational).

```
BUG #8 — THE GOLDEN RULE:
  next_state → driven ONLY by always_comb
  state      → driven ONLY by always_ff (as: state <= next_state)
```

---

### 8.2 Bug #9: SCL Permanently LOW — Full Autopsy

**Background:** This bug meant the master was completely non-functional.
Every single I2C transaction would hang forever because the slave never saw
a clock.

**The buggy timer comparison logic (reconstructed from bug report):**

```systemverilog
// BUGGY SCL generation for STATE_TX_BIT
STATE_TX_BIT: begin
  if (!timer_expired) begin
    scl_o <= 1'b0;   // During active counting: SCL LOW (correct for first half)
  end else begin
    scl_o <= 1'b0;   // Timer expired: SCL stays LOW (WRONG! Should pulse HIGH)
  end
end
```

The root cause is thinking about the timer incorrectly. The original developer
probably thought: "When the timer expires, toggle and reset." But `timer_expired`
is only HIGH for ONE cycle. In that one cycle, the SCL needed to go HIGH,
but the code drove it LOW.

Actually, looking at the bug report more carefully — both the "not expired" and
"expired" branches drove `scl_o <= 1'b0`. This means SCL was driven LOW for
ALL 500 ticks of every bit period. It never went high.

**The correct mental model (the fix):**

```systemverilog
// CORRECT SCL generation — timer value directly controls the phase
STATE_TX_BIT: begin
  if (timer < T_SCL_LOW)                        // Ticks 0-249: LOW phase
    scl_o <= 1'b0;
  else if (timer < T_SCL_LOW + T_SCL_HIGH)      // Ticks 250-499: HIGH phase
    scl_o <= 1'b1;
  else
    scl_o <= 1'b0;
end
```

Instead of using `timer_expired` as a toggle signal, the fix reads the timer
VALUE directly. The timer value tells us which phase we are in (LOW or HIGH).
This is more robust: the SCL output tracks the timer position every cycle.

**BEFORE vs AFTER:**

```
BEFORE (buggy):
Time:  0   50  100  150  200  250  300  350  400  450  499
SCL:   0   0   0    0    0    0    0    0    0    0    0
       (NEVER goes high — slave sees nothing)

AFTER (fixed):
Time:  0   50  100  150  200  250  300  350  400  450  499
SCL:   0   0   0    0    0    1    1    1    1    1    1
               (250 ticks LOW)     (250 ticks HIGH)
```

**In waveform form:**
```
BUGGY SCL:  _______________________________________________ (stuck low)
FIXED SCL:  _____________|‾‾‾‾‾‾‾‾‾‾‾‾‾|_____________|‾‾‾
             250 ticks    250 ticks      250 ticks     ...
```

**How to find this bug in simulation:**
1. Write a directed test: write a byte, check SCL waveform
2. Assert: `assert property (@(posedge clk) state==STATE_TX_BIT |-> ##250 $rose(scl_o))`
3. This property says: while in TX_BIT state, within 250 ticks, SCL must rise
4. With the bug, this fails immediately: SCL never rises, assertion triggers

---

<a name="part-9"></a>
## Part 9: Non-Blocking Assignment Trap

### 9.1 The Core Concept: RHS Before LHS

In SystemVerilog, non-blocking assignments in `always_ff` blocks work in two phases:

```
PHASE 1 (RHS evaluation): All right-hand sides computed using CURRENT flip-flop values
PHASE 2 (LHS update):     All left-hand sides updated simultaneously at clock edge
```

This is NOT how blocking (`=`) assignment works in regular software. In C, if
you write `a = b; b = a + 1;`, the second line sees the new value of `a`. In
RTL `always_ff` with `<=`, that NEVER happens — every RHS reads the value from
BEFORE the clock edge.

### 9.2 Concrete Example from This RTL

The shift register during RX (line 310):

```systemverilog
shift_reg <= {shift_reg[6:0], sda_i};
```

At clock edge where `scl_rise = 1` and `state = STATE_RX_BIT`:

- RHS: `{shift_reg[6:0], sda_i}` — reads the CURRENT shift_reg (before update)
  and appends the CURRENT sda_i
- LHS: `shift_reg` — will be updated AFTER this evaluation

So if `shift_reg = 8'b01010100` and `sda_i = 1`:
- RHS = `{7'b1010100, 1'b1}` = `8'b10101001`
- shift_reg becomes `8'b10101001` at the clock edge

This is correct. The new bit is appended, and the result does NOT read the
new shift_reg value before it is ready.

### 9.3 The Trap: Reading a Signal You Just Wrote in the Same Block

**Dangerous pattern (hypothetical):**

```systemverilog
always_ff @(posedge clk) begin
  shift_reg <= {shift_reg[6:0], sda_i};   // Non-blocking
  sda_o     <= shift_reg[7];               // Reads shift_reg — but which value?
end
```

With non-blocking, `sda_o` reads the OLD value of `shift_reg` (before the
shift). This means `sda_o` drives the bit that was in position [7] BEFORE
the shift — which is the correct bit to transmit!

But if someone "fixes" this to use blocking assignments:

```systemverilog
// WRONG: mixing blocking in always_ff
always_ff @(posedge clk) begin
  shift_reg = {shift_reg[6:0], sda_i};   // Blocking: shift_reg updates NOW
  sda_o     <= shift_reg[7];              // Reads the NEW shift_reg[7]!
end
```

Now `sda_o` drives `shift_reg[6]` (the OLD bit at position 6), not `shift_reg[7]`
(the OLD MSB). The data on the bus is off by one position. Every byte would
be corrupted.

**The fix is to never use blocking (`=`) in `always_ff` blocks. Ever.**

### 9.4 Why the Actual Code Avoids the Trap

In the actual RTL, `sda_o` is driven by a SEPARATE `always_ff` block (lines
270-293). It reads `shift_reg[7]` independently:

```systemverilog
// This is a DIFFERENT always_ff block
always_ff @(posedge clk or negedge rst_n) begin
  ...
  STATE_TX_BIT: sda_o <= shift_reg[7];   // Reads current shift_reg
  ...
end
```

This separate block reads `shift_reg` from the output of its flip-flop (the
CURRENT value). The shift register block simultaneously writes a new value to
`shift_reg`. Both operations happen at the same clock edge. The `sda_o` update
uses the OLD `shift_reg[7]` — correct behavior.

This is the beauty of the two-block structure: blocks are independent. No
cross-contamination of values within a clock cycle.

---

<a name="part-10"></a>
## Part 10: Interview Questions — Master Controller

### Q1: Why use a two-always-block FSM instead of one?

**Answer:** The two-always-block pattern separates registered state from
combinational next-state logic. The `always_ff` block is a simple D flip-flop:
`state <= next_state`. The `always_comb` block computes `next_state` from `state`
and inputs. This separation provides:

1. **No multi-driver risk:** `next_state` has exactly one driver (the comb block)
2. **Clean synthesis:** Synthesis tools can optimize each block independently
3. **Readable RTL:** State storage is obviously separate from state transitions
4. **Easier assertions:** You can assert on both `state` (current) and `next_state`
   (predicted future) simultaneously

The one-block FSM puts everything in `always_ff`, making next-state logic
effectively synthesize with an extra layer of flip-flops, which is usually
wrong and always harder to debug.

---

### Q2: How do you generate exactly 100 kHz SCL from a 50 MHz clock?

**Answer:** Use a timer counter. The SCL period at 100 kHz is 10 microseconds.
At 50 MHz, one clock tick is 20 nanoseconds. So:

```
Ticks per SCL period = 10,000 ns / 20 ns = 500 ticks
```

A 9-bit counter (`$clog2(500) = 9`) counts from 0 to 499 and wraps. Within
each period, the first 250 ticks drive SCL LOW and the last 250 ticks drive
SCL HIGH. The SCL output is a pure combinational function of the timer value:
`scl_o = (timer >= T_SCL_LOW)`.

For Fast Mode (400 kHz): `T_SCL_PERIOD = 125`, `T_SCL_HIGH = 50`, `T_SCL_LOW = 75`
(Fast Mode requires asymmetric duty cycle: min 0.6 us HIGH, min 1.3 us LOW).

---

### Q3: Why does the shift register shift left for both TX and RX?

**Answer:** I2C sends data MSB-first. For TX, we want to send `shift_reg[7]`
first. After each bit is sent, we shift left: the next-most-significant bit
promotes to position [7]. For RX, each incoming bit (MSB first) is inserted
at `shift_reg[0]`, and previously captured bits shift left. After 8 bits,
the first received bit (MSB) has been shifted 7 times to land at position [7],
while the last received bit (LSB) stays at position [0]. The byte is correctly
assembled in natural MSB-to-LSB order.

---

### Q4: What is the difference between ACK and NACK in I2C?

**Answer:** Both occur on the 9th SCL clock of an 8-bit transfer.

- **ACK (Acknowledge):** Receiver pulls SDA LOW. Meaning: "I received the byte successfully, continue."
- **NACK (Not Acknowledge):** Receiver releases SDA (HIGH via pull-up). Meaning: "Error, or I am done receiving."

When the master writes (TX):
- Slave sends ACK → transaction continues
- Slave sends NACK → master aborts with STOP

When the master reads (RX):
- Master sends ACK → slave sends another byte
- Master sends NACK → slave stops driving, transaction ending

The master ALWAYS drives ACK/NACK during RX. The slave ALWAYS drives ACK/NACK
during TX. Never the reverse.

---

### Q5: What does the `timer_clr` signal do and why is it important?

**Answer:** `timer_clr = (state != next_state)` — it clears the timer whenever
the FSM changes state. This is critical because each state needs its OWN full
T_SCL_PERIOD of timing. Without clearing, the timer would be mid-count when a
new state begins, giving the new state a partial period. The SCL timing would
be wrong, violating I2C timing specifications.

By clearing on every state transition, each state gets a fresh 500-tick budget.

---

### Q6: What happens if SCL gets stuck LOW?

**Answer:** This is clock stretching. A slave device can hold SCL LOW to
signal "not ready yet." The master must wait. The design handles this with:

1. `stretch_cnt` counter that increments while `scl_i = 0` and not IDLE (line 214)
2. `timeout = (stretch_cnt >= MAX_CLK_STRETCH)` triggers after 1000 ticks = 20 us
3. The combinational next-state logic checks `timeout` first:
   ```systemverilog
   if (timeout) next_state = STATE_IDLE;  // Escape hatch
   ```
4. `bus_error <= 1'b1` is set when timeout fires

The master abandons the transaction and returns to IDLE. The CPU sees
`bus_error = 1` and should retry or report the error.

---

### Q7: How would you add Fast Mode (400 kHz) support?

**Answer:** I2C Fast Mode requires:
- SCL frequency: 400 kHz → period = 2.5 us = 125 ticks at 50 MHz
- Minimum HIGH time: 0.6 us = 30 ticks
- Minimum LOW time: 1.3 us = 65 ticks

Changes needed:
1. Add a `mode` input (0=Standard, 1=Fast)
2. Add parameters: `T_SCL_PERIOD_FM = 125`, `T_SCL_HIGH_FM = 30`, `T_SCL_LOW_FM = 65`
3. Use a multiplexer in the timer compare: select between standard and fast parameters
4. Resize the timer: `$clog2(500) = 9` bits is sufficient for both (500 > 125)
5. Update setup/hold time parameters accordingly

The FSM states remain identical — only timing parameters change.

---

### Q8: Why does the master sample ACK on `scl_rise` but check timer in state transitions?

**Answer:** These serve different purposes.

`scl_rise` is used for ACK sampling (line 479) because the I2C spec says data
is valid on the rising edge of SCL. The slave drives SDA at any point during
SCL LOW and it must be stable by SCL rising. Sampling on `scl_rise` correctly
follows the spec regardless of any clock stretching.

`timer_done` is used for state transitions because the master needs to know when
its own SCL period is complete before advancing to the next bit or state. This
is about the master's OWN timing, not the slave's data validity.

Separating these concerns makes the design robust: ACK detection is edge-based
(protocol accurate), state advancement is timer-based (self-clocked).

---

### Q9: What is the purpose of `REP_START` vs. STOP followed by START?

**Answer:** Repeated START (Sr) keeps the master in control of the bus between
transactions. A STOP condition releases the bus — any other master could claim
it. A Repeated START does not release the bus.

Common use case: Reading a register from a temperature sensor
1. Write sensor address + WRITE bit
2. Write register address byte (e.g., 0x01 = temperature register)
3. **Repeated START** (instead of STOP + START)
4. Write sensor address + READ bit
5. Read 2 bytes of temperature data
6. NACK + STOP

If you used STOP + START, another master on the bus could claim the bus between
steps 3 and 4, and the sensor might lose track of which register you wanted.

---

### Q10: What would happen if `sda_o` were driven HIGH during ACK_WAIT?

**Answer:** This is exactly what the design does — and it is correct! In
`STATE_ACK_WAIT`, the master releases SDA by driving `sda_o = 1`:

```systemverilog
STATE_ACK_WAIT: sda_o <= 1'b1;   // Release SDA
```

Because of the tri-state assignment, `sda_o = 1` means the master drives `sda = Z`
(high-impedance). The pull-up resistor pulls the bus HIGH. Now the slave can
pull SDA LOW for ACK. If the master had driven `sda_o = 0`, it would be forcing
SDA LOW and the slave could never signal NACK (it would be fighting the master's
LOW driver). Releasing SDA is essential for the slave to respond.

---

### Q11: What assertions would you write for the master controller?

**Answer:** Key assertions:

```systemverilog
// 1. START condition: SDA must fall while SCL is high
property p_start_cond;
  @(posedge clk) $fell(sda) |-> scl_i == 1'b1;
endproperty
assert property (p_start_cond);

// 2. STOP condition: SDA must rise while SCL is high
property p_stop_cond;
  @(posedge clk) $rose(sda) |-> scl_i == 1'b1;
endproperty
assert property (p_stop_cond);

// 3. Data stability: SDA must not change while SCL is HIGH (except START/STOP)
// (Complex — requires excluding transition states)

// 4. After STOP_2, done must pulse exactly once
property p_done_pulse;
  @(posedge clk) (state == STATE_STOP_2 && next_state == STATE_IDLE) |=>
    (done == 1'b1) ##1 (done == 1'b0);
endproperty
assert property (p_done_pulse);

// 5. Busy must be high whenever not IDLE
property p_busy_not_idle;
  @(posedge clk) (state != STATE_IDLE) |-> (busy == 1'b1);
endproperty
assert property (p_busy_not_idle);

// 6. SCL must toggle during TX_BIT (catch Bug #9)
property p_scl_toggles_in_tx;
  @(posedge clk) (state == STATE_TX_BIT) |-> ##[1:500] $rose(scl_o);
endproperty
assert property (p_scl_toggles_in_tx);

// 7. ACK/NACK mutual exclusion
property p_ack_nack_mutex;
  @(posedge clk) not (ack == 1'b1 && nack == 1'b1);
endproperty
assert property (p_ack_nack_mutex);
```

---

### Q12: How does `cpu_irq` work, and when would you use it vs. polling?

**Answer:** `cpu_irq` is an interrupt line (line 517-527):

```systemverilog
cpu_irq <= |({reg_irq_en[0] & done,
              reg_irq_en[1] & ack,
              reg_irq_en[2] & nack,
              reg_irq_en[3] & timeout,
              reg_irq_en[4] & bus_error});
```

The CPU enables specific interrupt sources by writing bits to `REG_IRQ_EN`.
When any enabled event occurs, `cpu_irq` goes HIGH. The CPU's interrupt
controller sees this and vectors to the I2C interrupt service routine (ISR).

**Polling** (checking `REG_STATUS` in a loop): Simple but wastes CPU cycles.
Use for very fast I2C transactions or in bare-metal simple systems.

**Interrupt-driven**: CPU continues other work while I2C transfer runs. When
the transfer completes, the ISR is invoked. Required for RTOS-based systems or
when I2C transactions are long (1000+ bytes).

For this design, set `REG_IRQ_EN[0] = 1` to interrupt on `done`. The ISR reads
`REG_DATA` if this was a read transaction.

---

### Q13: The `current_cmd` is derived combinationally from `reg_cmd`. What is the danger?

**Answer:** `current_cmd = i2c_cmd_e'(reg_cmd[3:0])` at line 182 is purely
combinational. `reg_cmd` is a registered value (flip-flop), so it is stable.
The danger occurs if `cpu_wr && cpu_addr == REG_CMD` happens WHILE the FSM is
not in IDLE. In that case, `reg_cmd` updates immediately, and `current_cmd`
changes mid-transaction.

However, `cmd_valid` (the signal that actually triggers the FSM) is only checked
in STATE_IDLE. So even if `current_cmd` changes mid-transaction, the FSM will
not be affected until it returns to IDLE and `cmd_valid` fires again with the
new command in `reg_cmd`.

This is an implicit "last write wins" command register. It is acceptable for
simple designs but a FIFO-based command queue would be more robust.

---

### Q14: Why does `busy` use `next_state` instead of `state`?

**Answer:**
```systemverilog
busy <= (next_state != STATE_IDLE);
```

This makes `busy` predictive: it goes HIGH one cycle BEFORE the FSM actually
enters a non-IDLE state, and goes LOW one cycle BEFORE returning to IDLE. This
gives the CPU an early warning. The `done` signal (line 342) uses the same
pattern:

```systemverilog
done <= (state == STATE_STOP_2 && next_state == STATE_IDLE);
```

`done` fires in the last cycle of STOP_2 — the cycle BEFORE the FSM registers
itself as IDLE. This means when the CPU sees `done = 1`, the FSM is still
technically in STOP_2. One cycle later, `state = IDLE` and `busy = 0`.

This is a common optimization: "pre-decode" the status signals so they are
ready exactly when the CPU needs them, without an extra clock of latency.

---

### Q15: What would you change to make this master support 10-bit addressing?

**Answer:** I2C 10-bit addressing uses a two-byte address sequence:
- Byte 1: `11110xx1` (where `xx` = upper 2 bits of 10-bit address, `1` = write start)
- Byte 2: Lower 8 bits of address
- For reads: Repeated START, then `11110xx1` again with R/W=1

Changes needed:
1. `REG_ADDR` is currently 8 bits. Need to extend to 16 bits or add `REG_ADDR_HI`
2. Add a `addr_mode` bit in `REG_CTRL` (0=7-bit, 1=10-bit)
3. In the firmware driver: detect 10-bit mode and issue the two-byte sequence
   manually (CMD_WRITE the first address byte, CMD_WRITE the second address byte)
4. Alternatively: add a hardware state `STATE_TX_ADDR2` that automatically sends
   the second address byte when 10-bit mode is selected

The RTL FSM itself does not need fundamental changes — 10-bit addressing just
requires two consecutive CMD_WRITE operations at the driver level, which the
existing design already supports.

---

## Appendix A: Waveform Summary — Complete I2C Write Transaction

```
Byte: 0xA5 (10100101) to slave address 0x50 (Write transaction)

CPU Actions:
  Write REG_ADDR = 0xA0 (0x50<<1 | 0)
  Write REG_DATA = 0xA5
  Write REG_CMD  = CMD_START
  Write REG_CMD  = CMD_WRITE (address byte 0xA0)
  Write REG_CMD  = CMD_WRITE (data byte 0xA5)
  Write REG_CMD  = CMD_STOP

Bus Waveform:
     [S]  [ ADDRESS 0xA0 = 10100000 ]  [A]  [ DATA 0xA5 = 10100101 ]  [A]  [P]
SDA: \___  1 0 1 0 0 0 0 0             \    1 0 1 0 0 1 0 1           \    /
          ‾ ‾ ‾ ‾ ‾ ‾ ‾ ‾                   ‾ ‾ ‾ ‾ ‾ ‾ ‾ ‾
SCL:     |_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_

State: IDLE → S1 → S2 → [TX x8 ] → AW → [TX x8] → AW → STOP1 → STOP2 → IDLE
```

---

## Appendix B: Register Map Quick Reference

| Address | Name | Access | Description |
|---------|------|--------|-------------|
| 3'h0 | REG_CTRL | R/W | Bit[0]: Enable, Bit[1]: Mode |
| 3'h1 | REG_CMD | W | Write command opcode |
| 3'h2 | REG_STATUS | R | Current status (STS_IDLE/BUSY/DONE/etc.) |
| 3'h3 | REG_DATA | R/W | TX: write byte here. RX: read received byte |
| 3'h4 | REG_ADDR | R/W | Slave address byte [7:1]=addr, [0]=R/W |
| 3'h5 | REG_IRQ_EN | R/W | Bit mask enabling interrupt sources |
| 3'h6 | REG_IRQ_ST | R | Read returns current status (same as REG_STATUS) |

---

## Appendix C: Command Opcode Summary

| Command | Value | What Happens |
|---------|-------|-------------|
| CMD_NOP | 0x0 | Nothing |
| CMD_START | 0x1 | Generate START condition → STATE_START_1 |
| CMD_STOP | 0x2 | Generate STOP condition → STATE_STOP_1 |
| CMD_WRITE | 0x3 | Transmit shift_reg, wait for ACK → STATE_TX_BIT |
| CMD_READ_ACK | 0x4 | Receive byte, send ACK → STATE_RX_BIT |
| CMD_READ_NACK | 0x5 | Receive byte, send NACK (last) → STATE_RX_BIT |
| CMD_REP_START | 0x6 | Repeated START → STATE_REP_START_1 |
| CMD_ABORT | 0x7 | (Not implemented in FSM — falls to default IDLE) |

---

## Appendix D: Summary of Bugs in Master Controller

| Bug | Root Cause | Effect | Key Lesson |
|-----|-----------|--------|-----------|
| #8 | `next_state` driven by two always blocks | Synthesis error, simulation X | Each net has ONE driver |
| #9 | SCL timer comparison wrong | SCL stuck LOW, no data transfer | Verify clock generation first |
| #10 | `shift_reg` → `reg_data_buf` path missing | CPU reads 0x00 after every RX | Trace every data path end-to-end |

---

*This document was written for intern mentorship purposes. It covers every
aspect of `rtl/i2c_master_controller.sv` from first principles to interview
level. Refer to `rtl/i2c_pkg.sv` for parameter values and `docs/BUG_REPORT.md`
for full bug details.*
