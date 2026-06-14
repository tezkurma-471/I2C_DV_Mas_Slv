> **⚠️ 2026-06-10 AUDIT UPDATE — read this box before trusting the lesson below.**
> A deep audit + fix pass changed the code this walkthrough describes. Deltas for this file:
> - The master driver was REWRITTEN: per-bit timing honors T_HD_DAT/T_SU_DAT (+SVA pipeline margin), START/Sr/STOP honor T_SU_STA/T_HD_STA/T_SU_STO, and STOP is followed by a T_BUF bus-free wait.
> - `scl_release_wait()` makes the BFM genuinely clock-stretch aware: release SCL, wait for the WIRE to go high, uvm_error on MAX_CLK_STRETCH timeout. (The README used to describe this loop; it did not exist.)
> - NACK handling: address NACK → abort with STOP, payload cleared; data NACK → transfer ends at the NACK'd byte and the item is trimmed to what was actually driven.
> Full detail: [`19_audit_fixes_walkthrough.md`](./19_audit_fixes_walkthrough.md) and `docs/AUDIT_FIX_REPORT.md`.

# Lesson 09 — `i2c_master_driver.sv` and `i2c_slave_driver.sv` Deep Dive

**Files under study:**
- `uvm/i2c_master_driver.sv` (228 lines)
- `uvm/i2c_slave_driver.sv` (166 lines)

**Concepts covered:** `uvm_driver` base class, `run_phase` infinite loop, `seq_item_port.get_next_item / item_done`, TLM pull port mechanics, virtual interface (`vif`) wiring through `config_db`, driving open-drain / inout signals, clock-aligned pin wiggling, master vs slave driver role asymmetry, reset handling, pipelining, dual-driver conflicts.

**Date:** 2026-05-17

---

## Table of Contents

