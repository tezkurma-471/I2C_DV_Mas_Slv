> **⚠️ 2026-06-10 AUDIT UPDATE — read this box before trusting the lesson below.**
> A deep audit + fix pass changed the code this walkthrough describes. Deltas for this file:
> - Stretch-detection threshold rescaled from >260 to >64 consecutive SCL-low cycles — the new BFM's normal low phase is ~16 cycles, and slave stretch sequences now use 200-400 cycles.
> Full detail: [`19_audit_fixes_walkthrough.md`](./19_audit_fixes_walkthrough.md) and `docs/AUDIT_FIX_REPORT.md`.

# Lesson 10 — `i2c_monitor.sv` + `i2c_slave_monitor.sv` Deep Dive

**Files under study:**
- `uvm/i2c_monitor.sv` (~165 lines, master-side bus monitor)
- `uvm/i2c_slave_monitor.sv` (~80 lines, DUT-status monitor)

**Concepts covered:** UVM monitor role, passive observation, `uvm_analysis_port` TLM 1:N broadcast, transaction reconstruction state machine, clocking-block sampling, race-free sampling, START/STOP/Repeated-START parsing, subscriber pattern, analysis_port vs analysis_imp, master-monitor vs slave-monitor role separation.

**Date:** 2026-05-17
**Prerequisite lessons:** 01 (`i2c_pkg`), 08 (driver), 09 (sequencer)

---

## Table of Contents

