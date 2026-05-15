# File 01 — I2C Protocol Deep Dive

## Part 1: Why I2C Exists

Before 1982, chips on a PCB communicated using parallel buses — many wires for many bits simultaneously. 
Philips (now NXP) invented I2C to solve a real problem: **how do you connect many chips using the fewest wires possible?**

Their answer: use 2 wires and a simple protocol. One wire for data (SDA), one for a clock (SCL).
Every chip that understands I2C can be connected to these 2 wires, regardless of manufacturer.

Today you use I2C everywhere:
- Temperature sensors (like LM75)
- EEPROM memory chips (like AT24C)
- Display controllers (like SSD1306 OLED)
- Accelerometers (like MPU-6050)
- Real-time clocks (like DS3231)

This project implements an I2C master and slave in hardware (RTL) and verifies it.

---

## Part 2: The Physical Layer — Open-Drain Wiring

### Why "Open-Drain"?

Normal digital outputs push HIGH (drive to VDD) or LOW (drive to GND). This creates a problem
when two devices share the same wire — if one drives HIGH and another drives LOW, you get a short circuit.

I2C solves this with **open-drain** outputs:
- A device can PULL DOWN (drive to GND)
- A device CANNOT push HIGH — it just releases the wire
- A pull-up resistor (typically 4.7 kΩ) passively pulls the wire HIGH when nobody drives it LOW

```
              VDD
               |
           [4.7kΩ]   <- pull-up resistor
               |
SDA ———————————+———————-> all devices connect here
               |          |          |
           Device A    Device B   Device C
          (open-drain)(open-drain)(open-drain)
```

### The Wired-AND Property

Because any device can pull the wire LOW:
- If ALL devices release: wire = HIGH (pull-up wins)
- If ANY device pulls low: wire = LOW

This is called **wired-AND**: result is HIGH only if ALL outputs are HIGH (released).

**In SystemVerilog, this is modeled with drive strengths:**
```systemverilog
// Pull-up (weakest — pull-up resistor)
assign (weak1, highz0) sda = 1'b1;

// Device driver (strong pull-down, weak release)
assign (strong0, weak1) sda = (sda_drv == 1'b0) ? 1'b0 : 1'bz;
```

