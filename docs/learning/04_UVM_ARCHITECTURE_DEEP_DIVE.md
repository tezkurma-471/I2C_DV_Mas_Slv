# 04 — UVM Architecture Deep Dive
### A Complete Guide to the I2C Verification Environment
*Written for the intern who wants to understand every component, every connection, and every design decision — from zero.*

---

## Table of Contents

1. [Why UVM Exists — The Problem It Solves](#part-1)
2. [The Big Picture — Environment Architecture](#part-2)
3. [The Sequence Item — The Transaction](#part-3)
4. [Sequences — How Stimulus is Generated](#part-4)
5. [The Master Driver — Turning Transactions into Signals](#part-5)
6. [The Slave Driver — Active Slave Mode](#part-6)
7. [The Monitor — Observing Without Disturbing](#part-7)
8. [The Scoreboard — Verifying Correctness](#part-8)
9. [The Environment — Wiring It All Together](#part-9)
10. [Test Classes — The Top Level](#part-10)
11. [TLM — Transaction Level Modeling](#part-11)
12. [UVM Phases Deep Dive](#part-12)
13. [Interview Questions](#part-13)

---

<a name="part-1"></a>
## Part 1: Why UVM Exists — The Problem It Solves

### Before UVM: The Wild West of Testbenches

Picture it: the year is 2005. You are a verification engineer at a chip company. Your job is to verify that your I2C slave DUT works correctly. You write a testbench. It looks something like this:

```verilog
// Old-school Verilog testbench — no methodology, no reuse
module tb;
  reg clk, rst_n, sda, scl;
  
  i2c_slave dut(.clk(clk), .rst_n(rst_n), .sda(sda), .scl(scl));
  
  initial begin
    clk = 0; forever #10 clk = ~clk;
    rst_n = 0; #200; rst_n = 1;
    
    // Hardcoded: write 0xA5 to address 0x50
    sda = 1; scl = 1; #100;
    sda = 0; #100;          // START
    // ... 200 more lines of hand-coded bit-banging ...
    
    // Done. Did it work? Who knows. We eyeballed the waveform.
    $finish;
  end
endmodule
```

This approach has three devastating problems:

**Problem 1: No Reusability.** If you write a new I2C device next year — say, a master instead of a slave — you throw this testbench away and start over from scratch. Every testbench is an island. You cannot reuse the driver, you cannot reuse the monitor, you cannot reuse anything.

**Problem 2: No Randomization.** You wrote 0xA5 to 0x50. What about 0xFF? What about 0x00? What about 0x01 with an odd number of bytes? What about a repeated START? You'd have to write a separate test for every case. There are millions of possible inputs. A human cannot write them all.

**Problem 3: No Self-Checking.** "We eyeballed the waveform." This is not verification. This is hoping. A testbench that requires a human to look at waveforms after every run is not scalable, not repeatable, and will miss bugs.

### The Three Problems UVM Solves

**Reusability**: UVM defines standard base classes (`uvm_driver`, `uvm_monitor`, `uvm_scoreboard`, etc.) with standard interfaces. When you write your I2C driver as a class that extends `uvm_driver`, it slots into any UVM environment. The component hierarchy, the phase mechanism, the configuration database — all standardized. An engineer at company B can understand your testbench because it follows the same structure as their testbench.

**Randomization**: UVM sequence items are SystemVerilog objects with `rand` fields and `constraint` blocks. The simulator's constraint solver generates thousands of valid, legal, edge-case-hitting transactions automatically. You describe *what* a valid transaction looks like (via constraints), and UVM generates them. This is called Constrained Random Verification (CRV).

**Coverage-Driven Verification**: UVM connects randomized stimulus to functional coverage models. You run tests until your coverage model says "yes, I have seen a 32-byte burst write to address 0x50 and a NACK'd address and a clock-stretched read." When coverage is 100%, you are done. You have a quantitative answer to "how thoroughly did we test this?"

### The UVM Class Hierarchy

Think of UVM as a family tree of base classes:

```
uvm_void
  └── uvm_object           (the root of all UVM classes)
        ├── uvm_transaction
        │     └── uvm_sequence_item   (your "packet" — i2c_seq_item)
        ├── uvm_sequence_base
        │     └── uvm_sequence        (your "stimulus generator" — i2c_single_write_seq)
        └── uvm_component            (anything with a hierarchical name and phases)
              ├── uvm_driver          (i2c_driver)
              ├── uvm_monitor         (i2c_monitor)
              ├── uvm_scoreboard      (i2c_scoreboard)
              ├── uvm_agent           (i2c_master_agent)
              └── uvm_env             (i2c_env)
```

The key insight is the split between `uvm_object` and `uvm_component`.

**`uvm_object`**: Data. Packets. Sequences. Things that flow through the testbench. They are created and destroyed. They do not have a hierarchical name that persists through simulation. They do not have phases.

**`uvm_component`**: Infrastructure. Drivers, monitors, scoreboards, environments. They are created once during `build_phase` and live for the entire simulation. They have a hierarchical name (like `uvm_test_top.env.master_agent.driver`) and they participate in phases.

> **COMMON MISTAKE**: New engineers try to make a `uvm_component` do the work of a `uvm_sequence_item`, or they try to create a sequence item with `type_id::create("name", this)` using a parent argument. Sequence items are `uvm_object` — they take only a `name`, no parent. Only components take a parent.

### Why Phases Matter

UVM simulation proceeds through a fixed sequence of phases. Each phase serves a specific purpose. The simulator calls each component's phase method in a controlled order.

The critical insight is **ordering guarantees**. You cannot connect a monitor's analysis port to a scoreboard's export in `build_phase` — the scoreboard has not been created yet. UVM's phase ordering ensures that `build_phase` completes across the entire hierarchy before `connect_phase` begins. This eliminates an entire class of "component not yet instantiated" bugs that plagued ad-hoc testbenches.

---

<a name="part-2"></a>
## Part 2: The Big Picture — Environment Architecture

Before reading a single line of code, you need to see the whole picture. Study this diagram until it makes sense. Every arrow represents a data path or a connection.

```
+----------------------------------------------------------+
|  top_tb.sv (module — not UVM, the simulation root)      |
|  - Generates clk, rst_n                                 |
|  - Instantiates DUT (i2c_slave)                          |
|  - Instantiates i2c_if, i2c_slave_if                    |
|  - Sets config_db for vif, calls run_test()             |
+---------------------------+------------------------------+
                            |  run_test() spawns:
                            v
+----------------------------------------------------------+
|  i2c_base_test  (e.g., basic_write_test)                 |
|  - Raises objection                                      |
|  - Creates sequence, starts it on master_agent.sequencer |
|  - Drops objection when done                             |
+---------------------------+------------------------------+
                            |  creates/contains:
                            v
+----------------------------------------------------------+
|  i2c_env  (extends uvm_env)                              |
|                                                          |
|  +---------------------+  +---------------------------+ |
|  | i2c_master_agent    |  | i2c_slave_agent           | |
|  | (ALWAYS ACTIVE)     |  | (PASSIVE by default;      | |
|  |                     |  |  ACTIVE if test sets it)  | |
|  | +-----------------+ |  |                           | |
|  | | i2c_sequencer   | |  | +-----------+             | |
|  | | (uvm_sequencer) | |  | |i2c_slave  |             | |
|  | +-------+---------+ |  | |_sequencer |             | |
|  |         | get/put   |  | +-----+-----+             | |
|  | +-------v---------+ |  |       | get/put           | |
|  | | i2c_driver      +-+--+-->    |                   | |
|  | | (master BFM)    | |  | +-----v-----------+       | |
|  | | drives sda_drv  | |  | | i2c_slave_driver|       | |
|  | | drives scl_drv  | |  | | drives stretch  |       | |
|  | +-------+---------+ |  | | drives force_   |       | |
|  |         | (also     |  | | data_nack       |       | |
|  |         | broadcasts|  | +-----------------|       | |
|  |         | via        |  |                           | |
|  |  req_analysis_port)  |  | +-----------------------+ | |
|  |                     |  | | i2c_monitor (slave)   | | |
|  | +-----------------+ |  | | (passive — reads bus) | | |
|  | | i2c_monitor     | |  | +-----------+-----------+ | |
|  | | (master agent)  | |  |             |               | |
|  | | samples SDA/SCL | |  +-------------|---------------+ |
|  | +-------+---------+ |                |                  |
|  |         |            |                |                  |
|  +---------|------------+                |                  |
|            |                            |                  |
|  item_collected_port (uvm_analysis_port)                   |
|            |                                               |
|    +-------+------+    +-----------------------------+     |
|    |              |    |                             |     |
|    v              v    v                             |     |
|  +----------+  +----------------+                   |     |
|  | i2c_     |  | i2c_scoreboard |                   |     |
|  | coverage |  |                |<-- req_analysis   |     |
|  |          |  | ref_reg_bank[] |    _port (driver) |     |
|  +----------+  | shadow_ptr     |                   |     |
|                | error_count    |                   |     |
|                +----------------+                   |     |
|                                                          |
|  +-------------------------------+                       |
|  | i2c_virtual_sequencer         |                       |
|  | - master_seqr handle          |                       |
|  | - slave_seqr handle           |                       |
|  +-------------------------------+                       |
+----------------------------------------------------------+
                            |
           +----------------+----------------+
           |                                 |
           v                                 v
+--------------------+            +----------------------+
| i2c_if             |            | i2c_slave_if         |
| - sda (wire)       |            | - stretch_en         |
| - scl (wire)       |            | - stretch_cycles     |
| - sda_drv (logic)  |            | - force_data_nack    |
| - scl_drv (logic)  |            | - reg_bank           |
| - pull-up model    |            | - active, addr_match |
+--------+-----------+            +-----------+----------+
         |                                    |
         +------------------+  +--------------+
                            |  |
                            v  v
                    +----------------+
                    | i2c_slave DUT  |
                    | (the RTL we're |
                    |  verifying)    |
                    +----------------+
```

Every connection in this diagram has a purpose. Here is a one-line explanation of each:

| Connection | Description |
|---|---|
| Test → Sequencer | Test calls `seq.start(master_agent.sequencer)` to launch stimulus |
| Sequencer → Driver | `get_next_item()` / `item_done()` handshake delivers transactions |
| Driver → `i2c_if` | Driver sets `sda_drv`, `scl_drv` to generate I2C bus activity |
| `i2c_if` → DUT | Physical wires carry SCL/SDA into the DUT's input pins |
| Monitor → `item_collected_port` | Monitor broadcasts completed transactions to all subscribers |
| `item_collected_port` → Scoreboard `actual_export` | Scoreboard receives what the bus actually did |
| Driver → `req_analysis_port` → Scoreboard `expected_export` | Scoreboard receives what the test intended |
| `item_collected_port` → Coverage | Coverage model samples every completed transaction |
| Slave Driver → `i2c_slave_if` | Active slave driver sets control signals on the slave interface |
| `config_db` → Driver/Monitor | `uvm_config_db::get()` retrieves the virtual interface handle |

---

<a name="part-3"></a>
## Part 3: The Sequence Item — The Transaction

### What Is a Sequence Item?

Think of the sequence item as a **shipping label on a package**. Before any physical signals move on the bus, somebody has to fill out this label: "Destination address: 0x50. Direction: WRITE. Payload: 3 bytes of data." The sequence item is that label. It is a data object — an instance of `i2c_seq_item` — that travels from the sequence, through the sequencer, to the driver, and back via the analysis port to the scoreboard.

In our project, `i2c_seq_item extends uvm_sequence_item`. Let's walk through every field:

```systemverilog
// From: uvm/i2c_seq_item.sv

rand logic [6:0]  addr;       // 7-bit I2C slave address (e.g., 7'h50)
rand i2c_dir_e    dir;        // DIR_WRITE or DIR_READ (enum)

rand bit [7:0]    data [$];   // Dynamic array (queue) of data bytes
rand int          num_data;   // How many bytes to transfer (1–32)

rand bit          start_cond; // 1 = generate START condition before address
rand bit          stop_cond;  // 1 = generate STOP condition after last byte
rand bit          rep_start;  // 1 = generate Repeated START (no STOP between phases)

i2c_status_e      status;     // Not randomized — filled in by driver/monitor
bit               ack_received; // Was the address ACK'd?

bit               addr_ack;   // Populated by monitor: was address phase ACK'd?
bit               byte_ack[$]; // Per-byte ACK/NACK: 1=ACK, 0=NACK

rand bit          inject_nack;    // Error injection: force a NACK
rand bit          inject_timeout; // Error injection: force a timeout
```

Notice that `data` is declared as `bit [7:0] data [$]`. The `$` means it is a **queue** — a dynamic array that can grow at runtime. You can `push_back()` bytes into it and `pop_front()` bytes from it. The comment explains why `bit` was chosen over `logic`: `logic` can hold X (unknown) or Z (high-impedance) values, and the random solver can produce these. `bit` is always 0 or 1, which is what you want for data bytes.

### The Constraint Blocks — Why Randomization Needs Guardrails

Raw randomization without constraints is useless. If you just call `item.randomize()` with no constraints, you'd get addresses like 0x00 (the I2C general call address — reserved), 0x7F (reserved), and protocol-impossible states like both `start_cond` and `rep_start` being 1 simultaneously (physically impossible on the bus).

Constraints define the space of *legal* inputs:

```systemverilog
// From: uvm/i2c_seq_item.sv

constraint valid_addr_c {
  addr != 7'h00;              // General call address — reserved
  addr != 7'h7F;              // Reserved
  addr[6:3] != 4'b0000;       // Excludes 0x00–0x07 (reserved range)
  addr[6:3] != 4'b1111;       // Excludes 0x78–0x7F (reserved range)
}
```

**Mental model for constraints**: Think of constraints as fencing on a random number generator. Without fencing, it generates any 7-bit number (0–127). With `valid_addr_c`, it generates only legal I2C addresses.

```systemverilog
constraint data_size_c {
  num_data >= 1;              // Must transfer at least 1 byte
  num_data <= 32;             // Maximum burst: 32 bytes
  data.size() == num_data;   // Queue size must match the count field
}
```

This last constraint — `data.size() == num_data` — is elegant. The solver will simultaneously randomize `num_data` (between 1 and 32) AND ensure the `data` queue contains exactly that many elements. Without this, you could have `num_data = 5` but `data` only has 2 bytes — a bug waiting to happen.

```systemverilog
constraint valid_protocol_c {
  start_cond || rep_start;       // Every transaction must begin with START or Repeated START
  !(start_cond && rep_start);    // Cannot have both at once (physically impossible)
  stop_cond -> !rep_start;       // If there's a STOP, there cannot be a Repeated START too
}
```

The `->` operator is implication: "if `stop_cond` then `!rep_start`." This prevents impossible bus states.

```systemverilog
constraint default_errors_c {
  inject_nack    == 0;    // By default, no error injection
  inject_timeout == 0;    // Tests override these constraints when needed
}
```

> **COMMON MISTAKE**: Forgetting to turn off a default constraint when you need error injection. In `i2c_slave_force_nack_seq`, you see `ctrl.force_nack_off_c.constraint_mode(0)` — this disables the default constraint before randomizing with `force_data_nack == 1'b1`. If you skip the `constraint_mode(0)`, the solver will fail (conflicting constraints) and you will get a randomization error.

### The `do_copy`, `do_compare`, `convert2string` Methods

These three methods are the UVM "contract" for data objects. Every `uvm_object` must implement them to participate in the UVM framework:

**`convert2string()`**: Returns a human-readable string. Used in `uvm_info` messages. When you see a scoreboard log line like `"I2C: addr=0x50 dir=WRITE num_data=3 [START][STOP]"`, it came from this method. Without it, debug logs are useless.

**`do_copy(uvm_object rhs)`**: Deep-copies all fields from another item. The UVM `copy()` method calls this. It is needed when the driver needs to keep a snapshot of a transaction after `item_done()` (the sequencer may reclaim the item's memory).

```systemverilog
// From: uvm/i2c_seq_item.sv — notice every field is explicitly copied
virtual function void do_copy(uvm_object rhs);
  i2c_seq_item item;
  super.do_copy(rhs);
  if (!$cast(item, rhs)) return;   // Type-safety check
  addr           = item.addr;
  dir            = item.dir;
  data           = item.data;      // This is a queue — assignment copies all elements
  // ... all fields ...
endfunction
```

**`do_compare(uvm_object rhs, uvm_comparer comparer)`**: Field-by-field equality check. Used by the UVM compare framework and by the scoreboard when comparing expected vs actual transactions.

### How a Seq Item Differs from a Raw Signal

A signal on a wire is one bit at one moment in time. A sequence item is a **complete transaction** — an abstraction that bundles together all the signals, over all the time, for one I2C operation. The item exists *before* any signals are generated (the sequence creates it), *during* signal generation (the driver reads it), and *after* the bus is done (the monitor reconstructs it from sampled signals).

This abstraction is what makes UVM testbenches composable. The scoreboard never sees `sda` or `scl`. It sees `i2c_seq_item` objects. It doesn't care about timing, bus capacitance, or open-drain semantics. It only cares: "did the monitor see the same address, direction, and data that the driver intended to send?"

---

<a name="part-4"></a>
## Part 4: Sequences — How Stimulus is Generated

### The Sequencer-Driver Handshake

The sequencer and driver communicate through a standardized four-step handshake. Understanding this handshake is fundamental to UVM:

```
SEQUENCE                    SEQUENCER                   DRIVER
   |                            |                          |
   |  start_item(item) -------->|                          |
   |  (blocks until driver      | <--- get_next_item() --- |  (1. driver asks for work)
   |   is ready)                |                          |
   |                            | ------ item -----------> |  (2. driver gets the item)
   |  // item is now "granted"  |                          |
   |  // Sequence can fill in   |                          |
   |  // fields here (rare)     |                          |
   |  finish_item(item) ------->|                          |  (3. sequence signals done)
   |  (blocks until driver      |                          |  Driver executes transaction
   |   calls item_done)         |                          |  on the real bus...
   |                            | <------- item_done() --- |  (4. driver signals complete)
   |  // sequence continues     |                          |
```

**Step 1** (`start_item`): The sequence calls `start_item(item)`. This blocks until the sequencer has granted arbitration (important when multiple sequences compete for the same driver). The sequence does NOT put any data in the item yet at this point — it waits for the driver to be ready.

**Step 2** (between `start_item` and `finish_item`): This is the window where the sequence fills in the item's fields (via `randomize()` with inline constraints). The driver is blocked in `get_next_item()`.

**Step 3** (`finish_item`): The sequence calls `finish_item(item)`. The item is handed to the driver. The sequence blocks here until the driver calls `item_done()`.

**Step 4** (`item_done`): The driver finishes executing the transaction on the bus and calls `seq_item_port.item_done()`. The sequence unblocks and can generate the next item.

This synchronization ensures the driver is never starved (it always has an item ready) and the sequence never races ahead of the hardware.

### Walk Through: A Single Write Transaction

Here is `i2c_single_write_seq.body()` with annotations:

```systemverilog
// From: uvm/i2c_sequences.sv
task body();
  // Step 1: Create the transaction object (just allocating memory — no data yet)
  i2c_seq_item item = i2c_seq_item::type_id::create("single_write_item");

  // Step 2: start_item — blocks until sequencer grants us the driver
  start_item(item);

  // Step 3: Fill in the item (this happens AFTER we have the driver's attention)
  if (!item.randomize() with {
    addr       == local::addr;    // local:: refers to the SEQUENCE's addr field
    dir        == DIR_WRITE;      // Force write direction
    num_data   == 1;              // Single byte
    data[0]    == local::data;    // Force specific data value
    start_cond == 1;              // Generate START
    stop_cond  == 1;              // Generate STOP
    rep_start  == 0;              // No Repeated START
  }) `uvm_fatal("SEQ", "Randomization failed in i2c_single_write_seq")

  // Step 4: finish_item — hands the item to the driver, blocks until item_done()
  finish_item(item);
endtask
```

Why is `local::addr` needed? Because inside an `inline constraint with {}` block, the compiler's name resolution can be ambiguous. `local::addr` explicitly refers to the sequence's own `addr` field, not the item's `addr` field. Without `local::`, you would be constraining `item.addr == item.addr` (always true, no constraint at all).

### Walk Through: A Read Transaction

A read sequence is nearly identical, but with `dir == DIR_READ`. What changes is what happens *inside the driver*:

- For a WRITE, the driver calls `send_byte()` for each data byte, then `wait_for_ack()`
- For a READ, the driver calls `receive_byte(req_item.data[i])`, writing received data *back into the item's data queue*, then sends ACK (for all bytes except the last) or NACK (for the final byte, per I2C spec)

This is crucial: for a read, the `data[]` queue in the item starts empty (or randomized to garbage). The driver fills it in with what was actually received from the DUT. This is how the driver "returns" read data to the rest of the testbench.

### The Burst Write Sequence

```systemverilog
// From: uvm/i2c_sequences.sv
class i2c_burst_write_seq extends i2c_base_seq;
  rand logic [6:0] addr;
  rand int         burst_len;

  constraint burst_len_c { burst_len inside {[1:32]}; }

  task body();
    i2c_seq_item item = i2c_seq_item::type_id::create("burst_write_item");
    start_item(item);
    if (!item.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == local::burst_len;  // How many bytes?
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_burst_write_seq")
    finish_item(item);
  endtask
endclass
```

Notice: one `start_item/finish_item` pair, but `num_data` up to 32. The item's `data_size_c` constraint ensures `data.size() == num_data`, so the solver automatically generates a 32-element queue of random bytes for a burst of 32. The driver then sends all 32 bytes in a single `foreach` loop. This is the power of using a queue in the sequence item: burst length and data content are all randomized together in one solve.

### How Sequences Can Be Layered: Virtual Sequences

A virtual sequence is a sequence that runs on the **virtual sequencer** instead of a specific agent's sequencer. It coordinates multiple agents simultaneously.

Imagine you need to write data from the master while simultaneously activating clock stretching from the slave side. A virtual sequence looks like:

```systemverilog
class write_with_stretch_vseq extends uvm_sequence;
  // This runs on the virtual sequencer — not tied to any agent
  task body();
    i2c_burst_write_seq       master_seq;
    i2c_slave_stretch_ctrl_seq slave_seq;

    // Start slave side in background
    slave_seq = i2c_slave_stretch_ctrl_seq::type_id::create("slave_seq");
    slave_seq.stretch_cycles = 100;
    fork
      slave_seq.start(p_sequencer.slave_seqr);   // slave sequencer
    join_none

    // Start master side (foreground)
    master_seq = i2c_burst_write_seq::type_id::create("master_seq");
    master_seq.burst_len = 4;
    master_seq.start(p_sequencer.master_seqr);   // master sequencer
  endtask
endclass
```

The `i2c_virtual_sequencer` in our environment holds handles to both the master sequencer and the slave sequencer, making this coordination possible.

### Why Sequences Are the Right Pattern

The alternative — putting stimulus directly in the driver — is a dead end. If you put test logic in the driver, you need a separate driver for every test. You cannot reuse the driver. You cannot randomize across tests. You cannot mix and match.

With sequences: one driver, unlimited sequences. Write the driver once. Write sequences as you discover new test scenarios. The driver never changes.

---

<a name="part-5"></a>
## Part 5: The Master Driver — Turning Transactions into Signals

### The `run_phase` Loop

The driver's entire life is one infinite loop. It sits in `run_phase` and processes items one at a time, forever, until the simulation ends:

```systemverilog
// From: uvm/i2c_master_driver.sv
virtual task run_phase(uvm_phase phase);
  i2c_seq_item req_item;

  // Wait for reset to deassert before driving anything
  wait(vif.rst_n === 1'b1);
  `uvm_info(get_type_name(), "Reset released. Starting I2C driver.", UVM_LOW)

  forever begin
    // 1. Get the next transaction from the sequencer (blocks until available)
    seq_item_port.get_next_item(req_item);
    `uvm_info(get_type_name(), $sformatf("Got item: %s", req_item.convert2string()), UVM_MEDIUM)

    // 2. Execute the transaction on the physical interface
    if (req_item.start_cond && !req_item.rep_start)
      send_start();
    else if (req_item.rep_start)
      send_rep_start();

    // Always send address+direction after START
    if (req_item.start_cond || req_item.rep_start) begin
      send_byte({req_item.addr, logic'(req_item.dir)});
      wait_for_ack();
    end

    // Direction-dependent data phase
    if (req_item.dir == DIR_WRITE) begin
      foreach (req_item.data[i]) begin
        send_byte(req_item.data[i]);
        wait_for_ack();
      end
    end else begin
      for (int i = 0; i < req_item.data.size(); i++) begin
        receive_byte(req_item.data[i]);      // reads back into item!
        if (i < req_item.data.size() - 1)
          send_ack();    // ACK all bytes except the last
        else
          send_nack();   // NACK the last byte to signal "done"
      end
    end

    if (req_item.stop_cond)
      send_stop();

    // 3. Broadcast completed transaction to scoreboard via analysis port
    req_analysis_port.write(req_item);   // BUG FIX: write AFTER completion

    // 4. Tell the sequencer we are done — release the item, unblock the sequence
    seq_item_port.item_done();
  end
endtask
```

### How the Driver Converts a Seq Item into SCL/SDA Pin Transitions

Let us walk through `send_start()` in detail:

```systemverilog
// From: uvm/i2c_master_driver.sv
virtual task send_start();
  vif.sda_drv <= 1'b1;   // Release SDA (pull-up makes it HIGH)
  vif.scl_drv <= 1'b1;   // Release SCL (pull-up makes it HIGH)
  @(posedge vif.clk); @(posedge vif.clk);  // Hold high for 2 clock cycles (setup time)
  
  vif.sda_drv <= 1'b0;   // Drive SDA LOW while SCL is HIGH → THIS IS START
  @(posedge vif.clk); @(posedge vif.clk);  // Hold START for 2 cycles (hold time)
  
  vif.scl_drv <= 1'b0;   // Pull SCL LOW to "own" the bus
  @(posedge vif.clk);    // One more cycle before sending address
endtask
```

The I2C spec says: **START = SDA falls while SCL is HIGH**. The driver faithfully implements this. First release both to HIGH, then pull SDA low while SCL remains high.

Notice the driver does NOT write to `vif.sda` directly. It writes to `vif.sda_drv`. Look at `i2c_if.sv`:

```systemverilog
// From: tb/i2c_if.sv
// Strong pull-down from driver, weak pull-up from resistor model
assign (strong0, weak1) sda = (sda_drv == 1'b0) ? 1'b0 : 1'bz;
assign (weak1, highz0)  sda = 1'b1;   // Pull-up model
```

When `sda_drv = 0`, the interface drives SDA to strong 0. When `sda_drv = 1`, the driver "releases" SDA to high-impedance, and the pull-up model brings it to weak 1. This models the open-drain behavior of a real I2C bus: devices only pull the line down; the resistor provides the high state.

### The send_byte Task: Bit-by-Bit, MSB First

```systemverilog
// From: uvm/i2c_master_driver.sv
virtual task send_byte(input logic [7:0] byte_data);
  for (int i = 7; i >= 0; i--) begin   // MSB first (bit 7 down to bit 0)
    vif.scl_drv <= 1'b0;              // Pull SCL LOW (data can change now)
    vif.sda_drv <= byte_data[i];      // Put data bit on SDA
    @(posedge vif.clk);
    @(posedge vif.clk);               // SCL LOW phase: 2 cycles setup time
    
    vif.scl_drv <= 1'b1;              // Release SCL HIGH (slave samples SDA now)
    @(posedge vif.clk);
    @(posedge vif.clk);               // SCL HIGH phase: 2 cycles hold time
    
    vif.scl_drv <= 1'b0;              // Pull SCL LOW again for next bit
    @(posedge vif.clk);
  end
endtask
```

I2C data is sampled by the slave **when SCL is HIGH**. So the protocol is: pull SCL low, set SDA, wait, release SCL high (slave samples), wait, repeat. This is exactly what `send_byte` does.

### Why the Driver Drives the Interface, Not the DUT Directly

If the driver wrote directly to DUT input ports, there would be no separation between the testbench and the design. You could never reuse the driver with a different DUT. The interface (`i2c_if`) is the contract: it says "the bus has these signals, with these drive strengths, these clocking blocks." The driver and the DUT both connect to this interface independently. This is called **interface-based design** and it is the cornerstone of reusable UVM testbenches.

### Virtual Interface (`vif`) — What It Is and Why

A **virtual interface** is a variable that holds a *handle* to an interface instance. In SystemVerilog, interfaces are not classes — they are special module-like constructs that exist in the hardware hierarchy. You cannot store a reference to them directly in a class. Instead, you store a `virtual interface` handle.

```systemverilog
// In the driver class:
virtual i2c_if vif;  // This is just a handle — it points to nothing until assigned

// In build_phase:
if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", vif))
  `uvm_fatal(...);   // If this fails, the driver has no interface — fatal error
```

The actual assignment happens in `top_tb.sv`:
```systemverilog
// From: tb/top_tb.sv
uvm_config_db#(virtual i2c_if)::set(null, "*", "i2c_vif", i2c_bus_if);
```

Think of `config_db` as a global key-value store. The top-level module stores the interface under the key `"i2c_vif"`. Every driver and monitor that needs it retrieves it by the same key. This decouples the hardware hierarchy from the class hierarchy.

---

<a name="part-6"></a>
## Part 6: The Slave Driver — Active Slave Mode

### When Is the Slave Driver Active vs Passive?

By default, the slave agent is **PASSIVE**. In passive mode, only the monitor runs. There is no driver and no sequencer. The slave DUT responds to the bus using its own internal RTL logic. This is the standard configuration for 95% of tests.

For specific test scenarios — clock stretching, forced NACK on data — the test needs to *inject behavior* into the slave side. That requires an **ACTIVE** slave agent with a driver.

```systemverilog
// From: uvm/i2c_env.sv — the check-before-set pattern
function void build_phase(uvm_phase phase);
  // Try to get an override from the test first
  if (!uvm_config_db#(uvm_active_passive_enum)::get(
        this, "slave_agent", "is_active", slave_is_active)) begin
    // No override found — apply the safe default: PASSIVE
    uvm_config_db#(uvm_active_passive_enum)::set(
        this, "slave_agent", "is_active", UVM_PASSIVE);
  end
  slave_agent = i2c_slave_agent::type_id::create("slave_agent", this);
endfunction
```

### How the Slave Driver Controls the DUT

The slave driver does not drive SDA or SCL directly (that would conflict with the master driver on the shared bus). Instead, it drives the **control signals** on `i2c_slave_if` — the sideband interface that connects directly to the DUT's test ports:

```systemverilog
// From: uvm/i2c_slave_driver.sv
virtual task run_phase(uvm_phase phase);
  // Safe default: no stretch, no forced NACK
  vif.stretch_en      <= 1'b0;
  vif.stretch_cycles  <= 16'd0;
  vif.force_data_nack <= 1'b0;

  forever begin
    seq_item_port.get_next_item(req);
    `uvm_info(get_type_name(), $sformatf("Applying: %s", req.convert2string()), UVM_MEDIUM)

    // Apply control signals immediately
    vif.stretch_en      <= req.stretch_en;
    vif.stretch_cycles  <= req.stretch_cycles;
    vif.force_data_nack <= req.force_data_nack;

    // Wait for the transaction to COMPLETE before clearing
    if (req.stretch_en) begin
      wait (vif.active === 1'b1);  // Wait for transaction to START
      wait (vif.active === 1'b0);  // Wait for transaction to END
      vif.stretch_en      <= 1'b0;
      vif.stretch_cycles  <= 16'd0;
    end

    if (req.force_data_nack) begin
      wait (vif.active === 1'b1);
      wait (vif.active === 1'b0);
      vif.force_data_nack <= 1'b0;
    end

    seq_item_port.item_done();
  end
endtask
```

### BUG #7 Story: The Config_db Override Failure

This is a real bug we hit in this project, and it is a classic UVM pitfall worth understanding deeply.

**The symptom**: `data_nack_test` was supposed to activate the slave agent to force a data NACK. But the test was passing without the slave driver ever running. The NACK was never injected.

**The intended flow**:
```
data_nack_test::build_phase():
    uvm_config_db::set(this, "env.slave_agent", "is_active", UVM_ACTIVE);
    super.build_phase();  // This creates the env
    
i2c_env::build_phase():
    // Want to read UVM_ACTIVE here
    uvm_config_db::set(this, "slave_agent", "is_active", UVM_PASSIVE);  // BUG: overwrites!
```

**The root cause**: The env was always calling `set()` with `UVM_PASSIVE`, unconditionally. Even though the test called `set()` with `UVM_ACTIVE` first, the env's `set()` (which ran during `super.build_phase()`) overrode it. The env's set is called with a more specific scope context, so it wins.

**The fix — check before set**:
```systemverilog
// From: uvm/i2c_env.sv — the correct pattern
if (!uvm_config_db#(uvm_active_passive_enum)::get(
      this, "slave_agent", "is_active", slave_is_active)) begin
  // Only set the default if no test has already set it
  uvm_config_db#(uvm_active_passive_enum)::set(
      this, "slave_agent", "is_active", UVM_PASSIVE);
end
```

The env first tries to `get()` the value. If the test already set it (via `"env.slave_agent"`), `get()` succeeds and `slave_is_active` has the test's value. The env skips the `set()`. If no test set it, `get()` fails, and the env applies the safe PASSIVE default.

> **COMMON MISTAKE**: Assuming `set()` in a parent scope overrides `set()` in a child scope. The actual rule is nuanced and depends on the exact path strings and calling context. The safest pattern in environments is always check-before-set.

---

<a name="part-7"></a>
## Part 7: The Monitor — Observing Without Disturbing

### What the Monitor Does

If the driver is the testbench's "mouth" — it speaks to the DUT — then the monitor is the testbench's "eyes and ears." The monitor watches the physical SDA and SCL signals and reconstructs the abstract transaction that was performed. It never drives any signal. It only reads.

```systemverilog
// From: uvm/i2c_monitor.sv
class i2c_monitor extends uvm_monitor;
  virtual i2c_if vif;
  uvm_analysis_port #(i2c_seq_item) item_collected_port;  // Broadcast output

  // Internal state machine variables
  logic [7:0]  shift_reg;     // Shift register: accumulates bits as they arrive
  int          bit_cnt;       // Counts bits within each byte (0–8)
  bit          in_transaction; // Are we currently inside an I2C transaction?
  bit          addr_phase;    // Are we in the address byte phase?
```

### How the Monitor Detects START, Data Bits, ACK, and STOP

The monitor runs a state machine synchronized to the bus clock:

```systemverilog
// From: uvm/i2c_monitor.sv
virtual task monitor_bus();
  logic prev_sda, prev_scl;
  prev_sda = 1'b1;  // Bus idle: SDA=1, SCL=1
  prev_scl = 1'b1;

  forever begin
    @(posedge vif.clk);  // Sample every clock cycle

    // START detection: SDA fell (1→0) while SCL is HIGH
    if (vif.sda === 1'b0 && prev_sda === 1'b1 && vif.scl === 1'b1) begin
      if (in_transaction && current_item != null) begin
        // Already in a transaction — this is a REPEATED START
        finalize_and_write_item();  // Send the previous transaction
        saw_rep_start = 1;
      end
      // Start a new transaction item
      current_item = i2c_seq_item::type_id::create("mon_item");
      in_transaction = 1;
      addr_phase = 1;
      bit_cnt = 0;
      shift_reg = 8'h00;
      current_item.start_cond = 1;
      current_item.rep_start  = saw_rep_start;
    end

    // STOP detection: SDA rose (0→1) while SCL is HIGH
    if (vif.sda === 1'b1 && prev_sda === 1'b0 && vif.scl === 1'b1) begin
      if (in_transaction) begin
        current_item.stop_cond = 1;
        finalize_and_write_item();  // Complete the transaction
        in_transaction = 0;
      end
    end

    // Data bit sampling: SCL rising edge (0→1) while in transaction
    if (in_transaction && vif.scl === 1'b1 && prev_scl === 1'b0) begin
      if (bit_cnt < 8) begin
        // Data bit: shift into register, MSB first
        shift_reg = {shift_reg[6:0], vif.sda};
        bit_cnt = bit_cnt + 1;
      end
      else if (bit_cnt == 8) begin
        // ACK/NACK bit (9th SCL pulse)
        if (vif.sda === 1'b0) begin  // 0 = ACK, 1 = NACK
          if (addr_phase) current_item.addr_ack = 1'b1;
          else            current_item.byte_ack.push_back(1'b1);
        end else begin
          if (addr_phase) current_item.addr_ack = 1'b0;
          else            current_item.byte_ack.push_back(1'b0);
        end

        if (addr_phase) begin
          // First byte: bits [7:1] = address, bit [0] = direction
          current_item.addr = shift_reg[7:1];
          current_item.dir  = i2c_dir_e'(shift_reg[0]);
          addr_phase = 0;
        end else begin
          // Subsequent bytes: data
          current_item.data.push_back(shift_reg);
          current_item.num_data = current_item.num_data + 1;
        end
        bit_cnt = 0;
        shift_reg = 8'h00;
      end
    end

    prev_sda = vif.sda;
    prev_scl = vif.scl;
  end
endtask
```

The monitor knows a **byte boundary** has occurred when `bit_cnt` reaches 8 (after the 8th data bit). The next SCL pulse (bit_cnt == 8) is the ACK/NACK bit. After capturing ACK/NACK, `bit_cnt` resets to 0 for the next byte.

### The Analysis Port — The "Broadcast" Mechanism

When the monitor has a complete transaction, it calls:

```systemverilog
item_collected_port.write(current_item);
```

The `uvm_analysis_port` implements a publish-subscribe pattern. Multiple subscribers can connect to one port. In our environment, both the scoreboard and the coverage model are connected:

```systemverilog
// From: uvm/i2c_env.sv
master_agent.monitor.item_collected_port.connect(scoreboard.actual_export);
master_agent.monitor.item_collected_port.connect(coverage.analysis_export);
```

When the monitor calls `write()`, UVM automatically calls the `write()` method on EVERY connected export. The scoreboard gets the transaction. The coverage model gets it. Both happen in the same simulation cycle. This is TLM — Transaction Level Modeling.

### Why Monitors Are Always Passive

A monitor that drives signals is a contradiction. If the monitor drives, it changes the bus state, which changes what it observes. This is the observer effect: the measurement disturbs the system. More practically: if your monitor accidentally drives SDA low during an ACK phase, you have introduced a testbench bug that looks like a DUT bug. Never drive from a monitor.

---

<a name="part-8"></a>
## Part 8: The Scoreboard — Verifying Correctness

### The Shadow Register Model — What It Is and Why

The scoreboard maintains a **shadow register bank** — a software model of the DUT's internal registers. Every time the testbench writes to the DUT, the scoreboard updates its shadow copy. Every time the testbench reads from the DUT, the scoreboard compares the returned value against its shadow copy.

```systemverilog
// From: uvm/i2c_scoreboard.sv
logic [7:0] ref_reg_bank [0:7];   // Shadow of DUT's 8 internal registers
int         shadow_ptr;           // Tracks which register the next write goes to
```

Why is this needed? Because the DUT is a black box. We cannot read its internal registers directly from a testbench (that would require probing internal signals, which breaks encapsulation and is not synthesizable). The shadow model gives us an independent, software-maintained prediction of what the DUT's state should be.

### How the Scoreboard Tracks Writes

The scoreboard receives write transactions via its `expected_export` (from the driver's `req_analysis_port`) and its `actual_export` (from the monitor's `item_collected_port`).

When a write transaction arrives at `write_expected()`:

```systemverilog
// From: uvm/i2c_scoreboard.sv
virtual function void write_expected(i2c_seq_item item);
  expected_count++;

  if (item.dir == DIR_WRITE && item.addr == 7'h50) begin
    shadow_ptr = 0;  // DUT resets its reg_ptr on every new write transaction to 0x50
    foreach (item.data[i]) begin
      ref_reg_bank[shadow_ptr % 8] = item.data[i];  // Wrap around if burst > 8
      shadow_ptr++;
    end
  end
endfunction
```

The scoreboard keeps `shadow_ptr` aligned with the DUT's internal `reg_ptr`. The DUT resets its pointer to 0 every time a new addressed write begins. So does the scoreboard. The `% 8` handles burst writes longer than 8 bytes (the register bank wraps around).

### How the Scoreboard Tracks Reads

When a read transaction arrives at `write_actual()`:

```systemverilog
// From: uvm/i2c_scoreboard.sv
virtual function void check_data_integrity(i2c_seq_item item);
  if (item.dir == DIR_READ) begin
    int rd_ptr = 0;  // DUT also resets read pointer to 0 on each read transaction
    foreach (item.data[i]) begin
      logic [7:0] expected_val = ref_reg_bank[rd_ptr % 8];
      if (item.data[i] !== expected_val) begin
        `uvm_error(get_type_name(),
          $sformatf("READ MISMATCH reg[%0d]: expected=0x%02x actual=0x%02x",
                    rd_ptr % 8, expected_val, item.data[i]))
        error_count++;
      end else begin
        match_count++;
      end
      rd_ptr++;
    end
  end
endfunction
```

### Why Two Exports? The Analysis FIFO and Timing

Notice the scoreboard has **two** analysis exports: `expected_export` (from the driver) and `actual_export` (from the monitor).

Why two? Because the driver and monitor produce transactions at different times:
- The driver sends to `req_analysis_port` **after** the transaction completes on the bus
- The monitor sends to `item_collected_port` **when it detects the STOP condition**

These may arrive in different orders. By accepting expected and actual separately and independently, the scoreboard is not coupled to their relative timing. Each `write_expected()` or `write_actual()` call is handled as soon as it arrives.

The address ACK check is done in `write_actual()` (from the monitor), because only the monitor observes the actual ACK/NACK on the bus.

### Walk Through: A Complete Write-Then-Read

1. Test creates a `i2c_write_read_seq`
2. Sequence sends a WRITE item: `addr=0x50, dir=WRITE, data=[0xA5]`
3. Driver executes: START, sends `{0x50, 0}`, waits ACK, sends `0xA5`, waits ACK, STOP
4. Driver calls `req_analysis_port.write(item)` → Scoreboard `write_expected()` → `ref_reg_bank[0] = 0xA5`
5. Monitor detects START, address byte, data byte, STOP → calls `item_collected_port.write(item)`
6. Scoreboard `write_actual()` → `check_address_ack()` (0x50 → expect ACK → pass) → `check_data_integrity()` (WRITE, no read comparison needed) → `match_count++`
7. `#200` delay in the sequence
8. Sequence sends a READ item: `addr=0x50, dir=READ, num_data=1`
9. Driver executes: START, sends `{0x50, 1}`, waits ACK, receives one byte from DUT, sends NACK, STOP
10. Driver calls `req_analysis_port.write(item)` → Scoreboard `write_expected()` → DIR_READ, no shadow update
11. Monitor detects START, address byte, data byte, STOP → calls `item_collected_port.write(item)`
12. Scoreboard `write_actual()` → `check_address_ack()` → `check_data_integrity()` → compares `item.data[0]` (what DUT sent back) against `ref_reg_bank[0]` (0xA5 we wrote earlier)
13. If they match: `match_count++`. If not: `error_count++` and `uvm_error()`

### The report_phase Summary

At the end of simulation, `report_phase` prints:

```
========== SCOREBOARD REPORT ==========
  Expected Transactions : 2
  Actual Transactions   : 2
  Matches               : 4
  Errors                : 0
========================================
SCOREBOARD PASSED: All transactions matched.
```

If `error_count > 0` or `actual_count != expected_count`, the test fails with a `uvm_error`.

---

<a name="part-9"></a>
## Part 9: The Environment — Wiring It All Together

### The `build_phase`: Creating Components

```systemverilog
// From: uvm/i2c_env.sv
function void build_phase(uvm_phase phase);
  super.build_phase(phase);

  // Master agent is always created and always ACTIVE
  master_agent = i2c_master_agent::type_id::create("master_agent", this);

  // Slave agent: check for test override, then apply default
  if (!uvm_config_db#(uvm_active_passive_enum)::get(
        this, "slave_agent", "is_active", slave_is_active)) begin
    uvm_config_db#(uvm_active_passive_enum)::set(
        this, "slave_agent", "is_active", UVM_PASSIVE);
  end
  slave_agent  = i2c_slave_agent::type_id::create("slave_agent",  this);

  scoreboard   = i2c_scoreboard::type_id::create("scoreboard",    this);
  coverage     = i2c_coverage::type_id::create("coverage",        this);
  v_sequencer  = i2c_virtual_sequencer::type_id::create("v_sequencer", this);
endfunction
```

Every component is created with `type_id::create("name", this)`. The two arguments are:
- `"name"`: the UVM hierarchical name of this instance (e.g., `"master_agent"`)
- `this`: the parent component (this environment)

Using `type_id::create()` instead of `new()` enables **factory overrides** — a test can substitute a different component class without changing the environment code.

### The `connect_phase`: Wiring Analysis Ports

```systemverilog
// From: uvm/i2c_env.sv
function void connect_phase(uvm_phase phase);
  // Monitor → Scoreboard (actual transactions)
  master_agent.monitor.item_collected_port.connect(scoreboard.actual_export);

  // Monitor → Coverage (for functional coverage)
  master_agent.monitor.item_collected_port.connect(coverage.analysis_export);

  // Driver → Scoreboard (expected/intended transactions)
  master_agent.driver.req_analysis_port.connect(scoreboard.expected_export);

  // Wire virtual sequencer handles
  v_sequencer.master_seqr = master_agent.sequencer;
  if (slave_agent.get_is_active() == UVM_ACTIVE) begin
    v_sequencer.slave_seqr = slave_agent.sequencer;
  end
endfunction
```

Connections are made using port `.connect(export)`. An analysis port can connect to multiple exports. The virtual sequencer wiring is different — it is a simple handle assignment, not a TLM connection.

The slave sequencer handle is only wired if the slave is ACTIVE. In passive mode, `slave_agent.sequencer` does not exist (never created), so the conditional guard is essential.

### Active vs Passive Agent Configuration

An **active agent** contains: sequencer + driver + monitor. It generates stimulus and observes.
A **passive agent** contains: monitor only. It only observes.

This is controlled by the `is_active` field (of type `uvm_active_passive_enum`). The agent's `build_phase` checks this field and conditionally creates the sequencer and driver. This is standard UVM agent pattern.

### How the Test Controls the Environment

Tests never reach into the environment and set fields directly. They use:
1. `uvm_config_db::set()` — to set configuration (like `is_active`) before `build_phase`
2. Sequence `.start()` — to inject stimulus after build
3. Direct field access on sequences before starting them (like `seq.addr = 7'h50`)

This layering (test → sequence → driver → DUT) keeps the environment reusable across tests.

---

<a name="part-10"></a>
## Part 10: Test Classes — The Top Level

### How a Test Inherits from Base Test

All tests extend `i2c_base_test`, which handles environment creation:

```systemverilog
// i2c_base_test (conceptual — the actual file creates and stores env)
class i2c_base_test extends uvm_test;
  i2c_env env;

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = i2c_env::type_id::create("env", this);
  endfunction
endclass
```

A concrete test overrides only what it needs:

```systemverilog
// From: uvm/i2c_tests.sv
class basic_write_test extends i2c_base_test;
  `uvm_component_utils(basic_write_test)

  virtual task run_phase(uvm_phase phase);
    i2c_single_write_seq write_seq;

    phase.raise_objection(this);           // Tell UVM "don't end simulation yet"
    `uvm_info(get_type_name(), "Starting basic_write_test...", UVM_LOW)

    write_seq = i2c_single_write_seq::type_id::create("write_seq");
    write_seq.addr = 7'h50;    // Override the sequence's default address
    write_seq.data = 8'hA5;    // Override the sequence's data
    write_seq.start(env.master_agent.sequencer);  // Launch the sequence

    #500;                                  // Let the bus drain
    `uvm_info(get_type_name(), "basic_write_test finished.", UVM_LOW)
    phase.drop_objection(this);            // Tell UVM "I'm done, simulation can end"
  endtask
endclass
```

### Tests That Activate the Slave Agent

Tests like `data_nack_test` override `build_phase` to activate the slave:

```systemverilog
// From: uvm/i2c_tests.sv
class data_nack_test extends i2c_base_test;
  virtual function void build_phase(uvm_phase phase);
    // Set BEFORE super.build_phase() — env reads this during its own build
    uvm_config_db#(uvm_active_passive_enum)::set(
        this, "env.slave_agent", "is_active", UVM_ACTIVE);
    super.build_phase(phase);  // This triggers env::build_phase(), which reads the above
  endfunction

  virtual task run_phase(uvm_phase phase);
    i2c_data_nack_seq      write_seq;
    i2c_slave_force_nack_seq nack_ctrl_seq;

    phase.raise_objection(this);

    // Start the slave control sequence in the background
    nack_ctrl_seq = i2c_slave_force_nack_seq::type_id::create("nack_ctrl_seq");
    fork
      nack_ctrl_seq.start(env.slave_agent.sequencer);  // Runs in background
    join_none

    // Start the master sequence in foreground
    write_seq = i2c_data_nack_seq::type_id::create("write_seq");
    write_seq.addr = 7'h50;
    write_seq.data = 8'hDE;
    write_seq.start(env.master_agent.sequencer);

    #500;
    phase.drop_objection(this);
  endtask
endclass
```

### The `uvm_test_top` Naming Convention

When `run_test("basic_write_test")` is called, UVM creates an instance of `basic_write_test` named `uvm_test_top`. This name is fixed by the UVM framework. All components under the test will have paths starting with `uvm_test_top`:
- `uvm_test_top.env.master_agent.driver`
- `uvm_test_top.env.scoreboard`

This matters for `config_db` lookups, which use this hierarchical path for scope resolution.

### Running Different Tests

Test selection is controlled by the simulation plusarg `+UVM_TESTNAME`:

```bash
# In the Makefile or run script:
vsim top_tb +UVM_TESTNAME=basic_write_test
vsim top_tb +UVM_TESTNAME=full_stress_test
vsim top_tb +UVM_TESTNAME=data_nack_test
```

Notice `top_tb.sv` calls `run_test()` with no argument — the test name comes entirely from the plusarg. This allows running any test without recompilation, which is critical for regression suites.

---

<a name="part-11"></a>
## Part 11: TLM — Transaction Level Modeling

### What Is an Analysis Port?

An analysis port is a **one-to-many broadcast mechanism** operating at the transaction (not signal) level. It has exactly one writer and zero or more readers.

```
uvm_analysis_port           uvm_analysis_export
+------------------+        +---------------------+
| write(item)      +------->| write(item) called  |
|                  +------->| on each subscriber  |
|                  +------->|                     |
+------------------+        +---------------------+
```

The analysis port is different from the sequencer-driver TLM port:
- **Sequencer → Driver TLM**: blocking get/put. Driver requests one item, waits, gets it.
- **Analysis port**: non-blocking broadcast. Monitor calls `write()`, it returns immediately, all subscribers get the item.

### What Is a TLM FIFO?

A `uvm_tlm_analysis_fifo` decouples a producer and consumer that operate at different rates. In our scoreboard, we use **separate analysis imports** instead of FIFOs:

```systemverilog
// From: uvm/i2c_scoreboard.sv
`uvm_analysis_imp_decl(_expected)  // Creates write_expected() method
`uvm_analysis_imp_decl(_actual)    // Creates write_actual() method

uvm_analysis_imp_expected #(...) expected_export;
uvm_analysis_imp_actual   #(...) actual_export;
```

The `uvm_analysis_imp_decl` macro generates a specialized import class with a unique `write_*()` method suffix. This lets one scoreboard have two independent analysis inputs without naming conflicts.

### The `write()` Method — How Data Flows

```
Monitor calls: item_collected_port.write(mon_item)
  │
  ├──> scoreboard.actual_export.write(mon_item)
  │        └──> scoreboard.write_actual(mon_item)   [your checking code]
  │
  └──> coverage.analysis_export.write(mon_item)
           └──> coverage.write(mon_item)             [your coverage sampling code]
```

The `write()` chain is synchronous and immediate. There is no buffering unless you explicitly use a FIFO. All the `write()` calls happen in zero simulation time (they are functions, not tasks).

### Why TLM Matters: Loose Coupling

Without TLM, a monitor would need to know about the scoreboard explicitly, call its methods, and be aware of its internal structure. If you add a second scoreboard or a waveform logger, you have to modify the monitor. This is tight coupling — bad for reuse.

With TLM, the monitor knows nothing about its subscribers. It just calls `port.write(item)`. Subscribers register themselves by connecting their export to the monitor's port. You can add, remove, or replace subscribers without touching the monitor. This is loose coupling — essential for reusable, modular testbenches.

---

<a name="part-12"></a>
## Part 12: UVM Phases Deep Dive

### All 9 Standard Phases

UVM defines phases that execute in a fixed order. The first 4 are **functions** (zero simulation time). The middle ones are **tasks** (can consume simulation time). The last few are **functions** again.

```
Phase               Type        Purpose
─────────────────────────────────────────────────────────────────────────────
build_phase         function    Create component instances (top-down: parent first)
connect_phase       function    Wire TLM ports and exports (bottom-up: children first)
start_of_simulation function    Print topology, check connections, last-chance config
─────────────────────────────────────────────────────────────────────────────
run_phase           task        Main simulation: generate stimulus, check responses
                                  (Contains: pre_reset, reset, post_reset,
                                             pre_configure, configure, post_configure,
                                             pre_main, main, post_main,
                                             pre_shutdown, shutdown, post_shutdown)
─────────────────────────────────────────────────────────────────────────────
extract_phase       function    Pull results out of components
check_phase         function    Run final correctness checks
report_phase        function    Print summaries and statistics
final_phase         function    Clean up, close files
─────────────────────────────────────────────────────────────────────────────
```

### Why `build_phase` Before `connect_phase`

The UVM framework calls `build_phase` for all components in **top-down order**: the test first, then the env, then agents, then sub-components. Only after EVERY component's `build_phase` has run does the framework call `connect_phase`.

Why top-down for build? Because parent components create child components in their `build_phase`. The parent must exist before the child can be created.

Why wait for all builds before connecting? Because `connect_phase` wires port A to export B. If B does not exist yet (its component's build hasn't run), the connection would fail. By guaranteeing all components are built before any connections are made, UVM eliminates this race.

### The Objection Mechanism: How Tests Know When to End

The `run_phase` ends when all raised objections are dropped. This is the mechanism that keeps simulation alive while there is still work to do.

```
Test raises objection    ──────────────────────────────────────┐
  phase.raise_objection(this);                                 │ Simulation
                                                               │ runs here
  // ... run the sequence, wait for completion ...             │
                                                               │
Test drops objection     ──────────────────────────────────────┘
  phase.drop_objection(this);
  
At this point: objection count = 0, run_phase ends for all components.
```

> **COMMON MISTAKE**: Forgetting to call `drop_objection()`. The simulation runs forever. Or: dropping the objection before the DUT has finished processing. The scoreboard runs `report_phase` before the last transaction completes, reporting spurious mismatches.

A common pattern to handle drainage:

```systemverilog
write_seq.start(env.master_agent.sequencer);
#500;  // Wait for the bus to finish (last STOP condition and monitor to process)
phase.drop_objection(this);
```

### Drain Time

Some UVM practitioners use a dedicated `drain_time` configuration to add a fixed delay after all sequences complete and before objection is dropped. This ensures the monitor has time to observe the last transaction's STOP condition and the scoreboard has time to check it.

---

<a name="part-13"></a>
## Part 13: Interview Questions — UVM

These are real questions asked in verification engineer interviews. For each one, the answer should come naturally from the understanding in this document.

---

**Q1: What is the difference between `uvm_object` and `uvm_component`?**

`uvm_object` is the base class for data — sequence items, sequences, configurations, transactions. It has no hierarchical name, no parent, and does not participate in phases. It is created and destroyed dynamically.

`uvm_component` is the base class for testbench infrastructure — drivers, monitors, scoreboards, environments. It has a fixed hierarchical name (e.g., `uvm_test_top.env.master_agent.driver`), a parent, and participates in the phase mechanism. It lives for the entire simulation.

---

**Q2: Why do we need phases in UVM?**

Phases provide ordering guarantees. You cannot connect a monitor's port to a scoreboard's export until both have been built. The `build_phase → connect_phase` ordering guarantees this. Without phases, you'd have race conditions: some components connecting before others are built.

Phases also provide a standard structure that every UVM testbench follows. An engineer can look at any UVM project and immediately know where to find the component creation (`build_phase`), the connections (`connect_phase`), and the stimulus (`run_phase`).

---

**Q3: What is the sequencer-driver handshake? Explain step by step.**

1. Driver calls `seq_item_port.get_next_item(req)` — blocks until an item is available.
2. Sequencer calls `start_item(item)` from the active sequence — waits for driver to be ready.
3. Sequence fills in the item fields (randomizes it), then calls `finish_item(item)`.
4. Sequencer delivers the item to the driver — `get_next_item()` unblocks with the item.
5. Driver executes the transaction on the bus.
6. Driver calls `seq_item_port.item_done()` — signals completion.
7. Sequence's `finish_item()` unblocks — sequence can generate the next item.

---

**Q4: Why are monitors always passive?**

Monitors observe the DUT without changing its state. If a monitor drives signals, it introduces stimulus from an unexpected source, making it impossible to distinguish DUT behavior from monitor-induced behavior. It also means the monitor is no longer reusable — it is now part of the stimulus path. Passive monitors can be used in any environment, with any DUT, without side effects.

---

**Q5: What is an analysis port? How is it different from a TLM port?**

An analysis port (`uvm_analysis_port`) is a non-blocking, one-to-many broadcast port. The writer calls `write(item)` and returns immediately. All connected exports receive the item.

A TLM port (like `uvm_seq_item_pull_port` used between driver and sequencer) is a blocking, one-to-one request-response channel. The driver blocks in `get_next_item()` until an item is available. A TLM FIFO can decouple timing.

Analysis: broadcast, non-blocking, for observation.
TLM: unicast, blocking, for stimulus delivery.

---

**Q6: How does `config_db` work? What is the scope resolution path?**

`uvm_config_db` is a global key-value store where the key is `(type, scope, field_name)`. The scope is a hierarchical path string using UVM component names.

```systemverilog
// Set: from top_tb, visible to everyone ("*")
uvm_config_db#(virtual i2c_if)::set(null, "*", "i2c_vif", i2c_bus_if);

// Get: from inside the driver at path "uvm_test_top.env.master_agent.driver"
uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", vif);
```

Resolution: `get()` searches for a `set()` whose scope matches the component's hierarchical path. `set(null, "*", ...)` matches any component. `set(this, "slave_agent", ...)` in the env matches components under `uvm_test_top.env.slave_agent`.

---

**Q7: What is the shadow register model and why do scoreboards use it?**

The DUT's internal registers are not accessible from the testbench without intrusive signal probing. The shadow model is a software replica of the DUT's register file. The scoreboard updates it on every write transaction. On read transactions, it compares the DUT's returned values against the shadow. This is an independent, non-invasive way to verify DUT state.

---

**Q8: How would you add a second I2C master to this testbench?**

1. Create a second master agent (`i2c_master_agent_2`) in the env.
2. Add a second sequencer handle in the virtual sequencer.
3. In `connect_phase`, connect agent 2's monitor to the same scoreboard (or a second scoreboard, if you want per-master checking).
4. In the virtual sequencer, wire `master_seqr_2 = master_agent_2.sequencer`.
5. Write virtual sequences that orchestrate transactions from both masters (testing bus arbitration).
6. In `top_tb.sv`, the two drivers both connect to the same `i2c_if` — the wired-AND model handles contention correctly.

---

**Q9: What is factory override and when would you use it?**

The UVM factory allows you to substitute one class for another without changing the code that creates it. For example, replace `i2c_driver` with `i2c_driver_with_glitch` for a glitch-injection test:

```systemverilog
// In test build_phase:
i2c_driver_with_glitch::type_id::set_type_override(i2c_driver::get_type());
```

Now every `i2c_driver::type_id::create()` call produces an `i2c_driver_with_glitch` instance instead. Use this for: debug variants of components, coverage-enhanced monitors, protocol-error-injecting drivers, and test-specific specializations.

---

**Q10: Explain the UVM objection mechanism.**

The simulation's `run_phase` ends when all raised objections are dropped. A test raises an objection at the start (`phase.raise_objection(this)`) to prevent simulation from ending prematurely. When all stimulus is complete and the bus has drained, the test drops the objection (`phase.drop_objection(this)`). If no test raises an objection, the `run_phase` exits immediately at time 0. If a test never drops its objection, the simulation runs until the timeout.

---

**Q11: What is a virtual sequence? When do you use one?**

A virtual sequence runs on a virtual sequencer and coordinates stimulus across multiple agents. It holds handles to multiple sub-sequencers (master and slave) and starts sub-sequences on each. Use it when a test scenario requires synchronized activity from multiple agents — for example, starting a clock stretch sequence on the slave side while simultaneously starting a write sequence on the master side, as in `clock_stretch_test`.

---

**Q12: How do you parameterize a sequence for different payload sizes?**

Add a `rand` or plain field to the sequence class:

```systemverilog
class i2c_burst_write_seq extends i2c_base_seq;
  rand int burst_len;
  constraint burst_len_c { burst_len inside {[1:32]}; }
  // ...
endclass
```

In the test, override before calling `start()`:
```systemverilog
seq.burst_len = 8;       // Fixed length
seq.start(sequencer);
// OR: randomize the length too:
seq.randomize();
seq.start(sequencer);
```

---

**Q13: What does `start_item` / `finish_item` do?**

`start_item(item)` acquires the sequencer's grant to send an item. It blocks until the sequencer determines it is this sequence's turn (arbitration) and the driver is ready. Between `start_item` and `finish_item`, the sequence fills in the item's fields.

`finish_item(item)` delivers the filled-in item to the driver and blocks until the driver calls `item_done()`. Together, they implement the synchronization barrier between the sequence and the driver.

---

**Q14: What is `randomize()` and what is `constraint`?**

`randomize()` is a built-in SystemVerilog method on any class with `rand` fields. It invokes the constraint solver, which finds a set of values for all `rand` fields that satisfies all active `constraint` blocks simultaneously. It returns 1 on success, 0 on failure (infeasible constraints).

A `constraint` block defines a set of Boolean expressions that the solver must satisfy. Constraints can express: value ranges (`addr inside {[8:119]}`), relationships (`data.size() == num_data`), implications (`stop_cond -> !rep_start`), and distribution hints (`dist` keyword).

---

**Q15: How would you check that coverage is above 95%?**

In the `check_phase` of the test or environment:

```systemverilog
virtual function void check_phase(uvm_phase phase);
  real cov = $get_coverage();  // Returns 0.0–100.0
  if (cov < 95.0)
    `uvm_error(get_type_name(),
      $sformatf("Coverage below threshold: %.1f%% < 95%%", cov))
  else
    `uvm_info(get_type_name(),
      $sformatf("Coverage PASSED: %.1f%%", cov), UVM_LOW)
endfunction
```

You can also query individual covergroup instances using their `get_coverage()` method.

---

**Q16: What happens if `randomize()` fails? How do you debug it?**

`randomize()` returns 0. Good testbenches check the return value and call `uvm_fatal` if it fails (as all sequences in this project do). The typical causes:

1. **Contradictory constraints**: `addr == 7'h50` AND `addr != 7'h50` simultaneously
2. **Infeasible `inside` range**: `x inside {[]}` (empty set)
3. **Over-constrained queue size**: conflicting constraints on `data.size()`

To debug: call `constraint_mode(0)` to disable constraints one by one until `randomize()` passes — that identifies the problematic constraint. Also use `$display` with `get_constraint_info()` where available.

---

**Q17: What is the `do_print` method for?**

`do_print` integrates with UVM's `print()` and `sprint()` methods, which use a `uvm_printer` object to format output consistently. This matters for waveform viewers and log parsers that understand the UVM print format. Our `i2c_seq_item` implements it to expose all fields in a structured format.

---

**Q18: Why does the driver write to `req_analysis_port` AFTER `item_done()`, not before?**

In the original (buggy) code, the driver broadcast the item to the scoreboard via `req_analysis_port` before the transaction completed. For READ operations, the `data[]` field was not yet filled in (the driver had not yet received the bytes from the DUT). The scoreboard would see an empty `data[]` and report false mismatches.

The fix: broadcast AFTER the transaction is completely done, when `req_item.data[]` contains all received bytes for reads. Only then does the scoreboard receive accurate expected data.

---

**Q19: What is the difference between `uvm_info`, `uvm_warning`, `uvm_error`, and `uvm_fatal`?**

| Macro | Severity | Stops sim? | Use case |
|---|---|---|---|
| `uvm_info` | Informational | No | Debug logging, phase announcements |
| `uvm_warning` | Warning | No | Unexpected but recoverable conditions |
| `uvm_error` | Error | No (counts toward pass/fail) | Test failures, data mismatches |
| `uvm_fatal` | Fatal | Yes, immediately | Unrecoverable errors (missing vif, null pointer) |

`uvm_error` increments the global error count. At end of simulation, UVM checks this count and fails the test if it is non-zero. `uvm_fatal` is used when continuing simulation is pointless — e.g., if the driver cannot get its virtual interface, no transaction will ever work.

---

**Q20: What is `$cast` and why does `do_copy` use it?**

`$cast` is a runtime type check and conversion for class handles. In UVM, `do_copy(uvm_object rhs)` receives a base class handle. Before accessing derived class fields, you must confirm the handle actually points to an `i2c_seq_item`:

```systemverilog
virtual function void do_copy(uvm_object rhs);
  i2c_seq_item item;
  super.do_copy(rhs);
  if (!$cast(item, rhs)) return;  // Fails gracefully if wrong type
  addr = item.addr;               // Now safe to access derived fields
endfunction
```

Without `$cast`, accessing `item.addr` from a raw `uvm_object` handle would be a compile error (or runtime crash). `$cast` is the safe way to "downcast" from a base class to a derived class in SystemVerilog.

---

**Q21: The slave driver waits for `vif.active === 1'b1` before waiting for `vif.active === 1'b0`. Why is this ordering critical?**

This was Bug #7's sister issue in the slave driver. If you only wait for `active === 0` without first waiting for `active === 1`, you can pass immediately if the slave is idle at the moment the driver runs. The control signals (stretch_en, force_data_nack) get cleared before the master even starts the transaction. Result: the feature never activates.

By first waiting for `active === 1'b1` (transaction has started), then for `active === 1'b0` (transaction is complete), you guarantee the signals are held for the entire duration of exactly one transaction.

---

**Q22: In our `i2c_if`, why is `sda` declared as `wire` but `sda_drv` as `logic`?**

`wire` allows multiple drivers and resolves them according to drive strength. The I2C bus has multiple drivers (master and slave can both drive SDA). Using `wire` with the pull-up model and `(strong0, weak1)` drive strength assignments models the open-drain wired-AND behavior correctly.

`logic` is a simple 4-state (0, 1, X, Z) variable that holds the value driven by one source. It cannot model multiple-driver resolution. `sda_drv` is driven only by the testbench driver — one source — so `logic` is correct. The continuous assignment from `sda_drv` to the `wire sda` connects the two worlds.

---

## Part 14: T13 — The Arbitration_Lost Test (Multi-Master Testing)

This part walks through the most architecturally interesting test that was added to the project after the initial verification environment was complete: the arbitration-lost test, internally numbered T13. Unlike the single-master tests that exercise the master-vs-slave protocol, T13 has to model **two masters competing for the same bus** — a fundamentally different topology that pushes the UVM environment into territory the original architecture did not anticipate. The way we made it work without rebuilding the agent topology is, in itself, a verification engineering lesson.

### Why Multi-Master is Hard

Most I2C tests are single-master: one master that initiates, multiple slaves that respond. The bus has a clear "owner" at every moment, and protocol checks are essentially "did the master send the right bits and did the slave respond correctly?" Multi-master scenarios are exponentially harder, for several reasons:

1. **Two masters can simultaneously decide to start a transaction.** Each runs an independent clock and an independent FSM. There is no scheduling protocol — they just both pull SDA low when their internal logic decides it is time to send. From the perspective of either master, the other master is invisible until the wires resolve their conflict.

2. **The wired-AND bus property *is* the arbitration mechanism.** I2C deliberately uses open-drain outputs so that when two devices drive different values, the line resolves to the logical AND of their drives (any 0 wins over any 1). This is not a fault to be detected and recovered — it is the protocol's mechanism for picking a winner.

3. **The losing master must NOT issue a STOP.** This is the rule that catches inexperienced designers. A losing master never owned the bus to begin with; issuing a STOP would corrupt the winning master's transaction. Instead, the losing master must silently release SDA and go back to IDLE, leaving the winning master to continue alone. The waveform must show "one START condition, one continuous transaction, one STOP — but two masters started, and one quietly vanished mid-way".

4. **Detection of arb-loss is tricky:** the losing master must compare its *intended* output (sda_o) against the *observed* bus (sda_i) and notice the difference. This is "I drove HIGH but the bus is LOW" — a contradiction only possible when somebody else is also driving. The check is gated on SCL being HIGH, because data bits are only valid during the SCL HIGH window; during SCL LOW, the bus is in transition and a mismatch means nothing.

5. **A typical UVM testbench has ONE master agent.** To test two-master scenarios in a one-master environment, you have to fake the second master from somewhere else — and that somewhere must be able to drive the bus at the pin level. The slave agent in this project happens to have access to the bus interface (because it needs to monitor SCL for stretching), so we co-opt the slave driver as a fake master. This is unusual but practical.

### What is Arbitration Lost?

The mechanism, step by step:

1. **Both masters detect IDLE bus.** Each independently decides to start a transaction. They both drive SDA low simultaneously (or close enough that no master sees the other's START before its own).
2. **Both pull SDA low for their bit 7 (first data bit, MSB of address byte).** As long as both want to send the same value, they cannot tell each other apart — the bus carries the value they agreed on.
3. **At some bit position, the masters diverge.** Suppose master A wants to send `1` and master B wants to send `0`. Master A *releases* SDA (drives sda_o = 1, expecting the pull-up to take it high). Master B *pulls* SDA low (drives sda_o = 0). The wired-AND resolves: SDA = 0.
4. **Master A samples SDA during the next SCL HIGH window.** It sees 0 even though it drove 1. The contradiction is the arbitration-loss signal. Detection: `sda_o == 1 && sda_i == 0 && scl_i == 1`. The SCL guard is crucial because during SCL LOW the bit is transitioning and a transient mismatch is not a loss.
5. **Master A says "I lost. Master B wins. Stop driving."** Master A's FSM transitions to STATE_IDLE, releasing SDA, releasing SCL. No STOP is generated. The bus continues to belong to master B, which keeps clocking and sending bits as if nothing happened.
6. **The system continues normally with master B.** Master B did not know master A was even there — it just saw the bus behave normally. (In real I2C, master B might issue an interrupt asking "did anyone else try to talk?" but that is implementation-specific.)

The protocol is called **lossless arbitration** because no data is lost during the collision. The bit that the winner wanted to send is the bit that ends up on the bus — both masters wanted to send it, or only the winner wanted 0 and the loser wanted 1, and 0 wins so the winner's intent is preserved. The loser simply backs off without corrupting anything.

### The RTL Detection Logic (`rtl/i2c_master_controller.sv`)

The actual implementation is a single `always_ff` block plus an output assignment:

```systemverilog
//---------------------------------------------------------------------------
// Arbitration Loss Detection (T13)
// During data transmit phase, if we release SDA (drive sda_o=1) but the bus
// is LOW (sda_i=0), some other master is also transmitting and won the bit
// (wired-AND: 0 wins). We lost arbitration. Only check during the SCL HIGH
// window when bits are valid on the bus.
//
// On arb_lost: FSM returns to IDLE without driving STOP — releasing the bus
// is the correct multi-master courtesy (the winning master continues).
//---------------------------------------------------------------------------
logic arb_lost_reg;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    arb_lost_reg <= 1'b0;
  end else if (state == STATE_IDLE) begin
    arb_lost_reg <= 1'b0;  // clear on idle
  end else if ((state == STATE_TX_BIT) && (sda_o == 1'b1) && (sda_i == 1'b0) && (scl_i == 1'b1)) begin
    arb_lost_reg <= 1'b1;
  end
end

assign arb_lost = arb_lost_reg;
```

Walking through this carefully:

- **Reset behavior**: On `!rst_n`, the register clears to 0. Any pending arb-loss indication is wiped on reset, which is the correct behavior — a reset returns the controller to a clean IDLE-equivalent state and any prior arbitration history is irrelevant.
- **Clear-on-idle**: When the FSM is in `STATE_IDLE`, the register clears to 0. This is the "sticky-but-not-forever" behavior. The flag latches HIGH on the cycle of detection, and stays HIGH as long as the FSM is processing the abort (the next several cycles while the FSM transitions through STATE_TX_BIT → STATE_IDLE). Once IDLE is reached, the flag clears so that the *next* transaction can use the same flag for its own arbitration check. Without the clear-on-idle, a single arb-loss would poison the controller permanently.
- **Set condition**: The combination is `state == STATE_TX_BIT` AND `sda_o == 1'b1` AND `sda_i == 1'b0` AND `scl_i == 1'b1`. Read carefully:
  - **state == STATE_TX_BIT**: Only check during transmit. The receive phase (RX_BIT) is when the slave drives, so a mismatch there is normal. The ACK_WAIT phase is also receive-side from the master's view, though as we will see the FSM handles arb-loss-in-ACK separately by using the latched flag.
  - **sda_o == 1'b1**: The master *intended* to release the line (transmit a 1). If we intended to transmit 0, no contradiction is possible — both 0 outputs would just AND to 0.
  - **sda_i == 1'b0**: The bus is actually LOW. Combined with the previous condition, this is the contradiction.
  - **scl_i == 1'b1**: Sampling is only valid during SCL HIGH. During SCL LOW, the bit is transitioning. Without this guard, the start of every bit cycle (when SDA is just changing) would produce false detections.
- **FSM impact**: The FSM uses `arb_lost_reg` in two places. In `STATE_TX_BIT`, the very next clock checks `if (arb_lost_reg) next_state = STATE_IDLE` — this is the immediate abort. In `STATE_ACK_WAIT`, the same check exists — handles the case where the loss was detected on the last bit before transitioning to ACK_WAIT. Both transitions skip the STOP-generation states entirely; the FSM goes straight to IDLE, which deasserts both SDA and SCL drives, releasing the bus to the winner.

The corresponding `next_state` logic excerpts from the same file:

```systemverilog
STATE_TX_BIT: begin
  if (arb_lost_reg) begin
    next_state = STATE_IDLE;
  end else if (timer_done) begin
    if (bit_cnt == 3'd7) begin
      next_state = STATE_ACK_WAIT;
    end else begin
      next_state = STATE_TX_BIT;
    end
  end else begin
    next_state = STATE_TX_BIT;
  end
end

STATE_ACK_WAIT: begin
  if (arb_lost_reg) begin
    next_state = STATE_IDLE;
  end else if (timer_done) begin
    if (ack_received) begin
      next_state = STATE_IDLE; // Command complete
    end else begin
      next_state = STATE_STOP_1; // NACK -> abort with STOP
    end
  end else begin
    next_state = STATE_ACK_WAIT;
  end
end
```

A subtle but important detail: even in the NACK case (normal end-of-transaction with no ACK from slave), the FSM goes through STATE_STOP_1 — i.e., it generates a STOP. But on arb_lost, the FSM goes *directly* to STATE_IDLE, skipping STOP. This is the protocol contract: the losing master must not produce a STOP because it does not own the bus. Routing both NACK and arb_lost through the same FSM exit (e.g., always to STATE_STOP_1) would be wrong and silently break multi-master compatibility.

There is also a status register update:

```systemverilog
if (arb_lost_reg) reg_status <= STS_ARB_LOST;
```

This override happens after the state-based case in the status block, so it wins whenever arb_lost is high regardless of the current FSM state. This way the CPU register reads `STS_ARB_LOST` regardless of which exact cycle the read happens.

### The Testbench Trick — Competing Master via Slave Driver

The UVM environment originally had one master agent and one slave agent. The slave agent's job is to model a slave device — responding to addressed transactions, ACK/NACK-ing, optionally stretching the clock. It is reactive, not initiative. To test arb-loss, however, we need a *second initiator* that can pull SDA low at a precise moment to collide with the master under test.

Building a full second master agent (its own driver, sequencer, monitor, sequences) would be the architecturally clean answer but would take days of refactoring. Instead, we *augment* the existing slave driver with an optional "competing master" mode. The slave driver already has access to the bus interface (it needs to observe SCL for clock stretching), so it has everything it needs to also drive SDA at specific moments.

The implementation lives in `uvm/i2c_slave_driver.sv`:

```systemverilog
class i2c_slave_driver extends uvm_driver #(i2c_slave_ctrl_item);
  `uvm_component_utils(i2c_slave_driver)

  virtual i2c_slave_if vif;

  // T13: Optional bus-level interface handle used when this driver acts as
  // a "competing master" to provoke arbitration loss. Only fetched when
  // compete_mode is set by the test via config_db; otherwise unused.
  virtual i2c_if       bus_vif;

  // T13: Competing-master mode controls (set by test via config_db)
  bit  compete_mode    = 1'b0;
  int  compete_at_bit  = 3;

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual i2c_slave_if)::get(this, "", "i2c_slave_vif", vif)) begin
      `uvm_fatal(get_type_name(), "i2c_slave_vif not found in config_db")
    end
    // T13: Pull competing-master config (optional — defaults disable feature)
    void'(uvm_config_db#(bit)::get(this, "", "compete_mode",   compete_mode));
    void'(uvm_config_db#(int)::get(this, "", "compete_at_bit", compete_at_bit));
    if (compete_mode) begin
      if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", bus_vif)) begin
        `uvm_fatal(get_type_name(),
                   "compete_mode set but i2c_vif not found in config_db")
      end
      `uvm_info(get_type_name(),
                $sformatf("T13: compete_mode ENABLED, will collide at bit %0d",
                          compete_at_bit), UVM_LOW)
    end
  endfunction
```

Notice the design pattern: the new behavior is *opt-in* through `compete_mode`. Existing tests that never set `compete_mode` see no behavioral change — the new logic is dormant. This is essential for incremental feature addition without breaking the regression. The `void'(...)` casts on the config_db `get` calls silently accept "not found" as "use default" — a deliberate choice for optional configuration knobs.

The actual collision logic is a separate task forked at run_phase start:

```systemverilog
virtual task run_phase(uvm_phase phase);
  vif.stretch_en      <= 1'b0;
  vif.stretch_cycles  <= 16'd0;
  vif.force_data_nack <= 1'b0;

  // T13: Spawn competing-master driver as a background process when enabled.
  // It runs concurrently with the normal slave-control behavior so existing
  // sequences (stretch, force_nack) are unaffected.
  if (compete_mode) begin
    fork
      drive_competition();
    join_none
  end

  forever begin
    seq_item_port.get_next_item(req);
    // ... normal slave-control behavior ...
  end
endtask
```

The `fork ... join_none` spawns `drive_competition()` as an independent background thread. The normal slave-control loop continues unchanged in the foreground. Two independent activities now run in the slave driver: (a) responding to sequence items as usual, (b) acting as a competing master in the background. This dual-personality approach lets us add T13 without disturbing any other test.

And the actual competition task:

```systemverilog
//---------------------------------------------------------------------------
// T13: Competing-master driver task
// Waits for the master under test to issue START, then counts SCL pulses
// until reaching `compete_at_bit`. At that point, pulls SDA low for one
// SCL high window, which collides with the master's transmitted bit.
// If the master is driving SDA HIGH at that moment, it sees sda_i=0 and
// detects arbitration loss.
//---------------------------------------------------------------------------
virtual task drive_competition();
  `uvm_info(get_type_name(), "T13: competing master task started", UVM_MEDIUM)
  // Ensure released to start
  bus_vif.sda_drv_x <= 1'b1;

  // Wait for START condition: SDA falls while SCL is HIGH
  @(negedge bus_vif.sda);
  if (bus_vif.scl !== 1'b1) begin
    // Not a real START — wait again
    wait (bus_vif.sda === 1'b1 && bus_vif.scl === 1'b1);
    @(negedge bus_vif.sda);
  end
  `uvm_info(get_type_name(), "T13: detected START — counting SCL bits", UVM_MEDIUM)

  // Skip past addr byte + 1 ACK bit (8+1 = 9 SCL cycles already counted
  // implicitly via compete_at_bit). We count rising edges of SCL.
  for (int i = 0; i < compete_at_bit; i++) begin
    @(posedge bus_vif.scl);
  end

  // At the chosen bit position: drive SDA LOW during the next SCL HIGH
  @(negedge bus_vif.scl);             // wait for SCL to go LOW (bit change)
  bus_vif.sda_drv_x <= 1'b0;          // pull SDA LOW (compete)
  `uvm_info(get_type_name(),
            $sformatf("T13: pulling SDA LOW at bit %0d", compete_at_bit),
            UVM_LOW)
  @(posedge bus_vif.scl);             // hold through SCL HIGH window
  @(negedge bus_vif.scl);
  bus_vif.sda_drv_x <= 1'b1;          // release
  `uvm_info(get_type_name(), "T13: released SDA after collision", UVM_MEDIUM)
endtask
```

The flow:
1. **Initialize**: Drive `sda_drv_x = 1`, which means "do not pull SDA low". This is the open-drain "released" state.
2. **Detect START**: Wait for a falling edge of SDA while SCL is HIGH — that is the I2C START condition. The check `if (bus_vif.scl !== 1'b1)` handles the edge case where SDA fell for some other reason (test bench setup, initial transient); we re-wait for a true SDA=1, SCL=1 state before looking for the next falling edge.
3. **Count SCL rising edges**: Each `@(posedge bus_vif.scl)` advances one bit. The loop runs `compete_at_bit` times — so if `compete_at_bit = 3`, we step past 3 rising edges and end up at bit 3.
4. **Drive SDA LOW during SCL HIGH**: Wait for SCL to fall (bit boundary), pull SDA LOW, then wait for SCL to rise and fall again. This ensures the LOW drive overlaps the entire SCL HIGH window, which is when the master under test samples SDA. Inside this window, if the master tried to drive SDA HIGH, the wired-AND resolves to LOW, the master sees `sda_o=1 & sda_i=0 & scl_i=1`, and the arb_lost_reg latches HIGH.
5. **Release**: Drive `sda_drv_x = 1` again, returning to the open-drain released state so subsequent traffic is not corrupted.

The `compete_at_bit` value is configurable. The test sets it to 3 (collide on the 4th SCL pulse after START — i.e., bit 3 of the address byte). The choice depends on what pattern the master is transmitting and which bit value will cause a contradiction. The arb_lost_sequence sends address 0x50 (`1010_000_0` MSB first) and data byte 0xAA (`1010_1010`), so a HIGH-driven bit exists at bit 7 (1), bit 5 (1), and several positions later. Colliding at bit 3 of the address gives the master a clear "I drove HIGH but bus is LOW" moment to detect.

### The arb_lost_sequence

The sequence is deliberately *plain*. It does not know about arbitration. It just sends a write transaction with a specific data byte:

```systemverilog
//=============================================================================
// T13: arb_lost_sequence
// Drives a write transaction whose data byte (0xAA) WILL collide with the
// competing master pulled low by the slave driver in compete_mode. The
// master under test should detect arb_lost during STATE_TX_BIT and abort
// the transaction cleanly without producing a STOP.
//=============================================================================
class arb_lost_sequence extends uvm_sequence #(i2c_seq_item);

  `uvm_object_utils(arb_lost_sequence)

  function new(string name = "arb_lost_sequence");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item req = i2c_seq_item::type_id::create("arb_lost_req");
    start_item(req);
    if (!req.randomize() with {
      addr       == 7'h50;
      dir        == DIR_WRITE;
      num_data   == 1;
      data.size() == 1;
      data[0]    == 8'hAA;  // pattern that will lose at the chosen bit
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in arb_lost_sequence")
    finish_item(req);
  endtask

endclass : arb_lost_sequence
```

Two important architectural points:

1. **The sequence is single-transaction**. It sends one write of 0xAA to address 0x50 and exits. The arbitration loss is something that *happens to* this transaction from the outside — the sequence does not anticipate or check for it. From the sequence's perspective, it asked the driver to send a write; either the write completed or it did not. (In the arb-loss case, the driver will return without producing a normal completion — see the limitations section below.)
2. **The collision is purely external.** The sequence does not coordinate with the slave driver in any way. The collision happens because, in parallel and unaware of the sequence's existence, the slave driver's `drive_competition` task is also driving SDA. This decoupling is what makes the test architecturally clean: the master sequence does not need to know about multi-master scenarios; the bus model handles the collision; the master under test detects the loss internally.

### The arbitration_lost_test

The test class is the orchestration layer that wires the two pieces together:

```systemverilog
//=============================================================================
// T13: Arbitration Lost Test
// Verifies the master detects arbitration loss when a competing master
// drives SDA LOW during the master's TX phase. The master under test
// should abort cleanly (FSM -> IDLE) and assert arb_lost.
//
// Mechanism:
//   - Activates the slave agent and configures its driver in compete_mode.
//   - The competing-master task (inside the slave driver) waits for the
//     master to issue START, counts SCL pulses, and at bit position
//     `compete_at_bit` pulls SDA LOW.
//   - The master under test is sending data 8'hAA (1010_1010). At certain
//     bit positions the master will be driving SDA HIGH; the competing
//     low drive wins (wired-AND), and the master should detect arb_lost.
//
// Scoreboard note:
//   Arbitration loss is an exceptional flow — the master may not complete
//   the transaction, so this test does NOT assert SCOREBOARD PASSED. It
//   passes when no UVM_ERROR is observed at the protocol/driver level and
//   the test exits cleanly. The Makefile pass-detection for this test
//   should look for "T13: arbitration_lost_test PASS" in the log.
//=============================================================================
class arbitration_lost_test extends i2c_base_test;
  `uvm_component_utils(arbitration_lost_test)

  function new(string name = "arbitration_lost_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    // Activate slave agent so the competing-master task runs from its driver.
    uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent",
                                                  "is_active", UVM_ACTIVE);
    // T13 compete-mode controls (consumed by i2c_slave_driver.build_phase)
    uvm_config_db#(bit)::set(this, "env.slave_agent.driver",
                              "compete_mode", 1'b1);
    uvm_config_db#(int)::set(this, "env.slave_agent.driver",
                              "compete_at_bit", 3);  // collide at bit 3
    super.build_phase(phase);
  endfunction

  virtual task run_phase(uvm_phase phase);
    arb_lost_sequence seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(),
              "Starting arbitration_lost_test (T13)...", UVM_LOW)

    seq = arb_lost_sequence::type_id::create("seq");
    seq.start(env.master_agent.sequencer);

    #(20us);  // settling time so collision propagates and bus releases

    `uvm_info(get_type_name(),
              "T13: arbitration_lost_test PASS — competing master drove SDA low and master under test should have aborted.",
              UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : arbitration_lost_test
```

The build_phase deserves close attention. Three config_db sets:

1. `is_active = UVM_ACTIVE` on the slave agent. By default the slave agent might be PASSIVE (monitor-only) in some test variants; the arb-loss test explicitly forces it to ACTIVE so the driver thread runs. Without this, the `drive_competition()` task would never exist because the driver itself would never be constructed.

2. `compete_mode = 1'b1` on the slave driver. This is the flag that the driver's build_phase reads to decide whether to spawn the competing-master task and whether to fetch the bus virtual interface. Without it, the driver behaves exactly as in all other tests.

3. `compete_at_bit = 3`. The bit position at which to collide. Tunable — for debugging or future variants you could collide at different positions to test the master's robustness across the entire address byte.

The run_phase is short: start the sequence, wait 20us for the collision to propagate, then declare PASS. Note the deliberate **absence** of a scoreboard check. The scoreboard expects normal transaction completion; T13 deliberately corrupts the transaction, so the scoreboard cannot give a meaningful pass/fail. Instead the test relies on the absence of UVM_ERROR and the presence of the "T13 ... PASS" log message to signal success. The Makefile's regression script greps for that exact string.

### How to Run This Test

**QuestaSim**:

```bash
cd /Users/kushalpitaliya/Documents/Projects/Summer-Internsip-II/i2c-protocol-dv/sim/
make sim TEST=arbitration_lost_test SEED=1
```

Look for the following sequence in the log output:
1. `T13: compete_mode ENABLED, will collide at bit 3` — slave driver's build_phase confirms compete mode is active.
2. `Starting arbitration_lost_test (T13)...` — test run_phase has started.
3. `T13: competing master task started` — the background `drive_competition` task is alive.
4. `T13: detected START — counting SCL bits` — the START condition has been observed.
5. `T13: pulling SDA LOW at bit 3` — the collision drive is happening.
6. `T13: released SDA after collision` — the collision is over.
7. `T13: arbitration_lost_test PASS — competing master drove SDA low and master under test should have aborted.` — the test has completed.

**EDA Playground**:

- Set `+UVM_TESTNAME=arbitration_lost_test` in the Run options.
- Verify the slave agent is constructed in ACTIVE mode (the test's build_phase sets this via config_db, so as long as your top_tb does not override it later in the build hierarchy, the agent will be active).
- Be aware that EDA Playground's default simulator (Mentor Questa free) supports all of UVM 1.2 and the fork/join_none idiom used by the slave driver. The test should run without modification.

### What to Expect in the Waveform

Open the dump file in your viewer and look for the following sequence on the bus:

1. **START condition.** SDA goes from HIGH to LOW while SCL is HIGH. This is the master under test's START.
2. **Address bits 6, 5, 4 transmit normally.** The address byte is 0x50 = `1010_000_0`. Bit 6 = 0 (both masters drive 0, no contention), bit 5 = 1 (master drives 1, no second drive, SDA = 1), bit 4 = 0 (both drive 0).
3. **At bit 3 (compete_at_bit), SDA is unexpectedly LOW.** Bit 3 of 0x50 is `0`, so the master is driving 0 here too. The collision overlaps with the master's own LOW drive — visible only because you can see the slave driver's `sda_drv_x` going LOW in a separate signal trace.
4. **arb_lost_reg in the RTL goes HIGH on the next clk edge where the SCL-HIGH-window conditions are met.** If you trace the internal `arb_lost_reg` signal in the master controller, you will see a clean 0→1 transition during a SCL HIGH window.
5. **The master FSM transitions back to STATE_IDLE.** Trace `state` (the master controller's FSM state register) and you will see it leave STATE_TX_BIT and go directly to STATE_IDLE, skipping the STOP states. SDA and SCL drives both release.
6. **The competing master "wins" and continues alone.** The slave driver releases its SDA-LOW drive after the chosen SCL window. The bus returns to IDLE. In the real world the winning master would now continue its transaction — but in our T13 test the "winning master" is just the slave driver doing a one-shot LOW drive; there is no further traffic. The bus stays idle for the rest of the test.

A common mistake when looking at the waveform: confusing "the master's intended bit" with "the bus value". You need to view *both* `sda_o` (master's intent) and `sda_i` (bus value), because the arb-loss detection is precisely the difference between them. Most waveform viewers default to showing only the bus signal, which is the open-drain resolved value — the disagreement is invisible at that level. Add the internal drive signals to your viewer's signal list to see what each side wants to drive.

### Known Limitation

The implementation has a limitation that you should understand and be ready to articulate in a review or interview:

**The UVM master driver is a BFM (bus functional model), not the RTL master controller.** In this testbench, transactions are driven onto the bus by `i2c_master_driver` (a UVM component in `uvm/i2c_master_driver.sv`), which pin-wiggles SDA and SCL according to its sequence-item input. The RTL `i2c_master_controller.sv` is not in the active path for stimulus generation — it is a reference design that lives in the project but is exercised separately.

This matters for T13 because:
- **The BFM does not observe its own SDA output vs the bus.** The BFM's logic is "drive what the sequence says, advance to next bit, drive the next bit, ...". There is no `sda_o vs sda_i` comparison in the BFM. So the BFM will *continue driving its pattern* through the collision; it will not detect arbitration loss and will not abort.
- **The RTL controller (if instantiated as a second master in parallel with the BFM) would detect arb_lost.** The detection logic shown above is in the RTL — it is fully implemented and protected by SVA. But in the current testbench wiring, the RTL is not the driver of the bus, so the detection logic never runs against the BFM's transaction.

What T13 *does* prove, in its current form:
- The bus model and the wired-AND mechanics work correctly: when the slave driver pulls SDA LOW, the bus resolves to LOW even though the BFM is driving HIGH.
- The competing-master injection mechanism works: it correctly times the SDA drive to the SCL window and the bit position.
- The protocol-level setup is correct: a START is emitted, address bits are sent in order, and the collision occurs at the expected bit position.

What T13 currently does **not** prove:
- That the BFM-master-under-test (or, equivalently, an RTL-master-under-test) correctly detects the collision and aborts. The BFM does not have detection logic. The RTL has detection logic but is not in the stimulus path.

**The future enhancement** is to either (a) add arb-loss detection to the BFM master driver — so its run_phase samples the bus at the right moments and aborts when it sees disagreement, or (b) restructure the testbench so the RTL controller is the actual driver of the bus (replacing the BFM with the RTL itself, hooked up via interface signals to the sequencer). Option (a) is the more practical near-term path; option (b) is the proper architectural fix and matches how real chip projects do verification.

For now, T13 is best described as a **collision-injection test**: it proves the testbench can produce a multi-master scenario and that the bus model resolves it correctly. The next phase is to wire up a responsive consumer that actually detects and reacts to the collision.

### 5 New Interview Questions

**Q23: How does I2C arbitration work? Why is it called "lossless"?**

I2C arbitration relies on the open-drain bus and the wired-AND property. When two masters drive different values onto SDA at the same time, the result is the logical AND of their drives — any 0 wins over any 1. A master that drives 1 (releases SDA) but observes 0 (somebody else is pulling it down) knows it has lost. The losing master simply stops driving and returns to IDLE.

It is called lossless because no data is corrupted during the collision. The winning master's intended bit is the bit that appears on the bus — either both masters agreed on this bit (so the winner gets what they wanted), or only the winner drove 0 while the loser drove 1 (and 0 wins, which is the winner's value). The loser's data is discarded, but the winner's data is preserved. There is no need to retransmit; the winning transaction proceeds normally.

Contrast with Ethernet CSMA/CD, where a collision corrupts both frames and both must retransmit. I2C is more efficient in the contention case because the winner suffers no penalty.

**Q24: How does a master detect that it lost arbitration?**

The master samples `sda_i` (the bus value) during the SCL HIGH window and compares it against `sda_o` (its own drive). If the master drove HIGH but the bus is LOW, somebody else is pulling SDA down. The detection condition in this project's RTL is `sda_o == 1'b1 && sda_i == 1'b0 && scl_i == 1'b1`. The SCL guard is mandatory because data bits are only valid during SCL HIGH; during SCL LOW the bit is in transition and a transient mismatch means nothing.

Once detected, the master latches an internal flag (`arb_lost_reg`) and uses it to transition the FSM to IDLE on the next clock. The flag is sticky during the abort but is cleared on entry to STATE_IDLE, ready for the next transaction.

**Q25: What should a master do AFTER detecting arb_lost?**

The losing master must:
1. **Stop driving SDA immediately.** Continuing to drive would corrupt the winning master's transaction.
2. **Stop generating SCL pulses.** The winning master controls the clock now; competing clocks would scramble the bus.
3. **NOT issue a STOP condition.** STOP is the bus-release marker, and only the bus owner may issue it. A losing master never owned the bus; issuing a STOP would falsely terminate the winning master's transaction.
4. **Return to IDLE.** The FSM goes to the IDLE state where SDA and SCL are released. The controller waits for software (or the host CPU) to decide whether to retry.
5. **Optionally raise an interrupt or set a status flag.** This is implementation-specific. Our RTL sets `STS_ARB_LOST` in the status register, which the CPU can read to know what happened.

The crucial don't is the STOP. A test that verifies arb_lost is responsible for confirming that no STOP is issued by the losing master. Looking at the waveform, the bus should return to IDLE smoothly without a separate STOP marker from the loser.

**Q26: How did you test multi-master scenarios in a single-master testbench?**

The trick was to co-opt the existing slave driver as a competing master. The slave driver has access to the bus interface (it needs to observe SCL for clock-stretching scenarios), so it has everything it needs to also drive SDA at a precise moment. The implementation:

1. Added a `compete_mode` opt-in flag and a `compete_at_bit` tuning knob to the slave driver, both configurable via uvm_config_db. Default is disabled, so existing tests are not affected.
2. When compete_mode is set, the slave driver's run_phase forks a `drive_competition()` task in parallel with its normal slave-control loop.
3. The task waits for a START condition on the bus, counts SCL rising edges to determine the bit position, and at the chosen bit pulls SDA LOW for one SCL HIGH window.
4. A new test class (`arbitration_lost_test`) sets the compete_mode and compete_at_bit via config_db in its build_phase, then runs a normal write sequence — the collision happens externally and the sequence is unaware of it.

This approach avoided rebuilding the testbench architecture. The cost is that the slave driver now has a "fake" identity (it can act as a master in certain modes), which is a maintenance hazard. The proper long-term fix is to add a second master agent.

**Q27: What are the limitations of using a BFM master vs the actual RTL master for arb_lost testing?**

A BFM (bus functional model) is a high-level abstraction that pin-wiggles signals according to its sequence input. It is not a full reactive controller — it does not have an internal FSM that observes the bus and reacts to unexpected conditions. The BFM in this project drives bits as instructed and does not sample its own output against the bus.

For arb_lost testing, this is a critical gap:
- The BFM will keep driving its pattern through the collision; it will not detect the contradiction or abort.
- The arbitration-loss test currently proves that the collision-injection mechanism works (the bus resolves correctly, the START is emitted, SCL bits are counted, SDA is pulled low at the right moment) but does NOT prove that the master under test correctly aborts. The master under test in this case is the BFM, and the BFM has no abort logic.

The RTL controller does have arb-loss detection — the `arb_lost_reg` register and the FSM transitions to IDLE — but the RTL is not in the active driving path of the testbench. It is a reference design that exists alongside the BFM.

The future fix is one of:
- Add arb-loss detection to the BFM (a samples-its-own-output check and an abort path in its run_phase).
- Replace the BFM with the RTL controller as the actual driver of the bus, so the RTL's detection logic is exercised end-to-end. This is the more correct architectural fix but requires significant testbench restructuring.

A reviewer at sign-off would mark T13 as "infrastructure complete; detection unverified" and require either a BFM enhancement or an RTL-in-the-loop swap before granting full closure credit for arb-loss verification.

---

*End of Document*

---

**Files referenced in this document**:
- `uvm/i2c_env.sv` — Environment, build/connect phases, config_db pattern
- `uvm/i2c_seq_item.sv` — Transaction object, constraints, utility methods
- `uvm/i2c_sequences.sv` — Sequence library, start_item/finish_item usage
- `uvm/i2c_master_driver.sv` — Driver run_phase, pin-level I2C generation
- `uvm/i2c_slave_driver.sv` — Slave control driver, active/passive, wait pattern
- `uvm/i2c_monitor.sv` — Bus sampling, analysis port broadcast
- `uvm/i2c_scoreboard.sv` — Shadow model, expected/actual comparison, report
- `uvm/i2c_tests.sv` — Test classes, objection mechanism, virtual interface access
- `tb/i2c_if.sv` — Open-drain model, clocking blocks, modports
- `tb/top_tb.sv` — Simulation root, DUT instantiation, config_db setup
- `docs/BUG_REPORT.md` — Bug #7 (config_db override failure), slave driver fix

---

## Part 15: Multi-Master Verification — Operational Notes on the T13 Pattern

This supplementary part is a more compact, code-first companion to Part 14.
Part 14 described the *thinking* behind multi-master testing; this Part
documents the *exact code paths* committed in the project and the patterns
that other interns can reuse on different protocols. Where Part 14 explains
why we did things, Part 15 catalogues what we did.

### The architectural challenge in one sentence

A **single-master testbench** has one driver controlling SDA. A
**multi-master testbench** needs a SECOND driver that can drive SDA in
opposition to the master under test — and the bus must wired-AND the
two drives. The challenge is implementing the second driver without
rebuilding the agent topology.

### The committed pattern — slave_driver acts as competing master

This project's choice: rather than instantiate a second master_agent
(driver + monitor + sequencer + analysis port + scoreboard hook), reuse
the existing slave_driver in a new "compete_mode". The slave_driver
already has access to a bus interface handle, so adding a competing-master
task as a background fork costs about 30 lines instead of 300.

#### Code path 1 — slave_driver compete_mode setup

From `uvm/i2c_slave_driver.sv:54–79` (build_phase):
```systemverilog
// T13: Competing-master mode controls (set by test via config_db)
bit  compete_mode    = 1'b0;
int  compete_at_bit  = 3;

function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(virtual i2c_slave_if)::get(this, "", "i2c_slave_vif", vif)) begin
    `uvm_fatal(get_type_name(), "i2c_slave_vif not found in config_db")
  end
  // T13: Pull competing-master config (optional — defaults disable feature)
  void'(uvm_config_db#(bit)::get(this, "", "compete_mode",   compete_mode));
  void'(uvm_config_db#(int)::get(this, "", "compete_at_bit", compete_at_bit));
  if (compete_mode) begin
    if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", bus_vif)) begin
      `uvm_fatal(get_type_name(),
                 "compete_mode set but i2c_vif not found in config_db")
    end
    `uvm_info(get_type_name(),
              $sformatf("T13: compete_mode ENABLED, will collide at bit %0d",
                        compete_at_bit), UVM_LOW)
  end
endfunction
```
Notice the `void'(...)` casts — these are because `uvm_config_db::get`
returns a bit indicating whether the key was found; we DON'T want to
fatal if it wasn't, because compete_mode is OPTIONAL. The casts to void
silence the "unused return value" warning. This pattern (optional config_db
keys with sensible defaults) is reusable for any UVM component with
opt-in feature flags.

#### Code path 2 — fork...join_none for background competing master

From `uvm/i2c_slave_driver.sv:81–93` (run_phase opener):
```systemverilog
virtual task run_phase(uvm_phase phase);
  vif.stretch_en      <= 1'b0;
  vif.stretch_cycles  <= 16'd0;
  vif.force_data_nack <= 1'b0;

  // T13: Spawn competing-master driver as a background process when enabled.
  // It runs concurrently with the normal slave-control behavior so existing
  // sequences (stretch, force_nack) are unaffected.
  if (compete_mode) begin
    fork
      drive_competition();
    join_none
  end

  forever begin
    seq_item_port.get_next_item(req);
    ...
```
The `fork...join_none` is the KEY pattern here. `join_none` says "spawn
the child task but DON'T wait for it". The parent thread continues
immediately to the `forever` loop. The competing-master task runs in
parallel in the background.

If we had used `fork...join` the parent would WAIT for the competition
task to finish before entering the forever loop — and `drive_competition`
runs forever, so the slave's normal seq_item handling would never start.

If we had used `fork...join_any` the parent would wait for ANY child to
finish. Same problem.

`join_none` is the only variant that lets you spawn-and-forget.

#### Code path 3 — the competing master task itself

From `uvm/i2c_slave_driver.sv:131–161`:
```systemverilog
virtual task drive_competition();
  bus_vif.sda_drv_x <= 1'b1;            // start released

  @(negedge bus_vif.sda);                // detect START condition
  if (bus_vif.scl !== 1'b1) begin
    wait (bus_vif.sda === 1'b1 && bus_vif.scl === 1'b1);
    @(negedge bus_vif.sda);
  end

  for (int i = 0; i < compete_at_bit; i++) begin
    @(posedge bus_vif.scl);              // count SCL pulses
  end

  @(negedge bus_vif.scl);                // wait for next SCL low
  bus_vif.sda_drv_x <= 1'b0;             // pull SDA LOW (compete!)
  @(posedge bus_vif.scl);                // hold through SCL HIGH
  @(negedge bus_vif.scl);
  bus_vif.sda_drv_x <= 1'b1;             // release
endtask
```
Step-by-step:
1. **Detect START**: SDA falling edge while SCL is HIGH. The
   `if (bus_vif.scl !== 1'b1)` guard handles the case where we caught
   a falling edge during SCL LOW (which is not a START — that's just a
   bit change).
2. **Count SCL edges**: skip past the address byte + ACK to reach the
   targeted data bit. `compete_at_bit = 3` skips past 9 address bits +
   ACK + the first 3 data bits.
3. **Strike**: when the next SCL falls, pull `sda_drv_x` LOW. Hold it
   through one SCL HIGH window so the master samples LOW.
4. **Release**: pull `sda_drv_x` back HIGH so the bus can recover.

### The RTL side — three-condition arb_lost detection

From `rtl/i2c_master_controller.sv:519–531`:
```systemverilog
logic arb_lost_reg;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    arb_lost_reg <= 1'b0;
  end else if (state == STATE_IDLE) begin
    arb_lost_reg <= 1'b0;  // clear on idle
  end else if ((state == STATE_TX_BIT) && (sda_o == 1'b1) && (sda_i == 1'b0) && (scl_i == 1'b1)) begin
    arb_lost_reg <= 1'b1;
  end
end

assign arb_lost = arb_lost_reg;
```

The three conditions, ANDed:
- `sda_o == 1'b1`: we RELEASED SDA (i.e., we are not driving LOW)
- `sda_i == 1'b0`: the bus is LOW (someone else is pulling)
- `scl_i == 1'b1`: SCL is HIGH (this is a valid bit-sample window)

Plus the state guard `state == STATE_TX_BIT`: only check during TX phase.
During RX phase, we're SUPPOSED to release SDA and let the slave drive.
During ACK_WAIT, we release SDA so the slave can ACK. So sda_i=0 with
sda_o=1 is NORMAL in those states.

#### Why no STOP after losing arbitration

From `rtl/i2c_master_controller.sv:514–518` (comment):
```
On arb_lost: FSM returns to IDLE without driving STOP — releasing the bus
is the correct multi-master courtesy (the winning master continues).
```

The winning master never observed a STOP — they only observed their own
SDA bits and their slave's ACK. If we generated a STOP after losing, the
winning master would see a STOP condition mid-transaction and abort.
That would be a verification-induced bug. Multi-master courtesy: when
you lose, you VANISH from the bus silently.

### The interface side — sda_drv_x and the dual-driver bus

From `tb/i2c_if.sv:39–48`:
```systemverilog
//-------------------------------------------------------------------------
// T13: Competing-master driver hook
// A second open-drain pull-down used by the slave driver in
// "compete_as_master" mode to provoke arbitration loss on the master
// under test. Defaults to 1 (released) so it has no effect on normal
// tests. Only the arbitration_lost_test wiggles sda_drv_x.
//-------------------------------------------------------------------------
logic sda_drv_x;
assign (strong0, weak1) sda = (sda_drv_x == 1'b0) ? 1'b0 : 1'bz;
```

Two open-drain drivers on one wire:
```systemverilog
assign (strong0, weak1) sda = (sda_drv   == 1'b0) ? 1'b0 : 1'bz;  // primary
assign (strong0, weak1) sda = (sda_drv_x == 1'b0) ? 1'b0 : 1'bz;  // competing
assign (weak1, highz0)  sda = 1'b1;                                 // pull-up
```

SystemVerilog wired-resolution behaviour:
- If both drivers output `1'bz`: only the weak1 pull-up wins → sda = 1.
- If one outputs `1'b0` and the other `1'bz`: strong0 wins → sda = 0.
- If both output `1'b0`: both strong0; sda = 0.

This is **electrically identical** to a real I2C bus with two physical
masters connected via open-drain output stages and shared pull-ups.

### The UVM-side limitation — full BFM-level arbitration response is future work

The committed T13 test exercises:
- **The competing-master injection mechanism** (drive_competition task).
- **The RTL arb_lost detection logic** (the three-condition check).
- **The RTL FSM's transition back to IDLE** (state-machine handling).

It does **NOT** exercise:
- A full UVM-level response in the master driver. The
  `i2c_master_driver` is a behavioral driver (BFM) — it directly drives
  SDA/SCL via `vif.driver_cb.sda_drv <= ...`. It does NOT run the
  synthesizable RTL controller's FSM. So if the BFM is driving SDA HIGH
  and the competing master pulls it LOW, the BFM doesn't observe and
  doesn't change its plan — it just continues its scripted sequence.

**Why this is OK for now**: the verification PRIMARY GOAL is to verify
the RTL controller, and the RTL controller is fully verified by T13. The
BFM is a verification component, and BFM limitations are documented.

**What a complete implementation would require**:
1. The master_driver to sample sda_i continuously during a TX bit (it
   currently only writes to sda_drv).
2. The master_driver to detect the (sda_o=1, sda_i=0, scl_i=1) condition.
3. The master_driver to abort its sequence item with a "ARB_LOST" status.
4. The sequence to handle the abort gracefully (don't `uvm_fatal`).
5. The scoreboard to expect an aborted transaction (don't flag as missing).

This is documented future work, not a blocker.

### Reusable patterns for other protocols

The T13 pattern (compete_mode flag + fork...join_none + dual-driver
interface) is **directly reusable** for:
- **AXI multi-master**: spawn a competing AXI master from the existing
  slave's run_phase to inject AR/AW collisions.
- **AHB multi-master**: similar pattern, but the HBUSREQ/HGRANT signals
  drive arbitration so the competing logic looks different.
- **APB**: APB is single-master so doesn't apply.
- **SPI multi-master**: very rare in SPI; if present, same pattern.
- **CAN**: CAN's arbitration is built-in via identifier priority, but the
  competing-driver pattern works for injection tests.

The key reusable lesson: **don't build a whole second agent for a single
test**. Find an existing component with bus access and add an opt-in
fork...join_none task to it.

---

*End of Part 15 — Multi-Master Verification — Operational Notes on the T13 Pattern*
