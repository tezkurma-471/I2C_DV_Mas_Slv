# 03 — RTL Slave Controller: Deep Dive

**Document series**: Summer Internship — I2C Protocol DV  
**Audience**: Interns learning RTL analysis and digital verification  
**Source file**: `rtl/i2c_slave_controller.sv` (FIXED version)  
**Package file**: `rtl/i2c_pkg.sv`  
**Bug reference**: `docs/BUG_REPORT.md`  
**Date**: 2026-05-12

---

## Table of Contents

1. [Slave vs Master — Key Conceptual Differences](#part-1-slave-vs-master)
2. [Port Analysis — Every Signal Explained](#part-2-port-analysis)
3. [START/STOP Detection — The Hardest Part](#part-3-startstop-detection)
4. [The 10-State FSM — Every State Explained](#part-4-the-10-state-fsm)
5. [The RX Shift Register — Receiving Data](#part-5-the-rx-shift-register)
6. [The TX Shift Register — Transmitting Data](#part-6-the-tx-shift-register)
7. [Address Recognition](#part-7-address-recognition)
8. [Clock Stretching Deep Dive](#part-8-clock-stretching-deep-dive)
9. [The force_data_nack Test Hook](#part-9-the-force_data_nack-test-hook)
10. [The BUG #15 Dead Code Story](#part-10-the-bug-15-dead-code-story)
11. [Internal Register Bank](#part-11-internal-register-bank)
12. [Interview Questions — Slave Controller](#part-12-interview-questions)
13. [Synthesis Considerations — What Changes in Real Hardware](#part-13-synthesis-considerations)
14. [Verification Plan for the Slave Controller](#part-14-verification-plan)
15. [How to Debug the Slave Controller in Simulation](#part-15-debugging-guide)
16. [Comparing This Design to a Real-World I2C Slave](#part-16-real-world-comparison)

---

## How to Use This Document

Before we start, a note on **how senior engineers read RTL**. When you open a new Verilog or SystemVerilog file, your process should not be "read line 1, then line 2." It should be:

1. **Read the module header** — what are the ports? What is the interface contract?
2. **Find the FSM** — almost every controller has one. Understand the states.
3. **Find the data path** — how does data flow from input ports through registers to output ports?
4. **Find the control signals** — what drives the FSM transitions?
5. **Look for resets and edge cases** — what happens on reset? On error?

This document walks you through exactly that process for `i2c_slave_controller.sv`. Every time you see "When I see this code, my first question is..." — that is the senior engineering mindset. Train yourself to think that way.

---

## Part 1: Slave vs Master — Key Conceptual Differences

### 1.1 The Master Is the Boss — The Slave Just Responds

The most important thing to understand about I2C is the **asymmetry** between master and slave.

The **master**:
- Generates the clock (SCL)
- Decides when transactions start (generates START condition)
- Decides when transactions end (generates STOP condition)
- Initiates all data transfers — even when it "reads" from a slave, it is the one clocking the bits out

The **slave**:
- Does NOT generate SCL — it only listens
- Has no concept of time on its own — it wakes up when it sees a START
- Must detect START and STOP conditions by watching SDA change while SCL is HIGH
- Can only "respond" — it cannot initiate

**Why does this matter for RTL design?**

The master has a relatively straightforward job: it has a clock divider, it knows exactly when to drive SDA, it knows when SCL should be high. Everything is predictable.

The slave's job is fundamentally **reactive**. It cannot predict when the master will start. It cannot predict when a bit will arrive. Every single action the slave takes is a direct response to something it observed on the bus.

This means the slave's FSM is driven by **events** (START, STOP, SCL rising edge, SCL falling edge) rather than timers.

### 1.2 The Slave Must Detect START/STOP Asynchronously

This is the hardest part conceptually. Let's think about it carefully.

The system clock (`clk`) runs at 50 MHz. The I2C SCL runs at 100 kHz in standard mode. These are **two independent clocks**. The slave does not know when the master will decide to generate a START condition.

A START condition is defined by the I2C specification as: **SDA falls while SCL is HIGH**.

But the slave's digital logic only "looks" at signals on the rising edge of `clk`. So between two consecutive `clk` edges, SDA could have already gone low and come back up, and the slave would never know.

**The solution**: We sample `sda_i` every `clk` cycle. We keep a one-cycle-delayed copy called `sda_d`. If this cycle `sda_i` is 0 and last cycle `sda_d` was 1, then SDA just fell. If SCL is also high right now, we saw a START.

This is an **edge detector** implemented with a 1-bit shift register. It is the fundamental building block of asynchronous event detection in synchronous digital design.

> **SENIOR ENGINEER TIP**: Every time you need to detect a signal transition in synchronous logic, you will use this pattern: `signal_delayed <= signal; detect = (signal != signal_delayed);` The exact form depends on whether you want rising edge, falling edge, or both.

### 1.3 Address Recognition — "Is This Packet For Me?"

The I2C bus is a shared bus. Multiple slaves can be connected. When the master wants to talk to a specific slave, it broadcasts a 7-bit address after the START condition. Every slave on the bus receives this address byte. Each slave compares it to its own address (set via a hardware parameter). Only the slave whose address matches will respond.

This is exactly like an Ethernet frame — every device on a shared network segment sees every frame, but only the device whose MAC address matches will process it.

In our RTL:
- The slave's address is `SLAVE_ADDR = 7'h50` (a parameter, so it can be changed at instantiation time)
- The received address is `rx_addr` (assembled from the shift register)
- The comparison is `addr_matched = (shift_reg[6:0] == SLAVE_ADDR)`

### 1.4 Clock Stretching — The Slave Can Pause the Master

This is one of the most powerful features of I2C, and it is unique to the slave role.

If a slave is slow (for example, it needs to fetch data from internal flash memory, or it is doing a temperature conversion), it can **hold SCL LOW** after the master has pulled it low. The master, when it wants to release SCL (let it go HIGH for the next bit), samples the SCL line and sees it is still LOW. The master then **waits** — it does not advance.

The slave is literally pausing the master clock. The master can hold on for a bounded time (the `MAX_CLK_STRETCH` parameter in `i2c_pkg.sv` is 1000 clock cycles).

This is called **clock stretching**. The master cannot do this because, by definition, it owns the clock. Only the slave can stretch.

---

## Part 2: Port Analysis — Every Signal Explained

Let us look at the module declaration:

```systemverilog
// Lines 12-43
module i2c_slave_controller
#(
  parameter logic [6:0] SLAVE_ADDR = 7'h50
)
(
  input  logic        clk,
  input  logic        rst_n,

  inout  wire         scl,
  inout  wire         sda,

  output logic [7:0]  reg_bank    [0:7],
  output logic        reg_updated [0:7],
  output logic        addr_match,
  output logic        active,

  input  logic        stretch_en,
  input  logic [15:0] stretch_cycles,
  input  logic        force_data_nack,

  output logic        rx_data_valid,
  output logic [7:0]  rx_data,
  output logic        tx_ack,
  output logic        tx_nack,
  output logic        bus_error
);
```

### 2.1 System Ports

| Port | Direction | Width | Purpose |
|------|-----------|-------|---------|
| `clk` | input | 1-bit | System clock at 50 MHz. All sequential logic clocks on this. |
| `rst_n` | input | 1-bit | Active-LOW reset. When 0, everything goes to its initial state. |

When I see `rst_n`, my first question is: *is this synchronous or asynchronous reset?* Look at the `always_ff` sensitivity list:

```systemverilog
always_ff @(posedge clk or negedge rst_n)
```

The `or negedge rst_n` tells you it is **asynchronous reset**. The reset takes effect immediately when `rst_n` goes low — it does not wait for the next clock edge. This is standard practice for RTL that needs to come out of reset into a known state immediately.

### 2.2 I2C Physical Interface — The Inout Trick

```systemverilog
inout  wire         scl,
inout  wire         sda,
```

These are `inout` ports because the physical I2C bus is a **shared, open-drain wire**. Multiple devices can drive it, but only to LOW. If nobody is driving it LOW, pull-up resistors bring it HIGH.

But inside the RTL, we can't work with `inout` signals conveniently. So the design splits each bidirectional signal into a separate input and output:

```systemverilog
// Lines 52-60
logic sda_o, sda_i;
logic scl_i;
logic scl_o;

assign sda = (sda_o == 1'b0) ? 1'b0 : 1'bz;
assign scl = (scl_o == 1'b0) ? 1'b0 : 1'bz;
assign sda_i = sda;
assign scl_i = scl;
```

**The open-drain model in one sentence**: The device can only **pull the wire LOW**. To "release" the wire (let it go HIGH), the device goes high-impedance (`1'bz`), and external pull-up resistors do the rest.

So `sda_o == 0` means "I want to pull SDA low right now." `sda_o == 1` means "I release SDA — do what you want, pull-ups will take it high unless someone else pulls it low."

> **SENIOR ENGINEER TIP**: In simulation, `1'bz` tri-state propagates correctly because simulators model wired-AND/OR. In synthesis targeting FPGAs, the `inout` ports are typically implemented with IOBUF primitives that the synthesizer infers from this exact pattern. When reviewing RTL, always check that bidirectional signals use this `z` pattern correctly — a missing `z` can cause bus contention (two outputs fighting each other).

### 2.3 CPU-Like Register Interface

```systemverilog
output logic [7:0]  reg_bank    [0:7],
output logic        reg_updated [0:7],
output logic        addr_match,
output logic        active,
```

| Port | Width | Purpose |
|------|-------|---------|
| `reg_bank[0:7]` | 8 x 8-bit | The 8 internal registers. Whatever the master writes via I2C appears here. |
| `reg_updated[0:7]` | 8 x 1-bit | Strobe signals — goes HIGH for one cycle when the corresponding register is written. Lets the CPU know "register N was just updated." |
| `addr_match` | 1-bit | HIGH when the most recent address byte matched our `SLAVE_ADDR`. |
| `active` | 1-bit | HIGH when a transaction addressed to us is in progress. |

`reg_updated` is an example of a **write-strobe** or **update-pulse** pattern. It is not a level signal (which would stay HIGH as long as data is valid). It is a single-cycle pulse that says "update happened right now." The consuming logic (a CPU or another module) would typically latch this.

### 2.4 Test Hook Ports

```systemverilog
input  logic        stretch_en,
input  logic [15:0] stretch_cycles,
input  logic        force_data_nack,
```

These three inputs do not exist on a real I2C slave device. They are **verification test hooks** — extra control ports added specifically so the testbench can inject specific scenarios.

| Port | Purpose |
|------|---------|
| `stretch_en` | Trigger a clock stretch (rising edge activates it) |
| `stretch_cycles` | How many system clock cycles to hold SCL low |
| `force_data_nack` | Force the slave to NACK a received data byte instead of ACK |

We will discuss each of these in detail in Parts 8 and 9.

### 2.5 Status Outputs

```systemverilog
output logic        rx_data_valid,
output logic [7:0]  rx_data,
output logic        tx_ack,
output logic        tx_nack,
output logic        bus_error
```

| Port | Purpose |
|------|---------|
| `rx_data_valid` | HIGH while slave is in `SLV_RX_ACK` and a valid byte is ready |
| `rx_data` | The received byte (latched copy, not raw shift register) |
| `tx_ack` | HIGH when master sent ACK after slave's transmitted byte |
| `tx_nack` | HIGH when master sent NACK (last byte, stop reading) |
| `bus_error` | Hardwired LOW in this design (placeholder) |

---

## Part 3: START/STOP Detection — The Hardest Part

### 3.1 The SDA Edge Detector

```systemverilog
// Lines 130-138
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sda_d <= 1'b1;
    else        sda_d <= sda_i;
end

// START: SDA falls while SCL is HIGH
assign start_cond = (sda_i == 1'b0 && sda_d == 1'b1 && scl_i == 1'b1);
// STOP: SDA rises while SCL is HIGH
assign stop_cond  = (sda_i == 1'b1 && sda_d == 1'b0 && scl_i == 1'b1);
```

`sda_d` is `sda_i` delayed by exactly one system clock cycle. This is called a **D flip-flop chain** or a **pipeline stage**.

**Why do we need it?**

Consider what we want to detect: "SDA transitioned from 1 to 0." A transition is not a level — it is a *change* between two consecutive time points. To detect a change, you need to know the **current value** AND the **previous value**. `sda_i` gives you the current value. `sda_d` gives you what it was one cycle ago.

Without `sda_d`, you only know "SDA is 0 right now." But is that because it just fell, or because it has been 0 for 100 cycles? You cannot tell. With `sda_d`, you can say: "SDA is 0 now AND was 1 last cycle — so it fell exactly this cycle."

The `start_cond` logic translates directly from the I2C spec:

| Signal | Value | Meaning |
|--------|-------|---------|
| `sda_i` | 0 | SDA is currently LOW |
| `sda_d` | 1 | SDA was HIGH last cycle |
| `scl_i` | 1 | SCL is currently HIGH |
| `start_cond` | 1 | All three → START detected |

### 3.2 Three-Cycle Walkthrough of START Detection

Let us walk through what actually happens cycle by cycle. Assume the master generates a START condition: SDA falls while SCL is HIGH.

```
Cycle N-1:  SCL=1, SDA=1  (bus is idle, both high)
Cycle N:    SCL=1, SDA=0  (master pulls SDA low — START happening)
Cycle N+1:  SCL=1, SDA=0  (still in START hold time)
```

Now watch the signals cycle by cycle:

| Cycle | `scl_i` | `sda_i` | `sda_d` | `start_cond` |
|-------|---------|---------|---------|--------------|
| N-1   | 1       | 1       | 1       | 0 (sda_i=1, not falling) |
| N     | 1       | 0       | 1       | **1** (sda_i=0, sda_d=1, scl=1 — DETECTED!) |
| N+1   | 1       | 0       | 0       | 0 (sda_d=0 now, no transition) |

Notice that `start_cond` is HIGH for **exactly one clock cycle** — cycle N. This is important: it is a pulse, not a level. The FSM catches it on that single cycle. This is correct behavior; the START condition is an instantaneous event.

### 3.3 ASCII Waveform — START Detection

```
             +-----+     +-----+-----+-----+-----+
clk    ------+     +-----+     +     +     +     +-----
              N-2   N-1   N    N+1   N+2   N+3

             +--+--+--+--+     +--+--+--+--+--+--+
scl    ------+  +  +  +  +     +  +  +  +  +  +  +----   (SCL HIGH during START)
             (high throughout)

sda    ------+--+--+--+--+--\  +--+--+--+--+--+--+----
             1  1  1  1  1   \ 0  0  0  0  0  0  0
                               ^ SDA falls HERE (N = cycle where sda_i first = 0)

sda_d  ------+--+--+--+--+--+  +--+--+--+--+--+--+---
             1  1  1  1  1  1  0  0  0  0  0  0  0
                               ^ sda_d = 1 at cycle N (one cycle behind sda_i)

start  ------+--+--+--+--+--+--+  +--+--+--+--+--+---
cond         0  0  0  0  0  0  1  0  0  0  0  0  0
                               ^--- PULSE: exactly cycle N
```

### 3.4 STOP Detection — The Mirror Image

STOP is the exact mirror: SDA RISES while SCL is HIGH.

```systemverilog
assign stop_cond = (sda_i == 1'b1 && sda_d == 1'b0 && scl_i == 1'b1);
```

Same three-condition check, but now we want `sda_i=1` (currently high) AND `sda_d=0` (was low last cycle) AND `scl_i=1`.

---

## Part 4: The 10-State FSM — Every State Explained

The FSM is split into two `always` blocks — the standard two-always FSM pattern:

- `always_ff`: Sequential block — updates `state` register on clock edge
- `always_comb`: Combinational block — computes `next_state` based on current `state` and inputs

```systemverilog
// Lines 63-74
typedef enum logic [3:0] {
    SLV_IDLE,
    SLV_START,
    SLV_ADDR,
    SLV_ACK,
    SLV_RX,
    SLV_RX_ACK,
    SLV_TX,
    SLV_TX_ACK,
    SLV_STRETCH,
    SLV_STOP
} slv_state_e;
```

The combinational block starts with something important:

```systemverilog
// Lines 386-390
if (start_cond) begin
    next_state = SLV_START;
end else if (stop_cond) begin
    next_state = SLV_IDLE;
end else begin
    case (state) ...
```

START and STOP have **global priority** — they are checked before the case statement. This means: no matter what state the FSM is in, if START is detected, it immediately goes to `SLV_START`. If STOP is detected, it goes to `SLV_IDLE`. This is correct per the I2C spec: START and STOP are always valid and always override whatever was happening.

### State 1: SLV_IDLE

**What is happening on the bus?** Nothing. The bus is free. SCL is HIGH, SDA is HIGH (both pulled up by resistors). No transaction is happening.

**What does the slave do?** Nothing. It sits and waits. `sda_o` defaults to `1'b1` (releasing SDA). `scl_o` is `1'b1` (releasing SCL).

**bit_cnt**: Irrelevant. Reset to 0 on START.

**Entry**: On reset, or after a STOP condition is detected.

**Exit**: When `start_cond` fires (checked globally before the case), FSM moves to `SLV_START`.

```systemverilog
// Lines 397-399
SLV_IDLE: begin
    next_state = SLV_IDLE;
end
```

In the current fixed code, `SLV_IDLE` just loops on itself. The START detection above the case handles the exit.

**Bug that touched this state**: Bug #15 — the original code had a `start_cond` check inside the `SLV_IDLE` case branch, which was dead code because `start_cond` was already handled above the case. See Part 10 for the full story.

---

### State 2: SLV_START

**What is happening on the bus?** The master just generated a START condition. SDA is LOW, SCL is HIGH. The master is about to start clocking SCL and putting the 7-bit address on SDA.

**What does the slave do?** Nothing visible — it just immediately transitions to `SLV_ADDR` to get ready to receive the address byte.

**bit_cnt**: Reset to 0 (START/STOP detection logic resets it).

**Entry**: From `start_cond` global check.

**Exit**: Immediately to `SLV_ADDR` (no condition needed — just transition).

```systemverilog
// Lines 404-406
SLV_START: begin
    next_state = SLV_ADDR;
end
```

This state exists for clarity and to provide one cycle of latency between detecting START and beginning address sampling.

---

### State 3: SLV_ADDR

**What is happening on the bus?** The master is clocking out 8 bits: the 7-bit slave address (MSB first) followed by the R/W bit. SCL toggles for each bit. SDA carries one bit per SCL HIGH period.

**What does the slave do?** Sample `sda_i` on every `scl_rise`. Shift it into `shift_reg`. Do NOT drive SDA — the master is talking.

```systemverilog
// Lines 162-166
if (state == SLV_ADDR || state == SLV_RX) begin
    shift_reg <= {shift_reg[6:0], sda_i};
end
```

Each time SCL rises, the slave shifts `shift_reg` left by one and fills bit 0 with the current `sda_i`. After 8 SCL rises, `shift_reg[7:1]` has the 7-bit address and `shift_reg[0]` has the R/W bit. Actually, the address latch explicitly captures this:

```systemverilog
// Lines 177-182
end else if (state == SLV_ADDR && bit_cnt == 4'd7 && scl_rise) begin
    rx_addr      <= shift_reg[6:0];
    rx_rw        <= sda_i;         // R/W bit is the 8th bit, currently on SDA
    addr_matched <= (shift_reg[6:0] == SLAVE_ADDR);
end
```

Wait — `bit_cnt == 4'd7` but this is the 8th bit (bits 0 through 7). Let us verify: `bit_cnt` starts at 0 on START, increments on each `scl_rise`. So:
- `scl_rise` 1: `bit_cnt` becomes 1
- `scl_rise` 2: `bit_cnt` becomes 2
- ...
- `scl_rise` 7: `bit_cnt` becomes 7 (this is the 8th rising edge)

The address latch fires when `bit_cnt == 4'd7` and `scl_rise` is happening simultaneously. At this moment:
- `shift_reg[6:0]` contains the 7 bits already shifted in (bits 1-7 of the address byte)
- `sda_i` is the current bit (bit 8 = R/W bit, still being presented by the master)

This is why `rx_rw <= sda_i` rather than `rx_rw <= shift_reg[0]` — the 8th bit has not been shifted in yet when we latch.

**bit_cnt**: Counting from 0 to 7. Resets to 0 in ACK/RX_ACK/TX_ACK states.

**Entry**: From `SLV_START`.

**Exit**: When `bit_cnt == 4'd8 && scl_fall`. Note: `bit_cnt` reaches 8 after the 9th SCL rise. Wait — the address byte is only 8 bits. Why does `bit_cnt` need to reach 8?

Think about it: after the 8th bit is sampled (`bit_cnt` becomes 7 at the 8th `scl_rise`, then increments to 8 at... no wait). Let me re-read the bit counter:

```systemverilog
// Lines 143-153
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bit_cnt <= 4'd0;
    end else if (start_cond || stop_cond) begin
        bit_cnt <= 4'd0;
    end else if (state == SLV_ACK || state == SLV_RX_ACK || state == SLV_TX_ACK) begin
        bit_cnt <= 4'd0;
    end else if (scl_rise) begin
        bit_cnt <= bit_cnt + 1'b1;
    end
end
```

`bit_cnt` increments on every `scl_rise` except in ACK states (where it is forced to 0). So in `SLV_ADDR`:
- 1st SCL rise: bit_cnt = 1
- 2nd SCL rise: bit_cnt = 2
- ...
- 8th SCL rise: bit_cnt = 8

The transition condition in `SLV_ADDR` is `bit_cnt == 4'd8 && scl_fall`. After the 8th SCL rise, the master will pull SCL low. On that `scl_fall`, `bit_cnt` is 8. This is the transition point — all 8 bits have been presented and sampled.

**ASCII waveform — ADDR phase (simplified, 3 of 8 bits):**

```
SCL   ----+     +-----+     +-----+     +----
          |     |     |     |     |     |
          +-----+     +-----+     +-----+

SDA   --[A6]--[A6]--[A5]--[A5]--[A4]--[A4]--

           ^           ^           ^
           |           |           |
         scl_rise    scl_rise    scl_rise
         bit_cnt=1   bit_cnt=2   bit_cnt=3
         shift_reg   shift_reg   shift_reg
         gets A6     gets A5     gets A4
```

---

### State 4: SLV_ACK

**What is happening on the bus?** The master has finished sending the address byte. SCL is now LOW (master just dropped it after the 8th bit). The master is waiting for the slave to acknowledge.

**What does the slave do?** If `addr_matched`, drive `sda_o <= 1'b0` (pull SDA LOW = ACK). If not matched, release SDA (let it stay HIGH = NACK).

```systemverilog
// Lines 280-285
SLV_ACK: begin
    if (addr_matched) sda_o <= 1'b0;  // ACK (match found)
    else              sda_o <= 1'b1;  // NACK (no match)
end
```

This is the slave "answering the roll call." When the master cycles SCL for the 9th time, it samples SDA to see whether anyone ACK'd.

**entry**: From `SLV_ADDR` when `bit_cnt == 8 && scl_fall`.

**Exit**: On the next `scl_fall` (the 9th SCL LOW), the slave checks `addr_matched` and `rx_rw`:
- `addr_matched && rx_rw == 1'b1` → `SLV_TX` (master wants to read from slave)
- `addr_matched && rx_rw == 1'b0` → `SLV_RX` (master wants to write to slave)
- `!addr_matched` → `SLV_IDLE` (transaction is not for us, ignore it)

**Bugs**: None directly, but `active_int` is set in this state based on `addr_matched`.

```systemverilog
// Lines 327-330
end else if (state == SLV_ACK) begin
    active_int <= addr_matched;
end
```

---

### State 5: SLV_RX

**What is happening on the bus?** The master is writing a data byte to the slave. Same physical bus activity as ADDR: SCL toggling, SDA carrying bits, MSB first.

**What does the slave do?** Sample SDA on every `scl_rise`, shift into `shift_reg`. After all 8 bits, latch the complete byte.

**bit_cnt**: Counting from 0 to 8 (reset to 0 when entering from `SLV_RX_ACK`).

**Entry**: From `SLV_ACK` (when address matched and R/W=WRITE) or from `SLV_RX_ACK` (for subsequent bytes in a burst).

**Exit**: When `bit_cnt == 4'd8 && scl_fall` → move to `SLV_RX_ACK`.

**The latched byte fix (Bug #1 context)**:

```systemverilog
// Lines 215-217
end else if (state == SLV_RX && bit_cnt == 4'd7 && scl_rise) begin
    latched_rx_byte <= {shift_reg[6:0], sda_i};
end
```

The complete byte is assembled and latched at exactly the 8th `scl_rise` (when `bit_cnt` is about to become 8, but let us verify: `bit_cnt == 4'd7` means we have seen 7 rising edges already, and this 8th one is happening right now). The `{shift_reg[6:0], sda_i}` includes the 7 already-shifted bits and the current bit 8 from SDA.

We will cover the Bug #1 story in detail in Part 5.

---

### State 6: SLV_RX_ACK

**What is happening on the bus?** The slave just received a complete data byte. The master is waiting for an ACK. SCL is LOW (master dropped it after the 8th data bit).

**What does the slave do?**
- Drive `sda_o <= 1'b0` if `active_int && !force_data_nack` (ACK the received byte)
- Drive `sda_o <= 1'b1` if not (NACK)
- Write `latched_rx_byte` into `internal_regs[reg_ptr]`
- Increment `reg_ptr` for the next byte

```systemverilog
// Lines 288-291
SLV_RX_ACK: begin
    if (active_int && !force_data_nack) sda_o <= 1'b0;  // ACK
    else                                 sda_o <= 1'b1;  // NACK
end
```

**Entry**: From `SLV_RX` when `bit_cnt == 8 && scl_fall`.

**Exit**:
- `stop_cond` → `SLV_STOP`
- `start_cond` → `SLV_START` (Repeated START — master restarted without STOP)
- `scl_fall` (master clocked the ACK and dropped SCL again) → `SLV_RX` (ready for next byte)

**Bugs**:
- Bug #1 (latched byte fix) — affected data written to `internal_regs`
- Bug #6 (`force_data_nack` hook) — hardwired ACK, no way to test NACK path

---

### State 7: SLV_TX

**What is happening on the bus?** The master is reading from the slave. The slave is driving SDA. The master clocks SCL.

**What does the slave do?** Drive `sda_o <= tx_shift_reg[7]` (the MSB of the TX shift register). On every `scl_fall`, shift the TX register left to present the next bit.

```systemverilog
// Lines 294-300
SLV_TX: begin
    if (active_int) begin
        sda_o <= tx_shift_reg[7];
    end else begin
        sda_o <= 1'b1;
    end
end
```

And in the TX shift register logic:

```systemverilog
// Lines 267-270
end else if (state == SLV_TX && scl_fall) begin
    tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};
end
```

**bit_cnt**: Counting from 0 to 8.

**Entry**: From `SLV_ACK` (when address matched and R/W=READ).

**Exit**: `bit_cnt == 4'd8 && scl_fall` → `SLV_TX_ACK`.

**Bugs**:
- Bug #2 — the TX shift register did not exist. The slave drove high-Z or garbage. See Part 6 for the full story.

---

### State 8: SLV_TX_ACK

**What is happening on the bus?** The slave just finished transmitting 8 bits. The master will now send ACK or NACK on SDA. The master drives SDA; the slave samples it.

**What does the slave do?** Release SDA (set `sda_o <= 1'b1` via the default case). Wait for `scl_fall`. On `scl_fall`, sample `sda_i`:
- `sda_i == 1'b0` (LOW = ACK from master) → `SLV_TX` (send next byte)
- `sda_i == 1'b1` (HIGH = NACK from master) → `SLV_IDLE` (master is done reading)

```systemverilog
// Lines 476-487
SLV_TX_ACK: begin
    if (stop_cond) begin
        next_state = SLV_STOP;
    end else if (start_cond) begin
        next_state = SLV_START;
    end else if (scl_fall) begin
        if (sda_i == 1'b0) next_state = SLV_TX;
        else                next_state = SLV_IDLE;
    end ...
end
```

**Bugs**:
- Bug #4 — original code did not check `sda_i` at all; it always went back to `SLV_TX`, violating the spec.

**Status outputs in this state**:

```systemverilog
// Lines 522-523
assign tx_ack  = (state == SLV_TX_ACK && sda_i == 1'b0 && active_int);
assign tx_nack = (state == SLV_TX_ACK && sda_i == 1'b1 && active_int);
```

These are level outputs (high while in this state AND the condition holds), which gives the testbench a chance to observe them.

---

### State 9: SLV_STRETCH

**What is happening on the bus?** The slave has pulled SCL LOW. The master is waiting, watching SCL. Time is paused from the master's perspective.

**What does the slave do?** Nothing except hold `scl_o <= 1'b0`. The SCL output logic handles this:

```systemverilog
// Lines 311-318
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scl_o <= 1'b1;
    end else if (stretch_active) begin
        scl_o <= 1'b0;   // Hold SCL LOW
    end else begin
        scl_o <= 1'b1;   // Release SCL
    end
end
```

**Entry**: Whenever `stretch_active && active_int` is true (checked globally at the END of the combinational block, line 514), forcing `next_state = SLV_STRETCH`.

**Exit**: When `!stretch_active` (timer expired or stretch was deasserted) → restore `saved_state`.

```systemverilog
// Lines 492-499
SLV_STRETCH: begin
    if (!stretch_active) begin
        next_state = saved_state;
    end else begin
        next_state = SLV_STRETCH;
    end
end
```

**Bugs**:
- Bug #3 — original returned to `SLV_IDLE` instead of `saved_state`
- Bug #5 — no `active_int` guard, could fire during idle
- Bug #14 — timer off-by-one

See Part 8 for the complete clock stretching deep dive.

---

### State 10: SLV_STOP

**What is happening on the bus?** The master generated a STOP condition (SDA rose while SCL was HIGH). The transaction is complete. The bus will return to idle.

**What does the slave do?** Immediately transitions to `SLV_IDLE`. This state exists as a clean "one-cycle pause" between detecting STOP and returning to idle.

```systemverilog
// Lines 504-506
SLV_STOP: begin
    next_state = SLV_IDLE;
end
```

**Entry**: From global `stop_cond` check (transitions from any state) OR from `SLV_RX_ACK`/`SLV_TX_ACK` when `stop_cond` fires.

**Exit**: Immediately to `SLV_IDLE` on the next cycle.

---

## Part 5: The RX Shift Register — Receiving Data

### 5.1 How Bits Are Assembled

The shift register is the heart of serial-to-parallel conversion. Let us understand it deeply.

```systemverilog
// Lines 158-167
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        shift_reg <= 8'h00;
    end else if (scl_rise) begin
        if (state == SLV_ADDR || state == SLV_RX) begin
            shift_reg <= {shift_reg[6:0], sda_i};
        end
    end
end
```

The key operation is `{shift_reg[6:0], sda_i}`. Let me break this down:

- `shift_reg[6:0]`: Bits 6 down to 0 of the current shift register (7 bits, dropping bit 7)
- `sda_i`: The current bit on SDA (1 bit)
- `{A, B}`: Concatenation — put A in the MSBs, B in the LSBs

So the result is: take the lower 7 bits of the old shift_reg and append the new incoming bit at the bottom (LSB). This shifts everything LEFT by one and inserts the new bit at bit 0.

This implements **MSB-first** serial reception: the first bit received becomes bit 7, gets shifted down to bit 6 on the next clock, then bit 5, ..., eventually ending at bit 0 when the 8th bit arrives.

### 5.2 Receiving 0xA5 — Bit by Bit Walkthrough

0xA5 = `1010_0101` in binary. MSB first means the master sends bit 7 (1) first, then bit 6 (0), bit 5 (1), bit 4 (0), bit 3 (0), bit 2 (1), bit 1 (0), bit 0 (1).

| SCL Rise # | `sda_i` (bit sent) | `shift_reg` after |
|------------|---------------------|-------------------|
| Initial    | —                   | `0000_0000`       |
| 1          | 1 (bit 7 of 0xA5)  | `0000_0001`       |
| 2          | 0 (bit 6)           | `0000_0010`       |
| 3          | 1 (bit 5)           | `0000_0101`       |
| 4          | 0 (bit 4)           | `0000_1010`       |
| 5          | 0 (bit 3)           | `0001_0100`       |
| 6          | 1 (bit 2)           | `0010_1001`       |
| 7          | 0 (bit 1)           | `0101_0010`       |
| 8          | 1 (bit 0 of 0xA5)  | `1010_0101` = 0xA5 |

After 8 SCL rising edges, `shift_reg = 0xA5`. The original value has been reconstructed.

> **SENIOR ENGINEER TIP**: Always trace through a shift register manually with a known value when reviewing or debugging. Pick a value with alternating bits (like 0xA5 = `1010_0101`) so you can easily see if the shift direction is correct. If you used 0xFF or 0x00, the shift direction wouldn't matter — you'd get the right answer either way and miss a bug.

### 5.3 The BUG #1 Story — ACK Bit as Data

**The bug**: In the original code, the shift register was read as the data byte after the 9th `scl_rise` — the ACK clock.

Here is what actually happens on the wire:

```
SCL:  ----+   +---+   +---+   +---+   +---+   +---+   +---+   +---+   +---+----
          |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |
          +---+   +---+   +---+   +---+   +---+   +---+   +---+   +---+   +---

SDA:  [D7] [D7] [D6] [D6] [D5] ... [D0] [D0] [ACK] [ACK]
          bit1     bit2     bit3   ... bit8     bit9 (ACK)
```

The 9th SCL cycle is the ACK/NACK cycle. During this cycle, the master RELEASES SDA (it goes HIGH via pull-up, meaning "wait for slave ACK"). The slave is supposed to PULL SDA LOW to ACK.

If the original code updated the shift register on the 9th `scl_rise`, it would shift in `sda_i` from the ACK phase. During the ACK phase, `sda_i` reflects whatever the slave is driving (LOW for ACK, or the pull-up HIGH for NACK) — NOT the 8th data bit. This corrupts the received byte.

**The fix**: Latch `latched_rx_byte` at exactly the 8th `scl_rise`, before the ACK phase begins:

```systemverilog
// Lines 215-217
end else if (state == SLV_RX && bit_cnt == 4'd7 && scl_rise) begin
    latched_rx_byte <= {shift_reg[6:0], sda_i};
end
```

When `bit_cnt == 4'd7` and `scl_rise` fires, that is the 8th SCL rising edge (since `bit_cnt` was reset to 0 at `SLV_RX_ACK`/`SLV_ACK` and has counted up to 7 after 7 previous edges). At this instant, `shift_reg[6:0]` has the first 7 bits already shifted in, and `sda_i` is carrying the 8th data bit right now. Concatenating them gives the complete, correct byte.

The status outputs use this latched value:

```systemverilog
// Line 521
assign rx_data = latched_rx_byte;
```

---

## Part 6: The TX Shift Register — Transmitting Data

### 6.1 The TX Path

When the master reads from the slave (`rx_rw == 1'b1`), the slave must DRIVE data onto SDA. It uses a dedicated `tx_shift_reg`:

```systemverilog
// Lines 258-271
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_shift_reg <= 8'h00;
    end else if (state == SLV_ACK && addr_matched && rx_rw == 1'b1) begin
        // First byte: load from reg_ptr (which is 0 after SLV_ACK)
        tx_shift_reg <= internal_regs[reg_ptr];
    end else if (state == SLV_TX_ACK && scl_fall && sda_i == 1'b0 && active_int) begin
        // Master ACK'd: load NEXT register byte
        tx_shift_reg <= internal_regs[reg_ptr];
    end else if (state == SLV_TX && scl_fall) begin
        // Shift out next bit (MSB first)
        tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};
    end
end
```

Three operations:
1. **Load on entering TX mode**: When in `SLV_ACK` and `rx_rw==1`, load `internal_regs[reg_ptr]` (reg_ptr is 0 at this point). This prepares the first byte to send.
2. **Reload on master ACK**: When master ACKs in `SLV_TX_ACK`, load the next register (reg_ptr already incremented).
3. **Shift on each SCL fall**: During `SLV_TX`, every SCL falling edge shifts out the next bit.

The SDA output in `SLV_TX`:

```systemverilog
SLV_TX: begin
    if (active_int) begin
        sda_o <= tx_shift_reg[7];  // MSB first from shift register
    end
end
```

We always drive `tx_shift_reg[7]` — the MSB. After each `scl_fall`, we shift left (`{tx_shift_reg[6:0], 1'b0}`), bringing what was bit 6 into bit 7, so the next SCL cycle presents the next bit.

### 6.2 The BUG #2 Story — No TX Shift Register

In the original broken code, there was no `tx_shift_reg`. The slave was supposed to transmit data but had no mechanism to do so. What happened in practice was that `sda_o` was driven by the default case in the SDA output logic, which sets it to `1'b1` (release SDA). The bus floated HIGH via pull-up — the slave transmitted nothing but HIGH bits. Every read from the master returned `0xFF` or garbage.

The fix required adding the entire `tx_shift_reg` path: declaration, load logic, shift logic, and updating the SDA output in `SLV_TX` to use it.

**Why can't we reuse the RX shift register for TX?**

Because they operate in fundamentally different directions and timings:

| | RX shift_reg | TX tx_shift_reg |
|--|---|---|
| Direction | Serial in → parallel out | Parallel in → serial out |
| Load time | N/A (always accepting) | On entering TX mode |
| Shift timing | On `scl_rise` | On `scl_fall` |
| Drive point | Not driven | `tx_shift_reg[7]` drives SDA |
| States used | `SLV_ADDR`, `SLV_RX` | `SLV_TX` |

If you tried to use one register for both, you would have a conflict: during TX, the MSB needs to be stable for the entire SCL HIGH period (master samples it), but you can't shift it while also trying to present it. And during the transition from ACK (shift complete) to TX (start presenting), you would be loading new data into a register that might still be shifting.

---

## Part 7: Address Recognition

### 7.1 The Address Latch

```systemverilog
// Lines 172-183
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_addr      <= 7'h00;
        rx_rw        <= 1'b0;
        addr_matched <= 1'b0;
    end else if (state == SLV_ADDR && bit_cnt == 4'd7 && scl_rise) begin
        rx_addr      <= shift_reg[6:0];
        rx_rw        <= sda_i;
        addr_matched <= (shift_reg[6:0] == SLAVE_ADDR);
    end
end
```

When `bit_cnt == 4'd7` and `scl_rise`, we are at the 8th rising edge of the address byte. At this moment:
- `shift_reg[6:0]` has bits 7 through 1 of the address byte (7 bits worth)
- `sda_i` has bit 0 of the address byte, which per I2C spec is the R/W bit

The comparison `shift_reg[6:0] == SLAVE_ADDR` is a 7-bit equality check. If it matches, `addr_matched` becomes 1.

### 7.2 What Happens on Address Match

When `addr_matched` is true:
1. `SLV_ACK` state drives `sda_o <= 1'b0` (pull SDA LOW = ACK to master)
2. `active_int` is set to 1 (marks this slave as active in this transaction)
3. FSM transitions to either `SLV_RX` or `SLV_TX` depending on `rx_rw`

### 7.3 What Happens on Address Mismatch

When `addr_matched` is false:
1. `SLV_ACK` state drives `sda_o <= 1'b1` (release SDA — NACK, no one home)
2. `active_int` remains 0
3. FSM transitions to `SLV_IDLE` (ignore the rest of this transaction)

The master will see SDA HIGH during the ACK cycle, which it interprets as NACK, meaning "no device at this address." The master would then typically send STOP.

### 7.4 R/W Bit Decoding

| `rx_rw` value | I2C meaning | Slave next state |
|---------------|-------------|-----------------|
| `1'b0` (LOW)  | Master WRITE — master sends data to slave | `SLV_RX` |
| `1'b1` (HIGH) | Master READ — master requests data from slave | `SLV_TX` |

This is the standard I2C address byte format: bits [7:1] = address, bit [0] = R/W.

---

## Part 8: Clock Stretching Deep Dive

### 8.1 The Physical Mechanism

Clock stretching exploits the open-drain nature of I2C. After the master drops SCL LOW (to indicate a new clock period is starting), it eventually needs to release SCL (let it go HIGH) for the data bit to be valid.

But before releasing, it samples SCL. If SCL is still LOW (because the slave is holding it low), the master **waits**. This is the clock stretching protocol: the slave holds SCL LOW, the master waits patiently, and the slave releases SCL when it is ready.

### 8.2 The stretch_active Flag and scl_o

The `stretch_active` flag is the gate for this behavior:

```systemverilog
// Lines 344-364
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stretch_timer  <= 16'd0;
        stretch_active <= 1'b0;
    end else if (stretch_en_rise && !stretch_active && active_int) begin
        // FIX: Only trigger on RISING EDGE of stretch_en
        stretch_active <= 1'b1;
        stretch_timer  <= 16'd1;  // FIX: start at 1, not 0 (Bug #14)
    end else if (stretch_active) begin
        if (stretch_timer >= stretch_cycles) begin
            stretch_active <= 1'b0;
        end else begin
            stretch_timer <= stretch_timer + 1'b1;
        end
    end
end
```

When `stretch_active` is HIGH, the SCL output logic pulls SCL LOW:

```systemverilog
// Lines 313-315
end else if (stretch_active) begin
    scl_o <= 1'b0;   // Hold SCL LOW
end
```

And the FSM is forced to `SLV_STRETCH` by the global check at the end of the combinational block:

```systemverilog
// Line 514
if (stretch_active && active_int) next_state = SLV_STRETCH;
```

### 8.3 The saved_state Register

```systemverilog
// Lines 369-378
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= SLV_IDLE;
        saved_state <= SLV_IDLE;
    end else begin
        if (stretch_active && state != SLV_STRETCH)
            saved_state <= state;
        state <= next_state;
    end
end
```

`saved_state` captures the FSM state **at the moment stretch begins** — specifically, when `stretch_active` just became true and we are still in the previous state (not yet in `SLV_STRETCH`). The condition `state != SLV_STRETCH` prevents `saved_state` from being overwritten once we are already in `SLV_STRETCH`.

When the stretch completes, `SLV_STRETCH` returns to `saved_state`:

```systemverilog
SLV_STRETCH: begin
    if (!stretch_active) begin
        next_state = saved_state;
    end
end
```

### 8.4 The BUG #3 Story — Returning to Idle

The original `SLV_STRETCH` exit was simply `next_state = SLV_IDLE`. There was no `saved_state`. After any clock stretch, the slave forgot everything and started over from idle.

Imagine the slave was mid-way through transmitting a byte in `SLV_TX`. If a stretch fired, the FSM went to `SLV_STRETCH`. When the stretch ended, the FSM went to `SLV_IDLE` — completely forgetting it was in the middle of transmitting. The master would clock out more data bits, but the slave was in IDLE, not driving SDA. The transaction was silently corrupted.

The fix: add `saved_state` and return to it on stretch completion.

### 8.5 The BUG #5 Story — Stretch During Idle

The activation condition for stretch originally was:

```systemverilog
// Original (buggy):
stretch_en && !stretch_active
```

This would fire even if the slave was idle — not in any transaction at all. If `stretch_en` was asserted while the slave was sitting idle waiting for a START, `stretch_active` would go HIGH and `scl_o` would pull SCL LOW — with no transaction in progress! This could interfere with other devices on the same I2C bus.

The fix adds `active_int` to the condition:

```systemverilog
// Fixed:
stretch_en_rise && !stretch_active && active_int
```

Now stretch can only fire during an active transaction.

### 8.6 The BUG #14 Story — Timer Off-By-One

The timer originally started at 0 and checked `>= stretch_cycles`. Let us trace through `stretch_cycles = 3`:

**Original (buggy)**:
```
Cycle 0: stretch_active=1, timer=0. Check: 0 >= 3? NO. Timer increments.
Cycle 1: timer=1. Check: 1 >= 3? NO. Timer increments.
Cycle 2: timer=2. Check: 2 >= 3? NO. Timer increments.
Cycle 3: timer=3. Check: 3 >= 3? YES. stretch_active=0.
```
Duration: 4 cycles (0, 1, 2, 3). But we asked for 3. Off by one.

**Fixed**: Initialize timer to 1:

```
Cycle 0: stretch_active=1, timer=1. Check: 1 >= 3? NO. Timer increments.
Cycle 1: timer=2. Check: 2 >= 3? NO. Timer increments.
Cycle 2: timer=3. Check: 3 >= 3? YES. stretch_active=0.
```
Duration: 3 cycles. Exactly right.

> **SENIOR ENGINEER TIP**: Off-by-one errors in timers are extremely common in RTL. Always trace through manually with a small value like 3 or 4. Ask yourself: "If I set this to N, how many cycles does it actually run?" If the answer is N+1 or N-1, you have an off-by-one. The rule of thumb: if you initialize at 0 and use `>=`, add 1 to the initial value OR change to `>` instead. If you initialize at 1 and use `>=`, you get exactly N cycles.

### 8.7 ASCII Waveform — Clock Stretching

```
           START  [ADDR PHASE]          [ACK]  [STRETCH]   [TX DATA...]
clk   ----+  +  +  +  +  +  +  +  +  +  +  +  +  +  +  +  +  +  +  +  +

SCL   ----+------+  +--+  +--+  +  +  +--+  +  +  +  + ---  ---  +  +  +
          |      |__|  |__|  |__|  |__|  |  |__|  |__|  |   |   |  |__|  |
               (address bits)       ^   ACK ^         SLAVE^       ^data
                                    |       |         HOLDS |       |bits
                                    8th bit |         SCL   |       resume
                                            9th SCL         stretch ends

stretch_active:  ___________________________+---------+___________________
                                            ^ fires    ^ expires
scl_o:          ___________________________+---------+___________________
(slave drives)                             LOW        HIGH (released)

FSM state:     IDLE START ADDR...ADDR  ACK STRETCH STRETCH...TX TX TX...
                                           ^ saved_state=SLV_TX
                                                         ^ return to SLV_TX
```

---

## Part 9: The force_data_nack Test Hook

### 9.1 Why Test Hooks Exist in RTL

This is a concept that surprises many interns: **sometimes you add code to RTL specifically for verification, not for functionality**.

In a real product, the slave should always ACK data bytes when it is healthy and ready. But in verification, we need to TEST what happens when the slave NACKs a data byte. How does the master react? Does it retry? Does it send STOP? Does it hang?

To test this scenario, we need the slave to behave in a way it would never normally behave. We need a way to **inject** a NACK response. Enter `force_data_nack`:

```systemverilog
// Lines 288-291
SLV_RX_ACK: begin
    if (active_int && !force_data_nack) sda_o <= 1'b0;  // ACK
    else                                 sda_o <= 1'b1;  // NACK
end
```

By asserting `force_data_nack` from the testbench, the slave sends NACK instead of ACK for every received data byte.

### 9.2 The BUG #6 Story — Hardwired ACK

The original code had:

```systemverilog
// Original (buggy):
SLV_RX_ACK: begin
    sda_o <= 1'b0;  // Always ACK, hardwired
end
```

This was a hardwired ACK — impossible to override. The testbench had no way to make the slave NACK a data byte. The `data_nack_test` test case would either not exist or always fail to reach the NACK scenario.

The fix adds the `force_data_nack` port and the conditional check, giving the testbench the controllability it needs.

### 9.3 Controllability and Observability

In DV, we talk about two properties of a design:

- **Controllability**: Can I drive the design into any state I want? The `force_data_nack` port improves controllability — it lets us force a state (NACK) that would normally be hard to reach.
- **Observability**: Can I observe whether a given internal state was reached? The `reg_updated[0:7]` outputs improve observability — the testbench can observe exactly which register was written and when.

> **SENIOR ENGINEER TIP**: When designing RTL for a block that will be verified, think upfront about what scenarios your verification team will need to test. Add controllability hooks for hard-to-reach states and observability hooks for internal signals. It is much harder to retrofit these after the fact. The `stretch_en`, `stretch_cycles`, and `force_data_nack` ports are all examples of this forward thinking.

---

## Part 10: The BUG #15 Dead Code Story

### 10.1 What Is Dead Code in RTL?

Dead code is code that can **never execute**. It is syntactically valid code that the tools will parse without error, but due to surrounding logic, it can never actually affect the design behavior.

In software, dead code wastes compilation time and confuses readers. In RTL, dead code can also:
- Confuse the reader into thinking logic exists that does not
- Indicate a logic error (the author THOUGHT it would execute, but it cannot)
- Be a coverage hole (formal tools or coverage tools may report it as uncovered, causing investigation)

### 10.2 The Specific Bug

The FSM combinational block starts with:

```systemverilog
// Lines 386-390
if (start_cond) begin
    next_state = SLV_START;
end else if (stop_cond) begin
    next_state = SLV_IDLE;
end else begin
    case (state)
        SLV_IDLE: begin
            next_state = SLV_IDLE;
        end
        ...
    endcase
end
```

The outer `if (start_cond)` captures ALL cases where `start_cond` is true. Only if `start_cond` is false do we enter the `else` branch and reach the `case` statement.

Inside the `case` statement, the `SLV_IDLE` branch originally had:

```systemverilog
// ORIGINAL BUGGY CODE (dead):
SLV_IDLE: begin
    if (start_cond) begin
        next_state = SLV_START;  // THIS IS DEAD CODE
    end else begin
        next_state = SLV_IDLE;
    end
end
```

The inner `if (start_cond)` can NEVER be true because:
1. To reach the `case` statement, `start_cond` must be false (the outer `else`)
2. If `start_cond` is false, the inner `if (start_cond)` cannot be true

The `next_state = SLV_START` inside the IDLE case is dead code.

**The fix** (current code):

```systemverilog
SLV_IDLE: begin
    next_state = SLV_IDLE;  // Only reachable path
end
```

### 10.3 How to Find Dead Code

1. **Trace code paths manually**: Read from the entry point, follow all conditions, note what is possible at each point.
2. **Formal tools**: Tools like JasperGold or VC Formal can prove that certain code paths are unreachable.
3. **Coverage**: A toggling or branch coverage report will show branches that were never hit. If a branch is never hit in simulation AND can never be hit by design, it is dead code.
4. **Code review**: A careful second reader often spots dead code that the original author missed.

---

## Part 11: Internal Register Bank

### 11.1 The Register Array

```systemverilog
// Line 99
logic [7:0] internal_regs [0:7];
```

This is a packed array of 8 bytes. Think of it as 8 memory locations, each 8 bits wide, addressed by a 3-bit pointer (0 through 7).

The `reg_ptr` is the 3-bit pointer:

```systemverilog
// Line 84
logic [2:0] reg_ptr;
```

### 11.2 How reg_ptr Resets and Increments

```systemverilog
// Lines 190-204
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        reg_ptr <= 3'd0;
        reg_ptr_inc_done <= 1'b0;
    end else if (state == SLV_ACK && addr_matched) begin
        reg_ptr <= 3'd0;  // Reset to 0 at start of each transaction
    end else if (state == SLV_RX_ACK && active_int && rx_rw == 1'b0 && !reg_ptr_inc_done) begin
        reg_ptr <= reg_ptr + 1'b1;  // Write: advance after each byte
        reg_ptr_inc_done <= 1'b1;
    end else if (state == SLV_TX_ACK && active_int && rx_rw == 1'b1 && !reg_ptr_inc_done) begin
        reg_ptr <= reg_ptr + 1'b1;  // Read: advance after master ACKs each byte
        reg_ptr_inc_done <= 1'b1;
    end else if (state != SLV_RX_ACK && state != SLV_TX_ACK) begin
        reg_ptr_inc_done <= 1'b0;  // Clear the one-shot guard
    end
end
```

Key points:
1. **Reset to 0** on address match (`SLV_ACK` with `addr_matched`). Every new transaction starts at register 0.
2. **Increment after write**: In `SLV_RX_ACK` (after receiving a byte), `reg_ptr` increments. Next byte goes to reg 1, then reg 2, etc.
3. **Increment after read ACK**: In `SLV_TX_ACK` when master sent ACK, `reg_ptr` increments. Next read comes from reg 1, then reg 2, etc.
4. **`reg_ptr_inc_done` one-shot guard**: Prevents the pointer from incrementing MULTIPLE times while staying in `SLV_RX_ACK` or `SLV_TX_ACK`. Without this, the pointer would increment every clock cycle while in the ACK state, rapidly overflowing.

### 11.3 How Master Write Updates Registers

```systemverilog
// Lines 236-243
if (state == SLV_RX_ACK && active_int && (rx_rw == 1'b0) && !rx_write_done) begin
    internal_regs[reg_ptr]    <= latched_rx_byte;
    internal_updated[reg_ptr] <= 1'b1;
    rx_write_done             <= 1'b1;
end else if (state != SLV_RX_ACK) begin
    rx_write_done <= 1'b0;
end
```

When the slave enters `SLV_RX_ACK`:
- `latched_rx_byte` contains the just-received byte
- `reg_ptr` points to the target register
- The write happens once (`rx_write_done` one-shot guard prevents repeat writes)
- `internal_updated[reg_ptr]` pulses HIGH for one cycle to notify downstream logic

The `update_strobe` pattern:

```systemverilog
// Lines 231-233
for (int i = 0; i < 8; i++) begin
    internal_updated[i] <= 1'b0;  // Clear update strobes every cycle
end
```

Update strobes are cleared every cycle, so they are naturally one-cycle pulses. The only cycle they are HIGH is when the write happens (the `internal_updated[reg_ptr] <= 1'b1` assignment overrides the clear in that same cycle, because the clear applies to all 8 and the write applies to just one — in SystemVerilog, the last assignment to a variable in an `always_ff` wins, but here they are in the same always block with `for` first and the conditional second, so the conditional assignment after the for loop takes precedence for that specific index).

### 11.4 Burst Write Example

If the master writes 3 bytes (0xAA, 0xBB, 0xCC) in a burst:

| Phase | `reg_ptr` | Data | Action |
|-------|-----------|------|--------|
| SLV_ACK | 0 | — | Reset reg_ptr=0 |
| SLV_RX (byte 1) | 0 | 0xAA receiving | — |
| SLV_RX_ACK | 0 | 0xAA | Write to internal_regs[0], reg_ptr++ to 1 |
| SLV_RX (byte 2) | 1 | 0xBB receiving | — |
| SLV_RX_ACK | 1 | 0xBB | Write to internal_regs[1], reg_ptr++ to 2 |
| SLV_RX (byte 3) | 2 | 0xCC receiving | — |
| SLV_RX_ACK | 2 | 0xCC | Write to internal_regs[2], reg_ptr++ to 3 |
| STOP | — | — | Transaction ends |

After this burst: `internal_regs[0]=0xAA`, `internal_regs[1]=0xBB`, `internal_regs[2]=0xCC`.

---

## Part 12: Interview Questions — Slave Controller

The following questions range from basic recall to deep analytical thinking. A strong candidate answers not just WHAT, but WHY.

---

**Q1. How does the slave detect a START condition without a dedicated clock?**

The slave samples `sda_i` and `scl_i` on every rising edge of its system clock. It keeps `sda_d`, a one-cycle-delayed copy of `sda_i`. START is detected when `sda_i==0 && sda_d==1 && scl_i==1`, meaning SDA just fell while SCL was HIGH. This is edge detection implemented with a 1-bit shift register.

---

**Q2. What is the purpose of `sda_d`?**

`sda_d` provides the "previous cycle" value of SDA. A transition cannot be detected from a single sample — you need to know the current value AND the value one cycle ago. Without `sda_d`, you can tell if SDA is currently LOW, but you cannot tell if it JUST went low or has been low for 1000 cycles.

---

**Q3. Why does the slave have separate TX and RX shift registers?**

They operate in opposite directions, at different times, and with different bit-timing. The RX register shifts in new bits on `scl_rise` (sampling). The TX register shifts out old bits on `scl_fall` (presenting the next bit before the next `scl_rise`). They cannot be used simultaneously, and trying to time-share one register would require complex control logic and risk data corruption. Separate registers make the logic clean and unambiguous.

---

**Q4. What happens if the slave does not ACK its address?**

The slave drives SDA HIGH (releases it) during the 9th SCL cycle. The master samples SDA and sees HIGH = NACK. The master interprets this as "no device at this address." The master will typically generate a STOP condition and report an error. On our slave RTL side, `addr_matched` stays 0, `active_int` stays 0, and the FSM returns to `SLV_IDLE`.

---

**Q5. Draw the clock stretching waveform and explain what happens.**

```
SCL (from master perspective):
     +-----+     +-----+     +-----+     ...long pause...     +-----+
     |     |     |     |     |     |                           |     |
-----+     +-----+     +-----+     +---------------------------+     +-----
                                   ^ slave holds SCL LOW       ^ slave releases

SDA (slave driving data):
     [D7]        [D6]        [D5]  (hold)                      [D4]
```

The slave asserts `scl_o=0` when `stretch_active` fires. This pulls the open-drain SCL wire LOW. The master, wanting to release SCL for the next bit, finds it still LOW and waits. When the slave releases SCL (`stretch_active` expires, `scl_o` returns to 1), the master sees SCL go HIGH (pulled up by resistors) and continues.

---

**Q6. What is `saved_state` and why is it needed?**

`saved_state` is a register that captures the FSM state the moment a clock stretch begins. When the stretch ends, the FSM uses `saved_state` as the `next_state` instead of `SLV_IDLE`. Without it, the slave would forget what it was doing (transmitting, receiving, waiting for ACK) and return to IDLE after every stretch, breaking any transaction that involves stretching.

---

**Q7. How would you verify that the slave correctly rejects an address mismatch?**

Write a directed test that sends a transaction to an address that is NOT `SLAVE_ADDR`. For example, if `SLAVE_ADDR = 7'h50`, send to `7'h51`. The monitor should observe:
1. `addr_match` output remains LOW
2. SDA stays HIGH during the 9th SCL cycle (NACK)
3. `active` output remains LOW
4. The slave FSM returns to IDLE immediately after the NACK

The scoreboard should verify that no data was written to `reg_bank`.

---

**Q8. What is the difference between `force_data_nack` and a real NACK?**

A real data NACK would occur if the slave had a buffer overflow, was not ready, or had an internal error — scenarios that are hard or impossible to reproduce in controlled testing. `force_data_nack` is a synthesizable test hook that allows the testbench to inject a NACK at will, without needing to create the underlying condition. It is identical electrically (SDA HIGH during the 9th data clock cycle), but controlled by a testbench input rather than by organic conditions.

---

**Q9. If you see 0x00 on every read from the slave, what would you check first?**

First, check if the TX shift register is being loaded correctly:
1. Is `tx_shift_reg` being loaded from `internal_regs[reg_ptr]` in `SLV_ACK`? (Bug #2 was the TX register not existing at all)
2. Is `internal_regs` actually populated? Were previous writes successful?
3. Is `sda_o <= tx_shift_reg[7]` active in `SLV_TX`? Is `active_int` high?
4. Is the shift happening correctly — `{tx_shift_reg[6:0], 1'b0}` on `scl_fall`?

If all bits come out 0, the most likely cause is that `tx_shift_reg` is stuck at 0 (never loaded from `internal_regs`), which was exactly Bug #2.

---

**Q10. Why can't we use the same shift register for TX and RX?**

See Q3 above. The deeper reason: during RX, the shift register is the **destination** (bits shift IN, the register fills up). During TX, the shift register is the **source** (bits shift OUT, the register empties). These are fundamentally opposite operations. Also, the timing is inverted: RX samples on `scl_rise`, TX shifts on `scl_fall`. Sharing a register would require multiplexing the shift direction and timing, which is more complex and error-prone than simply having two registers.

---

**Q11. What does the `reg_ptr_inc_done` flag do? Why is it needed?**

It is a one-shot guard that prevents `reg_ptr` from incrementing more than once per ACK state visit. The FSM spends multiple clock cycles in `SLV_RX_ACK` (at least until the next `scl_fall`). Without the guard, `reg_ptr` would increment every cycle while in `SLV_RX_ACK`, quickly overflowing from 0 to 7 to 0 again. The `reg_ptr_inc_done` flag is set on the first increment and cleared when the FSM leaves the ACK state, ensuring exactly one increment per byte.

---

**Q12. What is the `active_int` signal used for? Give two examples.**

`active_int` is HIGH whenever the slave is in an active transaction (address matched, transaction in progress, not yet STOP'd). It is used as a guard in multiple places:

1. **Clock stretch activation**: `stretch_en_rise && !stretch_active && active_int` — prevents spurious stretches during idle.
2. **Status outputs**: `tx_ack = (state == SLV_TX_ACK && sda_i == 1'b0 && active_int)` — ensures status signals only fire for our own transaction, not for other devices' transactions on the bus.

---

**Q13. Why is the START condition checked BEFORE the case statement in the FSM?**

Because START and STOP are global events that must be handled immediately, regardless of the current state. Per the I2C specification, a START condition during an ongoing transaction is a "Repeated START" — the master is starting a new transaction without releasing the bus first. If START were handled only inside specific states, the FSM would miss Repeated STARTs during states that do not check for them. The global priority ensures no START or STOP is ever missed.

---

**Q14. What is open-drain signaling and why does I2C use it?**

Open-drain means a device can only drive the line LOW (by connecting it to ground through a transistor) or release it (let it float to the pull-up voltage). It cannot actively drive HIGH. I2C uses open-drain because it allows **multiple devices to share a single wire** without bus conflicts. If two devices drive opposing values (one HIGH, one LOW) on a push-pull bus, you get a short circuit. With open-drain, if any device pulls LOW, the wire is LOW. No conflict occurs. This is also called a "wired-AND" topology.

---

**Q15. Describe the flow of a complete I2C write transaction from the slave's perspective, naming every FSM state.**

1. **SLV_IDLE**: Bus is idle. Slave waits.
2. **SLV_START**: `start_cond` fires. Slave enters START state.
3. **SLV_ADDR**: Slave shifts in 8 bits (7-bit address + R/W). On the 8th `scl_rise`, latches `rx_addr`, `rx_rw`, and `addr_matched`.
4. **SLV_ACK**: Slave drives SDA LOW (ACK) if address matched. Sets `active_int`. FSM waits for next `scl_fall`.
5. **SLV_RX**: Slave shifts in 8 data bits from master. On 8th `scl_rise`, latches `latched_rx_byte`.
6. **SLV_RX_ACK**: Slave drives SDA LOW (ACK). Writes `latched_rx_byte` to `internal_regs[reg_ptr]`. Increments `reg_ptr`. Waits.
7. (Steps 5-6 repeat for each additional byte in a burst.)
8. **SLV_STOP**: `stop_cond` fires. Transaction ends.
9. **SLV_IDLE**: Slave returns to idle, ready for next transaction.

---

**Q16 (Bonus — Advanced). What would happen if `sda_d` was NOT reset to `1'b1` on reset, but instead reset to `1'b0`?**

If `sda_d` reset to `1'b0`, then on the very first clock cycle after reset, `sda_d == 1'b0`. If `sda_i` is pulled HIGH by the bus pull-ups (which it normally is when the bus is idle), then `sda_i=1` and `sda_d=0` with `scl_i=1` would cause `stop_cond` to fire immediately on the first cycle after reset, even though no STOP actually occurred. The FSM would spuriously enter `SLV_IDLE` from `SLV_IDLE` — which is harmless in this case, but in a more complex design could cause a spurious state transition. This is why the reset value matches the bus idle state: `sda_d <= 1'b1` (bus idle = SDA HIGH).

---

## Summary Table — All Bugs in Slave Controller

| Bug # | Severity | State(s) Affected | Root Cause | Fix |
|-------|----------|-------------------|------------|-----|
| #1 | Critical | `SLV_RX` | ACK bit sampled as data on 9th `scl_rise` | `latched_rx_byte` captured at 8th `scl_rise` |
| #2 | Critical | `SLV_TX` | No TX shift register existed | Added `tx_shift_reg` with load and shift logic |
| #3 | Major | `SLV_STRETCH` | Returned to `SLV_IDLE` instead of prior state | Added `saved_state` register |
| #4 | Major | `SLV_TX_ACK` | Did not check `sda_i` for master ACK/NACK | Added `if (sda_i==0) TX else IDLE` |
| #5 | Moderate | Stretch logic | `active_int` not checked on stretch activation | Added `&& active_int` to enable condition |
| #6 | Feature | `SLV_RX_ACK` | Hardwired ACK, no test hook | Added `force_data_nack` port and conditional |
| #14 | Minor | Stretch timer | Timer started at 0, caused N+1 cycle stretch | Initialize timer at 1 instead of 0 |
| #15 | Minor | `SLV_IDLE` | `start_cond` check inside case was dead code | Removed inner check, simplified to loop |

---

## Closing Thoughts — How to Level Up Your RTL Reading

After working through this document, you should be able to open `i2c_slave_controller.sv` and understand every single line. But more importantly, you should have internalized the **process**:

1. **Start with ports** — understand the interface contract before touching the internals.
2. **Find edge detectors** — `sda_d`, `scl_d`, `stretch_en_d` are your first signals that asynchronous events are being handled.
3. **Find the FSM** — the `typedef enum` and the two `always` blocks tell you everything about control flow.
4. **Trace the data path** — follow data from input port to output port: SDA in → `sda_i` → edge detect → START/STOP → FSM → shift_reg → latch → internal_regs → reg_bank out.
5. **Trace the control path** — follow control signals: FSM state → sda_o drive conditions → scl_o drive conditions.
6. **Check the edge cases** — what happens on reset? What happens when two conditions fire at once? What happens at the boundary of a counter (bit_cnt == 7 vs 8)?
7. **Look for bugs** — dead code, hardwired values, missing one-shot guards, wrong reset values.

This kind of systematic reading is what separates a junior engineer who "reads code" from a senior engineer who **analyzes** it.

---

## Part 13: Synthesis Considerations — What Changes in Real Hardware

Up to now we have focused on simulation behavior. But this RTL is synthesizable — it will be mapped to real gates and flip-flops. When you hand the file to a synthesis tool (Synopsys Design Compiler, Cadence Genus, or Xilinx Vivado), the tool translates your `always_ff` and `always_comb` blocks into a netlist of standard cells. Understanding what the tool does — and what can go wrong — is critical for a hardware engineer.

### 13.1 Combinational vs Registered Signals

Every signal in the design falls into one of two categories:

**Registered** (driven by `always_ff`): These signals are flip-flop outputs. They only change on the rising edge of `clk` (or, for asynchronous reset, on the falling edge of `rst_n`). The synthesis tool infers a flip-flop for each bit.

Examples from our design:
- `state`, `saved_state` — FSM state registers
- `sda_o`, `scl_o` — SDA and SCL drive registers
- `shift_reg`, `tx_shift_reg` — data path registers
- `bit_cnt`, `reg_ptr` — counter registers
- `stretch_active`, `stretch_timer` — stretch control registers
- `sda_d`, `scl_d` — delayed copies of bus inputs (synchronizer flip-flops)

**Combinational** (driven by `always_comb` or `assign`): These signals are purely combinational logic — no flip-flop is inferred. The output changes immediately (within gate propagation delay) when inputs change.

Examples:
- `next_state` — computed combinationally from `state` and bus events
- `start_cond`, `stop_cond` — AND gates on `sda_i`, `sda_d`, `scl_i`
- `scl_rise`, `scl_fall` — AND gates on `scl_i` and `!scl_d`
- `addr_match` — direct wire assignment from `addr_matched` register
- `active` — direct wire from `active_int` register
- `stretch_en_rise` — AND gate: `stretch_en && !stretch_en_d`

### 13.2 Why `always_comb` Prevents Latches

This is one of the most important synthesis rules you will encounter: **if a combinational signal is not assigned in every branch of an `always` block, the synthesis tool infers a latch**.

A **latch** is a storage element that is transparent when its enable is HIGH and holds its value when the enable is LOW. Unlike a flip-flop, a latch is level-sensitive, not edge-triggered. Latches are almost always undesirable in synchronous designs because:
- They are transparent to glitches on data inputs during the enable window
- They create timing exceptions that are hard to close
- Most synthesis guidelines forbid them unless intentionally designed

The `always_comb` keyword in SystemVerilog tells the synthesis tool: "I promise this is combinational." The tool then ENFORCES that every variable assigned in the block is assigned in every possible execution path. If you forget a branch, the tool generates a warning or error.

In our FSM's combinational block, the very first line is:

```systemverilog
always_comb begin
    next_state = state;  // Default assignment — covers every unspecified branch
    ...
end
```

This default assignment is the key. By assigning `next_state = state` before the `if/case` tree, every branch that does not explicitly reassign `next_state` will simply hold its current value — but as a combinational function of `state`, not as a latch. Without this default, any branch that does not assign `next_state` would require the synthesis tool to "remember" the old value, which implies a latch.

**Rule**: In `always_comb`, always start with a default assignment for every output variable. Then conditionally override it.

### 13.3 Reset Strategy — Asynchronous `negedge rst_n`

All sequential blocks in the design use:

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        signal <= RESET_VALUE;
    end else begin
        // Normal operation
    end
end
```

This is **asynchronous active-LOW reset**. "Asynchronous" means the reset does not wait for a clock edge — as soon as `rst_n` goes LOW, every flip-flop with this sensitivity list immediately drives its reset value, regardless of where `clk` is in its cycle.

**Why asynchronous?** In FPGA and ASIC designs, asynchronous reset is preferred for safety-critical signals (like the FSM state register) because it guarantees a known state even if the clock is not running yet (for example, during power-on before the PLL has locked).

**Why active-LOW?** Most embedded systems use active-LOW reset because it matches the electrical behavior of a power-on-reset circuit: the reset pin is pulled HIGH by a resistor (inactive), and the reset is triggered by pulling it LOW (active). This also means that if the reset wire breaks or floats, the system defaults to "not in reset" — a safer default than accidentally staying in reset forever.

**Reset values are chosen for bus safety**:
- `sda_o <= 1'b1` — release SDA (do not pull the bus LOW during reset)
- `scl_o <= 1'b1` — release SCL (do not interfere with the bus during reset)
- `state <= SLV_IDLE` — slave is not active
- `stretch_active <= 1'b0` — not stretching
- `active_int <= 1'b0` — no active transaction

If any of these reset to the wrong value — say `sda_o` reset to `0` — the slave would pull SDA LOW the instant reset released, which looks exactly like a START condition on the I2C bus. Every other device on the bus would see a spurious START and potentially get confused.

### 13.4 The `sda_o` vs `sda` Distinction

Inside the RTL, the slave drives the internal register `sda_o`. The actual I2C SDA wire is `sda` (the `inout` port). The connection between them is the open-drain assign:

```systemverilog
assign sda = (sda_o == 1'b0) ? 1'b0 : 1'bz;
```

In synthesis, this becomes an **output enable** pattern. The synthesis tool maps it to a tri-state buffer (OBUFT on Xilinx, IOBUF on other FPGAs, or a standard cell with enable in ASICs). When `sda_o == 0`, the buffer drives LOW. When `sda_o == 1`, the buffer is disabled (high-Z).

This distinction matters:
- `sda_o` is a register — it is clean, glitch-free (only changes on clock edges), and can be probed freely in simulation
- `sda` is the actual wire — it can have glitches, reflections, and voltage hazards; it reflects whatever is driven by ALL devices on the bus

In simulation, always probe `sda_o` for debugging the slave's intent. Probe `sda` to see what actually appears on the bus (the result of all drivers combined).

### 13.5 Timing Closure — Critical Paths

A **critical path** is the longest combinational path in the design — the path that limits how fast the clock can run. If the critical path's propagation delay is longer than one clock period, setup violations occur and the design fails timing.

For this slave controller, the most timing-critical paths are:

**Path 1: SCL input → scl_rise/scl_fall → next_state computation**

```
scl_i (input pin) → scl_d flip-flop → scl_rise = scl_i AND !scl_d → next_state logic → state flip-flop setup
```

This path must complete within one clock period (20 ns at 50 MHz). The input pin adds IO delay, the flip-flop has clock-to-Q delay, the AND gate is fast, and the `next_state` combinational logic has a deep mux tree (10-way case statement). This is the longest path.

**Path 2: SDA input → sda_d → start_cond → next_state**

```
sda_i → sda_d → start_cond (AND3) → next_state override → state
```

The `start_cond` AND gate is simple, but it feeds directly into the highest-priority override in `next_state` — so the combinational depth after `sda_d` is small.

**Path 3: bit_cnt → next_state condition**

```
bit_cnt flip-flop → comparator (bit_cnt == 8) → next_state case → state flip-flop
```

The comparator on `bit_cnt` is a 4-bit equality check, which is fast.

**Key insight for timing closure**: If this design needed to run faster (say, 200 MHz), the critical path would be the SCL edge-to-next-state path. The fix would be to pipeline the `next_state` computation — add a register stage between the edge detection and the FSM update. This introduces one cycle of latency but cuts the combinational path in half.

### 13.6 Clock Domain Crossings — Is scl Asynchronous?

Yes. `scl_i` is the I2C SCL signal. It is generated by the I2C master at 100 kHz. The slave's system clock is 50 MHz. These are **completely independent clocks** — the master's clock generator has no relationship to the slave's system clock.

This means `scl_i` is an **asynchronous input** from the perspective of the slave's `clk` domain. Sampling an asynchronous signal directly with a flip-flop clocked on `clk` can cause **metastability**: the flip-flop's output oscillates or settles to an unpredictable value if the input changes too close to the clock edge.

**The standard fix** for asynchronous inputs is a **two flip-flop synchronizer**:

```systemverilog
// Two-FF synchronizer for SCL
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scl_sync1 <= 1'b1;
        scl_sync2 <= 1'b1;  // scl_i used inside the design is scl_sync2
    end else begin
        scl_sync1 <= scl;       // First stage: may go metastable
        scl_sync2 <= scl_sync1; // Second stage: stable by now (MTBF argument)
    end
end
assign scl_i = scl_sync2;
```

The first flip-flop may go metastable, but it has a full clock period to resolve before the second flip-flop samples it. With a 50 MHz clock and typical flip-flop metastability resolution time constants, the Mean Time Between Failures (MTBF) with a two-FF synchronizer exceeds millions of years — acceptable for nearly all designs.

**Why does the current RTL appear to skip this?** In the as-written RTL, `scl_i` is directly assigned from the `inout` wire:

```systemverilog
assign scl_i = scl;
```

And `sda_i`:
```systemverilog
assign sda_i = sda;
```

These are combinational assignments with no synchronizer. In a real ASIC or FPGA targeting > 50 MHz with tight timing, you would add the two-FF synchronizer. For this project running at 50 MHz with a 100 kHz I2C clock (a 500:1 ratio), metastability events are very rare, and the design works in practice — but a production-quality implementation would add the synchronizer explicitly.

### 13.7 The Two Flip-Flop Synchronizer — Why It Works

The mathematics of metastability tells us: a flip-flop that goes metastable will resolve within time `t_r` with probability that grows exponentially with `t_r`. After one full clock period, the probability of still being metastable is astronomically small.

The two-FF synchronizer exploits this: the FIRST flip-flop is allowed to go metastable. The SECOND flip-flop is clocked one full period later. By then, the first flip-flop has almost certainly resolved to a stable 0 or 1. The second flip-flop sees a clean input and samples it reliably.

The rules for synchronizers:
1. **Always use exactly 2 FF stages** (3 for very high frequencies, but 2 is standard)
2. **Never add combinational logic between synchronizer stages** — it defeats the purpose
3. **Synchronize each independent signal separately** — do not try to synchronize a multi-bit bus with independent synchronizers (the bits may not sample together, causing "torn reads")
4. **For multi-bit values** (like a data byte), use a handshake protocol or a Gray-coded counter, not raw synchronizers

---

## Part 14: Verification Plan for the Slave Controller

A verification plan (vplan) is a document written BEFORE any testbench code. It defines WHAT needs to be verified and HOW. Without a vplan, verification is ad-hoc — engineers write tests based on what they happen to think of, leaving large holes in coverage.

A professional vplan for the slave controller would look like this:

### 14.1 Feature List and Coverage Goals

| Feature ID | Feature Description | Priority | Target Coverage |
|------------|---------------------|----------|-----------------|
| F01 | Address decode — correct SLAVE_ADDR ACK'd | Critical | 100% |
| F02 | Address decode — wrong address NACK'd | Critical | 100% |
| F03 | RX path — single-byte write | Critical | 100% |
| F04 | RX path — burst write (2-8 bytes) | Critical | 100% |
| F05 | TX path — single-byte read | Critical | 100% |
| F06 | TX path — burst read (2-8 bytes) | Critical | 100% |
| F07 | ACK generation — address ACK | Critical | 100% |
| F08 | ACK generation — data ACK | Critical | 100% |
| F09 | NACK generation — address NACK | Critical | 100% |
| F10 | NACK generation — forced data NACK via `force_data_nack` | High | 100% |
| F11 | Clock stretching — basic stretch-and-resume | High | 100% |
| F12 | Clock stretching — correct duration (`stretch_cycles` exact) | High | 100% |
| F13 | Clock stretching — resume to correct FSM state | High | 100% |
| F14 | Repeated START handling | High | 100% |
| F15 | STOP detection from any state | High | 100% |
| F16 | reg_bank output reflects written data | Critical | 100% |
| F17 | reg_updated strobe is one cycle wide | High | 100% |
| F18 | reg_ptr wraps correctly on 8+ byte burst | Medium | 100% |

### 14.2 Stimulus, Expected Response, and Check Method

**F01 — Address decode, correct address ACKed**

- **Stimulus**: Drive START, then clock out `{SLAVE_ADDR, 1'b0}` on SDA (write transaction). Clock SCL for 9 cycles.
- **Expected response**: On the 9th SCL cycle, `sda` is pulled LOW by the slave (ACK). `addr_match` output goes HIGH. `active` output goes HIGH.
- **How to check**: Monitor asserts `sda == 1'b0` during SCL-high window of cycle 9. Scoreboard checks `addr_match === 1'b1` and `active === 1'b1`.

**F02 — Address decode, wrong address NACKed**

- **Stimulus**: Drive START, then clock out `{SLAVE_ADDR ^ 7'h01, 1'b0}` (one address bit flipped). Clock SCL for 9 cycles.
- **Expected response**: SDA stays HIGH (slave does not pull it low). `addr_match` remains LOW. `active` remains LOW. Slave goes to IDLE.
- **How to check**: Monitor asserts `sda == 1'b1` during cycle 9 SCL-high window. Scoreboard verifies no register was updated.

**F03 — RX path, single-byte write**

- **Stimulus**: Complete address ACK sequence, then clock out one data byte (e.g., `8'hA5`) on SDA. Send STOP.
- **Expected response**: `rx_data_valid` goes HIGH in `SLV_RX_ACK`. `rx_data == 8'hA5`. `reg_bank[0] == 8'hA5`. `reg_updated[0]` pulses HIGH for exactly one clock cycle.
- **How to check**: Scoreboard compares `reg_bank[0]` to written value after STOP. Coverage bin captures the specific data value (all-zeros, all-ones, and random mid-range values).

**F11 — Clock stretching, basic operation**

- **Stimulus**: Mid-transaction, assert `stretch_en` (rising edge). Set `stretch_cycles = 20`.
- **Expected response**: `stretch_active` goes HIGH. SCL wire is held LOW. FSM enters `SLV_STRETCH`. After 20 cycles, `stretch_active` clears, SCL releases, FSM returns to `saved_state`.
- **How to check**: Monitor counts cycles between `stretch_active` rising edge and falling edge, asserts count == 20. Monitor checks that SCL is LOW throughout. Scoreboard verifies the transaction completes normally after stretch releases.

### 14.3 Corner Cases

**Corner Case CC01 — Address boundary: all-zeros address (0x00)**

Address `7'h00` is the I2C "general call" address. If `SLAVE_ADDR` is configured to `7'h00`, the slave would respond to general calls. More importantly, the address comparison logic must handle `0x00` without special-casing. Verify that `shift_reg[6:0] == SLAVE_ADDR` works when both are `0x00`.

**Corner Case CC02 — Address boundary: all-ones address (0x7F)**

Address `7'h7F` is in the reserved range per the I2C spec (addresses `1111_xxx` are reserved). Verify the RTL still handles it correctly at the logic level — the parameter is set by the user, not validated. This ensures the comparison logic is bit-correct at both extremes.

**Corner Case CC03 — Maximum burst write (8 bytes)**

Write exactly 8 bytes in a single transaction: `{0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22}`. Verify all 8 registers are written correctly. Then write a 9th byte — `reg_ptr` should wrap from 7 to 0 (3-bit counter overflow), overwriting `reg_bank[0]`. This tests that the design does not hang or corrupt on overflow.

**Corner Case CC04 — Simultaneous clock stretch and force_data_nack**

Assert both `stretch_en` and `force_data_nack` during `SLV_RX_ACK`. The slave must: (a) enter `SLV_STRETCH` due to stretch, and (b) when it returns to `SLV_RX_ACK`, drive SDA HIGH (NACK) due to `force_data_nack`. Verify the order of events and that both features compose correctly.

**Corner Case CC05 — Repeated START mid-burst**

After writing 2 bytes (ACK received for both), the master sends a Repeated START instead of a 3rd byte or STOP. The slave must immediately enter `SLV_START` (the global `start_cond` priority fires). Verify `active_int` is reset correctly and the new transaction starts cleanly.

**Corner Case CC06 — STOP in the middle of an address byte**

Assert STOP while in `SLV_ADDR` (after 4 bits of the address have been clocked in). The global `stop_cond` check must override the `SLV_ADDR` state and transition to `SLV_IDLE`. Verify no partial address write occurs.

### 14.4 Negative Tests

**Negative Test NT01 — Wrong address, followed by data**

Send a wrong address (NACK scenario). Then continue driving data bytes on SDA as if the slave had ACK'd. The slave must remain in `SLV_IDLE` and ignore all subsequent bus traffic. `reg_bank` must not be modified.

**Negative Test NT02 — NACK during write (force_data_nack)**

Assert `force_data_nack`. Perform a write transaction. The slave NACKs the first data byte. The master (per I2C protocol) should generate STOP. Verify: (a) slave correctly NACKs (SDA HIGH in 9th data clock), (b) `rx_data_valid` still goes HIGH so the testbench can observe what was received, (c) `reg_bank[0]` is NOT written (the NACK implies the byte was rejected), or IS written depending on your design choice — the vplan must specify which behavior is expected so the scoreboard can check it.

**Negative Test NT03 — Clock stretch timeout (stretch_cycles = MAX_CLK_STRETCH)**

Set `stretch_cycles = 1000` (the `MAX_CLK_STRETCH` value from `i2c_pkg.sv`). Verify the stretch runs for exactly 1000 cycles and releases. This ensures the timer does not overflow its 16-bit width at the maximum value. Check: `stretch_active` HIGH for exactly 1000 cycles.

**Negative Test NT04 — stretch_en asserted while idle**

Assert `stretch_en` while the slave is in `SLV_IDLE` with no transaction in progress. The `active_int` guard must prevent `stretch_active` from firing. SCL must not be pulled LOW. This was exactly Bug #5 before the fix.

---

## Part 15: How to Debug the Slave Controller in Simulation

Debugging a failing I2C simulation is a skill. This section gives you a step-by-step decision tree for the three most common failure modes.

### 15.1 "My Slave Isn't ACKing — Where Do I Look?"

**Symptom**: You send a write transaction to the slave. On the 9th SCL cycle, SDA stays HIGH (no ACK). The master sees NACK and aborts.

**Step 1: Check `active_int`**

Look at `active_int` in the waveform. Is it going HIGH after the address byte?

- If `active_int == 0` after the address phase: the slave did not see the transaction as addressed to it, OR it never even processed the address.
- If `active_int == 1`: the address was recognized, but the ACK drive failed — go to Step 3.

**Step 2: Check `rx_addr` vs `SLAVE_ADDR`**

Examine `rx_addr` in the waveform after the address byte is complete (after 8 `scl_rise` events from `SLV_START`).

- Does `rx_addr == SLAVE_ADDR`? If not, the slave received a different address than what it is configured for. Check: Was `SLAVE_ADDR` set correctly at instantiation? Is the testbench sending the right address?
- Is `addr_matched == 1'b1`? This is the result of the comparison. If `rx_addr == SLAVE_ADDR` but `addr_matched == 0`, there is a combinational logic bug in the comparison.

Also check `bit_cnt`: did it count correctly from 0 to 8? If `bit_cnt` never reached 8, the slave may not have counted enough `scl_rise` events. This could mean `scl_rise` was not firing — check that `scl_d` is updating correctly.

**Step 3: Check the `SLV_ACK` State**

Look at the FSM `state` signal. Did it transition to `SLV_ACK` after `bit_cnt == 8 && scl_fall`?

- If `state` never enters `SLV_ACK`: the transition condition was not met. Check `bit_cnt` and `scl_fall` timing. The fall must happen WHILE `bit_cnt == 8`, not before or after.
- If `state` is in `SLV_ACK`: check `sda_o`. Is it `1'b0` (slave is driving ACK)?

If `sda_o == 1'b0` but `sda == 1'b1`, the open-drain assignment is broken. Check:
```systemverilog
assign sda = (sda_o == 1'b0) ? 1'b0 : 1'bz;
```
In simulation, if the testbench is also driving `sda` and not releasing it to `1'bz`, the `sda` wire will show the testbench's value, not the slave's.

**Step 4: Check SCL Timing Relative to SDA**

The master samples SDA when SCL is HIGH. The slave must drive `sda_o <= 1'b0` BEFORE SCL goes HIGH. Check: is `sda_o` updated one clock cycle before `scl_rise`? If the slave drives `sda_o` on the same cycle SCL rises, the master may sample SDA before the slave's output is valid. This is a setup time violation.

---

### 15.2 "My Slave Is Sending Wrong Data — Where Do I Look?"

**Symptom**: You write known values to the slave's registers, then do a read transaction. The master receives wrong bytes.

**Step 1: Check `tx_shift_reg` Load Value**

Set a breakpoint or waveform cursor at the cycle where `state == SLV_ACK && addr_matched && rx_rw == 1'b1`. At this moment, `tx_shift_reg` should be loaded from `internal_regs[reg_ptr]`.

- What is `internal_regs[0]` at this point? Did the prior write transaction populate it correctly? (If not, the TX problem is really an RX problem — see Section 15.1.)
- What is `tx_shift_reg` after the load? It should equal `internal_regs[0]`.
- If `tx_shift_reg` is `8'h00` after the load, `internal_regs[0]` was never written. Confirm with a write transaction first.

**Step 2: Check `reg_ptr` at Load Time**

At the load moment (`SLV_ACK` with `rx_rw==1`), what is `reg_ptr`? It should be `3'd0` — reset by the `state == SLV_ACK && addr_matched` condition.

If `reg_ptr` is not 0 at load time, the reset of `reg_ptr` on address match is failing. Check that `addr_matched` is actually HIGH at that cycle.

**Step 3: Check MSB-First Shift Sequence**

Place your cursor at the first `scl_fall` in `SLV_TX` state. Check `tx_shift_reg`:

- Before `scl_fall`: `tx_shift_reg[7]` is the first bit being driven (it should be bit 7 of the data byte).
- After `scl_fall`: `tx_shift_reg` shifts left: `{tx_shift_reg[6:0], 1'b0}`. Now bit 6 of the original value is in position 7.
- On the NEXT `scl_rise`, the master samples `sda`, which should be driven from the NEW `tx_shift_reg[7]`.

Trace through all 8 bits manually, as in Section 5.2. If the sequence is correct but the bits look wrong, you may have the data in the register wrong. If the bits are in the wrong ORDER (LSB first instead of MSB first), the shift direction is wrong — check `{tx_shift_reg[6:0], 1'b0}` vs `{1'b0, tx_shift_reg[7:1]}` (left-shift vs right-shift).

**Step 4: Check SDA Output Timing**

In `SLV_TX`, `sda_o` is driven from `tx_shift_reg[7]`. The shift happens on `scl_fall`. The master samples SDA on `scl_rise`. The sequence must be:

```
scl_fall → tx_shift_reg shifts → sda_o = new tx_shift_reg[7] → ... → scl_rise (master samples)
```

If the shift is happening on `scl_rise` instead of `scl_fall`, the master would sample the OLD bit (before the shift), seeing the correct first bit but then all subsequent bits one bit late. This looks like a one-bit offset in the received data.

---

### 15.3 "Clock Stretching Isn't Releasing — Where Do I Look?"

**Symptom**: The slave enters `SLV_STRETCH`, SCL goes LOW, and never comes back HIGH. The simulation hangs.

**Step 1: Check `stretch_active` Signal**

Find the cycle where `stretch_active` went HIGH. Confirm it was triggered by `stretch_en_rise && !stretch_active && active_int`. Verify all three conditions were true at that cycle.

Now watch `stretch_active` going forward. Does it ever go LOW? If the simulation hangs with `stretch_active` stuck HIGH, the timer is not counting down — or the comparator is not firing.

**Step 2: Check `stretch_timer` vs `stretch_cycles`**

Look at `stretch_timer` after `stretch_active` goes HIGH:

- Is it starting at `16'd1` (after the fix)? If it starts at `16'd0`, the Bug #14 off-by-one is present.
- Is it incrementing each cycle? It should count: 1, 2, 3, ..., `stretch_cycles`.
- What is `stretch_cycles`? Read the testbench — what value was set? If `stretch_cycles` is `16'd0` or `16'hFFFF`, the behavior is unusual:
  - `stretch_cycles = 0`: timer starts at 1, check is `1 >= 0` which is TRUE immediately — stretch releases after 1 cycle. This is correct behavior.
  - `stretch_cycles = 16'hFFFF`: timer counts up to 65535, which takes 1310 ms at 50 MHz. The simulation will appear to hang because it is not actually hung — it is counting. This is a testbench configuration error.

**Step 3: Check `saved_state` Register Value**

Once `stretch_active` clears, does the FSM exit `SLV_STRETCH`? The condition is `!stretch_active` → `next_state = saved_state`.

What is `saved_state`? It should be the FSM state from the moment stretch was triggered (the state just before `SLV_STRETCH` was entered). If `saved_state == SLV_STRETCH` or `saved_state == SLV_IDLE`, there is a bug in the `saved_state` capture logic:

```systemverilog
if (stretch_active && state != SLV_STRETCH)
    saved_state <= state;
```

Check: was this condition true at the cycle when stretch was first activated? Specifically, at that cycle `stretch_active` should have just become `1'b1` (registered on the same edge) and `state` should NOT yet be `SLV_STRETCH` (that happens next cycle when `next_state = SLV_STRETCH` is registered). If your simulation shows `saved_state` is `SLV_STRETCH`, the condition timing is off.

Also verify that `saved_state` does not keep getting overwritten while in `SLV_STRETCH` — the `state != SLV_STRETCH` guard is critical for this.

---

## Part 16: Comparing This Design to a Real-World I2C Slave

It is worth stepping back to ask: how does this RTL compare to what you would find inside a commercial chip? Understanding the simplifications helps you know what "production quality" means and what additional work would be needed to ship this in a product.

### 16.1 What This RTL Has That Is Production-Quality

**Open-drain model**: The `assign sda = (sda_o == 1'b0) ? 1'b0 : 1'bz;` pattern is exactly how real I2C slaves are implemented. The distinction between driving LOW and releasing to high-Z is correct per the I2C specification and is directly synthesizable.

**Clock stretching with timer**: The ability to hold SCL LOW for a configurable number of cycles — and then release it cleanly — is a feature present in many production I2C peripherals (EEPROM slaves, sensor ICs, OLED controllers). The timer-based implementation is correct and practical.

**ACK/NACK control**: The separation between address ACK (based on address match) and data ACK (based on `force_data_nack` or internal readiness) mirrors real hardware. Production chips use internal signals like "FIFO full" or "write-protect active" to gate the data ACK in exactly this way.

**FSM global priority for START/STOP**: Checking `start_cond` and `stop_cond` before the case statement is the correct approach for handling Repeated START mid-transaction. This is a spec requirement and is handled correctly here.

**Parameterized slave address**: Using `parameter logic [6:0] SLAVE_ADDR = 7'h50` means the same RTL can be reused for different addresses without code changes. This is standard practice for IP reuse.

### 16.2 What Is Simplified Compared to Production

**Single master only**: This design assumes exactly one I2C master on the bus. In a real multi-master I2C system, bus arbitration is required: if two masters try to drive SDA simultaneously, each must monitor the wire and back off if it sees its driven 1 overridden by another master's 0. The `STS_ARB_LOST` status is defined in `i2c_pkg.sv` but is never generated by this slave — and the slave does not need it (only masters arbitrate). However, if this design were extended to include a master, arbitration logic would be needed.

**No address masking / multi-address**: Some I2C devices respond to a range of addresses (for example, an EEPROM might respond to any address in `7'h50`–`7'h57`, with the lower 3 bits determined by hardware pins). Our design responds to exactly one address. A production design would add an address mask register: `addr_matched = ((shift_reg[6:0] & addr_mask) == (SLAVE_ADDR & addr_mask))`.

**No 10-bit addressing**: The I2C specification defines 10-bit addressing mode for systems that need more than 112 device addresses. This design only supports 7-bit addressing. 10-bit addressing requires recognizing a two-byte address header and changes the FSM significantly.

**No clock synchronization/bus timeout**: Production I2C controllers include a timeout counter: if SCL stays LOW for longer than a threshold (per the I2C spec, a slave must release SCL within a bounded time), the controller resets. This design does not implement a SCL LOW timeout, meaning a stuck SCL would lock up the slave permanently.

**Simplified register model**: The 8-register flat array starting at address 0 is a simplification. Real devices use register address bytes — the first data byte written after the address byte is the register address, and subsequent bytes are the data. For example: `[START][ADDR+W][REG=0x05][DATA=0xAB][STOP]` — write 0xAB to register 5. This design treats the first data byte as data for register 0, not as a register address pointer.

### 16.3 What a Real Production Chip Adds

**Interrupt output**: A real slave asserts an interrupt to the host CPU when a transaction completes, a register is written, or an error occurs. The `reg_updated[0:7]` outputs are a simplified version of this, but a real design would combine them into a single interrupt line with an interrupt status register and mask register.

**Multiple clock domains and proper synchronization**: In a real chip, the I2C interface logic (driven by the SCL/SDA pins, effectively in the "I2C clock domain") is separate from the CPU register interface (driven by the system bus clock). Data crossing between these domains uses proper two-FF synchronizers for control signals and Gray-coded counters or handshake protocols for data buses.

**Power management**: Real I2C slaves support low-power modes. The slave can operate from the I2C bus power (no system clock needed) for address detection, then wake up the system clock only when it recognizes its address. This is called "SMBus alert" or "address-match wakeup." It requires a separate low-power always-on clock domain.

**Glitch filtering**: Real I2C input buffers include spike filters that suppress noise pulses shorter than 50 ns (per the Fast-mode I2C spec). A digital implementation adds a small counter: the signal must be stable for N consecutive cycles before being accepted. This prevents SCL glitches from causing false edge detections.

**ESD protection and analog IO**: On a real chip, the SCL and SDA pins have electrostatic discharge protection diodes, open-drain driver transistors, and programmable slew rate control. The RTL model presented here assumes ideal wire connections — real IO cells add delay, capacitance, and protection that the RTL does not model.

**Formal address reservation checking**: Production I2C controllers check that the configured slave address is not in a reserved range (per the I2C spec, addresses `0000_0xx` and `1111_1xx` are reserved). Our design does not validate `SLAVE_ADDR` at elaboration time. A real design would add:

```systemverilog
initial begin
    if (SLAVE_ADDR[6:3] == 4'b0000 || SLAVE_ADDR[6:3] == 4'b1111) begin
        $error("SLAVE_ADDR %0h is in reserved range per I2C spec", SLAVE_ADDR);
    end
end
```

This is a synthesis-time check that catches misconfiguration early.

### 16.4 Summary Comparison Table

| Feature | This Design | Production Chip |
|---------|-------------|-----------------|
| Open-drain model | Yes (correct) | Yes |
| Clock stretching | Yes (timer-based) | Yes (often adaptive) |
| ACK/NACK control | Yes (force hook) | Yes (internal conditions) |
| 7-bit address | Yes | Yes |
| 10-bit address | No | Most chips |
| Multi-master arbitration | No | Yes (if master capable) |
| Register address pointer | No (fixed offset 0) | Yes (first data byte) |
| Address masking | No | Many chips |
| Input glitch filter | No | Yes |
| Two-FF synchronizer | Not explicit | Always |
| Interrupt output | Simplified (reg_updated) | Yes (with mask/status) |
| Multiple clock domains | No | Yes |
| Power management | No | Yes |
| SCL timeout protection | No | Yes |
| Address range validation | No | Yes |

Understanding where this design sits relative to production helps you ask the right questions in interviews and design reviews: "What assumptions are we making that a real chip would handle?"

---

*Document created: 2026-05-12 | Project: Summer Internship I2C DV | Author: Senior Verification Engineer*
