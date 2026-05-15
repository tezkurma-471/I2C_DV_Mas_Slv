# File 08 — Interview Questions: 80+ Q&A for I2C DV Mastery

> "An interviewer does not want to hear what you did. They want to hear that
>  you understand WHY it is done that way. The 'why' separates juniors from
>  seniors in every conversation."

---

## How to Use This File

- Cover the answer. Try to answer from memory.
- If you get it wrong, do not just re-read the answer. Trace it back to the
  deep-dive file and understand the reasoning.
- The KEY INSIGHT line is what makes a GOOD answer. Without it, your answer
  is mediocre. With it, you stand out.
- Answers marked with a code block should be practiced until you can write the
  code from memory on a whiteboard.

---

## Section 1: I2C Protocol (20 Questions)

---

**Q1. What is I2C? How many wires does it use, and what does each wire do?**

I2C (Inter-Integrated Circuit) is a two-wire synchronous serial protocol
invented by Philips in 1982 for connecting chips on a PCB. It uses two wires:
SDA (Serial Data Line), which carries data bits, and SCL (Serial Clock Line),
which is driven by the master to synchronize data sampling. All devices share
both wires simultaneously, and devices are distinguished by 7-bit (or 10-bit)
addresses. Standard mode operates at up to 100 kHz; Fast mode at 400 kHz.

KEY INSIGHT: The reason I2C uses only 2 wires for multi-device communication
(vs. parallel buses with tens of wires) is the combination of open-drain wiring
and address-based device selection. Any interviewer who hears "it uses 2 wires"
without the "why" knows you are reading from memory, not understanding.

---

**Q2. What does "open-drain" mean and why does I2C require it?**

Open-drain means a device's output can only pull the bus LOW (drain to GND) or
release it — it cannot actively drive the bus HIGH. A passive pull-up resistor
(typically 2.2-10 kΩ) holds the bus HIGH when no device is pulling it low.
I2C requires open-drain for three reasons: (1) multiple devices share one wire
without a short circuit risk — if two devices drive opposite logic levels on a
push-pull bus you get a direct short; (2) it enables wired-AND for bus
arbitration — the bus is only HIGH if ALL devices release it; (3) it enables
clock stretching — the slave can hold SCL low even after the master releases it.

KEY INSIGHT: The wired-AND property of open-drain is foundational to I2C
arbitration. If two masters try to drive simultaneously, the master driving HIGH
(releasing) will see LOW on the bus and know another master is present.

```
// SystemVerilog open-drain model (from i2c_if.sv):
assign (weak1, highz0)  sda = 1'b1;              // pull-up resistor
assign (strong0, weak1) sda = drv ? 1'bz : 1'b0; // device driver
// strong0 (drive low) beats weak1 (pull-up) → SDA = 0
// highz0 (release) → weak1 (pull-up) wins → SDA = 1
```

---

**Q3. How does a START condition differ from a data bit, and why is this
distinction important for the slave's detection logic?**

During normal data transmission, SDA must remain STABLE while SCL is HIGH.
A START condition is defined as SDA falling WHILE SCL is HIGH — a pattern
that is impossible during normal data transmission, making it unambiguous.
This is why slaves can detect START without a separate START wire.

KEY INSIGHT: The uniqueness of START and STOP comes from breaking the
normal-data rule (SDA stable when SCL high). Any RTL that checks for START
must verify both: `sda_i == 0` (current), `sda_d == 1` (previous), AND
`scl_i == 1` (SCL currently high). Missing any one condition creates false
detections.

```systemverilog
// From i2c_slave_controller.sv:
assign start_cond = (sda_i == 1'b0 && sda_d == 1'b1 && scl_i == 1'b1);
// sda_d is the one-cycle registered version of sda_i (detects edge)
```

---

**Q4. Describe the complete I2C write transaction sequence, bit by bit.**

(1) START: SDA falls while SCL is high. (2) Address byte: 7-bit slave address
sent MSB-first, then R/W=0 (write). Total 8 bits. (3) Address ACK: slave
drives SDA low on 9th SCL pulse. (4) Data byte 1: master sends 8 bits.
(5) Data ACK: slave drives SDA low. (6) Steps 4-5 repeat for each byte.
(7) STOP: SCL goes high, then SDA rises while SCL stays high.

KEY INSIGHT: The 9th clock pulse is NOT a data clock — it is the ACK clock.
The RECEIVER drives SDA during this pulse. For writes: slave drives ACK after
each byte. For reads: master drives ACK (more data) or NACK (last byte).
Knowing exactly who drives SDA at each point is the most commonly tested
I2C detail.

```
Bit:    S  A6 A5 A4 A3 A2 A1 A0 R/W  ACK  D7  D6 ... D0  ACK   P
Driver: M  M  M  M  M  M  M  M  M    S    M   M  ... M   S     M
        ↑                            ↑                    ↑     ↑
       START                        9th clock             9th   STOP
```

---

**Q5. What is clock stretching and in what situations would a slave use it?**

Clock stretching is an I2C feature where a slave holds SCL LOW to pause the
master and buy processing time. Since SCL is open-drain, the slave can drive
SCL low even when the master has released it. The master monitors SCL and
waits until it goes high before proceeding. Typical use cases: (1) ADC needs
more time to complete a conversion, (2) EEPROM is mid-write and cannot accept
new data, (3) slave is processing a command and needs time before responding.

KEY INSIGHT: Clock stretching is ONLY valid for a slave that has been addressed
(is active in a transaction). A slave that stretches during idle violates the
protocol and can freeze the bus for all other devices. This is exactly Bug #5
in this project — stretch activated when `active_int` was false.

```systemverilog
// Correct stretch activation guard (from fixed i2c_slave_controller.sv):
if (stretch_en_rise && !stretch_active && active_int) begin
  stretch_active <= 1'b1;  // Only stretch during an active transaction
end
```

---

**Q6. What is a Repeated START (Sr) and why is it used instead of STOP+START?**

A Repeated START is a START condition issued without a preceding STOP. The
master retains control of the bus — no other master can gain bus ownership
between Sr and the next STOP. This is used when two bus operations must be
atomic (uninterruptible): for example, a write-then-read to a slave register.
The sequence is: START → write register address → Sr → read data → STOP.
Without Sr, a STOP releases the bus, and another master could take over
between the write and the read.

KEY INSIGHT: The most common use case for Sr is the "I2C register read" pattern:
(1) write the register address to the slave, (2) Sr (no bus release), (3) read
the register contents. This is how virtually every I2C sensor (temperature,
accelerometer, OLED display) is accessed in practice.

---

**Q7. What happens electrically if two masters try to drive SDA simultaneously?
How does I2C arbitration work?**

Because SDA is open-drain, if Master A drives HIGH (releases SDA) and Master B
drives LOW (pulls down), the bus settles to LOW. Master A is monitoring SDA
while it drives HIGH. It sees SDA = LOW when it expected HIGH — this signals
that another master is active. Master A immediately releases the bus (stops
driving). Master B, which drove LOW, sees SDA = LOW as expected and continues.
The master that drove LOW wins. This is "wired-AND arbitration" — no explicit
arbitration logic or coordination is needed between masters.

KEY INSIGHT: I2C arbitration is non-destructive — the losing master does not
corrupt the winning master's transaction. The losing master simply waits and
retries when the bus is free. This is fundamentally different from Ethernet
(CSMA/CD), where collisions destroy both frames.

---

**Q8. In our project, the slave has address 7'h50. What byte appears on the
SDA wire during the address phase for a write transaction?**

SLAVE_ADDR = 7'h50 = 7'b0101_000. During the address phase, 8 bits are sent:
7-bit address MSB-first, then R/W bit. For write: R/W=0.
The 8-bit address byte = {7'h50, 1'b0} = 8'b0101_000_0 = 0xA0.
For read: {7'h50, 1'b1} = 8'b0101_000_1 = 0xA1.

KEY INSIGHT: The I2C address byte is NOT just the 7-bit address — it is
{addr[6:0], R/W}. Confusing "address 0x50" with "address byte 0x50" is a
very common mistake. The address byte is 0xA0 (write) or 0xA1 (read).
This matters when debugging waveforms — you look for 0xA0, not 0x50.

---

**Q9. How is open-drain behavior modeled in SystemVerilog simulation?**

