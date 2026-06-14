# Lesson 06 — `i2c_if.sv` and `i2c_slave_if.sv` Deep Dive

**Files under study:**
- `tb/i2c_if.sv` (108 lines, master-side bus interface)
- `tb/i2c_slave_if.sv` (72 lines, slave-side control/status interface)

**Concepts covered:** SystemVerilog interfaces, clocking blocks, input/output skew, `#1step`, modports, virtual interfaces, `config_db` for vif distribution, modelling `inout` open-drain bus with drive strengths, race-free TB sampling, embedded utility tasks, interface-as-DUT-port-bundle.

**Date:** 2026-05-17

---

## Table of Contents

1. [Why Interfaces Exist — The Pre-SV Pain](#1-why-interfaces-exist--the-pre-sv-pain)
2. [Architecture — Where Interfaces Sit](#2-architecture--where-interfaces-sit)
3. [The 60-Second Elevator Pitch](#3-the-60-second-elevator-pitch)
4. [Walkthrough of `i2c_if.sv`](#4-walkthrough-of-i2c_ifsv)
5. [Walkthrough of `i2c_slave_if.sv`](#5-walkthrough-of-i2c_slave_ifsv)
6. [Clocking Block Deep-Dive — Skew, `#1step`, Race-Free TBs](#6-clocking-block-deep-dive)
7. [Modports — Declarative Direction Per Role](#7-modports--declarative-direction-per-role)
8. [Virtual Interfaces and `config_db` Plumbing](#8-virtual-interfaces-and-config_db-plumbing)
9. [Quiz — 10 Questions](#9-quiz--10-questions)
10. [Quiz — Answers & Senior-Grade Explanations](#10-quiz--answers--senior-grade-explanations)
11. [Key Takeaways](#11-key-takeaways)
12. [Action Items](#12-action-items)
13. [Honest Self-Score Template](#13-honest-self-score-template)

---

## 1. Why Interfaces Exist — The Pre-SV Pain

Before SystemVerilog interfaces (i.e., back in Verilog-2001 land), connecting a testbench to a DUT meant doing this:

```verilog
// The bad old days
module tb_top;
  wire        sda;
  wire        scl;
  wire        clk;
  wire        rst_n;
  wire [7:0]  apb_pwdata;
  wire [7:0]  apb_prdata;
  wire        apb_pwrite;
  wire        apb_psel;
  wire        apb_penable;
  wire [2:0]  apb_paddr;
  // ... 30 more signals

  i2c_dut u_dut (
    .sda(sda), .scl(scl), .clk(clk), .rst_n(rst_n),
    .pwdata(apb_pwdata), .prdata(apb_prdata),
    .pwrite(apb_pwrite), .psel(apb_psel), .penable(apb_penable),
    .paddr(apb_paddr) // ... 30 more
  );

  bfm_driver u_drv (
    .sda(sda), .scl(scl), .clk(clk), .rst_n(rst_n),
    .pwdata(apb_pwdata), .prdata(apb_prdata),
    .pwrite(apb_pwrite), .psel(apb_psel), .penable(apb_penable),
    .paddr(apb_paddr) // ... 30 more again
  );
endmodule
```

Every signal listed **three times**: once as a wire declaration, once in the DUT port-map, once in the driver port-map. Add a new signal? Three edits. Rename a signal? Three edits. Miss one? Silent disconnection bug.

This is what a **port-bundling explosion** looks like, and it gets exponentially worse with AXI (50+ signals), PCIe (hundreds), and DDR (also hundreds).

### Enter the `interface` Construct

A SystemVerilog `interface` is, mechanically, a **named bundle of signals plus optional behaviour**. Once defined, you instance it ONCE and pass the **single handle** wherever the bundle is needed.

```systemverilog
i2c_if vif (.clk(clk), .rst_n(rst_n));         // declare once
i2c_dut u_dut (.sda(vif.sda), .scl(vif.scl));  // DUT taps into it
// Driver/monitor receive a virtual interface handle — no port-map at all
```

Net win:
- **One source of truth** for the signal bundle.
- **Type safety** — the interface declaration documents the signals' widths and types.
- **Encapsulation** — utility tasks like `wait_bus_free()` live with the signals they manipulate.
- **Modports** — you declaratively restrict who can drive what, per role.
- **Clocking blocks** — you make sampling and driving race-free at the language level.

This is why every modern verification environment, UVM or not, builds around interfaces. **No exceptions.**

### Interface vs Module — One Critical Distinction

An interface and a module **look identical** in syntax — both have ports, both can contain `always` blocks, tasks, functions, even instances. So what's the difference?

| Feature | `module` | `interface` |
|---|---|---|
| Can be instanced | Yes | Yes |
| Can be a virtual handle (vif) | No | Yes |
| Can have modports | No | Yes |
| Can have clocking blocks | Yes (rarely useful) | Yes (idiomatic) |
| Synthesizable | Yes | Synthesizable subset only (no clocking/modports survive) |
| Intent | Functional design block | Signal-bundle container |

**The single biggest reason interfaces exist:** the **virtual interface** handle. You cannot have a `virtual module` — but you can have a `virtual i2c_if`, and that handle is what every UVM driver and monitor in your project carries.

---

## 2. Architecture — Where Interfaces Sit

```
   +--------------------------------------------------+
   |  tb_top.sv  (the simulation root module)         |
   |                                                  |
   |   logic clk, rst_n;                              |
   |                                                  |
   |   i2c_if       vif       (.clk, .rst_n);  <--+   |
   |   i2c_slave_if slv_vif   (.clk, .rst_n);  <--|--+|
   |                                              |  ||
   |   i2c_dut_top u_dut (                        |  ||
   |     .sda  ( vif.sda ),       <-- physical    |  ||
   |     .scl  ( vif.scl ),           wires       |  ||
   |     .clk  ( clk ),                           |  ||
   |     .rst_n( rst_n ),                         |  ||
   |     .stretch_en    ( slv_vif.stretch_en ),   |  ||
   |     .reg_bank      ( slv_vif.reg_bank   ),   |  ||
   |     ...                                      |  ||
   |   );                                         |  ||
   |                                              |  ||
   |   initial begin                              |  ||
   |     uvm_config_db#(virtual i2c_if)::set( ----+  ||
   |       null, "uvm_test_top.env.*", "vif", vif); ||
   |     uvm_config_db#(virtual i2c_slave_if)::set(--+|
   |       null, "uvm_test_top.env.*", "slv_vif",    |
   |       slv_vif);                                 |
   |     run_test();                                 |
   |   end                                           |
   +-------------------------|------------------------+
                             |
                             v  (UVM hierarchy below)
                +----------------------------+
                |  uvm_test_top              |
                |   env                      |
                |    master_agent            |
                |      driver  <-- get(vif)  |
                |      monitor <-- get(vif)  |
                |    slave_agent             |
                |      driver  <-- get(slv_vif)
                |      monitor <-- get(slv_vif)
                +----------------------------+
```

Reading this top-down:

1. **`tb_top`** is a normal module. It owns the clock, reset, the DUT instance, and the interface instances.
2. **Interfaces are instanced as concrete objects** at the testbench root — exactly like a module.
3. **The DUT port-map taps individual fields** of the interface (`vif.sda`, `slv_vif.reg_bank`, etc.). The DUT itself has **no idea** an interface exists — it just sees nets connected to its pins.
4. **`uvm_config_db::set`** publishes the interface handle (as a `virtual i2c_if`) under a string key so any UVM component can retrieve it.
5. **Drivers and monitors `get`** the handle in `build_phase` and from then on use `vif.driver_cb.sda_drv <= 1'b0;` to drive, `vif.monitor_cb.sda` to sample.

The mental model: **the interface is the chrome connector between the DUT pin domain and the UVM object-oriented domain.** Pins go in one side as `wire`, UVM components come out the other side as `virtual` handles.

---

## 3. The 60-Second Elevator Pitch

When the interviewer says: *"Walk me through how your testbench connects to the DUT,"* you say:

> *"My I2C testbench uses two SystemVerilog interfaces. The first, `i2c_if`, carries the open-drain SDA and SCL bus with proper wired-AND resolution modelled using drive strengths — `strong0/weak1` pull-downs plus weak pull-ups on the wire. The second, `i2c_slave_if`, carries the slave control and status signals — stretch enable, register bank, address-match, and error flags. Each interface has driver and monitor clocking blocks with `#1step` input skew so the testbench samples DUT outputs at the very end of the previous time step, eliminating zero-time race conditions. Modports declaratively restrict direction per role: the driver modport exposes the output clocking, the monitor modport exposes a passive sampling block. At `tb_top`, I `uvm_config_db::set` the virtual interface handles, and every UVM driver and monitor `get`s them in their `build_phase`. If the `get` returns false I `uvm_fatal` — that's the single most common UVM connection bug, and you must catch it at build time, not at the first null-pointer dereference in `run_phase`."*

Memorize the **shape**: two interfaces, why each exists, clocking blocks for race-freedom, modports for role-isolation, config_db for distribution, fatal on missing vif.

---

## 4. Walkthrough of `i2c_if.sv`

### 4.1 Header and Include Guard (lines 1-11)

```systemverilog
`ifndef I2C_IF_SV
`define I2C_IF_SV

interface i2c_if (
  input logic clk,
  input logic rst_n
);
```

Same include guard pattern as the package — see lesson 01 if rusty. The interface takes `clk` and `rst_n` as **ports**, not as internal signals. This is the idiomatic pattern: the clock is owned by `tb_top` (or generated outside), and the interface receives it. **Never** generate the clock inside an interface — you would couple every consumer of the interface to that clock's frequency.

### 4.2 Bus Signal Declarations — `wire` not `logic` (lines 17-26)

```systemverilog
wire sda;
wire scl;

// Pull-ups (open-drain idle = HIGH)
assign (weak1, highz0) sda = 1'b1;
assign (weak1, highz0) scl = 1'b1;
```

**Critical detail.** SDA and SCL are declared as `wire`, **not `logic`**, because I2C is an **open-drain wired-AND bus** with multiple drivers. The bus value at any instant is the resolution of:
- Master pulling down (or releasing high-Z)
- Slave pulling down (or releasing high-Z, for ACK and clock-stretching)
- Pull-up resistor to VDD

In SV, `logic` is a **single-driver** type — connecting two `logic` drivers triggers a compile error or yields `X`. `wire` is a **multi-driver net** with built-in resolution rules. For a wired-AND bus you **must** use `wire`.

The pull-up is modelled with `assign (weak1, highz0)` — meaning "drive a weak 1, or release to high-Z if assigned `1'bz`." This emulates the physical pull-up resistor.

**Interview trap:** *"Why not just use `logic sda; logic scl;`?"*
> *"I2C is multi-driver — the master drives, the slave drives during ACK and stretch, and arbitration requires both drivers to be active simultaneously. `logic` is single-driver; assigning from two places gives X or a compile error depending on the simulator. `wire` resolves multiple drivers per the standard 4-state table, which is exactly what we need to model wired-AND."*

### 4.3 Open-Drain Driver Proxies (lines 28-37)

```systemverilog
logic sda_drv;
logic scl_drv;

assign (strong0, weak1) sda = (sda_drv == 1'b0) ? 1'b0 : 1'bz;
assign (strong0, weak1) scl = (scl_drv == 1'b0) ? 1'b0 : 1'bz;
```

These are the **proxy signals** that the UVM driver actually writes to. The pattern is:
- Driver wants to pull down → set `sda_drv = 0`. The continuous assignment then drives `(strong0, weak1)` onto `sda`, with the ternary producing `1'b0`.
- Driver wants to release → set `sda_drv = 1`. The ternary produces `1'bz`. The pull-up's `weak1` then wins on the wire, so `sda` resolves to `1'b1`.

The drive strengths are doing the real work:
- `strong0` — when pulling low, do so with strong drive (overpowers anything weaker).
- `weak1` — when releasing high, drive with weak strength (loses to the pull-up's `weak1`... but they're equal, so the value is high either way; the important part is it doesn't fight a competing pull-down).

This is **the canonical way to model open-drain in SV**. Memorize it.

**Why use proxies instead of letting the driver write `sda` directly?**
- `sda` is a `wire` — you cannot procedurally assign to a wire from a clocking block or `always` block.
- The proxy gives you a `logic` you **can** drive procedurally, and the continuous assignment translates that into a multi-driver-resolved wire contribution.

### 4.4 Competing-Master Hook for Arbitration Tests (lines 39-52)

```systemverilog
logic sda_drv_x;

assign (strong0, weak1) sda = (sda_drv_x == 1'b0) ? 1'b0 : 1'bz;

logic arb_lost;
```

This is **clever**. A third driver on `sda` — `sda_drv_x` — exists specifically so the slave-side UVM driver can pretend to be a second master and pull SDA low during a time when the DUT master expects it to be high. That mismatch triggers arbitration loss in the DUT.

Defaults to `1'b1` (released), so normal tests are unaffected. Only the `arbitration_lost_test` wiggles it. The `arb_lost` flag is a hookpoint for monitors to sample arbitration status if the master RTL exposes such a signal.

**This is bug-T13 verification infrastructure** — you can mention this in interviews as a real-world example of how interfaces extend beyond "just signal bundling" to **enabling specific failure-mode tests**.

### 4.5 Initial Block — Released State (lines 54-60)

```systemverilog
initial begin
  sda_drv   = 1'b1;
  scl_drv   = 1'b1;
  sda_drv_x = 1'b1;
  arb_lost  = 1'b0;
end
```

Every proxy starts in the **released** state (`1`) so the bus idles high. Without this, the proxies would be `X` at time 0, the ternaries would propagate `X`, and the bus would resolve to `X` until the driver started — meaning every test would fail in monitor-init.

**Interview trap:** *"What goes wrong if you forget to initialize the driver proxies?"*
> *"At time 0 the proxies are X, the continuous assignments propagate X onto the bus, and the bus stays X until the first driver write. Any monitor sampling before that point sees X and fails its protocol checks. Always initialize driver proxies to the bus's idle state — for I2C that's released-high, so the proxies are 1."*

### 4.6 Driver Clocking Block (lines 62-72)

```systemverilog
clocking driver_cb @(posedge clk);
  default input #1step output #1;
  output sda_drv;
  output scl_drv;
  input  sda;
  input  scl;
endclocking
```

The driver clocking block is a synchronous "view" onto the bus, anchored to `posedge clk`.

- **`default input #1step output #1`** sets the skews for everything in the block.
  - `input #1step` — when the TB **reads** `sda` or `scl` through `driver_cb`, the value is what the wire had **one simulation time-step before** `posedge clk`. This is the **settled** value, i.e., post-RTL-update but pre-clock-edge.
  - `output #1` — when the TB **writes** `sda_drv` or `scl_drv` through `driver_cb`, the new value is applied **1 time unit after** the clock edge. This emulates the propagation delay of a real flip-flop and prevents zero-time hold violations.

- `output sda_drv, scl_drv` — these are driven by the TB.
- `input sda, scl` — the TB can sample the resolved bus value (useful for ACK detection and arbitration).

Section 6 of this lesson explains skew semantics in much more depth.

### 4.7 Monitor Clocking Block (lines 74-82)

```systemverilog
clocking monitor_cb @(posedge clk);
  default input #1step;
  input sda;
  input scl;
endclocking
```

**Passive — input only.** A monitor must **never** drive. If it does, you've conflated checking with stimulating, which violates the UVM separation-of-concerns and corrupts coverage. By making monitor_cb input-only, the language itself enforces "monitor cannot drive."

`#1step` again — sample the settled value just before `posedge clk`.

### 4.8 Embedded Utility Tasks (lines 84-97)

```systemverilog
task automatic wait_bus_free();
  @(posedge clk);
  wait (sda === 1'b1 && scl === 1'b1);
endtask

task automatic wait_n_clocks(input int n);
  repeat(n) @(posedge clk);
endtask
```

**Tasks inside the interface itself.** This is legal and idiomatic — the interface becomes more than a passive signal-bundle; it's a **stateful object** offering reusable bus-level primitives. Every driver, monitor, sequence, or test can call `vif.wait_bus_free()` without duplicating the wait logic.

Notice **`automatic`** — same rationale as the package's functions (lesson 01, Q5). Multiple parallel callers must not corrupt each other's locals.

**Design choice to know:** some shops keep tasks **out** of the interface, putting them in a "BFM" package or driver class instead. Pros: keeps the interface dumb and reusable across projects. Cons: more boilerplate. This project bundles them in; both styles are valid.

### 4.9 Modports (lines 100-104)

```systemverilog
modport master_mp  (clocking driver_cb,  input clk, rst_n);
modport monitor_mp (clocking monitor_cb, input clk, rst_n);
modport dut_mp     (inout sda, inout scl, input clk, rst_n);
```

Three modports, three roles:

1. **`master_mp`** — used by the master-side UVM driver. Exposes `driver_cb` (which can output the proxies), and read-only access to `clk`/`rst_n`. The driver cannot directly poke `sda_drv` outside the clocking block — it must go through `driver_cb.sda_drv`, which enforces the output skew.
2. **`monitor_mp`** — used by the master-side UVM monitor. Exposes only `monitor_cb` (input-only). The monitor structurally **cannot drive**.
3. **`dut_mp`** — used by the DUT RTL module instance. Exposes `sda` and `scl` as `inout` ports (because the DUT must be able to drive and sample them), plus `clk`/`rst_n` as inputs.

Section 7 covers modport semantics in detail.

---

## 5. Walkthrough of `i2c_slave_if.sv`

### 5.1 Purpose — What This Interface Is Not

This interface is **not the bus**. The actual SDA/SCL bus is already in `i2c_if`. `i2c_slave_if` carries everything else the slave UVM agent needs to **observe and reactively configure** the slave DUT:

- **Stretch control inputs** — testbench tells the slave when and how long to stretch the clock.
- **Slave status outputs** — register bank, address match, RX data, ACK/NACK, bus error.

Think of `i2c_if` as the **bus pins** and `i2c_slave_if` as the **slave's debug/control sidechannel**. In silicon this would be tied to a debug bus or scan chain; in simulation it's a clean SV interface.

### 5.2 Header and Ports (lines 1-16)

```systemverilog
`ifndef I2C_SLAVE_IF_SV
`define I2C_SLAVE_IF_SV

interface i2c_slave_if (
  input logic clk,
  input logic rst_n
);
```

Same boilerplate pattern. Clock and reset are inputs from the outside.

### 5.3 Slave Control Inputs (lines 18-20)

```systemverilog
logic        stretch_en;
logic [15:0] stretch_cycles;
logic        force_data_nack;
```

These are **driven by the testbench** into the slave DUT:

- **`stretch_en`** — when high, the slave should clock-stretch (hold SCL low) for `stretch_cycles` system-clock ticks before releasing.
- **`stretch_cycles`** — 16-bit count. Range: 0 to 65535 ticks. At 50 MHz that's up to ~1.3 ms of stretch.
- **`force_data_nack`** — when high, the slave NACKs the next data byte even if it could have ACKed. Used for error-injection tests.

These are all **single-driver** TB-to-DUT inputs, so `logic` is correct (no multi-driver resolution needed).

### 5.4 Slave Status Outputs (lines 22-30)

```systemverilog
logic [7:0]  reg_bank     [0:7];
logic        reg_updated  [0:7];
logic        addr_match;
logic        active;
logic        rx_data_valid;
logic [7:0]  rx_data;
logic        tx_ack;
logic        tx_nack;
logic        bus_error;
```

- **`reg_bank [0:7]`** — the slave's 8-byte register file, exposed as an unpacked array for monitor scoreboarding.
- **`reg_updated [0:7]`** — one-cycle pulse per register when written. Lets the monitor detect "register N was written" without polling.
- **`addr_match`** — slave asserted because the master's address byte targeted this slave.
- **`active`** — slave is currently in a transaction (between START and STOP).
- **`rx_data_valid` / `rx_data`** — handshake for "I just received this byte."
- **`tx_ack` / `tx_nack`** — slave's ACK/NACK decision pulse, sampled by the monitor.
- **`bus_error`** — protocol violation flag.

These are **slave-to-TB outputs** — single-driver, again `logic`.

### 5.5 Initialization (lines 32-36)

```systemverilog
initial begin
  stretch_en      = 1'b0;
  stretch_cycles  = 16'd0;
  force_data_nack = 1'b0;
end
```

Initialize the **TB-driven inputs** to "do nothing." Status outputs are driven by the DUT, so they don't need TB-side initialization.

### 5.6 Slave Clocking Block (lines 38-52)

```systemverilog
clocking slave_cb @(posedge clk);
  default input #1step output #1;
  output stretch_en;
  output stretch_cycles;
  output force_data_nack;
  input  reg_bank;
  input  reg_updated;
  input  addr_match;
  input  active;
  input  rx_data_valid;
  input  rx_data;
  input  tx_ack;
  input  tx_nack;
  input  bus_error;
endclocking
```

Outputs from the TB's perspective: `stretch_en`, `stretch_cycles`, `force_data_nack`. The slave UVM driver writes these.
Inputs from the TB's perspective: all the status signals. The slave UVM monitor (and driver, reactively) samples these.

Skews same as the master interface — `#1step` for race-free sampling, `#1` for write-after-edge propagation modelling.

### 5.7 Monitor Clocking Block (lines 54-65)

```systemverilog
clocking monitor_cb @(posedge clk);
  default input #1step;
  input reg_bank;
  ...
endclocking
```

Passive, input-only — same pattern as the master-side monitor. Monitor cannot drive.

### 5.8 Modports (lines 67-68)

```systemverilog
modport slave_mp   (clocking slave_cb,    input clk, rst_n);
modport monitor_mp (clocking monitor_cb,  input clk, rst_n);
```

Two roles only:
- **`slave_mp`** — slave UVM driver (drives stretch controls, samples status).
- **`monitor_mp`** — slave UVM monitor (passive sample).

**Note:** there is no `dut_mp` here. Why? Because the **DUT slave RTL** taps individual signal fields directly (e.g., `.stretch_en (slv_vif.stretch_en)`), not through a modport. The DUT doesn't need direction-restriction enforcement — those signals were chosen by the DUT's port direction, not by the interface. Modports exist mainly to constrain **testbench components**, where the same interface can be used by multiple roles.

---

## 6. Clocking Block Deep-Dive

This is the section that separates juniors from people who actually understand UVM. Read it twice.

### 6.1 The Race Problem — Why Clocking Blocks Exist

Without a clocking block, this seemingly innocent driver code is a **race condition**:

```systemverilog
always @(posedge clk) begin
  sda_drv <= driver_value;   // TB drives at posedge
end

// And elsewhere, the DUT
always @(posedge clk) begin
  internal_reg <= sda_drv;   // DUT samples at posedge
end
```

Both events happen at the **same simulation time**. Per IEEE 1800 LRM, non-blocking assignments are scheduled into the **NBA region**, but the order of multiple NBAs at the same time is **unspecified**. Half your simulator runs sample the old value; half sample the new. The bug appears intermittently. You waste a week.

Clocking blocks fix this by **explicitly specifying when** the TB reads and writes relative to the clock edge.

### 6.2 The Five Skew Quantities You Must Know

| Name | Type | Meaning |
|---|---|---|
| **input skew (positive #N)** | absolute lookback | TB sees the value that was on the signal `#N` time units **before** the clock edge |
| **input skew `#1step`** | special | TB sees the value at the very end of the **previous** time step (post-RTL, pre-edge) |
| **output skew #N** | absolute lookahead | TB-written value appears on the signal `#N` time units **after** the clock edge |
| **default input** | inherited | applies to every `input` signal in the block unless overridden |
| **default output** | inherited | applies to every `output` signal in the block unless overridden |

**Both interfaces in this project use `default input #1step output #1`.** Let's unpack each.

#### Input Skew `#1step` — The Senior-Grade Choice

`#1step` is a special skew meaning **"one simulation precision step before the clock edge."** It is intentionally tinier than any positive time unit. The effect: the TB samples the signal at the **very last moment** before `posedge clk`, after all RTL non-blocking assignments from the previous cycle have settled.

This is the **race-free** value. It is what the DUT's flip-flops are "looking at" as they latch. Sampling at exactly this point gives the TB the same view the DUT has.

**Why not `#0`?** `#0` means "in the same time step, after all active events." That's still in the **active region**, where RTL is still updating. You'd race with the RTL.

**Why not `#1`?** `#1` is "one time unit later." But the clock edge is **now** — one time unit later is **after** the edge, which means you'd see the NEW value the RTL just latched. You'd be one cycle ahead of the DUT.

`#1step` is the Goldilocks choice. **Memorize this.**

#### Output Skew `#1` — Drive After the Edge

`#1` output skew means **"the TB-written value appears on the signal 1 time unit after `posedge clk`."** Why is this good?

- It models the **clock-to-Q delay** of a real flip-flop. A real DUT outputs change ~1 time unit after the edge; the TB should too.
- It prevents **zero-time hold violations**. If the TB drove exactly at the edge and the DUT sampled at the edge, the DUT's hold window would be violated.
- It keeps waveforms readable — TB drives show up after the edge in waveform viewers, matching mental model.

#### The Combined Effect

With `input #1step output #1`:

```
Time:           T-Δ           T            T+1
                 |             |             |
RTL settles      |  posedge clk |             |
TB sample here --+             |             |
                               |  TB drive here --+
```

The TB **reads the old value just before the edge** (matching the DUT's view) and **writes the new value just after the edge** (matching real flop behaviour). Race-free in both directions.

### 6.3 What Goes Wrong If You Pick The Wrong Skew

| Mistake | Symptom |
|---|---|
| `input #0` instead of `#1step` | TB samples in active region; races RTL non-blocking updates; tests fail intermittently in some simulators, pass in others |
| `output #0` instead of `#1` | TB drive races DUT sample at the edge; the DUT either sees the new or old value depending on event-list order; "Heisenbug" |
| `input #1` (positive number) instead of `#1step` | TB samples **after** the clock edge; one cycle ahead of DUT; scoreboard mismatches everywhere |
| No clocking block at all | TB drives via `<=` in `always @(posedge clk)`; pure race; unreproducible failures |

### 6.4 The Cycle Domain — `vif.cb.signal <= value`

Once you have a clocking block, you drive and sample through it:

```systemverilog
// Drive — use <= (the clocking block synchronizes it)
vif.driver_cb.sda_drv <= 1'b0;

// Sample — read the .cb-qualified name
logic captured = vif.driver_cb.sda;

// Wait for an edge of the clocking block
@(vif.driver_cb);
```

`@(vif.driver_cb)` is short for `@(posedge clk)` (the event the clocking block is anchored to), but **also** establishes the clocking-block context for any reads in the same statement. The first time you see it in driver code, you'll wonder where the clock came from — this is your answer.

### 6.5 Embedded SVA (Not Present Here — But You Should Know)

Some interfaces embed SystemVerilog Assertions directly:

```systemverilog
property p_sda_stable_when_scl_high;
  @(posedge clk) (scl == 1'b1) |-> $stable(sda);
endproperty
a_sda_stable: assert property (p_sda_stable_when_scl_high)
  else $error("SDA changed while SCL was high");
```

Putting SVA in the interface keeps protocol-level checks **inseparable from the signals they reference**. The pros and cons:

**Pros:** assertions travel with the interface; reusable across projects; bound to the right signals automatically.
**Cons:** clutters the interface; mixes structural and behavioural concerns; harder to maintain in large protocols.

**The current `i2c_if.sv` has NO embedded SVA**, but this is a candidate improvement. Adding assertions for "SDA stable when SCL high" and "START is SDA falling while SCL high" would catch protocol violations earlier than a scoreboard would. **This is a real internship deliverable you could propose.**

---

## 7. Modports — Declarative Direction Per Role

### 7.1 The Core Idea

The **same interface** can be used by multiple components — driver, monitor, DUT — but each role has different needs and different rights. Modports let you say, at the language level: "**This role can only do these things.**"

```systemverilog
modport master_mp  (clocking driver_cb,  input clk, rst_n);
modport monitor_mp (clocking monitor_cb, input clk, rst_n);
modport dut_mp     (inout sda, inout scl, input clk, rst_n);
```

When a UVM driver declares its vif handle as `virtual i2c_if.master_mp vif`, **it can only access what `master_mp` exposes**. Try to read `vif.monitor_cb` — compile error. Try to drive `vif.sda` directly (bypassing the clocking block) — compile error.

### 7.2 Why This Matters — Three Concrete Wins

1. **Architectural enforcement.** The monitor literally **cannot** drive, because `monitor_mp` doesn't expose any outputs or any driver clocking. You can't accidentally write a monitor that drives.

2. **Documentation as code.** When a new engineer reads `modport master_mp (clocking driver_cb)`, they immediately know what the master role is allowed to do. No prose docs needed.

3. **Reusability across projects.** The same `i2c_if` with `master_mp`/`monitor_mp`/`dut_mp` works whether the master is a UVM agent, a directed test, or a bring-up sequence — as long as the role is honored.

### 7.3 Monitor Modport — Why Input-Only

```systemverilog
modport monitor_mp (clocking monitor_cb, input clk, rst_n);
```

`monitor_cb` itself is input-only (it has only `input` directions). Exposing it via the monitor modport means the monitor can sample `monitor_cb.sda` and `monitor_cb.scl`, but **literally has no way to drive anything**. This is **passive monitoring** enforced by the language.

If a monitor ever needs to drive (e.g., for back-pressure injection in a different protocol), you'd add a separate "active monitor" modport or use the driver modport — but you'd be conscious of the change.

### 7.4 DUT Modport — Different Game

```systemverilog
modport dut_mp (inout sda, inout scl, input clk, rst_n);
```

The DUT modport **doesn't use a clocking block**. Why? Because clocking blocks are a testbench-side abstraction — they exist to make TB sampling race-free. The DUT's own RTL has its own internal flip-flops; it samples `sda`/`scl` via standard RTL semantics. Forcing the DUT through a clocking block would distort its timing.

Also: `inout` for `sda` and `scl`. The DUT must drive (during ACK and clock-stretching for a slave; during command bytes for a master) and sample (always). `inout` lets the same port serve both directions, with multi-driver wire resolution handling the contention.

### 7.5 Modport Gotcha — Type Mismatch in vif Handle

```systemverilog
// In the driver:
virtual i2c_if.master_mp vif;   // ← Modport-qualified handle

// In the env:
uvm_config_db#(virtual i2c_if)::set(...);   // ← Unqualified handle being set
```

Mismatch. The `get` will fail at runtime. **The fix:** be consistent. Either both qualified or both unqualified.

Most shops use **unqualified** vifs (`virtual i2c_if`) for simplicity and add modport restrictions only in code that absolutely needs them. The trade-off: less compile-time enforcement, more flexibility.

---

## 8. Virtual Interfaces and `config_db` Plumbing

### 8.1 What `virtual` Means Here

`virtual interface` is **not** a polymorphism keyword like in C++ classes. It's SV-specific syntax meaning **"a reference handle to an interface instance, usable inside class-based code."**

UVM components are **classes**. Classes cannot directly contain `interface` instances (interfaces are static-module-hierarchy citizens, like modules). They can, however, hold a **reference** to an interface instance: that reference is the virtual interface handle.

```systemverilog
class i2c_driver extends uvm_driver;
  virtual i2c_if vif;          // a handle, not an instance
  ...
endclass
```

The handle is **null** until you assign it. That's where `config_db` comes in.

### 8.2 The `config_db` Pattern

The handle assignment is plumbed through UVM's configuration database — a global key-value store keyed on (component-path, string-name).

**At `tb_top` (the actual module that instances the interface):**

```systemverilog
i2c_if vif (.clk(clk), .rst_n(rst_n));

initial begin
  uvm_config_db#(virtual i2c_if)::set(
    null,                       // context (null = global)
    "uvm_test_top.env.*",       // path glob — anyone under env
    "vif",                      // name key
    vif                         // the handle
  );
  run_test();
end
```

**In every UVM component that needs the interface (driver, monitor, etc.):**

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(virtual i2c_if)::get(
        this, "", "vif", vif))
    `uvm_fatal("NOVIF", "Virtual interface not set for ", get_full_name())
endfunction
```

### 8.3 Why `uvm_fatal` and Not `uvm_error`

If the `get` returns false, **`vif` is null**. Any subsequent code that does `vif.driver_cb.sda_drv <= 1'b0;` will dereference null and crash in `run_phase` — often with a confusing "fatal SV runtime error" that hides the real cause.

`uvm_fatal` at the moment of detection stops the simulation immediately with a clear message: "the virtual interface was never set." That's the cheapest possible debug. **Always do this.**

### 8.4 The Single Most Common UVM Connection Bug

```
1. You forget the uvm_config_db::set in tb_top.
2. The driver's get fails.
3. (If you used uvm_error or just ignored the bool) vif stays null.
4. run_phase runs; first vif access crashes.
5. You spend an hour staring at the stack trace.
```

**Prevention checklist:**
- Always set the vif in `tb_top` **before** `run_test()`.
- Always `get` with an `if (!...)` and `uvm_fatal` inside.
- Verify the **path glob** matches the actual component hierarchy. If you `set` to `"uvm_test_top.env.master_agent.*"` but your driver is at `"uvm_test_top.env.master_agt.driver"`, the get fails silently.

### 8.5 Set-Path Globs — Subtle but Crucial

| `set` path glob | Who can `get` it |
|---|---|
| `"uvm_test_top.env.driver"` | only that exact component |
| `"uvm_test_top.env.*"` | any direct child of env (driver, monitor, scoreboard) |
| `"*"` | any component, anywhere |
| `"uvm_test_top.env.master_agent.*"` | only components under master_agent |

Wider globs are easier to set up but pollute the config db. Narrower globs are more discipline but easier to debug. **Common rule: scope as tightly as your component hierarchy allows.**

---

## 9. Quiz — 10 Questions

Cover the answer section. Take 25 minutes. Aim for 7+/10.

1. **What is the fundamental difference between an SV `interface` and a `module`?** Both can have ports and contain logic — so why does the language have both?

2. **Explain `default input #1step output #1` in plain English.** What exactly happens at `posedge clk` for an input and for an output?

3. **What is the purpose of a `modport`?** Give two concrete reasons modports help a testbench beyond "documentation."

4. **What is a `virtual interface`?** Why can't a UVM class hold an `interface` directly?

5. **Walk me through the `config_db` set/get flow for a vif.** Where is `set` called, where is `get` called, and what should happen if `get` returns false?

6. **Why does the `driver_cb` use `#1step` for input skew instead of `#0` or `#1`?** Describe the bug each wrong choice would cause.

7. **In `i2c_if.sv`, `sda` and `scl` are declared as `wire`, not `logic`. Why is this not a stylistic choice?** What would break if you used `logic`?

8. **When is it appropriate to embed SVA inside an interface vs. keeping them in a separate file?** What's the trade-off?

9. **Look at `monitor_mp`. It exposes only `monitor_cb`, and `monitor_cb` has only input directions. Why is this layered restriction valuable — wouldn't a single restriction at either level suffice?**

10. **You're debugging a UVM testbench where `run_phase` crashes on a null-pointer dereference of `vif.driver_cb`. What are the top three root causes you would check, in order?**

---

## 10. Quiz — Answers & Senior-Grade Explanations

### Q1 — Interface vs Module

Both are top-level instantiable constructs with ports, internal signals, and behaviour. The crucial differences:

| Capability | `module` | `interface` |
|---|---|---|
| Held by a virtual handle in a class | No | **Yes** — `virtual i2c_if vif;` |
| Has modports for role-based access control | No | Yes |
| Idiomatic use of clocking blocks | Rare | Standard |
| Intent | A functional design block | A signal-bundle abstraction |

**The single decisive reason interfaces exist:** you cannot have a `virtual module`. UVM classes (driver, monitor, scoreboard) need a handle to the DUT's signals. That handle has to be a **reference type**, and only `virtual interface` gives you that. Without interfaces, UVM as we know it doesn't work.

**Interview-grade answer:**

> *"Modules are functional design blocks; interfaces are signal-bundle abstractions designed specifically to be referenced by class-based code via virtual handles. The killer feature is `virtual interface` — a class-side reference to an interface instance, which UVM drivers and monitors use to access DUT pins. You can't have a `virtual module`, which is why even though the syntax looks similar, the language has both. Modports and clocking blocks are additional interface-specific features that make role separation and race-free TB code possible."*

---

### Q2 — `default input #1step output #1` Plain English

**`default input #1step`**: For every `input` signal in this clocking block, when the TB reads the signal, it sees the value the signal had **at the very last instant before the clock edge** — after all RTL non-blocking updates from the previous cycle settled, but before any current-edge events fire. This is the **race-free, settled** value.

**`default output #1`**: For every `output` signal in this clocking block, when the TB writes a new value, the value appears on the signal **1 time unit after the clock edge**. This models flip-flop clock-to-Q delay and prevents zero-time hold violations on the DUT side.

**Combined at `posedge clk`:**
1. Just before the edge: TB samples inputs (sees settled values).
2. Edge fires.
3. 1 time unit later: TB-driven outputs update on the signal.
4. The DUT's flip-flops latched at the edge using the old TB-driven values (so no race).
5. Next cycle the DUT sees the new TB-driven values.

**Interview-grade answer:**

> *"`#1step` input skew tells the simulator to sample the signal at the very end of the previous time step — after all RTL updates have settled but before the clock edge fires. That gives the testbench the same view the DUT's flip-flops have. `#1` output skew delays TB-driven values by one time unit after the edge, modelling clock-to-Q delay and avoiding hold violations. Together they make the clocking block race-free for both directions of data flow."*

---

### Q3 — Modport Purpose

**Beyond documentation**, two concrete wins:

1. **Compile-time role enforcement.** A monitor declared as `virtual i2c_if.monitor_mp vif` literally cannot drive anything — the modport doesn't expose any outputs or any driver clocking. If a junior engineer adds `vif.sda_drv <= 0` to the monitor by mistake, the compiler rejects it. The architecture is **enforced**, not just documented.

2. **Same interface, multiple coexisting roles.** A master driver, master monitor, and DUT can all reference the same interface instance simultaneously, each through its own modport, each with its own access rights. Without modports you'd either need separate interfaces per role (duplicating signal declarations) or unsafe full-access for everyone.

**Interview-grade answer:**

> *"Modports are role-based access control on interface signals. The two concrete wins beyond documentation are: first, compile-time enforcement — a passive monitor declared with `monitor_mp` can't drive anything because the modport doesn't expose outputs, so misuse is a compile error, not a runtime bug. Second, multi-role coexistence — the driver, monitor, and DUT all bind to the same interface but each sees only the subset of signals appropriate to its role. Without modports you'd either duplicate interfaces or open-access everything and lose the safety net."*

---

### Q4 — Virtual Interface

A `virtual interface` is **a reference handle** to an interface instance, usable inside class-based code. It is **not** related to OOP virtual/polymorphism.

**Why a class can't hold an `interface` directly:** interfaces live in the static module hierarchy — they're instantiated like modules, they have ports connected to other static-hierarchy signals. Classes, by contrast, are dynamic objects created at runtime via `new()` and connected to no hierarchy. The two worlds are mechanically incompatible.

The `virtual interface` keyword bridges them: an interface is statically instanced in the testbench module hierarchy, and a class holds a **reference** (the virtual handle) to that instance. Reads and writes through the handle redirect to the actual instance.

**Interview-grade answer:**

> *"A virtual interface is a reference handle that a class-based UVM component holds to an interface instance that lives in the static module hierarchy. Classes are dynamic objects created with `new` and have no place in the structural module tree; interfaces are hierarchy citizens with ports connected to other hierarchy signals. The virtual handle is the bridge — UVM drivers and monitors hold `virtual i2c_if vif`, assigned via `uvm_config_db`, and dereference it to drive and sample DUT pins."*

---

### Q5 — `config_db` Set/Get Flow

**Set side (in `tb_top` initial block, before `run_test()`):**

```systemverilog
i2c_if vif (.clk, .rst_n);
initial begin
  uvm_config_db#(virtual i2c_if)::set(
    null, "uvm_test_top.env.*", "vif", vif);
  run_test();
end
```

**Get side (in every component that needs the vif, in `build_phase`):**

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(virtual i2c_if)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF",
      $sformatf("vif not set for %s", get_full_name()))
endfunction
```

**On `get` returning false:** the handle is null, **`uvm_fatal` immediately**. Do not continue. Do not warn-and-soldier-on. If you let the component continue, you'll crash later in `run_phase` with a null-dereference error that's much harder to diagnose.

**Interview-grade answer:**

> *"In `tb_top`'s initial block I instantiate the interface and call `uvm_config_db::set` to publish the handle under a path glob like `uvm_test_top.env.*` with the key `vif`. Every UVM component that needs the interface — driver, monitor — calls `uvm_config_db::get` in its `build_phase`. The return value is a bool: false means no matching `set` was found. I always wrap the get in `if (!...) `uvm_fatal(...)` because a missing vif leads to a null-dereference crash in `run_phase`, and catching it at build time gives a clean error message instead of a stack trace from inside the driver."*

---

### Q6 — Why `#1step` for Input Skew

`#1step` samples at the very last simulator time step before the clock edge — after all RTL non-blocking updates settle, before the edge fires. This is the **same value the DUT's flip-flops latch**, so the testbench's view matches the DUT's view exactly.

| Alternative | Bug it would introduce |
|---|---|
| `#0` | Sampling happens in the **active region** of the same time step, racing with RTL updates. Sometimes you see the old value, sometimes the new — depends on event ordering. Tests pass on some simulators, fail on others. |
| `#1` (positive number) | Sampling happens **1 time unit after** the clock edge — you see the **new** RTL output, but the TB is now one cycle ahead of the DUT. Every scoreboard comparison is off by one cycle. |
| No clocking block | Procedural `<=` and direct reads in `always @(posedge clk)` — pure race condition. Unreproducible failures. |

**Interview-grade answer:**

> *"`#1step` is the special-purpose skew that means 'one simulator precision step before the clock edge.' It samples the signal at the very last instant of the previous time region — after RTL non-blocking assignments have all completed, before the current clock edge fires. That's the exact value the DUT's flip-flops are about to latch, so the TB sees what the DUT sees. `#0` would race with RTL updates in the active region; `#1` would sample after the edge and put the TB one cycle ahead of the DUT. `#1step` is the only correct choice for race-free, hold-aligned TB sampling."*

---

### Q7 — `wire` vs `logic` for SDA/SCL

I2C is an **open-drain wired-AND multi-driver bus**. At any instant, SDA and SCL can be:
- Pulled low by the master (active drive)
- Pulled low by the slave (during ACK or clock stretching)
- Released to high-Z by both, then pulled high by the pull-up resistor

`logic` in SystemVerilog is **single-driver**. Two procedural drivers assigning to the same `logic` give either a compile error or X resolution depending on the simulator. **It fundamentally cannot model a wired-AND bus.**

`wire` is a **multi-driver net** with built-in 4-state resolution rules per IEEE 1800. Combined with drive strengths (`strong0`, `weak1`, `highz0`), it correctly resolves multiple open-drain drivers and a pull-up — modelling I2C electrical behaviour faithfully.

**What breaks if you use `logic`:**
- Slave ACK (slave pulling low while master is high-Z) — multi-driver, compile error or X.
- Clock stretching (slave holding SCL low while master drives) — multi-driver, fails.
- Arbitration (two masters driving simultaneously) — multi-driver, the whole point of T13 — fails.

**Interview-grade answer:**

> *"SDA and SCL are open-drain wired-AND with multiple drivers — master, slave, and pull-up. `logic` is a single-driver type and can't model that; assigning from two places gives a compile error or X. `wire` with drive strengths — `strong0` for active pull-down and `weak1` for the released pull-up — gives correct multi-driver resolution per the standard 4-state table. Without `wire` you can't model slave ACK, clock stretching, or arbitration loss. It's not a style choice; it's a correctness requirement."*

---

### Q8 — Embedding SVA in Interface

**When YES (embed in interface):**
- Assertions reference signals that conceptually belong to the protocol (SDA/SCL).
- You want the assertions to travel automatically with the interface across projects.
- The protocol checks are tightly coupled to the bundle of signals already declared.

**When NO (keep SVA separate, often in a `bind`-ed module):**
- The interface is reused across projects with different assertion needs.
- The assertion logic is heavy — using auxiliary state, formal-mode constructs, complex sequences.
- You want to enable/disable assertions per regression run without recompiling the interface.

**The trade-off:** embedded SVA gives **automatic coupling** to the signals (the assertion can't miss a signal because they're in the same file) at the cost of **mixing concerns** (structural signal bundle + behavioural protocol checks).

The current `i2c_if.sv` has **no embedded SVA**. Adding "SDA must be stable while SCL is high" and "START is SDA falling while SCL high; STOP is SDA rising while SCL high" would catch protocol bugs much earlier than a scoreboard-level mismatch. **This is a real internship improvement to propose.**

**Interview-grade answer:**

> *"Embed in the interface when the assertions are tightly coupled to the signal bundle and need to travel with it across projects — basic protocol invariants like 'SDA stable when SCL high' fit this pattern. Keep them in a separate `bind`-ed module when the assertions are heavy, project-specific, or you want to swap assertion sets per regression without recompiling the interface. The trade-off is automatic coupling vs separation of concerns. In this I2C interface there are no embedded assertions, but I'd add SDA-stable-while-SCL-high and START/STOP edge checks because those catch bugs at the point of violation, not downstream in the scoreboard."*

---

### Q9 — Layered Restriction (Modport + Clocking Block Direction)

**Modport restricts `which signals` a role can access.**
**Clocking block direction restricts `how` those signals can be used (read-only vs read-write).**

`monitor_mp` exposes `monitor_cb`. `monitor_cb` has only `input` directions. So the monitor sees only the sampling block, and that block can only be read.

**Why both layers?** Defense in depth:

- A modport alone (without restricting the clocking block to input-only) — a role could expose a driver clocking block and access output signals through it.
- A clocking block alone (without modport restriction) — every role can see every clocking block in the interface, so a driver could accidentally use the monitor's clocking block for sampling and miss the proper skews, or worse, somebody adds output signals to monitor_cb later and the monitor starts driving.

Together, the modport gates **which** blocks are visible, and the clocking block's direction list gates **what** can be done within each visible block. Either layer alone has a leak; both layers eliminate the leak.

**Interview-grade answer:**

> *"It's defense in depth. The modport says 'this role can only see this clocking block.' The clocking block's `input`-only directions say 'within this block, only reads are allowed.' If you had only the modport, a role could expose a driver clocking block and gain write access by accident. If you had only the clocking block restriction, every role could see every clocking block and possibly use the wrong one with the wrong skews. Together, the modport gates visibility and the clocking block gates capability, eliminating both classes of misuse."*

---

### Q10 — Null-vif Debug

The top three root causes, in priority order:

1. **`uvm_config_db::set` was never called in `tb_top`.** Open `tb_top.sv`, search for `config_db.*set.*vif`. If absent, you found the bug.

2. **The `set` path glob doesn't match the `get` requestor's hierarchical path.** If `set` uses `"uvm_test_top.env.master_agent.*"` but the driver lives at `"uvm_test_top.env.master_agt.driver"` (note the typo: `agent` vs `agt`), the get returns false. Use `print_config_with_audit(1)` to dump the config db and compare paths.

3. **Type mismatch between set and get.** If you `set` as `virtual i2c_if` but `get` as `virtual i2c_if.master_mp`, UVM treats them as different types and the get fails. Standardize on unqualified handles unless you have a strong reason to use modport-qualified.

**Lesser causes worth checking after the top three:**
- The `get`'s return value isn't checked, so the vif stays null but no error fires until run_phase. Always `if (!get) `uvm_fatal`.
- The vif handle was reassigned to null somewhere after build_phase (rare, but possible if you have explicit `vif = null` somewhere).
- The interface is instanced but ports aren't connected to a real clock, so the clocking block never fires (causes hang, not null-deref — but mentioning shows breadth).

**Interview-grade answer:**

> *"Three causes in order. First, the `set` was never called — open `tb_top.sv` and grep for `config_db.*set.*vif`. Second, the set path glob doesn't match the requestor's `get_full_name()` — common when path strings are hand-typed; use `print_config_with_audit` to compare. Third, type mismatch between set and get — usually a modport-qualified handle on one side and unqualified on the other. After that I'd check the get's return value is actually being checked with `uvm_fatal` on failure, because silent failures lead to exactly this debug. Defensive coding catches the bug at build time, not at the first run_phase crash."*

---

## 11. Key Takeaways

### Conceptual

1. **Interfaces exist for one decisive reason: `virtual interface` handles**, which let class-based UVM code reference DUT signals. Modules can't do that.
2. **Open-drain buses require `wire` and drive strengths**, not `logic`. Multi-driver resolution is a language feature, not a workaround.
3. **Clocking blocks make TB code race-free.** `#1step` input skew samples at the settled, race-free instant just before the clock edge. `#1` output skew models flip-flop clock-to-Q and prevents hold violations.
4. **Modports enforce roles at compile time.** A monitor that "literally cannot drive" is architecture-as-code.
5. **`config_db::set` in tb_top, `config_db::get` with `uvm_fatal` in every component.** This is the single highest-ROI defensive pattern in UVM.
6. **The slave-side interface is a sidechannel**, not a bus. It carries control inputs and status outputs; the actual SDA/SCL still lives in the bus interface.

### Career-Critical

- **You will be asked about virtual interfaces and config_db in every UVM interview.** Q4, Q5, Q10 are guaranteed in some form.
- **Skew semantics (Q2, Q6) separate juniors from people who actually understand UVM.** Most freshers say "input skew samples before the edge" without naming `#1step` or explaining why. Saying `#1step` correctly is a credibility marker.
- **`wire` vs `logic` for multi-driver (Q7) is a fundamental SV literacy question.** Gaps here filter you out.
- **Adding embedded SVA to your I2C interface is a real internship improvement.** Protocol-level checks at the signal source catch bugs earlier and demonstrate verification maturity.

### Interview Traps Called Out

- "Why not `logic` for SDA?" — sounds innocent, tests multi-driver understanding.
- "What if you forget `#1step`?" — tests whether you understand WHY, not just memorized "use #1step."
- "Why is the monitor input-only?" — tests whether you can articulate layered defense (modport + clocking direction).
- "What if get returns false?" — tests defensive coding; correct answer is `uvm_fatal` immediately.

---

## 12. Action Items

- [ ] Re-do the 10-question quiz **without looking at answers** in 3 days. Aim for 8/10 correct.
- [ ] In your project's `tb_top.sv`, locate the `uvm_config_db::set` calls for both interfaces. Confirm the path globs match the agent hierarchy.
- [ ] In every UVM driver and monitor, confirm the `get` is wrapped in `if (!...) `uvm_fatal`. Add it where missing.
- [ ] **Stretch:** Add embedded SVA to `i2c_if.sv` for:
  - `a_sda_stable_when_scl_high`: SDA must not change while SCL is high (except at START/STOP).
  - `a_start_is_sda_fall_when_scl_high`: A START condition is recognizable as SDA falling while SCL is high.
  - `a_stop_is_sda_rise_when_scl_high`: A STOP condition is recognizable as SDA rising while SCL is high.
- [ ] **Stretch:** Refactor `i2c_slave_if.sv` to split into two interfaces: one for stretch/error-injection control inputs, one for status outputs. This makes ownership clearer and aligns with the active/passive agent split.
- [ ] When you reach the driver and monitor lessons, return here and re-read sections 6, 7, 8 with the concrete consumer code in front of you.
- [ ] Write a one-paragraph "interview elevator pitch" for each interface (master bus + slave sidechannel) and rehearse aloud until it's smooth.

---

## 13. Honest Self-Score Template

Fill this in the day you finish reading this lesson. Be brutal — partial-credit is for school, not for interviews.

| Area | Score (0/25/50/75/100) | Status | Notes |
|---|---|---|---|
| Why interfaces exist (Q1, vs module) | __ | __ | __ |
| `wire` vs `logic` for multi-driver (Q7) | __ | __ | __ |
| Open-drain modelling with drive strengths | __ | __ | __ |
| Clocking block purpose (race-free TB) | __ | __ | __ |
| `#1step` input skew semantics (Q2, Q6) | __ | __ | __ |
| `#1` output skew semantics (Q2) | __ | __ | __ |
| Modport purpose and modport-vs-clocking layering (Q3, Q9) | __ | __ | __ |
| Virtual interface concept (Q4) | __ | __ | __ |
| `config_db` set/get flow (Q5) | __ | __ | __ |
| `uvm_fatal` on null vif (Q5, Q10) | __ | __ | __ |
| Embedded SVA trade-offs (Q8) | __ | __ | __ |
| Slave-side interface as sidechannel (not bus) | __ | __ | __ |

**Status legend:**
- `Strong` (>= 75) — can answer cleanly in an interview without hesitation.
- `Partial` (50) — get the gist but stumble on terminology or edge cases. **Schedule a re-read in 1 week.**
- `Weak` (25) — heard the words but cannot articulate. **Re-read this lesson section before moving on.**
- `Unknown` (0) — never seen before. **Stop here. Read the section again now.**

**Re-test schedule:**
- T+3 days: re-do the 10-question quiz cold.
- T+7 days: re-do the quiz again; any area still <75 goes into spaced repetition.
- T+30 days: blind retest before any real interview.

---

**End of Lesson 06.** Next up: lesson 07 will likely cover the master agent (sequencer/driver/monitor) — where everything in this lesson actually gets used. Keep this file open in a side tab when reading that one.