1. [Monitor's Role in UVM — Why It Exists](#1-monitors-role-in-uvm--why-it-exists)
2. [The 60-Second Elevator Pitch](#2-the-60-second-elevator-pitch)
3. [Master Monitor Walkthrough — `i2c_monitor.sv`](#3-master-monitor-walkthrough--i2c_monitorsv)
4. [Slave Monitor Walkthrough — `i2c_slave_monitor.sv`](#4-slave-monitor-walkthrough--i2c_slave_monitorsv)
5. [The `uvm_analysis_port` Mechanic — TLM 1:N Broadcast](#5-the-uvm_analysis_port-mechanic--tlm-1n-broadcast)
6. [Reconstructing Protocol Transactions from Raw Signals](#6-reconstructing-protocol-transactions-from-raw-signals)
7. [Sampling Timing — Clocking Blocks, Input Skew, Race-Free Sampling](#7-sampling-timing--clocking-blocks-input-skew-race-free-sampling)
8. [End-of-Transaction Detection — STOP and Repeated START Parsing](#8-end-of-transaction-detection--stop-and-repeated-start-parsing)
9. [Quiz — 12 Questions](#9-quiz--12-questions)
10. [Quiz — Answers & Deep Explanations](#10-quiz--answers--deep-explanations)
11. [Key Takeaways](#11-key-takeaways)
12. [Action Items](#12-action-items)
13. [Honest Self-Score Template](#13-honest-self-score-template)

---

## 1. Monitor's Role in UVM — Why It Exists

Before reading a single line of monitor code, you must answer one question correctly: **what is the monitor's job, and what is it explicitly NOT allowed to do?**

### The One-Line Definition

> A UVM monitor is a **passive component** that **samples DUT signals**, **reconstructs them into transaction objects**, and **broadcasts those objects** to all subscribers via a `uvm_analysis_port`.

Read that again. Three verbs: **sample, reconstruct, broadcast.** Not "drive." Not "react." Not "force."

### The Cardinal Rule — Monitors Are Passive

A monitor **never drives a signal**. Ever. Not SDA, not SCL, not even a `reg` it accidentally created. The moment a monitor writes to the bus, it stops being a monitor and becomes a (broken) driver.

This isn't pedantry. It's the foundation of UVM topology:

```
  +-------------+        passive observation         +--------+
  |  DUT pins   |  ──────────────────────────────►   | MON    |
  +-------------+                                    +--------+
        ▲                                                │
        │ driven by                                      │ analysis_port
        │                                                │ (broadcast)
  +-------------+                                        ▼
  |  DRIVER     |                                    +--------+--------+
  |  (active)   |                                    | SCOREBOARD       |
  +-------------+                                    | COVERAGE         |
                                                     | PREDICTOR        |
                                                     +------------------+
```

**Driver and monitor sit on the same interface but face opposite directions.** Driver writes to `vif.<signal>`. Monitor only reads `vif.<signal>`. If you ever write a monitor that contains `vif.sda <= ...`, you have committed a UVM crime.

### Why Monitor's Independence Matters

The most common interview trap on this topic:

> *"You drove a sequence onto the bus. Why don't you just publish the original `seq_item` to the scoreboard? Why bother building a monitor that re-samples what you already drove?"*

The brutally-honest answer: **because the driver might be lying to you.** Consider:

- Driver issues `CMD_WRITE(0xAB)`. But a glitch on SDA causes the slave to interpret it as `0xAA`. If the scoreboard compares "expected `0xAB`" against "what the driver said it sent (`0xAB`)" — bug is INVISIBLE.
- If instead the scoreboard compares "expected `0xAB`" against **"what the monitor observed on the wire (`0xAA`)"** — the bug LIGHTS UP.

The monitor exists to give the scoreboard an **independent witness**. The driver's `seq_item` is the *intent*. The monitor's `seq_item` is the *observed reality*. Verification = comparing intent against reality.

If those two diverged, you have a bug. If they match, you have at least one passing test.

### The Two Monitors in This Project

There are **two distinct monitors**, observing **two distinct interfaces**:

| Monitor | Interface | What it observes | Output transaction |
|---|---|---|---|
| `i2c_monitor` | `i2c_if` (SDA/SCL bus pins) | The actual wire-level I2C protocol | `i2c_seq_item` (master-perspective transaction) |
| `i2c_slave_monitor` | `i2c_slave_if` (DUT status pins) | Internal slave state: `addr_match`, `rx_data_valid`, `active`, `bus_error`, register bank | `i2c_slave_status_item` |

This separation is deliberate. The bus monitor doesn't know about the DUT's internals. The slave monitor doesn't know about bus protocol. **Each monitor has exactly one concern.** This is the **Single Responsibility Principle** applied to UVM components.

---

## 2. The 60-Second Elevator Pitch

When the NVIDIA/Qualcomm/Intel interviewer asks: *"Walk me through the monitor in your UVM environment,"* this is what you say:

> *"My environment has two passive monitors. The first is `i2c_monitor`, which sits on the SDA/SCL bus and reconstructs I2C transactions from raw signal transitions — it detects START as SDA falling while SCL is high, samples each data bit on SCL's rising edge, shifts bits into an 8-bit register, then on the 9th edge reads the ACK/NACK and pushes the byte into the current transaction object. It detects Repeated START by seeing another START condition while still inside a transaction, and STOP as SDA rising while SCL is high. It also tracks clock stretching by counting consecutive SCL-low cycles. The second monitor, `i2c_slave_monitor`, observes DUT-internal status signals — `addr_match`, `rx_data_valid`, `bus_error` — and publishes them as separate transactions. Both monitors broadcast via `uvm_analysis_port` to the scoreboard and coverage subscribers. Crucially, neither monitor ever drives a signal — they only sample. This independence is what lets the scoreboard catch driver bugs."*

Memorize the **shape**. The shape is: (1) two monitors, (2) bus vs status, (3) reconstruction state machine, (4) analysis port broadcast, (5) passive.

---

## 3. Master Monitor Walkthrough — `i2c_monitor.sv`

This is the big one — ~165 lines of dense protocol-reconstruction logic. We'll walk it top-to-bottom.

### 3.1 Class Declaration and `uvm_component_utils`

```systemverilog
class i2c_monitor extends uvm_monitor;
  `uvm_component_utils(i2c_monitor)
  ...
endclass
```

`uvm_monitor` is just a thin subclass of `uvm_component` with no extra behavior — it exists purely as a **semantic marker**. Two reasons to inherit from it instead of `uvm_component` directly:

1. **Self-documenting code.** Anyone reading the class declaration sees the role instantly.
2. **Some UVM IDEs / linters / coverage tools** filter by base class — a `uvm_monitor` subclass might get treated differently than a `uvm_driver` subclass for tool-specific features.

`` `uvm_component_utils`` is the macro that registers the class with the UVM factory. Without it, `i2c_monitor::type_id::create()` won't work, and you can't override this monitor with a subclass via `set_type_override_by_type()`.

**Interview trap:**
> *"What's the difference between `` `uvm_component_utils`` and `` `uvm_object_utils``?"*
>
> `uvm_component_utils` is for components (live in tree, have phases). `uvm_object_utils` is for transient objects (sequence items, configs). **A monitor is a component. A `seq_item` is an object.** Use the right macro or factory creation fails silently.

### 3.2 Member Variables — The Reconstruction State

```systemverilog
virtual i2c_if vif;
uvm_analysis_port #(i2c_seq_item) item_collected_port;

i2c_seq_item    current_item;
logic [7:0]     shift_reg;
int             bit_cnt;
bit             in_transaction;
bit             addr_phase;
int             scl_low_cnt;
int             rep_start_chain_depth;
```

Every variable here has a purpose. Let me unpack each:

| Variable | Purpose |
|---|---|
| `vif` | Virtual interface handle — the monitor's only window to DUT pins |
| `item_collected_port` | The TLM 1:N broadcast endpoint to subscribers |
| `current_item` | In-flight transaction being built bit-by-bit |
| `shift_reg` | 8-bit serial-in register — holds bits as they arrive from SDA |
| `bit_cnt` | 0..8 counter; 0-7 are data bits, 8 is the ACK bit |
| `in_transaction` | Sticky flag — true between START and STOP |
| `addr_phase` | True for the FIRST byte after START (the address byte) |
| `scl_low_cnt` | Tracks consecutive SCL-low cycles to detect clock stretching |
| `rep_start_chain_depth` | Counts back-to-back Repeated STARTs for coverage |

**Why so much state?** Because reconstructing a transaction from raw SDA/SCL is **inherently stateful**. The monitor is replicating, in software, the DUT's protocol state machine — but only as much as it needs to interpret the bus.

### 3.3 `build_phase` — Wiring the Analysis Port and Virtual Interface

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  item_collected_port = new("item_collected_port", this);
  if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", vif)) begin
    `uvm_fatal(get_type_name(), "Virtual interface not found in config_db")
  end
endfunction
```

Three things happen here:

1. `super.build_phase(phase)` — call the parent first. Always. Skipping this breaks UVM phase orchestration.

2. `item_collected_port = new(...)` — the analysis port is **constructed**, not declared in-line. Forgetting this is a textbook UVM null-pointer crash: `port.write()` segfaults because the port handle is null.

3. `uvm_config_db::get(...)` — pull the virtual interface from the config database. The `i2c_vif` string is the **key** used by whoever called `uvm_config_db::set(...)` (typically the test or top-level testbench). If the key doesn't match exactly, the `get` returns 0 and `` `uvm_fatal`` halts simulation.

**Common student bug:** mismatched config-DB keys ("i2c_vif" vs "i2c_if" vs "vif") — a one-character typo and the entire monitor silently dies.

### 3.4 `run_phase` — The Forever Sampling Loop

```systemverilog
virtual task run_phase(uvm_phase phase);
  fork
    monitor_bus();
  join
endtask
```

A `fork ... join` with a single task is functionally identical to just calling `monitor_bus()` directly. The pattern here suggests the author **anticipated forking multiple parallel monitor threads later** (e.g., one for protocol, one for timing-check, one for stretch-watchdog). Today it's a hint about future scalability.

A simpler form would be:

```systemverilog
virtual task run_phase(uvm_phase phase);
  monitor_bus();
endtask
```

But the `fork-join` is harmless and documents intent.

### 3.5 `monitor_bus` — The Heart of the Monitor

This is a 90-line procedural task. We'll dissect it section by section.

#### 3.5.1 Initialization

```systemverilog
logic prev_sda, prev_scl;
bit   saw_rep_start;
prev_sda = 1'b1;
prev_scl = 1'b1;
saw_rep_start = 0;
scl_low_cnt = 0;
rep_start_chain_depth = 0;
```

Initialize `prev_sda` and `prev_scl` to `1'b1` because **I2C bus idle state is HIGH** (both lines pulled up). If you initialize them to `0` or `X`, the very first cycle of simulation will falsely look like a SDA-falling-edge (a START condition) and corrupt the monitor's state.

This is a classic "edge-detection trap": **edge detectors must be initialized to the bus's idle state**, never to 0 or unknown.

#### 3.5.2 The `forever` Loop

```systemverilog
forever begin
  @(posedge vif.clk);
  ...
end
```

This is the heartbeat: sample on every system-clock rising edge. Note that the monitor synchronizes to the **system clock**, not to SCL. This is critical because:

- SCL is itself a generated signal — it can stretch, glitch, or be paused.
- By sampling on system clock, the monitor sees SCL and SDA as ordinary signals it can analyze for edges.
- Sampling on SCL would create a chicken-and-egg problem: how do you detect a missing SCL edge if SCL is your clock?

**Interview-grade answer:**
> *"The monitor samples on system clock, not SCL, because SCL is one of the signals being observed — using it as a clock would prevent the monitor from detecting SCL stretching, glitches, or stuck-low conditions. System clock provides a stable, always-running reference."*

#### 3.5.3 Stretch Detection

```systemverilog
if (vif.scl === 1'b0) scl_low_cnt++;
else                   scl_low_cnt = 0;
if (in_transaction && scl_low_cnt > 260 && current_item != null)
  current_item.stretch_seen = 1'b1;
```

The slave is allowed to "stretch" SCL — hold it low past the master's intended low-period — to delay the next bit. The master must wait. If SCL stays low for more than `260` system-clock cycles (slightly more than a normal half-period of 250), the monitor flags `stretch_seen` on the in-flight transaction.

Why 260, not exactly 250? **Tolerance.** A normal half-period is 250 ticks; anything substantially longer is stretching. 260 is "normal half-period plus 10 cycles of slop." A real production monitor might make this a config-knob.

The use of `===` (case-equality) rather than `==` is intentional: it matches `X` and `Z` literally, so a stuck-`X` SCL doesn't get treated as low.

#### 3.5.4 START Detection

```systemverilog
if (vif.sda === 1'b0 && prev_sda === 1'b1 && vif.scl === 1'b1) begin
```

**The I2C START condition definition:** SDA falls while SCL is high. Implemented as:
- `prev_sda === 1'b1` (SDA was high last cycle)
- `vif.sda === 1'b0` (SDA is low this cycle) → falling edge
- `vif.scl === 1'b1` (SCL is high right now)

All three must be true *in the same clock cycle* to register a START.

The block below it splits into two cases:

```systemverilog
if (in_transaction && current_item != null) begin
  // Repeated START — finalize the current item first
  finalize_and_write_item();
  saw_rep_start = 1;
end else begin
  // Fresh START
  saw_rep_start = 0;
end
```

**This is the Repeated-START handler.** If a START is seen while already inside a transaction, this is by definition a Repeated START — the master is starting a new transfer without releasing the bus. The monitor:

1. Closes out the current item (sends it to the scoreboard).
2. Sets `saw_rep_start = 1` so the **next** item is flagged as Repeated.
3. Creates a fresh `current_item` to start collecting the new transfer.

The `saw_rep_start` flag is the trick: the START handler doesn't know yet whether this is "first START of a series" or "Repeated START in a chain." It uses `in_transaction` to decide and sets the flag for the new item.

```systemverilog
current_item = i2c_seq_item::type_id::create("mon_item");
in_transaction = 1;
addr_phase = 1;
bit_cnt = 0;
shift_reg = 8'h00;
current_item.start_cond = 1;
current_item.rep_start  = saw_rep_start;
```

After START:
- New item created via the **factory** (`type_id::create`). This is what makes the monitor's output overridable by a subclass.
- `in_transaction = 1` — flips the sticky flag.
- `addr_phase = 1` — the next 8 bits will be address+R/W, not data.
- `bit_cnt = 0`, `shift_reg = 0` — reset the bit assembler.

#### 3.5.5 STOP Detection

```systemverilog
if (vif.sda === 1'b1 && prev_sda === 1'b0 && vif.scl === 1'b1) begin
  if (in_transaction) begin
    current_item.stop_cond = 1;
    finalize_and_write_item();
    in_transaction = 0;
    ...
  end
end
```

**STOP = SDA rising while SCL is high.** Mirror of START.

When STOP is seen:
- Mark the current item with `stop_cond = 1`.
- Finalize and publish.
- Reset all state. The transaction is over.

Note that STOP **always closes the transaction**. There's no "stop mid-byte" handling because STOP can only legally occur between bytes (after an ACK). If it occurred mid-byte, that would be a protocol violation — and your monitor would still flag SOME final state, but the partial-byte data would be garbage.

A more robust monitor would explicitly flag protocol violations (e.g., "STOP seen with `bit_cnt != 0`"). This is an action item below.

#### 3.5.6 Data Sampling on SCL Rising Edge

```systemverilog
if (in_transaction && vif.scl === 1'b1 && prev_scl === 1'b0) begin
  if (bit_cnt < 8) begin
    shift_reg = {shift_reg[6:0], vif.sda};
    bit_cnt = bit_cnt + 1;
  end
  else if (bit_cnt == 8) begin
    // ACK/NACK handling
    ...
  end
end
```

**The shift-register trick.** I2C is MSB-first. On each SCL rising edge, the monitor:

1. Shifts the existing bits left by one.
2. Inserts the current SDA value as the new LSB.

After 8 rising edges, `shift_reg` holds the byte. After the 9th edge, it holds the ACK bit (sent by the receiver, which is the opposite party of whoever sent the byte).

**Why sample on rising edge?** Because the I2C spec says **SDA must be stable for the entire SCL-high window**. The transmitter sets up SDA while SCL is low, then SCL goes high — and SDA cannot change until SCL goes low again. So the rising edge is the **canonical, race-free sampling point**.

If you sampled on the falling edge of SCL, you'd be sampling right when the transmitter is about to change SDA. Race condition.

#### 3.5.7 ACK/NACK Handling

```systemverilog
if (bit_cnt == 8) begin
  if (vif.sda === 1'b0) begin
    if (addr_phase) current_item.addr_ack = 1'b1;
    else            current_item.byte_ack.push_back(1'b1);
  end else begin
    if (addr_phase) current_item.addr_ack = 1'b0;
    else            current_item.byte_ack.push_back(1'b0);
  end
```

The 9th bit is the **ACK**, sent by the *receiver*. Low (0) = ACK, high (1) = NACK. The monitor stores:
- `addr_ack` if this was the address byte
- pushes into `byte_ack` queue otherwise (one per data byte)

This per-byte ACK tracking is crucial: it lets the scoreboard verify that the slave ACK'd every byte the master expected, and lets coverage track ACK/NACK patterns.

```systemverilog
if (addr_phase) begin
  current_item.addr = shift_reg[7:1];
  current_item.dir  = i2c_dir_e'(shift_reg[0]);
  addr_phase = 0;
end else begin
  current_item.data.push_back(shift_reg);
  current_item.num_data = current_item.num_data + 1;
end

bit_cnt = 0;
shift_reg = 8'h00;
```

**Address byte split:** Top 7 bits = slave address. Bottom 1 bit = direction (R/W). The cast `i2c_dir_e'(shift_reg[0])` converts the raw bit to the enum type.

**Data byte:** Push into the dynamic `data` queue, increment `num_data`. Reset for next byte.

**`addr_phase = 0`** is the one-shot flip: after the first byte, every subsequent byte is data. The flag only resets to 1 when a new START is seen.

#### 3.5.8 Edge-Detector Bookkeeping

```systemverilog
prev_sda = vif.sda;
prev_scl = vif.scl;
```

At the bottom of every loop iteration, save the current values as "previous" for next cycle's edge detection. **Forgetting this is a fatal edge-detector bug** — you'd never see SDA fall or SCL rise.

### 3.6 `finalize_and_write_item` — The Publish Path

```systemverilog
virtual task finalize_and_write_item();
  if (current_item != null) begin
    if (current_item.addr != 0 || current_item.data.size() > 0) begin
      item_collected_port.write(current_item);
    end else begin
      `uvm_info(..., "skipping", UVM_HIGH)
    end
  end
endtask
```

This is the **single chokepoint** through which transactions reach subscribers. Three guards:

1. `current_item != null` — defensive against a STOP arriving before a START (malformed bus).
2. `addr != 0 || data.size() > 0` — skip empty items (e.g., back-to-back STARTs with no payload).
3. `write(current_item)` — the actual broadcast.

**Why is this a `task` and not a `function`?** Strictly speaking, `analysis_port.write()` is a blocking call only if subscribers do blocking work — but UVM analysis writes are **non-blocking by design**, so this could be a function. Making it a task gives the author latitude to add waits later (e.g., wait for synchronization with a scoreboard handshake) without changing every call site.

---

## 4. Slave Monitor Walkthrough — `i2c_slave_monitor.sv`

This file is much simpler — about 80 lines — because the slave monitor doesn't reconstruct bus protocol. It just **observes already-decoded DUT-internal status signals** and publishes them.

### 4.1 The `i2c_slave_status_item` — A Different Transaction Type

```systemverilog
class i2c_slave_status_item extends uvm_sequence_item;
  `uvm_object_utils(i2c_slave_status_item)

  logic [7:0] rx_data;
  bit         rx_data_valid;
  bit         addr_match;
  bit         active;
  bit         tx_ack;
  bit         tx_nack;
  bit         bus_error;
  logic [7:0] reg_bank [0:7];
  ...
endclass
```

This is **not** the same transaction class as `i2c_seq_item`. It's a separate type because:

- It describes **DUT internal state**, not bus protocol.
- It has fields like `addr_match` and `bus_error` that have no bus equivalent.
- It carries a snapshot of the 8-deep register bank.

**Two different transaction types → two different analysis_port template parameters → two independent broadcast streams.**

`uvm_object_utils` (not `uvm_component_utils`!) because a `seq_item` is a transient object, not a tree component.

### 4.2 The Monitor Class

```systemverilog
class i2c_slave_monitor extends uvm_monitor;
  `uvm_component_utils(i2c_slave_monitor)

  virtual i2c_slave_if vif;
  uvm_analysis_port #(i2c_slave_status_item) status_port;
```

Note the **different virtual interface** (`i2c_slave_if`) and **different analysis_port type** parameter. Same monitor pattern, completely independent wiring.

### 4.3 `build_phase`

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  status_port = new("status_port", this);
  if (!uvm_config_db#(virtual i2c_slave_if)::get(this, "", "i2c_slave_vif", vif))
    `uvm_fatal(...);
endfunction
```

Identical pattern to the master monitor: construct the port, fetch the vif. **Different config-db key** (`i2c_slave_vif`) — this is what ensures the right virtual interface lands here.

### 4.4 `run_phase` — Simpler, No Reconstruction

```systemverilog
virtual task run_phase(uvm_phase phase);
  forever begin
    @(posedge vif.clk);
    if (vif.rx_data_valid || vif.addr_match || vif.bus_error) begin
      i2c_slave_status_item item = i2c_slave_status_item::type_id::create("slv_status");
      item.rx_data       = vif.rx_data;
      item.rx_data_valid = vif.rx_data_valid;
      ...
      status_port.write(item);
    end
  end
endtask
```

This is a **trigger-on-event** monitor, not a state-machine reconstructor. On each clock edge, if any of the three "interesting" signals are asserted, snapshot the entire status set, publish.

**Why is this so much simpler than the bus monitor?** Because the DUT has already done the heavy lifting. By the time we see `rx_data_valid = 1`, the DUT has already:
- Detected START.
- Matched its address.
- Shifted in 8 bits.
- ACK'd.
- Latched the byte into a holding register.

The slave monitor is the easy half of the verification problem. The bus monitor is the hard half because **it has to do everything the DUT did**, in parallel, independently, to provide a check.

### 4.5 Subtle Issue — Edge-Sensitivity

A careful reader will spot: the slave monitor publishes a **new item every cycle that one of the trigger signals is high**. If `addr_match` stays high for 5 cycles, you get 5 nearly-identical items.

This is a **debatable design choice**:
- **Pro:** Scoreboard sees every cycle, can correlate exact timing.
- **Con:** Wasteful — most items are redundant.

A cleaner monitor would detect **rising edges** of `rx_data_valid` / `addr_match` / `bus_error` and emit one item per event. This is a refactor candidate (see Action Items).

---

## 5. The `uvm_analysis_port` Mechanic — TLM 1:N Broadcast

Let's get specific about what `item_collected_port.write(item)` actually does.

### 5.1 Analysis Port = 1-to-Many TLM Connection

In UVM/TLM, ports come in two flavors:

| Port type | Connection | Behavior |
|---|---|---|
| `uvm_blocking_put_port` | 1:1, blocking | Sender blocks until receiver consumes |
| `uvm_analysis_port` | **1:N**, **non-blocking** | Broadcast to all subscribers; sender never blocks |

The analysis port is specifically designed for **side-channel observation**: monitors publish what they see, and any number of scoreboards / coverage collectors / predictors can listen. No subscriber? No problem — the data is dropped silently.

### 5.2 How `connect_phase` Wires It

In the env's `connect_phase`:

```systemverilog
m_agent.monitor.item_collected_port.connect(m_scoreboard.observed_export);
m_agent.monitor.item_collected_port.connect(m_coverage.analysis_export);
m_agent.monitor.item_collected_port.connect(m_predictor.analysis_export);
```

The same port `connect()`s to multiple subscribers. Each subscriber declares a `uvm_analysis_imp` (implementation port) that implements a `write(T item)` function.

```systemverilog
// Inside scoreboard
uvm_analysis_imp #(i2c_seq_item, scoreboard) observed_export;

function void write(i2c_seq_item t);
  // process the observed item
endfunction
```

### 5.3 Under the Hood — What `port.write()` Does

When the monitor calls `item_collected_port.write(item)`:

1. The port iterates through its internal list of connected subscribers.
2. For each subscriber, it calls that subscriber's `write(item)` function **synchronously, in-order**.
3. Returns when all subscribers have processed.

**Critical subtleties:**

- All subscribers see the **same handle**. They receive a pointer, not a copy. If subscriber A modifies the item, subscriber B sees the modification.
- **This is a footgun.** Best practice: subscribers treat received items as **immutable**. If you must modify, **clone** first (`item.clone()`).
- Order of calls is **not guaranteed** to match connection order — it's implementation-defined.

### 5.4 `analysis_port` vs `analysis_imp` vs `analysis_export`

This trips up everyone. Here's the cheat sheet:

| Item | Lives where | Direction | Purpose |
|---|---|---|---|
| `uvm_analysis_port` | Producer (monitor) | OUT | Broadcasts data |
| `uvm_analysis_imp` | Consumer (scoreboard) | IN | Implements `write()` to handle data |
| `uvm_analysis_export` | Hierarchy passthrough | passthrough | Connects child's imp to parent's port |

**Rule of thumb:** Monitor = `port`. Scoreboard = `imp`. Env (intermediate component) = `export`.

### 5.5 Why Broadcast Matters for DV

The reason TLM analysis is 1:N is that **verification artifacts grow over time**. You start with one scoreboard. Then you add coverage. Then a reference model. Then a protocol checker. Then a transaction recorder. **Every one of these needs the same data stream.**

If the monitor used a 1:1 port, each new subscriber would require re-architecting the monitor. With 1:N analysis port, **the monitor doesn't care how many subscribers exist.** You can add or remove subscribers without touching monitor code.

This is **decoupling done right**.

---

## 6. Reconstructing Protocol Transactions from Raw Signals

This is the conceptual heart of the master monitor. Let's formalize what's happening.

### 6.1 The Monitor as a Software FSM

The monitor is a **state machine** parallel to the DUT's state machine. Both watch the same wires and decode the same protocol, but for different purposes:

- **DUT state machine:** Decode to **act** (latch data, ACK, drive next bit).
- **Monitor state machine:** Decode to **record** (build a transaction object).

The states in our monitor's implicit FSM:

```
        ┌─────────┐
        │  IDLE   │ ──── START detected ────┐
        └─────────┘                          │
             ▲                               ▼
             │                       ┌──────────────┐
             │ STOP                  │  ADDR_PHASE  │
             │                       │  (bit 0..7)  │
             │                       └──────────────┘
             │                               │
             │                       bit_cnt == 8
             │                               │
             │                               ▼
             │                       ┌──────────────┐
             │ ◄──── STOP ─────────  │  DATA_PHASE  │
             │                       │  (bit 0..7)  │
             │                       └──────────────┘
             │                               │
             │                       bit_cnt == 8
             │                               │
             │                               ▼
             │                       ┌──────────────┐
             │                       │  ACK_PHASE   │
             │                       │   (bit 8)    │
             │                       └──────────────┘
             │                               │
             │                       another data byte?
             │                               │
             └───── REP_START ◄──────────────┘
```

Note that **states are not stored as an enum** — they're implicit in the combination of `in_transaction`, `addr_phase`, and `bit_cnt`. This is a common UVM idiom: when the FSM is simple enough, flags are easier to read than a formal state register.

For a more complex protocol (PCIe, AXI, USB), a formal enum-driven FSM is mandatory.

### 6.2 Why Reconstruct at All?

Why doesn't the monitor just expose the raw SDA/SCL stream and let the scoreboard parse it? Two reasons:

1. **Abstraction.** The scoreboard shouldn't care that bytes are MSB-first or that the ACK bit is the 9th. It should compare `addr=0x50, dir=WRITE, data=[0xAB, 0xCD]` against expected.
2. **Centralization.** If parsing changed (e.g., switching to 10-bit addressing), you change it ONCE in the monitor, not in every subscriber.

This is the **TLM (Transaction-Level Modeling) principle**: communicate at the highest meaningful abstraction.

### 6.3 The Reconstruction Granularity Question

How much should the monitor reconstruct vs leave raw?

| Approach | Pros | Cons |
|---|---|---|
| Bit-level publish (every SDA value) | Maximum information | Subscribers drown in data |
| Byte-level publish (one item per byte) | Useful for ACK tracking | Loses transaction structure |
| Transaction-level (one item per START-STOP) | Matches stimulus level | Hides bus-cycle timing |

Our project uses **transaction-level** with byte-level metadata (`byte_ack` queue inside the transaction). This is the right call for protocol checking.

For **timing checks**, you'd add a parallel "timing monitor" that publishes bit-level events.

---

## 7. Sampling Timing — Clocking Blocks, Input Skew, Race-Free Sampling

This is the section where most candidates get cut in interviews. **Pay attention.**

### 7.1 The Race Condition Problem

A driver writes `vif.sda <= 1'b1` on a `posedge clk`. The monitor reads `vif.sda` on the same `posedge clk`. **What value does the monitor see — the new value or the old?**

**Answer:** In Verilog/SV, NBA (non-blocking assignment) updates happen in a specific scheduling region. Reading `vif.sda` in the same time step is **a race condition**: you might see old or new value, depending on the simulator's scheduler.

This is the **#1 cause of "passes in Mentor, fails in Synopsys" bugs**.

### 7.2 The Solution — Clocking Blocks

The clean fix is a **clocking block** in the interface:

```systemverilog
interface i2c_if(input logic clk);
  logic sda, scl;

  clocking mon_cb @(posedge clk);
    default input #1step;
    input sda, scl;
  endclocking

  clocking drv_cb @(posedge clk);
    default output #1;
    output sda, scl;
  endclocking
endinterface
```

The driver writes via `vif.drv_cb.sda <= ...` (with **#1 output skew** → NBA happens 1 time unit after `posedge`).
The monitor reads via `vif.mon_cb.sda` (with **#1step input skew** → sample taken just **before** `posedge`, in the preponed region).

**This guarantees** that the monitor sees the value that was stable *before* the driver's update. Race-free.

### 7.3 What This Project Does

Look back at the monitor code:

```systemverilog
forever begin
  @(posedge vif.clk);
  ...
  if (vif.sda === 1'b0 && prev_sda === 1'b1 && ...) ...
```

It reads `vif.sda` directly — **no clocking block.** This works because:
- I2C signals (SDA, SCL) change at human time-scales (microseconds).
- The system clock is much faster than I2C transitions (50 MHz vs 100 kHz → 500x).
- The race window is microscopic compared to the signal stability window.

In other words: **you can get away with raw signal sampling for slow protocols on a fast clock.** But for fast protocols (PCIe, DDR), clocking blocks are mandatory.

### 7.4 The Interview Trap

> *"Your monitor samples `vif.sda` directly without a clocking block. Is that a problem?"*

**Junior answer (wrong):** "No, because it works."

**Senior answer (right):**
> *"For this I2C environment it works because the signal transitions are 500 system-clock cycles apart, so race conditions are essentially impossible. But this is a code-smell — for a faster protocol or a different simulator scheduler, it would break. The right fix is to add a clocking block with `default input #1step` to make sampling race-free. I'd flag this as a tech-debt item in code review."*

### 7.5 Posedge vs Negedge — The Subtle Bug

The monitor samples data on **SCL rising edge** (correct, because SDA is stable then).

A common buggy pattern is sampling on **SCL falling edge**:

```systemverilog
if (vif.scl === 1'b0 && prev_scl === 1'b1) // WRONG — falling edge
  shift_reg = {shift_reg[6:0], vif.sda};
```

This is wrong because:
- The I2C transmitter is **about to change SDA** on SCL falling edge.
- You might catch SDA mid-transition.
- You'd miss data bits that completed cleanly within the SCL-high window.

**Always sample on rising edge for I2C.** This is in the spec.

---

## 8. End-of-Transaction Detection — STOP and Repeated START Parsing

End-of-transaction is more nuanced than it looks because I2C allows two ways to end a transaction-in-flight: **STOP** (true end) and **Repeated START** (transition to next transaction).

### 8.1 STOP Parsing

```systemverilog
if (vif.sda === 1'b1 && prev_sda === 1'b0 && vif.scl === 1'b1) begin
  if (in_transaction) begin
    current_item.stop_cond = 1;
    finalize_and_write_item();
    in_transaction = 0;
    ...
  end
end
```

The detection: **SDA rising edge while SCL is high.** Mirror of START.

The `if (in_transaction)` guard prevents spurious STOPs (e.g., during bus idle) from doing damage.

The completion sequence:
1. Mark `stop_cond = 1` on the current item.
2. Publish via analysis port.
3. Reset all in-flight state.

### 8.2 Repeated START — The Tricky One

Repeated START happens when the master wants to **start a new transfer without releasing the bus** — useful for multi-byte register reads (write the register address, then read its data without letting another master grab the bus).

In the bus monitor, Repeated START looks **identical** to a fresh START at the signal level. The only difference is **context**: we were already inside a transaction.

```systemverilog
if (vif.sda === 1'b0 && prev_sda === 1'b1 && vif.scl === 1'b1) begin
  if (in_transaction && current_item != null) begin
    // Repeated START — finalize current first
    finalize_and_write_item();
    saw_rep_start = 1;
  end else begin
    // Fresh START
    saw_rep_start = 0;
  end
  current_item = i2c_seq_item::type_id::create("mon_item");
  ...
  current_item.rep_start = saw_rep_start;
```

The flow:
1. Detect START signal.
2. If already in transaction → finalize current, set flag.
3. Always create new item.
4. Mark new item with `rep_start` based on flag.

**Why this matters for verification:**
- The scoreboard needs to know which transactions are Repeated (chained) vs Fresh.
- Coverage wants to track chain depth (`rep_start_chain_depth` field) — back-to-back-to-back Repeated STARTs are an interesting corner case.
- The DUT must handle Repeated START correctly without leaking state from the prior transaction.

### 8.3 What `finalize_and_write_item` Skips

```systemverilog
if (current_item.addr != 0 || current_item.data.size() > 0) begin
  item_collected_port.write(current_item);
end else begin
  `uvm_info(..., "skipping", UVM_HIGH)
end
```

The skip path catches edge cases:
- A START immediately followed by another START (no address sent).
- A monitor reset mid-transaction.
- Malformed bus activity.

**Subtle bug here:** the condition `addr != 0` assumes a non-zero address. If the test addresses slave at address 0 (general-call), this skip will discard legitimate items. **This is an open issue worth flagging in code review.**

A safer condition: track a `has_addr_phase_completed` flag and check that instead.

---

## 9. Quiz — 12 Questions

Cover the answers section before reading. Aim for 8/12 on first try; 10/12 after review.

1. **Why is the monitor declared as passive (never drives signals)? What goes wrong if a monitor accidentally drives a signal?**

2. **The monitor publishes via `uvm_analysis_port`. Explain why this is 1:N (broadcast) and what would change if it were a `uvm_blocking_put_port` instead.**

3. **The bus monitor reconstructs full I2C transactions from raw SDA/SCL transitions. Walk through what the monitor needs to track (state variables) to perform this reconstruction.**

4. **Why does the monitor sample on `posedge vif.clk` (system clock) and not on `posedge vif.scl` (I2C clock)?**

5. **Why does this project need TWO monitors — `i2c_monitor` and `i2c_slave_monitor`? Why not just one?**

6. **The monitor effectively re-implements the DUT's protocol decoding FSM in software. Isn't this redundant? Justify why the monitor must do this independently.**

7. **End-of-transaction is detected by parsing STOP and Repeated START. What's the signal-level difference? At the protocol level, how does the monitor distinguish a Repeated START from a fresh START?**

8. **What's a race condition in monitor sampling, and how does a clocking block with input skew prevent it? Why does this monitor get away without a clocking block?**

9. **Explain the subscriber pattern: how do scoreboard and coverage subscribe to the same monitor output? Walk through `connect_phase`.**

10. **What's the difference between `uvm_analysis_port` and `uvm_analysis_imp`? Where does each live?**

11. **A monitor's `vif` and a driver's `vif` are typically the SAME virtual interface, yet they "face opposite directions." Explain.**

12. **The monitor calls `finalize_and_write_item()` to publish. What breaks if the monitor publishes mid-transaction (before STOP or Repeated START)?**

---

## 10. Quiz — Answers & Deep Explanations

### Q1 — Why Monitors Must Be Passive

**Senior-engineer answer:**

A monitor is an **independent witness**. The whole reason it exists is to give the scoreboard a view of bus activity that doesn't come from the driver. If the monitor were to drive any signal, two things break:

1. **Bus contention.** Drivers and monitors are connected to the same virtual interface. If both write to `vif.sda`, the simulator sees a multi-driver scenario → result is `X`. The DUT now sees a corrupted bus.

2. **Verification self-deception.** The whole point of an independent monitor is to compare *intent* (from driver/sequence) against *observed reality* (from monitor). If the monitor also drives, the monitor is no longer reporting reality — it's reporting its own actions. You lose the independent witness, and bugs that manifest only in the driver's signal generation go invisible.

**Concrete example:** Suppose the driver has a bug that produces a 99 ns SCL period instead of 100 ns. If the monitor independently samples the bus, it sees the 99 ns and the timing scoreboard flags it. If the monitor uses the driver's intended values directly, the bug is invisible.

**Interview-grade answer:**

> *"A monitor must be passive because it's the independent observer in the agent. Driving from the monitor would create bus contention with the driver, but more importantly it would compromise the entire verification methodology — the monitor exists to capture observed bus reality and compare it against the driver's intent. If the monitor drives, you lose your ability to detect driver bugs."*

---

### Q2 — `uvm_analysis_port` vs `uvm_blocking_put_port`

**Analysis port (1:N, non-blocking):**

```systemverilog
uvm_analysis_port #(i2c_seq_item) item_collected_port;
...
item_collected_port.write(item);  // returns immediately
```

- Connects to **any number** of subscribers.
- The `write()` call iterates through subscribers and invokes their `write(t)` function.
- Sender never waits. Subscribers process immediately.
- If no subscribers, data is dropped silently.

**Blocking put port (1:1, blocking):**

```systemverilog
uvm_blocking_put_port #(i2c_seq_item) put_port;
...
put_port.put(item);  // BLOCKS until receiver consumes
```

- Connects to **exactly one** receiver.
- `put()` blocks the sender until the receiver's `put()` task completes.
- Used for producer-consumer flows where backpressure matters (driver-sequencer).

**Why monitors use analysis port:**

1. Multiple consumers (scoreboard, coverage, predictor) need the same data.
2. Monitor mustn't be slowed down — sampling must be real-time.
3. If a subscriber crashes/blocks, the monitor must continue.

**What changes if you used blocking_put:**

- Only one subscriber possible.
- Monitor blocks if subscriber is slow → can MISS subsequent bus events.
- Adding a second subscriber requires architecture rework.
- This is the wrong port for side-channel observation.

**Interview trap:**
> *"Can a monitor block on its port?"* — No. Analysis ports are non-blocking; this is by design.

---

### Q3 — Monitor's State Variables for Reconstruction

To reconstruct an I2C transaction from raw signals, the monitor must track:

| Variable | Role |
|---|---|
| `current_item` | The in-flight transaction object being built |
| `shift_reg [7:0]` | Serial-to-parallel byte assembler |
| `bit_cnt 0..8` | Current bit position; 8 = ACK bit |
| `in_transaction` | Sticky flag: true between START and STOP |
| `addr_phase` | True for the first byte (address+R/W) |
| `prev_sda, prev_scl` | Previous-cycle signal values for edge detection |
| `scl_low_cnt` | Counts SCL-low cycles for stretch detection |
| `rep_start_chain_depth` | Tracks back-to-back Repeated STARTs |
| `saw_rep_start` | Carries Repeated-START context across handler boundary |

**Why this much state?**

Because raw SDA/SCL are bits — to extract the meaningful structure (transactions, address, ACK pattern), the monitor must build up state across many cycles. **Reconstruction is inherently stateful.** Stateless monitors only work for stateless protocols (e.g., parallel buses where every cycle is independent).

**Interview-grade answer:**

> *"The monitor implements a small protocol decoder FSM. It needs: a transaction object to populate, a shift register to assemble bytes serially, a bit counter to know where in the byte we are, and sticky flags for transaction-in-flight and address-phase. Plus edge-detection memory for SDA/SCL to detect START and STOP conditions. Without all of this, you cannot map raw signal transitions to protocol transactions."*

---

### Q4 — System Clock vs SCL for Sampling

**The monitor samples on system clock**, not SCL. Why?

1. **SCL is itself a signal being observed.** If you clocked the monitor on SCL, you couldn't detect SCL stretching, glitching, or stuck-low conditions — your monitor would freeze.

2. **SCL is not always running.** Between transactions, SCL is idle high. A monitor clocked on SCL would have no heartbeat during bus idle.

3. **System clock is the reference for everything else.** Stretching timeouts, watchdog counters, and statistics gathering all need a reliable always-running clock.

4. **Edge detection requires a clock that can see both states of the signal.** To see SCL's rising edge, you need a clock that ticks faster than SCL.

**The trade-off:**

- Sampling on system clock means you observe SCL transitions at system-clock granularity (20 ns). For SCL at 100 kHz (10 µs period), that's ~500x oversampling — plenty fine.
- For faster protocols (SPI at 100 MHz on a 200 MHz system clock), oversampling is only 2x — clocking-block guarded sampling becomes mandatory.

**Interview-grade answer:**

> *"The monitor samples on system clock at 50 MHz, not on SCL. This is essential because SCL is one of the signals being observed — using SCL as a clock would prevent detection of stretching, glitches, or stuck-low. System clock gives a 500x oversample of SCL transitions, plenty to detect every edge cleanly."*

---

### Q5 — Why TWO Monitors

There are two monitors because they observe **two physically distinct interfaces** at **two different levels of abstraction**:

| Monitor | Interface | Abstraction | Purpose |
|---|---|---|---|
| `i2c_monitor` | I2C bus (SDA/SCL) | Wire-level protocol | Reconstruct transactions for protocol checking |
| `i2c_slave_monitor` | DUT status pins | Decoded internal state | Track DUT FSM behavior |

**Could you merge them into one monitor?** Technically yes. But:

1. **Single Responsibility Principle.** One monitor with one job is easier to debug.
2. **Different sampling needs.** Bus monitor does heavy reconstruction; status monitor is event-driven.
3. **Different subscriber sets.** The bus scoreboard might not care about register-bank contents. The DUT-status checker doesn't care about ACK timing.
4. **Independent observability.** If the slave monitor reports `addr_match=1` but the bus monitor reports the wrong address, that's a DUT bug. The cross-check requires independent monitors.

**Senior insight:**

> *"The two monitors are independent because they verify orthogonal properties. The bus monitor verifies 'what did the master send onto the wire?' The slave monitor verifies 'how did the DUT respond internally?' Comparing the two is how you catch DUT decode bugs. If they were the same monitor, you'd lose the cross-check."*

---

### Q6 — Why Reconstruct What the DUT Already Decoded

**The junior answer:** "It IS redundant — just use the DUT's outputs."

**Why that's wrong:** If you trust the DUT to tell you what the bus is doing, you can't catch DUT decode bugs. Verification = comparing two **independent** views.

The monitor's reconstruction is the **golden reference** against which the DUT's behavior is checked:

- Monitor decodes the bus → "I see address 0x50 with WRITE direction."
- DUT decodes the bus → asserts `addr_match=1`.
- Scoreboard checks: do these agree?

If the DUT had a decode bug (say, it triggered `addr_match` for address 0x51), the monitor would still report 0x50, and the scoreboard would flag the mismatch.

**Without an independent monitor, the DUT's bug is invisible** because you have no other view to compare against.

**Interview-grade answer:**

> *"Yes, the monitor and DUT are doing the same decoding in parallel. But that's the whole point — verification means comparing two independent decoders. If the DUT decoder has a bug, only an independent decoder can detect it. If we trusted the DUT to tell us what the bus is doing, we couldn't verify the DUT's decoding."*

This is the **fundamental principle of verification**: golden reference must be independent of the design under test.

---

### Q7 — STOP vs Repeated START

**Signal-level definitions:**

| Event | Definition |
|---|---|
| START | SDA falling while SCL is high |
| STOP | SDA rising while SCL is high |
| Repeated START | Same as START, but seen while already in a transaction |

**The monitor distinguishes Repeated START from fresh START using context**, not signals — the protocol-level state (`in_transaction` flag) tells it which.

```systemverilog
if (vif.sda === 1'b0 && prev_sda === 1'b1 && vif.scl === 1'b1) begin
  if (in_transaction && current_item != null) begin
    // Repeated START
    finalize_and_write_item();
    saw_rep_start = 1;
  end else begin
    // Fresh START
    saw_rep_start = 0;
  end
```

**Why this matters:**

- A fresh START is at the **beginning** of a transaction sequence.
- A Repeated START is **mid-sequence** — it ends the previous transaction and starts a new one without releasing the bus.
- For verification: the scoreboard needs to know which is which, because the DUT's expected behavior differs (e.g., a Repeated START shouldn't trigger a fresh address-matching cycle from scratch in some implementations).

**Interview-grade answer:**

> *"At the signal level, START and Repeated START are identical — SDA falling while SCL is high. The distinction is purely protocol context: if we were already inside a transaction when the START is detected, it's a Repeated START; otherwise it's fresh. The monitor uses the `in_transaction` flag to make this distinction and stamps it on the new transaction object."*

---

### Q8 — Race Conditions and Clocking Blocks

**The race:**

In SystemVerilog, NBA (`<=`) updates happen in a specific scheduling region (NBA region). Reads happen in the Active region. If a driver writes `vif.sda <= 1'b1` on `posedge clk`, and a monitor reads `vif.sda` on the same `posedge clk`, the simulator's scheduling order determines whether the monitor sees the old or new value.

**Different simulators may schedule differently.** Same code, different sims, different results. **This is the canonical race condition.**

**The fix — clocking blocks with input skew:**

```systemverilog
clocking mon_cb @(posedge clk);
  default input #1step;
  input sda, scl;
endclocking
```

`default input #1step` means: when the monitor reads `vif.mon_cb.sda`, the read happens **1 simulation step before** the rising clock edge (in the **preponed** region). This is **before any updates** in the current cycle, so the monitor sees the **stable, settled value from the previous cycle**.

Combined with `default output #1` on the driver's clocking block, you get:
- Driver writes 1 unit AFTER posedge.
- Monitor reads 1 step BEFORE posedge.
- They can never alias.

**Why this monitor gets away without it:**

I2C signals change at microsecond timescales. System clock ticks every 20 ns. **By the time SDA actually moves, hundreds of clock cycles have passed** since the driver's NBA. The race window is functionally impossible to hit.

But this is a **smell**, not a guarantee. For faster protocols, or different simulators, the race could manifest. The right fix is to add a clocking block — it costs nothing and makes the monitor portable.

**Interview-grade answer:**

> *"Sampling races occur when a driver's NBA write and a monitor's read happen in the same time step — the simulator's scheduling order determines the result, which makes the testbench non-portable. The fix is a clocking block with `default input #1step`, which forces the monitor's sample into the preponed region — before any current-cycle updates. This monitor doesn't have one, which works for I2C because signal transitions are 500 system clocks apart, but it's a tech-debt item I'd flag in code review."*

---

### Q9 — The Subscriber Pattern in `connect_phase`

Subscribers connect to a monitor's analysis port in the **env's** `connect_phase`:

```systemverilog
function void connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  // Connect monitor output to multiple subscribers
  m_agent.monitor.item_collected_port.connect(m_scoreboard.observed_export);
  m_agent.monitor.item_collected_port.connect(m_coverage.analysis_export);
  m_agent.monitor.item_collected_port.connect(m_predictor.analysis_export);
endfunction
```

Each subscriber implements an `analysis_imp` with a `write(t)` function:

```systemverilog
// In scoreboard
`uvm_analysis_imp_decl(_observed)
class i2c_scoreboard extends uvm_scoreboard;
  uvm_analysis_imp_observed #(i2c_seq_item, i2c_scoreboard) observed_export;
  
  function void write_observed(i2c_seq_item t);
    // process the observed transaction
  endfunction
endclass
```

When the monitor calls `item_collected_port.write(item)`:
1. The analysis_port iterates through its connected subscribers.
2. For each, invokes their `write(item)` function.
3. All happen in the same simulation time step.
4. Monitor returns immediately after all subscribers have processed.

**Why this is powerful:**

- **Decoupling.** Monitor doesn't know what consumers exist.
- **Extensibility.** Add a new subscriber → add one `.connect()` line in env.
- **Testability.** Disable a subscriber → comment out the connect line. Monitor untouched.

**Interview-grade answer:**

> *"Subscribers connect via `.connect()` calls in the env's connect_phase. The monitor exposes a `uvm_analysis_port` and each subscriber exposes a `uvm_analysis_imp` (or analysis_export for hierarchical passthrough). When the monitor calls `port.write()`, the port iterates all subscribers and invokes their write function. The pattern decouples the monitor from its consumers — you can add scoreboard, coverage, predictor, recorder without touching monitor code."*

---

### Q10 — `analysis_port` vs `analysis_imp`

| Item | Direction | Lives in | Purpose |
|---|---|---|---|
| `uvm_analysis_port` | OUT (producer) | Monitor | Calls `write()`; broadcasts to all connected imps |
| `uvm_analysis_imp` | IN (consumer) | Scoreboard / Coverage | Receives `write()` calls; implements the handler |
| `uvm_analysis_export` | passthrough | Env / hierarchical container | Forwards from child's port to parent's imp |

**The mental model:**

A **port** is "I produce data."
An **imp** is "I consume data."
An **export** is "I'm just passing data through this hierarchy level."

**Imp declaration uses a macro for multiple ports:**

```systemverilog
`uvm_analysis_imp_decl(_observed)
`uvm_analysis_imp_decl(_expected)

class scoreboard extends uvm_scoreboard;
  uvm_analysis_imp_observed #(i2c_seq_item, scoreboard) observed_export;
  uvm_analysis_imp_expected #(i2c_seq_item, scoreboard) expected_export;
  
  function void write_observed(i2c_seq_item t);  ... endfunction
  function void write_expected(i2c_seq_item t);  ... endfunction
endclass
```

The macro generates a typed imp that calls a uniquely-named write function (so one scoreboard can receive multiple streams without naming collision).

**Interview trap:**
> *"Why can't a scoreboard just have two `uvm_analysis_imp`s with the same type parameter?"*
> Because both would try to call `write(t)` and there's no way to distinguish. The `_observed` / `_expected` decl macros generate `write_observed`/`write_expected` to disambiguate.

---

### Q11 — Same VIF, Opposite Directions

The driver and monitor in an agent both take the **same `i2c_if` virtual interface handle**. Yet they have opposite "directions":

- **Driver:** writes to `vif.sda`, `vif.scl`.
- **Monitor:** reads from `vif.sda`, `vif.scl`.

This is enabled by **clocking blocks defined inside the interface with different modports**:

```systemverilog
interface i2c_if(input logic clk);
  logic sda, scl;

  clocking drv_cb @(posedge clk);
    default output #1;
    output sda, scl;        // driver writes
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input sda, scl;         // monitor reads
  endclocking

  modport DRV (clocking drv_cb);
  modport MON (clocking mon_cb);
endinterface
```

The driver accesses `vif.drv_cb.sda` (write-only via output skew).
The monitor accesses `vif.mon_cb.sda` (read-only via input skew).

**Same handle, different views.**

This is **modular IO discipline** — the language enforces that the driver can only write and the monitor can only read, eliminating an entire class of bugs where a monitor accidentally drives a signal.

**Interview-grade answer:**

> *"Driver and monitor share the same virtual interface handle but access it through different clocking blocks — the driver's clocking block has output skew on SDA/SCL while the monitor's has input skew. This gives the driver a write-only view and the monitor a read-only view, which prevents accidental contention and makes the role separation enforceable by the language."*

---

### Q12 — What Breaks if Monitor Publishes Mid-Transaction

**If the monitor calls `item_collected_port.write(item)` before STOP or Repeated START (i.e., mid-byte or mid-transaction)**, multiple things break:

1. **Scoreboard sees incomplete transaction.** It receives `{addr=0x50, dir=WRITE, data=[0xAB]}` when the master is actually still sending more bytes. The compare against expected `{addr=0x50, dir=WRITE, data=[0xAB, 0xCD, 0xEF]}` fails — false-positive bug report.

2. **Coverage misclassifies the transaction.** Coverage point for "3-byte transfer" never gets hit because the monitor reports it as a 1-byte transfer.

3. **Predictor models wrong state.** If a reference model receives the partial item, it predicts the slave's state incorrectly.

4. **The item handle is published, but the monitor keeps modifying it!** After the premature `write()`, the monitor continues to push more bytes into `current_item.data`. **The scoreboard's reference now sees those bytes appearing retroactively** (because subscribers receive a handle, not a copy). This is a write-after-publish race that produces non-deterministic test failures.

The contract is: **publish only complete transactions.** The "complete" boundary is STOP or Repeated START (which terminates the current transaction and starts a new one).

**The fix in this monitor:** `finalize_and_write_item()` is called only:
- On STOP detection.
- On Repeated START detection (to close out the prior transaction before starting the new one).

Never mid-byte. Never mid-transaction.

**Interview-grade answer:**

> *"Publishing mid-transaction is a contract violation. Subscribers receive a handle, not a copy, so any subsequent modifications by the monitor become visible to subscribers retroactively — that's a write-after-publish race. Even ignoring the race, the scoreboard sees an incomplete transaction and either flags false mismatches or skips logic that needed the complete view. The right boundary is STOP or Repeated START, which is exactly what this monitor uses."*

---

## 11. Key Takeaways

### Conceptual

1. **Monitor = passive observer + transaction reconstructor + broadcaster.** Three jobs, in that order.

2. **Monitor never drives.** The independence is what gives the scoreboard the ability to catch driver and DUT bugs simultaneously.

3. **`uvm_analysis_port` is 1:N broadcast.** Multiple subscribers receive the same data with no monitor-side knowledge of how many subscribers exist.

4. **Reconstruction is a state machine.** The monitor replicates the DUT's protocol decoding logic in software, with its own state variables, edge detectors, and transition rules.

5. **Sample on the right clock at the right edge.** System clock for the monitor heartbeat. Protocol-defined edge (SCL rising for I2C) for data sampling. Mixing these up creates race conditions or missed transitions.

6. **Two monitors for two interfaces.** Bus monitor (wire-level) and slave-status monitor (DUT-internal). They check orthogonal properties and cross-check each other.

7. **End-of-transaction has two flavors.** STOP (true end) and Repeated START (chain continuation). Both must close the current item; only STOP releases the bus.

8. **Subscribers receive handles, not copies.** Treat received items as immutable, or clone before modifying.

### Career-Critical

- **You WILL be asked Q1, Q4, Q6, and Q12 verbatim in interviews.** Memorize the senior framing.
- **Race conditions and clocking blocks are the #1 distinguisher between juniors and seniors.** Q8 separates the two cleanly.
- **TLM port vs imp confusion is universal.** Burn Q10 into memory.
- **The "why two monitors" question (Q5) is a frequent system-architecture probe.** It's testing whether you understand orthogonality and the Single Responsibility Principle in verification context.

### Project-Specific

- The skip condition `addr != 0 || data.size() > 0` discards transactions to address 0 (general-call). **Open bug.**
- No clocking block on the monitor — works for I2C, but tech-debt.
- The slave monitor publishes every cycle the trigger signals are high — could emit duplicates. Refactor to edge-triggered.
- No protocol-violation detection — STOP mid-byte, SDA glitch during SCL-high, etc., are silently accepted.

---

## 12. Action Items

### Must-Do (this week)

- [ ] Re-do the quiz **without looking at answers** in 3 days. Target: 9/12.
- [ ] Trace through one real waveform from a simulation run and manually walk the monitor's FSM state. Verify your mental model matches the actual code's behavior.
- [ ] Read the master and slave monitor side-by-side one more time and write, in your own words, **why the slave monitor is so much simpler**.

### Improvement Refactors (1-2 weeks)

- [ ] **Add a clocking block to `i2c_if`** with `default input #1step` for monitor sampling. Update the monitor to read via `vif.mon_cb.sda` instead of `vif.sda`. Document the change in the lesson notes.

- [ ] **Edge-triggered slave monitor.** Refactor to emit one item per rising edge of `rx_data_valid`, `addr_match`, or `bus_error`. Add an `event_type` field so subscribers know which trigger fired.

- [ ] **Fix the `addr != 0` skip bug.** Replace with a proper `has_addr_phase_completed` flag so general-call addresses (0x00) are not silently discarded.

- [ ] **Protocol-violation detection.** Add a separate analysis port (`protocol_error_port`) that publishes violations: STOP mid-byte, SDA change during SCL-high outside of START/STOP, unexpected glitches. This is interview gold for "how would you make this monitor more robust?"

### Stretch Goals (advanced)

- [ ] **Statistics-gathering subscriber.** Build a new subscriber (`i2c_stats_collector`) that subscribes to `item_collected_port` and tracks: total transactions, ACK/NACK ratio, average bytes/transaction, max chain depth of Repeated STARTs, total bus-stall time from stretching. Print on `report_phase`.

- [ ] **Error-injection coverage.** Cross-reference the monitor's stretch detection with deliberate test-injected stretches to verify the monitor detects them every time. Write a covergroup for stretch-event detection.

- [ ] **UVM RAL integration.** When you get to UVM RAL training, return here and use the slave monitor's `reg_bank` field to mirror updates into a `uvm_reg_block`. This is a deep integration project — interview ammunition for senior roles.

### Documentation

- [ ] Add a header comment to `i2c_monitor.sv` listing the **invariants** the monitor maintains (e.g., "publishes only complete transactions," "never drives any signal," "sampling is race-tolerant for I2C timing").

- [ ] Document the **two-monitor architecture** in the project README — what each one verifies, why they're separate.

---

## 13. Honest Self-Score Template

Fill this in *after* attempting the quiz without notes. **Brutal honesty only** — fake high scores teach you nothing.

| Area | Score | Status |
|---|---|---|
| Monitor passive role | __% | ⚪ ___ |
| analysis_port broadcast mechanic | __% | ⚪ ___ |
| Transaction reconstruction FSM | __% | ⚪ ___ |
| System-clock vs SCL sampling | __% | ⚪ ___ |
| Two-monitor architecture rationale | __% | ⚪ ___ |
| Reconstruction independence (why not trust DUT) | __% | ⚪ ___ |
| STOP vs Repeated START distinction | __% | ⚪ ___ |
| Race conditions and clocking blocks | __% | ⚪ ___ |
| Subscriber pattern (connect_phase) | __% | ⚪ ___ |
| analysis_port vs analysis_imp vs analysis_export | __% | ⚪ ___ |
| Driver-monitor opposite directions on same VIF | __% | ⚪ ___ |
| Mid-transaction publishing failure modes | __% | ⚪ ___ |

**Scoring guide:**
- **0-30%:** Material is new — re-read the lesson, then retry in 2 days.
- **30-60%:** Partial understanding — identify the weak quiz questions and re-read those sections.
- **60-85%:** Solid grasp — review the senior framings once and move on.
- **85-100%:** Mastered — congratulations, but **stay humble**. Real interviews probe deeper than 12 questions.

**Status legend:**
- ⚪ New / unscored
- 🟡 Partial — needs review
- 🟢 Solid
- ✅ Interview-ready
- ❌ Got wrong — flag for re-study

---

### Closing Note from your big-brother engineer

The monitor is, in a sense, the **soul of the testbench**. Drivers come and go. Sequences change. Scoreboards evolve. But the monitor — the silent witness on the wire — is the part of UVM that makes verification meaningful. **Without an independent monitor, you're not verifying — you're just running stimulus.**

Two more lessons after this and we'll have the full agent architecture in your head. Stay sharp.