Using drive strengths:
```systemverilog
// Pull-up resistor (weakest drive — always there, wins when nobody else drives)
assign (weak1, highz0) sda = 1'b1;

// Device driver (strong pull-down when active, releases when inactive)
assign (strong0, weak1) sda = (drv == 1'b0) ? 1'b0 : 1'bz;
```
`strong0` beats `weak1`, so when any device drives LOW, SDA = 0.
When all devices release (1'bz), `weak1` wins and SDA = 1.
This perfectly models the wired-AND property of real open-drain hardware.

KEY INSIGHT: The drive strength syntax `(weak1, highz0)` means "drive 1 with
weak strength, drive 0 with highz strength." `highz0` is invisible — no
ability to drive 0. This is exactly what a pull-up resistor does.

---

**Q10. What is T_SCL_PERIOD in this project, and how did you derive it?**

T_SCL_PERIOD = 500 clock cycles. Derivation: I2C standard mode = 100 kHz SCL.
SCL period = 1/100kHz = 10 µs. System clock = 50 MHz, period = 1/50MHz = 20 ns.
Number of system clock cycles per SCL period = 10 µs / 20 ns = 500 cycles.
T_SCL_HIGH = T_SCL_LOW = 250 cycles (5 µs each, meeting the ≥4 µs spec).

KEY INSIGHT: Always show your arithmetic in interviews. "T_SCL_PERIOD equals
500 because 10 µs divided by 20 ns equals 500" is a complete, checkable answer.
Saying "500" with no derivation suggests you memorized it without understanding.

---

**Q11. What are the I2C timing parameters and why does each matter?**

| Parameter | Value | Meaning and Consequence of Violation |
|-----------|-------|--------------------------------------|
| T_HD_STA  | 10 cycles | Hold time after START — SCL must stay HIGH for this long after SDA falls. Too short: slave may not detect START. |
| T_SU_DAT  | 5 cycles | Data setup — SDA must be stable this many cycles BEFORE SCL rises. Too short: slave samples wrong bit (setup violation). |
| T_HD_DAT  | 5 cycles | Data hold — SDA must remain stable this long AFTER SCL falls. Too short: slow devices may read old bit (hold violation). |
| T_BUF     | 20 cycles | Bus free time after STOP — no new START for this long. Too short: another device may interpret the new START as a continuation. |
| T_SU_STO  | 10 cycles | STOP setup — SDA must be LOW for this long before SCL rises for STOP. Too short: STOP may be missed. |

KEY INSIGHT: Setup violations cause incorrect data sampling (wrong 1/0 read).
Hold violations cause correct data to be overwritten before it is sampled.
Both violate the fundamental rule: SDA must be stable when SCL is high.

---

**Q12. What is the maximum number of I2C devices on a single bus?**

With 7-bit addressing: 128 possible addresses, but 16 are reserved by the
I2C specification (general call, high-speed mode master code, CBUS compatibility,
etc.), leaving 112 usable addresses. However, the practical limit is also
governed by bus capacitance: Standard Mode supports a maximum of 400 pF total
bus capacitance (sum of all device and wire capacitances). Exceeding this
slows the signal rise time (RC time constant of pull-up + bus capacitance)
and can cause bit errors.

KEY INSIGHT: The 112-device limit is theoretical. In practice, PCB trace
capacitance and device pin capacitance limit most buses to 10-20 devices.
You can use I2C bus buffers/repeaters to extend beyond this.

---

**Q13. What does NACK mean in each of the three contexts it can appear?**

After the address byte: no device with that address responded (wrong address,
device powered off, or device in a non-responsive state). The SDA line stays
high (no device drives it low). After a write data byte: the slave cannot
accept more data (buffer full, internal error, or `force_data_nack` is set in
our testbench). After a read data byte: the master is signaling "that was the
last byte I want — you may stop." This NACK tells the slave to release SDA and
wait for STOP.

KEY INSIGHT: The "read NACK" is normal and expected — it is how the master
signals the end of a read sequence. Treating a read NACK as an error in
software or RTL is a common mistake. Only address NACK and write data NACK
indicate an actual problem.

---

**Q14. Explain the difference between Standard, Fast, Fast-Plus, and High-Speed
I2C modes.**

| Mode | Speed | Key Difference |
|------|-------|----------------|
| Standard | 100 kHz | Original mode; weakest pull-ups acceptable |
| Fast | 400 kHz | Needs stronger pull-ups (lower resistance); different duty cycle |
| Fast-Plus | 1 MHz | Needs even stronger pull-ups; lower drive-strength devices may not work |
| High-Speed | 3.4 MHz | Requires a special "master code" handshake; current source instead of resistor pull-up |
| Ultra-Fast | 5 MHz | Unidirectional only (no ACK); not a standard open-drain bus |

KEY INSIGHT: Our project implements Standard Mode (100 kHz) with T_SCL_HIGH =
T_SCL_LOW = 250 cycles (50% duty cycle). Fast Mode uses a different duty cycle
(T_HIGH ≥ 600 ns, T_LOW ≥ 1300 ns — more asymmetric) because slave devices
need more time in the low phase to drive their outputs.

---

**Q15. How does the slave detect whether a transaction is a read or a write?**

After receiving the 7-bit address, the slave receives the R/W bit (bit 0 of
the address byte). In this project: `rx_rw <= sda_i` (sampled on the 8th SCL
rising edge). R/W=0 means write (master → slave), R/W=1 means read
(slave → master). After address ACK, the slave uses `rx_rw` to decide the next
state: `rx_rw == 1` → enter SLV_TX (slave transmits); `rx_rw == 0` → enter
SLV_RX (slave receives).

KEY INSIGHT: The R/W bit is sampled at the same clock edge as the 8th address
bit but via a separate path — `sda_i` directly, not from `shift_reg`. At the
moment of sampling, `shift_reg` contains bits [7:1] of the address (6 bits, not
all 7 yet). This is why `rx_addr <= shift_reg[6:0]` and `rx_rw <= sda_i` are
used simultaneously — the R/W bit is the current SDA bit, not in shift_reg.

---

**Q16. What is the purpose of `sda_d` in the slave controller, and why do
we need a registered (delayed) version of SDA?**

`sda_d` is a one-cycle-delayed, registered copy of `sda_i`. It is used to
detect EDGES on SDA: `sda_fall = sda_d==1 && sda_i==0` (SDA just fell), and
`sda_rise = sda_d==0 && sda_i==1` (SDA just rose). You cannot detect an edge
from a single combinational sample — you need two consecutive values to know
the direction of change. The registered version captures the value from the
previous clock cycle.

KEY INSIGHT: All edge detection in synchronous digital design requires a one-
or two-stage pipeline of registered samples. Without `sda_d`, you can only
ask "what is SDA now?" — you cannot ask "did SDA just change?" which is
required for START and STOP detection.

---

**Q17. In I2C, can a slave transmit data without being addressed first?**

No. A slave can only drive SDA when: (1) it has been addressed (address byte
matches), (2) the R/W bit is 1 (master requests a read), and (3) the current
bit is a data bit or the address ACK. At all other times, the slave must
release SDA (drive high-impedance / 1'b1 in our RTL). If a slave drove SDA
arbitrarily, it would corrupt transactions intended for other slaves.

KEY INSIGHT: The `active_int` flag in this project is the key: `sda_o` is
only driven to a meaningful value when `active_int == 1`. All other states
drive `sda_o <= 1'b1` (release). This is correct open-drain behavior.

---

**Q18. What would happen if the pull-up resistor on SDA was too large
(say, 100 kΩ)?**

The pull-up resistor and bus capacitance form an RC circuit. The time constant
τ = R × C. With R = 100 kΩ and typical bus capacitance of 50 pF:
τ = 100,000 × 50×10⁻¹² = 5 µs. This means the bus takes ~25 µs to reach 90%
of VDD after a device releases SDA. At 100 kHz (10 µs period), the bus would
not fully recover between bits. Devices would sample a low voltage and interpret
it as logic 0 — causing bit errors on every rising edge.

KEY INSIGHT: The pull-up resistor value is a performance-limiting parameter.
Too large: slow rise time, bit errors at higher speeds. Too small: excessive
current (P = V²/R), device drive limitations, power dissipation. The typical
4.7 kΩ is chosen as a balance for 100 kHz Standard Mode.

---

**Q19. What is the general call address and when would you use it?**

Address 0x00 (7'h00) is the general call address. A master sends START + 0x00
(write) and ALL slaves on the bus respond. It is used to broadcast data to all
devices simultaneously — for example, synchronizing the configuration of multiple
identical sensors, or resetting all devices. Slaves that cannot process general
call responses simply do not ACK.

KEY INSIGHT: The general call is one reason 7-bit I2C has only 112 usable
addresses instead of 128. Addresses 0x00 through 0x07 and 0x78 through 0x7F
are reserved for special functions (general call, CBUS, high-speed mode, etc.).

---

**Q20. How would you verify that a specific I2C timing parameter (like T_BUF)
is being met by your master RTL?**

Write an SVA assertion that fires when the timing is violated:
```systemverilog
property p_bus_free_time;
  @(posedge clk)
  disable iff (!rst_n)
  // After STOP (SDA rises while SCL high), no new START for T_BUF cycles
  (scl_samp == 1'b1 && sda_rise) |-> ##[1:T_BUF] (scl_samp == 1'b1 && sda_samp == 1'b1);
endproperty
assert_tbuf: assert property (p_bus_free_time);
```

Additionally, measure `T_BUF` in the scoreboard: record the time of STOP,
record the time of the next START, compute the difference, and assert it is
greater than or equal to T_BUF in system clock cycles.

KEY INSIGHT: This is exactly what Bug #12's FIXED assertion (A2) checks. Both
SVA and scoreboard checks are complementary: SVA fires immediately at violation
time; scoreboard validation catches aggregate timing across all transactions.

---

## Section 2: RTL Design (20 Questions)

---

**Q21. Explain the two-always-block FSM coding style. Why is it preferred
over a one-always-block FSM?**

The two-always-block style separates concerns:
- Block 1 (always_ff): registers the state. ONLY does `state <= next_state`.
- Block 2 (always_comb): computes next_state combinationally from current state
  and inputs.

This is preferred because: (1) it avoids multi-driver bugs — each signal is
driven by exactly one block; (2) the combinational logic is pure and re-evaluated
any time inputs change, giving correct simulation behavior; (3) it is cleaner
for lint and formal tools; (4) synthesis can optimize the combinational block
separately from the sequential block.

KEY INSIGHT: Bug #8 in this project was a multi-driver bug caused by breaking
this rule. `next_state` was driven in both the `always_ff` and `always_comb`
blocks. The fix was to make `always_comb` the SOLE driver of `next_state`.

```systemverilog
// Correct two-always-block pattern:
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) state <= STATE_IDLE;
  else        state <= next_state;   // Read next_state, never write it
end

always_comb begin
  next_state = state;                // Write next_state, never in always_ff
  case (state)
    // transitions...
  endcase
end
```

---

**Q22. What is the difference between blocking (=) and non-blocking (<=)
assignments in SystemVerilog? When must you use each?**

Blocking (=): executes immediately and sequentially. The updated value is
available to the next statement in the same block immediately.
Non-blocking (<=): schedules the assignment for the end of the time step.
The RHS is evaluated NOW, but the LHS is updated AFTER all non-blocking RHS
evaluations are complete.

Rules: In `always_ff` blocks (flip-flops): always use `<=` (non-blocking) to
model flip-flop behavior correctly. In `always_comb` blocks (combinational):
always use `=` (blocking) to model wire/gate behavior and ensure sensitivity
list completeness.

KEY INSIGHT: Using `=` in `always_ff` causes a read-before-write hazard in
simulation — a signal updated in the same cycle appears to update immediately,
which does not match real flip-flop behavior (where the new value is only
available NEXT cycle). This creates simulation-synthesis mismatches that are
extremely hard to debug.

---

**Q23. Explain what `always_ff`, `always_comb`, and `always_latch` mean in
SystemVerilog, and how they differ from plain `always`.**

`always_ff`: intent is a flip-flop. The tool ENFORCES that only
clock/reset-triggered behavior exists. No combinational feedback allowed.
`always_comb`: intent is combinational logic. The tool ENFORCES that the
sensitivity list is complete (all inputs to the block are automatically
included). A signal assigned here must be assigned on all paths (no latches).
`always_latch`: intent is a latch. The tool ENFORCES that a latch (not a
flip-flop) is inferred.
`always`: legacy Verilog — no enforcement. You can make any mistake and the
tool will not warn you.

KEY INSIGHT: Always use `always_ff` and `always_comb` in modern SystemVerilog.
The enforcement catches bugs at compile time instead of simulation time.
For example, if you forget a signal in a sensitivity list in `always @(...)`,
you get a simulation-synthesis mismatch. With `always_comb`, the tool infers
the complete sensitivity list automatically.

---

**Q24. What is an inferred latch and why is it almost always a bug?**

An inferred latch occurs when a combinational block (always_comb) does not
assign a variable on ALL paths through the logic. The tool infers a latch to
hold the previous value on the unassigned paths.

```systemverilog
// BUG: Inferred latch — 'y' not assigned when 'sel' is neither 2'b00 nor 2'b01
always_comb begin
  case (sel)
    2'b00: y = a;
    2'b01: y = b;
    // sel == 2'b10, 2'b11: y is NOT assigned → latch inferred
  endcase
end
```

Latches are problematic because they are transparent to the enable signal —
they do not use a clock edge, making timing analysis difficult and prone to
glitches. The fix is to add a default assignment before the case statement.

KEY INSIGHT: In FSM next-state logic, always set `next_state = state` (default)
before the case statement. This eliminates all latch inference in the case block.
Without this default, any unhandled state transition would infer a latch.

---

**Q25. What is a synthesis multi-driver error and how do you find it?**

A multi-driver error occurs when the same signal is assigned in more than one
procedural block. In hardware, this means two logic networks are connected to
the same wire — if they drive different values, you get a short circuit.
In simulation, the tool picks one value (often X or the last assignment),
giving incorrect results.

Finding it: grep for all assignments to the signal:
```bash
grep -n "signal_name\s*<=" rtl_file.sv
grep -n "assign signal_name" rtl_file.sv
```
If you find more than one unique always block or continuous assignment — multi-driver.

KEY INSIGHT: Bug #8 was exactly this. `next_state` was assigned in both
`always_ff` (wrong) and `always_comb` (correct). The fix removed the assignment
from `always_ff`. Synthesis tools report multi-driver as an ERROR, not a warning.

---

**Q26. What does `posedge clk or negedge rst_n` mean in a flip-flop always block,
and what does an asynchronous reset mean architecturally?**

`posedge clk or negedge rst_n` means the block triggers on EITHER the rising
edge of clk OR the falling edge of rst_n. The reset is therefore ASYNCHRONOUS —
it takes effect immediately when rst_n goes low, without waiting for a clock
edge. The flip-flop can reset at any time, regardless of the clock state.
An asynchronous reset is preferred when you need guaranteed reset even if the
clock is not running — common in power-on reset scenarios.

KEY INSIGHT: Synchronous reset (`if (!rst_n)` checked only on `posedge clk`)
uses the same clock path and therefore cannot reset a device without a clock.
Asynchronous reset acts immediately. The tradeoff: asynchronous reset requires
care in reset removal — the de-assertion of rst_n must be synchronized to the
clock (reset synchronizer circuit) to avoid metastability.

---

**Q27. Explain the shift register in the I2C slave. How does it work for
receiving (write transactions)?**

The slave's RX shift register accumulates bits arriving on SDA:
```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (scl_rise && (state == SLV_ADDR || state == SLV_RX)) begin
    shift_reg <= {shift_reg[6:0], sda_i};  // Shift left, new bit into LSB
  end
end
```
On each SCL rising edge (when SDA is valid per I2C protocol), the shift register
shifts left by 1 and the new bit enters from the right (LSB). After 8 SCL pulses,
`shift_reg` contains the complete byte, with bit 7 (MSB) being the first bit
received. MSB-first transmission matches I2C specification.

KEY INSIGHT: The critical fix in Bug #1 was that the original shift register
captured the 9th SCL pulse (ACK clock) as the 8th data bit. The fix captures
`latched_rx_byte <= {shift_reg[6:0], sda_i}` on the 8th SCL RISE (when
`bit_cnt == 7`), BEFORE the 9th clock. The full byte is captured on the
LAST DATA CLOCK, not on the ACK clock.

---

**Q28. What is the purpose of the `saved_state` register in the slave FSM?**

`saved_state` holds the FSM state that was active just before the slave entered
`SLV_STRETCH`. When clock stretching completes, the FSM returns to `saved_state`
instead of a fixed state. This is necessary because stretching can occur from
different points in the transaction (mid-read, mid-write, mid-byte) and the
slave must resume exactly where it paused.

```systemverilog
// In sequential always_ff (captures state before entering stretch):
if (stretch_active && state != SLV_STRETCH)
  saved_state <= state;

// In combinational next-state (restores state when stretch ends):
SLV_STRETCH: begin
  if (!stretch_active) next_state = saved_state;
  else                 next_state = SLV_STRETCH;
end
```

KEY INSIGHT: The `saved_state` pattern is the FSM analog of a function call's
return address. Without it, returning from a "service state" (stretch, pause,
interrupt) always goes to a fixed destination, which is only correct for one
calling context. With `saved_state`, any state can initiate a stretch and
correctly resume afterward.

---

**Q29. What is the reg_ptr and how does it advance in write and read modes?**

`reg_ptr` (3-bit) is the index into the slave's 8-register bank (0-7). It
determines which internal register is being read or written.
- On address ACK (`SLV_ACK`): `reg_ptr` resets to 0.
- After each received data byte (in `SLV_RX_ACK`, write mode): `reg_ptr` increments
  by 1, moving to the next register.
- After each transmitted data byte (in `SLV_TX_ACK`, read mode): `reg_ptr` increments,
  loading the next register into `tx_shift_reg` on the next cycle.

KEY INSIGHT: The `reg_ptr_inc_done` one-shot guard is critical — it prevents
`reg_ptr` from incrementing multiple times in the same `SLV_RX_ACK` or
`SLV_TX_ACK` state (since these states can last multiple clock cycles). Without
this guard, a 10-cycle ACK state would increment `reg_ptr` 10 times instead of
once, causing incorrect register access.

---

**Q30. What is the `active_int` signal and why is it needed?**

`active_int` is a flag that indicates the slave is currently participating in
an active transaction (it has been addressed and ACK'd its address). It is set
when the slave enters `SLV_ACK` and the address matches, and cleared on STOP.
Many slave behaviors are guarded by `active_int`: clock stretching only
activates when `active_int` is set, SDA output in RX_ACK and TX states is only
driven when `active_int` is set, and register writes are only performed when
`active_int` is set.

KEY INSIGHT: Without `active_int`, the slave would respond to address clock
edges even when not addressed, and could corrupt data for transactions intended
for other slaves. `active_int` is the "permission flag" — all active behavior
requires it.

---

**Q31. What is `timer_clr` in the master controller and how does it work?**

`timer_clr = (state != next_state)` — the timer resets whenever the FSM
transitions to a new state. This means the timer starts fresh at 0 upon every
state entry. Within a state, the timer counts up to T_SCL_PERIOD-1 and then
sets `timer_expired`. The master uses `timer_expired` to know when to move to
the next state or take an action (toggle SCL, shift the next bit, etc.).

KEY INSIGHT: Using `state != next_state` as the clear condition means the timer
resets on the SAME CYCLE that the state changes. This ensures the timer starts
counting from 0 on the first cycle of the new state. Using a delayed version
would cause an off-by-one in every state's timing.

---

**Q32. Why does the master RTL use both `scl_rise` and `timer_expired` for
different purposes?**

`timer_expired` is generated by the master's own internal timer — it fires when
the master WANTS SCL to have risen (based on T_SCL_LOW count). `scl_rise` is
an external observation of SCL actually rising, detected by comparing `scl_i`
with `scl_d`. During clock stretching, the master releases SCL but the slave
holds it low. `timer_expired` fires (master's timer ran out) but `scl_rise`
does NOT fire (SCL is still being held low). The master uses `scl_rise` for
ACK sampling (must sample AFTER SCL actually rises, not just after timer expiry)
and `timer_expired` for state transitions.

KEY INSIGHT: The distinction between "when the master expected SCL to rise"
(`timer_expired`) and "when SCL actually rose" (`scl_rise`) is fundamental to
clock stretching support. Ignoring this distinction causes the master to sample
SDA before SCL actually rises, reading the wrong bit value.

---

**Q33. What is the `reg_data_buf` register and what is its role in the
master's CPU interface?**

`reg_data_buf` is a CPU-visible register mapped to `REG_DATA` (address 3'd3).
The CPU writes data to be transmitted into this register before issuing a
CMD_WRITE command. The RTL loads `shift_reg` from `reg_data_buf` for
transmission. After a read transaction, the RTL writes the received byte
BACK into `reg_data_buf` (Bug #10 fix). The CPU then reads `REG_DATA` to
retrieve the received byte.

KEY INSIGHT: The data path for received data is: I2C SDA → `shift_reg` →
`reg_data_buf` → `cpu_rdata`. Bug #10 broke the second link: `shift_reg` was
NEVER written to `reg_data_buf` after reception. The CPU always read 0x00
(reset value). The fix is a single conditional assignment when the FSM
transitions from `STATE_RX_BIT` to `STATE_ACK_SEND`.

---

**Q34. What synthesis issue arises if you drive the same signal from
both `always_ff` and `always_comb` blocks?**

This causes a multi-driver synthesis error. In hardware, this means two logic
networks are simultaneously connected to the same wire. If they drive the same
value, it wastes power. If they drive different values, you get a logic conflict
(in real hardware, this can damage devices; in simulation, the result is X).
Synthesis tools refuse to generate a netlist for multi-driven signals.

In simulation, SystemVerilog resolves conflicts using drive strength — but in
synthesis, there is no drive strength concept. Synthesis requires exactly one
combinational driver per signal (for unregistered signals) or one sequential
driver (for registered signals).

KEY INSIGHT: The rule is simple: choose ONE always block to drive each signal.
`always_comb` drives combinational signals (like `next_state`). `always_ff`
drives registered signals (like `state`). Never mix.

---

**Q35. What is `$clog2` and when would you use it?**

`$clog2(N)` is a SystemVerilog system function that returns the ceiling of
log₂(N) — the minimum number of bits needed to represent N values.
`$clog2(500)` = 9 (since 2⁸=256 < 500 ≤ 512=2⁹).
Used in this project: `logic [$clog2(T_SCL_PERIOD)-1:0] timer` creates a
timer that is exactly wide enough to hold values 0 through T_SCL_PERIOD-1.

KEY INSIGHT: Using `$clog2` instead of hardcoding bit widths makes the design
parameter-scalable. If you change T_SCL_PERIOD (e.g., to support a different
clock frequency), the timer width adjusts automatically. Hardcoding widths is
a common source of overflow bugs when parameters change.

---

**Q36. Explain how the master generates a Repeated START on the I2C bus.**

A Repeated START requires: SCL high, then SDA goes high (SDA was already low),
then SDA goes low (START). The master FSM uses two states:
- `STATE_REP_START_1`: SCL goes HIGH, SDA goes HIGH. Wait T timing.
- `STATE_REP_START_2`: SCL stays HIGH, SDA goes LOW. This is the Sr.
  Then SCL goes LOW to begin clocking the new address.

This is different from a regular START because at the beginning of Sr, SDA is
LOW (from the previous data transmission). It must go high BEFORE going low
again to create the START pattern.

KEY INSIGHT: The sequence for Sr is: (1) ensure SCL is low (from previous data
bit), (2) release SDA HIGH while SCL is low, (3) raise SCL HIGH, (4) pull SDA
LOW while SCL remains HIGH (this is the START event), (5) pull SCL LOW to begin
the next address byte. Skipping step (2) would create a STOP instead of a Sr.

---

**Q37. What happens at reset (`rst_n == 0`) in this RTL and why does it matter?**

At reset, all registered signals return to safe default values:
- `state <= STATE_IDLE` / `SLV_IDLE`: FSM in idle, no active transaction
- `sda_o <= 1'b1`: SDA released (open-drain high, safe state)
- `scl_o <= 1'b1`: SCL released (open-drain high, safe state)
- `shift_reg <= 8'h00`, `reg_data_buf <= 8'h00`: data registers cleared
- `active_int <= 1'b0`: not in an active transaction

This matters because: (1) it defines a known starting state for the DUT;
(2) it ensures the bus is released at power-on (both lines high = idle);
(3) it enables the testbench to reset and re-run without residual state.

KEY INSIGHT: Reset logic is verified by a dedicated reset test that asserts
rst_n mid-transaction. The DUT must cleanly abandon the transaction and return
to idle. Any register that does NOT reset to a safe value is a potential reset
bug — the DUT may come out of reset in an invalid state.

---

**Q38. What is the purpose of the `stretch_en_rise` edge detector in the
slave controller?**

`stretch_en_rise` detects the RISING EDGE of `stretch_en` (when it goes from
0 to 1). Stretch activation is conditioned on `stretch_en_rise` instead of
`stretch_en` level. This prevents the stretch from re-activating every cycle
that `stretch_en` remains high. Without edge detection, a stretch that completes
(timer expires, `stretch_active = 0`) would immediately re-trigger as long as
`stretch_en` is still asserted, causing infinite stretching.

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) stretch_en_d <= 1'b0;
  else        stretch_en_d <= stretch_en;
end
assign stretch_en_rise = stretch_en && !stretch_en_d;  // edge detector
```

KEY INSIGHT: Edge detection (rise/fall) is a fundamental digital design
technique. Level-sensitive logic responds every cycle that a condition is true.
Edge-sensitive logic responds exactly once when a condition becomes true.
For one-shot behaviors (trigger once, then stop), you almost always need edge
detection.

---

**Q39. What is the `force_data_nack` port and why is it added to the DUT?**

`force_data_nack` is a test injection port — a DUT input added specifically to
enable testing of behavior that cannot be triggered through normal stimulus alone.
When `force_data_nack == 1`, the slave drives SDA HIGH (NACK) in `SLV_RX_ACK`
instead of LOW (ACK). This allows the testbench to test the master's data-NACK
handling path without modifying the slave's normal address-match logic.

KEY INSIGHT: Test hooks (also called "debug ports" or "DFT hooks") are a
standard DV practice. Any behavior in the DUT that requires a specific internal
condition (not triggerable externally) needs a test hook. Common examples:
error injection ports, freeze/pause signals, internal counter override inputs.
These ports are normally tied off in the final chip (force_data_nack=0) and
only active in verification.

---

**Q40. What is a one-shot guard and why is it used in the register-pointer
increment logic?**

A one-shot guard (implemented via `reg_ptr_inc_done`) ensures that an action
happens only ONCE per state entry, even if the FSM stays in that state for
multiple clock cycles. Without it, `reg_ptr <= reg_ptr + 1` would fire on every
cycle in `SLV_RX_ACK`, incrementing `reg_ptr` once per clock instead of once
per state.

```systemverilog
// With one-shot guard:
if (state == SLV_RX_ACK && active_int && !reg_ptr_inc_done) begin
  reg_ptr <= reg_ptr + 1;
  reg_ptr_inc_done <= 1'b1;  // Prevent re-trigger this state entry
end
// Reset the done flag when leaving SLV_RX_ACK:
else if (state != SLV_RX_ACK) begin
  reg_ptr_inc_done <= 1'b0;
end
```

KEY INSIGHT: One-shot guards are necessary whenever an action should be
triggered by state entry (once per transition into the state) rather than by
being in the state (once per clock cycle in the state). Without them, actions
in long-duration states repeat unintentionally.

---

## Section 3: UVM Methodology (20 Questions)

---

**Q41. What are the main components of a UVM testbench and what does each do?**

A UVM testbench has these main components:

- **Test**: top-level, selects sequences, configures the environment
- **Environment (uvm_env)**: instantiates and connects agents and scoreboards
- **Agent (uvm_agent)**: contains driver, monitor, and sequencer
- **Driver**: converts sequence items to pin-level stimulus (drives DUT inputs)
- **Monitor**: observes DUT interface signals and creates sequence items
- **Sequencer**: arbitrates between sequences and feeds items to the driver
- **Scoreboard**: compares DUT outputs (from monitor) to expected values
- **Coverage collector**: samples functional coverage when transactions complete

KEY INSIGHT: The division of Agent into driver+monitor+sequencer reflects the
separation of stimulus generation (driver/sequencer) from observation
(monitor). Monitors are always passive and never drive. Drivers are always
active and never observe. This separation allows the same monitor to be used
in both active (stimulus + observe) and passive (observe only) configurations.

---

**Q42. Explain the sequencer-driver handshake in UVM. What are the four
TLM method calls involved?**

The sequencer-driver handshake uses two TLM FIFO methods in a loop:

1. **`seq_item_port.get_next_item(req)`**: Driver requests the next item from
   the sequencer. Blocks until a sequence provides one.
2. **`seq_item_port.item_done()`**: Driver signals completion after driving the
   item. This frees the sequencer to provide the next item.

The sequence side uses:
3. **`start_item(req)`**: Sequence requests permission to send an item.
4. **`finish_item(req)`**: Sequence sends the item and waits for `item_done`.

KEY INSIGHT: The handshake ensures flow control: the driver runs at hardware
speed (one item per transaction), and the sequence generates at software speed.
The FIFO buffers mismatches. `item_done()` is commonly forgotten, causing the
simulation to hang (driver never signals completion, sequencer never sends next).

---

**Q43. What is `uvm_config_db` and how does it work? How was it misused in
Bug #7?**

`uvm_config_db` is a global database for passing configuration between UVM
components. You set values with:
```systemverilog
uvm_config_db#(type)::set(context, path, name, value);
```
And retrieve with:
```systemverilog
uvm_config_db#(type)::get(context, path, name, var);
```

The lookup matches the MOST SPECIFIC path. A set from a child component can
override a set from a parent if both use the same resolution path and the child
is more specific.

In Bug #7: the env set `UVM_PASSIVE` for `"slave_agent"` during build_phase,
AFTER the test had already set `UVM_ACTIVE` for `"env.slave_agent"`. The env's
set was more specific (relative to env context) and overwrote the test's set.
The fix was to `get` before `set` — only set the default if no value was already
configured.

KEY INSIGHT: Config_db follows "most specific path wins" — not "most recent
set wins." Understanding path resolution is critical for building testbenches
where tests can override environment defaults. The check-before-set pattern
is the standard idiom for overridable defaults.

---

**Q44. What is the UVM factory and when would you use it?**

The UVM factory is a registration and override mechanism. When you register a
class with the factory (`uvm_component_utils` or `uvm_object_utils`), the
factory can instantiate it. More importantly, you can override a class type
with a derived class without changing the testbench code:

```systemverilog
// In test: replace i2c_seq_item with error_injection_seq_item everywhere
factory.set_type_override_by_type(
  i2c_seq_item::get_type(),
  error_injection_seq_item::get_type()
);
```

KEY INSIGHT: The factory enables "variant testing" — using a different version
of a component for a specific test without recompiling the entire testbench.
This is used for: injecting error stimulus, replacing a monitor with a checking
monitor, or using a faster-but-less-accurate model.

---

**Q45. What is TLM (Transaction Level Modeling) and why is it used in UVM?**

TLM is an abstraction for communication between components using transactions
(objects) rather than signal-level data. In UVM, TLM ports and FIFOs connect
components: the driver pulls items from the sequencer via a TLM FIFO, and the
monitor writes transactions to a TLM analysis port that broadcasts to all
subscribers (scoreboards, coverage collectors).

KEY INSIGHT: The `analysis_port.write()` / `analysis_imp.write()` mechanism is
one-to-many: one monitor can feed multiple subscribers (scoreboard, coverage,
logger) without the monitor knowing how many there are. This loose coupling
allows adding a new checker without modifying the monitor.

```systemverilog
// Monitor broadcasts to all subscribers:
ap.write(item);  // analysis_port

// Scoreboard receives:
function void write(i2c_seq_item t);  // analysis_imp implementation
  // compare t against expected
endfunction
```

---

**Q46. What are UVM phases and in what order do they execute?**

UVM phases execute in this order:

BUILD PHASES (top-down, construction):
- `build_phase`: instantiate child components with `type::create()`
- `connect_phase`: connect TLM ports between components

SIMULATION PHASES (in order, bottom-up start for some):
- `start_of_simulation_phase`: final setup before simulation starts
- `run_phase`: all concurrent simulation activity (stimulus, monitoring)
  Note: run_phase uses objections to know when to end
- `extract_phase`, `check_phase`, `report_phase`: post-simulation analysis

KEY INSIGHT: `build_phase` is top-down (env builds before agents, agents build
before their children). `connect_phase` must happen AFTER all build phases
complete. This ordering is why you cannot instantiate a child and connect it
in the same phase — create in build, connect in connect.

---

**Q47. What is an UVM objection and how does the simulation know when to stop?**

UVM run_phase does not have a fixed end time. Instead, components raise
objections when they have work to do and drop them when finished:

```systemverilog
// In a sequence's body():
phase.raise_objection(this);  // "I have work to do"
// ... drive stimulus ...
phase.drop_objection(this);   // "I'm done"
```

The simulator ends the run_phase when all objections have been dropped.
If no test raises an objection, the simulation ends immediately at time 0.

KEY INSIGHT: Forgetting to drop an objection causes the simulation to run
forever (or until a timeout). Dropping before stimulus is complete causes early
termination. Objections are the standard mechanism, but some teams also use
`phase.phase_done.set_drain_time()` to add a grace period after the last
objection drops (allowing in-flight transactions to complete).

---

**Q48. What is a virtual sequence and why is it used?**

A virtual sequence coordinates multiple agent sequencers simultaneously. A
single test may need to drive the master agent (via the master sequencer) and
the slave agent (via the slave sequencer) at the same time. A virtual sequence
holds handles to both sequencers and can interleave or synchronize their
activities:

```systemverilog
class i2c_vseq extends uvm_sequence;
  i2c_master_sequencer master_sqr;
  i2c_slave_sequencer  slave_sqr;

  task body();
    fork
      `uvm_do_on(master_write_seq, master_sqr)
      `uvm_do_on(slave_respond_seq, slave_sqr)
    join
  endtask
endclass
```

KEY INSIGHT: Without virtual sequences, coordinating multiple agents requires
event synchronization across sequences — complex and error-prone. Virtual
sequences centralize coordination logic in one place, making test intent clear.

---

**Q49. What is the difference between a uvm_component and a uvm_object?**

`uvm_component`: has a fixed position in the component hierarchy (parent-child
relationships), participates in phases (has `build_phase`, `run_phase`, etc.),
and persists for the entire simulation. Examples: driver, monitor, scoreboard.

`uvm_object`: has no parent-child relationship, does NOT participate in phases,
and is transient (created and destroyed as needed). Examples: sequence items
(transactions), sequences, configuration objects.

KEY INSIGHT: Sequence items are `uvm_object` because they are created on the
fly (one per transaction) and garbage-collected after use. If they were
`uvm_component`, they would persist forever and the hierarchy would grow
unboundedly during simulation.

---

**Q50. How does a UVM monitor connect to the scoreboard?**

The monitor has a `uvm_analysis_port` (ap). The scoreboard has a
`uvm_analysis_imp` (which implements a `write()` function). In the environment's
`connect_phase`:

```systemverilog
function void connect_phase(uvm_phase phase);
  master_agent.monitor.ap.connect(scoreboard.master_imp);
  slave_agent.monitor.ap.connect(scoreboard.slave_imp);
endfunction
```

When the monitor calls `ap.write(item)`, UVM automatically calls
`scoreboard.master_imp.write(item)`. The scoreboard's `write()` function
processes the transaction (stores expected values, compares received values).

KEY INSIGHT: The `uvm_analysis_port` is a broadcast port — one write reaches
ALL connected subscribers. This is why both the scoreboard and the coverage
collector can both subscribe to the same monitor port without the monitor
needing to know about either of them.

---

**Q51. What is coverage-driven verification (CDV) and how does it relate to
your I2C project?**

CDV is a verification methodology where functional coverage goals drive the
regression process. You define a verification plan with measurable coverage
points (covergroups, bins). The simulation generates random tests. After each
regression, you check coverage. If coverage is below target (typically 90-100%),
you add directed tests or constrained-random sequences to hit the missing bins.
You do NOT declare verification complete until all coverage goals are met.

In this project: the 8 covergroups in `i2c_coverage.sv` define the coverage
model. The average coverage threshold of 90% triggers a warning if not met.

KEY INSIGHT: CDV is superior to "run N tests and hope" because it gives you a
measurable definition of "done." The verification plan is the contract between
the DV engineer and the chip owner — coverage is the proof that the contract
was fulfilled.

---

**Q52. What is the difference between `UVM_ACTIVE` and `UVM_PASSIVE` agents?**

`UVM_ACTIVE` agent: contains driver + sequencer + monitor. It generates stimulus
(drives DUT inputs) AND observes (monitors DUT outputs). Used when you need to
control the agent's interface.

`UVM_PASSIVE` agent: contains ONLY a monitor. It observes the interface but
does not drive. Used when the DUT itself drives the interface (you just want to
observe it) or when a different component drives.

KEY INSIGHT: In this project, the slave agent is normally `UVM_PASSIVE` (the
DUT slave drives itself). Tests like `clock_stretch_test` switch it to
`UVM_ACTIVE` to control the slave's stretch and NACK behavior. Bug #7 was
exactly this — the passive-default was overriding the test's active-request.

---

**Q53. What is `uvm_do` and what does it do under the hood?**

`uvm_do(item)` is a sequence macro that: (1) creates an item using the factory,
(2) randomizes it with constraints, (3) calls `start_item(item)` (requests
the sequencer), and (4) calls `finish_item(item)` (sends to driver, waits for
completion). It combines four steps into one line for convenience.

You would use `uvm_do_with` to add inline constraints:
```systemverilog
`uvm_do_with(item, { item.dir == DIR_READ; item.num_data == 4; })
```

KEY INSIGHT: `uvm_do` hides the `start_item`/`finish_item` handshake. If you
need precise control (e.g., set fields AFTER randomization but BEFORE sending),
use the manual 4-step version instead of the macro.

---

**Q54. How does the scoreboard know what the DUT should output?**

The scoreboard has two inputs: a "predicted" input (what the DUT SHOULD produce
based on the stimulus) and an "observed" input (what the DUT ACTUALLY produced,
from the monitor). The predicted model can be implemented as: a behavioral
model (reference model) that processes the same stimulus the driver sends, or
a golden-output table (pre-computed expected outputs for each scenario).

In this project: the scoreboard compares the received byte (from the slave
monitor) against the byte the master sent (from the master monitor). If they
match — pass. If not — MISMATCH error.

KEY INSIGHT: The scoreboard is the heart of self-checking verification. A
testbench without a scoreboard only tells you "the simulation ran without
crashing" — not "the DUT produced correct output." Scoreboards make failures
detectable without a human reading waveforms for every test.

---

**Q55. What does `uvm_component_utils` do and why is it required?**

`uvm_component_utils(class_name)` registers the class with the UVM factory.
It enables: (1) factory creation with `class_name::type_id::create(name, parent)`;
(2) factory overrides (replace this class type with a derived type); (3) UVM
messaging macros (`uvm_info`, `uvm_error`, etc.) to include the component name
automatically.

Without factory registration, you cannot use factory overrides, and the
component is invisible to UVM's type system.

KEY INSIGHT: `uvm_component_utils` generates several methods via macros,
including `get_type_name()`, `create()`, and `clone()`. The generated `create()`
is what makes factory overrides work — it calls through the factory instead
of calling `new()` directly.

---

**Q56. How do you pass a virtual interface to a UVM driver?**

Virtual interfaces are passed via `uvm_config_db`:

```systemverilog
// In the top-level testbench module (tb_top.sv):
uvm_config_db#(virtual i2c_if)::set(null, "uvm_test_top.*", "vif", i2c_if_inst);

// In the driver (or agent) build_phase:
virtual i2c_if vif;
if (!uvm_config_db#(virtual i2c_if)::get(this, "", "vif", vif)) begin
  `uvm_fatal(get_type_name(), "No virtual interface set for vif")
end
```

KEY INSIGHT: Virtual interfaces are the bridge between the UVM class world
(where no actual signals exist) and the SystemVerilog module world (where
physical signals are defined). The `virtual` keyword means "a handle to an
interface instance" — not the interface itself. The driver uses `vif.sda`
to drive the DUT signal through the interface.

---

**Q57. What is a `uvm_subscriber` and how is it used in the coverage
collector?**

`uvm_subscriber#(T)` is a convenience class that combines `uvm_component` with
a built-in `uvm_analysis_imp` for type T. It is the standard base class for
coverage collectors and scoreboards. The subclass implements the `write(T t)`
function, which is called every time a transaction arrives:

```systemverilog
class i2c_coverage extends uvm_subscriber #(i2c_seq_item);
  virtual function void write(i2c_seq_item t);
    this.item = t;
    i2c_dir_cg.sample();  // Sample coverage with the new item
  endfunction
endclass
```

KEY INSIGHT: `uvm_subscriber` is preferred over manually creating a
`uvm_analysis_imp` because it handles the TLM connection boilerplate. You
only need to implement `write()` and connect the port in the environment.

---

**Q58. What is the difference between `uvm_fatal`, `uvm_error`, `uvm_warning`,
and `uvm_info`?**

- `uvm_fatal`: terminates simulation immediately. Used when continuing would
  produce meaningless results (e.g., VIF not found).
- `uvm_error`: records an error but simulation CONTINUES. Used when the DUT
  produced wrong output — you want to collect all errors in one run.
- `uvm_warning`: records a warning, simulation continues. Used for borderline
  conditions that may or may not be bugs.
- `uvm_info`: informational message. Controlled by verbosity level (UVM_LOW,
  UVM_MEDIUM, UVM_HIGH, UVM_DEBUG).

KEY INSIGHT: Use `uvm_error` (not `uvm_fatal`) in scoreboards so that all
mismatches are reported in one simulation run. Using `uvm_fatal` at the first
mismatch means subsequent bugs are hidden, requiring re-runs to find them.
Use `uvm_fatal` only for setup errors where simulation cannot proceed correctly.

---

**Q59. What is a `uvm_sequence_item` and what fields does the I2C seq item
have in this project?**

A `uvm_sequence_item` is the data object passed between sequences and drivers.
It represents one logical transaction. For the I2C project, `i2c_seq_item` likely contains:

- `addr` (7-bit): target slave address
- `dir` (DIR_WRITE/DIR_READ): transaction direction
- `data[]` (byte array): bytes to write or received bytes from read
- `num_data` (int): number of data bytes
- `start_cond` (bit): whether a START was sent
- `stop_cond` (bit): whether a STOP was sent
- `rep_start` (bit): whether a Repeated START was used
- `addr_ack` (bit): whether the address was ACK'd
- `stretch_cycles` (int): how many cycles of clock stretch occurred

KEY INSIGHT: Sequence items should be self-contained — all information needed
to reconstruct the transaction from just the item. This allows the scoreboard
to compare without needing context from outside the item.

---

**Q60. How would you add a new test to this testbench?**

1. Create a new test class extending `i2c_base_test`:
```systemverilog
class i2c_burst_read_test extends i2c_base_test;
  `uvm_component_utils(i2c_burst_read_test)

  task run_phase(uvm_phase phase);
    i2c_burst_read_vseq vseq = i2c_burst_read_vseq::type_id::create("vseq");
    phase.raise_objection(this);
    vseq.start(env.master_agent.sequencer);
    phase.drop_objection(this);
  endtask
endclass
```

2. Create the virtual sequence with the desired stimulus.
3. Add the test to the regression list.
4. Run and check scoreboard + coverage.

KEY INSIGHT: The test itself should contain NO signal-level stimulus. All
signal driving is in the driver. All transaction definitions are in sequences.
The test only selects WHICH sequences to run. This separation means tests are
short, readable, and reusable.

---

## Section 4: SVA Assertions (10 Questions)

---

**Q61. What are the two types of SVA implication operators and when do you
use each?**

`|->` (overlapping): the consequent must be true starting from the SAME cycle
as the last part of the antecedent.
`|=>` (non-overlapping): the consequent must be true starting from the NEXT
cycle after the antecedent matches.

Example:
```systemverilog
// Overlapping: if SCL is high AND SDA just fell (START), then ALSO in THIS cycle SCL is high
(scl == 1 && $fell(sda)) |-> (scl == 1);  // Tautological — same cycle!

// Non-overlapping: after START, in the NEXT cycle something happens
(scl == 1 && $fell(sda)) |=> ##[0:10] (scl == 0);  // SCL must fall within 10 cycles
```

KEY INSIGHT: `|->` is for same-cycle or same-sequence-completion relations.
`|=>` is for "next cycle or later" relations. Bug #11's tautology used `|->`
with a consequent that was part of the antecedent — same cycle, same signal,
guaranteed true.

---

**Q62. What does `##N` mean in SVA and how do `##[1:5]` and `##[*0:$]` differ?**

`##N`: exactly N clock cycles later.
`##[m:n]`: anywhere between m and n clock cycles later (non-deterministic —
the property passes if ANY offset in the range satisfies the consequent).
`##[0:$]`: from 0 cycles to forever — "eventually."
`##[*0:$]` is `##[0:$]` with repetition.

Example from this project:
```systemverilog
// After START, SCL must fall within T_HD_STA + T_SCL_PERIOD cycles:
(scl_samp == 1'b1 && sda_fall) |-> ##[1:(T_HD_STA + T_SCL_PERIOD)] (scl_samp == 1'b0);
// Passes if SCL falls at ANY point from cycle 1 to cycle (T_HD_STA+T_SCL_PERIOD)
```

KEY INSIGHT: `##[1:N]` is an open-ended check — it passes if the condition is
true at ANY cycle in the range. It does NOT require the condition to be true
at ALL cycles in the range. For "must remain true," use `$stable()` or repeated
sequences instead.

---

**Q63. What is `disable iff` in an SVA property and when should you use it?**

`disable iff (condition)` vacuously passes the property whenever the condition
is true. It is used to suppress assertions during reset or during known-invalid
time periods:

```systemverilog
property p_sda_stable;
  @(posedge clk)
  disable iff (!rst_n)  // Suppress during reset — DUT is in unknown state
  (in_data_phase && scl_samp == 1'b1) |-> $stable(sda_samp);
endproperty
```

Without `disable iff (!rst_n)`, the assertion fires on the first clock after
power-on (when registered signals are still X or at reset values) and produces
false failures.

KEY INSIGHT: `disable iff` makes the assertion vacuously true (not "fail")
during the disabled period — it does NOT skip the clock edge. The assertion
is re-evaluated every clock, but if `disable_iff` is true, the result is
always pass. This is different from `assume` (which modifies formal behavior).

---

**Q64. What is the difference between `assert property` and `assume property`
in formal verification?**

`assert property`: a claim that must be TRUE. If the formal tool finds any
reachable state where the property is false, it generates a counterexample.
This is used for DUT correctness checks.

`assume property`: a constraint on inputs. The formal tool only explores input
sequences where the assume holds. This is used to constrain the input space
to valid scenarios (e.g., "assume the master always sends START before data").

KEY INSIGHT: In formal verification, wrong assumptions can hide bugs. If you
assume something the DUT actually depends on being a certain way, you may
prevent the tool from exploring the scenario where that assumption fails —
and that scenario might be the one where the bug is. Assumptions must be
verified by other means.

---

**Q65. How do you detect a tautological assertion? Give the formal logic proof.**

A tautological assertion has a consequent that is ALWAYS TRUE whenever the
antecedent is true — regardless of DUT behavior.

Test method: Assume the antecedent is true. Now check: can the consequent be
false? If NO — it is a tautology.

Formal proof for Bug #11:
- Antecedent: `(scl_samp == 1'b1 && sda_fall)` — this is TRUE only when `scl_samp == 1'b1`
- Consequent: `(scl_samp == 1'b1)` — this requires `scl_samp == 1'b1`
- Given antecedent is TRUE, we KNOW `scl_samp == 1'b1` (from antecedent).
- Therefore consequent is ALWAYS TRUE when antecedent is TRUE.
- The implication `A → B` is always true when B is guaranteed by A.
- Tautology proven. QED.

KEY INSIGHT: Spot-check for tautology: look at the consequent and ask "is this
a weaker or equal version of something already in the antecedent?" If yes —
tautology. The consequent must require DUT ACTION that is not already guaranteed
by the antecedent's conditions.

---

**Q66. What is the `$stable()` system function in SVA and how is it used?**

`$stable(signal)` is true if `signal` has the same value in the current clock
cycle as in the PREVIOUS clock cycle. It is used to check that a signal does
not change between two consecutive clock edges.

```systemverilog
// A3: SDA must not change while SCL is high (data validity)
property p_sda_stable;
  @(posedge clk)
  (in_data_phase && scl_samp == 1'b1) |-> $stable(sda_samp);
endproperty
```

If `scl_samp == 1'b1` and SDA changed since the last clock edge, the assertion
fires. This directly checks the core I2C rule: "SDA must be stable when SCL
is high."

KEY INSIGHT: `$stable(x)` is equivalent to `(x == $past(x))`. `$past(x)` is
the value of x from the previous clock cycle. Both are useful in SVA for
temporal comparisons between consecutive cycles.

---

**Q67. What is the `$isunknown()` function and when is it used in assertions?**

`$isunknown(expression)` returns TRUE if any bit of the expression is X or Z.
It is used to detect undriven or conflicting signals on the bus:

```systemverilog
// A6: No X/Z on SDA or SCL during active data transfer
property p_no_unknown_bus;
  @(posedge clk)
  (in_data_phase || in_ack_phase) |-> (!$isunknown(sda_samp) && !$isunknown(scl_samp));
endproperty
```

X values typically indicate: (1) multi-driver conflict (two drivers fighting),
(2) uninitialized flip-flop, (3) failed clock domain crossing. Z values indicate
a signal is not driven (high-impedance) when it should be.

KEY INSIGHT: X on a bus signal during active transfer is almost always a
catastrophic bug — either a multi-driver or a missing driver. The `p_no_unknown_bus`
assertion catches this immediately at the cycle it occurs, making it easy to
trace in the waveform.

---

**Q68. What is the difference between simulation-time assertions and formal
(proof-based) assertion checking?**

Simulation: assertions are checked only on the paths actually executed by the
testbench. If a test never creates the exact input pattern that violates the
assertion, the violation goes undetected. Coverage is limited to what you
stimulated.

Formal: the tool mathematically exhausts all possible input sequences (within
the input space defined by `assume` constraints). If there exists ANY input
sequence that violates the assertion, the tool finds it and produces a
counterexample. This is definitive — a "proven" result means the property holds
for ALL possible inputs.

KEY INSIGHT: Formal tools found tautological assertions (Bugs #11, #12) by
proving they could never be false. A "formally proven" tautological assertion
is immediately suspicious — correct properties are provable but non-trivial.
If a property is provably vacuous (holds for all inputs including completely
random ones), it is likely a tautology.

---

**Q69. What is assertion coverage and how does it differ from functional coverage?**

Assertion coverage measures whether assertions are being exercised — specifically:
(1) Whether the antecedent (trigger) was ever true, (2) whether the assertion
ever passed (consequent held), (3) whether the assertion ever fired (vacuously
passed because `disable iff` was true). A good assertion suite has high
antecedent hit rates.

Functional coverage (covergroups/bins) measures whether the DUT was exercised
in specific meaningful scenarios.

KEY INSIGHT: If an assertion's antecedent is never triggered in the entire
regression, the assertion is effectively off — it provides zero value.
Check assertion coverage alongside functional coverage. An untriggered
assertion is either: (1) a test gap (need a test that creates the condition),
or (2) an impossible condition (structural dead assertion — remove it).

---

**Q70. How would you write an SVA assertion to check that the bit counter
(bit_cnt) resets to 0 after ACK?**

```systemverilog
property p_bit_cnt_reset_after_ack;
  @(posedge clk)
  disable iff (!rst_n)
  // When entering SLV_ACK state (from SLV_ADDR), bit_cnt must reset next cycle
  (state == SLV_ADDR && next_state == SLV_ACK) |=> (bit_cnt == 4'd0);
endproperty
assert_bit_cnt: assert property (p_bit_cnt_reset_after_ack);
```

The `|=>` ensures we check the NEXT cycle (after the state has changed to SLV_ACK).

KEY INSIGHT: Structural assertions (checking state machine invariants like
"bit_cnt is 0 when entering ACK state") are powerful for catching FSM bugs.
They check that the RTL structure is correct, not just that outputs are right.
These assertions catch bugs before they propagate to outputs.

---

## Section 5: Functional Coverage (10 Questions)

---

**Q71. What is a covergroup and how does it differ from a coverpoint?**

A covergroup is a container that defines what to measure. It can contain
multiple coverpoints and cross coverage. A coverpoint is a single measurement
within a covergroup — it tracks values of one expression and distributes them
into bins:

```systemverilog
covergroup i2c_dir_cg;
  cp_dir: coverpoint item.dir {   // "cp_dir" is the coverpoint
    bins write = {DIR_WRITE};     // These are the bins
    bins read  = {DIR_READ};
  }
endgroup
```

`get_coverage()` returns the percentage of bins that have been hit.

KEY INSIGHT: A covergroup is instantiated with `new()` and sampled with
`.sample()`. Each `sample()` call evaluates all coverpoints in the group
and marks the appropriate bins as hit. Bins that have never been hit represent
scenarios that have not been verified.

---

**Q72. What are the types of bins in a coverpoint?**

- `bins name = {value_list}`: explicit bin — hits when the coverpoint equals
  any value in the list
- `bins name = {[min:max]}`: range bin — hits when value is in [min, max]
- `bins name[]`: automatic bins — one bin per value (for small ranges)
- `illegal_bins name = {...}`: marks values as illegal — triggers an error if hit
- `ignore_bins name = {...}`: marks values to be excluded from coverage calculation

KEY INSIGHT: `illegal_bins` is used for values the DUT should NEVER produce —
for example, `SDA = X` should be illegal. When the DUT produces an illegal
value, it is flagged as an error immediately (like an implicit assertion).
This is a useful alternative to writing explicit assertions for every illegal value.

---

**Q73. What is cross coverage and why is it useful?**

Cross coverage measures combinations of two or more coverpoints. A bin in cross
coverage is a PAIR (or tuple) of values — one from each crossed coverpoint.

```systemverilog
covergroup i2c_burst_cg;
  cp_dir: coverpoint item.dir;
  cp_size: coverpoint item.num_data {
    bins single = {1};
    bins burst  = {[2:32]};
  }
  cross cp_dir, cp_size;  // Measures all combinations of dir x size
endgroup
```

This ensures you cover: write+single, write+burst, read+single, read+burst.
Without cross coverage, you might have tested all directions and all sizes
separately, but never the combination "read a burst" — which might have a
different code path than "write a burst."

KEY INSIGHT: Cross coverage explodes combinatorially — 3 coverpoints with 4 bins
each produce 4×4×4 = 64 cross bins. For large coverpoint spaces, use
`binsof(cp_a.binname) && binsof(cp_b.binname)` to select only relevant
cross points, rather than crossing entire coverpoints.

---

**Q74. What is the difference between functional coverage and code coverage?**

Code coverage: measures which lines of RTL code were executed (line coverage),
which branches were taken (branch coverage), which conditions evaluated to
true/false (condition coverage), and which FSM states/transitions were reached
(FSM coverage). It is automatically generated by simulation tools.

Functional coverage: measures whether specific design behaviors or scenarios
occurred (as defined in covergroups). It is manually written based on the
verification plan.

KEY INSIGHT: 100% code coverage does NOT mean 100% functional coverage. You can
execute every RTL line without ever exercising the combination of "read
transaction + clock stretching + address NACK." Functional coverage closes this
gap by explicitly specifying which scenarios matter. Both metrics are required
for sign-off in serious DV flows.

---

**Q75. How do you close a coverage hole? Walk through the process.**

1. **Identify the missing bin:** Coverage report shows bin X is at 0%.
2. **Understand what the bin means:** What scenario does this bin represent?
3. **Check if it is reachable:** Is the scenario architecturally possible?
   If not — `ignore_bins` it and document why.
4. **Write or modify a sequence:** Create a constrained-random or directed
   sequence that forces the required scenario.
5. **Run the new test:** Verify the bin is now hit.
6. **Add to regression:** The new test joins the regression suite to keep
   coverage closed.

KEY INSIGHT: Coverage "holes" are often the most valuable tests to write —
they represent scenarios the team had not previously thought to test. When a
coverage hole corresponds to a functional bug, it means the scenario was both
untested and broken. Coverage-driven verification finds these systematic gaps.

---

**Q76. Why was Bug #13 (wrong coverage signal) a problem even though no
test failed?**

Bug #13 caused the "Register Bank Coverage" covergroup to show 100% coverage
after just a few transactions. This is a false confidence problem:

1. The covergroup claimed to measure "register access" but measured data values.
2. Data values 0-255 are easily hit by random transactions with no structure.
3. So 100% coverage was achieved trivially — with zero actual register-access
   verification.
4. Actual register access scenarios (single register write, full bank write,
   burst exceeding bank size) were never verified.
5. Bugs in register addressing logic could exist and never be caught.

KEY INSIGHT: False coverage confidence is WORSE than low coverage. Low coverage
is visible and actionable ("we need more tests here"). False confidence is
invisible — the team believes they are done when they are not. Always
verify that each coverpoint measures what its name says it measures.

---

**Q77. What is the `per_instance` coverage option and when would you use it?**

`option.per_instance = 1` creates a separate coverage database entry for each
INSTANCE of the covergroup, instead of merging all instances into one combined
report. Used when you instantiate the same covergroup multiple times (e.g., one
per agent) and want to track coverage per agent independently.

```systemverilog
covergroup i2c_dir_cg;
  option.per_instance = 1;  // Separate report for master_cg and slave_cg
  option.name = "Direction";
  // ...
endgroup

i2c_dir_cg master_cg = new();  // Separate coverage database entry
i2c_dir_cg slave_cg  = new();  // for each instance
```

KEY INSIGHT: Without `per_instance`, all instances of a covergroup contribute
to the same bins. If master always reads and slave always writes, the combined
report shows 100% coverage, hiding that each instance saw only 50%.

---

**Q78. What is the `$get_coverage()` function and how does the coverage
collector use it in `report_phase`?**

`covergroup_instance.get_coverage()` returns the current coverage percentage
(0.0 to 100.0) for that covergroup. The `i2c_coverage` collector uses this
in `report_phase` to report a summary and issue a warning if coverage is below
90%:

```systemverilog
virtual function void report_phase(uvm_phase phase);
  real avg_cov = (i2c_dir_cg.get_coverage() + i2c_data_size_cg.get_coverage() +
                  i2c_ack_cg.get_coverage() + i2c_burst_cg.get_coverage()) / 4.0;
  if (avg_cov < 90.0)
    `uvm_warning(get_type_name(), $sformatf("Coverage below 90%%: %0.2f%%", avg_cov))
endfunction
```

KEY INSIGHT: Coverage reporting in `report_phase` gives a summary at simulation
end. For multi-seed regressions, you merge coverage databases from all seeds
and evaluate the merged report — because no single seed exercises all corners.

---

**Q79. How would you add coverage for clock-stretching scenarios?**

```systemverilog
covergroup i2c_stretch_cg;
  option.per_instance = 1;
  option.name = "Clock Stretch";
  // Was stretching used at all?
  cp_stretch_used: coverpoint item.stretch_cycles > 0 {
    bins no_stretch  = {1'b0};
    bins has_stretch = {1'b1};
  }
  // What duration of stretch was used?
  cp_stretch_len: coverpoint item.stretch_cycles {
    bins short_stretch = {[1:50]};
    bins med_stretch   = {[51:500]};
    bins long_stretch  = {[501:1000]};
    ignore_bins no_stretch_case = {0};
  }
  // Cross: direction x stretch presence
  cp_dir: coverpoint item.dir;
  cross cp_dir, cp_stretch_used;
endgroup
```

KEY INSIGHT: The cross of direction x stretch_used ensures you cover all four
combinations: read without stretch, read with stretch, write without stretch,
write with stretch. Each may exercise different code paths — especially the
`SLV_STRETCH → saved_state` transition during a read vs. during a write.

---

**Q80. What is your coverage sign-off criteria and how do you know when
verification is complete?**

Verification is complete when:
1. **Functional coverage ≥ 90%** (all planned scenarios exercised — ideally 100%)
2. **Code coverage ≥ 95%** (nearly all RTL lines/branches executed)
3. **All assertions pass** with high antecedent-trigger rates
4. **Zero scoreboard errors** across the full regression
5. **All known bugs fixed** and regression passes with fixes
6. **Verification plan signed off** — all planned tests executed and passing

In this project: the 9-assertion suite + 8 covergroups + scoreboard together
constitute the sign-off criteria. The 90% average coverage threshold in
`report_phase` reflects this.

KEY INSIGHT: "Verification complete" is a contractual claim. The verification
plan is the contract. Every item on the plan must be checked, passed, and
documented. Ad-hoc testing ("I ran some tests and nothing crashed") is NOT
a valid sign-off — coverage and assertions provide the evidence.

---

## Section 6: Verification Methodology (10 Questions)

---

**Q81. What is a verification plan (vplan) and what does it contain?**

A verification plan is the document that defines WHAT must be verified and HOW.
It typically contains:
- Feature list: every feature of the DUT (write transactions, read transactions,
  clock stretching, Repeated START, NACK handling, etc.)
- Coverage goals: for each feature, which coverpoints measure it
- Test cases: directed tests for corner cases, constrained-random for exploration
- Assertions: which properties must hold
- Sign-off criteria: what constitutes "verification complete"

KEY INSIGHT: The vplan is written BEFORE any testbench code. This ensures you
think about what to verify before you think about how. A vplan written after
the testbench tends to match what was already tested, not what SHOULD have been
tested — a classic verification bias trap.

---

**Q82. What is a seed in random simulation and why do you run multiple seeds?**

A seed is the initial value given to the random number generator (RNG). The
same seed with the same test produces IDENTICAL results every run. Different
seeds produce different random stimulus. Running the same test with 100 seeds
= 100 statistically independent random tests, exercising different corners.

KEY INSIGHT: Bugs found by random testing are often "seed-dependent" — they
only appear with specific input patterns. When you file a bug, always record
the seed that exposed it. To reproduce the bug: use the same seed, same test.
After fixing, run the same seed to confirm the fix, then re-run the full
regression to ensure no regressions.

---

**Q83. What is the bug lifecycle in a professional DV flow?**

1. **Discovery**: simulation or formal tool finds the bug (assertion fires,
   scoreboard mismatch, coverage hole reveals untested scenario)
2. **Triage**: DV engineer confirms the bug is real (not a testbench issue)
   and classifies severity (critical/major/moderate/minor)
3. **Filing**: bug is entered into the bug tracking system (JIRA, Bugzilla, etc.)
   with: reproduction steps, failing test, failing seed, waveform
4. **Root cause analysis**: RTL designer investigates and finds the root cause
5. **Fix**: RTL is corrected; the fix is reviewed by a second engineer
6. **Verification**: the original failing test now passes; a regression is run
   to confirm no new failures (regression testing)
7. **Closure**: bug is marked closed with the fix commit hash recorded

KEY INSIGHT: Steps 3 (filing) and 6 (regression) are where junior engineers
often cut corners. Always file bugs with full reproduction information —
a bug that cannot be reproduced cannot be fixed. Always run regression after
a fix — RTL changes can introduce new bugs elsewhere.

---

**Q84. What is regression testing and when do you run it?**

A regression is a batch run of ALL tests in the test suite (often with multiple
seeds each). It answers: "Does the current RTL still pass all previously passing
tests?" You run regression:
- After any RTL change (to detect new failures)
- After any testbench change (to confirm the testbench is not broken)
- At milestone checkpoints (after feature-complete, before tape-out)
- Nightly (automated, to catch overnight RTL changes)

KEY INSIGHT: Regression tests must always pass. If a regression fails after an
RTL change, the change is reverted or fixed before continuing. "It failed
before too" is not acceptable — every test that was previously passing must
remain passing. This is the continuous integration principle applied to hardware.

---

**Q85. What is constrained random verification and what are its advantages?**

Constrained random verification generates stimulus by randomizing a sequence
item within constraints:
```systemverilog
class i2c_seq_item extends uvm_sequence_item;
  rand bit [6:0] addr;
  rand i2c_dir_e dir;
  rand int num_data;

  constraint valid_addr { addr inside {[7'h08:7'h77]}; }
  constraint valid_data { num_data inside {[1:32]}; }
endclass
```

Advantages: (1) explores large input space automatically without writing
individual test cases; (2) finds corner cases that directed tests miss;
(3) scales — adding more seeds adds more coverage without engineering effort.

KEY INSIGHT: Constrained random is not magic — it only explores the space
ALLOWED by the constraints. If your constraints are too tight, you miss corners.
If too loose, you generate many invalid scenarios that waste simulation time.
The art is in writing constraints that are exactly tight enough to generate
valid-but-interesting scenarios.

---

**Q86. What is directed testing and when is it preferred over constrained random?**

A directed test uses specific, fixed stimulus rather than random. It is used when:
1. The scenario is rare and unlikely to be hit randomly (e.g., exact timing
   violation at 250 cycle boundary)
2. The scenario requires complex coordination (e.g., clock stretch during
   the 7th bit of a read transaction)
3. Closing a specific coverage bin that random tests cannot easily hit
4. Reproducing a specific bug (the bug's reproduction case)

KEY INSIGHT: In a mature verification flow, you use BOTH: constrained random
for broad exploration, directed tests for corners and coverage closure.
Constrained random finds the bugs you did not think to test for. Directed
tests verify the behaviors you knew to worry about from the start.

---

**Q87. What DV metrics do you track to know the health of a verification project?**

Primary metrics:
- **Functional coverage**: % of covergroup bins hit (goal: ≥90%)
- **Code coverage**: line, branch, condition, FSM (goal: ≥95%)
- **Assertion pass rate**: # unique assertions that passed vs. total
- **Bug discovery rate**: new bugs per week (declining rate signals convergence)
- **Test pass rate**: % of regression tests passing

Secondary metrics:
- **Simulation throughput**: tests per hour (monitors testbench efficiency)
- **Bug closure rate**: bugs fixed per week
- **Coverage trend**: is coverage monotonically increasing with each regression?

KEY INSIGHT: Bug discovery rate is the most important project health signal.
High rate early in the project = normal (DUT is immature, bugs are plentiful).
High rate late in the project = alarming (DUT is not converging, schedule risk).
Zero rate for two weeks = either the DUT is correct OR the testbench is not
exercising it adequately.

---

**Q88. What is the difference between a monitor and a scoreboard?**

Monitor: a passive UVM component that observes DUT interface signals and
converts them to transaction objects (`i2c_seq_item`). It NEVER drives signals.
It publishes observed transactions to all subscribers via `analysis_port.write()`.

Scoreboard: a checking component that receives observed transactions from the
monitor AND expected transactions from the test/driver model, compares them,
and reports mismatches. It is the "judge" that decides pass or fail.

KEY INSIGHT: The monitor is a signal-to-transaction translator. The scoreboard
is a transaction-to-comparison engine. Keeping them separate means: (1) the
monitor can be reused in multiple environments with different scoreboards;
(2) the scoreboard is DUT-behavior-specific and can be swapped for different
check strategies.

---

**Q89. What is the purpose of a reference model (or golden model) and how
does it connect to the scoreboard?**

A reference model is a behavioral (often software) model of the DUT. It takes
the same stimulus as the DUT (same inputs) and produces the expected outputs
(golden outputs). The scoreboard compares the DUT's actual outputs (observed
by the monitor) against the reference model's predicted outputs.

In this project, the scoreboard receives write transactions from the master monitor
(expected data) and received data from the slave monitor (actual DUT behavior),
then compares them. The "reference model" is implicit: the expected output equals
the written value (identity function for a register write-read).

KEY INSIGHT: Complex DUTs (processors, protocol converters, compression engines)
need explicit reference models — often a C/C++ or Python model linked into the
simulation. For simple DUTs (like an I2C register slave), the reference model
is trivial: "read-back should equal write." Know the difference.

---

**Q90. If you had to write the verification plan for this I2C DV project from
scratch, what features would you list?**

Feature list (minimum):
1. Write transaction — single byte, multi-byte burst, max burst (8 bytes)
2. Read transaction — single byte, multi-byte burst
3. Write-then-read (Repeated START) — same register, different registers
4. Address NACK — wrong address, no ACK
5. Data NACK (write) — slave refuses data
6. Clock stretching — during write byte, during read byte, timeout scenario
7. STOP detection — clean stop, mid-byte abort
8. Arbitration (if multi-master) — bus contention detection
9. Timing compliance — T_HD_STA, T_SU_DAT, T_BUF margins
10. Reset during transaction — clean recovery to idle
11. Back-to-back transactions — no gap, minimum T_BUF gap
12. All 8 registers — each register written, each register read

KEY INSIGHT: A verification plan written without reading the RTL will miss
implementation-specific behaviors (like the `reg_ptr` auto-increment or the
`force_data_nack` hook). A verification plan written BY reading the RTL too
carefully may "verify the implementation" rather than "verify the spec."
Start from the spec, cross-reference with the RTL to find implementation
behaviors that also need coverage.

---

## Special Section: 10 "Trick" Questions That Trip Up Interns

These questions have subtleties that catch people who memorized answers
without building intuition. Study them carefully.

---

**TQ1. "Why can't you use blocking assignments (=) in an always_ff block?"**

The trap answer: "Because the simulator won't allow it."
The real answer: You CAN use blocking assignments in `always_ff` — the simulator
does not prevent it. But you SHOULD NOT because it causes simulation-synthesis
mismatches. With blocking assignments in `always_ff`, a signal updated in one
statement is immediately visible to the NEXT statement in the SAME cycle —
as if there is no flip-flop between them. In real silicon, flip-flop output
changes only on the NEXT clock edge. The simulation with `=` behaves like
combinational logic, but synthesis produces flip-flops. The design verifies
correctly in simulation but fails in hardware.

KEY INSIGHT: The SystemVerilog specification allows blocking assignments in
`always_ff` syntactically. The `always_ff` keyword is an INTENT marker, not a
syntactic enforcer. The rule is a design discipline, not a language rule.

---

**TQ2. "What happens if two masters try to talk simultaneously on I2C?"**

The trap answer: "The bus crashes."
The real answer: Because SDA is open-drain (wired-AND), bus arbitration happens
automatically without either master knowing the other exists. Both masters drive
SDA with their respective bits. If Master A drives HIGH (releases) and Master B
drives LOW (pulls down), the bus settles LOW. Master A monitors SDA and sees
LOW when it expected HIGH — it immediately backs off and waits. Master B sees
LOW as expected and continues. No crash, no data corruption on Master B's
transaction. Master A simply retries when the bus is free.

KEY INSIGHT: I2C arbitration is non-destructive because open-drain prevents
any master from FORCING the bus HIGH. A high-driving master is always the loser
in arbitration, and the loss is detectable because the master monitors the bus.

---

**TQ3. "How do you know when a simulation has verified enough?"**

The trap answer: "When coverage is 100%."
The real answer: Coverage of 100% is necessary but not sufficient. You also need:
(1) All assertions passing with high trigger rates (assertions that never trigger
provide zero value); (2) Zero scoreboard mismatches over the full regression;
(3) Bug discovery rate has converged to near-zero (diminishing returns signal
the testbench has explored the reachable space); (4) The verification plan is
explicitly signed off. "100% coverage" with weak assertions and no scoreboard
is a false signal — you have measured a lot but checked very little.

KEY INSIGHT: Coverage measures BREADTH of stimulus (what scenarios were exercised).
Checking (assertions, scoreboards) measures DEPTH of validation (whether each
scenario produced correct output). Both are required. High coverage with no
checking = "we drove the DUT many ways but never verified it was right."

---

**TQ4. "Your assertion passes 100% of the time — is that good?"**

The trap answer: "Yes, the DUT is passing all checks."
The real answer: Not necessarily. Ask: "Is the antecedent ever triggered?"
If the assertion antecedent never fires, the assertion passes vacuously — it is
never even checked. An assertion that never triggers provides exactly zero
verification value. Additionally, the assertion could be a tautology (Bugs #11,
#12) — structurally impossible to fail regardless of DUT behavior. A good
assertion: triggers frequently in normal operation, fails when the corresponding
DUT feature is broken.

KEY INSIGHT: The correct metric is not "did the assertion pass?" but
"(1) did the assertion trigger frequently? AND (2) did the assertion ever fail
when the DUT was intentionally broken?" If you cannot answer yes to both,
the assertion may be useless.

---

**TQ5. "How do you test a feature that should NEVER happen?"**

The trap answer: "You can't — if it never happens, you can't verify it."
The real answer: Use negative testing. You inject the condition artificially
(via test hooks or interface forcing) and verify that the DUT handles it
correctly — even if "correct handling" means ignoring it or generating an error.
Additionally, use formal verification: prove that the condition cannot be reached
under normal operation. Both approaches are valid and complementary.

For example, verifying "SDA must never change while SCL is high (except START/STOP)":
Write an assertion that checks this. Then inject a violation (force SDA to change
at the wrong time) and confirm the assertion fires. This validates the assertion
itself.

KEY INSIGHT: Testing negative scenarios ("what happens if X goes wrong") is as
important as testing positive scenarios ("does X work correctly"). Many bugs in
error handling and protocol violation recovery are found only by injecting
specific error conditions.

---

**TQ6. "What is the first thing you do when a regression fails overnight?"**

The trap answer: "Debug the failure."
The real answer: First, determine if it is a NEW failure or a pre-existing one.
Check: was this test passing before the last RTL change? If yes — the failure
is likely caused by the recent change. If no — the failure is pre-existing and
may not be related to today's work. Then: reproduce the failure locally with
the same seed. Read the error message and identify the first wrong signal. Only
THEN start debugging.

KEY INSIGHT: Jumping to debugging before confirming "is this new?" wastes time.
A failure that existed before a change is not the change's fault. Bisecting the
commit history (if the regression history is tracked) quickly identifies which
RTL change introduced the failure.

---

**TQ7. "You find a bug late in the project schedule. The design lead wants to
ship without fixing it. What do you do?"**

The trap answer: "Fix it or refuse to sign off."
The real answer: This is a risk management decision, not a purely technical one.
Document the bug clearly: severity, impact, reproducibility, workaround. Escalate
to the engineering lead with your technical assessment. The decision to ship with
a known bug belongs to the engineering lead or program manager — not the DV
engineer acting alone. Your job is to ensure the decision-makers have accurate
information. If overruled, document that you flagged the risk and were overruled.

KEY INSIGHT: DV engineers provide technical truth, not business decisions.
"The chip has this bug under these conditions" is a DV responsibility. "Should
we ship anyway?" is a program management decision. These are different roles.
The documentation protects you professionally if the shipped chip exhibits
the bug in the field.

---

**TQ8. "What is an X-pessimism false failure and how do you deal with it?"**

X-pessimism occurs when simulation propagates X (unknown) through logic gates
according to conservative X-propagation rules, producing X on signals that
would actually be 0 or 1 in real hardware. For example: `x AND 0 = 0` in
hardware (0 kills it), but some simulators produce X. This causes assertions
to fail on conditions that are actually benign in hardware.

Dealing with it: (1) use `$rose()`, `$fell()`, `$stable()` instead of
comparisons with X-possible signals; (2) add explicit reset checks to eliminate
X before sampling; (3) use X-optimistic simulation modes (e.g., Synopsys VCS's
-xprop feature) when X-pessimism is confirmed to be false; (4) ensure all
flip-flops are explicitly reset to eliminate post-reset X propagation.

KEY INSIGHT: X-pessimism is a simulation-only artifact — real hardware never
has X. If an assertion fails at time=0 before reset, X-pessimism is the likely
cause. The `disable iff (!rst_n)` in every assertion prevents this specific case.

---

**TQ9. "What is the difference between $rose and $posedge in SVA?"**

`$posedge(signal)`: a clock specification keyword used in `@(posedge clk)`.
It describes WHEN to sample — "evaluate at the rising edge of clk."
`$rose(signal)`: a sampled value function used in SVA sequences. It is true
if `signal` was 0 in the PREVIOUS cycle and is 1 in the CURRENT cycle (when
evaluated after the sampling clock edge). It detects a rising edge on a sampled
signal.

```systemverilog
@(posedge clk)  // posedge clk is the sampling clock
$rose(sda)      // is true if sda just transitioned from 0 to 1
```

KEY INSIGHT: In SVA, `$rose(sda)` is evaluated at the sampling clock edge —
it checks sampled values, not the actual signal edge. This is important because
SVA operates on sampled values (after the clock captures them), not on
combinational glitches.

---

**TQ10. "When would you use a formal tool instead of simulation?"**

Simulation is better when: the design space is large and random coverage can
explore it efficiently; when runtime-long transactions (hundreds of thousands
of cycles) need to be simulated; when software-hardware co-verification is
needed.

Formal is better when: you need to PROVE a property for ALL possible inputs
(not just simulated ones); when the bug requires a very specific, rare input
sequence that random tests are unlikely to generate; when you want to find the
MINIMUM number of cycles needed to violate a property (shortest counterexample);
when proving that unreachable code is truly unreachable (reachability analysis).

KEY INSIGHT: Formal tools are a complement to simulation, not a replacement.
Use formal to prove properties that simulation cannot exhaustively check. Use
simulation for behavioral verification at system-transaction level. The most
powerful DV flows combine both: simulation for functional verification,
formal for protocol property proving.

---

## Quick Reference: Most Commonly Asked Topics

```
Topic                         Most Important Point
---------------------------   --------------------------------------------------
I2C START/STOP               SDA changes while SCL HIGH — unique, unambiguous
I2C ACK                      9th bit, driven by RECEIVER (not sender)
Open-drain                   Can only pull LOW, cannot push HIGH
Wired-AND                    Any device pulling LOW wins (arbitration basis)
Clock stretching             Slave holds SCL LOW; must be in active transaction
Two-always FSM               FF owns state registration; comb owns next_state
Non-blocking assignment      RHS evaluated now, LHS updated at end of time step
Shift register               Shifts on SCL rise; latch BEFORE 9th clock (ACK)
Saved state                  Service state must record where it came from
Off-by-one counter           Start at 1 for >= N comparison; start at 0 for > N
Multi-driver                 grep all assignments; one always block per signal
Tautology                    Consequent guaranteed by antecedent → always passes
Config_db override           Check-before-set pattern for overridable defaults
Factory override             Replace class type without modifying testbench code
Coverage vs assertions       Coverage = breadth (what was exercised)
                              Assertions = depth (was each scenario correct)
Formal vs simulation         Formal proves for ALL inputs; simulation checks some
```

---

*This file is the final document in the I2C Protocol DV learning series.*

---

## Section 7: Recent Enhancements Q&A — T13 Arbitration, A7-A9 Assertions, Coverage Closure

This section was added after the project was extended with:
- 3 new SVA assertions (A7 strict bus-free, A8 hold time, A9 setup time)
- 1 new test (T13 arbitration_lost_test) with RTL `arb_lost` detection
- A coverage closure report (`docs/COVERAGE_CLOSURE_REPORT.md`)

The 10 questions below cover topics that interviewers will probe if you
mention these enhancements in a portfolio review. Each answer has 3-5
sentences plus a KEY INSIGHT line for quick recall.

---

### Q1: How does I2C bus arbitration work between two masters?

**Answer**: I2C uses an open-drain (wired-AND) bus where any device can
only pull the line LOW; releasing means HIGH (via pull-up). When two
masters try to transmit simultaneously, they both drive the bus and
compare what they see. The master driving LOW always wins because LOW
overrides HIGH electrically. The losing master detects loss by observing
that the bus reads LOW when it intended to drive HIGH (i.e., its
released SDA came back as 0 because another master is pulling it down).
On detecting loss, the loser releases the bus silently and goes to IDLE
— it must NOT issue a STOP because that would corrupt the winning
master's ongoing transaction.

**KEY INSIGHT**: Arbitration is not "fault detection and recovery" — it
is the INTENDED mechanism for picking a winner. The losing master's job
is to vanish silently; the winner doesn't even know there was a contest.

---

### Q2: How did you verify arbitration in your project?

**Answer**: I added a 16th test, T13 (`arbitration_lost_test`). Rather
than building a whole second master UVM agent (which would cost ~300
lines), I reused the existing slave_driver in a new "compete_mode". When
the test sets `compete_mode = 1` via config_db, the slave_driver spawns
a background task `drive_competition()` using `fork...join_none`. That
task watches for the master under test to issue START, counts SCL pulses,
and at the configured bit position pulls SDA LOW via a new
`sda_drv_x` open-drain proxy in the interface. The master RTL's
`arb_lost` detection logic sees `sda_o=1, sda_i=0, scl_i=1` and latches
the arb_lost flag, transitioning to IDLE without driving STOP. The test
PASSES if no UVM_ERROR is observed at the protocol layer.

**KEY INSIGHT**: When you need a second driver for one test, look at
which existing component already has bus access and add an opt-in
fork-join_none task to it. Don't build a whole new agent.

---

### Q3: What's the difference between A2 (bus free at some point in T_BUF) and A7 (bus free for ALL of T_BUF)?

**Answer**: A2 is a "weak liveness" check — it requires the bus to be
HIGH at SOME point within T_BUF after STOP. This is necessary but not
sufficient — it proves the bus EVENTUALLY recovers. A7 is a "strong
safety" check — it requires the bus to be HIGH at EVERY cycle of T_BUF.
This is sufficient — it proves the bus stays clean for the entire
recovery period. A2 alone misses glitches DURING the bus-free window
(e.g., a slow slave that briefly pulls SDA low mid-recovery). A7 catches
those because every cycle must be HIGH. You want BOTH: A2 alone is
insufficient, A7 alone has no antecedent if the bus never reaches STOP.

**KEY INSIGHT**: Necessary vs sufficient — A2 is necessary (bus must
eventually recover), A7 is sufficient (bus must stay clean throughout).
Production-quality verification needs both.

---

### Q4: Explain the `[*N]` operator in SVA.

**Answer**: `[*N]` is the consecutive-repetition operator. The
expression `P[*N]` means "P must hold for N consecutive clock cycles".
The simulator unrolls it into `P ##1 P ##1 P ##1 ... ##1 P` with N
repetitions, where `##1` advances one cycle each step. If ANY one of
those N cycles fails, the entire sequence fails. There are two related
operators: `[=N]` (non-consecutive — P must hold N times eventually,
with gaps allowed) and `[->N]` (goto repetition — P must hold N times,
ending exactly when the Nth hold occurs). For setup/hold/window checks
you almost always want `[*N]` because you need CONTIGUOUS stability.

**KEY INSIGHT**: `[*N]` is for "must hold for N cycles in a row". `[=N]`
is for "must hold N times total". `[->N]` is for "fire on the Nth
occurrence". Pick `[*N]` for setup/hold/window protection.

---

### Q5: What is the difference between data SETUP time and data HOLD time?

**Answer**: Setup time is how long a signal must be STABLE BEFORE a
clock edge so the receiver's sample flip-flop can latch it cleanly.
Hold time is how long a signal must be STABLE AFTER a clock edge before
it's safe to change. In I2C terms: T_SU_DAT (setup) means SDA must be
stable for N cycles BEFORE SCL rises (so the slave samples a settled
value). T_HD_DAT (hold) means SDA must be stable for N cycles AFTER
SCL falls (so the slave's sample doesn't catch a transient value). Both
violations create metastability in the receiver. Setup violations =
slave samples wrong bit. Hold violations = slave's flip-flop output is
indeterminate.

**KEY INSIGHT**: Setup = BEFORE the edge (when the sample happens).
Hold = AFTER the edge (when the value must remain). Both protect the
receiver's flip-flop from metastable inputs.

---

### Q6: Why do we need separate setup and hold assertions when we already have "SDA stable during SCL high"?

**Answer**: A3 ("SDA stable during SCL high") is the VALIDITY-window
check — it confirms the bit value doesn't change while the clock is
HIGH. But A3 says NOTHING about what happens at the EDGES — the
transitions from LOW-to-HIGH (rising) and HIGH-to-LOW (falling). A
master could change SDA exactly at the moment SCL rises, and A3 would
PASS (the new value IS stable during the subsequent SCL HIGH window).
But the slave's sample-flip-flop would see a glitch at the rising edge.
A8 (hold) and A9 (setup) protect the edge windows. A3 protects the
middle. Together they form a complete "ring of protection" around every
SDA transition. Different protocol violations live at different points
in the cycle.

**KEY INSIGHT**: A3 = validity window. A8/A9 = transition windows. The
sample flip-flop's setup/hold requirements are independent of the
validity window. A3 alone doesn't catch edge-window glitches.

---

### Q7: What is `$past(signal, N)` in SVA?

**Answer**: `$past(signal, N)` is a built-in SVA function that returns
the value of `signal` from N clock cycles ago. The simulator maintains a
sliding history buffer of `signal`'s recent values; calling
`$past(sda_samp, 5)` looks up what `sda_samp` was 5 cycles before the
current cycle. We use it in A9 to compare `$past(sda_samp, T_SU_DAT) ==
sda_samp` — if they match, SDA has been at its current value for at
least T_SU_DAT cycles. This is more efficient than `$stable(sda_samp)
[*T_SU_DAT]` because it's a simple equality check, not a sequence with
unrolled-cycle machinery. There's also `$past(signal)` (one cycle ago,
N defaults to 1) and `$past(signal, N, expr)` which gates the lookup
on `expr`.

**KEY INSIGHT**: `$past(s, N)` = "what was s, N cycles ago?". Used for
setup checks. Cheaper than `$stable(s)[*N]` because no sequence
machinery is built.

---

### Q8: How do you achieve coverage closure?

**Answer**: Coverage closure is an iterative process: (1) Define a
coverage model (covergroups, bins, crosses) based on the spec — what
SHOULD be exercised? (2) Run the full regression with coverage enabled
to produce UCDB/.vdb files. (3) Merge the per-test coverage databases
into a single closure database. (4) Generate HTML/text reports and
identify holes — bins at 0%, low-hit bins, missing crosses. (5) For
each hole, decide: write a directed test, broaden a random constraint,
or document an ignore_bins justification. (6) Re-run regression and
re-measure. Iterate until you reach 95%+ (with the remaining 5% being
documented ignore_bins or work in progress). The final deliverable is a
closure report (like `docs/COVERAGE_CLOSURE_REPORT.md`) that traces
every bin to a hitting test and lists every excluded bin with
justification.

**KEY INSIGHT**: Closure is iterative, not one-shot. Each iteration:
identify holes, write fixes, re-measure. End state is 95%+ with the
remaining 5% being EXPLICITLY waived bins.

---

### Q9: What is a cross coverage hole and why does it matter?

**Answer**: A cross-coverage hole is a CELL in a cross-product that
nobody hits, even when each INDIVIDUAL coverpoint reaches 100%. For
example, `i2c_burst_cg` crosses direction (WRITE, READ) with size
buckets (single, short, med, long). The individual `cp_dir` might be
100% (every direction hit somewhere) and `cp_size` might be 100% (every
bucket hit somewhere), but the cell `READ × long_burst` might never be
hit because all your read tests use small bursts. Most bugs live at
cross intersections — e.g., the slave handles long bursts correctly for
WRITE but corrupts them for READ. If you measure only individual
coverpoints, you'd report "100% closed" and miss the bug. Cross
coverage forces directional tests through every combination.

**KEY INSIGHT**: Individual coverpoints answer "did we exercise X and
Y separately?". Crosses answer "did we exercise X AND Y together?".
The combinations are where bugs hide.

---

### Q10: If a coverage bin is impossible to hit, what should you do?

**Answer**: Mark it with `ignore_bins`. The syntax is `ignore_bins
<name> = {<value>};` inside the coverpoint. This tells the simulator
that the bin is intentionally excluded from the closure percentage — it
won't count as a "missing hit" and won't degrade the closure number.
You MUST include a comment explaining WHY the bin is unreachable; in
this project, `cp_start.no_start = 0` is unreachable because
`valid_protocol_c` in `i2c_seq_item.sv:58` forbids `start_cond=0` AND
`rep_start=0` simultaneously. If the bin SHOULD never happen (i.e.,
hitting it indicates a bug), use `illegal_bins` instead — that flags a
hit as an error. A blanket "I can't figure out how to hit this so I'll
ignore it" is rejected at sign-off review; the justification must be
based on a constraint or spec rule.

**KEY INSIGHT**: `ignore_bins` = "this is intentionally not measured,
with justification". `illegal_bins` = "this would be a bug if it ever
hit". `bins` without ignore/illegal = "this MUST be hit by some test".

---

*End of Section 7 — Recent Enhancements Q&A*

---

## Section 7B — Coverage Model Expansion (CG9-CG16) Q&A

*Ten additional questions covering the second-round coverage expansion from
8 to 16 covergroups. These questions target the specific implementation
decisions made when closing the five measurement holes and adding five new
cross covergroups.*

---

### Q11: Describe the three-layer pattern used to get monitor-observed data into a coverage bin.

**Answer**: The pattern has three distinct layers that each carry one
responsibility. Layer 1 is the monitor, which observes bus pins and populates
seq_item fields — it adds `scl_low_cnt` counting and `rep_start_chain_depth`
tracking, then writes the result into `current_item.stretch_seen` and
`current_item.num_rep_starts`. Layer 2 is the seq_item itself, which is the
data-transfer object: it added `stretch_seen` and `num_rep_starts` as new
fields, plus updated `new()` to initialize them and `do_copy()` to copy them.
Layer 3 is the coverage class, which receives the seq_item via the analysis
port subscriber interface and calls `.sample()` on the relevant covergroup. No
layer bypasses another — the monitor does not call coverage directly, and the
coverage class does not read bus pins. This separation means you can debug each
layer independently: if a bin is empty, check (a) is the monitor setting the
field? (b) is `do_copy()` propagating it? (c) is the covergroup sampling it?

**KEY INSIGHT**: Monitor → seq_item → coverage is not just a UVM convention.
It is a three-way separation of concerns that makes coverage bugs diagnosable.
A missing coverage bin narrows to one layer without touching the others.

---

### Q12: How does the monitor detect clock stretching, and why is the threshold 260 cycles?

**Answer**: The monitor maintains `scl_low_cnt`, an integer that increments
on every `posedge clk` when `scl === 1'b0` and resets to zero the moment
`scl === 1'b1`. In normal I2C operation for this design, the SCL low period is
250 cycles (one half-period at the operating frequency). When a slave stretches
the clock it holds SCL LOW by driving the open-drain line — the bus stays LOW
even after the master releases it. This shows up as `scl_low_cnt` climbing past
250. The threshold of 260 adds a 10-cycle margin for clock-domain crossing
latency and minor timing jitter — any low period of 261+ cycles is
unambiguously stretching, not a normal low period with a delayed sample. Setting
the threshold too low (say 252) would produce false positives under jitter;
setting it too high (say 350) would miss short stretches. The 10-cycle margin
balances both risks.

**KEY INSIGHT**: The threshold is `T_SCL_LOW + margin`, not an arbitrary
constant. In a real project, compute it from the clock frequency and protocol
parameters in the design specification. Hard-coding a magic number without a
comment is a maintenance hazard.

---

### Q13: What is `ignore_bins` and when should you use it instead of simply omitting the bin?

**Answer**: `ignore_bins <name> = {<values>}` is a SystemVerilog construct
that explicitly classifies a value as "intentionally not measured." It differs
from omission in three ways. First, it eliminates simulator warnings about
unclassified values — when `start_cond=0` is observed for a rep-start segment,
the simulator with `ignore_bins no_start_ok = {0}` processes it silently
instead of emitting "unclassified value in coverpoint." Second, it guarantees
the value is excluded from the closure-percentage denominator consistently
across all simulator tools (behavior for unclassified values is tool-dependent).
Third, and most importantly, it documents intent in code: any engineer reading
the file sees that someone explicitly considered this value and made a deliberate
decision. Use `ignore_bins` when: the value is unreachable due to a constraint
(`valid_protocol_c` prevents `start_cond=0` in randomised items), the value is
a don't-care state documented in the spec, or the value is a reset/idle
condition that is not relevant to the design behavior under test. Do not use it
as a shortcut to hide bins you haven't figured out how to hit — reviews should
reject `ignore_bins` without a clear justification comment.

**KEY INSIGHT**: `ignore_bins` = "I considered this and explicitly excluded it."
Omission = "I forgot this exists." Coverage review should treat them
differently: the first passes, the second fails.

---

### Q14: Why is `has_data_nack` computed in `write()` rather than expressed directly as a coverpoint on `byte_ack[0]`?

**Answer**: A coverpoint expression must be a static signal reference — it
cannot contain loops, function calls that modify state, or queue operations.
The condition "at least one byte in `byte_ack[]` is a NACK" requires iterating
over a dynamic queue of variable length, which is not expressible in coverpoint
syntax. Even referencing `byte_ack[0]` alone would only check the first byte,
missing NACKs on bytes 1, 2, ... N. The solution is to promote the computation
to the `write()` function, which executes procedural SystemVerilog code freely.
A `foreach` loop scans the queue and sets `has_data_nack = 1` if any element
is zero. The coverpoint then references the scalar `has_data_nack`. This is a
general pattern: whenever a coverage condition requires a computation that
coverpoint syntax cannot express, compute it in `write()` and cover the result.
A secondary benefit is testability — `has_data_nack` can be checked with
`$display` or a `uvm_info` call during debug, whereas a coverpoint expression
cannot be inspected at runtime.

**KEY INSIGHT**: Coverpoints cover signals. When your condition is a
computation, compute it first and then cover the result. The coverage class is
allowed to be a thin data processor, not just a passive subscriber.

---

### Q15: If a 2×3 cross covergroup has 6 cells and all 5 individual bins close at 100%, is there anything that can still be wrong?

**Answer**: Yes — individual 100% closure is entirely compatible with several
cross cells remaining at 0%. The cross measures COMBINATIONS, not presence.
For `i2c_dir_addr_cross_cg` with 2 directions × 3 address ranges, the 6 cells
are: WRITE×target, WRITE×low, WRITE×high, READ×target, READ×low, READ×high.
Suppose `cp_dir` hits both WRITE and READ (100%), and `cp_addr_range` hits all
three ranges (100%). The individual coverpoints report perfect closure. But if
reads only ever went to the target address (0x50) — because `basic_read_test`
hard-codes `addr = 7'h50` — then READ×low and READ×high are empty. A direction-
specific address-decoding bug that only manifests during reads to non-target
addresses would survive 100% individual coverage. The cross forces
verification of every direction-address combination in the same transaction.
Six cells, not two-plus-three.

**KEY INSIGHT**: Individual coverpoints answer "was X ever true AND was Y ever
true (independently)?". A cross answers "was X true at the same time as Y, for
every combination?". The combinations are where direction-specific bugs hide.

---

### Q16: The `deep_rep` bin in CG11 (depth 3+) is defined but will never be hit by current tests. What should you do?

**Answer**: There are three options. Option 1: write a new sequence that sends
three or more consecutive rep-START segments (write → write → read, for
example). This is the correct long-term solution and is estimated at medium
effort. Option 2: mark the bin as a known gap in the closure report and track
it as a work item — this is acceptable for an interim closure if the gap is
documented with a justification (no such multi-segment transaction pattern
appears in the I2C spec sections covered by this project). Option 3: do NOT
use `ignore_bins` unless the three-segment pattern is actually prohibited by
the spec or the design; if deep chains are a valid bus behavior, the bin must
eventually be hit. The approach taken in this project was Option 2 for this
revision with Option 1 planned for the next sprint. Leaving the bin defined
(not ignored) means the closure percentage reflects the gap honestly — any
report showing less than 100% closure draws attention to it.

**KEY INSIGHT**: A defined-but-unhit bin that you leave open is better than an
`ignore_bins` for something that is theoretically reachable. The open bin is
a standing reminder. The `ignore_bins` is a commitment that it will never be
hit — make that commitment only when you can justify it from the spec.

---

### Q17: Why is arbitration-lost coverage particularly hard to close without architectural changes?

**Answer**: Arbitration loss in I2C requires two masters simultaneously
attempting to drive SDA to different values during the same bit slot. One
master drives SDA HIGH (releases the line) while another drives SDA LOW —
the LOW wins on the open-drain bus, and the HIGH-driving master detects the
discrepancy and backs off, setting `STS_ARB_LOST`. To produce this in a UVM
testbench requires a second master BFM that can be scheduled to start a
transaction at exactly the right cycle. In this project, the environment has
one master agent and one slave agent. Adding a second master agent changes the
testbench topology (two active drivers on the same bus, a new arbitration-
detection scoreboard, synchronization of the two master sequences). This is
not a one-hour change — it requires redesigning the environment architecture.
In contrast, all other coverage gaps in this project were closed by adding
fields to an existing seq_item and writing new covergroup code, which takes
minutes. Architectural changes take days and carry regression risk.

**KEY INSIGHT**: Not all coverage gaps have equal implementation cost. Before
accepting a gap as architectural, verify that no creative use of the existing
environment (force statements, direct DUT stimulus) could produce the condition.
Only escalate to architectural change when you are certain.

---

### Q18: How would you verify in simulation that `stretch_seen` is actually being set correctly by the monitor?

**Answer**: Three complementary verification strategies. First, add a
`uvm_info` print in the monitor at the exact line where `stretch_seen` is set:
`\`uvm_info(get_type_name(), "stretch_seen set on item", UVM_HIGH)` — when
running `clock_stretch_test`, you should see this message in the simulation
log. If you don't, the monitor's threshold is wrong or `scl_low_cnt` is not
counting correctly. Second, add a scoreboard check in `clock_stretch_test`'s
run_phase: after the sequence completes, drain the monitor's output port and
assert that at least one received item has `stretch_seen == 1'b1`. This turns
a coverage-model question into a self-checking test. Third, examine the
coverage report after simulation: if `stretch_seen_bin` is 0% after running
`clock_stretch_test`, the monitor is broken or the test is not actually
producing stretching. The combination of the `uvm_info` trace, the scoreboard
assertion, and the coverage report gives three independent signals — all three
should agree.

**KEY INSIGHT**: "The test passed" is not the same as "the monitor observed
what the test did." Always add at least one independently verifiable check
that the monitor's output matches the test's intent.

---

### Q19: How do you measure progress from 39 to 85 coverage points? What does that number actually represent?

**Answer**: The count of 39 (old) and 85 (new) refers to the total number of
coverage bins across all covergroups. Each individual `bins` declaration counts
as one point; each cell in a cross covergroup also counts as one point. For
example, `i2c_dir_ack_cross_cg` with 2 directions × 2 ACK states contributes
4 cells = 4 coverage points. The growth from 39 to 85 comes from CG9 (2 bins),
CG10 (2 bins), CG11 (4 bins), CG12 (6 cross cells), CG13 (4 cross cells),
CG14 (4 cross cells), CG15 (10 cross cells), CG16 (4 cross cells) plus the
`ignore_bins` fix which removes a false positive but does not change the closed
count. To measure progress: (a) count bins in the source file for the "model
size" metric, (b) use a simulator's `vcover report` or equivalent for the "bins
closed" metric, (c) the ratio gives the closure percentage. Raw bin count is a
coverage MODEL quality metric; closure percentage is a verification PROGRESS
metric. Both are important and neither should be reported alone.

**KEY INSIGHT**: More coverage bins is NOT automatically better. Each bin must
be motivated by a specific bug class or spec requirement. "85 points" only has
meaning if you can explain what each group of bins is guarding against.

---

### Q20: If you were presenting this I2C DV project in a hiring interview, how would you describe the coverage model in 60 seconds?

**Answer**: "The I2C verification environment uses a 16-covergroup functional
coverage model targeting approximately 85 coverage points. The model was built
iteratively: the first version had 8 covergroups covering the fundamental
protocol dimensions — direction, burst size, address range, ACK behavior, and
two cross combinations. After a systematic coverage-hole analysis, we identified
five measurement gaps: per-byte NACK tracking was never measured despite the
field existing in the data model for months, clock stretch detection had a test
but no coverage, and repeated-START chain depth was measured only as a binary
flag. We also identified five missing cross combinations that each catch a
specific class of direction-asymmetric bugs. We implemented all five new
covergroups plus all five crosses, growing the model from 39 to 85 points. Two
gaps were deliberately deferred: arbitration-lost coverage requires a second
master BFM which is an architectural change, and deep rep-start chains need a
new test sequence. Both are documented in the closure report. The key lesson
from this project is that coverage gaps often live in data that already exists
in the design — the problem is not missing stimulus but missing measurement."

**KEY INSIGHT**: In an interview, coverage discussion has three parts: (1) what
you measured and why, (2) what holes you found and how you found them, (3) what
you did about the holes and what you deliberately deferred. An interviewer who
hears all three parts knows you understand coverage as an engineering discipline,
not just a syntax exercise.

---

*End of Section 7B — Coverage Model Expansion (CG9-CG16) Q&A*

---

## Section 7C — BUG #16, Deep Rep-START, and CG17

### Q21: Why did the original `valid_protocol_c` constraint block deep repeated-START sequences? How was it fixed?

**Answer**: The constraint in `i2c_seq_item.sv` contained the implication:

```systemverilog
stop_cond -> !rep_start
```

This reads as: "if `stop_cond` is 1, then `rep_start` must be 0." The intent
was to prevent a constraint contradiction where a transaction simultaneously
claims to end with STOP and to be a repeated-START continuation. On the
surface, that sounds reasonable — STOP and rep-START seem mutually exclusive.

But in a multi-segment repeated-START chain, the FINAL segment legitimately has
BOTH `rep_start=1` (it is a continuation segment — the bus transitioned from
the previous segment via a repeated-START rather than a full STOP) AND
`stop_cond=1` (it ends the entire chain with a proper STOP). The implication
`stop_cond -> !rep_start` incorrectly treated these two fields as mutually
exclusive in ALL segments, when in fact they are only mutually exclusive for
single-segment transactions.

The consequence: when `deep_rep_start_sequence` attempted to randomize segment
3 (rep_start=1, stop_cond=1), the solver failed with a constraint contradiction.
No final segment could be generated, so the deep chain could not be completed.

The fix was to simply remove that implication from `valid_protocol_c`. The two
fields are not mutually exclusive by the I2C protocol — they represent
orthogonal aspects of a segment's role in a chain. With the constraint removed,
`deep_rep_start_sequence` can randomize segment 3 (or any final segment) with
both flags set, and CG11's `deep_rep` bin can now be closed.

**Key insight**: Constraint implications that "seem" correct for simple cases
can be catastrophically wrong for edge cases. Always test your constraints by
trying to randomize the exact scenarios you care about. If `randomize()` fails,
the constraint model is the first suspect.

---

### Q22: Explain the `deep_rep_start_sequence` — why 4 segments, why `constraint_mode(0)`?

**Answer**: The `deep_rep_start_sequence` is designed to close all 4 bins of
CG11 (`i2c_rep_depth_cg`) in a single test run. The 4 bins map to chain depths
0, 1, 2, and 3+:

| Segment | `num_rep_starts` | `rep_start` | `stop_cond` | CG11 bin closed |
|---------|-----------------|-------------|-------------|-----------------|
| seg0: fresh START, write | 0 | 0 | 0 | `no_rep` |
| seg1: first rep-START, write | 1 | 1 | 0 | `one_rep` |
| seg2: second rep-START, write | 2 | 1 | 0 | `two_rep` |
| seg3: third rep-START, read, STOP | 3 | 1 | 1 | `deep_rep` |

Four segments because CG11 has four bins. Each segment contributes exactly one
bin — this is deliberate directed-test engineering, not happy-path randomness.

The reason for `constraint_mode(0)` on `default_trans_c` per segment: the
`default_trans_c` constraint in `i2c_seq_item.sv` hard-codes `start_cond=1`,
`stop_cond=1`, and `rep_start=0`. This matches the "simple single transaction"
pattern that most tests use. But for middle and final segments of a chain, you
need `stop_cond=0` (don't stop the chain) and `rep_start=1` (this is a
continuation). Those requirements directly conflict with `default_trans_c`.

The solution is `req.default_trans_c.constraint_mode(0)` before each
`randomize()`, then adding inline constraints to specify exactly what the
segment needs. This gives precise per-segment control without fighting the
defaults. You never permanently disable `default_trans_c` — you turn it off for
this one `randomize()` call, then the constraint is irrelevant because you have
overridden everything it would have set.

**Key insight**: `constraint_mode(0)` is the correct tool when you need to
break free from class-level constraints for a specific randomization. Leaving it
permanently off is a maintenance problem — future code that uses the sequence
would lose the safety net. Per-`randomize()` disable is the surgical approach.

---

### Q23: What gap does CG17 (stretch × direction cross) catch that CG10 alone couldn't?

**Answer**: CG10 (`i2c_stretch_cg`) has two bins: `no_stretch` and
`stretch_seen_bin`. When `clock_stretch_test` runs, `stretch_seen_bin` hits and
CG10 reports 100% closure. This tells you: "stretch was observed at least once."

What CG10 cannot tell you: whether stretch was observed during a READ direction
transaction. `clock_stretch_test` only exercises write transactions (the slave
stretches SCL while storing incoming write data). If a slave implementation has
direction-asymmetric stretch behavior — for example, a slave that holds SCL
during reads but the read-path stretch logic has a bug — that bug is completely
invisible to CG10. The `stretch_seen_bin` is already 100%. Nothing changes.

CG17 (`i2c_stretch_dir_cross_cg`) crosses stretch with direction, producing 4
cells: no_stretch×WRITE, no_stretch×READ, stretch×WRITE, stretch×READ. After
the existing regression, three cells close. The `stretch × READ` cell remains
open. That open cell is not a failure — it is an honest declaration that "we
have not tested stretch during a read transaction." The closure report now
surfaces this gap explicitly, which forces the team to either write a
`stretch_read_test` to close it or formally waive it with documented rationale.

The rule: CG10 answers "did stretch happen?" CG17 answers "did stretch happen
in BOTH directions?" Those are different engineering questions. A coverage model
that can only answer the first question but not the second is leaving a real
asymmetry bug class undetected.

---

*End of Section 7C — BUG #16, Deep Rep-START, and CG17 Q&A*

*Total document Q&A coverage: original 80+ questions plus Section 7's 10
enhancement questions plus Section 7B's 10 expansion questions plus Section 7C's
3 questions = 103+ questions across protocol, RTL, UVM, SVA, coverage,
methodology, trick questions, and enhancement-specific topics.*
*Files 01-08 together cover everything needed to own this project at a senior level.*
