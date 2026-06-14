> **⚠️ 2026-06-10 AUDIT UPDATE — read this box before trusting the lesson below.**
> A deep audit + fix pass changed the code this walkthrough describes. Deltas for this file:
> - SCL/SDA inputs are now 2-flop synchronized before all edge detection (CDC).
> - `sda_o` updates in SLV_ACK/SLV_RX_ACK/SLV_TX are gated on SCL-low and HELD through SCL-high (UM10204 data-validity rule).
> - Stretch arming changed: a `stretch_pending` latch holds a stretch_en rising edge until the transaction is active — the old edge-AND-active condition meant the DUT NEVER actually stretched in UVM runs.
> - `saved_state` is captured exactly on the transition INTO SLV_STRETCH; `reg_ptr` resets only on ENTRY to SLV_ACK; dead SLV_STOP state and shadowed inner START/STOP branches removed; `rx_data_valid` is now a 1-cycle strobe.
> Full detail: [`19_audit_fixes_walkthrough.md`](./19_audit_fixes_walkthrough.md) and `docs/AUDIT_FIX_REPORT.md`.

# Lesson 04 — `i2c_slave_controller.sv` Deep Dive

**File under study:** `rtl/i2c_slave_controller.sv` (~529 lines, 18 KB)
**DUT role:** This file IS the device-under-test. Everything you verified, every bug you found, every coverpoint you closed — it all aimed at this module.
**Concepts covered:** Slave FSM design, edge-detect START/STOP, address compare, ACK timing, RX/TX shift registers, clock stretching, fault injection, observability ports, 2-state vs 4-state synthesis
**Date:** 2026-05-17

---

## Table of Contents