When `sda_drv = 0`: strong0 drives SDA LOW — wins against weak1 pull-up. SDA = 0.
When `sda_drv = 1`: driver releases (1'bz), weak1 pull-up takes over. SDA = 1.

This is in `tb/i2c_if.sv` and it precisely models the physics of I2C.

---

## Part 3: The I2C Bus Protocol — Bit by Bit

### 3.1 Bus Idle State

When no transaction is happening:
- SDA = HIGH (released, pull-up wins)
- SCL = HIGH (released, pull-up wins)

Both wires high = bus is free.

### 3.2 START Condition

The master begins every transaction by generating a START:

```
     ______
SDA       |___________    <- SDA falls while SCL is HIGH
     ___________
SCL             |______   <- SCL then falls to begin clocking
```

**Rule: SDA falls WHILE SCL is HIGH.**

This is special because during normal data transfer, SDA must be STABLE when SCL is HIGH.
A falling SDA during SCL high is the START signal — it means "I'm about to start a transaction."

In `i2c_slave_controller.sv`:
```systemverilog
assign start_cond = (sda_i == 1'b0 && sda_d == 1'b1 && scl_i == 1'b1);
//                   SDA is LOW now  AND  was HIGH before  AND  SCL is still HIGH
```

`sda_d` is the registered (1-cycle delayed) version of SDA. So:
- `sda_d == 1'b1`: SDA WAS high last cycle
- `sda_i == 1'b0`: SDA IS low now
- `scl_i == 1'b1`: SCL is high

Together: SDA just fell while SCL was high = START detected.

### 3.3 Address Phase (7-bit addressing)

After START, the master sends 8 bits:
- Bits [7:1]: 7-bit slave address (MSB first)
- Bit [0]: Direction bit (0 = write, 1 = read)

```
SDA: [A6][A5][A4][A3][A2][A1][A0][R/W]
      ^                             ^
    MSB                            LSB
    sent first                    sent last
```

For our slave with address 7'h50 = 0101_000:
```
A6=0, A5=1, A4=0, A3=1, A2=0, A1=0, A0=0
```

So the address byte on the wire:
- Write: 0b0101_000_0 = 0xA0
- Read:  0b0101_000_1 = 0xA1

**Each bit is transmitted during one SCL cycle:**
```
SCL: __/^^^\__/^^^\__/^^^\...
SDA:   [A6]   [A5]   [A4]  ...
         ^
    Master drives SDA LOW while SCL is LOW
    SCL goes HIGH — slave samples SDA
    SCL goes LOW — master changes to next bit
```

**Critical rule: SDA changes while SCL is LOW. SDA is sampled while SCL is HIGH.**

### 3.4 ACK/NACK — The 9th Bit

After 8 data bits, there's a 9th clock pulse for acknowledgment.

- The SENDER releases SDA (stops driving)
- The RECEIVER drives SDA:
  - LOW = ACK (acknowledge — I received it correctly)
  - HIGH (released) = NACK (not acknowledged — something wrong)

For address phase: the slave ACKs if it recognizes its own address.
For data phase: the slave ACKs each byte it receives (unless force_data_nack).

```
SCL:  __/^^^\__  <- 9th clock pulse
SDA:  <————>    <- slave drives LOW for ACK
      (ACK)
```

In the master RTL:
```systemverilog
STATE_ACK_WAIT: sda_o <= 1'b1;  // Master releases SDA
                                  // Slave must drive LOW for ACK
```

Then the master samples:
```systemverilog
if (state == STATE_ACK_WAIT && scl_rise) begin
    ack_received <= (sda_i == 1'b0); // 0 = ACK, 1 = NACK
end
```

### 3.5 Data Phase

After address + ACK, data bytes follow. Each byte is 8 bits + 1 ACK/NACK.

**Write transaction (master->slave):**
```
Master sends data byte, slave drives ACK after each byte.
```

**Read transaction (slave->master):**
```
Master releases SDA, slave drives data bits.
After each byte, master drives ACK (to request more) or NACK (last byte).
```

### 3.6 STOP Condition

```
         ___________
SDA  ___|            <- SDA RISES while SCL is HIGH
     ___________
SCL             ^^^  <- SCL is HIGH throughout
```

**Rule: SDA rises WHILE SCL is HIGH.**

This is the mirror of START. After STOP, both SDA and SCL are HIGH -> bus is free.

In `i2c_slave_controller.sv`:
```systemverilog
assign stop_cond = (sda_i == 1'b1 && sda_d == 1'b0 && scl_i == 1'b1);
//                  SDA is HIGH now  AND  was LOW before  AND  SCL is HIGH
```

### 3.7 Repeated START

Instead of STOP followed by START (releasing the bus), a master can issue a 
**Repeated START (Sr)** to change direction (write->read) without releasing the bus:

```
[START][ADDR+W][ACK][DATA][...] [Sr][ADDR+R][ACK][DATA]...[NACK][STOP]
                                 ^
                         No STOP here — bus not released
                         Another master can't steal the bus between these
```

This is useful for:
- Read-after-write to the same slave without interruption
- Direction change (write register address, then read data)

### 3.8 Clock Stretching

The slave can HOLD SCL LOW to pause the master. How?

Since SCL is open-drain: even if the master releases SCL (wants to go high),
the slave can keep driving SCL low. The master samples SCL and sees it's still LOW —
it waits.

```
Master: releases SCL (wants HIGH)  -> SCL stays LOW (slave is stretching)
Master: waits...                   -> SCL still LOW
Slave: finishes processing         -> slave releases SCL
SCL goes HIGH                      -> master continues
```

This is used when the slave needs more time to process data (e.g., an ADC completing a conversion).

In our slave: `scl_o` drives SCL when `stretch_active` is high:
```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          scl_o <= 1'b1;  // release
    else if (stretch_active) scl_o <= 1'b0;  // hold SCL low
    else                 scl_o <= 1'b1;  // release
end
```

---

## Part 4: Complete Transaction Waveform

### Write Transaction: Master writes 0xA5 to slave 0x50

```
Bit:    S  A6 A5 A4 A3 A2 A1 A0 R/W ACK D7 D6 D5 D4 D3 D2 D1 D0 ACK  P
SDA:    v  0  1  0  1  0  0  0  0   v   1  0  1  0  0  1  0  1   v   ^
SCL:    ^  _^ _^ _^ _^ _^ _^ _^ _^   _^  _^ _^ _^ _^ _^ _^ _^ _^   _^ ^

S = START (SDA falls, SCL high)
Addr byte = 0b01010000 = 0xA0 (address 0x50, write)
ACK = slave drives SDA LOW
Data byte = 0b10100101 = 0xA5
ACK = slave drives SDA LOW
P = STOP (SDA rises, SCL high)
```

### Read Transaction: Master reads 1 byte from slave 0x50

```
Bit:    S  A6 A5 A4 A3 A2 A1 A0 R/W ACK D7 D6 D5 D4 D3 D2 D1 D0 NAK  P
SDA:    v  0  1  0  1  0  0  0  1   v   (slave drives data bits)   ^   ^
SCL:    ^  _^ _^ _^ _^ _^ _^ _^ _^   _^  _^ _^ _^ _^ _^ _^ _^ _^   _^ ^

Note: R/W = 1 (read)
ACK = slave ACKs its own address
Data = slave drives SDA, master clocks
NACK = master drives HIGH (last byte, no more needed)
STOP = master ends transaction
```

---

## Part 5: Timing Parameters and Why They Matter

All timing values are in the `i2c_pkg.sv`:

```systemverilog
parameter int CLK_FREQ_MHZ  = 50;    // System clock
parameter int T_SCL_PERIOD  = 500;   // 10us SCL period -> 100kHz
parameter int T_SCL_HIGH    = 250;   // SCL high time (5us)
parameter int T_SCL_LOW     = 250;   // SCL low time (5us)
parameter int T_SU_STA      = 10;    // START setup time (0.2us)
parameter int T_HD_STA      = 10;    // START hold time (0.2us)
parameter int T_SU_STO      = 10;    // STOP setup time (0.2us)
parameter int T_HD_DAT      = 5;     // Data hold time (0.1us)
parameter int T_SU_DAT      = 5;     // Data setup time (0.1us)
parameter int T_BUF         = 20;    // Bus free time (0.4us)
parameter int MAX_CLK_STRETCH = 1000; // Max stretch (20us)
```

**Why do these matter?**

- `T_HD_STA`: After SDA falls (START), SCL must stay HIGH for at least this long before falling.
  If SCL falls too soon, some slow devices might not detect the START.

- `T_SU_DAT`: SDA must be stable for this many cycles BEFORE SCL rises.
  If SDA changes too close to SCL rising, the slave might sample the wrong value (setup violation).

- `T_HD_DAT`: After SCL falls, SDA must hold for this long before changing.
  If SDA changes too soon after SCL falls, slow devices might see the old bit (hold violation).

- `T_BUF`: After STOP, no new START for at least this long. Bus needs time to recover.

---

## Part 6: I2C Standard Mode vs Other Modes

| Mode | Max Speed | Note |
|------|-----------|------|
| Standard Mode | 100 kHz | Our implementation |
| Fast Mode | 400 kHz | T_SCL_HIGH/LOW ratios differ |
| Fast-Plus | 1 MHz | Needs stronger pull-ups |
| High-Speed | 3.4 MHz | Special handshake required |
| Ultra-Fast | 5 MHz | Unidirectional only |

Our design uses Standard Mode (100 kHz). The timing parameters in i2c_pkg.sv are
calibrated for this mode with a 50 MHz system clock.

---

## Part 7: What Can Go Wrong — Protocol Violations

Understanding violations helps you understand what assertions catch:

| Violation | Description | Caught by |
|-----------|-------------|-----------|
| SDA changes while SCL HIGH | During data phase | A3 assertion |
| No ACK after address | Slave not present | Scoreboard addr_ack check |
| Clock stuck LOW | Slave crash or pullup failure | A5 assertion (stretch bound) |
| X/Z on SDA or SCL | Multi-driver conflict | A6 assertion |
| No STOP after transaction | Master crash | Timeout |
| Premature START (no T_BUF) | Bus not free | A2 assertion (fixed) |

---

## Interview Questions — I2C Protocol

**Q1: What is I2C? How many wires does it use?**
A: I2C (Inter-Integrated Circuit) is a 2-wire synchronous serial protocol.
SDA (Serial Data Line) and SCL (Serial Clock Line). The master generates SCL.
All devices share the same 2 wires. Addresses distinguish devices.

**Q2: What does "open-drain" mean and why does I2C use it?**
A: Open-drain means outputs can only pull the wire LOW, not push it HIGH.
A passive pull-up resistor provides the HIGH state. I2C uses this because:
(1) Multiple devices share one wire — no short circuit possible.
(2) Enables wired-AND for bus arbitration.
(3) Clock stretching — slave can hold SCL low to pause master.

**Q3: How is a START condition different from a data bit?**
A: During data transmission, SDA must NOT change while SCL is HIGH.
A START is specifically SDA falling while SCL is HIGH — a pattern that
cannot occur during normal data transmission. This makes START unambiguous.

**Q4: How does the slave know the transaction is for it?**
A: After START, the master sends 7-bit address + R/W bit. Each slave compares
this address to its own. If they match, the slave drives SDA LOW for ACK.
If no match, SDA stays HIGH (NACK — no device pulls it down).

**Q5: What is clock stretching and when would a slave use it?**
A: A slave holds SCL LOW to pause the master. Used when:
- ADC is mid-conversion and needs more time
- Slave is processing previous data and not ready for next byte
- Slave is performing a write to internal EEPROM

**Q6: What is a Repeated START and why use it instead of STOP+START?**
A: Repeated START (Sr) is a START without a preceding STOP. The master retains
bus control — another master cannot steal the bus. Used for:
- Write-then-read without bus release (common for register read: write address, Sr, read data)
- Atomic transactions where both write and read must not be interrupted

**Q7: What is the maximum number of devices on an I2C bus?**
A: With 7-bit addressing: 128 addresses, but 16 are reserved, so 112 usable.
The actual limit is also determined by bus capacitance (<=400 pF for Standard Mode).

**Q8: What does NACK mean in each context?**
A: 
- After address: no slave responded (wrong address, or slave crashed)
- After data byte during write: slave cannot accept more data (buffer full)
- After data byte during read: master telling slave "that was the last byte I want"

**Q9: How do you verify open-drain behavior in simulation?**
A: Using SystemVerilog drive strengths:
```systemverilog
assign (weak1, highz0) sda = 1'b1;              // pull-up
assign (strong0, weak1) sda = drv ? 1'bz : 1'b0; // driver
```
strong0 always wins against weak1. If driver releases (1'bz), weak1 pull-up wins.
The net result models real open-drain behavior.

**Q10: In Standard Mode at 50 MHz system clock, what timer value gives 100 kHz SCL?**
A: SCL period = 1/100kHz = 10us. System clock period = 1/50MHz = 20ns.
Timer count = 10us / 20ns = 500 cycles. T_SCL_PERIOD = 500.
HIGH and LOW each 250 cycles (5us each, meeting >=4us spec for Standard Mode).

---

## Part 8: I2C Bus Arbitration — When Two Masters Collide

### The Problem: Two Masters, One Bus

In a single-master I2C system, life is simple — only one device ever drives the bus,
so there is no conflict. But real systems often need multiple masters. Think of two
microcontrollers sharing the same sensor bus, or a DMA engine and a CPU both needing
to initiate transfers. What happens when both decide to start at exactly the same time?

On a traditional bus with push-pull drivers, two simultaneous transmitters would create
a short circuit — one driving HIGH, the other driving LOW, potentially damaging both chips.
I2C's open-drain topology makes this impossible to damage, and turns the collision into
a clean arbitration mechanism.

### The Wired-AND as an Arbitration Oracle

Recall the fundamental open-drain rule:
- Any device driving LOW: the wire goes LOW (strong0 wins).
- All devices released: the wire goes HIGH (weak1 pull-up).

Now consider two masters simultaneously driving SDA:

```
Master A wants to send bit = 1 (releases SDA, lets pull-up win)
Master B wants to send bit = 0 (drives SDA LOW with strong0)

Result on wire: LOW  (Master B's strong0 wins against pull-up)
```

Master A reads back SDA and sees it is LOW. But Master A drove it HIGH (released it).
The values are different. Master A knows it has **lost arbitration** — another master
is simultaneously driving a different pattern.

### Step-by-Step Arbitration Walkthrough

Here is the exact sequence of events when two masters collide:

```
         ___________________________________________
SCL  ___|  bit1  |  bit2  |  bit3  |  bit4  |

Master A SDA:  1      1      0      1      ...
Master B SDA:  1      1      0      0      ...

Wire SDA:      1      1      0      [!]
                                     ^
                              At bit 4: Master A drives 1 (releases)
                              Master B drives 0 (pulls LOW)
                              Wire = 0
                              Master A reads back 0, expected 1 -> LOST
```

**Detailed ASCII waveform for two masters colliding at bit 4:**

```
         _____   _____   _____   _____   _____
SCL  ___|     |_|     |_|     |_|     |_|     |_

         _______________________         _______
MSDA_A                          |_______|
(Master A SDA intent — HIGH on bit4)

         ________________________
MSDA_B                          |_______ ...
(Master B SDA intent — LOW on bit4)

         _______________________
Wire SDA                        |_______ ...
(Wire goes LOW — B wins, A loses)

                                ^
                                Master A sees mismatch here.
                                It stops driving. Backs off.
                                Master B does not even know A was there.
                                Master B's data is still valid on the bus.
```

### What the Losing Master Must Do

The moment a master detects arbitration loss (it drove HIGH but read back LOW), it must:

1. **Immediately stop driving SDA.** It must not pull down any more bits.
2. **Stop driving SCL.** It hands off clock control to the winning master.
3. **Assert STS_ARB_LOST** to notify the CPU or higher-level software.
4. **Wait for the bus to become free** (both SDA and SCL HIGH after STOP).
5. **Retry the transaction** after T_BUF has elapsed.

In `i2c_pkg.sv`, the arbitration-lost status is defined:
```systemverilog
STS_ARB_LOST = 3'b100,  // Arbitration lost (not used in single-master)
```

The comment says "not used in single-master" — our testbench only has one master,
so arbitration never fires. But the status enum is there for multi-master extensions.

### Why Arbitration is Lossless

The winning master (Master B in the example) never knew there was a collision.
Its data appears on the bus correctly. The arbitration process is completely
transparent to the winner — no data is corrupted, no resend is needed.

This works because:
- Both masters started at the same time (after detecting bus free).
- Both sent the same bits up to the point of divergence.
- The divergence point IS the arbitration: the master sending 0 wins,
  because 0 dominates on the wired-AND bus.

The winning master simply continues as if it were alone. The losing master
steps aside gracefully.

### Multi-Master Systems in Practice

Real systems using multi-master I2C include:
- **Embedded Linux SoCs**: CPU and DMA both accessing I2C peripherals.
- **Automotive ECUs**: Multiple ECUs sharing a body control bus.
- **Industrial systems**: Multiple controllers accessing shared sensor banks.

The I2C specification requires every master implementation to support arbitration.
In hardware, this is implemented by:
1. Comparing `sda_o` (what master wants to drive) with `sda_i` (what is on the wire).
2. If `sda_o = 1` (released) but `sda_i = 0` (bus pulled low): arbitration lost.
3. Transition to an ARB_LOST recovery state.

```systemverilog
// Typical arbitration detection in master RTL
always_ff @(posedge clk) begin
    if (state == STATE_TX_BIT && scl_rise) begin
        // We drove sda_o. Now read back what's on wire.
        if (sda_o == 1'b1 && sda_i == 1'b0) begin
            arb_lost <= 1'b1;  // We lost — another master is here
        end
    end
end
```

### Arbitration vs. Collision in Other Protocols

| Protocol | Multi-Master Handling |
|----------|-----------------------|
| I2C | Wired-AND arbitration — lossless, automatic |
| SPI | No arbitration — single master only |
| CAN | Similar wired-AND dominant/recessive scheme |
| Ethernet | CSMA/CD — detect collision, both back off randomly |
| USB | Token-based — host controls all transactions |

I2C's arbitration is deterministic (lower address wins more often, since lower addresses
have more 0 bits transmitted earlier). CAN uses a similar mechanism with explicit
priority fields.

---

## Part 9: I2C 10-bit Addressing

### Why 7-bit Addressing Is Not Always Enough

With 7 bits, you have 128 possible addresses. Remove the 16 reserved addresses
(0x00-0x07 and 0x78-0x7F) and you have 112 usable addresses. For a small embedded
system with 5-10 devices, 112 is more than enough.

But in a large industrial system — a factory floor with dozens of sensors, displays,
RTCs, and EEPROMs all on the same bus — 112 addresses can run out quickly.
I2C solves this with **10-bit addressing**, which expands the address space to 1024
usable addresses.

### The 10-bit Address Format

10-bit addressing uses a two-byte address field. The format is:

```
First byte:   1  1  1  1  0  A9 A8  R/W
              ^              ^  ^
              Reserved       Upper 2 bits of 10-bit address
              prefix 0b11110

Second byte:  A7 A6 A5 A4 A3 A2 A1 A0
              ^                      ^
              Bits [7:1] of address  Bit [0] of address
```

The prefix `0b11110xx` in bits [7:2] of the first byte is the reserved marker
that tells every device: "this is a 10-bit address frame, not a 7-bit one."

In `i2c_pkg.sv`, the reserved check:
```systemverilog
// 0000_XXX and 1111_XXX are reserved as per UM10204
return !((addr_byte[7:4] == 4'b0000) || (addr_byte[7:4] == 4'b1111));
```

The `1111` prefix is exactly the 10-bit address marker (11110xx in bits [7:1]).

### The Exact Byte Sequence on the Bus

For a 10-bit write transaction to address 0x2A5 (binary: 10_1010_0101):

```
A9 A8 = 10  (upper 2 bits)
A7..A0 = 1010_0101 = 0xA5  (lower 8 bits)

First byte:   1 1 1 1 0 1 0 0  = 0xF4  (prefix 11110 + A9=1 + A8=0 + R/W=0)
Second byte:  1 0 1 0 0 1 0 1  = 0xA5  (lower 8 bits of address)
Data bytes:   follow as normal
```

**Full bus sequence for a 10-bit write:**

```
[START] [0xF4] [SLAVE_ACK] [0xA5] [SLAVE_ACK] [DATA] [SLAVE_ACK] ... [STOP]
    ^       ^                  ^                   ^
  START  First addr byte    Second addr byte    Data starts
         (11110 A9 A8 W)    (A7..A0)
```

### How the Slave Recognizes a 10-bit Address

A 10-bit slave must:
1. Detect the START condition.
2. Receive the first address byte.
3. Check if bits [7:3] = `11110` (the 10-bit marker).
4. If yes, **ACK** and wait for the second address byte.
5. Receive the second address byte.
6. Concatenate both to form the full 10-bit address.
7. Compare to its own address. If match, ACK.

This requires two ACK cycles before data begins — one after each address byte.

### Backward Compatibility

10-bit and 7-bit devices can coexist on the same bus:
- 7-bit devices ignore frames where the first byte has prefix `11110` (they don't recognize their address).
- 10-bit devices only respond to their two-byte address sequence.
- A 7-bit device at address 0x78 would respond to `11110000` — this is why the
  I2C spec reserves `11110xx` — no 7-bit device should use addresses in the
  0x78-0x7F range for general use.

### 10-bit Read: The Repeated START Trick

For a 10-bit READ, the protocol requires a repeated START after the second address byte:

```
[START] [0xF4 WRITE] [ACK] [0xA5] [ACK] [Sr] [0xF5 READ] [ACK] [DATA] [NACK] [STOP]
                                          ^         ^
                                     Repeated    Same prefix but R/W=1
                                      START      (0xF5 = 11110 A9 A8 1)
```

The slave must remember the 10-bit address from the write phase and match it
again after the repeated START. Only the first byte is resent after Sr
(the 10-bit prefix byte with R/W=1) — the second address byte is not repeated.

---

## Part 10: The Open-Drain Model in Simulation — Deep Dive

### The Problem with Logic Simulation

In real hardware, the open-drain property is a physical reality — a transistor can only
pull a wire low, not push it high. In simulation (SystemVerilog), all signals are logic
types that can be driven to any value from any number of sources. Without careful modeling,
simulation will produce wrong results when multiple drivers are present.

The `tb/i2c_if.sv` file solves this using SystemVerilog's drive strength system.
Let us read the exact code and understand every line.

### The Exact Code from tb/i2c_if.sv

```systemverilog
// Model pull-up resistors (open-drain idle = HIGH)
assign (weak1, highz0) sda = 1'b1;
assign (weak1, highz0) scl = 1'b1;

// Strong0 pull-down, weak1 release (simulates open-drain)
assign (strong0, weak1) sda = (sda_drv == 1'b0) ? 1'b0 : 1'bz;
assign (strong0, weak1) scl = (scl_drv == 1'b0) ? 1'b0 : 1'bz;
```

There are two separate `assign` statements for each wire. They both drive the same
`wire sda`. In SystemVerilog, when multiple drivers compete on a `wire`, the simulator
uses the drive strengths to resolve who wins.

### Understanding `(weak1, highz0)`

Syntax: `assign (strength1, strength0) target = value;`
- `strength1` = drive strength when the assigned value is 1 (HIGH)
- `strength0` = drive strength when the assigned value is 0 (LOW)

For `assign (weak1, highz0) sda = 1'b1;`:
- The right-hand side is always `1'b1`.
- When this value is HIGH (1): drives with strength `weak1`.
- When this value is LOW (0): drives with strength `highz0`.
- But since the value is always `1'b1`, the LOW case (`highz0`) never applies.

**What is `highz0`?**

`highz0` means "high impedance when the value is 0." In other words: if this assign
tried to drive a 0, it would not actually drive anything — it would be high-impedance.
This is intentional here because `1'b1` never produces a 0. The `highz0` is a safety
net that says "I will never actively pull this wire low."

So this assign is: "Always weakly drive sda HIGH. Never pull it LOW at all."

This is exactly a pull-up resistor:
- It tries to hold the wire HIGH with weak strength.
- It never fights against anything that wants to pull the wire LOW.

### Understanding `(strong0, weak1)`

For `assign (strong0, weak1) sda = (sda_drv == 1'b0) ? 1'b0 : 1'bz;`:

When `sda_drv == 0` (driver wants to pull LOW):
- Right-hand side = `1'b0`
- Drive strength for 0 = `strong0`
- Effect: wire is driven LOW with strong strength

When `sda_drv == 1` (driver wants to release):
- Right-hand side = `1'bz` (high-impedance)
- When the value is Z, no driving occurs at all
- Effect: this assign contributes nothing to the wire

**What does `weak1` do then?** The `weak1` in `(strong0, weak1)` is the strength
used when the value is 1. But since the conditional either gives `1'b0` or `1'bz`
(never `1'b1`), the `weak1` strength is also never used from this driver. It is
specified for completeness in the strength tuple.

### Strength Resolution: The Three Key Cases

SystemVerilog has a defined strength hierarchy (from weakest to strongest):
`highz < small < medium < weak < large < pull < strong < supply`

**Case 1: Both `strong0` drivers assert (two devices pulling LOW)**

```
assign (weak1, highz0)  sda = 1'b1;       // pull-up: weak1
assign (strong0, weak1) sda = 1'b0;       // driver 1: strong0
assign (strong0, weak1) sda = 1'b0;       // driver 2: strong0
```

Result: When two `strong0` drivers both drive 0, the wire is 0 with `strong0` strength.
There is no contention — both want the same value (0). This is fine and models the
real hardware behavior: two devices can simultaneously pull the wire LOW without conflict.

**Case 2: `strong0` driver vs `weak1` pull-up**

```
assign (weak1, highz0)  sda = 1'b1;   // pull-up driving 1 with weak1
assign (strong0, weak1) sda = 1'b0;   // device driving 0 with strong0
```

The simulator compares `weak1` (from pull-up, wanting 1) vs `strong0` (from device, wanting 0).
`strong0 > weak1` in the strength hierarchy. The stronger driver wins.
Result: SDA = 0.

This precisely models the physics: a transistor pulling the wire to GND wins against
a resistor pulling it to VDD.

**Case 3: All devices release, only `weak1` pull-up remains**

```
assign (weak1, highz0)  sda = 1'b1;   // pull-up: weak1
assign (strong0, weak1) sda = 1'bz;   // device released (Z — no drive)
```

When the device drives `1'bz`, its assign contributes zero drive to the wire.
Only the pull-up remains, weakly driving HIGH.
Result: SDA = 1.

This is the idle state: nobody pulling down, pull-up wins, bus is HIGH.

### Why This Precisely Models Real Hardware

Real I2C hardware works like this:

| Hardware Component | Simulation Equivalent |
|--------------------|-----------------------|
| Physical pull-up resistor | `assign (weak1, highz0) sda = 1'b1` |
| Open-drain transistor ON (pulling LOW) | `assign (strong0, weak1) sda = 1'b0` |
| Open-drain transistor OFF (released) | `assign (strong0, weak1) sda = 1'bz` |
| Wire with multiple devices | SystemVerilog `wire` type (multi-driver resolution) |

The `wire` type (not `logic`, not `reg`) is essential. Only `wire` types undergo
multi-driver resolution. If you accidentally used `logic` or `reg` for `sda` or `scl`,
the last assignment would simply win — completely breaking the wired-AND model.

### What Happens with X/Z on the Wire

If any driver produces an unknown (X), it can contaminate the wire:
- `strong0 + strongX` = X (contention between real value and unknown)
- This causes assertion A6 to fire in the testbench

In a well-functioning simulation, SDA and SCL should never be X or Z (the pull-up
ensures at least weak1 = 1 when released). Seeing X/Z on SDA/SCL indicates a
multi-driver conflict (e.g., two devices both driving SDA to different values
with equal strength — a real short-circuit scenario).

---

## Part 11: I2C Transaction State Machine — The Big Picture

### The Bus-Level State Machine

This is not the master FSM or slave FSM — it is the bus-level state machine that
describes what is visible on the wire at any moment. Both master and slave must
track this state to know what is happening.

```
                    +-----------+
              ----->|   IDLE    |<-----
              |     | SDA=1     |     |
              |     | SCL=1     |     |
              |     +-----------+     |
              |           |          |
              |     (SDA falls,       |
              |      SCL high)        |
              |           v          |
              |     +-----------+    |
              |     |   START   |    |
              |     | SDA=0     |    |
              |     | SCL=1     |    |
              |     +-----------+    |
              |           |          |
              |     (SCL falls)       |
              |           v          |
              |     +-----------+    |
              |     |  ADDRESS  |    |
              |     | Master    |    |
              |     | drives SDA|    |
              |     | 8 bits    |    |
              |     +-----------+    |
              |           |          |
              |     (8th bit done,   |
              |      SCL falls)      |
              |           v          |
              |     +-----------+    |
              |     | ADDR_ACK  |    |
              |     | Slave     |    |
              |     | drives SDA|    |
              |     +-----------+    |
              |      /        \      |
              |  (ACK)       (NACK)  |
              |    |              \  |
              |    v               ->|
              |  +-----------+       |
              |  |   DATA    |       |
              |  | (W: master|       |
              |  |  drives)  |       |
              |  | (R: slave |       |
              |  |  drives)  |       |
              |  +-----------+       |
              |        |             |
              |  (8 bits done,       |
              |   SCL falls)         |
              |        v             |
              |  +-----------+       |
              |  | DATA_ACK  |       |
              |  | (W: slave |       |
              |  |  drives)  |       |
              |  | (R: master|       |
              |  |  drives)  |       |
              |  +-----------+       |
              |    /       \         |
              | (ACK)     (NACK)     |
              |   |           |      |
              |   |       (R: last   |
              |   |        byte, go  |
              |   |        to STOP)  |
              |   |           v      |
              | (more data)   |      |
              |   |     +-----------+|
              |   v     |   STOP    ||
              | (loop   | SDA rises ||
              |  back   | SCL high  ||
              |  to     +-----------+|
              |  DATA)         |    |
              |                -----+
              |
              |   [Repeated START path]
              |
              |     +-----------+
              ------|  Rep.START|
                    | SDA falls |
                    | SCL high  |
                    | (no STOP) |
                    +-----------+
                          |
                    (goes to ADDRESS)
```

### SDA and SCL Values in Each State

| Bus State | SCL | SDA | Who Drives SDA |
|-----------|-----|-----|----------------|
| IDLE | HIGH | HIGH | Nobody (pull-up) |
| START | HIGH -> LOW | HIGH -> LOW | Master (pulls SDA LOW first) |
| ADDRESS | Toggles | Data bits [7:0] | Master |
| ADDR_ACK (9th clk) | Toggles | LOW=ACK, HIGH=NACK | Slave (or nobody for NACK) |
| DATA (write) | Toggles | Data bits [7:0] | Master |
| DATA (read) | Toggles | Data bits [7:0] | Slave |
| DATA_ACK write | Toggles | LOW=ACK, HIGH=NACK | Slave |
| DATA_ACK read | Toggles | LOW=ACK(more), HIGH=NACK(last) | Master |
| Repeated START | HIGH | HIGH -> LOW | Master |
| STOP | HIGH | LOW -> HIGH | Master (releases SDA to rise) |

### Key Transitions Annotated

**IDLE -> START:**
- Master pulls SDA LOW while SCL is still HIGH.
- All slaves detect the start condition simultaneously.
- After T_HD_STA, master pulls SCL LOW to begin clocking.

**ADDRESS -> ADDR_ACK:**
- Master sends 8 bits (7-bit address + R/W).
- On the 9th SCL pulse, master releases SDA.
- Addressed slave pulls SDA LOW for ACK.
- Unaddressed slaves remain idle.

**DATA_ACK -> DATA (loop):**
- If ACK received (slave pulls LOW): master sends next byte (write) or
  slave sends next byte (read).
- If NACK received: transaction ends, master generates STOP.

**Any state -> Repeated START:**
- Master generates a START condition without a preceding STOP.
- SCL goes HIGH, SDA goes HIGH then LOW while SCL is HIGH.
- This resets the address phase without releasing bus ownership.

**DATA_ACK -> STOP:**
- For reads: master drives NACK (HIGH), then generates STOP.
- For writes: after final byte ACKed, master generates STOP.
- STOP: SCL HIGH, then SDA rises from LOW to HIGH.

---

## Part 12: Practical I2C — Real World Examples

### Example 1: Reading Temperature from LM75 Sensor

The LM75 is a classic I2C temperature sensor with address configurable via
pins A2, A1, A0 (giving addresses 0x48 through 0x4F).

**Scenario:** LM75 at address 0x48. Read the 2-byte temperature register (register 0x00).

**Step 1: Write the register pointer (tell LM75 which register to read)**
```
[START] [0x90 = 0x48<<1 | WRITE] [ACK] [0x00 = temp reg] [ACK] [STOP]
```

**Step 2: Read 2 bytes using Repeated START**
```
[START] [0x91 = 0x48<<1 | READ] [ACK] [MSB_data] [ACK] [LSB_data] [NACK] [STOP]
```

**The complete byte sequence on the wire:**

```
Cycle 1 (write pointer):
  SDA: START, 1,0,0,1,0,0,0,0 (0x90=write), ACK, 0,0,0,0,0,0,0,0 (0x00), ACK, STOP

Cycle 2 (read data):
  SDA: START, 1,0,0,1,0,0,0,1 (0x91=read), ACK,
       [MSB of temp, slave drives], ACK (master wants more),
       [LSB of temp, slave drives], NACK (master done), STOP
```

**Why Repeated START is used here:**

If the master did STOP between step 1 and step 2, another master could steal the bus
and write a different register pointer before the read. Using Repeated START ensures
the register pointer set in step 1 is definitely what step 2 reads.

**Temperature decoding:**

The LM75 returns a 16-bit value where:
- Bits [15:7] = 9-bit two's complement temperature
- Bits [6:0] = don't care
- Resolution: 0.5 degrees C per LSB of the 9-bit value

For +25.0 C: raw = 0x3200 = 0011_0010_0000_0000, upper 9 bits = 0_0110_010 = 50, 50 * 0.5 = 25.0 C.

### Example 2: Writing to EEPROM (AT24C02)

The AT24C02 is a 2-Kbit (256-byte) EEPROM at address 0x50 (our slave's default address).

**Scenario:** Write byte 0xAB to memory address 0x10.

**Write sequence:**
```
[START] [0xA0 = 0x50<<1 | WRITE] [ACK] [0x10 = mem addr] [ACK] [0xAB = data] [ACK] [STOP]
```

**Why EEPROM Needs ACK Polling After Write:**

After the STOP, the EEPROM begins an internal write cycle. During this time
(typically 5ms for AT24C02), the chip does NOT respond to I2C. It is busy
programming its Flash cells.

If the master tries to start a new transaction immediately, the EEPROM will NACK
its own address — it cannot respond while writing.

**ACK Polling procedure:**

```
Loop:
    [START] [0xA0 = write address] [wait for ACK]
    If NACK -> EEPROM still busy -> [STOP] -> retry
    If ACK  -> EEPROM is ready   -> proceed with next transaction
End loop
```

In Python pseudocode:
```python
i2c.write(0x50, [0x10, 0xAB])  # Write 0xAB to address 0x10

# ACK polling
while True:
    try:
        i2c.write_quick(0x50)  # Just send address, check ACK
        break                   # ACK received, EEPROM ready
    except OSError:
        pass                    # NACK, still busy — retry
```

**Clock Stretching During Write:**

Some EEPROMs use clock stretching instead of (or in addition to) ACK polling.
During an internal write cycle, when the master tries to clock the next transaction,
the EEPROM holds SCL LOW. The master waits (up to MAX_CLK_STRETCH cycles). When the
EEPROM finishes, it releases SCL and the transaction continues.

In our RTL, this is handled in the master:
```systemverilog
// Clock stretch detection (from i2c_master_controller.sv)
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stretch_cnt <= '0;
    end else if (scl_i == 1'b0 && state != STATE_IDLE) begin
        stretch_cnt <= stretch_cnt + 1'b1;  // Count cycles SCL is held low
    end else begin
        stretch_cnt <= '0;  // Reset when SCL released
    end
end
assign timeout = (stretch_cnt >= MAX_CLK_STRETCH);  // 1000 cycles = 20us
```

If the EEPROM holds SCL LOW for more than 20us (1000 cycles at 50 MHz), the master
declares a timeout and aborts the transaction.

### Example 3: Scanning the I2C Bus

A bus scan is the I2C equivalent of "ping" — try every possible address
and record which ones respond. This is how software detects what devices are connected.

**Algorithm:**
1. For each address from 0x08 to 0x77 (skipping reserved addresses):
2. Generate START.
3. Send address byte (7-bit address, write mode).
4. Check response:
   - ACK (SDA pulled LOW) = device found at this address.
   - NACK (SDA stays HIGH) = no device at this address.
5. Generate STOP.
6. Record and move to next address.

**Python pseudocode for bus scan:**
```python
import smbus2

bus = smbus2.SMBus(1)  # Use I2C bus 1 on Raspberry Pi
found_devices = []

print("Scanning I2C bus...")
for addr in range(0x08, 0x78):  # Skip reserved 0x00-0x07 and 0x78-0x7F
    try:
        bus.write_quick(addr)   # Send address + write bit, check ACK
        found_devices.append(addr)
        print(f"  Device found at address: 0x{addr:02X}")
    except OSError:
        pass  # NACK — no device at this address

print(f"\nScan complete. Found {len(found_devices)} device(s).")
bus.close()
```

**Example output:**
```
Scanning I2C bus...
  Device found at address: 0x48  (LM75 temperature sensor)
  Device found at address: 0x50  (AT24C02 EEPROM)
  Device found at address: 0x68  (DS3231 RTC)

Scan complete. Found 3 device(s).
```

**Hardware I2C Bus Scan with a Logic Analyzer:**

Looking at the waveforms, a bus scan generates a rapid sequence of:
```
[START][ADDR_0x08 WRITE][NACK][STOP]
[START][ADDR_0x09 WRITE][NACK][STOP]
...
[START][ADDR_0x48 WRITE][ACK][STOP]   <- device found
...
```

Each attempt takes approximately 9 SCL cycles (8 address + 1 ACK). At 100 kHz,
scanning all 112 addresses takes about 112 * 9 / 100,000 = ~10ms. That is why
bus scans are only done at startup, not during normal operation.

---

## Part 13: Common I2C Bugs and How They Manifest

### Overview

I2C bugs can be surprisingly difficult to debug because the symptoms (wrong data,
hanging software, missing interrupts) often look unrelated to the root cause.
This table summarizes the most common failure modes and their signatures.

| Bug | Root Cause | Symptom | Recovery |
|-----|-----------|---------|----------|
| SCL stuck LOW | Slave crash, broken pull-up | Master times out | Power cycle or 9-clock recovery |
| SDA stuck LOW | Bus contention, mid-transaction | Bus appears busy forever | 9-clock recovery |
| Missing ACK | Wrong address, device absent | Master NACK, transaction aborted | Verify address, check device power |
| Corrupted data | SDA changed while SCL HIGH | Wrong register values, CRC fail | Check signal integrity, reduce speed |
| Bus lockup | Slave frozen mid-byte | No transactions succeed | 9-clock recovery |
| Clock stretch timeout | Slave too slow | Master aborts, timeout error | Increase MAX_CLK_STRETCH |

### Bug 1: SCL Stuck LOW

**What causes it:**
- A slave crashes mid-transaction and leaves its SCL driver asserted.
- A broken or missing pull-up resistor — SCL cannot rise even when released.
- A physical short circuit between SCL and GND on the PCB.

**Symptom:**
The master releases SCL (wants to go HIGH for next transaction), but SCL stays LOW.
The master's clock stretch counter increments until it hits MAX_CLK_STRETCH.
In our RTL:
```systemverilog
assign timeout = (stretch_cnt >= MAX_CLK_STRETCH);  // 1000 cycles
// When timeout fires:
if (timeout) bus_error <= 1'b1;  // bus_error output goes HIGH
```
The CPU receives a bus_error interrupt and the master transitions to STATE_IDLE.

**Recovery:**
SCL stuck LOW cannot be fixed with software alone if the cause is hardware.
A pull-up failure requires hardware repair. A crashed slave may recover after
a power cycle.

### Bug 2: SDA Stuck LOW

**What causes it:**
- A slave was receiving bytes and the master reset mid-transaction.
- The slave is waiting to send more data bits (its open-drain driver is asserted).
- The master has no context for this — it reset and thinks the bus is idle.
- But SDA is LOW (slave is still driving), so every START attempt appears to be
  a collision or the bus looks busy.

**Symptom:**
After master reset, the master checks if bus is free: `wait (sda == 1 && scl == 1)`.
But SDA is stuck LOW. The master waits forever. Software hangs.

**The 9-Clock Recovery Procedure:**

This is the standard I2C recovery defined in the specification (UM10204 section 3.1.16):

1. Generate up to 9 SCL clock pulses.
2. After each clock, check if SDA is HIGH.
3. If SDA goes HIGH before 9 clocks: slave released. Recovery done.
4. After 9 clocks: generate a STOP condition (SCL HIGH, SDA rises).
5. If SDA is still stuck: hardware problem, power cycle required.

Why 9 clocks? Because the longest stuck state is a slave frozen while receiving
the last bit of a byte (8 bits) and the ACK (1 bit) = 9 clock positions maximum.
After 9 clocks, the slave has shifted out all queued bits and should release SDA.

**SystemVerilog model of 9-clock recovery:**
```systemverilog
// 9-clock recovery sequence
task automatic recover_bus();
    int clocks_sent;
    
    scl_drv = 1'b1;  // Release SCL
    sda_drv = 1'b1;  // Release SDA
    
    for (clocks_sent = 0; clocks_sent < 9; clocks_sent++) begin
        if (sda === 1'b1) break;  // SDA released — done
        
        // Clock one pulse
        scl_drv = 1'b0;  // SCL LOW
        repeat(T_SCL_LOW) @(posedge clk);
        scl_drv = 1'b1;  // SCL HIGH
        repeat(T_SCL_HIGH) @(posedge clk);
    end
    
    // Generate STOP condition
    sda_drv = 1'b0;  // SDA LOW
    repeat(T_SU_STO) @(posedge clk);
    scl_drv = 1'b1;  // SCL HIGH
    repeat(T_HD_STA) @(posedge clk);
    sda_drv = 1'b1;  // SDA rises = STOP
    repeat(T_BUF) @(posedge clk);
endtask
```

### Bug 3: Missing ACK

**What causes it:**
- Wrong address in the firmware (off by one: sent 0x51 instead of 0x50).
- Device not present on the bus (not soldered, wrong board revision).
- Device in reset or power-off state.
- Device busy and using NACK to signal "not ready."

**Symptom:**
After sending the address byte, SDA stays HIGH during the 9th clock pulse.
The master reads `ack_received = 0` and transitions to STOP (abort).
In our RTL: `nack <= ~ack_received;` goes HIGH.

**How to distinguish "wrong address" from "device absent":**
- Wrong address: changing the address in firmware fixes it.
- Device absent: bus scan finds no device, checking hardware reveals the issue.
- Device busy: retrying after a delay works; EEPROM ACK polling handles this.

### Bug 4: Corrupted Data

**What causes it:**
- SDA changes while SCL is HIGH (setup/hold violation).
- Excessive capacitance on the bus causes SDA transitions to be too slow.
- Electrical noise spikes during SCL high window.
- Two masters both driving SDA without proper arbitration.

**Symptom:**
Register reads return wrong values. CRC checks fail on multi-byte reads.
Sensors return impossible readings (temperature of 300 C, etc.).

**Timing violation specifics:**
- Setup violation (T_SU_DAT): SDA changed too close to SCL rising edge.
  Slave samples SDA mid-transition — may get wrong value.
- Hold violation (T_HD_DAT): SDA changed too soon after SCL fell.
  Slow slaves may still be sampling the previous bit.

In `i2c_pkg.sv`:
```
T_HD_DAT = 5   // 5 clock cycles = 100ns at 50 MHz
T_SU_DAT = 5   // 5 clock cycles = 100ns at 50 MHz
```
Standard Mode spec requires T_HD_DAT >= 0ns and T_SU_DAT >= 250ns.
Our 100ns at 50 MHz system clock actually violates T_SU_DAT for marginal devices.
This is why real designs add margin and run timing simulations with slow corners.

### Bug 5: Bus Lockup and Recovery

**How lockup happens:**
1. Master starts sending a byte.
2. SCL or power glitch resets the master mid-byte.
3. Slave has received, say, 5 bits. It is waiting for 3 more bits + ACK window.
4. Master resets, thinks bus is idle. Tries to send START.
5. But slave is still holding SDA LOW (it shifted in a 0 data bit).
6. Master sees SDA LOW during START attempt — waits for bus free.
7. Bus free never comes. System hangs.

**Detection:**
```systemverilog
// In the testbench or firmware:
// If SDA or SCL has been continuously non-idle for > T_TIMEOUT:
if (sda_stuck_low_count > LOCKUP_THRESHOLD) begin
    trigger_9clock_recovery();
end
```

**Prevention:**
- Always use a hardware watchdog that triggers bus recovery on I2C timeout.
- I2C controllers on modern SoCs have built-in bus recovery logic.
- In firmware: use a timeout on every I2C call; never block indefinitely.

### Bug 6: Clock Stretching Timeout

**What causes it:**
- Slave needs more time than MAX_CLK_STRETCH allows.
- Misconfigured MAX_CLK_STRETCH too small for a slow device.
- Slave firmware is stuck in a loop while holding SCL LOW.

In `i2c_pkg.sv`: `MAX_CLK_STRETCH = 1000` cycles = 20us at 50 MHz.
Standard Mode spec allows slaves to stretch indefinitely — but that is not
practical. Most implementations add a configurable timeout.

**Fix:** Increase MAX_CLK_STRETCH or debug why the slave is slow.
In the RTL test:
```systemverilog
// Test: slave stretches for 900 cycles — should succeed (< 1000)
stretch_cycles = 900;

// Test: slave stretches for 1100 cycles — should timeout
stretch_cycles = 1100;
```

---

## Part 14: I2C vs SPI vs UART — When to Use Which

### Comparison Table

| Feature | I2C | SPI | UART |
|---------|-----|-----|------|
| Number of wires | 2 (SDA + SCL) | 4+ (MOSI, MISO, SCLK, CS per device) | 2 (TX + RX) |
| Max speed | 5 MHz (Ultra-Fast) | 50+ MHz | ~115200 bps (async) |
| Multi-device support | Yes (addressing) | Yes (separate CS per device) | No (point-to-point) |
| Multi-master support | Yes (arbitration) | No (single master) | N/A |
| Clock | Synchronous (SCL) | Synchronous (SCLK) | Asynchronous |
| Full-duplex | No (half-duplex, SDA shared) | Yes (MOSI + MISO simultaneous) | Yes |
| Hardware complexity | Medium (open-drain + ACK) | Low (simple shift registers) | Low |
| Protocol overhead | High (START + ACK per byte) | Low (just clock) | Medium (start/stop bits) |
| Bus capacitance limit | 400 pF (Standard Mode) | No spec limit | No spec limit |
| Flow control | Clock stretching | None (master controls all) | RTS/CTS (optional) |

### When to Choose I2C

Choose I2C when:
1. **Wire count matters.** Only 2 wires for any number of devices.
2. **Many low-speed sensors on one bus.** Adding more sensors = adding addresses, not wires.
3. **Multi-master needed.** I2C has arbitration built-in. SPI does not.
4. **Short distances.** I2C is for on-board communication (PCB traces or short cables).
5. **Standard peripherals.** Almost every sensor and memory chip has an I2C variant.

### When NOT to Choose I2C

Avoid I2C when:
1. **High speed needed.** SPI runs at 50+ MHz; I2C tops at 5 MHz.
2. **Full-duplex required.** SDA is shared — you cannot send and receive simultaneously.
3. **Bus capacitance is high.** Long cables or many devices degrade signal edges.
4. **Strict real-time latency.** Clock stretching allows slaves to delay the master unpredictably.
5. **Simple point-to-point.** UART is simpler for one-to-one communication.

### SPI Deep Dive for Comparison

SPI uses 4 wires for a single slave:
- SCLK: clock (master drives)
- MOSI: Master Out Slave In (master to slave data)
- MISO: Master In Slave Out (slave to master data)
- CS: Chip Select (active low, one per slave)

For N slaves: 3 + N wires (or more with clock + data sharing).

SPI is faster because:
- No addressing overhead (CS line selects the device).
- No ACK bit (no handshake).
- Full-duplex (MOSI and MISO active simultaneously).
- No open-drain overhead (push-pull drivers at full speed).

But SPI scales badly: 10 devices = 13 wires minimum. I2C: still just 2 wires.

### UART Deep Dive for Comparison

UART is asynchronous — no shared clock. Each device has its own clock, and
both sides must be configured to the same baud rate in advance.

UART uses:
- TX pin (transmit) -> connected to other device's RX
- RX pin (receive) <- connected to other device's TX

Start bit + 8 data bits + optional parity + 1-2 stop bits per byte.

UART is good for:
- Debug consoles (JTAG/UART for printf-style debugging).
- GPS modules, Bluetooth modules, GSM modems.
- Long-distance communication (RS-232, RS-485 variants).

UART cannot do multi-device — you need multiple UART peripherals or a software
mux for each device.

---

## Part 15: Detailed Timing Diagrams — Every Edge Labeled

### Complete I2C Write Transaction Timing

The following diagram shows a complete write transaction with every timing parameter
labeled. Values are from `i2c_pkg.sv` with a 50 MHz system clock (1 clock = 20 ns).

```
TIMING PARAMETER REFERENCE (from i2c_pkg.sv, at 50 MHz):
  T_BUF         = 20 clocks = 400 ns   (bus free time)
  T_HD_STA      = 10 clocks = 200 ns   (START hold time)
  T_SU_STA      = 10 clocks = 200 ns   (repeated START setup time)
  T_SCL_LOW     = 250 clocks = 5000 ns (SCL low period)
  T_SCL_HIGH    = 250 clocks = 5000 ns (SCL high period)
  T_HD_DAT      = 5 clocks  = 100 ns   (data hold after SCL falls)
  T_SU_DAT      = 5 clocks  = 100 ns   (data setup before SCL rises)
  T_SU_STO      = 10 clocks = 200 ns   (STOP setup time)

----T_BUF------+
               |
        [BUS FREE — both SDA and SCL HIGH]
               |
SDA:  _________ \_______________________________________________
                  ^             (SDA falls = START)
SCL:  ___________/^^^^^^^^^^^^^^\_____/^^^^^^^^^^^^^^\_____
                 |<--T_HD_STA-->|     |<--T_SCL_HIGH->|
                                |<-T_SCL_LOW->|
                                              |<--T_SU_DAT-->|
```

**Full annotated waveform for writing 1 bit (bit 7 = 1, i.e., SDA HIGH):**

```
         T_BUF
  |<---------------->|
  |                  |
  |   IDLE           | START CONDITION
  |                  | SDA falls
SCL: ^^^^^^^^^^^^^^^^|^^^^^^^^\___________/^^^^^^^^^^^^^^^^^\_______
                               ^           ^
                               |T_HD_STA   |
SDA: ^^^^^^^^^^^^^^^^|_________|           |~~~~~~~~~~~~~~~~~~~~~~~~~~
                                <-T_HD_STA->
                                           ^
                                           SCL falls here to begin first bit
                                    |<---T_SCL_LOW--->|<--T_SCL_HIGH-->|
                                                      |<T_SU_DAT>|
                              SDA: ___________________|~~(stable)~|~~~~
                                   ^                              ^
                              SDA changes                   SCL rises here
                              after T_HD_DAT               slave samples SDA
                              from prev SCL fall

STOP CONDITION:
                         |<--T_SU_STO-->|
                  _______               |
SCL:         ___|       |^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
             (low)   (T_SU_STO)(SCL rises)
SDA:    _______________|____________________________________^^^^^^^^
                                                           ^
                                                     SDA rises = STOP
                                                     (while SCL is HIGH)
```

### Detailed Timing Table

Each timing parameter, its value in clock cycles and nanoseconds, the spec minimum
(Standard Mode from UM10204), and what violation looks like:

| Parameter | Symbol | Value (clks) | Value (ns) | Spec Min (ns) | Violation Symptom |
|-----------|--------|-------------|------------|---------------|-------------------|
| Bus free time | T_BUF | 20 | 400 | 4700 | Bus lockup, START during busy |
| START hold | T_HD_STA | 10 | 200 | 4000 | Missed START detection in slow slaves |
| START setup (Sr) | T_SU_STA | 10 | 200 | 4700 | Repeated START not detected |
| SCL low period | T_SCL_LOW | 250 | 5000 | 4700 | Slave cannot sample SDA |
| SCL high period | T_SCL_HIGH | 250 | 5000 | 4000 | Data changes seen on bus |
| Data hold | T_HD_DAT | 5 | 100 | 0 | Hold violation (marginal) |
| Data setup | T_SU_DAT | 5 | 100 | 250 | Setup violation — wrong bit sampled |
| STOP setup | T_SU_STO | 10 | 200 | 4000 | STOP not recognized by slow devices |

**Important note on T_BUF and T_SU_DAT:**

Looking at the table, our T_BUF = 400 ns but the spec requires 4700 ns. And
T_SU_DAT = 100 ns but spec requires 250 ns. This means our design is technically
violating Standard Mode timing for very strict devices. This is a common situation
in FPGA prototyping — the internal simulation passes, but real hardware may fail
with marginal devices.

In a real project, you would:
1. Increase T_BUF and T_SU_DAT in `i2c_pkg.sv` to meet spec.
2. Add timing assertions that check these minimums.
3. Run STA (Static Timing Analysis) to verify no setup/hold violations in the FPGA.

### Annotated Waveform: Complete Write of One Byte

```
[START] [bit7=1] [bit6=0] [bit5=1] [bit4=0] [bit3=0] [bit2=1] [bit1=0] [bit0=1] [ACK] [STOP]
  SDA: 0xA5 = 1010_0101

Time:  0          10         20         30         40         50        60         70        80   (x10 clocks)

SCL:   ^^^\_______/^^^^^^^^^\_________/^^^^^^^^^\_________/^^^^^^^^^\_________/^^^^^^^^^\_________
                  ^bit7              ^bit6              ^bit5              ^bit4
                  sampled            sampled            sampled            sampled

SDA:   ___(A5[7]=1)____(A5[6]=0)____(A5[5]=1)____(A5[4]=0)____...

       |<T_HD_STA>|     |<T_SU_DAT>|     |
                   |<-T_SCL_LOW->|<-T_SCL_HIGH->|
```

For the ACK bit (9th clock pulse):

```
SCL:   ___/^^^^^^^^^\_______/^^^^^^^^^\_______
            ^                              ^
     8th bit sampled                ACK sampled here
     Master finishes transmitting   Master releases SDA (sda_o = 1)
                                    Slave pulls SDA LOW for ACK
                                    Master reads SDA = 0 = ACK
```

---

## Part 16: Interview Questions — Extended Set (20 More Questions)

**Q11: What happens when two I2C masters start a transaction simultaneously?**

A: Bus arbitration occurs automatically via the wired-AND property.
When both masters simultaneously drive SDA, the wire goes to the dominant (LOW) value.
The master driving HIGH (releasing SDA) reads back LOW — it detects it lost arbitration.
The losing master immediately stops driving, waits for the bus to become free, then retries.
The winning master's transaction completes normally — it never knew the collision happened.
Arbitration is lossless: the winning data is valid and uncorrupted on the bus.

**Q12: Why does the losing master in arbitration detect the loss?**

A: The master monitors SDA continuously while driving it. When it drives SDA HIGH
(releases) but reads back LOW, there is a mismatch. This cannot happen unless
another device is driving LOW. The mismatch is the arbitration-lost signal.
The rule: "if I released SDA but it is LOW, someone else is pulling it down — I lost."
This is exactly what the RTL checks:
```systemverilog
if (sda_o == 1'b1 && sda_i == 1'b0) begin
    arb_lost <= 1'b1;  // Drove HIGH, read back LOW — arbitration lost
end
```

**Q13: Explain the 10-bit I2C addressing format completely.**

A: 10-bit addressing sends the address in two bytes:
- First byte: `1 1 1 1 0 A9 A8 R/W` — the `11110` prefix signals 10-bit mode.
- Second byte: `A7 A6 A5 A4 A3 A2 A1 A0` — the lower 8 bits of the address.
- Both bytes require ACK from the slave.
- For reads: a repeated START is sent after the second address byte, followed by
  the first byte again but with R/W=1.
- 7-bit devices with addresses 0x00-0x07 and 0x78-0x7F are reserved.
- The `1111` prefix in the first byte is why those addresses are reserved.

**Q14: Why is the 10-bit address prefix `11110` and not something else?**

A: The I2C specification specifically reserved addresses where the upper 4 bits are
`1111` for future extensions. The 5-bit prefix `11110` (with the upper nibble being
`1111`) was chosen for 10-bit addressing. It was available (not used by any 7-bit device)
and unambiguous — no 7-bit device should ever have an address in the 0x78-0x7F range.
The `x` in `11110xx` are the upper two bits of the 10-bit address, and the final bit
is R/W.

**Q15: Describe the 9-clock recovery procedure step by step.**

A: The 9-clock recovery is a standard way to recover an I2C bus where a slave is
stuck mid-byte holding SDA LOW.

Steps:
1. Assert SCL LOW, then HIGH for one cycle. Check SDA.
2. Repeat up to 9 times.
3. After each clock, if SDA goes HIGH — the slave released — recovery done.
4. After 9 clocks, generate a STOP condition (SCL HIGH, SDA rises from LOW to HIGH).
5. If SDA is still LOW after 9 clocks + STOP: hardware failure, power cycle required.

Why 9 clocks? Because the worst case is the slave froze while waiting for its 8th
data bit and the 9th ACK bit — at most 9 positions remain in the shift register.
Clocking 9 SCL pulses flushes the slave's shift register completely.

**Q16: What are the trade-offs between I2C and SPI?**

A:
- **I2C wins**: wire count (always 2 wires), multi-device (addressing), multi-master,
  low pin count for microcontrollers with many peripherals.
- **SPI wins**: speed (10-100x faster), full-duplex (simultaneous TX + RX), simpler
  protocol (no ACK, no addressing), no bus capacitance constraint.
- **I2C weaknesses**: half-duplex, clock stretching can cause unpredictable latency,
  400pF bus capacitance limit, ACK overhead adds latency per byte.
- **SPI weaknesses**: scales badly (N devices = N+3 wires), no flow control,
  no arbitration, no standard for multi-master.

Choose I2C for sensor networks with many devices. Choose SPI for high-speed flash
memory, displays, or ADCs where throughput matters.

**Q17: What are the symptoms of a T_SU_DAT (data setup time) violation?**

A: T_SU_DAT is the time SDA must be stable BEFORE SCL rises. If violated:
- SDA is still transitioning when SCL rises.
- The slave's flip-flop samples the signal mid-transition.
- It may capture a 0 instead of 1, or vice versa — a bit error.
- The received byte is corrupted: some bits are wrong.
- Symptoms: wrong register values, CRC failures, sensors returning garbage data.
- The corruption is non-deterministic — it may depend on temperature, voltage,
  and rise/fall times of SDA (which depend on bus capacitance).

**Q18: What is the symptom of a T_HD_DAT (data hold time) violation?**

A: T_HD_DAT is the time SDA must hold its value AFTER SCL falls. If violated:
- SDA changes before slow slaves have completed sampling.
- Slow slaves (with long clock-to-Q times) may sample the NEW bit instead of the OLD bit.
- Again results in corrupted data.
- Since Standard Mode requires T_HD_DAT >= 0ns, our 100ns implementation
  technically meets spec — but with very little margin for slow devices.
- Real designs add 300-500ns of hold time for safety.

**Q19: How do you model open-drain bus arbitration using SystemVerilog drive strengths?**

A: The interface models open-drain with two assigns on each wire:
```systemverilog
// Pull-up resistor: weak HIGH, never pulls LOW
assign (weak1, highz0) sda = 1'b1;

// Open-drain driver: strong LOW when asserted, Z when released
assign (strong0, weak1) sda = (sda_drv == 1'b0) ? 1'b0 : 1'bz;
```
When driver pulls LOW: `strong0` wins over `weak1` pull-up. SDA = 0.
When driver releases: `1'bz` contributes nothing. Only `weak1` pull-up remains. SDA = 1.
When two drivers both pull LOW: both contribute `strong0`. SDA = 0. No conflict.
When one releases and another drives LOW: same as single driver. SDA = 0.
The wired-AND behavior emerges naturally from strength resolution.

**Q20: How does a slave implement clock stretching in hardware?**

A: Clock stretching exploits the open-drain property of SCL:
1. The slave monitors SCL. When it needs more time, it actively drives SCL LOW.
2. The slave sets `scl_o = 0`, which drives the open-drain SCL line LOW via:
   `assign scl = (scl_o == 1'b0) ? 1'b0 : 1'bz;`
3. The master releases SCL (wants it to go HIGH), but the slave's `strong0` driver
   wins — SCL stays LOW.
4. The master's stretch counter increments: `stretch_cnt <= stretch_cnt + 1`.
5. When the slave finishes processing, it releases SCL: `scl_o = 1` (releases to Z).
6. The master's pull-up + the master's SCL driver (also released) cause SCL to rise.
7. The master resumes normal operation.

**Q21: How do you detect that the I2C bus is locked up in firmware?**

A: Implement a timeout on every I2C operation:
1. Set a timer before every I2C call.
2. If the operation does not complete within T_TIMEOUT (e.g., 25ms), declare lockup.
3. Call the 9-clock recovery procedure.
4. Re-initialize the I2C controller (reset its state machine).
5. Try the operation again.

In hardware, use a watchdog counter that counts system clock cycles during an
I2C transaction. If the transaction duration exceeds a limit, trigger recovery.
The master in our RTL does this with `MAX_CLK_STRETCH` — but this only detects
clock stretching, not all lockup conditions. A full implementation would also
monitor SDA for stuck-LOW while SCL is being clocked by the master.

**Q22: What is the maximum I2C bus speed for a given bus capacitance?**

A: The relationship between bus speed and capacitance comes from the RC time constant.
The pull-up resistor and bus capacitance form an RC circuit:
```
Rise time ~= 0.8473 * R_pullup * C_bus
```
For Standard Mode, the rise time must be at most 1000ns.
For a 4.7kΩ pull-up and 400pF capacitance:
```
Rise time = 0.8473 * 4700 * 400e-12 = 1594 ns
```
This is too slow for Standard Mode! You would need a smaller pull-up (2.2kΩ).
The spec limits total capacitance to 400pF at Standard Mode. In practice:
- Standard Mode (100 kHz): up to ~400pF with 4.7kΩ
- Fast Mode (400 kHz): up to ~200pF requires ~1.2kΩ
- Fast-Plus (1 MHz): up to ~100pF requires ~400Ω
Higher speed = lower capacitance limit = shorter traces, fewer devices, or active
pull-up circuits.

**Q23: What are the reserved I2C addresses and why are they reserved?**

A: The I2C spec reserves specific address ranges for special purposes:

| Address | Use |
|---------|-----|
| 0x00 | General Call (broadcast to all slaves) |
| 0x01 | CBUS compatibility addresses |
| 0x02 | Reserved for future use |
| 0x03 | Reserved for future use |
| 0x04-0x07 | Reserved for future use (lower 0000 prefix) |
| 0x78-0x7B | 10-bit slave addressing (11110xx prefix) |
| 0x7C-0x7F | Reserved for future use (11111xx) |

The General Call address (0x00) deserves special mention: when the master sends
address 0x00, ALL slaves that support General Call will ACK and receive the
following data byte. This is used for simultaneously resetting or configuring
all devices on a bus.

In `i2c_pkg.sv`, the validity check:
```systemverilog
function automatic logic is_valid_addr(addr_byte_t addr_byte);
    // 0000_XXX and 1111_XXX are reserved as per UM10204
    return !((addr_byte[7:4] == 4'b0000) || (addr_byte[7:4] == 4'b1111));
endfunction
```

**Q24: What is the General Call address and how does it work?**

A: General Call uses address 0x00 (all zeros). When the master sends:
```
[START] [0x00 = general call] [ACK] [command byte] [ACK] [STOP]
```
All slaves that support General Call ACK simultaneously (wired-AND — if any ACKs, bus goes LOW).
The command byte specifies the action:
- 0x06: Reset all slaves
- 0x04: Write to slaves programmed address (used in manufacturing)
- Other values: device-specific

Not all slaves support General Call — most sensors and EEPROMs ignore it.
The master cannot tell which slaves responded, or how many. General Call is
primarily used in simple networks where all devices are the same type.

**Q25: Describe exactly what happens to the bus when a slave is powered off mid-transaction.**

A: If a slave powers off mid-transaction:
1. Its open-drain drivers go high-impedance (no longer driving).
2. If it was ACKing (driving SDA LOW), SDA suddenly rises to HIGH.
3. The master may interpret this as a NACK.
4. If it was receiving data, the master continues sending, gets a NACK from the
   (now absent) device, and aborts with a STOP.
5. If it was sending data (read transaction), SDA rises, master gets all-1 data,
   and eventually sends NACK+STOP.

The bus returns to idle state because the slave's open-drain drivers are no longer
asserted. Other slaves on the bus are unaffected. The master declares a NACK error
and the higher-level software must handle it (retry, log error, etc.).

**Q26: What is SMBus and how does it differ from I2C?**

A: SMBus (System Management Bus) is a subset of I2C, defined by Intel for use
in PC motherboards (connecting to batteries, temperature sensors, voltage regulators).

Key differences:
- **Timeout**: SMBus mandates timeouts. A slave must respond within 35ms.
  I2C has no mandatory timeout (clock stretching can be indefinite).
- **Speed**: SMBus specifies 10 kHz to 100 kHz. I2C supports 5 MHz.
- **Voltage**: SMBus uses 3.3V logic with defined noise margins.
- **Packet Error Checking**: SMBus optionally appends a CRC byte.
- **Address reserved**: SMBus reserves additional addresses (0x18-0x1F for ACPI).
- **Protocol layers**: SMBus defines higher-level commands (Read Byte, Write Word, etc.)
  on top of raw I2C byte transfers.

Most I2C devices work on SMBus at 100 kHz, but strict SMBus hosts may reject
I2C devices that use indefinite clock stretching or non-standard addresses.

**Q27: What does the `(weak1, highz0)` strength tuple mean precisely, and why is `highz0` chosen instead of `weak0`?**

A: The tuple `(strength_for_1, strength_for_0)` specifies separate drive strengths
for when the driven value is 1 versus 0.

For `assign (weak1, highz0) sda = 1'b1;`:
- The value is always `1'b1`.
- For the 1 value: drive strength is `weak1` — the weakest active drive.
- For the 0 value: drive strength is `highz0` — which means high-impedance when 0.

But since the value is always 1, the `highz0` part is never active. Why specify it?
Because the SystemVerilog syntax requires both strengths in the tuple. Choosing `highz0`
(instead of `weak0` or `strong0`) makes the intent explicit:
"This driver will NEVER pull the wire LOW." Even if a bug caused the assign to evaluate
to 0 (impossible here, but as a safety property), `highz0` would not drive the wire LOW
— it would go high-impedance instead. This is the right behavior for a pull-up resistor
model: a pull-up should never actively pull LOW under any circumstances.

Using `weak0` instead would be incorrect: it would mean "pull LOW with weak strength
if the value were 0" — which is not what a pull-up resistor does.

**Q28: If two `strong0` drivers both assert simultaneously on the same I2C wire, what happens in simulation?**

A: In SystemVerilog, when two drivers of equal strength drive the same value to a `wire`,
the result is that value with the same strength. There is no conflict.

```
Driver 1: strong0 driving 0
Driver 2: strong0 driving 0
Result: wire = 0 with strong0 strength
```

No X, no contention, no error. This is correct — in real hardware, two transistors
both pulling the wire to GND is not a problem (both transistors are in the same state).

If they drove different values:
```
Driver 1: strong0 driving 0
Driver 2: strong0 driving 1
Result: wire = X (contention — equal strength, different values)
```

This produces X in simulation and represents a real short circuit in hardware.
In a properly designed I2C system this should never happen, because:
- Open-drain drivers can only drive 0 (strong0) or release (Z).
- A properly modeled driver never drives strong1 (pushes HIGH).
- The pull-up uses weak1, which always loses to strong0.
So you can never get `strong0 vs strong1` on a well-modeled I2C bus.

**Q29: How does clock stretching affect the master's SCL generation logic?**

A: The master generates SCL by counting timer ticks. Without clock stretching, it toggles
SCL at fixed intervals (T_SCL_LOW and T_SCL_HIGH).

With clock stretching:
1. Master releases SCL (wants it to go HIGH).
2. Slave pulls SCL LOW using its open-drain driver.
3. The `scl_i` input to the master reads LOW (even though `scl_o` is released).
4. The master detects that SCL is not rising: it reads back LOW when it expected HIGH.
5. The master stalls — it does not advance its timer or state machine until SCL rises.

In `i2c_master_controller.sv`, the stretch counter:
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

If `scl_i` stays LOW for MAX_CLK_STRETCH = 1000 cycles (20us at 50 MHz), the master
declares a timeout and aborts. This prevents the system from hanging indefinitely if
a slave crashes while holding SCL LOW.

**Q30: A slave receives 8 data bits correctly. What is the exact sequence of events that causes the register bank to be updated?**

A: Walking through `i2c_slave_controller.sv`:

1. **SLV_RX state**: On each `scl_rise`, the shift register shifts in one bit:
   ```systemverilog
   shift_reg <= {shift_reg[6:0], sda_i};
   ```

2. **After bit 7 (8th SCL rise)**: `bit_cnt == 7` and `scl_rise` is true.
   The last data bit is latched:
   ```systemverilog
   latched_rx_byte <= {shift_reg[6:0], sda_i};
   ```
   (shift_reg has bits 6:0 from previous clocks, sda_i is the 8th bit.)

3. **After bit 8 SCL fall** (`bit_cnt == 8 && scl_fall`): FSM transitions to SLV_RX_ACK.

4. **SLV_RX_ACK state**: Slave drives SDA LOW (ACK). The register bank update fires:
   ```systemverilog
   if (state == SLV_RX_ACK && active_int && (rx_rw == 1'b0) && !rx_write_done) begin
       internal_regs[reg_ptr] <= latched_rx_byte;
       internal_updated[reg_ptr] <= 1'b1;
       rx_write_done <= 1'b1;
   end
   ```

5. The `rx_write_done` one-shot flag prevents the register from being written multiple
   times during the same ACK window.

6. The `internal_updated` strobe pulses HIGH for one cycle, signaling to external
   logic that the register at `reg_ptr` has new data.

7. The `reg_ptr` increments to point to the next register (one-shot guard prevents
   multiple increments).

This is Bug Fix #15 territory: getting the timing of the latch exactly right
(on `scl_rise` at `bit_cnt == 7`, not on the 9th clock) prevents the ACK bit from
being accidentally captured as part of the data byte.

---

## Appendix A: Quick Reference Card

### I2C Signal States

| SDA | SCL | Meaning |
|-----|-----|---------|
| HIGH | HIGH | Bus idle |
| HIGH->LOW | HIGH | START condition |
| LOW->HIGH | HIGH | STOP condition |
| Changing | LOW | Data being set up by transmitter |
| Stable | HIGH | Data being sampled by receiver |
| LOW (9th bit) | Toggling | ACK (receiver drives LOW) |
| HIGH (9th bit) | Toggling | NACK (nobody drives SDA) |

### Transaction Sequence Templates

**Write N bytes:**
```
[START][ADDR+W][S_ACK][DATA_0][S_ACK][DATA_1][S_ACK]...[DATA_N-1][S_ACK][STOP]
S_ACK = slave ACK
```

**Read N bytes:**
```
[START][ADDR+R][S_ACK][DATA_0][M_ACK]...[DATA_N-2][M_ACK][DATA_N-1][M_NACK][STOP]
S_ACK = slave ACK, M_ACK = master ACK, M_NACK = master NACK (last byte)
```

**Write-then-Read (Repeated START):**
```
[START][ADDR+W][S_ACK][REG_ADDR][S_ACK][Sr][ADDR+R][S_ACK][DATA_0][M_ACK]...[DATA_N-1][M_NACK][STOP]
Sr = Repeated START
```

### Timing Quick Reference (50 MHz System Clock, Standard Mode)

| Parameter | Cycles | Time | Spec Min |
|-----------|--------|------|----------|
| T_BUF | 20 | 400 ns | 4700 ns |
| T_HD_STA | 10 | 200 ns | 4000 ns |
| T_SU_STA | 10 | 200 ns | 4700 ns |
| T_SCL_LOW | 250 | 5 us | 4700 ns |
| T_SCL_HIGH | 250 | 5 us | 4000 ns |
| T_HD_DAT | 5 | 100 ns | 0 ns |
| T_SU_DAT | 5 | 100 ns | 250 ns |
| T_SU_STO | 10 | 200 ns | 4000 ns |

### Address Byte Construction

```systemverilog
// From i2c_pkg.sv
function automatic addr_byte_t build_addr_byte(
    logic [6:0] addr,
    i2c_dir_e   dir
);
    return {addr, dir}; // {7-bit address, R/W bit}
endfunction

// Example:
addr_byte = build_addr_byte(7'h50, DIR_WRITE); // = 8'hA0
addr_byte = build_addr_byte(7'h50, DIR_READ);  // = 8'hA1
```

### State Machine States Summary

**Master FSM (i2c_master_controller.sv):**
```
STATE_IDLE -> STATE_START_1 -> STATE_START_2 -> STATE_TX_BIT -> STATE_ACK_WAIT -> STATE_IDLE
                                             -> STATE_RX_BIT -> STATE_ACK_SEND -> STATE_IDLE
STATE_IDLE -> STATE_STOP_1 -> STATE_STOP_2 -> STATE_IDLE
STATE_IDLE -> STATE_REP_START_1 -> STATE_REP_START_2 -> STATE_TX_BIT
```

**Slave FSM (i2c_slave_controller.sv):**
```
SLV_IDLE -> SLV_START -> SLV_ADDR -> SLV_ACK -> SLV_RX -> SLV_RX_ACK -> (loop or STOP)
                                              -> SLV_TX -> SLV_TX_ACK -> (loop or STOP)
Any state -> SLV_STRETCH -> (resume previous state)
Any state -> SLV_IDLE (on STOP condition)
```

### Common Commands from i2c_pkg.sv

| Command | Value | Effect |
|---------|-------|--------|
| CMD_NOP | 0x0 | No operation |
| CMD_START | 0x1 | Generate START condition |
| CMD_STOP | 0x2 | Generate STOP condition |
| CMD_WRITE | 0x3 | Write byte, wait for ACK/NACK |
| CMD_READ_ACK | 0x4 | Read byte, send ACK |
| CMD_READ_NACK | 0x5 | Read byte, send NACK (last byte) |
| CMD_REP_START | 0x6 | Generate Repeated START |
| CMD_ABORT | 0x7 | Abort and release bus |

---

## Appendix B: Glossary

**ACK**: Acknowledge. The receiver drives SDA LOW during the 9th SCL clock to
confirm successful receipt.

**Arbitration**: The process by which one master wins bus control when two masters
start simultaneously. The losing master backs off; the winner continues normally.

**Bus Capacitance**: Total capacitive load on SDA and SCL lines. Limits maximum
speed (higher cap = slower rise time = lower max frequency).

**Clock Stretching**: A slave holds SCL LOW to pause the master. Allows slow slaves
to control transaction pace.

**General Call**: Address 0x00. Broadcast to all slaves that support it.

**NACK**: Not Acknowledge. SDA stays HIGH during the 9th clock (nobody drives it LOW).
Meanings depend on context (wrong address, last byte, slave busy).

**Open-Drain**: Output type where the device can only pull LOW. HIGH state achieved
by releasing the wire to a passive pull-up resistor.

**Pull-up Resistor**: Passive resistor connected between SDA/SCL and VDD. Holds lines
HIGH when no device is driving LOW. Typical value: 4.7 kΩ for Standard Mode.

**Repeated START (Sr)**: A new START condition generated without a preceding STOP.
Keeps bus ownership for the initiating master.

**SDA**: Serial Data Line. Bidirectional, open-drain. Carries all data and address bits.

**SCL**: Serial Clock Line. Driven by the master (usually). Open-drain to allow clock
stretching by slaves.

**Standard Mode**: I2C operating at up to 100 kHz SCL frequency.

**Wired-AND**: The logical AND of all outputs appears on the wire. Achieved via
open-drain topology: any LOW output dominates.

**10-bit Addressing**: Extended addressing using a two-byte address field, allowing
1024 device addresses. First byte has prefix `11110`.