1. [Driver Architecture in UVM — Where the Driver Sits](#1-driver-architecture-in-uvm--where-the-driver-sits)
2. [60-Second Elevator Pitch](#2-60-second-elevator-pitch)
3. [Master Driver Walkthrough — Line by Line](#3-master-driver-walkthrough--line-by-line)
4. [Slave Driver Walkthrough — A Reactive Beast](#4-slave-driver-walkthrough--a-reactive-beast)
5. [The Driver-Sequencer Handshake — `get_next_item` vs `try_next_item` vs `peek`](#5-the-driver-sequencer-handshake--get_next_item-vs-try_next_item-vs-peek)
6. [`item_done` — When, Why, and What Breaks if You Forget](#6-item_done--when-why-and-what-breaks-if-you-forget)
7. [Pipelined Driving — Multiple In-Flight Items](#7-pipelined-driving--multiple-in-flight-items)
8. [CPU Command Sequencing in the Master Driver](#8-cpu-command-sequencing-in-the-master-driver)
9. [Driving `inout` Signals via Interface — the `oe` Discipline](#9-driving-inout-signals-via-interface--the-oe-discipline)
10. [Quiz — 15 Questions](#10-quiz--15-questions)
11. [Quiz — Answers & Senior-Grade Deep Explanations](#11-quiz--answers--senior-grade-deep-explanations)
12. [Key Takeaways](#12-key-takeaways)
13. [Action Items](#13-action-items)
14. [Honest Self-Score Template](#14-honest-self-score-template)

---

## 1. Driver Architecture in UVM — Where the Driver Sits

Before staring at any line of code, you must internalize **where** the driver lives in the UVM
component graph. Drivers are not standalone; they are the **pin-level executor** at the bottom
of a four-layer chain:

```
+--------------------------------------------------+
|              uvm_test (top of the food chain)    |   ← orchestrates sequences
+--------------------------------------------------+
                       |
                       v
+--------------------------------------------------+
|             uvm_env                              |   ← contains agent(s) + scoreboard
+--------------------------------------------------+
                       |
                       v
+--------------------------------------------------+
|             uvm_agent (i2c_agent)                |   ← contains driver + sequencer + monitor
|                                                  |
|   +----------+      +-----------+   +---------+  |
|   |sequencer | <--->|  DRIVER   |   | monitor |  |
|   +----------+      +-----------+   +---------+  |
|         ^                |                ^      |
|         |                | vif            |      |
|         |                v                |      |
|   +------------+    +-------------+       |      |
|   | sequence   |    | i2c_if (DUT |-------+      |
|   | (testbench)|    |  pins)      |              |
|   +------------+    +-------------+              |
+--------------------------------------------------+
                       |
                       v
                  RTL DUT (i2c_master_controller)
```

### The TLM Pull Handshake — Read This Three Times

The sequencer **does not push** items to the driver. The driver **pulls** them.

That single sentence is the entire mental model. The transport mechanism is a
**`uvm_seq_item_pull_port`** on the driver side, connected to a **`uvm_seq_item_pull_imp`**
on the sequencer side. The handle name in your driver is `seq_item_port` — inherited
automatically from `uvm_driver #(T)`.

The protocol is a request/response rendezvous:

```
SEQUENCE                SEQUENCER                  DRIVER
   |                       |                          |
   |--start_item---------->|                          |
   |                       |<--get_next_item()--------|   (driver blocks here)
   |                       |                          |
   |--finish_item--------->|                          |
   |                       |--hand over the item----->|   (driver receives `req`)
   |                       |                          |   (drives pins)
   |                       |                          |
   |                       |<--item_done()------------|   (driver releases sequencer)
   |  <--finish_item ret---|                          |
   |                       |                          |
```

**Three things this proves:**

1. The driver controls the pace of stimulus. If the driver doesn't call
   `get_next_item()`, the sequence is **stuck** at `finish_item()`. This is not a bug — it
   is the back-pressure mechanism that lets the driver throttle when DUT is busy.

2. There is **no mailbox, no queue, no FIFO** between sequencer and driver by default. It is
   a one-deep handshake. The "queueing" happens at the sequence-arbitration layer above.

3. The data does **not get copied**. `req` is a class handle. Both sequencer and driver
   point to the **same object**. The driver can mutate fields on it (e.g. write back received
   read data) and the sequence will see those changes after `finish_item()` returns —
   **provided the driver writes those fields before calling `item_done`**.

### What `uvm_driver #(T)` Gives You for Free

```systemverilog
class uvm_driver #(type REQ = uvm_sequence_item,
                   type RSP = REQ) extends uvm_component;
  uvm_seq_item_pull_port #(REQ, RSP) seq_item_port;
  REQ req;       // <-- yes, a built-in handle named `req`
  RSP rsp;
  ...
endclass
```

This is why in `i2c_slave_driver.sv` you see `seq_item_port.get_next_item(req)` with no
declaration of `req` — it's inherited. The master driver in this project explicitly declares
a local `req_item` instead, which is a stylistic choice (cleaner, no shadowing
surprises). **Both are legal.** Senior teams typically prefer the explicit local variable
for readability.

---

## 2. 60-Second Elevator Pitch

When NVIDIA / Qualcomm / Intel / AMD ask: *"Walk me through the driver in your I2C
verification environment,"* **say this**:

> *"My environment has two drivers because the I2C protocol has an inherent role
> asymmetry. The master driver is an active stimulator — it pulls a transaction
> sequence item from the sequencer, then drives `sda_drv` and `scl_drv` lines through
> the virtual interface to generate START, the address byte, payload bytes, and STOP,
> waiting for ACK between bytes. The slave driver is a reactive controller — it doesn't
> drive bus pins directly. Instead, it pokes side-band control signals like `stretch_en`,
> `stretch_cycles`, and `force_data_nack` on a slave-side interface and waits for the
> in-progress transaction to complete before clearing them. Both drivers follow the
> classic `get_next_item -> drive -> item_done` loop in `run_phase`, and both pull their
> virtual interface handles via `uvm_config_db` in `build_phase`. The master driver also
> has an analysis port to broadcast the completed transaction to the scoreboard."*

Memorize the **shape**: two drivers, one active, one reactive, both follow the same
UVM template but with very different responsibilities.

---

## 3. Master Driver Walkthrough — Line by Line

### 3.1 Class Declaration and Parametrization

```systemverilog
class i2c_driver extends uvm_driver #(i2c_seq_item);
  `uvm_component_utils(i2c_driver)
  virtual i2c_if vif;
  uvm_analysis_port #(i2c_seq_item) req_analysis_port;
```

**What's happening:**

| Element | Meaning |
|---|---|
| `extends uvm_driver #(i2c_seq_item)` | The driver is parameterized over the **request item type**. This is how the inherited `seq_item_port` and `req` get their concrete types — no casting needed inside the driver. |
| `` `uvm_component_utils(i2c_driver) `` | Macro that registers the class with the UVM factory. Without it, `i2c_driver::type_id::create()` would not compile. **Forget this macro and your override hooks die silently.** |
| `virtual i2c_if vif` | The **handle** (not the interface itself) to the bus interface module. Without `virtual`, you couldn't store an interface inside a class. |
| `uvm_analysis_port #(i2c_seq_item) req_analysis_port` | Outbound broadcast port. The driver publishes the completed item — including data captured from the bus on reads — for the scoreboard / coverage to consume. |

**Interview trap on the parameterization:**

> *"Why is `uvm_driver` parameterized over the request type?"*
> Because the inherited `seq_item_port` is `uvm_seq_item_pull_port#(REQ, RSP)`. If you
> didn't parameterize the driver, the port would be `uvm_sequence_item` (the base), and
> every access to `req.addr`, `req.data`, etc. would require `$cast` — both ugly and
> error-prone at runtime.

### 3.2 The Constructor — Boring, But Get It Right

```systemverilog
function new(string name = "i2c_driver", uvm_component parent = null);
  super.new(name, parent);
endfunction
```

That's the canonical `uvm_component` constructor. Two facts you must know:

1. **You must call `super.new(name, parent)`.** If you omit it, UVM cannot register this
   component in the hierarchy and `print_topology()` will not show it.
2. The defaults (`""`, `null`) exist so the factory's `create()` method can default-construct
   the object. **Removing the defaults breaks factory creation** — a real bug fresher
   engineers introduce regularly.

### 3.3 `build_phase` — Where the Driver Wakes Up

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  req_analysis_port = new("req_analysis_port", this);
  if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", vif)) begin
    `uvm_fatal(get_type_name(), "Virtual interface not found in config_db")
  end
endfunction
```

**Three operations, in strict order:**

1. **`super.build_phase(phase)`** — runs the parent's `build_phase`. For `uvm_driver`,
   this is mostly bookkeeping, but skipping it is a code-smell and may break future
   UVM versions.

2. **`req_analysis_port = new(...)`** — analysis ports are constructed in `build_phase`,
   never in the constructor. Why? Because **the parent handle isn't valid until
   build_phase**. Constructing analysis ports in `new()` is a subtle bug that causes the
   port to attach to the wrong hierarchy.

3. **`uvm_config_db::get(...)`** — pull the virtual interface handle that the top-level
   testbench (or test) stuffed into the configuration database with the key `"i2c_vif"`.
   The `if (!...) `uvm_fatal` pattern is the standard defensive check.

**The single most common bug in any UVM environment:** the test sets the vif at a path
that doesn't match where the driver looks for it. Result: `vif` is `null`, and the
first `vif.sda_drv <= ...` throws a null-pointer fatal at runtime.

> **Interview-grade answer for "why is my driver throwing a null reference":**
> *"99% of the time it's a `config_db` path mismatch. The test sets `i2c_vif` at one
> hierarchy node and the driver retrieves it from another. The cleanest debug is to
> turn on UVM_CONFIG_DB_TRACE on the command line — it logs every `set` and `get` and
> immediately shows the path mismatch."*

### 3.4 `run_phase` — The Heart of the Driver

```systemverilog
virtual task run_phase(uvm_phase phase);
  i2c_seq_item req_item;
  wait(vif.rst_n === 1'b1);
  `uvm_info(get_type_name(), "Reset released. Starting I2C driver.", UVM_LOW)
  forever begin
    seq_item_port.get_next_item(req_item);
    ...
    req_analysis_port.write(req_item);
    seq_item_port.item_done();
  end
endtask
```

Decompose this carefully:

| Step | Why it matters |
|---|---|
| `wait(vif.rst_n === 1'b1)` | Driver does NOT drive anything while reset is asserted. If you start driving during reset, the DUT may latch garbage on reset deassertion, polluting the first transaction. **Always gate the driver on reset.** |
| `forever begin ... end` | Standard infinite stimulus loop. The driver only exits when the simulation ends (`phase.drop_objection()` propagation kills it). |
| `seq_item_port.get_next_item(req_item)` | **Blocking pull**. The driver waits here until a sequence calls `finish_item`. Zero-cost when idle (it's a queue wait, not a polling loop). |
| `req_analysis_port.write(req_item)` | **CRITICAL ORDER**: write to the analysis port AFTER the bus activity finishes. If you broadcast before driving, the scoreboard receives expected data that hasn't been confirmed on the wire yet — and on reads, the `data[]` field hasn't been populated. The inline `// FIX` comment in your code is a battle scar from this exact bug. |
| `seq_item_port.item_done()` | Releases the sequencer to grant the next item. **Forgetting this hangs the simulation forever** — see Section 6. |

### 3.5 The Per-Item Drive Sequence

```systemverilog
if (req_item.start_cond && !req_item.rep_start) send_start();
else if (req_item.rep_start)                    send_rep_start();

if (req_item.start_cond || req_item.rep_start) begin
  send_byte({req_item.addr, logic'(req_item.dir)});
  wait_for_ack();
end

if (req_item.dir == DIR_WRITE) begin
  foreach (req_item.data[i]) begin
    send_byte(req_item.data[i]);
    wait_for_ack();
  end
end else begin
  for (int i = 0; i < req_item.data.size(); i++) begin
    receive_byte(req_item.data[i]);
    if (i < req_item.data.size() - 1) send_ack();
    else                              send_nack();
  end
end

if (req_item.stop_cond) send_stop();
```

This is the **protocol layer** of the driver. Notes:

1. **Address byte construction:** `{req_item.addr, logic'(req_item.dir)}` packs the 7-bit
   address and the 1-bit direction (`DIR_READ` / `DIR_WRITE`) into the standard I2C
   address byte. The explicit cast `logic'(req_item.dir)` is defensive — `dir` is an
   enum, and SystemVerilog occasionally complains about enum-in-concatenation without
   an explicit cast.

2. **Last-byte NACK on reads:** Per I2C spec, the master ACKs every received byte
   **except the last**, where it sends NACK to signal "I'm done." Look at the loop —
   the `if (i < size-1) send_ack else send_nack` pattern is exactly this.

3. **`foreach` vs `for` symmetry:** The write path uses `foreach`, the read path uses
   `for` with an index. The read path needs the index to detect "last byte"; the write
   path does not. Either form is legal — this is stylistic.

### 3.6 Pin-Level Tasks — `send_start`, `send_byte`, etc.

```systemverilog
virtual task send_start();
  vif.sda_drv <= 1'b1;
  vif.scl_drv <= 1'b1;
  @(posedge vif.clk); @(posedge vif.clk);
  vif.sda_drv <= 1'b0;   // SDA falls while SCL HIGH = START
  @(posedge vif.clk); @(posedge vif.clk);
  vif.scl_drv <= 1'b0;
  @(posedge vif.clk);
endtask
```

**Notice:** every state change is followed by **two `@(posedge clk)` waits**. This is
clock-aligned driving — the driver only mutates pins on rising edges of the system
clock, and it waits multiple cycles to ensure the slave (which samples on its own
schedule) sees stable values for setup/hold purposes.

**Why two cycles and not one?** Look at it as a setup buffer:

- Cycle 1: change SDA. (Old value still on the wire because non-blocking `<=`.)
- Cycle 2: new value visible; slave can sample now.

If the slave samples on its first rising edge after we write, a single-cycle wait
might not give it enough setup. Two cycles is conservative.

**Interview trap:**

> *"Why do you use non-blocking `<=` to drive the interface?"*
> Because the interface signals are typically logic registers updated by a clocking
> block or a `reg`. Non-blocking semantics match RTL behavior — the assignment takes
> effect at the end of the current time step, not immediately. Blocking assignment on
> a clocked signal causes simulation races between the driver thread and any
> consumer sampling the same signal.

### 3.7 The Open-Drain Trick — `sda_drv = 1` Is "Release"

I2C is **open-drain**: lines are pulled up externally, and any participant can
**pull low** but nobody actively drives high. The "release" state is "drive HIGH" on
this `sda_drv` signal, because the interface (and DUT) treats HIGH as "I'm not pulling."

Look at `receive_byte`:

```systemverilog
vif.sda_drv <= 1'b1;   // Release SDA (let slave drive)
@(posedge vif.clk); @(posedge vif.clk);
vif.scl_drv <= 1'b1;   // SCL HIGH — sample SDA
@(posedge vif.clk);
received_byte[i] = vif.sda;  // Sample on SCL HIGH
```

Two things:

1. We **release** `sda_drv` to 1, so the slave can pull it low to transmit a 0.
2. We **sample** `vif.sda` — the bus-state signal, **not** the drive signal. The bus
   signal is the wire-OR of all drives plus the pull-up.

**This convention — separate `drv` and bus signals — is the cleanest way to model
inout in UVM.** Real bidirectional pins (`inout` in modules) are messy in pure
behavioral SV. The standard trick is:
- `sda_drv`: what this master *wants* to drive (1 = release, 0 = pull low).
- `sda`: the resolved bus value (after merging with slave's drive).

See Section 9 for the deeper `oe` (output-enable) variant.

---

## 4. Slave Driver Walkthrough — A Reactive Beast

### 4.1 Why Two Drivers At All?

**The fundamental asymmetry of I2C:**

- The **master** *initiates* — it generates SCL, drives START, sends address, etc.
- The **slave** *responds* — it ACKs, optionally stretches the clock, optionally
  NACKs to signal an error.

In this project the **slave is the DUT** — actual RTL implementing the slave protocol.
So why is there a "slave driver" in the testbench at all? Because the slave RTL has
**configurable behaviors** that are controlled by side-band signals:

| Signal | Purpose |
|---|---|
| `stretch_en` | When 1, the slave will hold SCL low (clock-stretch) to back-pressure the master. |
| `stretch_cycles` | How many cycles to stretch. |
| `force_data_nack` | When 1, force the slave to NACK the next data byte (error-injection). |

The slave driver doesn't drive `sda` or `scl` (the DUT does). It **pokes these
side-band knobs** to make the DUT exhibit specific behaviors that the master driver
then exercises. It is a *behavior selector*, not a *protocol driver*.

### 4.2 The Sequence Item — A Different Beast

```systemverilog
class i2c_slave_ctrl_item extends uvm_sequence_item;
  `uvm_object_utils(i2c_slave_ctrl_item)
  rand bit         stretch_en;
  rand logic [15:0] stretch_cycles;
  rand bit         force_data_nack;

  constraint stretch_cycles_c {
    stretch_cycles inside {[16'd1 : 16'd500]};
  }
  constraint stretch_en_off_c  { stretch_en  == 1'b0; }
  constraint force_nack_off_c  { force_data_nack == 1'b0; }
```

Two things to notice:

1. The item is **not** a data-bearing transaction. It is a *configuration request*
   ("for the next transaction, please stretch / NACK").

2. The `stretch_en_off_c` and `force_nack_off_c` constraints **default these to 0**.
   Test sequences that want to exercise the feature must `constraint_mode(0)`
   (disable the off-constraint) and then constrain to 1. This is the standard
   "default-safe, opt-in to evil" idiom.

> **Interview-grade answer on default-safe constraints:**
> *"I always make stimulus default to the boring case. A user has to explicitly opt-in
> to the corner cases by turning off the inhibiting constraint. This means a sloppy
> sequence doesn't accidentally exercise an exotic mode and pollute the regression."*

### 4.3 `build_phase` — Three vif Handles

```systemverilog
virtual i2c_slave_if vif;
virtual i2c_if       bus_vif;    // T13: optional, only when compete_mode
bit  compete_mode    = 1'b0;
int  compete_at_bit  = 3;
```

The slave driver pulls **two** virtual interfaces:

- `i2c_slave_if vif` — slave-side control signals (`stretch_en`, `force_data_nack`,
  `active`).
- `i2c_if bus_vif` — **only** when `compete_mode` is set. This is for the T13
  competing-master scenario, where the slave driver becomes a *second master* and
  drives the bus to provoke arbitration loss.

```systemverilog
void'(uvm_config_db#(bit)::get(this, "", "compete_mode",   compete_mode));
void'(uvm_config_db#(int)::get(this, "", "compete_at_bit", compete_at_bit));
```

**Note the `void'(...)`**. Why discard the return value of `get`? Because here, an
absent config is fine — the defaults already specify safe values. We only want to
upgrade if the test bothered to set them. **`uvm_fatal` on a missing optional config
is a bug.**

### 4.4 `run_phase` — Reset Init + Optional Fork + Forever Loop

```systemverilog
vif.stretch_en      <= 1'b0;
vif.stretch_cycles  <= 16'd0;
vif.force_data_nack <= 1'b0;

if (compete_mode) begin
  fork
    drive_competition();
  join_none
end

forever begin
  seq_item_port.get_next_item(req);
  ...
  seq_item_port.item_done();
end
```

The structure:

1. **Initialize side-band signals to safe defaults.** Avoid X-propagation at
   start-of-sim.
2. **Optionally fork a background "competing master" thread** — `join_none` is the key:
   it spawns the thread and **immediately** continues to the `forever` loop without
   waiting for the fork to finish.
3. **Standard forever loop** consuming `i2c_slave_ctrl_item`s.

### 4.5 The Reactive-Wait Pattern

```systemverilog
if (req.stretch_en) begin
  wait (vif.active === 1'b1);   // FIX: Wait for transaction to START
  wait (vif.active === 1'b0);   // Then wait for transaction to END
  vif.stretch_en      <= 1'b0;
  vif.stretch_cycles  <= 16'd0;
end
```

The inline `// FIX` comment captures one of the **most instructive bugs** in this
project. Read the original (buggy) version mentally:

```systemverilog
// BUGGY VERSION:
wait (vif.active === 1'b0);   // Wait for transaction to END
```

What happens? If the master hasn't started yet, `active === 1'b0` is *already true*,
so the wait passes immediately, the driver clears the control signal, and the
stretch never happens. The transaction proceeds with default behavior. The test
*looks* like it ran the corner case but actually didn't.

> **Senior-engineer interview-grade answer:**
> *"This is a classic edge-trigger vs level-trigger bug. The driver wanted to wait
> for the trailing edge of `active`, but it was implemented as a level-wait. Fix is
> to wait for the rising edge first, then the falling edge — explicit START detection
> followed by END detection. This kind of bug doesn't surface in normal regressions
> because the master happens to start fast enough; it appears stochastically when
> the master is slow."*

### 4.6 The Competing-Master Side Quest

```systemverilog
virtual task drive_competition();
  bus_vif.sda_drv_x <= 1'b1;          // ensure released

  @(negedge bus_vif.sda);
  if (bus_vif.scl !== 1'b1) begin     // not a real START
    wait (bus_vif.sda === 1'b1 && bus_vif.scl === 1'b1);
    @(negedge bus_vif.sda);
  end

  for (int i = 0; i < compete_at_bit; i++) @(posedge bus_vif.scl);

  @(negedge bus_vif.scl);
  bus_vif.sda_drv_x <= 1'b0;          // pull SDA LOW = collision
  @(posedge bus_vif.scl);
  @(negedge bus_vif.scl);
  bus_vif.sda_drv_x <= 1'b1;          // release
endtask
```

This is a **mini standalone driver** running concurrently with the slave driver's main
loop. It watches the bus, waits for START, counts SCL pulses, then pulls SDA low at a
chosen bit position to clash with the master's drive. If the master was driving HIGH
at that moment, it now reads back LOW from the bus and detects arbitration loss.

**Why `sda_drv_x` and not `sda_drv`?** Because the regular master driver uses
`sda_drv`. The competing master needs its own drive lane so that the bus-resolution
function in the interface can wire-AND both contributions. If the competing master
used `sda_drv` directly, you'd have a SystemVerilog multi-driver compile error.

> **Interview-grade reflection:**
> *"This is a great example of why interface modeling matters more than the protocol
> itself. In real silicon, two masters pulling open-drain SDA is just current flowing
> through pull-ups — no compile error. In SV simulation, you must explicitly model
> the wire-AND, typically via per-source `drv` signals all feeding into a resolved
> bus signal."*

---

## 5. The Driver-Sequencer Handshake — `get_next_item` vs `try_next_item` vs `peek`

| API | Blocking? | Removes item from queue? | Use case |
|---|---|---|---|
| `get_next_item(req)` | **Yes** — waits forever for an item | No — driver still owes `item_done` | **Default.** Driver always wants the next item; idle when none available. |
| `try_next_item(req)` | **No** — returns immediately; `req` is null if none available | No — must still call `item_done` if you got one | Driver wants to do other work (e.g., poll DUT, advance bus) when sequencer has nothing. |
| `peek(req)` | **Yes** — waits, but **does not consume** the item | No — leaves item in queue, no `item_done` needed | Driver wants to "look ahead" — e.g., check what kind of item is coming before deciding how to schedule it. |
| `get(req)` | **Yes** — atomic get+done | **Yes** — item is consumed; no `item_done` needed | Convenience for stateless drivers that don't need the explicit done step. Rare in modern UVM. |

### When to Use Which — A Decision Tree

```
Does your driver need to do anything other than process items?
   |
   +--> NO  --> get_next_item + item_done   (the standard)
   |
   +--> YES, with optional items
         |
         +--> Driver must always make progress (e.g., refresh registers)
                use try_next_item; do other work when null
         |
         +--> Driver needs to inspect item BEFORE consuming
                use peek; decide; then get_next_item to actually consume
```

### A Concrete `peek` Example

```systemverilog
seq_item_port.peek(req);
if (req.is_high_priority) begin
  // re-arrange other work first
  prepare_dut_for_priority();
end
seq_item_port.get_next_item(req);   // now actually consume
// drive...
seq_item_port.item_done();
```

> **Interview-grade answer on `peek`:**
> *"`peek` is rare but lifesaving for drivers that need to take preparatory action
> based on item content — for example, a DDR driver that needs to switch banks before
> consuming a read. Most I2C/SPI/AXI drivers don't need `peek` because the work is
> uniform per item."*

---

## 6. `item_done` — When, Why, and What Breaks if You Forget

### When to Call

```systemverilog
forever begin
  seq_item_port.get_next_item(req);
  // ... drive pins ...
  // ... wait for completion ...
  seq_item_port.item_done();           // <- here, after the bus activity is done
end
```

**Rule:** Call `item_done` after the driver has **fully consumed** the item — meaning
the bus activity is complete and any captured response data has been written back
into `req`.

### What Happens If You Forget

The sequencer's grant logic looks like:

```
sequencer: pick next sequence to grant
  -> wait until current item_done called
  -> grant the next item
```

If `item_done` is never called, the sequencer **never grants a new item**. The next
`get_next_item` in the driver blocks forever. The sequence's `finish_item` (or
`start_item` on the next item) blocks forever. The simulation **hangs**.

You will see:
- All UVM objection-based phases stop progressing.
- Top-level test eventually times out (if you have a global watchdog) or runs
  forever.
- Wave dump shows no further bus activity after the last successful item.

**Debug trick:** turn on `+UVM_PHASE_TRACE` and `+UVM_OBJECTION_TRACE`. You'll see
objection counts not dropping, and you'll spot the stuck phase. Then add a
`uvm_info` before and after `item_done` in your driver to find the missing path.

### What If You Call `item_done` Twice?

UVM throws a `UVM_ERROR` like *"item_done called without get_next_item"*. The
sequencer's state machine breaks, future grants get out of sync, and downstream
sequences may receive responses meant for prior items. Very nasty bug. Don't do it.

### `item_done` vs `finish_item`

| Lives in | Method | Purpose |
|---|---|---|
| **Sequence** (testbench) | `finish_item(req)` | "I'm done preparing this item; hand it to the driver and wait for completion." |
| **Driver** | `item_done()` | "I'm done driving this item on the wire; release the sequence." |

They are the two ends of the rendezvous. Sequence side: `start_item -> randomize ->
finish_item`. Driver side: `get_next_item -> drive -> item_done`.

---

## 7. Pipelined Driving — Multiple In-Flight Items

The default UVM driver pattern is **strictly serial**: one item drives at a time,
`item_done` blocks the next item until the previous is fully wire-complete.

But some protocols (AXI, DDR, PCIe) support **outstanding transactions** — the
driver can issue requests faster than responses arrive. This needs **pipelining**.

### The Pipeline Pattern

```systemverilog
virtual task run_phase(uvm_phase phase);
  fork
    request_thread();   // get items, issue requests, do NOT wait for response
    response_thread();  // collect responses, populate rsp, call item_done
  join
endtask

task request_thread();
  forever begin
    seq_item_port.get_next_item(req);
    issue_request(req);
    pending_q.push_back(req);
    seq_item_port.item_done();   // release sequencer immediately
  end
endtask

task response_thread();
  forever begin
    response_data = collect_response();
    req = pending_q.pop_front();
    req.data = response_data;
    seq_item_port.put_response(req);   // for response-bearing protocols
  end
endtask
```

**Key insight:** with pipelining, `item_done` is called **as soon as the request is
issued**, not when the response arrives. This lets the sequencer dispatch the
**next** item while the **previous** is still in flight. The driver maintains a
queue of pending items and reconciles responses asynchronously.

### Why I2C Doesn't Need This

I2C is **strictly synchronous**: every byte is followed immediately by an ACK on the
9th bit, and the master cannot proceed to the next byte until the ACK is sampled.
There is no concept of outstanding bytes. So our `i2c_driver` is correctly serial.

> **Interview-grade answer when asked about pipelining I2C:**
> *"I2C is inherently non-pipelined at the byte level — the protocol requires an ACK
> after every byte, and the master holds SCL until the ACK. You could pipeline at the
> *transaction* level — sequence multiple distinct I2C transactions back-to-back — but
> the protocol prohibits pipelining within a transaction. Pipelining is a property of
> the protocol, not just the driver implementation."*

### What if I want to do it for AXI in interviews?

You'd say:
> *"For AXI, I'd split the driver into address-channel and data-channel threads,
> with a queue of outstanding IDs. AXI explicitly supports up to 16 outstanding
> transactions per channel; the driver must track WID/RID/BID matching."*

---

## 8. CPU Command Sequencing in the Master Driver

Read the master driver carefully and you'll notice it does **NOT** write to an APB
register interface. It directly drives `sda_drv` and `scl_drv` pins. **This is the
bit-banging style** of master driver.

But your I2C master controller (the RTL) is **CPU-controlled** in real systems. A
"real" master driver — i.e., one that talks to the RTL master via APB — would look
fundamentally different. Both styles exist. Let me explain both.

### Style A: The Bit-Banging Master (What's in This File)

```systemverilog
// Driver itself generates START, SCL, SDA bits — DUT is the slave.
send_start();
send_byte({req_item.addr, req_item.dir});
wait_for_ack();
...
```

**Use this when:** The DUT is the I2C slave, and you need an active master to drive
the bus. The driver becomes a behavioral model of an I2C master.

**Pros:** Simple. Full control over edge cases (early STOP, glitches).
**Cons:** No reuse from the RTL master; you must maintain protocol correctness in TB.

### Style B: The CPU-Style Master Driver

```systemverilog
// Driver pokes APB registers; the RTL master IP generates the actual bus signals.
apb_write(REG_DATA,  req_item.data[0]);
apb_write(REG_ADDR,  req_item.addr);
apb_write(REG_CMD,   CMD_START);
poll_busy_flag();
apb_write(REG_CMD,   CMD_WRITE);
poll_busy_flag();
...
apb_write(REG_CMD,   CMD_STOP);
```

**Use this when:** The DUT is the I2C master itself, and you're verifying the master's
register interface and FSM.

**Pros:** Verifies the actual register interface (which is what software will use).
**Cons:** Slower; you must poll busy/done flags; corner cases in protocol can't be
forced.

### How You'd Combine Them

A complete I2C IP testbench typically has **both** drivers:

1. A CPU-style master driver that pokes registers, simulating the software stack.
2. A bus-side passive **monitor** that observes the resulting bus activity.

If the DUT is the slave, you flip it: bit-banging master driver, passive register
monitor on the slave side.

> **Interview-grade answer on driver style:**
> *"It depends on what's being verified. If the DUT is an I2C master IP, the driver
> drives the CPU register interface — typically APB — and a separate monitor
> observes the bus. If the DUT is the slave, the driver bit-bangs the bus directly.
> In our project, the DUT is a slave with a configurable behavior model, so we have a
> bit-banging bus driver plus a side-band control driver for the slave's behavior
> knobs. There's no single right answer — it depends on where the verification
> boundary lies."*

### The Polling Loop You'll Be Asked About

Even in our project, *if* we had a CPU-style master driver, the inner loop would be:

```systemverilog
apb_write(REG_CMD, CMD_WRITE);
do begin
  apb_read(REG_STATUS, status);
end while (status[BUSY_BIT] === 1'b1);
if (status[NACK_BIT]) `uvm_error(...,"NACK received");
```

**Interview gotchas on polling:**

1. **Always include a timeout** in the polling loop. Infinite polling on a hung
   DUT looks identical to a missing `item_done` — both hang the sim.
2. **Use `fork...join_any` with a watchdog**:
   ```systemverilog
   fork
     while (status[BUSY] === 1'b1) apb_read(REG_STATUS, status);
     begin #1ms; `uvm_fatal(...,"poll timeout"); end
   join_any
   disable fork;
   ```
3. **Prefer interrupts** over polling for response-driven protocols. Polling burns
   simulation time; interrupt waits are zero-cost in simulators.

---

## 9. Driving `inout` Signals via Interface — the `oe` Discipline

I2C SDA is the textbook example of a bidirectional, open-drain signal. SystemVerilog
gives you a few ways to model it; the cleanest is the **output-enable (`oe`) pattern**.

### The Three Patterns

#### Pattern 1: Separate drive signals (used in this project)

```systemverilog
interface i2c_if(input logic clk, input logic rst_n);
  logic sda_drv;     // driver's intent
  logic sda;         // resolved bus value
  assign sda = sda_drv & dut_sda_out;   // wire-AND, or pull-up resolution
endinterface
```

Master driver sets `sda_drv = 0` to pull low, `sda_drv = 1` to release. Reads from
`sda` to observe the bus. Already covered in Section 3.7.

#### Pattern 2: Explicit `oe` + `data` (the canonical "real" inout pattern)

```systemverilog
interface i2c_if(...);
  logic sda_oe;      // output-enable: 1 = drive, 0 = release
  logic sda_o;       // data to drive when oe=1
  wire  sda;         // tri-state
  assign sda = sda_oe ? sda_o : 1'bz;
endinterface
```

Driver code:

```systemverilog
task drive_low();
  vif.sda_oe <= 1'b1;
  vif.sda_o  <= 1'b0;
endtask

task release_bus();
  vif.sda_oe <= 1'b0;     // tristate
endtask
```

This is what you'd use in **synthesizable** RTL. In a TB, it's a tad more verbose
but more closely matches silicon behavior.

#### Pattern 3: Direct inout (rare and ugly)

```systemverilog
inout logic sda;
```

Avoid in classes — you cannot drive `inout` from a class directly. Requires interface
or module-level assignments. Generally only used in DUT-level pin lists.

### The `oe` + Tristate Discipline

When using Pattern 2 in a driver:

| Action | `oe` | `data` (`o`) | Reading from |
|---|---|---|---|
| Drive 0 | 1 | 0 | — (don't read while driving) |
| Drive 1 (open-drain: release) | 0 | x | — |
| Read bus | 0 | x | `vif.sda` |

The **discipline** is: always set `oe = 0` before sampling, and always set `o`
before raising `oe`. If you mess up the order, you can momentarily drive an old
value, causing a glitch.

> **Interview-grade answer on inout discipline:**
> *"For bidirectional pins in SV testbench, I prefer the explicit `oe`/`out`/`bus`
> three-signal model. Driver sets `out` first, then asserts `oe`. To release,
> de-assert `oe` and let the pull-up (modeled with a `pullup` primitive or an
> assignment to `1`) reclaim the line. The biggest pitfall is forgetting to release
> `oe` before reading — you'd be sampling your own drive value, not the bus."*

### The Common Bug — Forgetting to Release

In `receive_byte`, look at the line:

```systemverilog
vif.sda_drv <= 1'b1;   // Release SDA (let slave drive)
```

This is the release. If you forgot it — say you left `sda_drv = 0` from the previous
byte — the master would still be pulling SDA low and the slave's drive would have
no effect. You'd always sample 0 and think every received byte is `0x00`.

**This bug is so common it has a name: "stuck-driver bug."** Always release before
sampling.

---

## 10. Quiz — 15 Questions

Cover the answer section below before you read further. Aim for 12/15 before
moving on. **Do not look at the answers on first pass.**

1. **Phase order:** List the UVM phases in execution order from `build_phase` through
   `run_phase`. Where exactly does the driver's `forever` loop start, and which
   phase ends it?

2. **`get_next_item` vs `try_next_item`:** When would you use `try_next_item` in
   an I2C driver? Give a concrete scenario.

3. **`item_done` semantics:** What three things does calling `item_done` cause to
   happen, in the order they happen?

4. **Vif null reference:** Your driver throws `Null pointer access` on the first
   `vif.sda_drv <= 0` line. List **three** distinct root causes you'd investigate,
   in priority order.

5. **Driving inout via `oe`:** Walk through the exact order of operations to (a)
   drive a 0 on SDA, then (b) release SDA, then (c) read SDA from the bus. Use the
   3-signal model (`oe`, `o`, `bus`).

6. **Reset mid-item:** A reset is asserted while your driver is halfway through
   `send_byte`. What should the driver do? What does the code in this project do?

7. **Master driver style — APB vs bit-bang:** Your DUT is the I2C *master* IP. Should
   your master driver bit-bang SDA/SCL, or write to APB registers? Why?

8. **Pipelining:** Explain why I2C cannot be pipelined at the byte level but AXI can.
   What architectural feature enables AXI pipelining?

9. **Clock alignment:** Why are pin changes in the master driver always preceded by
   `@(posedge vif.clk)` rather than just delays like `#10ns`?

10. **`finish_item` vs `item_done`:** Which lives in the sequence, which in the
    driver? What synchronization do they implement together?

11. **Seq item type vs driver type:** The master driver is `uvm_driver
    #(i2c_seq_item)`. What would break if a sequence pushed an `i2c_slave_ctrl_item`
    instead?

12. **Dual drivers on one DUT:** You instantiate the master driver and the
    competing-master logic in the slave driver, both potentially driving SDA. What
    SV mechanism prevents the simulator from throwing a multi-driver error?

13. **End of test:** When the test calls `phase.drop_objection`, what happens to the
    driver's `forever` loop? How does the simulation terminate cleanly without
    leaking the in-flight item?

14. **`run_phase` `fork` structure:** Look at the slave driver — it has a
    `fork ... join_none` for the competing master and a `forever` loop. Why
    `join_none` and not `join` or `join_any`? What would each alternative do?

15. **Non-automatic driver fail:** If you accidentally wrote `function i2c_driver`
    instead of `function automatic` in a helper, what would actually go wrong? Be
    precise about *which kind of variable* corrupts.

---

## 11. Quiz — Answers & Senior-Grade Deep Explanations

### Q1 — UVM Phase Order

**Common phases in execution order:**

| Phase | Type | What runs here |
|---|---|---|
| `build_phase` | function (top-down) | Construct sub-components, fetch config_db. |
| `connect_phase` | function (bottom-up) | TLM port wiring. |
| `end_of_elaboration_phase` | function | Last chance before sim starts. |
| `start_of_simulation_phase` | function | Banner prints, summary. |
| `run_phase` | task (parallel) | Real stimulus. Driver `forever` loops here. |
| `extract_phase` ... `final_phase` | function | Post-run cleanup. |

**The driver's `forever` loop starts in `run_phase`** and runs until the global
objection count drops to zero. When the last objection is dropped (typically by
the test after the last sequence finishes), the phase ends and any active
`forever` loops are killed.

**Interview-grade answer:**

> *"`run_phase` is the only **task** phase in the typical flow — everything before it
> is a function and must return zero-time. The driver's `forever` loop runs in
> `run_phase`. Termination is objection-based: when the test calls
> `phase.drop_objection` and all other components have also dropped, UVM kills the
> phase and the `forever` loop dies. There's no explicit return — the loop is
> *terminated* by the phaser, not exited by the code."*

---

### Q2 — `get_next_item` vs `try_next_item`

**Default choice:** `get_next_item`. It blocks; driver is idle when no item
available; zero cost when idle.

**Use `try_next_item` when:**

1. Driver must keep doing background work (refreshing CSRs, idling the bus with
   keep-alives, generating bus turn-around) when no item is available.
2. Driver implements a polling pattern over multiple sequencers and shouldn't
   block on any single one.

**Concrete I2C scenario:**

> *"Imagine an I2C driver that, when idle, must continuously refresh a `RUN_TIMER`
> register every 100 µs to keep the master IP alive. Pure `get_next_item` would
> block forever during idle periods and starve the refresh. Using `try_next_item`,
> the driver does the refresh if no item is pending, then loops back to check
> again."*

**The trap:** `try_next_item` still requires `item_done` if it returned a non-null
item. Easy to forget when the code path is conditional.

---

### Q3 — `item_done` Semantics

When you call `seq_item_port.item_done()`, three things happen **in this order**:

1. **The sequencer's grant lock is released.** The next item can now be granted.
2. **The sequence's `finish_item` call returns**, allowing the sequence body to
   advance to the next item.
3. **(If applicable) the response is sent back** — for `item_done(rsp)` variants,
   the response is delivered to the sequence's response queue.

> **Interview-grade answer:**
> *"`item_done` is the driver's signal that it has finished consuming the item. It
> unblocks `finish_item` in the sequence, releases the sequencer's arbitration
> lock so the next item can be granted, and — if a response argument is supplied —
> delivers that response to the sequence's `get_response` queue. The three are
> tightly coupled; you can't observe one without the others happening."*

---

### Q4 — Vif Null Reference Root Causes

In priority order:

1. **`config_db` path mismatch.** Most common. The test sets `i2c_vif` at one
   hierarchy node, the driver searches for it at another. Run with
   `+UVM_CONFIG_DB_TRACE` and you'll see the `set`/`get` paths printed; the
   mismatch is obvious.

2. **`config_db::set` happens after `build_phase`.** UVM `build_phase` is top-down.
   If you put the `set` in a parent's `start_of_simulation_phase` instead of
   `build_phase`, the driver's `build_phase` already ran with no vif found. The
   driver runs with `vif == null` until it dereferences and dies.

3. **Wrong key string.** The set uses `"i2c_vif"`, the get uses `"i2c_if_vif"` or
   `"vif"`. Pure string mismatch. No type system catches this. Define the keys as
   `localparam string` constants in a package to eliminate.

**Additional sneaky causes you'd mention if pressed:**

- **Parameter mismatch:** test sets `virtual i2c_if#(.WIDTH(16))`, driver gets
  `virtual i2c_if#(.WIDTH(8))`. The two parameterized types are distinct classes;
  the get fails silently.
- **Wildcard scope mismatch:** test does `set(this, "env.agent.*", ...)`, driver
  does `get(this, "", ...)`. The driver's *full path* must match the wildcard.

> **Interview-grade answer:**
> *"99% of null-vif bugs are `config_db` path mismatches. My first action is always
> `+UVM_CONFIG_DB_TRACE` — it logs every `set` and `get` with the full path string,
> and the mismatch jumps out. Less commonly, the `set` happens after the consumer's
> `build_phase`, or the keys are different strings due to a typo. Defining keys as
> `localparam` constants in a shared package eliminates the typo class of bug."*

---

### Q5 — Driving inout via `oe`

Using the 3-signal model: `sda_oe`, `sda_o`, `sda` (the bus).

**(a) Drive 0:**
```systemverilog
vif.sda_o  <= 1'b0;        // set data first
@(posedge vif.clk);
vif.sda_oe <= 1'b1;        // then enable output
```
Order matters: if you set `oe` before `o`, you'd briefly drive whatever `o`'s
previous value was — a glitch.

**(b) Release:**
```systemverilog
vif.sda_oe <= 1'b0;        // disable output
@(posedge vif.clk);
// Pull-up (modeled in interface) reclaims the bus to 1
```

**(c) Read:**
```systemverilog
// Make sure oe is already 0
@(posedge vif.clk);        // allow pull-up to settle
sampled = vif.sda;         // read from the bus, not from sda_o
```

> **Interview-grade answer:**
> *"Discipline matters. To drive low: set data first, then enable. To release:
> de-assert enable, let the pull-up settle. To read: sample from the bus signal,
> never from your own drive register. The most common bug is reading from
> `sda_o` — you'd just be reading back what you last drove, not the actual bus
> state."*

---

### Q6 — Reset Mid-Item

**What should happen:**

1. The driver detects reset assertion.
2. It immediately stops driving the bus (releases all `drv` lines to safe defaults).
3. It abandons the current item — typically discarding it without calling
   `item_done` is dangerous; UVM convention is to call `item_done` (possibly with
   an error-marked response) so the sequence isn't stuck.
4. After reset deasserts, it returns to the top of the `forever` loop.

**What this code does:**

Look at the master driver:

```systemverilog
wait(vif.rst_n === 1'b1);
forever begin
  seq_item_port.get_next_item(req_item);
  ...
end
```

The driver waits for reset to deassert **at startup**, then enters the loop. It
does **NOT** check for reset re-assertion mid-item. **This is a latent bug** in
the driver. If reset toggles mid-test, the driver would continue driving and
corrupt the bus.

**Proper fix — `fork-join_any` with reset monitor:**

```systemverilog
forever begin
  seq_item_port.get_next_item(req_item);
  fork
    begin
      drive_item(req_item);
    end
    begin
      @(negedge vif.rst_n);    // reset asserted
      `uvm_warning(get_type_name(), "Reset asserted mid-item, aborting")
    end
  join_any
  disable fork;                // kill whichever didn't finish
  release_all_pins();
  seq_item_port.item_done();
  wait(vif.rst_n === 1'b1);
end
```

> **Interview-grade answer:**
> *"The driver in this project gates startup on reset deassertion but does **not**
> handle mid-item reset — if reset toggles during a transaction, the driver
> continues bit-banging through it, which would generate garbage on the bus. The
> proper pattern is to `fork-join_any` the drive task against a reset watcher; on
> reset, `disable fork`, release pins, mark the item with an error response, call
> `item_done`, then re-wait for reset deassertion. This is a known gap I'd close
> before promoting the driver to a regression."*

---

### Q7 — Master Driver Style: APB vs Bit-Bang

**If the DUT is the I2C master IP:** Use APB-style driver.

**Why:**
1. The DUT exposes a register interface — APB / AHB / AXI-Lite — to the CPU. That
   register interface IS what software will use; verification *must* exercise it.
2. Bit-banging would bypass the DUT entirely and verify nothing about the master IP.
3. The DUT's own logic generates SDA/SCL — your driver poking those pins would
   *conflict* with the DUT's drivers (multi-driver error).

**If the DUT is the slave (our project):** Bit-banging is correct.

**Why:**
1. There's no register interface on the slave we're driving; the master is
   external (testbench).
2. We need an active master to talk to the DUT; the simplest one is a behavioral
   TB driver.

> **Interview-grade answer:**
> *"Driver style is a function of the DUT boundary. If the DUT is a master IP with a
> register interface, the driver writes registers — APB-style — and a monitor
> observes the bus. If the DUT is a slave, the driver becomes a behavioral master
> bit-banging the bus. Mixing them up is a common fresher mistake: trying to
> bit-bang the bus while the master IP is also driving it produces multi-driver
> errors at best, undefined waveforms at worst."*

---

### Q8 — Why I2C Can't Be Pipelined, AXI Can

**I2C constraint:** every byte transfer is *immediately* followed by ACK on the 9th
bit, on the **same wire**, in the **same SCL cycle window**. The master cannot
start byte N+1 until ACK for byte N is sampled. There's no spare bandwidth and no
separate response channel.

**AXI architectural feature that enables pipelining:** AXI is a **split-transaction**
protocol with **independent address and data channels**, plus per-transaction IDs.

| AXI channel | Direction | What flows |
|---|---|---|
| AW | Master -> Slave | Write address + ID |
| W | Master -> Slave | Write data + last marker |
| B | Slave -> Master | Write response + ID |
| AR | Master -> Slave | Read address + ID |
| R | Slave -> Master | Read data + ID + last marker |

The master can issue AW1, AW2, AW3 on the address channel before any B response
arrives. Each transaction is tagged with an ID, so responses don't need to come
back in order. Up to 16 outstanding (by default).

> **Interview-grade answer:**
> *"I2C is a single-wire, half-duplex protocol with embedded acknowledgment after
> every byte — there's no architectural room for outstanding transactions within a
> single transfer. AXI, by contrast, has five independent channels and per-transaction
> IDs, which lets the master issue up to 16 outstanding reads or writes per channel
> and reconcile responses by ID. Pipelining is enabled by **channel separation** and
> **out-of-order completion** — neither of which I2C provides."*

---

### Q9 — Clock Alignment with `@(posedge vif.clk)`

**Why not `#10ns`?**

1. **Robustness to clock frequency changes.** If someone changes the system clock
   from 50 MHz to 100 MHz, `#10ns` is now half a cycle and breaks. `@(posedge clk)`
   adapts automatically.
2. **Avoiding races with the DUT.** The DUT samples pins on `posedge clk`. If the
   driver changes pins at the same simulation time but in the active region, the
   DUT may sample old or new value non-deterministically. Driving on
   `@(posedge clk)` followed by `<=` puts the new value in the NBA region — DUT
   sees old value at this edge, new value at the next.
3. **Setup/hold compliance.** Driving relative to the clock edge guarantees
   setup time naturally; driving with absolute delays does not.

**The strict pattern is the clocking block:**

```systemverilog
clocking driver_cb @(posedge clk);
  default input #1step output #1ns;
  output sda_drv, scl_drv;
  input  sda, scl;
endclocking
```

With a clocking block, every output drive is offset from the clock edge by the
`output` skew — eliminating sample/drive races entirely.

> **Interview-grade answer:**
> *"`@(posedge clk)` makes the driver clock-frequency agnostic and avoids
> simulation races between driver and DUT sampling. The gold-standard is a
> **clocking block** with explicit input and output skews — that's what production
> UVCs use. Absolute delays like `#10ns` are appropriate only for asynchronous,
> non-clocked interfaces."*

**Project-specific note:** This master driver uses bare `@(posedge vif.clk)` and
non-blocking assigns without a clocking block. It works but is more fragile than
a clocking-block-driven version. **An improvement to propose in your project.**

---

### Q10 — `finish_item` vs `item_done`

| Method | Lives in | Caller's perspective | Effect |
|---|---|---|---|
| `start_item(req)` | Sequence | "I'm about to send an item; lock the sequencer." | Acquires sequencer arbitration. Blocks until granted. |
| `finish_item(req)` | Sequence | "Item is ready, hand it over." | Delivers the item to the driver; blocks until `item_done`. |
| `get_next_item(req)` | Driver | "Give me work." | Pulls the item; blocks if none. |
| `item_done()` | Driver | "I'm finished." | Unblocks `finish_item` in the sequence. |

**Together they implement a rendezvous:** sequence blocks until driver completes;
driver blocks until sequence supplies. Neither side can race ahead.

> **Interview-grade answer:**
> *"`finish_item` is in the sequence, `item_done` is in the driver. They form a
> rendezvous — the sequence blocks at `finish_item` until the driver calls
> `item_done`. This back-pressure mechanism is what lets the driver pace stimulus
> based on DUT readiness without needing any external queueing."*

---

### Q11 — Seq Item Type Mismatch

The master driver is `uvm_driver #(i2c_seq_item)`. Its `seq_item_port` is
`uvm_seq_item_pull_port #(i2c_seq_item, i2c_seq_item)`. Its inherited `req`
handle (and the local `req_item` it declares) are of type `i2c_seq_item`.

**If a sequence connected to this driver pushed `i2c_slave_ctrl_item` instead:**

- **At connection time:** UVM type checks the connection. If the sequencer was
  declared as `uvm_sequencer #(i2c_seq_item)` and the sequence parametrized over
  `i2c_slave_ctrl_item`, the `connect_phase` would fail with a type-mismatch
  error.

- **If you bypass the type check** (e.g., raw `uvm_sequencer` base type used):
  - Compile-time: passes (since you used the base).
  - Run-time: the driver does `req_item.addr` — and if `req_item` is actually a
    `i2c_slave_ctrl_item` cast to `i2c_seq_item`, the field doesn't exist. You'd
    get a null reference or a `$cast` failure.

> **Interview-grade answer:**
> *"UVM enforces type safety via parameterization on the sequencer and driver.
> Mixing types compiles only if you use the base `uvm_sequencer` and `uvm_driver`
> — which is bad practice — and at run time you'd see `$cast` failures or null
> dereferences when the driver accesses fields that don't exist on the wrong type.
> Always parameterize sequencer and driver with the same item type; this is the
> single biggest correctness property of a UVM agent."*

---

### Q12 — Dual Drivers on One Bus

In SystemVerilog, a `logic` variable can have **only one continuous driver**. A
`wire` can have multiple, with resolution. So how do the master driver and the
competing-master logic coexist on SDA?

**The answer is in the interface.** Look at how the bus is modeled:

- Master driver writes to `vif.sda_drv` (its own drive lane).
- Competing master writes to `vif.sda_drv_x` (a *different* drive lane).
- The interface internally resolves them:
  ```systemverilog
  assign sda = sda_drv & sda_drv_x & dut_sda_o;   // wire-AND for open-drain
  ```

Each driver has its **own dedicated variable**, eliminating the multi-driver
compile error. The interface combines them into the shared bus.

**If you forgot this and both drivers wrote to `sda_drv` directly:**
- Compile error: *"Variable `sda_drv` has multiple continuous drivers"* or, in
  procedural code, simulation race with non-deterministic last-writer-wins.

> **Interview-grade answer:**
> *"Modeling multi-master open-drain in SV requires giving each master its own
> drive variable and resolving them in the interface — typically wire-AND for
> open-drain. If both masters wrote to the same variable, you'd get either a
> compile error or a race condition. The slave driver here uses `sda_drv_x` as a
> separate lane for the same reason."*

---

### Q13 — End of Test Termination

**Termination chain:**

1. Test calls `phase.drop_objection(this)` when its sequences finish.
2. The objection mechanism propagates: when **all** components have dropped
   objections, the phase's objection count reaches 0.
3. UVM moves to the next phase (`extract_phase`, etc.). The `run_phase` is
   declared "ended."
4. Any active threads in `run_phase` (including our driver's `forever` loop)
   are **killed** — UVM uses `disable fork` under the hood.

**What about an in-flight item?**

If the driver is mid-`drive_item` when the phase ends, the drive aborts where it
stands. The bus may be left in a partial state. The sequence may have a pending
`finish_item` that never returns — but since the phase ended, the sequence is
also killed.

**Clean termination pattern:**

The test must wait for the **last item to complete** before dropping the objection:

```systemverilog
task body();
  phase.raise_objection(this);
  fork
    foreach (items[i]) `uvm_do(my_seq);
  join                  // wait for ALL sequences to finish
  #100ns;               // grace period for last bus activity
  phase.drop_objection(this);
endtask
```

> **Interview-grade answer:**
> *"`run_phase` ends when the objection count reaches zero. UVM `disable`s all
> threads still running in the phase, including the driver's `forever` loop. If
> you drop objections too early, the last bus transaction is truncated mid-byte —
> the wave will show an incomplete byte and the DUT will be in an undefined state.
> The fix is always to wait for sequences to fully complete (and add a small
> drain time) before dropping objections."*

---

### Q14 — `fork...join_none` Choice

```systemverilog
if (compete_mode) begin
  fork
    drive_competition();
  join_none
end
forever begin ... end
```

| Variant | Behavior |
|---|---|
| `join` | Parent waits for ALL children to finish before continuing. Would block here forever (the child is itself `forever`-like) and the `forever` main loop would never start. **WRONG.** |
| `join_any` | Parent waits for ANY one child to finish. With one child, it's the same as `join`. **Still WRONG** for our case. |
| `join_none` | Parent does NOT wait for children. Spawns them and immediately continues. **CORRECT.** |

So `join_none` spawns the competing-master thread as a daemon and lets the main
loop run normally.

**Subtle point about lifetime:** A `fork...join_none` thread runs **only as long
as its parent process is alive**. Since the parent is `run_phase`, the competing
thread dies with the phase. Good.

> **Interview-grade answer:**
> *"`join_none` is the spawn-and-forget pattern. The parent doesn't block waiting
> for the child to finish, so it can proceed to the main `forever` loop while the
> background daemon runs. `join` would deadlock; `join_any` would behave like
> `join` with a single child. The child's lifetime is bounded by the parent —
> killing `run_phase` also kills the daemon, which is exactly what we want."*

---

### Q15 — Non-Automatic Driver Failure Mode

In SystemVerilog, **class methods are automatic by default** — every call gets
its own stack frame. **So most driver bugs around automatic-ness happen in
helper functions or tasks declared outside a class.**

The issue arises with **static lifetime** local variables in tasks/functions.
If you accidentally write `task` (no automatic keyword, in some legacy contexts)
or use `static` on locals, you can get:

**The kind of variable that corrupts:** **local variables of tasks/functions
that are called concurrently from multiple processes.**

Example:

```systemverilog
task drive_pulse();             // static lifetime in old Verilog
  int count;                    // shared across all callers
  for (count = 0; count < 10; count++) begin
    @(posedge clk);
    sda_drv <= ~sda_drv;
  end
endtask
```

If two `fork`-ed threads call `drive_pulse` at the same time, **they share `count`**.
The loop terminates erratically; pulse trains overlap nonsensically.

**For class methods:** Default is automatic. **You generally cannot reproduce
this bug inside a class method** unless you explicitly write `static` on a local
variable. (Class member variables, of course, are shared by all method calls on
that object — but that's normal.)

> **Interview-grade answer:**
> *"In SV, class methods default to automatic, so the typical 'static-locals'
> bug doesn't appear inside class bodies. It appears in package-level tasks /
> functions or in module-level tasks where `automatic` is not specified — there,
> local variables have static lifetime and are shared across concurrent calls.
> If a driver's helper task were static and called by two fork threads, the
> local counters would corrupt and you'd see non-deterministic bus waveforms
> that look like 'random simulator bugs.' The fix is to declare every shared
> task / function as `automatic` and never use `static` locals in TB code unless
> you genuinely want module-static state."*

---

## 12. Key Takeaways

### Conceptual

1. **Drivers are pull-based, not push-based.** The sequencer never pushes items;
   the driver pulls them via `seq_item_port.get_next_item`. This back-pressure
   mechanism throttles stimulus to DUT readiness.

2. **`get_next_item -> drive -> item_done` is the universal loop.** Every
   protocol driver follows this template. The body inside is protocol-specific;
   the framing is invariant.

3. **`item_done` is the gate; forget it and your sim hangs.** Every successful
   `get_next_item` must be paired with exactly one `item_done`. UVM has no
   garbage collection for missed `item_done`.

4. **Virtual interfaces are class handles to the physical interface.** They're
   wired via `uvm_config_db` in `build_phase`. Path mismatches are the #1 cause
   of null-pointer fatals in UVM environments.

5. **Bit-banging vs APB-driver choice is a function of DUT boundary.** Slave DUT
   → bit-bang. Master DUT → APB-style. Don't mix.

6. **Multi-master modeling requires per-source drive lanes** and interface-level
   resolution (wire-AND for open-drain). Single shared variable = compile error
   or race.

7. **Reset handling in drivers must cover mid-item reset.** Gating only at
   startup is a latent bug; production drivers use `fork-join_any` with a
   reset watcher.

8. **Clocking blocks > bare `@(posedge clk)`.** Clocking blocks enforce
   setup/hold timing automatically and prevent driver-sampler races.

9. **Pipelining is a protocol property**, not a driver implementation choice.
   I2C cannot pipeline; AXI can. Driver structure reflects this.

10. **Master driver here is a *bus protocol* driver. Slave driver is a *behavior
    selector* driver.** Same UVM machinery, fundamentally different role.

### Career-Critical

- **`config_db` path mismatch is the most common UVM bug you'll ever debug.** Master
  `+UVM_CONFIG_DB_TRACE` now; it'll save you 100 hours over your career.

- **The `get_next_item / item_done` rendezvous comes up in every UVM interview.**
  Be able to draw the sequence diagram from memory.

- **The bit-bang vs APB-driver question is a senior-grade litmus test.** Freshers
  get it wrong; mid-levels get it right; seniors discuss the trade-offs unprompted.

- **Reset-mid-item handling is the question that separates "I followed a tutorial"
  from "I built a real driver."** Tutorials skip it; production code requires it.

- **Pipelining knowledge is mandatory for AMBA / DDR / PCIe roles.** I2C is your
  *gateway*; build the mental model now so it transfers cleanly.

---

## 13. Action Items

- [ ] Re-read this lesson **once a week for 4 weeks**. By week 4 you should be
      able to recite the elevator pitch (Section 2) from memory.

- [ ] Redo the 15-question quiz **without looking at answers** in 3 days. Aim
      for 12/15.

- [ ] **Add a clocking block** to `i2c_if`. Refactor the master driver to drive
      through the clocking block (`vif.driver_cb.sda_drv <= ...`) instead of
      bare interface signals. This eliminates race conditions and is what
      production UVCs look like. **Estimated effort: 2 hours.** **Interview value:
      enormous.**

- [ ] **Add reset-mid-item handling** to the master driver. Wrap the per-item
      drive in a `fork-join_any` against `@(negedge vif.rst_n)`. Test by
      asserting reset mid-transaction and confirming the driver releases pins
      cleanly. **Estimated effort: 3 hours.**

- [ ] **Propose pipelined transaction support** (Stretch). Even though I2C
      can't pipeline at the byte level, you can queue up multiple *transactions*
      back-to-back without dropping STOP between them (Repeated START chains).
      Refactor the driver to accept a queue of items and decide when to issue
      a STOP based on lookahead. **Interview talking point:** "I noticed the
      protocol allows Repeated START to chain transactions without bus release;
      I built a pipelined driver that exploits this for higher throughput."

- [ ] **Add an exclusive-access mode** (Stretch). Some I2C controllers support a
      "transaction lock" where one master holds the bus across multiple Repeated
      STARTs to prevent another master from interleaving. Add a `lock_bus` flag
      to the sequence item and have the driver hold off `item_done` until the
      lock is explicitly released. **Real-silicon parallel:** AXI exclusive
      access. **Interview value: high.**

- [ ] **Add a `+UVM_CONFIG_DB_TRACE` run** to your standard regression command
      line and inspect the log once. Build muscle memory for what the trace
      output looks like; you'll need it the day a vif goes null in production.

- [ ] When you reach the **scoreboard** lesson, return here and trace the path
      of `req_analysis_port.write(req_item)` all the way into the scoreboard's
      `write` callback. End-to-end TLM understanding is interview gold.

---

## 14. Honest Self-Score Template

After completing the quiz cold, fill this in honestly:

| Area | Score | Status | Notes |
|---|---|---|---|
| UVM phase order | / | | |
| `get_next_item` vs `try_next_item` vs `peek` | / | | |
| `item_done` semantics + hang failure mode | / | | |
| vif null debug methodology | / | | |
| Driving inout with `oe` discipline | / | | |
| Reset-mid-item handling | / | | |
| Bit-bang vs APB master driver choice | / | | |
| Pipelining concept + I2C vs AXI | / | | |
| Clock-aligned driving rationale | / | | |
| `finish_item` vs `item_done` rendezvous | / | | |
| Seq item type vs driver type parameterization | / | | |
| Dual drivers on one bus modeling | / | | |
| End-of-test termination chain | / | | |
| `join`/`join_any`/`join_none` choice | / | | |
| Automatic vs static task locals | / | | |

**Scoring guide:**
- **0%** — Wrong or no answer. Re-read the relevant section, schedule a re-quiz in 3 days.
- **50%** — Right instinct, missing the senior framing. Re-read the "Interview-grade answer" callout for that question.
- **100%** — Could deliver the senior answer in an interview without notes.

**Target after one revision pass:** average ≥ 70% across all rows.
**Target after four revision passes:** average ≥ 90% across all rows, with no row below 70%.

---

**End of Lesson 09.**

Next up — Lesson 10: the **monitor** and analysis-port plumbing. The monitor is
the driver's mirror image: it observes, never drives, and feeds the scoreboard.
Once you understand both, you can describe a complete UVC end-to-end in an
interview — which is the line between fresher and mid-level.
