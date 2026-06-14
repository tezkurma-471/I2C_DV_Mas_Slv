## Lesson 02 — `i2c_master.sv` + `i2c_slave.sv` Wrappers

**Files under study:**
- `rtl/i2c_master.sv` (57 lines, thin top-level wrapper, no parameters)
- `rtl/i2c_slave.sv` (65 lines, parameterized wrapper with TB-visibility hooks and fault-injection inputs)

**Concepts covered:** `inout wire` vs `output logic`, open-drain bus modeling, `1'bz` semantics, wire resolution rules, parameterized modules, mixed packed/unpacked arrays, verification-only ports (fault injection), named vs implicit port connections, internal-state visibility for DV, SV `bind`, hierarchical probes, the wrapper/controller hierarchy pattern.

**Date:** 2026-05-17
**Project:** I2C DV — 7-bit Standard Mode slave at 7'h50, single-master, 50 MHz system clock.

---

## Table of Contents

1. [Architecture — Where the Wrappers Fit](#1-architecture--where-the-wrappers-fit)
2. [60-Second Elevator Pitch](#2-60-second-elevator-pitch)
3. [The "Port-Isolation" Pattern — Why Two Wrappers Exist](#3-the-port-isolation-pattern--why-two-wrappers-exist)
4. [Deep Walkthrough — `i2c_master.sv`](#4-deep-walkthrough--i2c_mastersv)
5. [Deep Walkthrough — `i2c_slave.sv`](#5-deep-walkthrough--i2c_slavesv)
6. [Master vs Slave Wrapper Comparison Table](#6-master-vs-slave-wrapper-comparison-table)
7. [Quiz — 10 Questions](#7-quiz--10-questions)
8. [Quiz — Answers & Deep Explanations](#8-quiz--answers--deep-explanations)
9. [Key Takeaways](#9-key-takeaways)
10. [Action Items](#10-action-items)
11. [Honest Self-Score Template](#11-honest-self-score-template)

---

## 1. Architecture — Where the Wrappers Fit

Before line-by-line analysis, internalize where these two files live in the project. You cannot walk through a wrapper in an interview without first explaining the layering.

```
                      +-----------------------+
                      |     i2c_pkg.sv        |   <- shared vocabulary
                      |  (params, enums)      |       (Lesson 01)
                      +-----------------------+
                                 |
                 imported by both design & TB
                                 |
   +----------------------+              +-----------------------+
   |  i2c_master.sv       |              |  i2c_slave.sv         |
   |  (THIS LESSON)       |              |  (THIS LESSON)        |
   |  - top-level pins    |              |  - top-level pins     |
   |  - no params         |              |  - SLAVE_ADDR param   |
   |  - thin wrapper      |              |  - TB visibility hooks|
   +----------+-----------+              +-----------+-----------+
              |                                      |
              v                                      v
   +----------------------+              +-----------------------+
   | i2c_master_          |              | i2c_slave_            |
   |   controller.sv      |              |   controller.sv       |
   |  (FSM, the MEAT)     |              |  (FSM, the MEAT)      |
   |  ~20 KB              |              |  ~18 KB               |
   +----------+-----------+              +-----------+-----------+
              |                                      |
              |        scl (inout wire)              |
              +======================================+
              |        sda (inout wire)              |
              +======================================+
                         OPEN-DRAIN BUS
                  (pulled high by external Rp)
```

### What this picture is telling you

- The **wrappers** (this lesson) only re-export pins. They do not implement protocol logic.
- The **controllers** implement the I2C state machine. They are the actual chip.
- The **package** is shared vocabulary so RTL and TB agree on `CMD_START`, `T_SCL_PERIOD`, etc.
- The **bus** (`scl`, `sda`) is the only point where master and slave meet — and it is open-drain, which is why we must use `wire`, not `logic` (covered in detail below).

### Why this matters in interviews

When asked "what's the hierarchy of your project?" — most freshers say "I have a master module and a slave module." That is junior-grade. The senior framing is: *"I have a layered design — a thin wrapper at the top boundary that pins out the ports, and a controller core underneath that implements the FSM. The wrapper exists so the testbench can bind to a stable port list while the controller implementation can be swapped or refactored without breaking integration."*

---

## 2. 60-Second Elevator Pitch

When an NVIDIA/Qualcomm/Intel/AMD interviewer points at `i2c_master.sv` or `i2c_slave.sv` on a shared screen and says *"walk me through your wrapper modules,"* deliver this:

> *"These are thin top-level wrappers around the controller cores. `i2c_master.sv` exposes the CPU-side APB-like CSR interface, the open-drain bus pins, and a set of status outputs — `busy`, `done`, `ack`, `nack`, `timeout`, `bus_error`, `arb_lost`. It has no parameters because the master's timing comes from `i2c_pkg.sv`. `i2c_slave.sv` is parameterized by `SLAVE_ADDR` defaulting to 7'h50 so the same RTL can be instantiated for multiple slaves on the same bus. The slave wrapper additionally exposes verification-only ports — `force_data_nack`, `stretch_en`, `stretch_cycles` for fault injection, and `reg_bank`, `addr_match`, `rx_data_valid` as TB-visible internal state. The bus pins `scl` and `sda` are declared `inout wire` because I2C is open-drain — drivers can only pull low or release to high-Z, and the bus resolves to the wired-AND of all participants. In real silicon those visibility outputs would not exist at the pad ring — DV would use SV `bind` or hierarchical probes for the same observation."*

That is roughly 50 seconds at normal speaking pace. Memorize the **shape**, not the words.

---

## 3. The "Port-Isolation" Pattern — Why Two Wrappers Exist

You will be asked: *"Why do you have a wrapper AND a controller? Couldn't the controller just be the top?"*

The senior-engineer answer has four pillars.

### Pillar 1 — Pin stability across implementation refactors

Once a wrapper's port list is locked, the testbench, the SoC integration, the synthesis constraints (SDC), the floorplan, and the pad ring all wire up to it. If you change the **controller** internals — say, refactor the FSM, retime the data path, change variable names — none of that propagates to the wrapper's port list. The TB never needs to recompile.

If the FSM and the top were one module, every internal refactor would touch the SoC integration boundary. That is a non-starter at NVIDIA-scale, where dozens of teams integrate against a fixed port list.

### Pillar 2 — A clean place for pad-level concerns

The wrapper is where pad-related code lives in real silicon:

- IO buffer cells (e.g., `bidir_pad`, `od_pad`)
- IO retention logic for low-power flows
- Test-mode muxes (scan, boundary scan, JTAG)
- ESD protection clamps (instance-level)

In this academic project the wrapper is currently empty of those concerns, but architecturally that is **where they would go**. Knowing that placement is what separates a fresher from someone who has seen tape-out.

### Pillar 3 — Verification entry point

The testbench `bind`s to the wrapper, not the controller. This means:

- The wrapper's port list is the **DV contract**.
- Verification ports (`force_data_nack`, `reg_bank` outputs) are added at the wrapper layer where they cannot accidentally pollute the synthesizable controller.
- The wrapper can `ifdef` out simulation-only ports for synthesis, while the controller stays untouched.

### Pillar 4 — Configurability without parameter explosion in the core

`i2c_slave.sv` accepts `SLAVE_ADDR` and forwards it to the controller. If we later wanted to add `SLAVE_ADDR_MASK` for multi-address aliasing, that parameter would be added at the wrapper and forwarded. The controller stays clean of "user-facing" parameters versus "implementation" parameters.

### The pattern in a single sentence

> "The wrapper is the **stable contract** with the outside world; the controller is the **swappable implementation** underneath."

This pattern is called **port isolation** (sometimes "shell/core" or "facade") and is genuinely industry-standard for any IP that ships to multiple consumers.

---

## 4. Deep Walkthrough — `i2c_master.sv`

Let us walk the file top to bottom. The full file is only 57 lines, so we will cover every meaningful one.

### Lines 1-6 — File header

```systemverilog
//=============================================================================
// File          : i2c_master.sv
// Description   : Top-level I2C Master wrapper
//               : Connects the controller to the open-drain IO pads.
// Language      : SystemVerilog (IEEE 1800-2012)
//=============================================================================
```

**Why this matters:** File headers are not decoration. In a real review, the **Language line** is what tells the synthesis tool and the linter which dialect to enforce. `IEEE 1800-2012` is SystemVerilog. The 2017 revision is also common; some shops still pin to 2005-Verilog for legacy reasons. Always state the standard at the top of every file.

### Lines 8-9 — Include guard

```systemverilog
`ifndef I2C_MASTER_SV
`define I2C_MASTER_SV
```

We covered include guards in Lesson 01 — same pattern: prevent duplicate compilation when the file is textually `` `include``-ed multiple times. With a clean file-list flow, this is redundant but harmless.

### Line 11 — Module declaration

```systemverilog
module i2c_master (
```

Note: **no parameter block** (`#(...)`). The master has zero parameters at the wrapper boundary. This is intentional and one of the quiz questions — keep it in mind.

### Lines 12-14 — System ports

```systemverilog
  // System
  input  logic        clk,
  input  logic        rst_n,
```

- `clk` — the 50 MHz system clock. The master generates SCL from this by counting `T_SCL_PERIOD = 500` ticks (Lesson 01 math).
- `rst_n` — active-low asynchronous reset. The trailing `_n` is the convention.

**Why `logic` and not `wire`?**
`logic` is a **resolved 4-state type** that can be driven from a single source. `wire` is a **net** that supports multiple drivers and resolution functions. For a single-driver input port, `logic` is preferred — it is the SV-era default. Use `wire` only where you genuinely have multiple drivers (open-drain busses, tri-state busses, wired-OR logic).

**Interview trap:** *"What's the difference between `logic` and `reg` and `wire`?"*
- `reg` (Verilog-1995) — variable assignable from `always` blocks only.
- `wire` (Verilog-1995) — net for continuous assignments / multi-driver resolution.
- `logic` (SystemVerilog) — unified type, can be used as variable OR net for single-driver cases. Use it everywhere unless you specifically need `wire` semantics.

### Lines 16-21 — Host CPU interface (APB-like CSR)

```systemverilog
  input  logic [2:0]  cpu_addr,
  input  logic        cpu_wr,
  input  logic [7:0]  cpu_wdata,
  output logic [7:0]  cpu_rdata,
  output logic        cpu_irq,
```

This is a **simplified APB**. Real APB has `psel`, `penable`, `paddr`, `pwrite`, `pwdata`, `prdata`, `pready`, `pslverr`. This project reduces it to:

| Port | Width | Meaning | APB equivalent |
|---|---|---|---|
| `cpu_addr` | 3 | Register address (one of 7 CSRs, `REG_CTRL`...`REG_IRQ_ST`) | `paddr[4:2]` |
| `cpu_wr` | 1 | 1 = write, 0 = read | `pwrite` |
| `cpu_wdata` | 8 | Write data | `pwdata` |
| `cpu_rdata` | 8 | Read data (combinationally returned) | `prdata` |
| `cpu_irq` | 1 | Interrupt out | (separate IRQ line) |

`cpu_addr` is 3 bits because we have 7 CSRs and 3 bits gives 8 codes (one unused). This matches the `i2c_reg_e` enum width in `i2c_pkg.sv`.

**Senior-engineer thought process:** When you see a CSR bus, ask:
1. "Is there a ready/valid handshake?" Here: **no**. That implies single-cycle access — the controller must respond combinationally on reads.
2. "Is there a separate read-data path?" Here: **yes**, `cpu_rdata` is independent of `cpu_wdata`. Good — that means simultaneous read while another write is queued is at least *possible*.
3. "Is the IRQ level or edge?" The wrapper does not tell us. **Flag this in code review.**

### Lines 23-25 — The I2C bus

```systemverilog
  // I2C Physical Interface (Open-Drain, Wired-AND)
  inout  wire         scl,
  inout  wire         sda,
```

This is **THE** critical part of this file. Everything in the quiz hinges on it.

#### `inout` — bidirectional port

`scl` and `sda` are bidirectional. The master sometimes drives (e.g., generating start/stop, sending data) and sometimes releases the bus (during read phases). The slave sometimes drives (e.g., ACK pulses, sending data during master reads).

#### `wire` — multi-driver net with resolution

A `wire` can have multiple drivers simultaneously. SV resolves them per IEEE 1800: if any driver is `1'b0`, the wire is `1'b0`; if all drivers are `1'bz` (high-impedance), an external pull-up resolves the bus to `1'b1`; if drivers conflict (`1'b0` from A, `1'b1` from B), the resolution is `1'bx`.

#### Open-drain modeling — the trick

Real I2C devices have an open-drain output stage: they can either **pull SCL/SDA to ground** or **release them to high-Z**. They cannot drive a hard `1'b1`. An external pull-up resistor (Rp, typically 4.7 kΩ) pulls the bus to VDD when no one is driving.

In SV, you model this with:

```systemverilog
assign sda = sda_drive_low ? 1'b0 : 1'bz;
```

- When `sda_drive_low` is asserted, the driver outputs `1'b0`.
- Otherwise the driver outputs `1'bz` (high-impedance / "I'm not driving").

If both master and slave release, all drivers are `1'bz`. The wire resolves to `1'bz` — UNLESS there is a pull-up modelled with `pullup(sda);` or `assign (weak1, weak0) sda = 1'b1;`. Standard I2C testbenches include this pull-up explicitly.

#### Wired-AND behavior

The bus implements a **wired-AND**: it is `1'b1` only if **every** participant releases. Any participant pulling low forces the whole bus low. This is the property that makes:

- **Clock stretching** work (slave holds SCL low → master cannot proceed)
- **Arbitration** work (in multi-master, lowest data wins automatically)
- **ACK/NACK** work (receiver pulls SDA low during the 9th SCL pulse to ACK)

You **cannot model open-drain with `output logic`** — `logic` is single-driver, so the slave could not assert ACK against a master driving high. The `inout wire` is mandatory.

### Lines 27-34 — Control / Status outputs

```systemverilog
  output logic        busy,
  output logic        done,
  output logic        ack,
  output logic        nack,
  output logic        timeout,
  output logic        bus_error,
  output logic        arb_lost
```

These are the **summary flags** the CPU and testbench watch.

| Port | Meaning | When asserted |
|---|---|---|
| `busy` | Master is mid-transaction | Between START and STOP |
| `done` | Last requested command completed | Pulse for one clock |
| `ack` | Last byte received an ACK from the slave | After the 9th SCL of a byte |
| `nack` | Last byte received NACK | After the 9th SCL of a byte |
| `timeout` | Clock-stretch or arbitration timed out | When `MAX_CLK_STRETCH` counter expires |
| `bus_error` | Protocol violation seen on the bus | START in the middle of a byte, etc. |
| `arb_lost` | Lost multi-master arbitration | Should never fire in single-master |

Note `arb_lost` is **declared but never used** in single-master operation. We discussed this in Lesson 01 Q7 — it is a scope-excluded port that lives in the design for future multi-master extension. The verification plan should waive coverage on it.

### Lines 38-55 — Controller instantiation

```systemverilog
  i2c_master_controller master_core (
    .clk      (clk),
    .rst_n    (rst_n),
    .cpu_addr (cpu_addr),
    .cpu_wr   (cpu_wr),
    .cpu_wdata(cpu_wdata),
    .cpu_rdata(cpu_rdata),
    .cpu_irq  (cpu_irq),
    .scl      (scl),
    .sda      (sda),
    .busy     (busy),
    .done     (done),
    .ack      (ack),
    .nack     (nack),
    .timeout  (timeout),
    .bus_error(bus_error),
    .arb_lost (arb_lost)
  );
```

This is a **named port connection** instantiation. Every port is connected as `.port_name(signal_name)`.

#### Why named connections matter

There are three styles in SV:

```systemverilog
// 1. Positional — DEPRECATED for anything non-trivial
controller u1 (clk, rst_n, cpu_addr, ...);

// 2. Named explicit — REQUIRED by every serious coding standard
controller u1 (.clk(clk), .rst_n(rst_n), .cpu_addr(cpu_addr), ...);

// 3. Named implicit (SV "shortcut") — Style 2's lazy cousin
controller u1 (.clk, .rst_n, .cpu_addr, ...);
```

The master wrapper uses **style 2** consistently. This is the safe, idiomatic, NVIDIA-coding-standard-compliant form.

The slave wrapper uses **style 3** (we will get to that). Both compile, but style 2 is preferred because:
- Style 3 silently breaks if the port name or local signal name diverges (e.g., refactor renames `clk` to `core_clk` in the parent — implicit connection now fails, but only at elaboration).
- Style 2 makes the intent explicit and survives renames.

This is **quiz question 9**.

### Line 57 — `endmodule`

```systemverilog
endmodule
```

Ends the module. The `` `endif`` on the next line closes the include guard.

### Master wrapper — Summary

- **Lines of actual code:** ~20 (rest is comments, guards, port list).
- **Logic in the wrapper:** ZERO. Pure pin-out.
- **Style:** Named-explicit port connections.
- **Parameters:** None. All timing comes from `i2c_pkg.sv`.

---

## 5. Deep Walkthrough — `i2c_slave.sv`

The slave wrapper is **structurally similar** to the master but with three meaningful differences:

1. It is **parameterized** by `SLAVE_ADDR`.
2. It exposes **verification-only inputs** for fault injection.
3. It exposes **internal state outputs** for TB observation.

Let us walk it.

### Lines 1-9 — Header and guard

Same pattern as the master. Skip.

### Lines 10-13 — Parameterized module declaration

```systemverilog
module i2c_slave
#(
  parameter logic [6:0] SLAVE_ADDR = 7'h50
)
(
```

This is the **key syntactic difference** from the master.

#### Why parameterize the address?

I2C is a multi-slave bus. Multiple devices live on the same `scl`/`sda` pair, distinguished by 7-bit address. To verify a system with multiple slaves at different addresses, you instantiate the same RTL multiple times:

```systemverilog
i2c_slave #(.SLAVE_ADDR(7'h50)) u_eeprom   (...);
i2c_slave #(.SLAVE_ADDR(7'h68)) u_rtc      (...);
i2c_slave #(.SLAVE_ADDR(7'h1D)) u_accel    (...);
```

Without the parameter, you would need three separate RTL files — DRY violation.

#### Why is the type `logic [6:0]` and not `int`?

`parameter int SLAVE_ADDR = 7'h50;` would also work, but:

- `logic [6:0]` is **width-restricted at declaration**. If a caller passes 8 bits (`7'h80` mistakenly typed as `8'h80`), the synthesizer catches it.
- `int` is 32 bits. Caller could pass `7'h150` and you would silently lose the MSB on assignment.
- Using `logic [6:0]` documents *"this parameter represents a 7-bit hardware quantity."*

**Senior framing:** *"Type the parameter to match the hardware semantics, not the general-purpose programming type."*

#### Default value `7'h50`

`7'h50` is `7'b101_0000`. It is in the **legal range** (not reserved). Reserved I2C addresses are `7'b0000_xxx` and `7'b1111_xxx` per NXP UM10204. We verified this with `is_valid_addr()` in Lesson 01 — that function should be applied at the controller boundary to assert the parameter is sane.

### Lines 15-17 — System inputs

```systemverilog
  // System
  input  logic        clk,
  input  logic        rst_n,
```

Identical to the master.

### Lines 19-21 — Bus pins

```systemverilog
  // I2C Physical Interface (Open-Drain)
  inout  wire         scl,
  inout  wire         sda,
```

Identical typing to the master. The slave can pull SCL low (clock-stretching) or release it. Same for SDA.

### Lines 23-26 — Verification-only inputs

This is the **first major difference** from the master.

```systemverilog
  // Clock stretching control
  input  logic        stretch_en,
  input  logic [15:0] stretch_cycles,
  input  logic        force_data_nack,
```

| Port | Type | Purpose |
|---|---|---|
| `stretch_en` | input | Enable clock stretching feature |
| `stretch_cycles` | input [15:0] | How many cycles to stretch SCL low |
| `force_data_nack` | input | Force the slave to NACK incoming data |

These are **fault-injection / stimulus-control inputs**. They do not exist on a real I2C EEPROM chip. They are added to RTL specifically so the testbench can control corner cases without rewriting the FSM.

#### Why fault-injection ports?

In DV, you need to test:
- **Happy path** — slave ACKs every byte. Easy.
- **Sad path #1** — slave NACKs a data byte (e.g., write-protected page in an EEPROM). How do you make the slave NACK? You **inject** that response via `force_data_nack`.
- **Sad path #2** — slave clock-stretches because it is busy. How do you make the slave stretch? You inject with `stretch_en` and program duration with `stretch_cycles`.

#### Do these ports survive to silicon? NO.

In production silicon:
- The pad ring does not have `force_data_nack` or `stretch_en` pins.
- These ports are typically gated behind `` `ifdef SIM`` or **removed at the wrapper boundary** for synthesis.
- Or they are **wrapped into a test-mode CSR** that is locked in production by an eFuse.

For this academic project, they are unconditionally present. In a real shop, you would surround them with:

```systemverilog
`ifndef SYNTHESIS
  input  logic        force_data_nack,
  input  logic        stretch_en,
  input  logic [15:0] stretch_cycles,
`endif
```

#### What verification concept do these enable?

**Stimulus controllability** — the testbench can drive the DUT into specific protocol states (NACK on byte 3, stretch SCL for 1000 cycles, etc.) without having to find a "natural" trigger.

This is **quiz question 2** — burn the concept into memory: *"Fault-injection ports give the testbench knobs to reach corner cases that would be impractical to hit organically."*

### Lines 28-37 — Status outputs (TB visibility hooks)

```systemverilog
  // Status outputs for testbench monitoring
  output logic [7:0]  reg_bank    [0:7],
  output logic        reg_updated [0:7],
  output logic        addr_match,
  output logic        active,
  output logic        rx_data_valid,
  output logic [7:0]  rx_data,
  output logic        tx_ack,
  output logic        tx_nack,
  output logic        bus_error
```

This is the **second major difference** from the master.

These ports expose **internal state** of the controller for testbench monitoring.

| Port | Width | What it exposes |
|---|---|---|
| `reg_bank` | [7:0] x 8 | The internal register file (8 bytes, like an EEPROM page) |
| `reg_updated` | 1 x 8 | One-hot vector marking which register was last written |
| `addr_match` | 1 | Whether the address phase matched `SLAVE_ADDR` |
| `active` | 1 | Slave FSM is engaged with the bus |
| `rx_data_valid` | 1 | A new RX byte is ready |
| `rx_data` | 8 | The most recent RX byte |
| `tx_ack` | 1 | Slave asserted ACK |
| `tx_nack` | 1 | Slave asserted NACK |
| `bus_error` | 1 | Slave saw a protocol violation |

#### Why expose `reg_bank` as an output port?

In a real EEPROM chip, the register bank is **deep internal state**. You cannot put 64 wires on the package — pad cost would be prohibitive.

In this DV environment, the testbench needs to **compare DUT register state against an expected reference model** (the scoreboard). The cheapest way to expose internal state is by hoisting it through the wrapper as output ports. Then the TB monitor reads them directly.

#### `output logic [7:0] reg_bank [0:7]` — packed × unpacked dissection

This is **quiz question 3** and one of the most-asked SV interview points.

```systemverilog
output logic [7:0] reg_bank [0:7]
            └──┬──┘         └──┬──┘
            PACKED         UNPACKED
```

- **Packed dimension** `[7:0]` — the part **left of the signal name**. It describes bits of a single element. Packed dimensions are contiguous bits, like a register.
- **Unpacked dimension** `[0:7]` — the part **right of the signal name**. It describes how many elements there are. Unpacked dimensions are array-of-things, like memory.

**Total bits = 8 packed * 8 elements = 64 bits.**

In memory layout terms:
- `reg_bank` is an **array of 8 bytes**, indexed `[0]`, `[1]`, ..., `[7]`.
- Each byte is 8 bits, indexed `[7]`, `[6]`, ..., `[0]` (MSB first).

#### Reading `[7:0]` vs `[0:7]` — order matters

| Direction | Meaning |
|---|---|
| `[7:0]` (descending) | MSB-to-LSB packed bit layout. `reg_bank[3][7]` is the MSB of byte 3. |
| `[0:7]` (ascending) | Element 0 is the **first** element. Standard "little-endian" array indexing. |

Why the asymmetry? Convention:
- **Packed bits** are typically declared **MSB-to-LSB**: `[7:0]`, `[31:0]`, `[WIDTH-1:0]`. Matches how we read binary numbers.
- **Unpacked arrays** are typically declared **start-to-end**: `[0:DEPTH-1]` or `[0:7]`. Matches how we read sequences.

If you reverse them (`[0:7]` packed or `[7:0]` unpacked), the code compiles but reads backwards from convention. Linters and humans flag it as suspicious.

**Interview trap:** *"What's the bit order of `logic [0:7] x;`?"*
Answer: `x[0]` is the MSB. This is the opposite of `logic [7:0]` and almost never what you want for arithmetic. Use it only when modelling something that is **inherently big-endian** (e.g., network byte order).

#### Where this packed/unpacked thing breaks things

You **cannot directly pass an unpacked array through a single wire-style assignment**. For example:

```systemverilog
logic [7:0] all_bytes;
logic [7:0] reg_bank [0:7];
assign all_bytes = reg_bank;     // ERROR — type mismatch
```

You have to iterate:

```systemverilog
generate
  for (genvar i = 0; i < 8; i++) begin : g_flatten
    assign flat_bus[i*8 +: 8] = reg_bank[i];
  end
endgenerate
```

This is one reason real SoCs prefer **packed-only arrays** at module boundaries:

```systemverilog
output logic [63:0] reg_bank_flat
```

The slave wrapper chose the **unpacked form** because the controller core uses memory-like indexing internally and exporting it unchanged is cheapest.

### Lines 40-62 — Controller instantiation

```systemverilog
  i2c_slave_controller
  #(
    .SLAVE_ADDR(SLAVE_ADDR)
  )
  slave_core
  (
    .clk,
    .rst_n,
    .scl,
    .sda,
    .reg_bank,
    .reg_updated,
    .addr_match,
    .active,
    .stretch_en,
    .stretch_cycles,
    .force_data_nack,
    .rx_data_valid,
    .rx_data,
    .tx_ack,
    .tx_nack,
    .bus_error
  );
```

Two things to notice:

#### 1. Parameter forwarding

```systemverilog
i2c_slave_controller
#(
  .SLAVE_ADDR(SLAVE_ADDR)
)
slave_core
```

The wrapper's `SLAVE_ADDR` parameter is **forwarded** to the controller's `SLAVE_ADDR` parameter. The controller is also parameterized — the wrapper does not "consume" the parameter; it passes it through. Without this forwarding, the controller would always use its own default.

#### 2. Implicit (`.name`) port connection style

```systemverilog
.clk,
.rst_n,
.scl,
.sda,
.reg_bank,
...
```

This is **SystemVerilog's "name shortcut"**: `.clk` is shorthand for `.clk(clk)`. It requires the port name (in the controller) to match the local signal name (in the wrapper).

This is **quiz question 6 and 9**.

#### Why implicit style is risky

| Risk | Example | Detection |
|---|---|---|
| Port rename in child | Controller renames `clk` to `core_clk` | Compiler error at elaboration — actually safe |
| Local signal rename | Wrapper renames `clk` to `sys_clk` but forgets to update `.clk` | **Silent miscompile** — `.clk` still resolves to a different `clk` in scope, or compile error |
| Implicit-wire creation in some tools | Unset signal becomes a 1-bit wire | Bug only seen at simulation, often `1'bx` |
| Code review friction | Reviewer cannot see what is being connected | Slows reviews and hides errors |

#### Why NVIDIA-style coding standards ban implicit connections

Big silicon companies (NVIDIA, Apple, Qualcomm, Intel, AMD, Synopsys) typically have lint rules that **forbid** `.name` and **require** `.name(signal)` everywhere. Reasons:

1. **Greppability** — searching for `.clk(` finds every connection. Searching for `.clk` finds nothing useful.
2. **Refactor safety** — explicit connections survive signal renames; implicit ones do not.
3. **Cognitive load** — explicit form makes the inter-module wiring obvious to a reviewer.
4. **Tool compatibility** — older synthesis tools and linters do not always handle `.name` cleanly.

**Code review verdict on this file:** the slave wrapper should be rewritten in named-explicit form for consistency with the master.

```systemverilog
// Preferred:
.clk      (clk),
.rst_n    (rst_n),
.scl      (scl),
...
```

### Line 64 — `endmodule`

Standard close.

### Slave wrapper — Summary

- **Lines of actual code:** ~25.
- **Logic in wrapper:** ZERO. Pure pin-out with parameter forwarding.
- **Style:** Named-implicit port connections (inconsistent with master — code-review issue).
- **Parameters:** `SLAVE_ADDR` (7-bit address, default 7'h50).
- **Verification-only inputs:** `stretch_en`, `stretch_cycles`, `force_data_nack`.
- **TB visibility outputs:** `reg_bank`, `reg_updated`, `addr_match`, `active`, `rx_data_valid`, `rx_data`, `tx_ack`, `tx_nack`, `bus_error`.

---

## 6. Master vs Slave Wrapper Comparison Table

| Aspect | `i2c_master.sv` | `i2c_slave.sv` | Why |
|---|---|---|---|
| Total lines | 57 | 65 | Slave has more ports + parameter block |
| Parameters | None | `SLAVE_ADDR = 7'h50` | Multiple slaves need distinct addresses; master is unique on bus |
| Bus pins | `inout wire scl, sda` | `inout wire scl, sda` | Identical — open-drain requires `wire` |
| CPU-side interface | APB-like (`cpu_addr`, `cpu_wr`, `cpu_wdata`, `cpu_rdata`, `cpu_irq`) | None | Slave is autonomous; no CPU drives it from the host side |
| Fault-injection inputs | None | `force_data_nack`, `stretch_en`, `stretch_cycles` | TB needs to drive slave into corner cases |
| TB visibility outputs | Limited (`busy`, `done`, `ack`, etc.) | Rich (`reg_bank`, `addr_match`, `rx_data_valid`...) | DUT-under-test (slave) needs more observability than the BFM (master) |
| Port-connection style | Named explicit `.clk(clk)` | Named implicit `.clk` | Style inconsistency — should be unified |
| Controller instantiated | `i2c_master_controller` (no param fwd) | `i2c_slave_controller` (with `.SLAVE_ADDR` fwd) | Master has no param; slave forwards `SLAVE_ADDR` |
| Synthesizable as-is | Yes | Mostly — fault-injection ports would be `ifdef`-gated in real flow | Verification-only ports do not belong in production RTL |
| Include guard | Yes | Yes | Both — defensive |

### Strategic interview line

> *"The master is a BFM in this project — its job is to drive the bus per a test plan. The slave is the DUT — its job is to be observed. So the slave wrapper carries the verification ports; the master wrapper does not."*

---

## 7. Quiz — 10 Questions

Cover the answers section before reading further. Score yourself honestly.

1. **Why is `scl`/`sda` typed `inout wire` and not `output logic`? What does `1'bz` mean in simulation, and how does the bus resolve when multiple devices "drive" it?**

2. **The slave has `force_data_nack` as an input. Does this port exist in real production silicon? If not, why is it in RTL? What verification concept does it enable?**

3. **`output logic [7:0] reg_bank [0:7]` — how many total bits is this? Which part is packed, which is unpacked? Why does the order `[7:0]` vs `[0:7]` matter when reading SV mixed-array declarations?**

4. **Two slaves at the same `SLAVE_ADDR = 7'h50` by mistake — what happens at the I2C protocol level on the bus? Walk through what the master observes.**

5. **The master wrapper has no parameters; everything comes from `i2c_pkg.sv`. Is this a design limitation? To test the master's clock-stretch timeout with a much shorter `MAX_CLK_STRETCH` in simulation, what would you actually do — is changing the package value the right answer?**

6. **The master uses named port connections; the slave uses implicit (`.clk` shorthand). Both compile. What's the risk of implicit connections? Why do NVIDIA-style coding standards often ban them?**

7. **The slave exposes `reg_bank [0:7]` directly as output ports for testbench monitoring. In real silicon, these wouldn't be visible at the pad ring. How would a DV engineer access internal state in a real project? Name TWO methods.**

8. **Why does the slave wrapper have `SLAVE_ADDR` as a parameter but the master has no parameters? Is this asymmetry a design flaw or intentional?**

9. **The master uses `.clk(clk)` style; the slave uses `.clk` style. Is this style inconsistency a problem? How would you fix it in a code review?**

10. **`inout wire` vs `inout logic` — why does I2C specifically need `wire`? What would `inout logic` do differently in simulation?**

---

## 8. Quiz — Answers & Deep Explanations

### Q1 — `inout wire` vs `output logic`, `1'bz`, bus resolution

**Why `inout wire`:**
- `inout` because both master and slave drive the same physical wire at different times.
- `wire` because the bus has **multiple drivers** and SV requires `wire` (a net type) for multi-driver resolution. `logic` is a variable that allows only one driver.

**`1'bz` (high-impedance):**
`1'bz` means *"this driver is not asserting any logic level; the wire is floating from my perspective."* It is the SV representation of a tri-state output that has released its pull-down. In open-drain modeling:

```systemverilog
assign sda = drive_low ? 1'b0 : 1'bz;
```

When `drive_low` is 0, this driver contributes `1'bz`. If every driver contributes `1'bz`, the wire is floating; an external `pullup(sda);` then pulls it to `1'b1`.

**Resolution table (single wire, multiple drivers):**

| Driver A | Driver B | Resolved |
|---|---|---|
| 0 | 0 | 0 |
| 0 | 1 | x (conflict) |
| 0 | z | 0 |
| 1 | 1 | 1 |
| 1 | z | 1 |
| z | z | z (then pull-up makes it 1) |

For open-drain (where nobody ever drives a hard 1), the conflict row never appears. The resolved value is `1'b0` if ANY driver pulls low, `1'b1` (via pull-up) if ALL release. This is the **wired-AND**.

> **Interview-grade answer:**
> *"`scl` and `sda` are typed `inout wire` because I2C is an open-drain, multi-driver bus. Drivers can only pull low or release to `1'bz`; the bus is pulled high by an external resistor and resolves to the wired-AND of all participants. `logic` cannot model this because it is a single-driver variable type — you cannot have both master and slave drive the same `logic` signal. `1'bz` is the SV representation of a released driver; combined with `pullup(sda);` in the TB, releasing produces `1'b1`."*

---

### Q2 — `force_data_nack` in production silicon

**Short answer: NO, this port does not exist in production silicon.**

**Why it is in RTL:**

`force_data_nack` is a **fault-injection / stimulus-control input** added specifically so the testbench can drive the slave into a state where it NACKs data. In a real EEPROM, a NACK happens "naturally" — write-protect bit set, page full, address out of range, etc. In DV, you do not want to wait for or engineer those natural conditions; you want a direct knob.

**Verification concept this enables: stimulus controllability.**

DV engineers measure how easily they can reach any state of the DUT. Without `force_data_nack`, you would need:
- A specific EEPROM-like internal model with write-protect registers
- A test sequence that puts the slave in write-protected state
- Then a write attempt that should NACK

That is fragile and slow. With `force_data_nack`, the TB simply asserts the pin and observes NACK on the bus. Done.

**In a real shop, you would:**
- Wrap fault-injection ports in `` `ifndef SYNTHESIS`` or equivalent.
- Or expose them through a **test-mode register** that is locked by an eFuse in production.
- Or use **force/release** from the testbench to hit the same nodes inside the controller — no extra port required.

> **Interview-grade answer:**
> *"It is a verification-only port. Real silicon would not pin this out — either it would be `ifdef`-gated for synthesis, or hidden behind a test-mode CSR locked in production. The reason it exists in RTL is **stimulus controllability**: it lets the testbench drive the slave into NACK behavior on demand without engineering a natural cause. In a senior flow, the same effect can be achieved with force/release from the TB, but for a teaching project a dedicated input is cleaner."*

---

### Q3 — `output logic [7:0] reg_bank [0:7]` dissection

**Total bits:** 8 (packed width) * 8 (unpacked depth) = **64 bits.**

**Packed dimension:** `[7:0]` — between the type `logic` and the signal name `reg_bank`. This is the bit width of **a single element**. MSB-to-LSB declaration (descending) is conventional for packed.

**Unpacked dimension:** `[0:7]` — to the **right** of the signal name. This is the array depth. Ascending (`0:7`) is conventional for memory-like indexing where index 0 is the first element.

**Why order matters:**

| Declaration | Meaning |
|---|---|
| `logic [7:0] x [0:3]` | x is array of 4 bytes; x[0] is first byte; x[0][7] is MSB of first byte |
| `logic [0:7] x [0:3]` | x is array of 4 bytes; x[0][0] is MSB of first byte (reversed bit order) |
| `logic [7:0] x [3:0]` | x is array of 4 bytes; x[3] is first element (reversed array order) |
| `logic [3:0] x [0:7]` | x is array of 8 nibbles; x[0][3] is MSB of first nibble |

The **direction** of the packed range and the **direction** of the unpacked range are independent and both matter for indexing.

**Convention you should learn and never break:**

```systemverilog
logic [WIDTH-1:0]  signal_name [0:DEPTH-1];
       descending                ascending
       (MSB-first)              (index-0-first)
```

**Why this is interview-critical:**

You will be handed a port list and asked *"how wide is this and what is element 3, bit 7?"* You must be able to answer in 5 seconds. Practice on these:

- `logic [15:0] mem [0:255]` — 256 elements, 16 bits each, 4096 bits total, `mem[3]` is the 4th element.
- `logic [31:0] data [0:3][0:3]` — 4x4 array of 32-bit words, 512 bits total.
- `logic mask [0:7]` — 8-element unpacked array of 1-bit signals, 8 bits total.

> **Interview-grade answer:**
> *"This is 64 bits total — packed 8 bits, unpacked 8 elements. The packed dimension `[7:0]` describes a single element's bit layout MSB-first. The unpacked dimension `[0:7]` describes the array, with index 0 being the first element. The conventional reading is `logic [WIDTH-1:0] name [0:DEPTH-1]` — packed descending, unpacked ascending. Reversing either direction compiles but reads wrong and triggers lint warnings."*

---

### Q4 — Two slaves at the same address

This is a real I2C hazard. Walk through it step by step.

**Setup:** Master sends `START` then byte `{7'h50, 1'b0}` (address 0x50, write).

**What every slave on the bus does:**
1. Sees `START` (SDA falling while SCL high). Goes into address-decode state.
2. Captures the next 8 bits on SCL rising edges.
3. Compares the upper 7 bits to its own `SLAVE_ADDR`.
4. If match, drives SDA **low** during the 9th SCL pulse to ACK.

**With two slaves both at 7'h50:**

Both `addr_match` flags go high. Both slaves pull SDA low during the ACK slot. The bus shows `1'b0` for the ACK — the master sees a successful ACK and proceeds.

**Then the master sends a data byte:**

Both slaves enter "receive data" state, both capture the data byte.

**Now the master expects ACK on the data byte:**

Both slaves ACK simultaneously. SDA = `1'b0`. The master sees ACK and proceeds.

**Things break on the FIRST READ:**

If the master switches to a READ (sends `{7'h50, 1'b1}` and expects the slave to drive data), **both slaves drive SDA simultaneously**. Bit values may disagree. The wired-AND resolves to the bit-wise AND of both data sources:

- If slave A drives bit 7 = 1 and slave B drives bit 7 = 0, the wire shows 0.
- If both drive the same bit, the wire shows that bit.

The master receives **corrupted data** — it cannot tell from the wire alone that two slaves collided.

**What the master observes:**
- Address phase ACK: success.
- Write phase ACK: success.
- Read phase: garbage data, NO bus error flag fires (the master cannot distinguish "this is a single slave with this data" from "two slaves wired-AND-ed to this data").

**In multi-master arbitration, the protocol handles this** because masters monitor SDA after driving. But for slave-slave collision, there is **no protocol-level detection** — the system designer must ensure address uniqueness at the board level.

**Senior-engineer thought process:**
1. *"Whose responsibility is this?"* Answer: the **board / SoC integrator**, not the slave RTL. The slave RTL is correct; the system is misconfigured.
2. *"Can DV catch this?"* Answer: only with **system-level (SoC) tests** that instantiate multiple slaves and check end-to-end behavior. Block-level slave verification (our project) cannot catch it.
3. *"What's the assertion you'd add?"* At the bus level: `assert (count_of_drivers_low(sda_in_ack_slot) <= 1)` — but practically this is hard to model.

> **Interview-grade answer:**
> *"At the protocol level, I2C has no slave-collision detection. Both slaves ACK the address and any writes — the bus wired-ANDs to a valid ACK. The collision only manifests on reads, where both slaves drive data simultaneously and the bus resolves to the bitwise AND of their outputs. The master sees corrupted data with no error indication. This is an integration-level bug — slave RTL is fine; the SoC integrator must guarantee address uniqueness. Catching it requires multi-slave system tests, not block-level verification."*

---

### Q5 — Master has no parameters; changing `MAX_CLK_STRETCH` for sim

**Is this a design limitation?** Depends how you frame it.

- **Junior view:** "Yes, parameters are flexibility. The master has none, so it is rigid."
- **Senior view:** "No — the master uses the package as the single source of truth. Adding parameters at the wrapper would create **two** places to configure timing (package + module parameter), which is worse than one. The package centralization is intentional."

**To shorten `MAX_CLK_STRETCH` for simulation, the WRONG answers:**

1. **Edit `i2c_pkg.sv` directly.** Bad because: pollutes RTL with sim-only values; risks accidental commit; affects synthesis if not reverted.

2. **Use Verilog `defparam`.** Bad because: deprecated in modern SV; tool-dependent; breaks scoping rules.

**The RIGHT answers, in order of cleanliness:**

#### Option A — Override the package value via simulator command-line

Most simulators let you redefine `` `define`` macros from the command line:

```bash
vlog +define+MAX_CLK_STRETCH=100 i2c_pkg.sv
```

This requires the package to express the constant as `` `MAX_CLK_STRETCH`` rather than `parameter int MAX_CLK_STRETCH = ...`. Refactoring opportunity.

#### Option B — Parameterize the master_controller and wrapper

Add an optional override parameter:

```systemverilog
module i2c_master #(
  parameter int MAX_CLK_STRETCH_OVR = -1  // -1 = use package default
) (...);

  localparam int EFFECTIVE_MAX = (MAX_CLK_STRETCH_OVR < 0) 
                                  ? i2c_pkg::MAX_CLK_STRETCH 
                                  : MAX_CLK_STRETCH_OVR;
```

Now the testbench instantiates `i2c_master #(.MAX_CLK_STRETCH_OVR(100)) DUT (...)` without touching the package.

#### Option C — Use SV `bind` to override the timing in the controller

Bind a small monitor module that hijacks the timeout counter. More invasive, but allows late-stage override without RTL changes.

#### Option D — Force from the testbench

```systemverilog
initial begin
  force u_dut.master_core.timeout_limit = 16'd100;
end
```

Quick-and-dirty but it works. Generally avoided in production DV because force/release breaks coverage and is fragile against RTL refactors.

> **Interview-grade answer:**
> *"Editing the package is wrong — it pollutes RTL with sim values and risks accidental commit. The clean solutions are: (1) parameterize the master with an override parameter so the TB can pass a sim-only value via instantiation, (2) define the constant as a backtick-define so simulators can override via `+define`, or (3) force the relevant signal from the TB. Option 1 is cleanest because it keeps the value visible in elaboration and avoids force semantics. The wrapper having no parameters is not a flaw — it is the package-as-source-of-truth pattern. The fix is to add an override parameter, not to abandon centralization."*

---

### Q6 — Named vs implicit port connections

**Both compile.** Both are legal SV. The risks of implicit (`.name`):

#### Risk 1 — Silent semantic drift on rename

```systemverilog
// Wrapper
logic clk;
controller u1 (.clk, ...);   // OK — .clk binds to local clk

// Refactor: rename the wrapper signal
logic core_clk;
controller u1 (.clk, ...);   // ERROR or unexpected behavior
```

The behavior depends on the tool:
- **Strict tools:** Elaboration error — `clk` not found in scope.
- **Permissive tools:** Implicitly creates a 1-bit net called `clk` (the old Verilog "implicit wire" rule). The controller's clock is now disconnected — simulation runs but FSM never advances. **Silent miscompile.**

#### Risk 2 — Greppability

```bash
grep -rn '.clk(' rtl/    # finds all explicit connections
grep -rn '.clk[^(]' rtl/ # tries to find implicit — also matches comments, declarations, garbage
```

In a 500-file codebase, you cannot trace signal usage if half the connections are implicit.

#### Risk 3 — Reviewer cognitive load

When reviewing a PR:
```systemverilog
controller u1 (.clk, .rst_n, .a, .b, .c);   // What is connected to what?
```
The reviewer must mentally resolve `.a` to the local signal `a` for every port. Easy to miss a name mismatch.

#### Risk 4 — Tool compatibility

Some older synthesis tools and lint tools predate SV-2005's `.name` shortcut and may not handle it cleanly. Net warnings, missed connections, or weird elaboration behavior.

**Why NVIDIA-style standards ban it:**

NVIDIA, Apple, Qualcomm, Intel, AMD, Samsung Foundry — every serious silicon shop has a coding standard. The relevant rule is typically:

> *"Module instantiation port connections SHALL use named-explicit form: `.port(signal)`. Positional and named-implicit forms are forbidden."*

The standard then justifies it with the four risks above plus a fifth: **uniform style across the codebase makes auto-formatters and IDE tooling work consistently.**

> **Interview-grade answer:**
> *"Both forms compile, but the implicit `.clk` form is brittle. If the local signal is renamed, some tools throw an elaboration error and others silently auto-create a wire — leaving the connection dangling. It also hurts greppability and code-review clarity. NVIDIA-style coding standards ban it for those reasons; the explicit `.port(signal)` form is the only acceptable style."*

---

### Q7 — Accessing internal state in real silicon

In this academic project, `reg_bank`, `addr_match`, `rx_data_valid` are hoisted to wrapper outputs for TB monitoring. In production silicon, the pad ring does not expose them. A DV engineer must observe internal state by other means.

**Two methods — name and explain each:**

#### Method 1 — SystemVerilog `bind`

`bind` is a non-intrusive way to attach a checker, monitor, or assertion module to an instance **without modifying the target RTL**.

```systemverilog
// In the testbench:
bind i2c_slave_controller slave_monitor u_mon (
  .clk          (clk),
  .reg_bank     (reg_bank),       // hierarchical access into the controller
  .addr_match   (addr_match),
  .rx_data_valid(rx_data_valid)
);
```

The `bind` directive elaborates `slave_monitor` as if it were instantiated inside `i2c_slave_controller`. The monitor can then read internal signals directly. The RTL file is untouched — synthesis ignores the `bind` (it is testbench-only).

**Pros:**
- Zero RTL pollution.
- Survives RTL refactors (as long as signal names persist).
- Standard, widely-supported (VCS, Questa, Xcelium).
- Allows SVA, coverage, and functional monitors to be attached cleanly.

**Cons:**
- Signal renames in the DUT break the bind.
- Requires the DV engineer to know internal signal names.

#### Method 2 — Hierarchical probes (cross-module references)

Use dotted hierarchical paths from the TB:

```systemverilog
initial begin
  forever @(posedge clk) begin
    $display("reg_bank[3] = %h", tb_top.u_dut.slave_core.reg_bank[3]);
  end
end
```

This is the simplest method — TB code reaches into the DUT's hierarchy with `.` separators. Synthesis tools ignore it (testbench only).

**Pros:**
- Trivial to use for quick observation.
- No infrastructure setup.

**Cons:**
- Tightly coupled to hierarchy — any RTL refactor breaks it.
- Some shops disallow cross-module refs in strict UVM environments.
- Read-only typically; for writes you need `force`.

#### Bonus methods (for completeness)

3. **`force` / `release`** — TB overrides internal signal values:
   ```systemverilog
   force u_dut.slave_core.reg_bank[3] = 8'hAA;
   #100;
   release u_dut.slave_core.reg_bank[3];
   ```
   Useful for fault injection. Avoided in production DV because it breaks coverage.

4. **DPI-C (Direct Programming Interface for C)** — Export internal state via a C function called from RTL. Mostly used for high-throughput data export (e.g., dumping a frame buffer to a file via C).

5. **Probe/extract files (tool-specific)** — Some simulators support runtime probe insertion via TCL commands without RTL changes.

> **Interview-grade answer:**
> *"In real silicon you would not pin internal state out to the boundary. The two standard DV methods are (1) SystemVerilog `bind`, which attaches a monitor module to an internal instance without modifying RTL — clean and refactor-resilient; and (2) hierarchical references, where the TB reads internal signals via dotted paths like `dut.core.reg_bank` — simple but fragile to refactors. For fault injection rather than just observation, `force`/`release` lets the TB override internal nodes. DPI-C is used for high-bandwidth data export. The wrapper-output-port approach in this project is a teaching shortcut, not industry practice."*

---

### Q8 — Why asymmetric parameterization (slave parameterized, master not)?

**Short answer: intentional, driven by usage pattern.**

**Slave is parameterized because:**
- I2C buses host multiple slaves on the same wires.
- Each slave needs a unique 7-bit address.
- Same RTL instantiated multiple times with different `SLAVE_ADDR` is DRY.
- Parameterization is the natural way to express "this is the same kind of thing, just configured differently."

**Master is not parameterized because:**
- I2C has typically one master per bus (in single-master mode, which this project is).
- The master does not need a per-instance configurable "identity" — there is only one.
- All timing (`T_SCL_PERIOD`, `MAX_CLK_STRETCH`, etc.) comes from `i2c_pkg.sv` — the project decided to centralize timing in the package, not per-module.

**Is the asymmetry a flaw?**

No. It mirrors the **real-world asymmetry** of the bus role:
- Slaves are addressable, so they have an "address parameter."
- Masters are not addressable in single-master, so they have no "identity parameter."

**Could the master be more parameterized?**

Sure, in a real design the master might expose:
- `parameter int FIFO_DEPTH` for the data FIFO size.
- `parameter int CLOCK_DIVIDER_W` for the SCL divider width.
- `parameter logic [7:0] DEFAULT_SCL_DIVISOR` for power-on default.

This project does not, which is a simplification valid for educational scope. **Not a flaw — a scope decision.**

> **Interview-grade answer:**
> *"It is intentional, not a flaw. The slave is parameterized because I2C is a multi-slave bus and each slave needs a unique address — parameterization lets one RTL serve many instances. The master is unique on a single-master bus, so it has no identity parameter. All timing constants are centralized in `i2c_pkg.sv` as the single source of truth, which is why the master wrapper does not duplicate them as parameters. In a more general design you would add parameters for FIFO depth, clock divider, etc., but the asymmetry of master-vs-slave parameterization reflects the asymmetry of their roles."*

---

### Q9 — Style inconsistency between wrappers

**Yes, it is a problem.** Not a functional bug, but a code-review issue worth fixing.

**The inconsistency:**

- `i2c_master.sv` uses `.clk(clk)` (named-explicit).
- `i2c_slave.sv` uses `.clk` (named-implicit).

**Why it matters:**

1. **Codebase coherence** — a project that mixes styles signals lack of review discipline. Reviewers waste mental cycles deciding which file follows the standard.
2. **Tool linting** — most lint flows have ONE preferred style and warn on the other. Mixed code generates warnings.
3. **Auto-formatter chaos** — some formatters convert one style to the other; mixed code produces unstable diffs.
4. **Onboarding friction** — new team members ask "which style do we use?" There should be one answer.

**How to fix in a code review:**

**Step 1 — Pick the standard.** For NVIDIA-style work, that means **named-explicit**: `.port(signal)`.

**Step 2 — Refactor the slave wrapper:**

```systemverilog
// BEFORE
i2c_slave_controller
#(
  .SLAVE_ADDR(SLAVE_ADDR)
)
slave_core
(
  .clk,
  .rst_n,
  .scl,
  ...
);

// AFTER
i2c_slave_controller #(
  .SLAVE_ADDR(SLAVE_ADDR)
) slave_core (
  .clk            (clk),
  .rst_n          (rst_n),
  .scl            (scl),
  .sda            (sda),
  .reg_bank       (reg_bank),
  .reg_updated    (reg_updated),
  .addr_match     (addr_match),
  .active         (active),
  .stretch_en     (stretch_en),
  .stretch_cycles (stretch_cycles),
  .force_data_nack(force_data_nack),
  .rx_data_valid  (rx_data_valid),
  .rx_data        (rx_data),
  .tx_ack         (tx_ack),
  .tx_nack        (tx_nack),
  .bus_error      (bus_error)
);
```

**Step 3 — Add a lint rule** to the project's lint config (e.g., Verilator, Spyglass, Verissimo, Ascent Lint) that forbids implicit connections going forward.

**Step 4 — Document the standard** in a `CODING_STYLE.md` or in the project README.

> **Interview-grade answer:**
> *"It is a code-review issue. Both styles compile, but mixing them signals lack of discipline and causes lint warnings. The fix is to unify on named-explicit `.port(signal)` form, refactor the slave wrapper, and add a lint rule preventing regression. Pick one style, document it, enforce it through tooling. This is a low-effort, high-signal cleanup that demonstrates ownership during a code review."*

---

### Q10 — `inout wire` vs `inout logic`

**The short answer:** `inout logic` is **either illegal or restrictive** depending on SV revision, and it cannot model multi-driver behavior.

**Detailed breakdown:**

#### Why `wire` is mandatory for I2C

`wire` is a **net type**. It supports:
- Multiple concurrent drivers.
- Built-in 4-state resolution (`0`, `1`, `x`, `z`).
- Strength-based resolution (pull-up vs strong driver).
- Continuous assignment from multiple sources.

These are **exactly** the semantics I2C needs:
- Multiple drivers (master + slave + others) on the same SCL and SDA.
- High-impedance `1'bz` from a released driver.
- Pull-up resolves `1'bz` to `1'b1`.

#### Why `logic` would not work

`logic` is a **variable type** (4-state). It supports:
- A single procedural driver (an `always` block) OR a single continuous driver.
- NOT multiple concurrent drivers.

If you declare `inout logic sda;`:
- IEEE 1800-2012 allows `inout logic` only at the **port** level, with restrictions on internal usage.
- Most synthesis tools accept it but treat it as a single-driver variable.
- If both master and slave try to drive it, you get a **multiple-driver error** at elaboration, not a wired-AND.

#### What `inout logic` would do differently in simulation

Three possibilities depending on the tool and exact usage:

1. **Elaboration error** — most common: tool refuses to compile a multi-driver `logic`.

2. **"Last-writer-wins" semantics** — some tools accept it and use procedural ordering: whichever process last assigned to the variable wins. This is wrong for I2C and produces simulation-only behavior that does not match silicon.

3. **Race-condition warning** — tool warns about non-determinism and proceeds with an undefined resolution. Simulation results depend on simulator implementation.

**None of these is wired-AND.** None of them models open-drain correctly.

#### A useful mental model

| Type | Drivers allowed | Resolution | I2C OK? |
|---|---|---|---|
| `wire` | Multiple | Wired-AND with strengths | YES |
| `logic` | One | None — single-driver only | NO |
| `tri` | Multiple | Same as `wire`, alias | YES |
| `wand` | Multiple | Explicit wired-AND | YES (alternative) |
| `wor` | Multiple | Wired-OR | No (wrong polarity) |

You could use `tri` or `wand` instead of `wire` — they have the same behavior. `wire` is conventional for I2C because it is the most generic net type and tool support is universal.

> **Interview-grade answer:**
> *"I2C needs multi-driver semantics — master and slave both drive the same bus, releasing to `1'bz` when not driving, with an external pull-up resolving to `1'b1`. Only `wire` (or its aliases `tri`, `wand`) supports multiple concurrent drivers and 4-state resolution. `logic` is a variable type with single-driver semantics — declaring `inout logic sda` either fails elaboration with a multi-driver error or produces undefined last-writer-wins behavior that does not match silicon. The wired-AND of an open-drain bus is impossible to model with `logic`. So `inout wire` is mandatory; `inout logic` is wrong."*

---

## 9. Key Takeaways

### Conceptual

1. **Wrappers and controllers serve different jobs.** Wrappers are the stable contract with the outside world; controllers are the swappable implementation. Always frame your hierarchy in those terms.

2. **`inout wire` is mandatory for open-drain busses.** `logic` cannot model multi-driver behavior. This is the single most important SV typing decision in I2C/SMBus/MDIO/1-Wire.

3. **`1'bz` means "I am not driving."** It is the SV representation of high-impedance. Combined with a pull-up, it resolves to `1'b1`. Without the pull-up, the wire floats and produces `1'bz` everywhere — common simulation bug.

4. **Packed vs unpacked dimensions follow a convention: packed descending, unpacked ascending.** `logic [WIDTH-1:0] sig [0:DEPTH-1]`. Memorize this and never break it without a justification.

5. **Verification-only ports are real and necessary.** Fault injection (`force_data_nack`, `stretch_en`) is a standard DV technique. Production silicon hides these behind `ifdef` or test-mode CSRs.

6. **Internal-state visibility in real silicon is via `bind`, hierarchical refs, force/release, or DPI-C — not port output.** Knowing this distinguishes a fresher from someone who has worked on production-scale DV.

7. **Parameterization should match the hardware role.** Slaves are addressable so they have an address parameter. Masters in single-master mode have no identity, so no identity parameter.

8. **Named-explicit port connections are the only acceptable style for production silicon.** Implicit `.name` connections are banned in every NVIDIA-tier coding standard.

### Career-critical

- **Q1, Q3, Q6, Q10 are interview classics.** If you cannot articulate open-drain bus modeling, packed/unpacked arrays, and named-vs-implicit ports in under 60 seconds each, you will be filtered out by a competent screener.

- **Q7 is the differentiator.** Knowing that real DV uses `bind`/hierarchical-refs instead of TB-output-ports is what separates someone who has only done academic labs from someone who could ship to a real project. Even saying "I'm aware these visibility ports would not exist on real silicon" in an interview signals maturity.

- **Q4 (address collision) and Q5 (parameter override strategy) test your systems thinking.** They are not pure RTL questions; they are *how-would-you-debug-and-handle-this* questions. Practice answering them.

- **The wrapper file looks "easy" but is dense with interview material.** Do not skim. Every port type and connection style is an interview question waiting to be asked.

- **Adding a coding-standard document and lint config to this project is the highest-ROI cleanup you can do.** It demonstrates judgment, not just coding ability.

---

## 10. Action Items

- [ ] Re-read this entire file weekly for the next 4 weeks. Force recall on each table.
- [ ] Re-do the 10-question quiz **without looking** in 3 days. Aim for 8/10 correct.
- [ ] Draw the open-drain bus resolution table from memory on paper. Repeat in 1 week.
- [ ] Write a 2-line `assign` statement in a scratch file that models open-drain output for SDA. Verify it compiles in EDA Playground.
- [ ] Refactor `i2c_slave.sv` to use named-explicit port connections (Q9 fix). Diff it against the original; commit with a "style: unify port-connection syntax" message.
- [ ] Add a lint config file (e.g., `lint.cfg` for Verible, or `.svlint.toml`) banning implicit port connections. Document in README.
- [ ] Write a `bind`-based monitor that observes `reg_bank` from outside the slave wrapper without using the output ports. Compare with current observation method.
- [ ] Add `` `ifndef SYNTHESIS`` guards around the slave's verification-only ports as a refactor. Confirm simulation still works.
- [ ] **(Stretch)** Add an override parameter `MAX_CLK_STRETCH_OVR` to the master wrapper (Q5 Option B). Use it from a test to shorten timeout.
- [ ] **(Stretch)** When you reach UVM RAL training, return here and replace the ad-hoc CPU interface in `i2c_master.sv` with a `uvm_reg_block`.

---

## 11. Honest Self-Score Template

Fill this in **after** attempting the quiz without notes. Be brutally honest — partial credit means partial recall.

| Area | Score | Status | Notes |
|---|---|---|---|
| Q1 — `inout wire`, `1'bz`, bus resolution |   |   |   |
| Q2 — Fault injection / stimulus controllability |   |   |   |
| Q3 — Packed vs unpacked array, total bits |   |   |   |
| Q4 — Address collision, wired-AND of read data |   |   |   |
| Q5 — Parameter override strategy for sim |   |   |   |
| Q6 — Named vs implicit connection risks |   |   |   |
| Q7 — `bind`, hierarchical refs, force/release |   |   |   |
| Q8 — Master/slave parameterization asymmetry |   |   |   |
| Q9 — Style inconsistency code-review fix |   |   |   |
| Q10 — `inout wire` vs `inout logic` |   |   |   |
| Wrapper/controller pattern articulation |   |   |   |
| Open-drain `assign sda = ... ? 1'b0 : 1'bz;` (write from memory) |   |   |   |

**Scoring scale:**
- 100% — Could teach it to a junior in your team.
- 75% — Could answer cleanly in an interview with minor stumbles.
- 50% — Right instinct, missing senior framing or one key detail.
- 25% — Recognize the question, cannot articulate fully.
- 0% — New material or got it wrong.

**Status codes:**
- Strong — leave alone for 4 weeks.
- Partial — review in 1 week.
- New — review in 3 days.
- Wrong — review TOMORROW and re-quiz.

---

*End of Lesson 02. Next planned lesson: `03_i2c_master_controller_walkthrough.md` (FSM deep dive).*
