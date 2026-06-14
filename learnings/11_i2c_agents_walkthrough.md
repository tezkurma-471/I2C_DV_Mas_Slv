# Lesson 11 — `i2c_master_agent.sv` & `i2c_slave_agent.sv` Deep Dive

**Files under study:**
- `uvm/i2c_master_agent.sv` (66 lines, 2.9 KB)
- `uvm/i2c_slave_agent.sv` (42 lines, 1.5 KB)

**Concepts covered:** UVM agent architecture, the bundle pattern, active vs passive agents, `uvm_active_passive_enum`, `is_active` conditional build, `config_db` propagation, `connect_phase` wiring (driver-sequencer TLM), analysis_port forwarding, multi-agent environments, the missed-`ap`-forwarding bug, factory overrides on agents, agent reuse across blocks, common interview traps.

**Date:** 2026-05-17
**Status:** This is the file that ties together everything you've built in Lessons 08-10. The agent is the smallest *reusable* unit in UVM. If you nail this lesson, you can drop these two classes into ANY future verification environment and they will work.

---

## Table of Contents

1. [UVM Agent Architecture — The Bundle Pattern](#1-uvm-agent-architecture--the-bundle-pattern)
2. [The 60-Second Elevator Pitch](#2-the-60-second-elevator-pitch)
3. [Master Agent — Line-by-Line Walkthrough](#3-master-agent--line-by-line-walkthrough)
4. [Slave Agent — Line-by-Line Walkthrough](#4-slave-agent--line-by-line-walkthrough)
5. [`uvm_active_passive_enum` — UVM_ACTIVE vs UVM_PASSIVE](#5-uvm_active_passive_enum--uvm_active-vs-uvm_passive)
6. [`config_db` — Propagating the Virtual Interface](#6-config_db--propagating-the-virtual-interface)
7. [`connect_phase` — Wiring `seq_item_port` to `seq_item_export`](#7-connect_phase--wiring-seq_item_port-to-seq_item_export)
8. [Analysis Port Forwarding — Re-Publishing the Monitor's Stream](#8-analysis-port-forwarding--re-publishing-the-monitors-stream)
9. [Why the Master Agent Has an `analysis_port` but the Slave Does Not](#9-why-the-master-agent-has-an-analysis_port-but-the-slave-does-not)
10. [Quiz — 10 Questions](#10-quiz--10-questions)
11. [Quiz — Senior-Engineer-Grade Answers](#11-quiz--senior-engineer-grade-answers)
12. [Key Takeaways](#12-key-takeaways)
13. [Action Items](#13-action-items)
14. [Honest Self-Score Template](#14-honest-self-score-template)

---

## 1. UVM Agent Architecture — The Bundle Pattern

Before you stare at a single line of code, internalize what an agent **is** and what an agent **is not**.

### The One-Sentence Definition

> **An agent is a UVM container that bundles a sequencer, a driver, and a monitor for one logical interface of the DUT.**

That's it. The agent itself has no behavior. It does not drive pins. It does not generate transactions. It does not check anything. It exists to **own** three things and present them to the environment as a single unit. Think of it as a folder — when you need to pass around the I2C-master capability, you pass the folder, not three separate files.

> **Interview-grade answer:** *"A UVM agent is a structural container — it owns the sequencer, driver, and monitor for one logical interface of the DUT and presents them to the environment as a single reusable unit. The agent itself contains zero behavior; all the work is delegated to the sub-components. Its job is encapsulation and reuse: any test environment that needs an I2C master can instantiate one i2c_master_agent and immediately have stimulus generation, pin-level driving, and bus observation. The bundle pattern is what makes UVM environments composable across projects."*

### Why Bundle Them?

Three reasons, in order of importance:

1. **Reuse.** When the next project needs an I2C master, you do not re-wire three sub-components — you instantiate one agent and walk away. The encapsulation is the *product*.
2. **Lifecycle ownership.** The agent is the unique parent of the sequencer, driver, and monitor. Their build, connect, and run phases happen under one umbrella. The `config_db` scope rules use this hierarchy.
3. **Active/passive switch.** A single boolean (`is_active`) controls whether the agent generates stimulus or just observes. This lets the same class participate in both the standalone testbench (active) and the system-level testbench (passive monitor only).

> **Interview-grade answer:** *"There are three reasons we bundle into agents. First, reuse — the agent is the unit you ship between projects. Second, lifecycle ownership — the agent is the unique parent of its three sub-components, which gives you a clean scope for config_db lookups and phase coordination. Third, the active/passive switch — by toggling one enum, the same agent class either drives stimulus or operates as a pure observer. That last property is what enables a master-agent class to be reused at system-level where the real RTL master is in the DUT and the testbench only needs to monitor it."*

### The Big Picture

```
+------------------------------- env -------------------------------+
|                                                                   |
|   +--------------- i2c_master_agent (ACTIVE) ---------------+    |
|   |                                                          |    |
|   |   +-----------+      +---------+       +----------+    |    |
|   |   | sequencer |----->|  driver |       | monitor  |    |    |
|   |   +-----------+      +---------+       +----------+    |    |
|   |                          |                  |          |    |
|   |                          v                  v          |    |
|   |                       (vif drv)         (vif mon)      |    |
|   |                          |                  |          |    |
|   |                          |                  | item_collected_port
|   |                          |                  |          |    |
|   |                          |                  v          |    |
|   |                          |          +------------+    |    |
|   |                          |          | analysis   |--->|---> scoreboard.actual_export
|   |                          |          | port (agt) |    |    |
|   |                          |          +------------+    |    |
|   |                          |                             |    |
|   +--------------------------|-----------------------------+    |
|                              |                                   |
|                              v                                   |
|                     +------------------+                         |
|                     | i2c_if (virtual) |--->  DUT pins (SCL/SDA) |
|                     +------------------+                         |
|                                                                   |
|   +--------------- i2c_slave_agent (PASSIVE) --------------+    |
|   |                                                          |    |
|   |   (no sequencer)     (no driver)      +----------+    |    |
|   |                                        | monitor  |    |    |
|   |                                        +----------+    |    |
|   |                                             |          |    |
|   |                                             v          |    |
|   |                                       (slave vif mon)  |    |
|   +----------------------------------------------------------+    |
|                                                                   |
+-------------------------------------------------------------------+
```

The diagram tells the whole story:

- The **active master agent** owns a sequencer, driver, and monitor. The sequencer feeds the driver through a TLM port. The monitor publishes observed items via its own `item_collected_port`, which the agent re-publishes via its own `analysis_port`. The environment connects the agent-level `analysis_port` to the scoreboard.
- The **passive slave agent** owns only the monitor (the slave_driver/sequencer exist for some configurations, but in the default-passive case they are absent). It does not connect to any analysis port at the agent level — the environment can reach into `slave_agent.monitor.item_collected_port` directly if needed.

> **Interview-grade answer:** *"The agent is the unit of encapsulation; the env is the unit of composition. The agent hides whether stimulus is being generated or not behind the active/passive switch. The env sees a uniform interface — an analysis port to subscribe to — and does not need to know if there is a driver inside. That separation is what lets the same agent code live in both a standalone block-level testbench and a system-level testbench where the master is part of the DUT."*

---

## 2. The 60-Second Elevator Pitch

> *"`i2c_master_agent.sv` is the UVM container for one I2C master interface. It owns three sub-components: a sequencer (which generates stimulus), a driver (which pulls/releases SCL and SDA), and a monitor (which observes the bus). In `build_phase`, the agent conditionally creates the sequencer and driver only if `get_is_active()` returns `UVM_ACTIVE` — that switch lets the same class be reused as a passive observer in system-level environments. In `connect_phase`, the agent wires the driver's `seq_item_port` to the sequencer's `seq_item_export` (this is the TLM put-pattern the driver uses to request the next transaction), and it forwards the monitor's `item_collected_port` to its own `analysis_port` so the environment has a single, agent-level subscription point. The slave agent is the same shape but smaller — passive by default, no agent-level analysis port, because the scoreboard subscribes to the slave monitor directly. The whole pattern is about presenting a clean, reusable interface to the env."*

If you can deliver that in 60 seconds, clearly, without "ums," you are at a senior-junior level on UVM agents.

---

## 3. Master Agent — Line-by-Line Walkthrough

Let's go top to bottom. I will not skip a single line, because every line is doing real work in UVM.

### File header

```systemverilog
//=============================================================================
// File          : i2c_master_agent.sv
// Description   : UVM Agent for I2C Master — wraps driver, monitor, sequencer.
//               : Active agent: drives stimulus AND observes the bus.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================
```

Standard banner. Note **UVM 1.2** — this matters when you read or write code that uses UVM 1.1 (no `report_phase` distinction), UVM 1.2 (current), or UVM IEEE-1800.2 (current standard, mostly compatible). API-level differences are minor for agents, but you should know what release you target.

### Include guard

```systemverilog
`ifndef I2C_MASTER_AGENT_SV
`define I2C_MASTER_AGENT_SV
...
`endif
```

> **Interview-grade answer:** *"The include guard is the C-style protection against double-compilation of the same class definition. In a UVM package compile, you do not strictly need it because the package only `include`s the file once — but when a file is `\`include`'d directly into a top-level testbench or used in a mixed-flow build with both package and file-list compilation, the guard prevents duplicate declarations. It costs nothing and protects against accidental double-inclusion. Industry convention is to always include it."*

### Class declaration

```systemverilog
class i2c_master_agent extends uvm_agent;
  `uvm_component_utils(i2c_master_agent)
```

Two important things here.

1. **`extends uvm_agent`** — not `uvm_component` directly. The base class `uvm_agent` adds the `is_active` field of type `uvm_active_passive_enum` and the `get_is_active()` accessor. If you used `uvm_component`, you would have to roll your own active/passive switch.

2. **`\`uvm_component_utils`** registers the class with the UVM factory. This single macro generates `type_id`, `create()`, `get_type_name()`, and registers the class so that `set_type_override_by_type()` and similar factory APIs work. Without it, you cannot do factory creation, and the test cannot override the type.

> **Interview-grade answer:** *"`uvm_component_utils` is the factory-registration macro. It does three things behind the scenes: it generates a static type proxy class so the factory can ask 'what is your concrete type?', it generates a public create function that the factory invokes via type_id::create, and it inserts the class into the factory's registration map. Without it, the class is just a regular SystemVerilog class — the line `i2c_master_agent::type_id::create(...)` would not even compile. The macro is what enables polymorphism through the factory, which is the cornerstone of UVM's test-portable architecture."*

### Sub-component handles

```systemverilog
  i2c_driver              driver;
  i2c_monitor             monitor;
  uvm_sequencer #(i2c_seq_item) sequencer;
```

Three handles, all `null` until `build_phase` creates the actual objects. Note that `sequencer` uses the parameterized base class `uvm_sequencer #(i2c_seq_item)` — we did not bother making a project-specific `i2c_sequencer` derived class because there is no custom behavior. This is the common pattern. **You only subclass `uvm_sequencer` when you need to add layered sequences, a custom `pre_body`/`post_body`, or arbitration overrides.**

> **Interview-grade answer:** *"Most projects use `uvm_sequencer #(item_type)` directly — there's rarely a reason to subclass it. You only derive your own sequencer when you need to override `select_sequence` for custom arbitration, add layered sequence APIs like a register-level interface, or expose extra hooks for the env. For 95 percent of agents, including this one, parametrizing the base class is enough."*

### Analysis port

```systemverilog
  uvm_analysis_port #(i2c_seq_item) analysis_port;
```

This is the agent-level analysis port — the thing the env subscribes to. It is *not* the monitor's port. The monitor has its own `item_collected_port`. The agent's `connect_phase` will forward one to the other.

Why have two ports?

- **The monitor's `item_collected_port`** is internal to the monitor. It exists so the monitor can broadcast without knowing who is listening.
- **The agent's `analysis_port`** is the *public face*. The env code only knows about the agent — it should never reach into `agent.monitor.item_collected_port`. By exposing an agent-level port, you give the env a stable, encapsulated interface.

> **Interview-grade answer:** *"You expose an agent-level analysis port to preserve encapsulation. The env should not be reaching into `agent.monitor.item_collected_port` — that breaks the agent's abstraction boundary and means anyone refactoring the monitor would also have to change every env that connects to it. By having the agent declare its own analysis port and forwarding the monitor's stream to it in connect_phase, the env code stays stable even if the agent's internal wiring changes. This is the same principle as a public API on a class — you only commit to the agent's interface, not its internals."*

### Constructor

```systemverilog
  function new(string name = "i2c_master_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction
```

Standard `uvm_component` constructor. The default values let you create without arguments (`new()`), but in practice the factory passes both name and parent.

### `build_phase` — the heart

```systemverilog
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = i2c_driver::type_id::create("driver",    this);
      sequencer = uvm_sequencer #(i2c_seq_item)::type_id::create("sequencer", this);
    end
    monitor       = i2c_monitor::type_id::create("monitor", this);
    analysis_port = new("analysis_port", this);
  endfunction
```

Read this carefully. Three things are happening:

1. **`super.build_phase(phase)`** — call the parent. Inside `uvm_agent::build_phase`, the framework reads `is_active` from the config_db (looking for the key `"is_active"` in this scope). If a value is set, `is_active` becomes that value. If nothing is set, `is_active` defaults to `UVM_ACTIVE`. This is **why you must call `super.build_phase` before checking `get_is_active()`** — otherwise you read the uninitialized default.

2. **Conditional creation of driver and sequencer.** If passive, we skip these. The monitor is always created — passive agents still observe.

3. **`analysis_port = new(...)`**. Note the syntax: analysis ports are not factory-created — they are plain `new()`. They have no parameters, no override pattern, no test customization. This is the *one* exception in a UVM build where you write `new(...)` instead of `type_id::create(...)`.

> **Interview-grade answer:** *"The order is critical: super.build_phase first, because that's where uvm_agent reads is_active from the config_db. If you check get_is_active() before calling super, you get the default-uninitialized value, which silently leads to wrong-mode agents. The conditional creation pattern means the agent never holds dangling handles to a sequencer or driver in passive mode — they remain null, which is the correct semantic for 'I am observing only.' Finally, analysis ports use plain `new` rather than type_id::create because they are pure TLM connections with no factory override semantics — they have nothing to override."*

### `connect_phase`

```systemverilog
  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
    monitor.item_collected_port.connect(analysis_port);
  endfunction
```

Two connections:

1. **`driver.seq_item_port.connect(sequencer.seq_item_export)`** — the TLM port-to-export wiring. This enables `driver.seq_item_port.get_next_item(req)` to call into the sequencer and request the next transaction. **The direction matters:** the driver *initiates* (it has the port), the sequencer *responds* (it has the export). This is the TLM "pull" model — driver pulls from sequencer, not the other way.

2. **`monitor.item_collected_port.connect(analysis_port)`** — forwarding. The monitor will call `item_collected_port.write(item)`. That call propagates through the connection to `analysis_port.write(item)`, which then fans out to every subscriber the env has connected.

> **Interview-grade answer:** *"The driver-sequencer connection uses the TLM port-export pattern where the driver is the initiator. The driver calls `seq_item_port.get_next_item(req)`, which blocks until the sequencer hands it a transaction. That pull semantic — driver pulls, sequencer waits — is what allows the driver to control timing: it only asks for new stimulus when it is ready to drive. The monitor-to-agent-port connection is a fan-out forwarding: when the monitor writes to its port, the call propagates through the agent's analysis port and out to every connected subscriber. Both connections live in connect_phase because that's when all sub-components are guaranteed to be built but no thread has started running yet."*

---

## 4. Slave Agent — Line-by-Line Walkthrough

```systemverilog
class i2c_slave_agent extends uvm_agent;
  `uvm_component_utils(i2c_slave_agent)

  i2c_slave_driver              driver;
  i2c_slave_monitor             monitor;
  uvm_sequencer #(i2c_slave_ctrl_item) sequencer;

  function new(string name = "i2c_slave_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = i2c_slave_monitor::type_id::create("monitor", this);
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = i2c_slave_driver::type_id::create("driver", this);
      sequencer = uvm_sequencer #(i2c_slave_ctrl_item)::type_id::create("sequencer", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction
endclass : i2c_slave_agent
```

Three structural differences from the master agent:

| Aspect | Master Agent | Slave Agent |
|---|---|---|
| Default mode | Active (env sets) | Passive (env sets) |
| Agent-level analysis port | Yes (`analysis_port`) | **No** |
| Sequencer item type | `i2c_seq_item` (transaction) | `i2c_slave_ctrl_item` (control / config) |
| Connect-phase forwarding | Forwards monitor port | None |

The big architectural call: **the slave agent does not have an agent-level analysis port**. Why? Because the env can reach `slave_agent.monitor.item_collected_port` directly and connect it to the scoreboard. The trade-off is a small encapsulation hit for code simplicity. **This is a project-specific design choice and you should know how to defend it in an interview.**

> **Interview-grade answer:** *"The slave agent in this project omits the agent-level analysis port for code simplicity — the env subscribes directly to `slave_agent.monitor.item_collected_port`. The trade-off is encapsulation versus boilerplate. The correct UVM-by-the-book pattern is to mirror the master agent and have a forwarded analysis port at the agent boundary. If I were refactoring this code, I would add one for consistency — it costs three lines and gains the right encapsulation boundary, especially for downstream reuse where someone else might want to wrap or filter the slave's observed stream without modifying the agent."*

### Why the slave uses `i2c_slave_ctrl_item` instead of `i2c_seq_item`

The slave sequencer drives the slave-side **control** behavior (when to clock-stretch, when to NACK, when to inject a glitch) — not the bus protocol per se. The bus protocol lives on `i2c_seq_item`, which the master sequencer generates. The slave is reactive — it responds to whatever the master puts on the bus. The control item parameterizes that response.

This is the standard UVM agent pattern for any reactive interface (memory model, slave PHY, peripheral DUT). The sequencer item describes *behavior modulation*, not *protocol transactions*.

> **Interview-grade answer:** *"The slave is a reactive interface — it doesn't generate the I2C protocol, it reacts to the master. The sequencer item type therefore describes behavior modulation: when to NACK, when to stretch, what address to claim. That is fundamentally different from the master's seq_item which is a full transaction descriptor. Using two separate item types is the correct factoring — confusing them by reusing i2c_seq_item on the slave side would conflate 'transaction observed' with 'control configuration,' which makes the code harder to read and harder to reuse."*

### Note on the build order in the slave

In the slave agent, the monitor is created **before** the `if (get_is_active())` block. In the master agent, the monitor is created **after**. Functionally equivalent — UVM components within `build_phase` are not order-sensitive among siblings. But stylistically, the slave's order (monitor first, then conditional) is slightly clearer because it expresses "the monitor always exists; the rest is conditional." Either order works.

---

## 5. `uvm_active_passive_enum` — UVM_ACTIVE vs UVM_PASSIVE

```systemverilog
typedef enum bit { UVM_PASSIVE = 0, UVM_ACTIVE = 1 } uvm_active_passive_enum;
```

A two-value enum. That's all `is_active` ever is.

### Semantics

- **`UVM_ACTIVE`**: the agent will build a driver and a sequencer. It will drive stimulus onto the bus. Use this when the testbench is responsible for generating the protocol traffic for this interface.
- **`UVM_PASSIVE`**: the agent will build only the monitor. It will only observe. Use this when the protocol traffic is generated elsewhere (by another agent or by the DUT itself).

### How the env sets it

```systemverilog
// In i2c_env::build_phase, BEFORE super.build_phase
uvm_config_db#(uvm_active_passive_enum)::set(
  this,                              // context
  "master_agent",                    // path (agent instance name)
  "is_active",                       // field name uvm_agent reads
  UVM_ACTIVE
);
uvm_config_db#(uvm_active_passive_enum)::set(
  this, "slave_agent", "is_active", UVM_PASSIVE
);
super.build_phase(phase);
master_agent = i2c_master_agent::type_id::create("master_agent", this);
slave_agent  = i2c_slave_agent::type_id::create("slave_agent", this);
```

The set call **must happen before** the agent's `build_phase` runs, because that is when the agent reads its `is_active` via `super.build_phase`.

> **Interview-grade answer:** *"is_active uses a single-bit enum, set via config_db before the agent's build_phase runs. The env writes `uvm_config_db::set(this, \"master_agent\", \"is_active\", UVM_ACTIVE)` and the base class uvm_agent reads it inside super.build_phase. The timing is critical: if you set after the agent's build_phase has executed, the agent has already decided whether to build the driver and sequencer. That's why config_db writes go in the env's build_phase BEFORE the children are created."*

### A common interview question — "What is the difference between active and passive?"

The wrong answer (junior): "Active drives, passive observes."

The right answer (senior):

> **Interview-grade answer:** *"Active means the agent owns the stimulus generation for this interface — driver and sequencer are built, the sequencer fires sequences, and the driver translates them into pin wiggles. Passive means the agent observes only — the monitor is built but the driver and sequencer are not. The key insight is that the same agent class can be either, controlled by a config_db setting. That property is what enables vertical reuse: at block level the master agent is active because the testbench drives the DUT; at system level the same class is passive because the master is now inside the DUT and the testbench only watches the bus. One class, two roles, zero code duplication."*

### Where the default comes from

In `uvm_agent`, the default is `UVM_ACTIVE`. If no one sets `is_active`, the agent builds driver and sequencer. This is the correct default for block-level testing.

> **Rule of thumb:** *Default is active, because block-level testbenches are the most common context, and in a block-level testbench the agent always drives. The env is responsible for downgrading to passive when reused in a higher-level context.*

### Why `get_is_active()` not `is_active`

The base class field `is_active` is `protected`, not `public`. The accessor `get_is_active()` is the documented API. **Always use the function**, not direct field access. This protects you against UVM internal changes.

> *"Public APIs survive across UVM library upgrades; direct field access into protected members does not. The accessor is the contract; the field is the implementation. Always code against contracts."*

### Multi-agent matrices

In a multi-master / multi-slave system, you might have four agents, only some of which are active. The env writes four `set` calls:

```systemverilog
uvm_config_db#(uvm_active_passive_enum)::set(this, "master_agent_0", "is_active", UVM_ACTIVE);
uvm_config_db#(uvm_active_passive_enum)::set(this, "master_agent_1", "is_active", UVM_PASSIVE);
uvm_config_db#(uvm_active_passive_enum)::set(this, "slave_agent_0",  "is_active", UVM_PASSIVE);
uvm_config_db#(uvm_active_passive_enum)::set(this, "slave_agent_1",  "is_active", UVM_PASSIVE);
```

Each agent reads its own setting independently. There is no global flag. This per-instance control is what lets you build heterogeneous environments — one active master plus three passive observers, for example.

> **Interview-grade answer:** *"Each agent instance reads its own is_active setting independently via its hierarchical path in the config_db. There is no global 'all agents active' flag — and that is by design, because real environments often have one active driver and many passive observers. Per-instance control is what enables that heterogeneity. In a four-master, four-slave system-level testbench, you might have one active driver (the test target) and seven passive observers."*

---

## 6. `config_db` — Propagating the Virtual Interface

This is the most-tested UVM concept in interviews. Master it cold.

### What is `uvm_config_db`?

A class-based, key-value, hierarchically-scoped database for passing handles and parameters into UVM components from outside their normal constructor argument chain. It is how the test sets parameters into deeply-nested agents without threading every value through every parent class.

### The three-step pattern

**Step 1 — Set, in the test or env:**

```systemverilog
uvm_config_db#(virtual i2c_if)::set(
  null,                  // context (null = global)
  "uvm_test_top.env.master_agent.driver",   // path (full or wildcard)
  "vif",                 // field name
  master_if
);
```

**Step 2 — Get, in the receiver (driver, monitor):**

```systemverilog
if (!uvm_config_db#(virtual i2c_if)::get(this, "", "vif", vif))
  `uvm_fatal("NO_VIF", "Virtual interface not set for ", get_full_name())
```

**Step 3 — Use it.** The driver and monitor now have a handle to the bus and can drive/sample pins.

### How does the agent participate?

In our current implementation, the agent does *not* call `set` or `get` on the vif — the test sets it at the driver/monitor scope directly. But there is an alternative pattern where the env sets it at the agent scope and the agent forwards it down:

```systemverilog
// Alternative: agent forwards vif to its children
function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(virtual i2c_if)::get(this, "", "vif", vif))
    `uvm_fatal("NO_VIF", "...")
  uvm_config_db#(virtual i2c_if)::set(this, "driver", "vif", vif);
  uvm_config_db#(virtual i2c_if)::set(this, "monitor", "vif", vif);
  // then create children...
endfunction
```

Both patterns work. Our current code uses the **flat** pattern (test sets directly to driver and monitor). The **forwarding** pattern adds encapsulation — the test only knows about the agent, not its internal structure.

> **Interview-grade answer:** *"There are two valid patterns for config_db propagation through an agent. The flat pattern is what this project uses — the test sets the vif directly at the driver and monitor scopes. It is simpler but couples the test to the agent's internal structure. The forwarding pattern is more encapsulated — the test sets the vif at the agent scope, the agent's build_phase reads it and re-sets it for the driver and monitor. The forwarding pattern is what I would recommend for a reusable IP-level agent, because it lets the agent's internal sub-component names change without breaking external tests. The trade-off is six extra lines of code per agent."*

### The scope rules — wildcards and context

The `path` argument in `set()` and `get()` is a string with optional wildcards.

| Path | Matches |
|---|---|
| `"uvm_test_top.env.master_agent.driver"` | Exactly that scope |
| `"*.master_agent.driver"` | Any path ending in `.master_agent.driver` |
| `"*"` | Everywhere — DANGER, broadcasts to all components |
| `""` (from inside `get`) | The current `this` scope |

The `context` argument is the *anchor* relative to which the path is interpreted.

> **Interview-grade answer:** *"config_db paths combine the context handle and the path string. If context is non-null, the path is relative to that component's hierarchical name; if context is null, the path is absolute from uvm_test_top. Wildcards let you broadcast to multiple scopes — `*` matches everywhere, which is convenient but dangerous in large environments because you can accidentally overwrite settings in unrelated subsystems. The rule of thumb is: use the most specific scope you can. Never use a bare `*` for anything you would not also accept being set globally."*

### A trap to know

If you `set` after the `get` has already happened, the new value is ignored — `get` already returned the old (or absent) value. **Always set in `build_phase` of a parent, before the child's `build_phase` runs.** UVM's top-down build order guarantees parents run before children.

> *"Set before get. The config_db is push, then pull — you write into it, the children read from it during their own build_phase. Reversing the order silently fails."*

### Type parameter on `config_db` — exact match required

```systemverilog
uvm_config_db#(virtual i2c_if)::set(...);
uvm_config_db#(virtual i2c_if)::get(...);   // works
uvm_config_db#(uvm_object)::get(...);       // does NOT match the above set
```

The type parameter is part of the database key. `set` with one type and `get` with another silently misses. **This is one of the most common UVM bugs in production.** When a vif `get` fails with no error, the first thing to check is whether the type parameters on set and get agree exactly, including the `virtual` keyword.

> **Interview-grade answer:** *"The config_db type parameter is part of the lookup key. A set with type virtual i2c_if and a get with type uvm_object will not match, even if you cast the handle. The framework hashes on the type at compile time. This silent type mismatch is one of the most-reported bugs in UVM Q-and-A forums. The defense is to always copy the type from the set site to the get site, including the virtual keyword for interfaces, and never paraphrase."*

### Wildcards in practice

```systemverilog
// Permissive — set for all drivers in any agent under env
uvm_config_db#(virtual i2c_if)::set(null, "uvm_test_top.env.*.driver", "vif", master_if);
```

The `*` pattern matches any single-level path component. **Use this sparingly.** In a small environment, it is a convenient shortcut; in a large environment, you can accidentally configure other agents that you did not intend.

> *"Specificity over convenience. The shortest path that uniquely identifies the target is the safest path. Wildcards are a smell — convenient at first, dangerous as the environment grows."*

---

## 7. `connect_phase` — Wiring `seq_item_port` to `seq_item_export`

### The TLM "pull" model

The driver wants the next transaction. It calls:

```systemverilog
seq_item_port.get_next_item(req);   // blocking
// drive pins...
seq_item_port.item_done();          // release sequencer
```

`get_next_item` is a **blocking** call into the sequencer. The sequencer, on the other end, has been advertising "I have a sequence running, here's the next item." The connection is what binds those two endpoints.

### The ports involved

- **`driver.seq_item_port`** — type `uvm_seq_item_pull_port #(REQ, RSP)`. The *initiator* side.
- **`sequencer.seq_item_export`** — type `uvm_seq_item_pull_imp #(REQ, RSP, ...)`. The *responder* side.
- The connection is `port.connect(export)`. Direction: initiator → responder.

### Visual

```
driver                                sequencer
+---------------------+               +---------------------+
|                     |               |                     |
| seq_item_port       |---connect---->| seq_item_export     |
| (uvm_seq_item       |               | (uvm_seq_item       |
|  _pull_port)        |               |  _pull_imp)         |
+---------------------+               +---------------------+
        |
        v
   get_next_item(req)  -------->  sequencer hands req
   item_done()         -------->  sequencer releases
```

### Why connect, not assignment?

You might think "just point `driver.seq_item_port = sequencer.seq_item_export`." That doesn't work because:

1. The port and export are different types. The port is the *interface*; the export is the *implementation*.
2. The TLM framework uses the `connect` API to set up the internal pointers, validate type compatibility, and register the connection for the implementation phase.

> **Interview-grade answer:** *"TLM connections are not handle assignments — they are typed function calls into the TLM framework that build the runtime bindings. The port advertises 'I want to call get_next_item'; the export advertises 'I implement get_next_item'. The connect call validates type compatibility at elaboration, registers the binding, and at runtime when the driver calls seq_item_port.get_next_item, the framework routes the call to the sequencer's actual implementation. It's a strongly-typed publish-subscribe with a single subscriber, not a pointer assignment."*

### The slave agent's `connect_phase`

```systemverilog
function void connect_phase(uvm_phase phase);
  if (get_is_active() == UVM_ACTIVE) begin
    driver.seq_item_port.connect(sequencer.seq_item_export);
  end
endfunction
```

Same pattern, gated by active. If passive, no driver exists, no connection needed. The monitor's port is connected by the env directly (since there is no agent-level analysis_port forwarded by the slave_agent in this project).

> *"Symmetry between build_phase and connect_phase: if something was conditionally built, its connection must also be conditionally made. Otherwise you call a method on null and the simulator crashes."*

### What if the driver and sequencer were created but not connected?

The driver's `seq_item_port.get_next_item(req)` call would never return — the port is unconnected, so the framework has no responder to route the call to. The simulation hangs. The driver thread blocks forever waiting for a transaction.

> **Interview-grade answer:** *"An unconnected seq_item_port causes a deadlock — the driver blocks forever inside get_next_item because there is no responder. This is one of the easier UVM bugs to diagnose because the symptom is unmistakable: time stops advancing, the driver's thread is stuck inside a TLM call, and a debugger backtrace shows it parked in the framework code. The defense is the same as for any TLM port: pair every port declaration with a connect call in connect_phase, gated by the same conditions as the declaration."*

### Phase ordering recap

```
1. build_phase      (top-down)   <- create components, set config_db
2. connect_phase    (bottom-up)  <- wire TLM ports
3. end_of_elaboration_phase      <- last chance to check structure
4. start_of_simulation_phase     <- print banner, etc.
5. run_phase        (parallel)   <- everything happens here
6. extract / check / report_phase (bottom-up) <- post-mortem
```

`build_phase` is top-down: env builds before agents, which build before drivers. `connect_phase` is bottom-up: drivers' connect runs before agents' connect runs before env's connect. But the agent's connect_phase only depends on its own children, so the bottom-up order does not matter for the connections you see in this file.

> *"build_phase creates things; connect_phase wires them. Never mix the two — putting a connect call in build_phase risks the target component not existing yet."*

---

## 8. Analysis Port Forwarding — Re-Publishing the Monitor's Stream

This is where the master agent goes a step further than the slave. Look at the line again:

```systemverilog
monitor.item_collected_port.connect(analysis_port);
```

### What just happened?

The monitor has `item_collected_port` — a `uvm_analysis_port #(i2c_seq_item)`. The agent has `analysis_port` — also a `uvm_analysis_port #(i2c_seq_item)`. The connection is **port-to-port**, not port-to-export.

When the monitor calls `item_collected_port.write(item)`:

1. The call propagates to the agent's `analysis_port.write(item)`.
2. Which propagates to every `analysis_export` connected to the agent's port.
3. Which lands in the scoreboard's `write` function via the `uvm_analysis_imp #(...)`.

The agent is just a relay. But it is a *named* relay — the env code says `master_agent.analysis_port.connect(scoreboard.actual_export)`. That name encapsulates the agent's internal monitor structure.

> **Interview-grade answer:** *"Analysis port forwarding is the pattern where one analysis port writes to another. The monitor's port broadcasts; the agent's port subscribes and re-broadcasts. The mechanical effect is identical to subscribing directly to the monitor — every write fans out to all connected subscribers — but the architectural effect is encapsulation. The env never names the monitor. If we later rename the monitor or move its responsibilities, the env code does not change. That's the kind of refactor-safety that makes UVM environments survive long IP lifecycles."*

### Subtle point — analysis ports vs analysis exports

| Class | Where used | Direction |
|---|---|---|
| `uvm_analysis_port #(T)` | Publisher side (monitor, agent) | Calls `write` outward |
| `uvm_analysis_imp #(T, P)` | Final subscriber side (scoreboard, coverage) | Implements `write` |
| `uvm_analysis_export #(T)` | Pass-through / aggregator | Forwards to internal imp |

The monitor uses `uvm_analysis_port`. The agent also uses `uvm_analysis_port`. The connection between them is `port.connect(port)`, which is valid. The fan-out happens naturally — every connect adds another listener.

### The classic agent bug — forgetting to forward

```systemverilog
// BUG — analysis_port declared and built, but never connected.
function void connect_phase(uvm_phase phase);
  if (get_is_active() == UVM_ACTIVE) begin
    driver.seq_item_port.connect(sequencer.seq_item_export);
  end
  // monitor.item_collected_port.connect(analysis_port);  ← missing!
endfunction
```

The agent compiles, the env compiles, the scoreboard's export connects to the agent's port — but no items ever arrive at the scoreboard. The monitor IS publishing, but to its own port that no one listens to. The scoreboard receives zero transactions, fails silently, and the test passes (because there is nothing to compare and no checker fires).

This is the most common UVM-newbie bug after `super.build_phase` ordering. **Watch for it in code review.**

> **Interview-grade answer:** *"The classic agent bug is forgetting to forward the monitor's analysis port to the agent's port. The code compiles, the env connects to the agent's port, but nothing arrives at the scoreboard — the monitor is publishing into a port with no subscribers. The symptom is a silent zero-traffic scoreboard, which often presents as a falsely-passing test. The defense is two-fold: first, always grep your agents for the connect_phase forwarding line as a code-review checkpoint; second, add a coverage point or a `\`uvm_info` heartbeat in the scoreboard that flags zero received items as a warning. That double check would have saved me from spending half a day debugging an empty scoreboard."*

---

## 9. Why the Master Agent Has an `analysis_port` but the Slave Does Not

A project-level design decision. Let's lay out the trade-off honestly.

### Argument for adding it to the slave (orthodoxy)

- **Consistency.** Both agents look the same; engineers reading the code know where to subscribe.
- **Encapsulation.** Env never names the monitor sub-component, only the agent.
- **Future-proofing.** If the slave monitor is later split into two monitors (e.g. one for protocol, one for timing), the agent's port can aggregate; env-side code does not change.

### Argument for omitting it (current project choice)

- **Simplicity.** One less port to declare and connect.
- **The scoreboard subscribes to slave traffic less often anyway** — in this project, the master-side monitor publishes the reference of truth.
- **Less boilerplate** for an agent that is typically passive.

> **Interview-grade answer:** *"This project omits the slave agent's analysis port to reduce boilerplate, but the cleaner UVM-by-the-book pattern is to mirror the master and forward the slave monitor's port to an agent-level port. The difference is three lines of code: declare uvm_analysis_port, instantiate in build_phase, connect in connect_phase. The benefit is uniform encapsulation across both agents, and future-proofing if the slave monitor is later refactored. In an interview, I would say 'we made a pragmatic call for simplicity but I would refactor it for consistency if I were starting from scratch.'"*

### The general rule

> **Add an agent-level analysis port if more than one subscriber will listen to this agent's monitor, OR if you anticipate the monitor being refactored, OR if the agent is meant to be reused across projects.** For one-off, one-subscriber, throwaway code: skip it.

In our project, the slave agent fits the "one-off" bucket today. The master agent has two subscribers (scoreboard and coverage), so the agent-level port is mandatory.

> *"The number of subscribers is the deciding factor. One subscriber, throwaway code: skip the agent-level port. Two or more, or any expectation of reuse: declare and forward."*

---

## 9b. Agent Reuse Across Projects — Vertical Reuse Done Right

The whole point of investing in the agent pattern is that the agent class survives between projects. Here is what "survives" means concretely.

### What ships with the agent

A correctly-packaged agent ships with:

1. **The agent class itself** (this file).
2. **The driver, sequencer item, and monitor** it owns.
3. **The seq_item base class.**
4. **A documented config_db API** — "set 'vif' to a virtual i2c_if at the agent scope before super.build_phase."
5. **A documented analysis-port API** — "subscribe to `agent.analysis_port` for observed transactions."
6. **An example test or sequence library.**

What does NOT ship: the env, the scoreboard, the coverage. Those are project-specific.

> **Interview-grade answer:** *"A reusable agent ships as a self-contained package: agent class, driver, monitor, sequencer item, base sequence library, and a one-page README documenting the config_db keys it expects and the analysis ports it provides. The env and scoreboard are NOT part of the agent — they are project-specific. The interface boundary is exactly the agent class, the config_db keys, and the analysis ports. If you discipline yourself to never let your env code reach into the agent's internals, the agent is shippable as a standalone IP-VC."*

### Common reuse failure modes

1. **Env reaching into `agent.driver` or `agent.monitor`** for configuration. Breaks encapsulation. Refactor: move the config_db calls to the agent scope and have the agent forward them.

2. **Hard-coded paths in sequences.** A sequence that calls `uvm_config_db::set(null, "uvm_test_top.env.master_agent...", ...)` cannot be reused at system level where the path is different. Refactor: use relative paths or pass the target via constructor.

3. **Coupling the seq_item to project-specific extensions.** A field added for project X's coverage breaks project Y. Refactor: subclass the seq_item for project-specific extensions.

> *"Treat your agent as a library, not a script. Libraries take parameters; scripts hard-code paths."*

### Vertical-reuse story (block-level to system-level)

At block level, the testbench:
- Instantiates `i2c_master_agent` as active.
- Drives I2C transactions from sequences.
- Subscribes the scoreboard to `master_agent.analysis_port`.

At system level (where the master IP is part of the DUT):
- Instantiates `i2c_master_agent` as passive.
- Sequences are not used — the DUT's CPU initiates traffic.
- The scoreboard still subscribes to `master_agent.analysis_port` to observe what the DUT-internal master produces.

> **Interview-grade answer:** *"Vertical reuse means the same agent class moves from block-level (where it is active and drives the DUT input) to system-level (where it is passive and observes a DUT-internal master). The single line of code change is in the env's config_db set call — UVM_ACTIVE becomes UVM_PASSIVE. No other code changes. The analysis port stays connected, the monitor stays running, only the driver and sequencer disappear. That property is the entire architectural reason agents exist in UVM."*

---

## 9c. Common Traps and Edge Cases

A list of footguns to memorize and watch for.

### Trap 1 — Creating components outside `build_phase`

```systemverilog
function new(...);
  super.new(name, parent);
  driver = i2c_driver::type_id::create("driver", this);  // WRONG
endfunction
```

Don't. Sub-components must be created in `build_phase`, not the constructor. The constructor runs at SystemVerilog object-creation time, before UVM phasing has started. The factory's type overrides are not yet active. The config_db has not been populated.

> **Interview-grade answer:** *"Sub-component creation belongs exclusively in build_phase. The constructor runs at object construction time, which is before UVM phasing starts. Factory overrides set in the test's build_phase haven't taken effect yet, and config_db lookups would return defaults. Always create in build_phase; the constructor exists only to call super.new and (rarely) initialize plain SystemVerilog fields."*

### Trap 2 — Forgetting `super.build_phase` in derived classes

When you subclass an agent — say, an `i2c_master_agent_extended` — and override `build_phase`, you must call `super.build_phase(phase)` first. Otherwise the base class's `is_active` resolution never runs.

> *"Every override of every UVM phase function starts with super.<phase>(phase). No exceptions. The base class is doing real setup work — never skip it."*

### Trap 3 — Setting `is_active` in the test, not the env

```systemverilog
// In test, AFTER env is constructed and built
uvm_config_db#(uvm_active_passive_enum)::set(this, "env.master_agent", "is_active", UVM_PASSIVE);
super.build_phase(phase);  // env builds; agent reads is_active <- works
```

Subtle: this *does* work because the test's `build_phase` runs before the env's `build_phase` (top-down build). But it is fragile. The cleaner pattern is to set in the env's build_phase, before super, because the env owns the agent's lifecycle.

> **Interview-grade answer:** *"The 'who sets is_active' question has two valid answers: the test or the env. Setting in the test's build_phase works because of top-down build order, but it couples the test to the env's internal structure. Setting in the env's build_phase is cleaner because the env owns the agents and is the natural authority for their active/passive status. The test should set higher-level things like 'which test scenario' rather than reaching into env internals."*

### Trap 4 — Two agents writing the same config_db key with different values

```systemverilog
uvm_config_db#(int)::set(null, "*", "max_retries", 3);   // from test
uvm_config_db#(int)::set(this, "*", "max_retries", 5);   // from env
```

The agent's child gets whichever value won the precedence battle. UVM's rules: highest in hierarchy wins, then most-specific path. The interactions are subtle. Avoid by using specific scopes.

> *"Two writers, one key, no logging — silent override. The defense is specificity: use full paths, not wildcards, and let the framework's precedence rules never be the deciding factor in a real bug."*

### Trap 5 — Using `uvm_object_utils` instead of `uvm_component_utils`

```systemverilog
class my_agent extends uvm_agent;
  `uvm_object_utils(my_agent)   // WRONG — should be uvm_component_utils
endclass
```

`uvm_object` is for transient objects (transactions, sequences). `uvm_component` is for structural components (agents, drivers, scoreboards). The factory has separate registries; the wrong macro registers the class in the wrong place. Type lookups silently fail.

> **Interview-grade answer:** *"uvm_object_utils registers a transient class — sequences, transactions, configurations. uvm_component_utils registers a structural class with phasing and a hierarchy. Mixing them up means the factory cannot find the class when type_id::create is called from the component side, or the component lacks phasing. The macro is the only thing distinguishing the two registrations; pick the right one based on whether the class is structural and persistent (component) or transient (object)."*

### Trap 6 — Creating the sequencer in passive mode by accident

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  monitor = ...;
  sequencer = uvm_sequencer #(i2c_seq_item)::type_id::create("sequencer", this);  // BUG
  if (get_is_active() == UVM_ACTIVE) begin
    driver = i2c_driver::type_id::create("driver", this);
  end
endfunction
```

Now the sequencer exists in passive mode but is unconnected — and is also harmless, since nothing references it. The bug is wasted memory and a misleading hierarchy: a tool dumping the UVM topology shows a sequencer in a passive agent, which is semantic noise. Always gate driver AND sequencer together.

> *"Driver and sequencer are siblings in the active-mode bundle. They live together or they don't live at all. Splitting them is a maintenance hazard."*

### Trap 7 — Cleaning up by hand

UVM components are not manually destroyed. They are owned by their parent and live for the entire simulation. Do not write a `~i2c_master_agent()` destructor; do not `null` out handles in `final` blocks. The UVM framework manages the lifecycle.

> **Interview-grade answer:** *"UVM components have a managed lifecycle — they are created in build_phase, run during run_phase, and are cleaned up by the framework at simulation end. There is no manual destruction. Writing a destructor or nulling handles is not just unnecessary, it can interfere with end-of-simulation report and check phases that need the components to still exist. Trust the framework; don't fight it."*

---

## 9d. The Debug Cookbook for Agent Issues

A short reference for the symptoms you will hit in practice.

### Symptom 1 — `uvm_fatal: NO_VIF`

```
UVM_FATAL @ 0: uvm_test_top.env.master_agent.driver [NO_VIF] Virtual interface not set
```

Cause: the test or env did not write the vif to the config_db at a scope visible to the driver.

Debug: print the full hierarchical name in the fatal message. Verify the set-site path. Check the type parameter exactly matches.

> *"NO_VIF is almost always a path or type mismatch in config_db. Two locations to check: the set site and the get site. Diff them character by character."*

### Symptom 2 — Driver hangs in `get_next_item`

```
# (debugger shows driver thread parked inside uvm_seq_item_pull_port::get_next_item)
```

Cause: either no sequence is running on the sequencer, or the seq_item_port is not connected to the sequencer's export.

Debug: print `seqr.is_sequence_running` from a heartbeat thread; print the connected ports via `seqr.print_topology()`.

> **Interview-grade answer:** *"A driver parked in get_next_item is one of two things: an unconnected port, or no sequence running on the sequencer. The first is a connect_phase bug; the second is a test-setup bug. Diagnose by inspecting the sequencer's connected-ports list at end_of_elaboration_phase — if the seq_item_export shows zero connections, the agent's connect_phase has a missing line. If the export is connected but the sequencer is idle, the test never launched a sequence."*

### Symptom 3 — Scoreboard receives zero items

Already covered: missing analysis-port forward in the agent. Add the heartbeat check.

> *"Zero items at the scoreboard is the agent's classic silent failure. Defense in depth: add a coverage point on item count, a heartbeat in check_phase, and a code review rule."*

### Symptom 4 — Test passes when it should fail

Cause: scoreboard never received items, OR the comparison is too lenient. The agent is suspect if traffic is supposed to be flowing.

Debug: count items at agent's analysis port; count items at scoreboard's actual_export; they should be equal.

> **Interview-grade answer:** *"False-pass tests are the most dangerous failure mode in verification. The defense is item-count parity checking at multiple levels: monitor-to-agent-port, agent-port-to-scoreboard, expected-to-actual at the scoreboard. Any zero or any mismatch is a red flag. I add these checks in check_phase by default; they cost nothing and catch silent disconnections."*

### Symptom 5 — Random behavior despite seed

Cause: a sequence is calling `randomize()` without controlling the seed, or a config_db value is being read in a non-deterministic order.

Debug: this is usually NOT the agent — usually the test or sequence. But when reusing an agent across projects, double-check that the agent does not read shared global state.

> *"Reproducibility is non-negotiable in DV. If a test fails with seed X and passes with seed Y when nothing should have changed, you have a randomness leak. Audit every randomize call for missing constraints."*

---

## 9e. Mental Model — How to Think About Agents

If you remember nothing else from this lesson, remember this mental model.

### The agent is a publisher and a controllable noise source

- **As a publisher**, the agent broadcasts what is on the bus via its analysis port. Always. Active or passive.
- **As a controllable noise source**, the agent injects stimulus via its driver. Only when active.

The two roles are decoupled. You can have publishing without injection (passive). You cannot have injection without publishing — if the agent drives, something is on the bus, and the monitor will see it.

> **Interview-grade answer:** *"The cleanest mental model is to think of the agent as having two roles: a publisher and a controllable noise source. The publisher is always on — the monitor always observes and broadcasts. The noise source is conditional — driver and sequencer only exist in active mode. The two roles are decoupled, which is what enables the active/passive switch. When you reason about agent reuse, ask: 'do I need the publisher or the noise source or both?' If only the publisher, go passive. If both, go active."*

### The env is the conductor; agents are instruments

Agents have no opinion about which scenarios to run. They expose capability — "I can drive an I2C master" or "I can observe an I2C slave." The env, and beyond it the test, decides what to do with those capabilities.

> *"Agents are dumb. They expose handles, they receive config_db, they obey the active/passive switch. Intelligence lives in tests and sequences, not in agents."*

### The factory is the swap mechanism

Anywhere the agent calls `type_id::create`, a test can substitute a different concrete class. This is the only way to inject behavior changes from a test without modifying agent code.

> *"If the agent uses type_id::create everywhere, the test can swap any sub-component at any time. If the agent uses bare `new`, that swap door is locked. The factory pattern is what keeps the door open."*

---

## 9f. Worked Example — Walking Through One Full Build

To cement everything, let's trace a single simulation from `run_test()` to the moment the driver hands its first item to the bus.

### Step 0 — `run_test("base_test")`

The simulator calls `run_test`, which the UVM framework hooks into. The framework finds the class `base_test` in the factory, constructs an instance, and calls its build_phase.

### Step 1 — `base_test::build_phase`

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);                      // does nothing meaningful at test level
  uvm_config_db#(virtual i2c_if)::set(this, "env.master_agent.driver",  "vif", tb_top.master_if);
  uvm_config_db#(virtual i2c_if)::set(this, "env.master_agent.monitor", "vif", tb_top.master_if);
  uvm_config_db#(virtual i2c_if)::set(this, "env.slave_agent.monitor",  "vif", tb_top.slave_if);
  env = i2c_env::type_id::create("env", this);   // constructs and triggers env's build
endfunction
```

The test sets vifs in the config_db, then creates the env. Creating the env triggers UVM's build phase on the env.

### Step 2 — `i2c_env::build_phase`

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  uvm_config_db#(uvm_active_passive_enum)::set(this, "master_agent", "is_active", UVM_ACTIVE);
  uvm_config_db#(uvm_active_passive_enum)::set(this, "slave_agent",  "is_active", UVM_PASSIVE);
  master_agent = i2c_master_agent::type_id::create("master_agent", this);
  slave_agent  = i2c_slave_agent::type_id::create("slave_agent",  this);
  scoreboard   = i2c_scoreboard::type_id::create("scoreboard",    this);
endfunction
```

The env writes the active/passive flags, then creates the children. Creating each child triggers their build_phase recursively.

> **Interview-grade answer:** *"The env's build_phase writes the active/passive setting BEFORE creating the agent. This ordering is critical because the agent reads the setting inside its own super.build_phase. If the env writes after the create call, the agent has already executed its build_phase with the default value. The pattern `set then create` is a discipline you must hold across every UVM hierarchy level."*

### Step 3 — `i2c_master_agent::build_phase`

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);                      // <- reads "is_active" from config_db
  if (get_is_active() == UVM_ACTIVE) begin       // -> UVM_ACTIVE in this test
    driver    = i2c_driver::type_id::create("driver",    this);
    sequencer = uvm_sequencer #(i2c_seq_item)::type_id::create("sequencer", this);
  end
  monitor       = i2c_monitor::type_id::create("monitor", this);
  analysis_port = new("analysis_port", this);
endfunction
```

Driver and sequencer are created. Each of those triggers their own build_phase recursively. The driver's build_phase reads the vif from config_db at scope "uvm_test_top.env.master_agent.driver". The monitor's build_phase does the same at its scope.

### Step 4 — `i2c_master_agent::connect_phase`

```systemverilog
function void connect_phase(uvm_phase phase);
  if (get_is_active() == UVM_ACTIVE) begin
    driver.seq_item_port.connect(sequencer.seq_item_export);
  end
  monitor.item_collected_port.connect(analysis_port);
endfunction
```

The driver-sequencer link is established. The monitor's port is forwarded to the agent's analysis port.

### Step 5 — `i2c_env::connect_phase`

```systemverilog
function void connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  master_agent.analysis_port.connect(scoreboard.actual_export);
  slave_agent.monitor.item_collected_port.connect(scoreboard.slave_export);
endfunction
```

The scoreboard subscribes to both agents. The master subscription is at the agent-level port; the slave subscription reaches into the monitor directly (because the slave agent has no agent-level analysis port).

> **Interview-grade answer:** *"In connect_phase, the env wires the agent analysis ports into the scoreboard. The asymmetry between master and slave subscription paths reflects the project's current design — master goes through the encapsulating agent port, slave goes directly into the monitor. The refactor I would propose is to mirror the slave agent to have its own analysis port; the env-side connect call would then read 'slave_agent.analysis_port.connect(...)' which matches the master's pattern."*

### Step 6 — Run phase starts

The test's `run_phase` forks the sequence:

```systemverilog
task run_phase(uvm_phase phase);
  i2c_basic_seq seq;
  phase.raise_objection(this);
  seq = i2c_basic_seq::type_id::create("seq");
  seq.start(env.master_agent.sequencer);     // <-- here it goes
  phase.drop_objection(this);
endtask
```

The sequence's body executes on the sequencer. Each `\`uvm_do` creates a transaction and offers it to the driver via the TLM connection.

### Step 7 — The driver's run loop

```systemverilog
task run_phase(uvm_phase phase);
  forever begin
    seq_item_port.get_next_item(req);         // blocks until the sequencer has an item
    drive_item(req);                          // wiggles SCL/SDA on the vif
    seq_item_port.item_done();                // tells sequencer to advance
  end
endtask
```

`get_next_item` blocks until the sequence's `\`uvm_do` produces an item. The driver then translates the abstract transaction into pin wiggles via `vif.drive_byte(...)` or similar. After driving, `item_done()` releases the sequencer to produce the next item.

> **Interview-grade answer:** *"The driver's run_phase is a forever loop with three steps: pull from sequencer, drive on vif, release sequencer. The pull is blocking — the driver does nothing until the sequencer has work. The drive is what turns abstract data into wire activity. The release is a TLM handshake that lets the sequencer advance the body. The whole loop is straight-line code; concurrency is handled by the framework's blocking calls. This is the cleanest pattern in UVM — once you internalize it, every driver looks the same."*

### Step 8 — The monitor publishes

In parallel with the driver, the monitor watches the bus:

```systemverilog
task run_phase(uvm_phase phase);
  forever begin
    sample_byte_from_vif(observed);           // blocks on SDA/SCL edges
    item_collected_port.write(observed);      // publishes to the world
  end
endtask
```

`item_collected_port.write` propagates through the agent's analysis port and out to the scoreboard. The scoreboard's `write` function compares this observed item against the expected reference.

> *"The monitor publishes asynchronously to driver activity. It does not know what the driver is sending; it only sees the bus. This independence is the foundation of scoreboard checking."*

### Step 9 — End of simulation

The sequence finishes its body. The test's `run_phase` drops the objection. UVM proceeds to extract/check/report phases. The scoreboard's `check_phase` runs and asserts that all expected items were matched.

> **Interview-grade answer:** *"The end-of-simulation flow is objection-driven. The test raises an objection at the start of run_phase, the sequence runs and completes, the test drops the objection, and UVM proceeds through extract, check, and report phases in bottom-up order. The scoreboard's check_phase is where final accounting happens — every expected transaction should be matched, every received transaction should be expected. If not, the test fails. The objection model is what gives you deterministic test termination; without it, the simulation would either hang or end too early."*

---

## 9g. The Refactor Wishlist — How I Would Improve These Two Files

If I were code-reviewing my own work, here are the changes I would make.

### Wishlist 1 — Mirror the slave agent's analysis port

Add `uvm_analysis_port #(i2c_seq_item) analysis_port;` to the slave agent and forward `monitor.item_collected_port` to it in `connect_phase`. Updates the env to subscribe via the agent-level port. Three-line change, big encapsulation win.

> *"Consistency between sibling classes is worth more than three lines of code. Make the slave look like the master."*

### Wishlist 2 — Forward the vif inside the agent's build_phase

Currently the test/env writes the vif directly to the driver and monitor scopes. Moving the vif lookup to the agent's build_phase and re-setting it for children decouples the test from the agent's internal structure.

> *"The test should know the agent exists. The test should NOT know the agent has a driver and a monitor named exactly so. Encapsulate."*

### Wishlist 3 — Add an end-of-elaboration sanity check

```systemverilog
function void end_of_elaboration_phase(uvm_phase phase);
  if (analysis_port.size() == 0)
    `uvm_warning("AGENT_PORT", "analysis_port has no subscribers - traffic will be unobserved")
endfunction
```

Catches the dropped-subscription bug at elaboration time, not at end-of-test.

> **Interview-grade answer:** *"An end_of_elaboration_phase sanity check on subscriber counts is cheap insurance. It catches the missing-subscriber bug at structural-check time, long before any transactions run. The fix is a five-line addition to the agent: query analysis_port.size at end_of_elaboration_phase and warn if zero. Combined with the heartbeat in the scoreboard, you have two-layer defense against silent zero-traffic test passes."*

### Wishlist 4 — Document the config_db keys in the file header

Future engineers should not have to read the build_phase to know what keys the agent expects. A header comment block listing every config_db key the agent reads, its type, and its meaning is good documentation hygiene.

> *"If the next engineer has to grep your code to find your config_db keys, you have failed at documentation."*

### Wishlist 5 — Add a `print_topology()` helper

For debug, a one-call helper that dumps the agent's sub-components, their hierarchical names, and their TLM connections is invaluable. UVM provides `uvm_top.print_topology()` for the whole hierarchy; an agent-level version is convenient when chasing a specific bug.

> **Interview-grade answer:** *"Debug helpers are a force multiplier. A print_topology method on the agent that dumps sub-component names, vif handles, and TLM connection counts cuts the time-to-diagnose for the common bugs from hours to minutes. The cost is one function; the payoff is every future debug session. I would add this to any agent I expect to live longer than one project."*

---

Sit down with a blank page. Try to answer each from memory first. Then read the answers.

1. What is a UVM agent? Define it in one sentence, then explain why the bundling matters.

2. Explain the active/passive switch. Where does the value come from, when is it read, and what does it control?

3. In `build_phase`, why must `super.build_phase(phase)` be called *before* `get_is_active()`?

4. Why is the monitor created unconditionally, while the driver and sequencer are gated by `is_active`?

5. Explain the difference between `monitor.item_collected_port` and `agent.analysis_port`. Why have both? Could you skip the agent-level port?

6. Trace what happens when the driver calls `seq_item_port.get_next_item(req)`. Which classes are involved, what's the direction of data flow, and what blocks until what?

7. Why does `analysis_port = new("analysis_port", this);` use plain `new()` instead of `type_id::create()`?

8. Suppose the connect_phase line `monitor.item_collected_port.connect(analysis_port);` is missing. What happens? How would you detect this bug?

9. The slave agent uses `uvm_sequencer #(i2c_slave_ctrl_item)`, not `uvm_sequencer #(i2c_seq_item)`. Why two different item types?

10. Suppose you want to *override* `i2c_driver` with a debug-instrumented subclass in one specific test. Walk through the factory override mechanism end-to-end. Which line in the agent makes this possible?

---

## 11. Quiz — Senior-Engineer-Grade Answers

### Q1 — What is a UVM agent?

A UVM agent is a structural container that bundles a sequencer, a driver, and a monitor for one logical interface of the DUT. The agent itself has no behavior — it owns the three sub-components and presents them as a single, reusable unit to the environment.

The bundling matters for three reasons:

1. **Reuse.** Pass the agent between projects; you do not re-wire three sub-components every time.
2. **Lifecycle.** All three sub-components share a parent for `config_db` scoping and phase coordination.
3. **Active/passive switch.** A single boolean controls whether stimulus is generated, enabling vertical reuse between block-level and system-level testbenches.

> **Interview-grade answer:** *"A UVM agent is the structural unit that bundles one interface's sequencer, driver, and monitor into one reusable component. The bundling exists for reuse, lifecycle ownership, and the active/passive switch — the last of which is what lets the same agent class participate in both standalone testbenches as an active driver and in system-level testbenches as a passive observer. The agent itself contains no functional code; it is pure encapsulation."*

---

### Q2 — Explain the active/passive switch

`is_active` is a field of type `uvm_active_passive_enum` defined in the base class `uvm_agent`. Its value comes from the `config_db` — specifically, the parent (typically the env) calls:

```systemverilog
uvm_config_db#(uvm_active_passive_enum)::set(this, "master_agent", "is_active", UVM_ACTIVE);
```

before instantiating the agent. The agent's `super.build_phase(phase)` reads the value during build. If no value is set, the default is `UVM_ACTIVE`.

What it controls:

- **`UVM_ACTIVE`** → `build_phase` creates the driver and sequencer. `connect_phase` wires them. The agent generates stimulus.
- **`UVM_PASSIVE`** → driver and sequencer are not created. Only the monitor exists. The agent is observation-only.

> **Interview-grade answer:** *"is_active is read from the config_db in the agent's super.build_phase. Active mode builds the driver and sequencer; passive mode skips them and only builds the monitor. The architectural value is reuse — the same agent class can act as a stimulus generator at block level or a pure observer at system level just by toggling that one config setting. Without that switch, you would need two separate classes, which would violate DRY and create drift between block-level and system-level testbenches."*

---

### Q3 — Why `super.build_phase` *before* `get_is_active`?

Because `uvm_agent::build_phase` is where the base class reads the `is_active` field from the `config_db`. If you call `get_is_active()` before `super.build_phase`, the field still holds its default-initialized value (which happens to be `UVM_ACTIVE` in current UVM, but you should not rely on this — the semantic guarantee is "after super.build_phase returns, is_active is correct").

**The general principle:** UVM phase functions should always start with `super.<phase>(phase)`. The base class does setup work for you; skipping it leaves the object half-initialized.

> **Interview-grade answer:** *"You must call super.build_phase first because the base class uvm_agent reads is_active from the config_db inside that call. Skipping it leaves is_active at its default-initialized value, which silently makes every passive request behave like an active agent. The general rule is: always call super at the start of every UVM phase function. The base class is doing real setup work, not just reflection — it reads config_db values, resolves type overrides, and configures internal state. Skipping super is a UVM newbie footgun."*

---

### Q4 — Why create the monitor unconditionally?

Because **passive agents still observe**. The whole point of passive mode is "I am only watching the bus." That means we need the monitor. We do not need the driver (no stimulus). We do not need the sequencer (no transactions to send). But the monitor is mandatory.

A passive agent with no monitor would be useless — it would have neither outputs nor observations. The active-vs-passive switch is exclusively about *stimulus generation*, never about *observation*.

> **Interview-grade answer:** *"The monitor is the agent's reason to exist in passive mode — passive means 'I observe only,' which by definition requires the monitor. The active-passive switch controls stimulus, not observation. A passive agent with no monitor would be a no-op component, which would have no reason to exist. So the monitor is unconditional, and the driver and sequencer are conditional on active mode."*

---

### Q5 — `monitor.item_collected_port` vs `agent.analysis_port`?

`monitor.item_collected_port` is the monitor's internal publication port. It exists so the monitor can broadcast without knowing the subscriber.

`agent.analysis_port` is the agent's *public face* — the encapsulated, agent-level port that the env subscribes to.

Why have both? Encapsulation. The env should not name the monitor. If we have one port (the monitor's only), then every env that subscribes does `master_agent.monitor.item_collected_port.connect(scoreboard...)`. That couples the env to the agent's internal sub-component name. If we later rename the monitor, every env breaks.

Could you skip the agent-level port? Yes, but then you are committing to the monitor's name being permanent and to the env reaching past the agent boundary. For one-off code, that's fine; for reusable IP-level agents, do not skip it.

> **Interview-grade answer:** *"The monitor's port is its internal publication mechanism; the agent's port is the public, encapsulated subscription point for the env. The reason to have both is encapsulation — the env should only know about the agent, not its sub-components. If we expose only the monitor's port, every env hard-codes the path 'agent.monitor.item_collected_port,' which breaks the moment we refactor the monitor. Skipping the agent-level port is a pragmatic shortcut for throwaway code, but for reusable agents it is the wrong call."*

---

### Q6 — Trace `get_next_item`

The driver calls:

```systemverilog
seq_item_port.get_next_item(req);
```

What happens, step by step:

1. The call enters the driver's `seq_item_port`, which is a `uvm_seq_item_pull_port`.
2. The port has been `connect`-ed to the sequencer's `seq_item_export`. The framework routes the call to the export.
3. The export forwards into the sequencer's internal arbitration logic. The sequencer asks "is there a running sequence?" — if so, it pulls the next item from the sequence's body. If not, it blocks until a sequence starts.
4. Once an item is available, the sequencer returns it. The driver's `req` handle now points to the transaction.
5. The driver drives the pins.
6. The driver calls `seq_item_port.item_done()`. This signals the sequencer that the item has been processed and the sequence can advance to the next item.

The whole exchange is **blocking** — the driver does nothing until the sequencer has an item; the sequencer's sequence does not advance until the driver calls `item_done`.

> **Interview-grade answer:** *"The driver calls get_next_item on its seq_item_port; the call routes through the connect-time-established TLM binding to the sequencer's seq_item_export and into the sequencer's arbitration logic. If a sequence is active, the sequencer hands back the next item; if not, the call blocks. After driving the pins, the driver calls item_done, which signals the sequencer to advance. The whole protocol is blocking and synchronized — driver and sequencer never race because each handoff is explicit. That's why you can write a driver that reads from the sequencer without worrying about thread safety."*

---

### Q7 — Why `new()` not `type_id::create()` for analysis port?

Because analysis ports are not factory-registered classes. They have no `\`uvm_component_utils` macro inside. They are intentionally non-overridable — the framework treats them as plain TLM endpoints.

The reason: factory overrides exist for *behavioral* customization (a debug driver, a stricter monitor). Analysis ports have no behavior to customize — they just forward `write()` calls. There is nothing to override. Therefore, no factory registration; therefore, plain `new()`.

> **Interview-grade answer:** *"Analysis ports are not factory-registered because they have no behavior to override — they are pure TLM relays. The factory exists for cases where you want to swap one class's behavior for another at test time, like installing a debug driver in place of the real one. An analysis port has no swappable behavior; write is write. So the framework uses plain `new`, which is also slightly faster at elaboration. Plain new is the documented API for ports."*

---

### Q8 — Missing analysis port forwarding

If `monitor.item_collected_port.connect(analysis_port);` is missing:

- The code compiles.
- The env's `master_agent.analysis_port.connect(scoreboard.actual_export)` succeeds.
- The monitor publishes — but to its own internal port, which nothing is listening to.
- The agent's analysis port never sees a write.
- The scoreboard receives zero items.
- The test passes (silently, because the scoreboard has nothing to disagree with).

**How to detect:**

1. **Add a heartbeat** in the scoreboard: if zero items arrive in N nanoseconds after run starts, raise `\`uvm_warning`.
2. **Coverage:** define a cover point on items-received-count > 0. The coverage hole flags the bug.
3. **End-of-test check:** in `check_phase`, assert that the scoreboard received at least one transaction.
4. **Code review:** grep every agent for the pattern `analysis_port` and verify a corresponding `connect` exists.

> **Interview-grade answer:** *"Missing the forwarding line creates a silent passing-test failure. The monitor publishes to its internal port, which has no listeners. The agent's analysis port stays empty. The scoreboard receives zero items and reports no errors because it has nothing to disagree with. The bug manifests as a clean-passing test with zero verification value. Defenses are an end-of-test 'items-received-must-be > 0' check in the scoreboard, a coverage point on transaction count, and a code-review rule that every analysis_port declaration must have a corresponding connect in the same file."*

---

### Q9 — Two different item types

The master sequencer generates `i2c_seq_item` — a *transaction* descriptor (address, data, RW, expected ACK). The driver translates this into pin wiggles.

The slave sequencer generates `i2c_slave_ctrl_item` — a *control* descriptor (when to NACK, how long to stretch, what address to claim). The slave driver uses this to modulate the slave's reactive behavior.

These are different semantic objects:

- `i2c_seq_item` describes "what the master wants to send on the bus."
- `i2c_slave_ctrl_item` describes "how the slave should respond to whatever the master sends."

Confusing them by reusing one item type would conflate transaction generation with behavior modulation, making the code harder to read and harder to reuse.

> **Interview-grade answer:** *"The master and slave have semantically different responsibilities. The master generates transactions — address, data, direction — so its item describes a full bus transaction. The slave is reactive — it does not initiate, it responds — so its item describes behavior modulation: NACK or ACK, stretch duration, address to claim. These are different objects describing different things. Using one item type for both would conflate 'what to send' with 'how to react,' which would obscure the protocol semantics and prevent independent reuse of the slave agent in environments with different masters."*

---

### Q10 — Factory override walkthrough

Suppose you have a debug-instrumented driver, `i2c_driver_dbg`, derived from `i2c_driver`. In one specific test, you want to use it.

**Step 1 — Both classes must be factory-registered:**

```systemverilog
class i2c_driver extends uvm_driver #(i2c_seq_item);
  `uvm_component_utils(i2c_driver)
  ...
endclass

class i2c_driver_dbg extends i2c_driver;
  `uvm_component_utils(i2c_driver_dbg)
  // override drive_item, add waveform dumps, etc.
endclass
```

**Step 2 — In the test, before `super.build_phase`:**

```systemverilog
class debug_test extends base_test;
  function void build_phase(uvm_phase phase);
    set_type_override_by_type(
      i2c_driver::get_type(),       // original
      i2c_driver_dbg::get_type()    // replacement
    );
    super.build_phase(phase);
  endfunction
endclass
```

**Step 3 — When the agent calls `i2c_driver::type_id::create("driver", this)`**, the factory checks its override table. It finds the type override and instead instantiates `i2c_driver_dbg`. The agent has no idea the swap happened.

**The line in the agent that makes this possible:**

```systemverilog
driver = i2c_driver::type_id::create("driver", this);
```

The `type_id::create` is the factory entry point. If the agent used `new i2c_driver(...)` directly, the override would not work. **Factory-based creation is what enables type overrides.**

> **Interview-grade answer:** *"Factory override works because the agent does not call `new i2c_driver` directly — it calls `i2c_driver::type_id::create`, which routes through the UVM factory. The factory maintains a registration table that maps original types to overrides; when type_id::create is called, the factory consults the table and instantiates the override if one is registered. The test sets the override via set_type_override_by_type before super.build_phase, so when the env and agent build phases run and create their children, the children come back as the overridden type. The polymorphism is transparent — the agent still holds a base-class handle named driver, but the actual object is the debug subclass. That's the entire reason UVM uses the factory pattern: test-portable behavior swaps with no code changes outside the test."*

---

## 12. Key Takeaways

### Conceptual

1. **An agent is a bundle, not a behavior.** It owns sequencer + driver + monitor for one interface and presents them as one unit.

2. **`is_active` is the single bit that decides whether the agent generates stimulus.** Set via `config_db` in the env before `super.build_phase`.

3. **`super.build_phase(phase)` must come first** in every UVM phase function. The base class does real work.

4. **The monitor is unconditional; the driver and sequencer are conditional.** Passive means observe-only.

5. **Agent-level analysis port forwarding** preserves encapsulation between the env and the monitor.

6. **Driver-sequencer connection is a TLM port-to-export pull binding.** The driver pulls; the sequencer responds.

7. **Factory-based creation (`type_id::create`)** is what enables test-portable type overrides. Always use it for sub-components.

8. **Analysis ports use plain `new()`** because they have no behavior to override.

9. **Two different item types for master and slave** because they describe semantically different things (transaction vs reactive behavior).

10. **The classic agent bug is forgetting to forward the monitor's port** to the agent-level analysis port. Silent fail. Add a heartbeat check.

### Bugs / Issues Worth Tracking

| Item | Severity | Status |
|---|---|---|
| Slave agent has no analysis_port (inconsistency with master) | Low | Open — refactor for consistency |
| No assertion that monitor.item_collected_port is connected | Low | Open — add elaboration check |
| No scoreboard heartbeat for zero-traffic | Medium | Open — add end-of-test check |
| Slave sequencer uses base class — no custom arbitration | Low | Acceptable for current scope |

### Career-critical

1. **You will be asked "What is a UVM agent?" in nearly every DV interview.** Have the one-sentence answer memorized.
2. **The active/passive distinction** is high-frequency interview material.
3. **`super.build_phase` ordering** is a favorite trick question — answer it crisply.
4. **TLM port-export pull semantics** — diagram it on a whiteboard if asked.
5. **Factory override mechanism** — this separates juniors from seniors. Walk through it end-to-end.

---

## 13. Action Items

- [ ] Re-do the 10-question quiz cold in 3 days. Target >= 8/10.
- [ ] Draw the master-agent + env + scoreboard diagram from memory on a whiteboard. Time yourself — target under 3 minutes.
- [ ] Refactor the slave agent to add an agent-level analysis port. Submit as a PR.
- [ ] Add a `\`uvm_warning` heartbeat in the scoreboard for "zero items received." Run all tests; confirm none trigger.
- [ ] Practice the factory-override walkthrough out loud (90 seconds). Record yourself. Listen back.
- [ ] Read the UVM reference manual sections on `uvm_agent`, `uvm_active_passive_enum`, and the TLM port classes. One page each.
- [ ] **(Stretch)** Write a debug-instrumented `i2c_driver_dbg` that dumps every transaction to a log. Use it via factory override in one test.
- [ ] **(Stretch)** Convert the slave agent's flat config_db pattern to the forwarding pattern. Document the trade-off.
- [ ] **(Stretch)** Add an SVA / coverage point in the testbench that asserts every active-mode agent has its analysis port connected to at least one subscriber.

---

## 14. Honest Self-Score Template

Fill in honestly. Re-evaluate weekly.

| Area | Score | Notes |
|---|---|---|
| Can define UVM agent in one sentence | __% | Recorded and listened back? |
| Active/passive switch — set, get, when read | __% | Without looking? |
| `super.build_phase` first — and why | __% | Can I explain the consequence of skipping it? |
| Monitor unconditional, driver/sequencer conditional | __% | Can I justify this in the design? |
| `analysis_port` forwarding pattern | __% | Can I draw the port-to-port wiring? |
| TLM pull model (driver -> sequencer) | __% | Can I trace `get_next_item` step by step? |
| Factory override end-to-end | __% | Can I walk through it in 90 seconds? |
| Why `new()` not `create()` for analysis port | __% | Can I explain "no behavior to override"? |
| Master vs slave item type distinction | __% | Can I defend two item types? |
| Detecting the missing-forward bug | __% | Can I name two detection mechanisms? |
| config_db scope rules and timing | __% | Set before child's build_phase — why? |
| Drawing the env-agent-scoreboard diagram cold | __% | Under 3 minutes from memory? |

### Suggested Rubric

- **0%:** Heard for the first time. Reread the section.
- **30%:** Recall the concept but not the details. Reread + quiz once.
- **60%:** Can explain it under no pressure. Practice with a friend / camera.
- **80%:** Can explain it cold under interview pressure. Move on.
- **100%:** Could teach this section to someone else from scratch. Mastered.

---

**End of Lesson 11.** Next file: `i2c_scoreboard.sv` — the actual reference model and comparison logic. We'll look at how the master agent's analysis port feeds the scoreboard, how the scoreboard maintains its expected queue, and where the BUG #15 self-checking gap was found and fixed.