1. [Architecture — The Slave's Role in I2C](#1-architecture--the-slaves-role-in-i2c)
2. [The 60-Second Elevator Pitch](#2-the-60-second-elevator-pitch)
3. [START / STOP Detection — Sensing Without Owning the Bus](#3-start--stop-detection--sensing-without-owning-the-bus)
4. [Address Byte Decoding — Match or Stay Silent](#4-address-byte-decoding--match-or-stay-silent)
5. [ACK Generation — The Most Time-Critical Action](#5-ack-generation--the-most-time-critical-action)
6. [RX Data Path — Sampling SDA on SCL High](#6-rx-data-path--sampling-sda-on-scl-high)
7. [TX Data Path — Driving SDA, Reading the Bank](#7-tx-data-path--driving-sda-reading-the-bank)
8. [Clock Stretching — How a Slave Slows the Master](#8-clock-stretching--how-a-slave-slows-the-master)
9. [Fault Injection — `force_data_nack`](#9-fault-injection--force_data_nack)
10. [Register Bank — Observability & `reg_updated` Flags](#10-register-bank--observability--reg_updated-flags)
11. [Quiz — 20 Questions](#11-quiz--20-questions)
12. [Quiz — Answers & Senior-Grade Explanations](#12-quiz--answers--senior-grade-explanations)
13. [Key Takeaways](#13-key-takeaways)
14. [Action Items](#14-action-items)
15. [Honest Self-Score Template](#15-honest-self-score-template)

---

## 1. Architecture — The Slave's Role in I2C

Before line-by-line reading, internalize **what a slave actually does on an I2C bus** vs the master. This is a recurring interview lens — many candidates flunk because they describe the slave as "just listens to the master" and miss the subtleties.

### Master vs Slave — Role Asymmetry

| Aspect | Master | Slave (this DUT) |
|---|---|---|
| Owns SCL? | Yes (drives) | No — but can **stretch low** |
| Initiates START/STOP? | Yes | Never |
| Generates addresses? | Yes | Compares against own `SLAVE_ADDR` |
| Drives SDA when? | Sending bytes; reading-NACK | When sending ACK; when transmitting data byte on read |
| Reads SDA when? | Receiving bytes; reading slave-ACK | Receiving address; receiving data byte; checking master-ACK |
| Generates clock edges? | Yes (`scl_o` toggling) | No — only pulls low for stretch |
| Observability ports we cared about | `cmd_done`, `status`, `done` | `reg_bank`, `reg_updated[]`, `addr_match`, `active`, `rx_data_valid` |

**Key mental model:** The slave is a **stateful pattern-matcher**. It watches the bus, decodes incoming bytes, and responds **at very precise moments** — getting an ACK out one half-SCL-cycle late means the master reads `1` (NACK) instead of `0` (ACK), and the transaction collapses. **Slave bugs are nearly always timing bugs.**

### FSM — ASCII State Diagram

```
                            +-----------+
            +---------------|  SLV_IDLE |<-----------------+
            |               +-----------+                  |
            | start_cond                                   | stop_cond
            v                                              |
       +-----------+                                  +-----------+
       | SLV_START |                                  |  SLV_STOP |
       +-----------+                                  +-----------+
            |                                              ^
            v                                              | stop_cond
       +-----------+    bit_cnt==8                         |
       | SLV_ADDR  |--- &  scl_fall ---> +-----------+     |
       +-----------+                     |  SLV_ACK  |     |
            ^                            +-----------+     |
            | (continue shifting)         |          \     |
            |                             | match &   \    |
            |                             | rw==0      \   |
            |                             v             \  |
            |                        +-----------+       \ |
            |                        |  SLV_RX   |        \|
            |                        +-----------+         |
            |                             |                |
            |                bit_cnt==8 &  scl_fall        |
            |                             v                |
            |                        +------------+        |
            |                        | SLV_RX_ACK |--------+ (stop_cond)
            |                        +------------+
            |                             |
            |              scl_fall (continue)
            |                             v
            |                        (loops back to SLV_RX)
            |
            |                       match & rw==1
            |                             |
            |                             v
            |                        +-----------+
            |                        |  SLV_TX   |
            |                        +-----------+
            |                             |
            |                bit_cnt==8 &  scl_fall
            |                             v
            |                        +-------------+
            |                        | SLV_TX_ACK  |---+ master ACK (sda=0)
            |                        +-------------+    \
            |                             | master NACK  \-> back to SLV_TX
            |                             | (sda=1)
            |                             v
            +---- (SLV_IDLE on NACK) -----+

   Overlay (orthogonal):
   +--------------+
   | SLV_STRETCH  |  ← Entered from ANY active state when stretch_active && active_int
   +--------------+    Returns to saved_state when stretch_timer expires
```

Notice three things that trip up freshers:

1. **`SLV_START` is a 1-cycle transit state.** It does no work — it exists so the FSM has a clean "I just saw START" tick before sampling the address.
2. **`SLV_ACK` and `SLV_RX_ACK` are *not* the same state.** `SLV_ACK` is for the address byte's ACK; `SLV_RX_ACK` is for every subsequent data byte's ACK. Junior designers conflate them and end up with bugs like "first byte ACKs but data bytes don't."
3. **`SLV_STRETCH` is an *orthogonal* overlay.** It can be entered from any active state and returns to where it came from via `saved_state`. Most slave FSM diagrams in textbooks hide this — read carefully.

### File Section Map

| Lines | Section | What it does |
|---|---|---|
| 12-43 | Port list | Defines the slave's I/O — note the observability ports (`reg_bank`, `addr_match`, `active`) |
| 47-108 | Internal signal declarations | All the latches, counters, flags |
| 110-138 | SCL/START/STOP edge detection | The "senses" of the slave |
| 140-167 | Bit counter & shift register | Byte assembly |
| 169-218 | Address latching, register pointer, RX byte latching | The "memory" |
| 220-271 | Register bank + TX shift register | The "payload" path |
| 273-318 | SDA & SCL output (open-drain) | The "voice" |
| 320-364 | Active flag + clock stretch logic | Bookkeeping & throttling |
| 366-515 | Main FSM (sequential + combinational) | The "brain" |
| 517-527 | Status outputs | Telemetry to TB |

---

## 2. The 60-Second Elevator Pitch

When an NVIDIA/Qualcomm/Intel interviewer asks: *"Walk me through your DUT,"* **say this**:

> *"The DUT is a 7-bit I2C slave at address 0x50, running Standard Mode. Internally it's a 10-state FSM driven by SCL-rise and SCL-fall edge detection. It senses START and STOP combinationally — falling SDA while SCL is high, and rising SDA while SCL is high, respectively. On every SCL-rise it shifts SDA into an 8-bit shift register. After 8 bits, it compares against `SLAVE_ADDR` and either pulls SDA low for an ACK or stays released. For writes, the next byte goes into one of eight internal registers indexed by an auto-incrementing pointer. For reads, the slave drives MSB-first from a TX shift register, then samples master's ACK on the 9th bit to decide if it should keep transmitting or release. It also supports clock stretching — when `stretch_en` rises mid-transaction, the slave pulls SCL low for `stretch_cycles` system clocks. I found and fixed 15 bugs in this module — including a one-cycle ACK timing slip and a clock-stretch counter off-by-one."*

Memorize the **shape**. The bullets are: address, FSM, edge detection, ACK path, register pointer, TX path, stretch, bugs.

---

## 3. START / STOP Detection — Sensing Without Owning the Bus

This is the single most asked slave-design question in interviews. **A slave does not control SCL or SDA** (except for ACK and stretch). So how does it know a transaction has started?

### The Code

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

### Why "SDA edge while SCL is high"?

**Spec rule:** During a normal data byte, SDA is *only allowed to change while SCL is low*. So if SDA changes while SCL is high, it is **definitionally** either a START (falling edge) or a STOP (rising edge). Nothing else.

### What `sda_d` is doing

`sda_d` is the **registered previous value** of SDA. By comparing the current sampled SDA (`sda_i`) with the prior cycle's value (`sda_d`), the slave gets a **one-system-clock-wide edge pulse**. Combined with `scl_i` being high, you have your START/STOP detector.

### Senior-engineer thought process

There is a subtle hazard here. `scl_i` and `sda_i` are **external asynchronous inputs**. If they're not properly synchronized, a glitch could appear simultaneously on both lines and look like a START. Production slaves add a **2-flip-flop synchronizer + glitch filter** in front:

```
sda_pad --> [FF1] --> [FF2] --> [Glitch filter, e.g., 3-of-5 majority] --> sda_i
```

This DUT skips that step — fine for simulation, **a real silicon implementation would absolutely need it** (and a digital-glitch-filter spec compliance like `t_SP ≥ 50 ns` for Standard Mode).

**Interview-grade answer:**

> *"The slave detects START by looking for a falling SDA edge while SCL is high, using a one-cycle delayed copy of SDA to derive the edge. STOP is the rising version. Per the I2C spec, SDA may only transition while SCL is low during data — so any SDA edge while SCL is high is unambiguously a framing event. In production silicon I'd add a 2-FF synchronizer and a 50-ns glitch filter before this detector to satisfy the spec's `t_SP` parameter; this DUT skips that step for simulation simplicity."*

### Interview trap

> *"What if SCL itself is glitching and goes briefly high during a normal data bit? Could your detector trigger a false START?"*

Answer: **Yes — and that's why glitch filtering is part of the I2C compliance spec.** A naive implementation will false-trigger on bus noise. Mention this proactively in interviews; it shows spec awareness.

### Why detection is in `assign` (combinational) and not a state

The conditions are checked **every clock**, regardless of state. This is the right call: a START or STOP can occur **mid-transaction** (Repeated START is the obvious case, but also master aborts). If detection lived inside the FSM's state-specific logic, you'd miss these. Notice in the code that the next-state logic always pre-empts with `start_cond` / `stop_cond` at the top of `always_comb`:

```systemverilog
// Lines 386-390
if (start_cond) begin
  next_state = SLV_START;
end else if (stop_cond) begin
  next_state = SLV_IDLE;
end else begin
  case (state) ...
```

That ordering is **deliberate and load-bearing**. Removing it would break Repeated START handling.

---

## 4. Address Byte Decoding — Match or Stay Silent

### The Code

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

### Walkthrough

1. **First 7 SCL rises:** Each rise shifts SDA into `shift_reg` from the right. After 7 rises, `shift_reg[6:0]` holds the 7-bit address; the 8th bit (R/W) hasn't been shifted yet.
2. **At `bit_cnt == 7` and `scl_rise`** (the 8th rising edge):
   - `shift_reg[6:0]` is the **OLD value** before this rise (non-blocking semantics — RHS reads the registered value, not the about-to-be-written one).
   - `sda_i` is the **current SDA** which IS the R/W bit being sampled now.
   - So `rx_addr` ← top 7 bits of shift_reg (old) and `rx_rw` ← current SDA.
3. `addr_matched` is computed combinationally on the same edge.

### The "where is the R/W bit?" trap

This is one of the most asked SV semantic questions. Re-read carefully:

```systemverilog
rx_addr      <= shift_reg[6:0];  // OLD shift_reg → 7-bit addr
rx_rw        <= sda_i;            // CURRENT SDA   → R/W bit
addr_matched <= (shift_reg[6:0] == SLAVE_ADDR);
```

**Why does this work?** Non-blocking (`<=`) means RHS evaluates **before** any LHS updates. So `shift_reg[6:0]` is the value from the PREVIOUS clock — which contains only the first 7 bits of the address (the R/W bit hasn't been shifted in yet).

If a junior had written:

```systemverilog
shift_reg <= {shift_reg[6:0], sda_i};
if (bit_cnt == 7) rx_addr <= shift_reg[7:1];  // ❌ WRONG
```

…they'd be reading the **same OLD shift_reg** and trying to slice it differently. The R/W bit would be missing from `shift_reg` at this point.

### Interview-grade answer

> *"On the 8th SCL rise of the address phase, the slave latches `rx_addr` from the lower 7 bits of `shift_reg` and `rx_rw` directly from current SDA. This works because non-blocking assignment reads the pre-update value of `shift_reg`, which contains the first 7 address bits before this rise integrates the 8th bit. The address compare is combinational with `SLAVE_ADDR` and the result drops into `addr_matched`. If the parameter were 8 bits or if I needed multi-address aliasing, I'd add a programmable mask register."*

### What if the address doesn't match?

```systemverilog
// SLV_ACK next_state, line 423-433
SLV_ACK: begin
  if (scl_fall) begin
    if (addr_matched) begin
      if (rx_rw == 1'b1) next_state = SLV_TX;
      else                next_state = SLV_RX;
    end else begin
      next_state = SLV_IDLE; // Addr mismatch, ignore transaction
    end
  end ...
```

On mismatch, the slave returns to IDLE — and critically, **never asserts SDA = 0** in the ACK slot (see `sda_o` logic: `else sda_o <= 1'b1;`). That release-high *is* the NACK from a slave perspective. Master sees `1` on SDA during the 9th SCL high, interprets NACK, and aborts.

### Reserved addresses

The slave does **not** filter reserved addresses (e.g., `0000xxx` general-call, `1111xxx` Hs-mode codes). It only checks for exact match against `SLAVE_ADDR = 7'h50`. So if a (broken or malicious) master tried `7'h00`, this slave would ignore it. The package's `is_valid_addr()` helper exists for the master side; the slave is naturally protected by exact-match.

**Interview trap:** *"Does your slave respond to a general call (0x00)?"* → "No, exact-match only. Adding general-call support would need an OR'd condition in the address compare."

---

## 5. ACK Generation — The Most Time-Critical Action

### Why ACK is dangerous

Per spec, the slave must drive SDA = 0 **during the entire high period of the 9th SCL clock**. The master samples SDA at the middle of SCL-high. If the slave is even **one half-SCL period late**, the master reads SDA = 1 (released line) and interprets NACK. **You will get this question. Memorize the timing.**

### The Code — Two ACK States

```systemverilog
// Lines 280-291
case (state)
  SLV_ACK: begin
    if (addr_matched) sda_o <= 1'b0; // ACK (match found)
    else              sda_o <= 1'b1; // NACK (no match)
  end
  SLV_RX_ACK: begin
    if (active_int && !force_data_nack) sda_o <= 1'b0; // ACK
    else                                 sda_o <= 1'b1; // NACK
  end
```

### Timing diagram

```
            8 clocks: address byte                       9th clock: ACK
            
SCL:     __|‾|__|‾|__|‾|__|‾|__|‾|__|‾|__|‾|__|‾|________|‾‾‾‾‾‾‾‾|________
                                                          ^         ^
                                                   slave drives    slave
                                                   sda=0 here     releases
                                                   (must be set   (after scl_fall
                                                    BEFORE scl    going to SLV_RX
                                                    rises)        or SLV_IDLE)
SDA:     [A6][A5][A4][A3][A2][A1][A0][R/W]  ----- ACK = 0 -----  -----------
```

### When does the slave actually start driving low?

Look at the FSM:

```systemverilog
// Lines 412-417: SLV_ADDR -> SLV_ACK on bit_cnt==8 && scl_fall
SLV_ADDR: begin
  if (bit_cnt == 4'd8 && scl_fall) begin
    next_state = SLV_ACK;
```

The transition happens on the **SCL falling edge** after the 8 address bits. So one system clock later, the FSM is in `SLV_ACK`, and the SDA output register (`sda_o`) becomes `0` on the next `posedge clk` (since `sda_o` is in an `always_ff`). The slave is now driving SDA low **while SCL is low**, with plenty of margin before SCL goes high again. 

### Bug class: ACK timing slip

The classic bug pattern:

1. FSM transitions to `SLV_ACK` correctly.
2. But the `sda_o` logic is missing the `SLV_ACK` case (default = 1).
3. Or worse, `sda_o` is combinationally tied to state and the state register is registered → one cycle late → master misses ACK window.

**Story for interview:** *"One of the 15 bugs I found was an ACK that asserted one half-cycle too late because the SDA output register pipeline depth wasn't accounting for the SCL-fall to state-transition latency. Fix was to either go combinational on SDA-out during ACK states, or pre-emptively set `sda_o = 0` in `SLV_ADDR` when `bit_cnt == 8 && scl_fall && addr_matched`."*

### Why `sda_o` is `always_ff` and not `always_comb`

If `sda_o` were combinational on `state`, every state change would propagate to SDA *immediately* — including glitches during state transitions. Registering it gives a clean, glitch-free output **at the cost of one clock of latency**. The design pre-computes the next ACK state on `scl_fall` to absorb that latency.

### Senior-engineer thought process

> *"A frequent slave bug is treating ACK timing as 'just go to the ACK state.' The reality is: from the master's perspective, ACK is sampled at a specific moment in SCL-high. The slave must drive SDA low BEFORE the master starts seeing SCL rise. That means using SCL-fall (not SCL-rise) as the trigger to enter the ACK state, registering the output to avoid glitches, and verifying with an assertion like `assert property (@(posedge clk) (state == SLV_ACK && scl_rise && addr_matched) |-> (sda_o == 1'b0))`."*

---

## 6. RX Data Path — Sampling SDA on SCL High

### The "sample SDA on SCL high" rule

Per spec: **SDA must be stable during SCL-high.** Therefore, the slave samples SDA on **SCL rising edges**. That's why the shift register is clocked by `scl_rise`.

### The Code

```systemverilog
// Lines 158-167 — shift register
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    shift_reg <= 8'h00;
  end else if (scl_rise) begin
    if (state == SLV_ADDR || state == SLV_RX) begin
      shift_reg <= {shift_reg[6:0], sda_i};   // ← left shift, new bit at bit 0
    end
  end
end
```

### Shift direction — left, MSB-first

I2C is **MSB-first on the wire**. So the first SDA sample is `bit[7]` of the byte. The shift register receives it at bit 0 first, then shifts left, so after 8 samples:

```
After bit 0 captured: shift_reg = 8'b0000000X  (X = A6, the MSB)
After bit 1:          shift_reg = 8'b000000XY
After bit 7:          shift_reg = 8'bXYZABCDE  (full byte, A6 in bit 7)
```

**Common bug:** Shifting *right* instead of *left*. Result: the byte assembles bit-reversed. Master sends `0x50` (`0101_0000`), slave reads `0x0A` (`0000_1010`), no address match, slave goes silent. Master shows NACK and aborts. Hard to debug because the symptom is "slave isn't responding" but the bus traces look fine.

**Interview trap:** *"If I send 0x50 and your slave never ACKs, name three bugs that could cause it."*
1. Shift direction wrong.
2. SCL edge detector wrong polarity (firing on falling not rising).
3. Address compare against wrong field of `shift_reg`.

### The "latched RX byte" trick (lines 212-218)

This is where the file's comments shout `FIX:`. Read carefully:

```systemverilog
// Latch the rx_byte on scl_fall after all 8 data bits are received  
// This avoids using the ACK bit (9th) as the 8th data bit
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    latched_rx_byte <= 8'h00;
  end else if (state == SLV_RX && bit_cnt == 4'd7 && scl_rise) begin
    latched_rx_byte <= {shift_reg[6:0], sda_i}; // Correct: last data bit captured on last scl_rise
  end
end
```

**Why this exists:** The 8th SCL rise samples bit 0 (LSB) of the data byte. The 9th SCL rise is the ACK slot — that's not data. If you read `rx_data` directly from `shift_reg` *after* the 9th rise, you've corrupted byte[0] with the ACK bit. The latch freezes the byte at the right moment.

**Interview-grade answer:**

> *"Naive RX paths use the shift register itself as the output byte. The bug: by the time downstream logic reads `shift_reg`, the 9th SCL rise has already shifted in the ACK bit on bit 0. The fix is to latch the byte the moment the 8th data bit is captured — on the 8th SCL rise — into a separate `latched_rx_byte` register, and only expose THAT to the testbench and register-bank-write path."*

### The byte assembly timing trick

Note the timing math:
- `bit_cnt == 0` at start of SLV_RX.
- After 1st `scl_rise`, `bit_cnt → 1`.
- After 7 rises, `bit_cnt == 7` and the 8th bit is **about to be captured** on this very rise.
- At that moment: `latched_rx_byte <= {shift_reg[6:0], sda_i}`.

`shift_reg[6:0]` is the 7 bits that arrived in rises 1-7. `sda_i` is the 8th bit on the wire right now. Non-blocking semantics save us: the latch grabs the not-yet-shifted-in 8th bit directly from SDA, while shift_reg still holds bits 1-7.

This is the same trick used for address latching. It's a **non-blocking idiom worth memorizing** — it appears in countless real designs.

---

## 7. TX Data Path — Driving SDA, Reading the Bank

### When the slave talks

The slave only drives SDA in three scenarios:
1. **ACK after address byte** (`SLV_ACK` state, address match)
2. **ACK after received data byte** (`SLV_RX_ACK` state)
3. **Transmitting a data byte during master read** (`SLV_TX` state)

### The TX shift register

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

### Three modes of load/shift

| Event | Action |
|---|---|
| Address ACK with R/W=1 | Load first byte from `internal_regs[0]` (reg_ptr was just reset) |
| Master ACK received (SLV_TX_ACK, sda_i==0 on scl_fall) | Load next byte from `internal_regs[reg_ptr]` (reg_ptr was incremented one-shot) |
| Inside SLV_TX, every scl_fall | Shift left by one, zero-fill LSB |

### The SDA-output for TX

```systemverilog
// Lines 294-300
SLV_TX: begin
  if (active_int) begin
    sda_o <= tx_shift_reg[7]; // MSB first from shift register
  end else begin
    sda_o <= 1'b1;
  end
end
```

The MSB of `tx_shift_reg` is **always** what gets driven onto SDA. Each `scl_fall` shifts the register left, so the next MSB takes its place. After 8 falls, the byte has been fully transmitted.

### Why drive on SCL-fall, not SCL-rise

Spec: **SDA must be stable during SCL-high.** So all SDA changes must happen during SCL-low. The shift trigger is `scl_fall` — placing the new SDA value safely into the low phase, with plenty of setup time before SCL rises and the master samples.

If you shifted on `scl_rise`, you'd be changing SDA *during* SCL-high — a spec violation that looks like a START or STOP to other devices on the bus.

### NACK handling — master tells slave "stop sending"

```systemverilog
// Lines 476-487
SLV_TX_ACK: begin
  if (stop_cond) begin
    next_state = SLV_STOP;
  end else if (start_cond) begin
    next_state = SLV_START; // Repeated START
  end else if (scl_fall) begin
    if (sda_i == 1'b0) next_state = SLV_TX;       // Master ACK → continue
    else                next_state = SLV_IDLE;     // Master NACK → done
  end ...
```

Master tells slave to stop sending more bytes by **driving SDA = 1** during the 9th clock (NACK). The slave samples this on `scl_fall` (entering the bit-time after the 9th high), and transitions to IDLE.

**This is the standard "last byte" pattern in master-read transactions:** master ACKs bytes 1..N-1, NACKs byte N, then issues STOP.

### Senior-engineer thought process

> *"A slave's TX path has three orthogonal concerns: (a) loading bytes from the register source, (b) shifting them MSB-first onto SDA aligned to SCL phase, and (c) responding to master ACK/NACK. The shift trigger MUST be SCL-fall — anything else violates the I2C stability rule. The load trigger has two modes: 'initial byte' on transitioning into SLV_ACK with R/W=1, and 'subsequent bytes' on master-ACK-detected. The NACK detection in SLV_TX_ACK collapses the FSM to IDLE — but a real implementation needs to confirm STOP follows soon after, else flag a protocol error."*

---

## 8. Clock Stretching — How a Slave Slows the Master

### What clock stretching is

A slow slave that can't process data fast enough has one tool: **pull SCL low and hold it there.** The master is supposed to detect SCL-low-when-it-released-it and **wait**. This is called clock stretching.

### Open-drain physics

I2C SCL is an open-drain line with a pull-up. Anyone can pull it low; release means "let pull-up bring it high." If master releases (drives Z) but slave is still pulling low, the line stays low. Master must monitor SCL and **not advance** until the line goes high.

### The Code

```systemverilog
// Lines 58 — SCL output declaration
assign scl = (scl_o == 1'b0) ? 1'b0 : 1'bz;

// Lines 338-364
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) stretch_en_d <= 1'b0;
  else        stretch_en_d <= stretch_en;
end
assign stretch_en_rise = stretch_en && !stretch_en_d;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    stretch_timer  <= 16'd0;
    stretch_active <= 1'b0;
  end else if (stretch_en_rise && !stretch_active && active_int) begin
    stretch_active <= 1'b1;
    stretch_timer  <= 16'd1;  // FIX BUG #15: start at 1, not 0
  end else if (stretch_active) begin
    if (stretch_timer >= stretch_cycles) begin
      stretch_active <= 1'b0;
    end else begin
      stretch_timer <= stretch_timer + 1'b1;
    end
  end
end

// Lines 310-318 — drive SCL low when stretching
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    scl_o <= 1'b1;
  end else if (stretch_active) begin
    scl_o <= 1'b0;
  end else begin
    scl_o <= 1'b1;
  end
end
```

### The edge-detect rationale

```systemverilog
assign stretch_en_rise = stretch_en && !stretch_en_d;
```

**Why edge, not level?** If the trigger was level (`stretch_en == 1`), and the testbench held `stretch_en` high for the whole simulation, the slave would re-enter stretch every time it tried to exit — infinite stretch. The edge-detect makes it a **one-shot trigger**: each rising edge of `stretch_en` arms exactly one stretch event. This is **BUG #14** in your DUT history.

### The off-by-one timer fix

The comments document the fix in detail:

```
// FIX BUG #15: Initialize timer at 1, not 0.
// With timer=0 and ">=", the stretch lasted stretch_cycles+1 cycles
// because the check at cycle N fires after N increments (0→1→...→N).
// Starting at 1 aligns the >= check so it fires after exactly
// stretch_cycles cycles: timer goes 1, 2, ..., stretch_cycles → fires.
```

**Walk it through:**
- If `stretch_cycles = 10`, starting timer at 0 means: at cycle 10, timer reaches 10, check fires — but the stretch was active for cycles 0, 1, ..., 10 = **11 cycles**.
- Starting at 1: timer goes 1, 2, ..., 10, check fires — **10 cycles active**. Correct.

This is the classic "fence-post error" rendered in hardware. Every junior writes it wrong the first time.

### FSM integration — `SLV_STRETCH` as overlay

```systemverilog
// Lines 369-378
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    state <= SLV_IDLE;
    saved_state <= SLV_IDLE;
  end else begin
    if (stretch_active && state != SLV_STRETCH)
      saved_state <= state;
    state <= next_state;
  end
end

// Lines 513-514
if (stretch_active && active_int) next_state = SLV_STRETCH;
```

**Mechanism:** When `stretch_active` rises, the sequential block snapshots the current state into `saved_state`, then the combinational block forces `next_state = SLV_STRETCH`. The FSM sits in `SLV_STRETCH` for as long as `stretch_active` is high. When stretch ends, `SLV_STRETCH` returns to `saved_state`.

This is a **classic "interrupted state" pattern**. Same trick used in CPU pipeline stalls — freeze the pipeline state and resume.

### Interview-grade answer

> *"The slave implements clock stretching by pulling SCL low through an open-drain output. The trigger uses an edge detector on `stretch_en` so each pulse arms exactly one stretch event — otherwise a held-high enable would cause infinite stretch. The stretch duration is counted in system clocks via a 16-bit timer initialized to 1 (not 0) to avoid an off-by-one error — with `>=` semantics, starting at 0 gives N+1 active cycles, starting at 1 gives N. The FSM enters a `SLV_STRETCH` state via an overlay rule that snapshots the current state into `saved_state` and forces the next-state to `SLV_STRETCH`. On exit, the FSM resumes from `saved_state`. This is the same interrupted-state pattern used in pipeline stalls."*

### What if the master times out?

The spec defines `t_TIMEOUT` (~25 ms) — if SCL stays low that long, master can recover and assume the slave is broken. The DUT doesn't enforce a timeout cap; the testbench must verify `stretch_cycles * T_CLK < 25 ms` to stay spec-compliant.

---

## 9. Fault Injection — `force_data_nack`

### The Code

```systemverilog
// Lines 287-291
SLV_RX_ACK: begin
  if (active_int && !force_data_nack) sda_o <= 1'b0; // ACK
  else                                 sda_o <= 1'b1; // NACK
end
```

### Mechanism

When `force_data_nack` is asserted by the testbench, the slave **deliberately NACKs** every received data byte — even when it would normally ACK. The signal bypasses normal ACK logic with a simple AND gate.

### Why this exists

In DV, you must **verify the master's NACK-handling path**. Question: how do you get a real slave to NACK? Normally a slave ACKs every byte it can store. To force a NACK from outside, you need a backdoor — `force_data_nack` is that backdoor.

### Where in the FSM it influences

Only in `SLV_RX_ACK`. It does **not** affect:
- Address ACK (`SLV_ACK`) — slave still ACKs the address normally
- TX direction — slave still drives data bits as before
- START/STOP detection — orthogonal

This is a **scope-bounded fault injection** — exactly the right thing for a verification port.

### Interview-grade answer

> *"`force_data_nack` is a fault-injection port for the verification environment. It overrides the normal ACK logic during data-byte ACK slots — when asserted, the slave drives SDA = 1 instead of 0, simulating a slave that can't accept more data. We use it to verify the master's NACK-handling path: does the master correctly abort, set status to STS_NACK, raise the interrupt, etc.? Importantly, the fault is scope-bounded — it doesn't affect address ACK or TX data, so we can isolate the master's data-NACK behavior without breaking the rest of the transaction setup."*

### Senior thought process — fault injection vs functional bypass

There's a design-discipline trap here: **fault injection ports shouldn't be in the netlist that ships to silicon.** Two options:

1. **Conditional compile:** Wrap fault-injection in `` `ifdef DV_FAULT_INJECTION``.
2. **Test-mode register:** Gate `force_data_nack` behind a TEST_MODE register that's strapped off in production.

This DUT exposes the port unconditionally — fine for class projects, **bad for silicon**. Mention this in interviews to show silicon-readiness awareness.

---

## 10. Register Bank — Observability & `reg_updated` Flags

### The Code

```systemverilog
// Lines 99-100
logic [7:0] internal_regs [0:7];
logic       internal_updated [0:7];

// Lines 223-244
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    for (int i = 0; i < 8; i++) begin
      internal_regs[i]    <= 8'h00;
      internal_updated[i] <= 1'b0;
    end
    rx_write_done <= 1'b0;
  end else begin
    for (int i = 0; i < 8; i++) begin
      internal_updated[i] <= 1'b0;       // Clear all strobes
    end

    if (state == SLV_RX_ACK && active_int && (rx_rw == 1'b0) && !rx_write_done) begin
      internal_regs[reg_ptr]    <= latched_rx_byte;
      internal_updated[reg_ptr] <= 1'b1;
      rx_write_done             <= 1'b1;
    end else if (state != SLV_RX_ACK) begin
      rx_write_done <= 1'b0;
    end
  end
end
```

### Why a register bank?

The slave needs **somewhere to put received data and somewhere to read TX data from**. A small bank of 8 bytes is the simplest model — real I2C slaves like EEPROMs or sensor IPs typically have a much larger register space addressed by an "internal pointer" byte the master sends first.

### The auto-increment pointer (lines 190-205)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    reg_ptr <= 3'd0;
    reg_ptr_inc_done <= 1'b0;
  end else if (state == SLV_ACK && addr_matched) begin
    reg_ptr <= 3'd0;                      // Reset pointer at start of transaction
  end else if (state == SLV_RX_ACK && active_int && rx_rw == 1'b0 && !reg_ptr_inc_done) begin
    reg_ptr <= reg_ptr + 1'b1;
    reg_ptr_inc_done <= 1'b1;
  end else if (state == SLV_TX_ACK && active_int && rx_rw == 1'b1 && !reg_ptr_inc_done) begin
    reg_ptr <= reg_ptr + 1'b1;
    reg_ptr_inc_done <= 1'b1;
  end else if (state != SLV_RX_ACK && state != SLV_TX_ACK) begin
    reg_ptr_inc_done <= 1'b0;             // Re-arm guard
  end
end
```

**Behavior:** Pointer starts at 0 each transaction; increments by 1 after each byte's ACK slot completes. Wraps at 7→0 (3-bit register).

### The `_done` guard — preventing double-increment

`reg_ptr_inc_done` is a **one-shot latch**: once the increment fires in a given ACK state, the guard prevents it from firing again until the state changes. Without this guard, the increment would fire every clock the FSM is in `SLV_RX_ACK` — for the entire SCL-high duration. That's potentially hundreds of system clocks → pointer overruns wildly.

**Interview trap:** *"Why not just increment once when entering the state?"* Answer: in an `always_ff`, there's no "entering" event — you can only sample `state == X`. The guard latch is the standard way to fire exactly once per state visit.

### `reg_updated[]` — strobed flags

Each `internal_updated[i]` is a **one-clock-wide strobe** — set when register `i` is written, cleared on the next clock by the `for` loop at the top of the block.

This is a **classic pattern for write-strobed outputs**:
- Allows the testbench to detect a write event without having to compare the register value (which might not change).
- Combinable into interrupts: OR all strobes and you have a "register written" interrupt.

**Why important for DV?** Your scoreboard uses these flags to know *when* a write happened, so it can compare expected vs actual at the right moment. Without strobes, you'd have to poll register values — race-prone.

### The output ports

```systemverilog
output logic [7:0]  reg_bank    [0:7],
output logic        reg_updated [0:7],
output logic        addr_match,
output logic        active,
```

These are pure **observability** — they exist for the testbench, not for the bus. In silicon, the bank values would be exposed via a CPU-side register interface (APB/AHB); the strobes might gate an interrupt. **The DV testbench shortcut is to expose them directly as RTL ports.**

### Interview-grade answer

> *"The slave has an 8-byte register bank with a 3-bit auto-incrementing pointer. The pointer resets at the start of a matched-address transaction and increments after every ACK slot completes — with a one-shot guard latch to prevent re-increment within the same state. Each register also has a one-clock-wide `reg_updated` strobe that fires the cycle a write completes, enabling event-driven scoreboarding in the testbench. The strobes and bank are exposed as direct RTL ports for verification visibility — in silicon, this would be a CPU-side memory-mapped interface."*

---

## 11. Quiz — 20 Questions

Cover the answers below. Take a clean stab at each.

1. **How does the slave detect a START without controlling SCL or SDA?** Walk through the gate-level mechanism.

2. **Why is the START/STOP detection check `if (start_cond) ... else if (stop_cond) ...` placed *outside* the `case (state)` statement instead of inside each state?**

3. **Predict the bug:** A junior modifies the shift register to use `scl_fall` instead of `scl_rise`. What happens? Walk through the I2C spec violation and what the master sees.

4. **In the address-latching block, `rx_addr <= shift_reg[6:0]` and `rx_rw <= sda_i` happen on the same edge. Why do these two reads pick up *different* bits of the address byte?** Explain the non-blocking semantics that make this correct.

5. **What bug would happen if the address compare were done one SCL cycle too early — at `bit_cnt == 6` instead of `bit_cnt == 7`?**

6. **The ACK pulldown of SDA is registered (`always_ff`), not combinational. What's the timing-margin reason for registering it?** What's the cost?

7. **Explain why the TX shift trigger is `scl_fall` and never `scl_rise`.** Cite the spec rule that forces this.

8. **What's the purpose of `latched_rx_byte`?** What goes wrong if you skip it and feed `shift_reg` directly into the register bank's write path?

9. **The `reg_ptr` increment uses a `reg_ptr_inc_done` latch as a one-shot guard. Describe the bug that occurs without this guard.** Be specific about how many times the pointer would increment.

10. **In `SLV_RX_ACK`, the next-state logic checks `stop_cond`, `start_cond`, and `scl_fall` in that order. What does this priority encoding tell you about the expected I2C transaction structure?**

11. **Clock stretching uses an edge detector on `stretch_en` instead of level sensitivity. Describe the bug that level-sensitivity would cause.** Walk through what a testbench mistake could trigger.

12. **The stretch timer starts at 1, not 0. Walk through why starting at 0 gives `stretch_cycles + 1` cycles of stretch.**

13. **Predict the bug:** Suppose someone removes the `active_int` check from the stretch-trigger condition. Now `stretch_active` can fire when the slave is idle. What's the consequence for other slaves on the bus?

14. **The `SLV_STRETCH` state uses a `saved_state` register to resume after stretch. Why is `saved_state` snapshotted in the **sequential** block (`always_ff`) instead of the combinational next-state block?**

15. **`force_data_nack` overrides the SDA output in `SLV_RX_ACK` only. List three other places in the FSM where you'd expect a fault-injection port — but where this signal does NOT reach. Why is the scope deliberate?**

16. **2-state vs 4-state synthesis:** If we synthesized this DUT with a 2-state simulator (only 0/1, no X), what kind of bug would silently survive that would show up in a 4-state sim?

17. **Reset behavior:** What's the state of `reg_bank[0..7]`, `addr_match`, and `sda_o` immediately after `rst_n` is asserted? Why does the reset clear `rx_write_done` explicitly (line 229)?

18. **Repeated START in the middle of a write transaction:** Master sends START → ADDR(W) → DATA1 → REPEATED-START → ADDR(R) → reads. Trace the slave's FSM transitions. Where is the danger that the slave could miss the repeated START?

19. **Interview articulation:** A hiring manager says *"Walk me through how your slave knows when to drive SDA and when to release it."* Give the 30-second senior-grade answer.

20. **What is the single most likely *real-silicon* bug you'd expect to see in this DUT that doesn't show up in simulation?** (Think glitch filter, async sync, metastability.)

---

## 12. Quiz — Answers & Senior-Grade Explanations

### Q1 — How does the slave detect START?

The slave never owns SCL or SDA — it just **samples** them every system clock. The detection mechanism is:

1. SDA is sampled every `posedge clk` into `sda_i` (via the inout/assign).
2. The previous value is registered into `sda_d`.
3. A combinational expression checks: `start_cond = sda_i == 0 && sda_d == 1 && scl_i == 1`.
4. That expression is consumed by the next-state logic outside the `case`.

**The key insight:** edge detection requires **two samples in time** — current and previous. This is the universal pattern for "detect a transition" in synchronous logic.

**Interview-grade answer:**

> *"The slave samples SDA and SCL every system clock, then derives a one-cycle-delayed copy of SDA. Combinationally, it asserts START when the delayed SDA was high but current SDA is low, and SCL is high simultaneously. The spec guarantees SDA may only change while SCL is low during data, so any SDA edge during SCL-high is unambiguously a framing condition — falling for START, rising for STOP."*

---

### Q2 — Why is START/STOP detection outside the `case`?

**Junior answer:** "To save lines of code."

**Senior-engineer answer:** Because START and STOP can occur **at any time** during the transaction — including mid-byte and mid-ACK. Specifically:

- **Repeated START** in the middle of `SLV_RX_ACK` → must transition to `SLV_START`, not `SLV_RX`.
- **Master abort** mid-byte (rare but spec-legal) → must transition to `SLV_IDLE`.
- **Glitch on SDA during a critical transition** → may need to flag bus error.

If detection lived inside each state's branch, you'd have to replicate the check in every state — error-prone, and easy to miss one state. The "global" check at the top of the next-state logic is a clean defensive pattern.

**Interview-grade answer:**

> *"START and STOP are asynchronous events relative to the FSM's expected sequence — they can interrupt any state. Putting the detection above the case statement makes it a global override that's impossible to forget when adding new states. This is the same defensive pattern as putting reset above all logic — it's the highest-priority condition."*

---

### Q3 — Predict the bug: shift register on `scl_fall`

**Walkthrough:**

If shift triggers on SCL-fall, the slave samples SDA *during the SCL-low phase*. Per spec, SDA is allowed to change while SCL is low. **So the slave is sampling SDA while it's actively transitioning** — undefined values, race with the master's drive.

What the master sees: ACK works (slave still drives SDA low in the ACK state), but the data bits look corrupted. Result: master writes 0x55, slave's register receives 0xAA or something random. Scoreboard fails on the data compare. Debug points at the register bank — but the bug is in the shift trigger.

**Interview-grade answer:**

> *"Shifting on SCL-fall samples SDA during the SCL-low phase when SDA is allowed to be in transition per the I2C spec. The result is data corruption — random bits enter the shift register. The address compare might still pass occasionally if the bits happen to settle correctly, leading to intermittent failures that are very hard to debug. The correct trigger is SCL-rise, when SDA is guaranteed stable."*

---

### Q4 — Non-blocking semantics in address latching

The two assignments:
```systemverilog
rx_addr <= shift_reg[6:0];  // Reads OLD shift_reg
rx_rw   <= sda_i;            // Reads CURRENT sda_i
```

happen on the same `posedge clk`. Non-blocking `<=` semantics say: **all RHS evaluations happen before any LHS update.** So `shift_reg[6:0]` reads the value `shift_reg` had **before** this clock — that's the value containing bits A6..A0 from the first 7 SCL rises.

Meanwhile, `sda_i` is a **continuous wire**, sampling the pin in real time. At this clock edge, SDA on the bus is the R/W bit (because we're in the 8th SCL-rise window).

So the two reads pick up: shift_reg = "the 7 already-shifted address bits," sda_i = "the R/W bit currently on the wire." Both correct, both at the same edge.

**Interview-grade answer:**

> *"Non-blocking assignment guarantees all RHS expressions evaluate first, then all LHS updates happen atomically. So `shift_reg[6:0]` reads the value before this clock — the 7 address bits shifted in over the previous 7 SCL rises. Simultaneously, `sda_i` reads the current wire value, which is the R/W bit being clocked in right now. The result: in a single clock edge, the slave assembles the full 8-bit address byte cleanly. If we used blocking `=`, the order would matter and we'd risk reading the not-yet-updated shift_reg."*

---

### Q5 — Address compare one cycle too early

If `bit_cnt == 6` triggers the compare, the slave is making the decision on **6 received bits** plus whatever was in shift_reg from before. Specifically, only A6..A1 have been shifted in — A0 hasn't arrived yet. The compare uses 7 bits of shift_reg, but the bottom bit is stale (likely 0 from reset, or junk from a previous transaction).

Result: address match fires (or fails) **non-deterministically**. Sometimes 0x50 looks like 0x50 because the stale LSB happened to be 0; sometimes it looks like 0x51. Master sees inconsistent ACK behavior.

**Bug class:** "Off-by-one in the bit counter compare." Same family as the clock-stretch timer fence-post error.

---

### Q6 — Registering the SDA output

**Cost:** One clock of latency between FSM state and SDA output.

**Benefit:** **Glitch-free output.** A combinational SDA-output would propagate every state transition, every flag flip, every `addr_matched` change — directly to the open-drain pin. Any combinational glitch in those upstream signals would show up as a momentary SDA dip during SCL-high → false NACK or false START detected by master.

Registering forces SDA to change only on `posedge clk`, after all upstream signals have settled. The one-clock latency is absorbed by triggering the state transition on `scl_fall` rather than `scl_rise`.

**Interview-grade answer:**

> *"Registering SDA gives a glitch-free output at the cost of one system-clock latency. The latency is hidden by triggering state transitions on SCL-fall so the registered output is updated well before SCL rises. If SDA were combinational, every upstream flag transition could cause a brief SDA glitch — disastrous because the master would interpret it as a false START or NACK. This is the standard pattern for bus outputs: register at the boundary, design upstream timing to absorb the latency."*

---

### Q7 — TX shift on `scl_fall` only

**Spec rule:** *"SDA may only change while SCL is low."* (I2C spec, NXP UM10204.)

If TX shifts on `scl_rise`, SDA changes during SCL-high. That's spec-violating. Worse: a falling-SDA-during-SCL-high looks **exactly like a START condition** to every other device on the bus, including the master itself. The master might abort, other slaves might think a new transaction is starting → bus chaos.

Therefore: TX shift trigger must be `scl_fall` (or earlier in the SCL-low phase). The slave gets the entire SCL-low duration as setup time before the master starts reading SCL-high.

---

### Q8 — Why `latched_rx_byte` exists

Without latching, downstream code reads `shift_reg` to get the byte. But by the time downstream consumes it, the 9th SCL rise has shifted in the ACK bit, polluting bit 0.

Specifically:
- After 8th SCL rise: `shift_reg = [D7..D0]` (good byte).
- 9th SCL rise (ACK slot, sampling SDA which is low if slave is ACKing): `shift_reg = [D6..D0, 0]` — D7 fell off the left, ACK bit (0) at bit 0.

If the register bank's write path reads `shift_reg` on the 9th rise or after, it writes a shifted, ACK-polluted byte. The data is mangled.

**Fix:** Latch `latched_rx_byte` on the 8th SCL rise (when shift_reg + current SDA together form the full byte) and use that latch for downstream writes.

---

### Q9 — `reg_ptr_inc_done` guard latch

Without the guard:

```systemverilog
end else if (state == SLV_RX_ACK && active_int && rx_rw == 1'b0) begin
  reg_ptr <= reg_ptr + 1'b1;
end ...
```

The slave is in `SLV_RX_ACK` for the **entire 9th SCL clock period** — that's `T_SCL_PERIOD / 2 = 250` system clocks (Standard Mode at 50 MHz). Every single system clock, `reg_ptr` increments by 1. Result: pointer wraps around the 3-bit space ~30 times during one ACK slot.

Net effect: by the time the slave is ready to receive the next data byte, `reg_ptr` is at some pseudo-random value. Subsequent writes land in the wrong register.

**The fix:** A one-shot latch (`reg_ptr_inc_done`) that gates the increment to fire exactly once per `SLV_RX_ACK` visit, then re-arms when the state changes.

**Interview-grade answer:**

> *"Without a one-shot guard, `reg_ptr` would increment every system clock the FSM is in SLV_RX_ACK — about 250 times in Standard Mode. The pointer would wrap around the 8-entry bank many times and land somewhere unpredictable. The `_inc_done` latch fires the increment once and then blocks further increments until the state changes, re-arming the latch. This is the standard 'edge-trigger inside a level-stable state' pattern — same idea as edge-detecting `stretch_en`."*

---

### Q10 — Priority encoding in `SLV_RX_ACK`

```systemverilog
SLV_RX_ACK: begin
  if (stop_cond) begin
    next_state = SLV_STOP;          // Priority 1
  end else if (start_cond) begin
    next_state = SLV_START;         // Priority 2 (Repeated START)
  end else if (scl_fall) begin
    next_state = SLV_RX;            // Priority 3 (normal continue)
```

**What this tells you about the protocol:**

1. **STOP can preempt anything** — master might decide to end the transaction at any byte boundary. Highest priority because STOP must be detected even if other conditions look true.
2. **Repeated START is legal mid-transaction** — typically used to switch from write-to-read without releasing the bus (combined write-then-read EEPROM access).
3. **Normal continue is the default** — on SCL-fall (master moving to next bit-time), go back to SLV_RX to receive the next byte.

If priorities were reversed, you'd miss STOP because SCL-fall would always be true first.

**Interview-grade answer:**

> *"The priority order tells you the protocol structure: STOP and Repeated START are global preemptions that can happen at any byte boundary, and the normal byte-continue path is the default. STOP is highest priority because a missed STOP leaves the slave hung waiting for more data, while a missed Repeated START at worst makes one transaction look like two. The if-else-if order encodes this hierarchy directly."*

---

### Q11 — Level vs edge sensitivity on `stretch_en`

**With level sensitivity:**

If the testbench drives `stretch_en = 1` and holds it high, the slave triggers stretch. Stretch fires for `stretch_cycles`, releases SCL. Immediately, `stretch_en` is still high → trigger condition is still true → stretch fires again. Infinite loop.

The SCL line is held low forever. Master times out, simulation hangs. **Real bug from BUG #14 in this project's history.**

**With edge sensitivity:**

```systemverilog
assign stretch_en_rise = stretch_en && !stretch_en_d;
```

The trigger is `stretch_en_rise` — true for exactly one clock when `stretch_en` transitions 0→1. Each pulse arms exactly one stretch event; subsequent stretch requires `stretch_en` to fall and rise again.

**Interview-grade answer:**

> *"Level-sensitivity creates infinite re-trigger — the moment stretch ends, the level is still high, so stretch fires again immediately, hanging SCL low forever. The master times out and the bus deadlocks. Edge-sensitivity makes each rising edge of stretch_en a one-shot arm; the testbench must explicitly pulse the signal to request another stretch. This is the same edge-vs-level lesson that applies to interrupt request lines: level-sensitive IRQs need explicit clear-acknowledge, edge-sensitive IRQs are self-clearing."*

---

### Q12 — Timer starting at 1, not 0

Let `stretch_cycles = N`.

**With timer init = 0:**
- Cycle 0: stretch_active set, timer = 0. Check: 0 >= N? No (assume N > 0). Increment → timer = 1.
- Cycle 1: Check: 1 >= N? Increment → timer = 2.
- ...
- Cycle N: Check: N >= N? Yes. Clear stretch_active.

But stretch_active was set for cycles 0, 1, 2, ..., N → **N+1 cycles active**.

**With timer init = 1:**
- Cycle 0: stretch_active set, timer = 1. Check: 1 >= N? No (assume N > 1). Increment.
- ...
- Cycle N-1: timer = N. Check: N >= N? Yes. Clear stretch_active.

stretch_active was set for cycles 0, 1, ..., N-1 → **exactly N cycles active**.

**This is the canonical "fence-post" error.** Counting from 0 vs 1 changes the boundary.

---

### Q13 — Removing the `active_int` check

If we strip `active_int` from the stretch trigger:

```systemverilog
end else if (stretch_en_rise && !stretch_active) begin  // active_int removed
  stretch_active <= 1'b1;
```

Now an idle slave (not addressed in current transaction) can stretch SCL.

**Consequence on the bus:** All slaves share SCL. If a wrong-address slave starts stretching, the **addressed slave** is also frozen — master can't advance, the actual target slave is stuck mid-byte. The whole bus is held hostage by a slave that isn't even part of the current transaction.

This is exactly why the `active_int` check exists — **only the currently-addressed slave should stretch.** Anything else is a bus-level fault.

**Senior thought process:** In a multi-slave I2C bus, the slaves are like roommates sharing a bathroom. If a roommate who isn't using the bathroom locks the door anyway, everyone suffers. The `active_int` check is the lock-only-when-you're-inside rule.

---

### Q14 — `saved_state` in `always_ff`, not `always_comb`

`saved_state` must be a **register** — it needs to remember a value across many clocks (the entire stretch duration). Combinational logic doesn't store; it only computes.

Look at the code:

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    state <= SLV_IDLE;
    saved_state <= SLV_IDLE;
  end else begin
    if (stretch_active && state != SLV_STRETCH)
      saved_state <= state;       // ← Snapshot on entry to STRETCH
    state <= next_state;
  end
end
```

The snapshot fires **once**, on the cycle where stretch becomes active but the state hasn't yet transitioned to `SLV_STRETCH`. From then on, `saved_state` is held until the next stretch event.

If you tried this in combinational logic, `saved_state` would be a wire constantly recomputed — there's no concept of "snapshot then hold" in pure combinational logic. You need a flip-flop.

**Interview-grade answer:**

> *"`saved_state` is a register because it holds a value across many clocks — the entire duration of clock stretching. Combinational logic can't store. The snapshot fires on the cycle stretch becomes active but state hasn't yet moved to SLV_STRETCH — that's the last cycle of the 'previous' state. Then the register holds until the next stretch event overwrites it. This is the standard interrupted-state pattern: save the program counter, execute the interrupt handler, restore."*

---

### Q15 — Where `force_data_nack` does NOT reach

`force_data_nack` only influences `SLV_RX_ACK`. It does **not** affect:

1. **Address ACK in `SLV_ACK`** — the slave still ACKs its address normally. Why? Because if address ACK was also forced to NACK, the master would abort before we even got to test the data-NACK path. The test setup would be broken.

2. **TX direction in `SLV_TX`** — the slave still drives data bits normally. The test goal is to verify master's behavior when the **slave** NACKs — not when the slave goes silent or sends garbage.

3. **START/STOP detection** — orthogonal protocol-framing. Fault injection here would be a different bug class entirely.

**The deliberate scope:** isolate exactly one fault — "slave NACKs a data byte" — without breaking the test setup or muddling the result.

**Senior thought process:** Fault injection ports should be **surgical**, not blanket. A signal called `force_everything_wrong` would be useless because you couldn't tell which specific path failed.

---

### Q16 — 2-state vs 4-state X-propagation hazards

In a **4-state simulator** (Verilog default), uninitialized registers hold `X`. If your FSM has a state register reset only partially, or if you have a register read before write, you see `X` propagating through your logic — eventually reaching outputs and your assertions.

In a **2-state simulator** (some synthesis flows, faster sim), `X` doesn't exist. Uninitialized registers default to `0`. Your FSM behaves "correctly" because reads of uninitialized registers return 0 — which is a valid value.

**Bug that hides in 2-state:** A path where you forgot to reset `rx_write_done` (line 229). In 4-state, before the first transaction, `rx_write_done = X`. The condition `!rx_write_done` is `X` (unknown), gating the register write — undefined behavior, assertions catch it. In 2-state, `rx_write_done = 0`, `!rx_write_done = 1`, the write fires "correctly" on cycle 0 of the very first transaction. **Hidden bug.**

This is why the file explicitly notes `// FIX: properly reset to avoid X-pessimism`.

**Interview-grade answer:**

> *"2-state simulators treat uninitialized registers as 0, so any missing-reset bug looks like correct behavior. A 4-state simulator propagates X from uninitialized registers, which catches the bug because the X infects downstream logic and gets flagged by assertions. The rule is: **always run 4-state at least once before signoff, and explicitly reset every flop in every reset branch.** This DUT had `rx_write_done` initially unset on reset — fixed by adding `rx_write_done <= 1'b0` to the reset branch."*

---

### Q17 — Reset behavior

After `rst_n` asserts (active-low):
- `reg_bank[0..7]` ← `8'h00` each (for loop in reset branch)
- `addr_match` ← `1'b0` (registered, reset clears)
- `sda_o` ← `1'b1` (released, open-drain high — does not drive bus low)
- `scl_o` ← `1'b1` (released)
- `state` ← `SLV_IDLE`
- `rx_write_done` ← `1'b0` (explicit reset to avoid X-pessimism)

**Why `rx_write_done` needs explicit reset:**

`rx_write_done` is in the same `always_ff` block as the register bank. The for-loop in the reset branch resets `internal_regs` and `internal_updated`, but `rx_write_done` is a separate scalar — easy to forget. If forgotten, it would hold `X` in 4-state simulation, gating the very first register write conditionally on an unknown value — assertion failures, undefined behavior.

**Senior rule:** Every flop in every reset branch. No exceptions. Code-review checklist item.

---

### Q18 — Repeated START mid-write

Transaction: `START → ADDR(W) → DATA1 → REP-START → ADDR(R) → DATA → STOP`.

**FSM trace:**

1. `SLV_IDLE` → `start_cond` → `SLV_START`.
2. `SLV_START` → `SLV_ADDR`.
3. `SLV_ADDR` shifts 8 bits, `bit_cnt == 8 && scl_fall` → `SLV_ACK` (with `addr_matched = 1`, `rx_rw = 0`).
4. `SLV_ACK` on `scl_fall` → `SLV_RX`.
5. `SLV_RX` shifts DATA1 in, `bit_cnt == 8 && scl_fall` → `SLV_RX_ACK`.
6. In `SLV_RX_ACK`: priority check — `stop_cond`? `start_cond`? `scl_fall`?
   - Here the master generates REP-START: SDA falls while SCL is high. `start_cond` fires.
   - Next state: `SLV_START`.
7. `SLV_START` → `SLV_ADDR` again, shift in the new address byte (this time with R/W = 1).
8. ...continues as master read.

**Danger zone:** Step 6. The priority of `start_cond` in `SLV_RX_ACK` is what makes this work. If a junior moved `scl_fall` priority before `start_cond`, the slave would head to `SLV_RX` and miss the repeated START — eventually the master's address bits would be interpreted as data, the slave would write garbage to register 0, and the master's read would never get serviced.

**Also dangerous:** The slave is mid-ACK pulldown in `SLV_RX_ACK` (driving SDA low). Master needs to first **release** the bus to be able to drive SDA — but the slave's ACK has already finished by the time the 9th SCL clock ends, so SDA is naturally released before the master drives it. This timing alignment is implicit in the spec.

**Interview-grade answer:**

> *"Repeated START is a master-initiated condition that can fire during the slave's ACK state. The slave's FSM detects it via the global `start_cond` check at the top of next-state logic, which has priority over the normal `scl_fall` advance. The danger is that the slave is finishing its ACK pulldown when the START detection fires — but by spec timing, the slave releases SDA after the ACK slot ends, before the master needs to drive SDA for the START. The priority encoding inside `SLV_RX_ACK` — stop, then start, then scl_fall — encodes exactly this protocol structure."*

---

### Q19 — Interview articulation: "When does the slave drive vs release SDA?"

**30-second senior-grade answer:**

> *"The slave releases SDA (open-drain high) by default, and only drives it low in three cases: first, when it's matched the incoming address byte — it pulls SDA low for the entire 9th SCL clock to ACK the address. Second, after receiving each data byte from the master, it pulls SDA low to ACK the byte — unless `force_data_nack` is asserted by the testbench. Third, during master-read transactions, the slave drives SDA bit-by-bit MSB-first from a TX shift register, with each shift triggered on SCL-fall to keep SDA stable during SCL-high. Every other moment — idle, address bits, RX data bits, post-NACK — the slave's `sda_o` is 1, meaning open-drain release, meaning the line floats to whatever the master and pull-ups dictate."*

This is your **memorize-this** answer. Three drive cases, three release moments.

---

### Q20 — Most likely real-silicon-only bug

**Async input metastability and glitch sensitivity on SDA/SCL.**

In simulation, `sda_i` and `scl_i` are deterministic — they change at simulation events. In silicon:
- The pads are connected to an external bus shared with potentially noisy, slewing analog signals.
- The slave's flip-flops can go metastable when SDA/SCL transition near a `posedge clk`.
- A glitch on SCL (e.g., 30 ns dip due to noise) could falsely register as a `scl_rise` followed by a `scl_fall`, advancing the bit counter.

**Mitigations needed in silicon:**
1. **2-flip-flop synchronizer** on SDA and SCL → resolves metastability.
2. **Digital glitch filter** with a programmable width (≥ 50 ns for Standard Mode per spec) → rejects short transients.
3. **Spike rejection** especially on START/STOP detection — perhaps require N consecutive matching samples.

None of these are in the DUT. They're not bugs in simulation because simulation has no analog noise. But synthesizing this design to silicon **would expose immediate functional failures on real I2C buses with realistic noise.**

**Interview-grade answer:**

> *"The biggest gap between simulation and silicon for this slave is the lack of input synchronization and glitch filtering on SDA and SCL. In simulation, the inputs are clean digital events; in silicon, they're noisy analog signals shared with other devices. A 30-nanosecond glitch on SCL — easily produced by capacitive coupling or pull-up sag — would look like a valid SCL pulse and falsely advance the bit counter. Production-quality slaves include a 2-FF synchronizer, a 50-ns glitch filter to meet the spec's `t_SP` parameter, and often a spike-rejection layer on START/STOP detection. This DUT skips all of that, which is fine for class verification but would fail immediately on real silicon."*

---

## 13. Key Takeaways

### Conceptual

1. **A slave is a stateful pattern-matcher, not just a listener.** Every action — ACK, RX, TX, stretch — is a precisely-timed response to a master event. Slave bugs are almost always timing bugs.

2. **START/STOP detection is the slave's only sensing primitive.** It must be combinational, global (not state-locked), and based on SDA-edge-during-SCL-high. Glitch filtering is critical for silicon — absent in sim.

3. **Non-blocking semantics are the language-level trick that makes simultaneous reads of "old" and "new" values work.** The address-latch and RX-byte-latch idioms depend on this.

4. **SDA changes on SCL-fall, sampled on SCL-rise.** This rule controls every data path in the slave. Violate it and you create false STARTs/STOPs and bus chaos.

5. **One-shot latches are the standard way to gate "fire once per state visit."** Used for `reg_ptr_inc_done`, `rx_write_done`, and `stretch_en_rise`. Memorize this pattern.

6. **Clock stretching is an overlay FSM, not a linear state.** `SLV_STRETCH` is entered from any active state and returns to `saved_state`. The fence-post error on the timer (start at 1, not 0) is the classic off-by-one.

7. **Fault injection should be scope-bounded.** `force_data_nack` only affects `SLV_RX_ACK` — never address ACK, never TX. Surgical fault injection enables precise root-cause isolation.

8. **Reset every flop in every reset branch.** Missing a reset hides in 2-state simulation but breaks in 4-state and possibly in silicon X-propagation.

### Bug Patterns (Slave-Specific)

Memorize these — they reappear in every slave-design interview:

| Bug | Symptom | Root Cause |
|---|---|---|
| ACK timing slip | Master sees NACK on every byte | SDA output set one half-cycle late; not registered to absorb SCL-fall latency |
| Shift direction error | Address never matches | `{sda_i, shift_reg[7:1]}` instead of `{shift_reg[6:0], sda_i}` |
| Address compare on wrong byte | Slave responds to wrong address or silent | Compare fires at wrong `bit_cnt` value |
| Stretch infinite re-trigger | Bus deadlock | Level-sensitive stretch_en instead of edge |
| Stretch off-by-one | Stretch lasts N+1 cycles | Timer init = 0 with `>=` check |
| ACK pollutes RX byte | Received bytes have LSB stuck at 0 | Read shift_reg instead of latched_rx_byte |
| reg_ptr overruns | Wrong register written to | Missing `_inc_done` one-shot guard |
| Active-flag missing on stretch | Bus held by non-addressed slave | Stretch trigger missing `active_int` check |

### Career-critical

- **The "drive vs release SDA" question is a fresher-filter.** Memorize the three drive cases and the corresponding release moments. (Q19.)
- **Clock stretching is the slave-design topic interviewers love** because it tests open-drain understanding, edge detection, FSM overlay, and off-by-one math all at once.
- **2-state vs 4-state X-propagation is a senior-fresher discriminator.** Most candidates have never thought about it. (Q16.)
- **Silicon-readiness awareness — async sync, glitch filter, spec compliance like `t_SP` — earns interview points.** Mention them proactively even when not asked.

---

## 14. Action Items

- [ ] Re-derive the START detection logic on paper without looking. Draw the SCL/SDA waveforms and label `sda_i`, `sda_d`, `start_cond`.
- [ ] Re-do the quiz **without looking at answers** in 4 days. Aim for 16/20 correct.
- [ ] Re-trace the **Repeated START mid-write** scenario (Q18) on paper, marking FSM transitions and `bit_cnt` values at each clock.
- [ ] Write down (or sketch) the timing diagram of clock stretching — `stretch_en`, `stretch_en_rise`, `stretch_active`, `stretch_timer`, `scl_o`. Verify that for `stretch_cycles = 5`, SCL stays low for exactly 5 system clocks.
- [ ] Identify, in your testbench (when you get there), at least one assertion you would add per quiz answer that exposes the bug. Examples:
  - `assert property (@(posedge clk) (state == SLV_ACK && scl_rise && addr_matched) |-> (sda_o == 1'b0))` (Q6)
  - `assert property (@(posedge clk) (state == SLV_RX_ACK && reg_ptr_inc_done) |-> $stable(reg_ptr))` (Q9)
- [ ] **(Stretch)** Sketch the silicon-grade version of this slave with synchronizer + glitch filter + spike rejection. This is a real interview ask at NVIDIA/Intel.
- [ ] **(Stretch)** Add to README a "Known Scope Limitations" section listing: no glitch filter, no synchronizer, no general-call, no multi-master arbitration, no 10-bit addressing.

---

## 15. Honest Self-Score Template

Fill this out **after** doing the quiz from memory. Be brutally honest.

| Area | Score | Status |
|---|---|---|
| START/STOP detection mechanism | ___% | |
| FSM state diagram (can you draw it?) | ___% | |
| Non-blocking semantics in address latch | ___% | |
| Shift register direction (MSB-first reasoning) | ___% | |
| ACK timing — when slave drives SDA low | ___% | |
| SDA on SCL-fall (TX), sampled on SCL-rise (RX) | ___% | |
| `latched_rx_byte` purpose | ___% | |
| `reg_ptr` and the `_inc_done` guard | ___% | |
| Clock stretch edge-detect rationale | ___% | |
| Off-by-one in stretch timer (init=1) | ___% | |
| `saved_state` overlay pattern | ___% | |
| `force_data_nack` scope-bounded fault injection | ___% | |
| 2-state vs 4-state X-propagation | ___% | |
| Repeated START mid-transaction FSM trace | ___% | |
| Reset-every-flop rule | ___% | |
| Glitch filter / synchronizer in silicon | ___% | |
| 30-sec "when does slave drive SDA" articulation | ___% | |
| Bug-pattern memorization (table in §13) | ___% | |

**Total target on next pass:** ≥ 80% across the board. Anything below 60% means re-read that section and re-do the quiz item.

---

---

## Appendix A — Full Cycle-by-Cycle Trace: Master Write of 0x55 to Slave 0x50

This appendix walks the slave's behavior cycle-by-cycle for a complete write transaction. Use it to internalize **how the FSM threads together**. The trace assumes Standard Mode (T_SCL_PERIOD = 500 system clocks) but compresses time for readability.

### Setup

- `SLAVE_ADDR = 7'h50` = `7'b101_0000`.
- Master sends: START → ADDR(W) byte `8'hA0` (= `0101_0000_0` = address 0x50 with R/W = 0) → DATA byte `8'h55` → STOP.

### Phase 1: START

| Event | State | bit_cnt | sda_o | Notes |
|---|---|---|---|---|
| Bus idle, SDA=H, SCL=H | SLV_IDLE | 0 | 1 (released) | Slave watching |
| SDA falls, SCL still H | SLV_IDLE | 0 | 1 | `start_cond = 1` fires |
| Next clock | SLV_START | 0 | 1 | One-cycle transit |
| Next clock | SLV_ADDR | 0 | 1 | Begin address shift |

### Phase 2: Address byte (A6 A5 A4 A3 A2 A1 A0 R/W = 1010_0000)

Master clocks SCL: low → high → low → high ... 8 times. At each SCL rise, slave samples SDA and shifts.

| SCL rise # | SDA | shift_reg before | shift_reg after | bit_cnt after |
|---|---|---|---|---|
| 1 | 1 (A6) | 0000_0000 | 0000_0001 | 1 |
| 2 | 0 (A5) | 0000_0001 | 0000_0010 | 2 |
| 3 | 1 (A4) | 0000_0010 | 0000_0101 | 3 |
| 4 | 0 (A3) | 0000_0101 | 0000_1010 | 4 |
| 5 | 0 (A2) | 0000_1010 | 0001_0100 | 5 |
| 6 | 0 (A1) | 0001_0100 | 0010_1000 | 6 |
| 7 | 0 (A0) | 0010_1000 | 0101_0000 | 7 |
| 8 | 0 (R/W) | 0101_0000 | (latched separately) | 8 |

At **rise 8** (bit_cnt was 7 at this edge):
- `rx_addr <= shift_reg[6:0]` → `7'b101_0000` = `0x50` (using **old** shift_reg).
- `rx_rw <= sda_i` → `0` (write).
- `addr_matched <= (shift_reg[6:0] == SLAVE_ADDR)` → `1`.

### Phase 3: ACK

| Event | State | sda_o | Notes |
|---|---|---|---|
| SCL falls after 8th high | SLV_ADDR | 1 | `bit_cnt == 8 && scl_fall` triggers transition |
| Next clock | SLV_ACK | 0 (driving low) | ACK pulldown — addr matched |
| SCL rises (9th high) | SLV_ACK | 0 | Master samples SDA=0, reads ACK |
| SCL falls (end of 9th) | SLV_ACK | 0 → 1 (transitioning) | `scl_fall && addr_matched && rx_rw==0` → SLV_RX |
| Next clock | SLV_RX | 1 (released) | Ready for data shift |

`reg_ptr` reset to 0 during SLV_ACK. `active_int` set to 1.

### Phase 4: Data byte 0x55 (0101_0101)

8 SCL cycles, master clocks data on each. Slave samples on SCL rise.

| SCL rise # | SDA | shift_reg after | bit_cnt after |
|---|---|---|---|
| 1 | 0 | 0000_0000 | 1 |
| 2 | 1 | 0000_0001 | 2 |
| 3 | 0 | 0000_0010 | 3 |
| 4 | 1 | 0000_0101 | 4 |
| 5 | 0 | 0000_1010 | 5 |
| 6 | 1 | 0001_0101 | 6 |
| 7 | 0 | 0010_1010 | 7 |
| 8 | 1 | (latched separately) | 8 |

At rise 8: `latched_rx_byte <= {shift_reg[6:0], sda_i}` = `{2'b010_1010, 1'b1}` = `8'b0101_0101` = `0x55`. ✅

### Phase 5: Data ACK

| Event | State | sda_o | Action |
|---|---|---|---|
| SCL falls after 8th rise | SLV_RX | 1 | Transition triggers |
| Next clock | SLV_RX_ACK | 0 (ACK) | `active_int && !force_data_nack` |
| Inside SLV_RX_ACK | SLV_RX_ACK | 0 | `internal_regs[0] <= 0x55`; `internal_updated[0] <= 1`; `rx_write_done <= 1` |
| Same state, next clock | SLV_RX_ACK | 0 | `reg_ptr <= 1`; `reg_ptr_inc_done <= 1` |
| SCL rises (9th high) | SLV_RX_ACK | 0 | Master samples ACK |
| SCL falls (end 9th) | SLV_RX_ACK | 0 → 1 | If no STOP/REP-START: → SLV_RX for next byte |

### Phase 6: STOP

Master holds SCL high, then releases SDA from low to high.

| Event | State | Notes |
|---|---|---|
| SDA rises while SCL=H | (any) | `stop_cond = 1` fires globally |
| Next clock | SLV_STOP | One-cycle transit |
| Next clock | SLV_IDLE | `active_int <= 0` cleared |

### Observable testbench events

Over the entire transaction, the testbench sees:
- `addr_match` high after Phase 3.
- `active` high from Phase 3 to STOP.
- `rx_data_valid` pulses during Phase 5.
- `rx_data` = `0x55` during Phase 5.
- `reg_updated[0]` strobes once during Phase 5.
- `reg_bank[0]` = `0x55` from Phase 5 onward.

**This is the complete observability footprint.** When you write the scoreboard, these are the signals you sample.

---

## Appendix B — Common DV Mistakes Made Against This DUT

These are gotchas your testbench could hit if not careful. Memorize them — they show up in DV interviews as "tell me about a difficult bug you debugged" stories.

### B1. Reading `reg_bank` too early

Junior code:
```systemverilog
// Send a write, then immediately read reg_bank
@(posedge clk);
dut_drive_write(0x50, 0x55);
@(posedge clk);
expected_value = 0x55;
observed_value = reg_bank[0];   // ← Often X or stale!
```

**Why broken:** The full I2C write transaction takes hundreds of system clocks. After `dut_drive_write` returns (assuming it's non-blocking), `reg_bank[0]` hasn't been updated yet.

**Fix:** Wait for `reg_updated[0]` strobe or `rx_data_valid` event before sampling.

### B2. Pulse-counting `reg_updated[]`

Junior code:
```systemverilog
forever begin
  @(posedge reg_updated[0]);
  write_count++;
end
```

**Risk:** The strobe is **one clock wide**. If your monitor task is doing other work and misses the posedge, the count is wrong. Use `@(posedge clk) if (reg_updated[0]) ...` in a continuous monitor.

### B3. Not handling clock stretching in the testbench predictor

Junior code:
```systemverilog
// Expected: master finishes write in N cycles
expected_done_time = current_time + N * T_SCL_PERIOD;
```

**Broken when stretch fires.** The master extends by `stretch_cycles` system clocks. Your scoreboard's timing model must account for stretch.

### B4. Asserting `force_data_nack` mid-byte

`force_data_nack` is checked in `SLV_RX_ACK`. If you assert it in the middle of `SLV_RX` (during data shift), it has no effect on the current byte. The ACK decision is made when the FSM enters `SLV_RX_ACK`.

**Best practice:** Assert `force_data_nack` *before* the byte starts, so the value is stable when SLV_RX_ACK is entered.

### B5. Driving SDA on the testbench side when slave is driving

Both can drive SDA low simultaneously (open-drain) — no electrical conflict. But if your testbench is forcing SDA high (instead of releasing to Z), you create a **driver conflict** with the slave's ACK pulldown. The master sees `X` on SDA.

**Best practice:** TB always uses open-drain (drive Z for release, drive 0 for low). Never drive 1 actively.

---

## Appendix C — Comparing the Slave to a Real-World I2C IP

To anchor what you learned, here's how the project DUT compares to a production-grade I2C slave (e.g., a sensor's I2C slave block).

| Feature | This DUT | Production I2C Slave |
|---|---|---|
| Address width | 7-bit | 7-bit + optional 10-bit |
| General call (0x00) | Not supported | Usually supported, software-enabled |
| Programmable address | Parameter only | Register-controlled, run-time changeable |
| Glitch filter | None | 50-ns or programmable |
| Input synchronizer | None | 2-FF synchronizer mandatory |
| Register count | 8 | Often 256+ with auto-increment + sub-address |
| Clock stretch | Yes, externally controlled | Yes, internally triggered by FIFO-full or similar |
| Interrupt outputs | One pulse per RX | Multiple — RX, TX, addressed, bus error, arbitration |
| Multi-master support | No | Usually yes (arbitration loss detection) |
| Reset behavior | Sync to rst_n | May include soft reset via I2C command (0x06 general call) |
| Power management | None | Wake-on-address-match for low-power apps |
| ECC on register bank | No | Often yes for safety-critical (ASIL-B/D) |

**The lesson:** This DUT is a *teaching-grade* implementation. It teaches the protocol fundamentals. To go from this to production silicon, you'd need to add roughly **2-3x more logic** for robustness, low power, and edge cases.

**Interview ammo:** When asked "what would you add to make this production-ready?" — the table above is your answer template. Pick three items and articulate them.

---

## Appendix D — Hand-Drawing the FSM for Whiteboard Interviews

You will be asked to draw a slave I2C FSM on a whiteboard. Here is the **minimum viable version** to draw — small enough to fit in 3 minutes, complete enough to discuss every interview topic.

### Drawing order

1. **Top-left:** `IDLE`. Self-loop labeled "no START."
2. **Right of IDLE:** `START`. Arrow from IDLE labeled `start_cond`.
3. **Below START:** `ADDR`. Self-loop labeled "shift bits." Arrow from START unlabeled.
4. **Right of ADDR:** `ACK`. Arrow from ADDR labeled `bit_cnt==8 && scl_fall`.
5. **Diverge from ACK:** Two arrows — one to `RX` (labeled "match && rw==0"), one to `TX` (labeled "match && rw==1"). Third arrow back to IDLE labeled "no match."
6. **RX → RX_ACK:** Labeled `bit_cnt==8 && scl_fall`. RX_ACK → RX labeled `scl_fall` (continue).
7. **TX → TX_ACK:** Labeled `bit_cnt==8 && scl_fall`. TX_ACK → TX labeled "master ACK." TX_ACK → IDLE labeled "master NACK."
8. **Global preempt arrows:** From every state to STOP labeled `stop_cond`; STOP → IDLE.
9. **Add stretch overlay (in a separate corner):** Box labeled `STRETCH` with arrow in from "any state" labeled `stretch_en_rise && active_int`, and arrow out labeled "timer expires → return to saved_state."

### Why this is the right scope

Interviewers test **structure**, not exact state names. The 10-state version with all internal flags is overwhelming on a whiteboard and obscures the architecture. Draw the **9 functional states + stretch overlay** and you communicate clearly.

### Common whiteboard mistakes

- **Drawing one ACK state instead of two.** Bug: ACK for address and ACK for data are not the same — different next-state logic, different SDA behavior.
- **Forgetting the STOP preempt.** Interviewer will ask "what happens if master STOPs mid-write?" — you need an answer.
- **Treating stretch as a linear state in the main chain.** It's an overlay. Draw it separately to communicate that.

---

**Final note from your big brother:** This module is where every I2C-DV interview question lives. Reading it once is not enough. Re-read it after every interview prep session for the next month — the patterns here repeat across SPI, UART, AXI-Lite slave responders, and every other protocol slave you'll ever verify. Master this one DUT and you've mastered the **slave-side mental model** for the rest of your career.

Two takeaways to hold onto:

1. **Slaves are stateful pattern-matchers with strict timing.** Every action — ACK pulldown, RX byte latching, TX MSB drive, stretch — is a precisely-timed response to a master event. Get the timing right and the protocol works. Get it wrong by one half-cycle and the master sees NACK or worse.

2. **Observability ports are how DV engineers see inside.** The `reg_bank`, `reg_updated`, `addr_match`, `active`, and `rx_data_valid` ports exist for your scoreboard — not for the silicon. Understand why each one is there, and you understand the entire verification-handshake between RTL and TB.

When you walk into NVIDIA, Qualcomm, Intel, or AMD interviews — these are the patterns the senior engineer across the table is testing for. Show them you understand the **mechanism**, not just the **what**, and you'll be the candidate they remember.

---

## Appendix E — Five Interview Questions You Should Practice Articulating Aloud

Reading and understanding is not the same as articulating. The job of an interview is to **explain a concept verbally under pressure**. Below are five questions tied directly to this DUT. Practice each out loud — record yourself if possible.

### E1. "Tell me about a bug you found in your slave."

Pick the **clock-stretch off-by-one** (BUG #15) or **stretch_en level-vs-edge** (BUG #14). They're both small, easy to explain, and demonstrate timing awareness.

Sample answer structure:
1. **What it was** (one sentence).
2. **How it manifested** (symptom — what test failed, what the bus looked like).
3. **How you debugged it** (waveforms, prints, assertions).
4. **Root cause** (one technical sentence).
5. **The fix** (one technical sentence).
6. **What it taught you** (one sentence — usually about edge-vs-level or fence-post errors).

### E2. "How does your slave handle Repeated START?"

Walk through the priority encoding in `SLV_RX_ACK` and `SLV_TX_ACK`. Mention that `start_cond` is a **global preempt** detected outside the case statement. Trace the FSM from data-byte through to the new address byte.

### E3. "Why is the SDA output registered and not combinational?"

Glitch-free output, one-clock latency absorbed by triggering state transitions on SCL-fall. Add: "I confirmed this with an assertion that SDA must be stable during SCL-high."

### E4. "What's the difference between `SLV_ACK` and `SLV_RX_ACK`?"

ACK for the address byte vs ACK for every subsequent data byte. Different next-state logic — `SLV_ACK` decides whether to enter `SLV_RX` or `SLV_TX` based on R/W; `SLV_RX_ACK` always returns to `SLV_RX` (or exits on STOP/REP-START). Different SDA conditions — `SLV_ACK` checks `addr_matched`; `SLV_RX_ACK` checks `active_int && !force_data_nack`.

### E5. "If I asked you to make this slave production-ready, what would you add?"

Refer to Appendix C. Pick three of:
- 2-FF synchronizer on SDA/SCL.
- Glitch filter to meet `t_SP` spec.
- General-call (0x00) decode.
- Sub-address auto-increment beyond 8 registers.
- Bus error detection (e.g., timeout when SCL stuck low > 25 ms).

Don't just list — explain **why** each one matters.

---

## Appendix F — How This Maps to Future Protocols

The patterns in this slave repeat across many protocols. Map your knowledge:

| Pattern in this DUT | Equivalent in AXI4-Lite | Equivalent in SPI Slave | Equivalent in UART RX |
|---|---|---|---|
| START detection | `AWVALID && AWREADY` handshake | Chip-select assertion | Start bit detection (falling edge) |
| Address compare | Address-decoded slave select | (n/a, SPI uses CS) | (n/a, point-to-point) |
| ACK pulldown | `BVALID` write response | (n/a) | (n/a) |
| Shift register | (full-width AXI bus) | MISO shift register | RX shift register |
| Clock stretching | `*READY` deassertion | Throttle via CS deassert | Hardware flow control (RTS/CTS) |
| `force_data_nack` | Inject `BRESP = SLVERR` | (n/a directly) | Parity-error inject |
| Observability ports | RAL backdoor reads | Internal scan registers | UART status register |

The lesson: **slave-side mental model is universal.** Master this DUT and you're 80% of the way to understanding any peripheral slave at the protocol layer.

When you progress to your AXI XBar project (already in your notes), notice how `AWREADY` deassertion is the AXI equivalent of clock stretching. Same idea, different mechanism. The mental model carries over.
