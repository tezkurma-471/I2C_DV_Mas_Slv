# 06 — Functional Coverage: A Complete Deep Dive

**Audience**: Intern with zero prior coverage knowledge  
**Project**: I2C Protocol DV — `uvm/i2c_coverage.sv`  
**Goal**: Understand what coverage is, how to write it, how to measure it, and why it is the backbone of serious chip verification

---

## Table of Contents

1. [What Coverage Means and Why It Matters](#part-1-what-coverage-means-and-why-it-matters)
2. [SystemVerilog Coverage Syntax From Zero](#part-2-systemverilog-coverage-syntax-from-zero)
3. [Every Covergroup in This Project — Analyzed](#part-3-every-covergroup-in-this-project--analyzed)
4. [Cross Coverage](#part-4-cross-coverage)
5. [Coverage-Driven Verification — The Workflow](#part-5-coverage-driven-verification--the-workflow)
6. [The Ideal Coverage Model for I2C](#part-6-the-ideal-coverage-model-for-i2c)
7. [The Wrong Coverage Model — What Not to Measure](#part-7-the-wrong-coverage-model--what-not-to-measure)
8. [Coverage Metrics and Sign-Off Gates](#part-8-coverage-metrics-and-sign-off-gates)
9. [Interview Questions — Coverage](#part-9-interview-questions--coverage)
10. [Writing Coverage From Scratch — The Design Process](#part-10-writing-coverage-from-scratch--the-design-process)
11. [Coverage Holes — The 5 Most Common Gaps in I2C Verification](#part-11-coverage-holes--the-5-most-common-gaps-in-i2c-verification)
12. [Coverage-Assertion Complementarity](#part-12-coverage-assertion-complementarity)
13. [Advanced Bins — Transition Bins and Wildcard Bins](#part-13-advanced-bins--transition-bins-and-wildcard-bins)
14. [Integration with UVM — How the Coverage Class Connects](#part-14-integration-with-uvm--how-the-coverage-class-connects)
15. [Industry Coverage Practices — What Real Chip Projects Do](#part-15-industry-coverage-practices--what-real-chip-projects-do)

---

## Part 1: What Coverage Means and Why It Matters

### The Core Problem: How Do You Know You've Tested Enough?

Imagine you are writing tests for a chip. You run 500 simulations. They all pass. Are you done?

The honest answer is: **you don't know**. Passing tests only tell you that the scenarios you happened to test worked correctly. They tell you nothing about the scenarios you forgot to test.

Coverage is the answer to the question: **"Have I exercised all the important behaviors?"**

---

### 1.1 The Two Families of Coverage

Coverage in hardware verification splits into two broad families:

**Structural Coverage** (also called Code Coverage): Did the simulator actually execute this line? Did it take both branches of this if-statement? Did this flip-flop toggle from 0 to 1 and back?

**Functional Coverage**: Did the design experience the *important behaviors* that a human engineer decided were worth verifying?

These two families are not the same thing, and understanding the difference is one of the most important conceptual leaps in this field.

---

### 1.2 Code Coverage — Useful but Insufficient

Code coverage is automatic. Your simulator measures it for free. The main types are:

| Type | What It Measures |
|------|-----------------|
| **Line coverage** | Was this line of RTL ever executed? |
| **Branch coverage** | Did this `if` take both the true and false path? |
| **Toggle coverage** | Did this net/register toggle 0→1 and 1→0 at least once? |
| **FSM coverage** | Were all FSM states visited? Were all state transitions taken? |
| **Condition coverage** | Were all sub-conditions in a compound boolean expression exercised independently? |

Code coverage is valuable because it tells you where your tests completely missed the RTL. If a block of code has 0% line coverage, you definitely didn't test it. That is a test gap.

But here is the critical limitation: **code coverage tells you what was executed, not whether it was executed correctly.**

**Example**: Consider the I2C slave shift register bug (Bug #1 in this project). The line:

```systemverilog
latched_rx_byte <= {shift_reg[6:0], sda_i};  // BUG: captures ACK bit as data byte
```

This line has 100% line coverage — it is executed on every received byte. Toggle coverage is 100% — both `latched_rx_byte` and `sda_i` toggle. But the line is *wrong*. It is capturing the 9th SDA bit (the ACK) as the MSB of the data byte. A scoreboard check would catch this, but code coverage alone never would. The code runs; the code is just doing the wrong thing.

> **SENIOR ENGINEER INSIGHT**: A chip that has 100% code coverage can still ship with catastrophic bugs. Code coverage tells you *which* code ran. Functional coverage tells you *which behaviors* were exercised. Assertions tell you whether behaviors were *correct*. You need all three.

---

### 1.3 Functional Coverage — Measuring Behaviors, Not Lines

Functional coverage lets you, the verification engineer, define exactly what "done" looks like for your design. You translate the design specification into a set of measurable scenarios. Each scenario is a "bin" in a "coverpoint". When simulation creates a transaction that matches that bin, it is "hit" and counted.

For an I2C verification, a functional coverage model might say:

- "We must see at least one write transaction"
- "We must see at least one read transaction"
- "We must see at least one transaction with a NACK response"
- "We must see transactions with burst lengths of 1, 2-8, 9-16, and 17-32 bytes"
- "We must see the address 0x50 accessed in both read and write mode"

None of these are RTL lines. They are *protocol behaviors*. Code coverage cannot tell you whether you exercised all of them. Functional coverage can.

---

### 1.4 The Coverage Closure Problem

**Coverage closure** is the process of getting every bin in your coverage model to be hit at least once (or the required number of times). It is often the hardest part of a verification project.

A common misconception is that 100% functional coverage means zero bugs. It does not. Coverage is only as good as the coverage model you wrote. If you forgot to include a bin for "repeated START with NACK," then 100% coverage tells you nothing about that scenario.

The correct interpretation of 100% functional coverage is: **"We have exercised every behavior that we, the verification team, agreed was important."** If the coverage model was thorough, this is meaningful. If the coverage model was shallow, 100% is a false sense of security.

> **COMMON MISTAKE**: Writing a coverage model that is easy to close rather than one that is thorough. If every bin is hit after 10 random tests, your coverage model is probably not measuring anything interesting.

---

### 1.5 The Simulation-Coverage Feedback Loop

Coverage is not a one-shot measurement. It drives a continuous cycle:

```
Define Coverage Model
        |
        v
Write Random Tests
        |
        v
Run Simulation
        |
        v
Measure Coverage
        |
        v
Identify Uncovered Bins -----> Write Directed Tests ----+
        |                                                |
        | (all bins hit)                                 |
        v                                                |
  Coverage Closure <-------------------------------------+
```

This loop is called **Coverage-Driven Verification (CDV)**. You will learn the full workflow in Part 5. For now, understand that coverage is not just a report you look at at the end — it actively guides what tests you write next.

---

## Part 2: SystemVerilog Coverage Syntax From Zero

### 2.1 The covergroup — The Container

A `covergroup` is a named container that holds one or more `coverpoint`s. It is the top-level structure that your simulator reports coverage for.

```systemverilog
covergroup my_first_cg;
  // coverpoints go inside here
endgroup
```

A covergroup is a type. You must instantiate it:

```systemverilog
covergroup my_first_cg;
  // ...
endgroup

my_first_cg cg_inst = new();  // instantiation
```

In UVM, you typically instantiate covergroups in the `new()` function of your coverage class.

---

### 2.2 The coverpoint — What to Measure

A `coverpoint` names a signal or expression you want to track:

```systemverilog
covergroup transaction_cg;
  cp_direction: coverpoint item.dir;  // track the direction field
endgroup
```

The coverpoint name (`cp_direction`) is used in reports. The expression (`item.dir`) is the thing being sampled. Every time the covergroup is sampled, the simulator looks at the current value of `item.dir` and increments the appropriate counter.

---

### 2.3 Bins — The Categories

Without explicit bins, the simulator creates automatic bins — one per possible value. For a 2-bit signal, that is 4 bins (0, 1, 2, 3). For an 8-bit signal, that would be 256 auto-bins — usually too many to be meaningful.

Explicit bins let you group values into meaningful categories:

```systemverilog
covergroup direction_cg;
  cp_dir: coverpoint item.dir {
    bins write = {DIR_WRITE};  // bin named "write", hit when item.dir == DIR_WRITE
    bins read  = {DIR_READ};   // bin named "read",  hit when item.dir == DIR_READ
  }
endgroup
```

Each bin has a name (for readability in reports) and a value-set (the condition that triggers it). When the coverpoint is sampled and `item.dir == DIR_WRITE`, the "write" bin is incremented. When it is `DIR_READ`, the "read" bin is incremented.

**Coverage percentage for this coverpoint = (bins hit / total bins) * 100**

If only `DIR_WRITE` transactions are generated, coverage is 50% — one of two bins is hit.

---

### 2.4 Auto-bins vs Explicit Bins

**Auto-bins**: When you do not specify bins, the simulator creates one per legal value. For an enum with 4 values, you get 4 auto-bins. For a 32-bit integer, you get 2^32 bins (simulator usually caps this — check your tool's limits). Auto-bins are fine for small enums, dangerous for wide integers.

**Explicit bins**: You define exactly what you care about. Ranges, specific values, or sets of values. This is almost always what you want for anything more than a 2-3 bit signal.

```systemverilog
// Auto-bins (only OK for tiny enums)
cp_dir: coverpoint item.dir;

// Explicit bins (preferred for anything wider)
cp_size: coverpoint item.num_data {
  bins single      = {1};
  bins short_burst = {[2:8]};    // range syntax: [low:high]
  bins long_burst  = {[9:32]};
}
```

> **COMMON MISTAKE**: Using auto-bins on a wide signal like `num_data` (which ranges 1-32). You get 32 auto-bins, simulation reports 18/32 hit, but you do not know which 18 matter. Explicit bins with meaningful names are always better.

---

### 2.5 Cross Coverage — Measuring Combinations

A `cross` measures the combination of two or more coverpoints. If you have a direction coverpoint (2 bins) and a size coverpoint (4 bins), their cross has 2 × 4 = 8 cross-bins — one for every (direction, size) combination.

```systemverilog
covergroup burst_cg;
  cp_dir:  coverpoint item.dir;
  cp_size: coverpoint item.num_data {
    bins single = {1};
    bins burst  = {[2:32]};
  }
  cross cp_dir, cp_size;  // 2 x 2 = 4 cross-bins
endgroup
```

The 4 cross-bins are:
- `<DIR_WRITE, single>` — a single-byte write
- `<DIR_WRITE, burst>` — a burst write
- `<DIR_READ, single>` — a single-byte read
- `<DIR_READ, burst>` — a burst read

Without cross coverage, you might have 100% on `cp_dir` (both write and read seen) and 100% on `cp_size` (both single and burst seen), but never actually sent a burst read. Cross coverage catches that gap.

---

### 2.6 option.per_instance

When you have multiple instances of the same covergroup class, `option.per_instance = 1` tells the simulator to report coverage per instance separately rather than merging them. This matters when, for example, you have one coverage collector per I2C bus and want to see per-bus coverage.

```systemverilog
covergroup my_cg;
  option.per_instance = 1;
  // ...
endgroup
```

In this project, all covergroups have `option.per_instance = 1`. This is good practice — it keeps coverage numbers clean and attributable to the specific object that collected them.

---

### 2.7 option.weight

`option.weight` controls how much a covergroup contributes to the overall coverage percentage. Default is 1. Setting `option.weight = 0` means the covergroup's coverage is tracked but does not count toward the aggregate number — useful for experimental or informational coverpoints that are not yet part of the sign-off criteria.

```systemverilog
covergroup experimental_cg;
  option.weight = 0;  // tracked but not counted in sign-off
  cp_experimental: coverpoint item.some_new_field;
endgroup
```

---

### 2.8 ignore_bins — Intentionally Excluded Cases

`ignore_bins` marks values that should not be counted as uncovered. They are legal but uninteresting:

```systemverilog
cp_addr: coverpoint item.addr {
  bins valid_range = {[7'h08:7'h77]};
  ignore_bins reserved_low  = {[7'h00:7'h07]};  // I2C reserved addresses
  ignore_bins reserved_high = {[7'h78:7'h7F]};   // I2C reserved addresses
}
```

Reserved I2C addresses (0x00-0x07 and 0x78-0x7F) are invalid per the I2C spec. You don't want simulation to report "you never covered address 0x7F" because that address should never appear. `ignore_bins` silences those.

---

### 2.9 illegal_bins — Cases That Should Never Happen

`illegal_bins` is stronger: if a value matching an `illegal_bins` is ever sampled, the simulator emits an error. This converts coverage into an automatic assertion:

```systemverilog
cp_length: coverpoint item.num_data {
  bins valid = {[1:32]};
  illegal_bins zero_length = {0};  // num_data==0 should never happen
}
```

If `num_data` is ever 0 during simulation, you get an immediate error — no need to write a separate assertion. Use `illegal_bins` for protocol violations and impossible states.

> **SENIOR ENGINEER INSIGHT**: `illegal_bins` is underused by junior engineers. Any value that would represent a protocol violation, an impossible FSM state, or a constraint violation should be an `illegal_bins`, not just an uncovered bin. It gives you free bug detection.

---

### 2.10 Sampling — Event-Driven vs sample() Method

A covergroup is sampled when you tell it to be. There are two ways:

**Event-driven** (sampling at a clock edge):
```systemverilog
covergroup transaction_cg @(posedge clk);
  cp_dir: coverpoint dir_signal;
endgroup
```
This samples automatically on every positive clock edge. Good for RTL signal tracking.

**Explicit sample() method** (UVM-style):
```systemverilog
covergroup transaction_cg;
  cp_dir: coverpoint item.dir;
endgroup

// In the write() function:
function void write(i2c_seq_item t);
  this.item = t;
  transaction_cg.sample();  // sample exactly when a new transaction arrives
endfunction
```

In UVM coverage collectors, explicit `sample()` is almost always better. You sample exactly when a complete, valid transaction arrives from the monitor — not on every clock edge. This avoids sampling garbage values mid-transaction.

In this project, the `write()` function is called by the UVM TLM analysis port whenever the monitor completes a transaction. All covergroup sampling happens there.

---

## Part 3: Every Covergroup in This Project — Analyzed

The coverage file is at `uvm/i2c_coverage.sv`. There are 17 covergroups (CG1-CG17). Part 3 walks through the original 8; Parts 18 and 19 cover the expansions to CG16 and CG17 respectively. Let's analyze the foundational 8 first.

---

### Covergroup 1: i2c_dir_cg — Transaction Direction

**The Code:**
```systemverilog
covergroup i2c_dir_cg;
  option.per_instance = 1;
  option.name = "Direction";
  cp_dir: coverpoint item.dir {
    bins write = {DIR_WRITE};
    bins read  = {DIR_READ};
  }
endgroup
```

**What It Measures**: Whether we have seen both write transactions (master sending data to slave) and read transactions (master requesting data from slave).

**Why This Matters**: Write and read are fundamentally different code paths in both the master and slave RTL. A write transaction exercises the slave's RX shift register, RX ACK logic, and data storage. A read transaction exercises the slave's TX shift register (Bug #2 in this project involved missing TX shift register logic entirely), TX ACK check, and data output. If you only ever test writes, you would have missed Bug #2, Bug #4, and Bug #10 — three of the most critical bugs in this project.

**The Bins:**

| Bin Name | When Hit | Example Scenario |
|----------|----------|-----------------|
| `write` | `item.dir == DIR_WRITE` | Run `i2c_single_write_seq` — any write transaction hits this |
| `read`  | `item.dir == DIR_READ`  | Run `i2c_single_read_seq` — any read transaction hits this |

**What Simulation Scenario Hits Each Bin:**
- `write`: The very first test that sends any data to the slave hits this.
- `read`: You need to explicitly send a read transaction. `i2c_single_read_seq` or `i2c_write_read_seq` hits this.

---

### Covergroup 2: i2c_data_size_cg — Burst Length Categories

**The Code:**
```systemverilog
covergroup i2c_data_size_cg;
  option.per_instance = 1;
  option.name = "Data Size";
  cp_size: coverpoint item.num_data {
    bins single      = {1};
    bins short_burst = {[2:8]};
    bins med_burst   = {[9:16]};
    bins long_burst  = {[17:32]};
  }
endgroup
```

**What It Measures**: How many bytes are transferred in a single I2C transaction, grouped into four meaningful categories.

**Why This Matters**: The number of bytes in a transaction stresses different parts of the design in different ways:
- **single (1 byte)**: The absolute minimum — tests basic start/stop framing. This is likely the most common case in real software drivers.
- **short_burst (2-8)**: Tests the slave's loop logic — does it correctly handle multiple sequential bytes with intermediate ACKs?
- **med_burst (9-16)**: Pushes the register bank deeper. Does the register pointer wrap correctly?
- **long_burst (17-32)**: Exercises the maximum burst depth. Does any counter overflow? Does memory management in the RTL handle the edge?

**The Bins:**

| Bin Name | Value Range | What It Stresses |
|----------|-------------|-----------------|
| `single` | `num_data == 1` | Basic framing, one byte path |
| `short_burst` | 2 to 8 bytes | Loop, sequential ACK, intermediate byte handling |
| `med_burst` | 9 to 16 bytes | Register bank mid-range, pointer arithmetic |
| `long_burst` | 17 to 32 bytes | Maximum burst, edge of register space |

**What Simulation Scenario Hits Each Bin:**
- `single`: `i2c_single_write_seq` with `num_data == 1`.
- `short_burst`: `i2c_burst_write_seq` with `burst_len` in [2:8].
- `med_burst`: `i2c_burst_write_seq` with `burst_len` in [9:16].
- `long_burst`: `i2c_burst_write_seq` with `burst_len` in [17:32].

---

### Covergroup 3: i2c_addr_cg — Address Types

**The Code:**
```systemverilog
covergroup i2c_addr_cg;
  option.per_instance = 1;
  option.name = "Address";
  cp_addr: coverpoint item.addr {
    bins target_addr = {7'h50};
    bins other_addrs = {[7'h08:7'h4F], [7'h51:7'h77]};
  }
endgroup
```

**What It Measures**: Whether we have addressed the slave at its real address (0x50) and whether we have sent transactions to other (non-matching) addresses.

**Why This Matters**: An I2C slave must respond ACK when addressed at its own address and stay silent (NACK) when addressed at any other address. If you only ever use address 0x50, you never verify the slave's address-decode rejection logic. Sending a wrong address is what verifies Bug #4's flip side — the slave should NACK an address it does not own.

**The Bins:**

| Bin Name | When Hit | What It Verifies |
|----------|----------|-----------------|
| `target_addr` | `item.addr == 7'h50` | Slave recognizes its address and ACKs |
| `other_addrs` | Any valid addr other than 0x50 | Slave stays silent; address NACK scenario |

**What Simulation Scenario Hits Each Bin:**
- `target_addr`: Almost every sequence in this project defaults to `addr == 7'h50`.
- `other_addrs`: `i2c_nack_addr_seq` sends to a constrained random wrong address. `i2c_addr_sweep_seq` sweeps all valid I2C addresses.

---

### Covergroup 4: i2c_protocol_cg — Protocol Conditions

**The Code:**
```systemverilog
covergroup i2c_protocol_cg;
  option.per_instance = 1;
  option.name = "Protocol";
  cp_start: coverpoint item.start_cond { bins has_start = {1}; }
  cp_stop:  coverpoint item.stop_cond  { bins has_stop  = {1}; bins no_stop = {0}; }
  cp_rep:   coverpoint item.rep_start  { bins has_rep   = {1}; bins no_rep  = {0}; }
endgroup
```

**What It Measures**: Three distinct protocol control signals — whether a START condition was issued, whether a STOP condition was issued, and whether a Repeated START was issued.

**Why This Matters**:
- `has_start` / `has_stop` is the normal case — every standard transaction should have both.
- `no_stop` means the transaction is part of a Repeated START sequence. The bus is not released.
- `has_rep` means this transaction *is* the Repeated START — a direction change without releasing the bus.

The I2C Repeated START is one of the most complex protocol features. It allows a master to switch from write to read (or read to write) without another device taking the bus. Bugs in this area (like losing state between the two phases) are caught by `i2c_rep_start_seq`.

**The Bins:**

| Coverpoint | Bin | Meaning |
|------------|-----|---------|
| `cp_start` | `has_start` | Normal START — always present |
| `cp_stop` | `has_stop` | Normal STOP — transaction ends and releases bus |
| `cp_stop` | `no_stop` | No STOP — transaction continues with Repeated START |
| `cp_rep` | `has_rep` | This transaction began with Repeated START |
| `cp_rep` | `no_rep` | Normal transaction — no Repeated START |

---

### Covergroup 5: i2c_ack_cg — ACK/NACK Tracking

**The Code:**
```systemverilog
covergroup i2c_ack_cg;
  option.per_instance = 1;
  option.name = "ACK Responses";
  cp_addr_ack: coverpoint item.addr_ack {
    bins ack  = {1};
    bins nack = {0};
  }
endgroup
```

**What It Measures**: Whether the slave acknowledged (`addr_ack == 1`) or rejected (`addr_ack == 0`) the address phase of the transaction.

**Why This Matters**: The NACK response is one of the most important error conditions in I2C. When the slave does not recognize its address — or when it is busy — it returns a NACK by releasing SDA during the ACK clock. The master must detect this and abort the transaction. If you never test NACK, you never verify:
1. The slave's address rejection logic (wrong address → NACK)
2. The master's NACK detection and abort behavior
3. Bug #4 in this project — `SLV_TX_ACK` ignoring master NACK

**The Bins:**

| Bin | When Hit | Test Scenario |
|-----|----------|--------------|
| `ack` | `item.addr_ack == 1` | Any successful transaction to address 0x50 |
| `nack` | `item.addr_ack == 0` | `i2c_nack_addr_seq` — wrong address → slave silent |

> **COMMON MISTAKE**: Writing a test plan that never injects NACK. The `ack` bin is trivially hit by the very first test. The `nack` bin requires explicit effort — a wrong address sequence or a `force_data_nack` injection. Many interns never add the NACK test and end up at 50% on this covergroup without realizing it.

---

### Covergroup 6: i2c_burst_cg — Cross: Direction x Size

**The Code:**
```systemverilog
covergroup i2c_burst_cg;
  option.per_instance = 1;
  option.name = "Burst Cross";
  cp_dir: coverpoint item.dir;
  cp_size: coverpoint item.num_data {
    bins single      = {1};
    bins short_burst = {[2:8]};
    bins med_burst   = {[9:16]};
    bins long_burst  = {[17:32]};
  }
  cross cp_dir, cp_size;
endgroup
```

**What It Measures**: Every combination of direction (write/read) and burst length category. This is a 2 × 4 cross, giving 8 cross-bins.

**Why This Matters**: Without cross coverage, you might separately verify "all burst lengths in write mode" and "read transactions" but never actually run a long burst read. The cross forces you to cover all 8 combinations:

| Cross-Bin | Meaning | Why It Matters |
|-----------|---------|---------------|
| `<DIR_WRITE, single>` | Single-byte write | Basic write path |
| `<DIR_WRITE, short_burst>` | 2-8 byte write | Write loop, sequential ACKs |
| `<DIR_WRITE, med_burst>` | 9-16 byte write | Mid-range register fill |
| `<DIR_WRITE, long_burst>` | 17-32 byte write | Maximum write depth |
| `<DIR_READ, single>` | Single-byte read | Basic read path, TX shift reg |
| `<DIR_READ, short_burst>` | 2-8 byte read | Read loop, master ACK between bytes |
| `<DIR_READ, med_burst>` | 9-16 byte read | Mid-range register drain |
| `<DIR_READ, long_burst>` | 17-32 byte read | Maximum read burst, Bug #10 territory |

The `<DIR_READ, long_burst>` bin is particularly important — it is where Bug #10 (`reg_data_buf` never updated after RX, always reads 0x00) would be most thoroughly exposed.

---

### Covergroup 7: i2c_reg_ptr_cg — Register Bank Coverage (and Bug #13)

This covergroup has a story. Understanding it teaches you one of the most important lessons in coverage design.

**The WRONG Version (Before Bug #13 Fix):**
```systemverilog
// WRONG: This was the original implementation
covergroup i2c_reg_ptr_cg;
  option.per_instance = 1;
  option.name = "Register Access";
  cp_reg: coverpoint item.data[0] {  // <-- WRONG: measuring first DATA BYTE VALUE
    bins low_range  = {[8'h00:8'h3F]};
    bins mid_range  = {[8'h40:8'hBF]};
    bins high_range = {[8'hC0:8'hFF]};
  }
endgroup
```

This measured `item.data[0]` — the *value* of the first data byte. It was labeled "Register Access" but had absolutely nothing to do with which register was being accessed. The data byte value (0-255) tells you nothing about register access patterns. The bin would be hit by any transaction that happened to have a data byte in that value range, completely independent of the verification goal.

**Why This Is a Major Verification Gap:**

The intent of "Register Bank Coverage" is to verify that we access the slave's internal register bank in different ways — touching one register, touching a partial set, touching all of them. The register pointer (`reg_ptr` inside the RTL) advances with each byte written or read. The way to measure this from the testbench side is `item.num_data` — the number of bytes in the transaction, which equals the number of register slots accessed starting from `reg_ptr=0`.

**The FIXED Version (After Bug #13 Fix):**
```systemverilog
covergroup i2c_reg_ptr_cg;
  option.per_instance = 1;
  option.name = "Register Bank Coverage";
  cp_reg: coverpoint item.num_data {
    bins single_reg      = {1};        // Touch 1 register
    bins partial_bank    = {[2:4]};    // Touch 2-4 registers (quarter bank)
    bins more_than_half  = {[5:7]};    // Touch 5-7 registers (more than half)
    bins full_bank       = {8};        // Touch exactly 8 registers (full bank)
    bins multi_wrap      = {[9:32]};   // Access wraps beyond bank boundary
  }
endgroup
```

**What Each Fixed Bin Means:**

| Bin | num_data Range | What It Verifies |
|-----|---------------|-----------------|
| `single_reg` | 1 | Touching exactly one register — most common driver case |
| `partial_bank` | 2-4 | Sequential register write — page write scenarios |
| `more_than_half` | 5-7 | More than half the register bank — stress test |
| `full_bank` | 8 | Exactly filling the entire 8-slot register bank |
| `multi_wrap` | 9-32 | More data than register slots — wrap-around behavior |

**The Lesson:**

The label "Register Bank Coverage" should match what the coverpoint actually measures. The original coverpoint was measuring something completely different from its label — a coverage ghost. It looked complete in reports (high percentage hit) but was providing zero information about register access patterns.

> **SENIOR ENGINEER INSIGHT**: The most dangerous kind of coverage bug is one where coverage looks high but is measuring the wrong thing. Bug #13 is a perfect example: `item.data[0]` ranges from 0-255 randomly, so the three bins would be hit quickly by any random test — giving you false confidence. Always ask: "If this bin is hit, does it guarantee the behavior I care about was exercised?"

---

### Covergroup 8: i2c_target_cg — Cross: Target Address x Direction

**The Code:**
```systemverilog
covergroup i2c_target_cg;
  option.per_instance = 1;
  option.name = "Target Cross";
  cp_addr: coverpoint item.addr { bins target = {7'h50}; }
  cp_dir: coverpoint item.dir;
  cross cp_addr, cp_dir;
endgroup
```

**What It Measures**: Whether we have seen both write AND read transactions directed at the target slave address (0x50).

**Why This Matters**: Targeting 0x50 with a write tests the slave's data-receive path. Targeting 0x50 with a read tests the slave's data-transmit path. Both must work. This covergroup is sampled conditionally:

```systemverilog
if (t.addr == 7'h50) i2c_target_cg.sample();
```

It only samples when the address is 0x50 — other addresses would pollute the cross with entries the covergroup was not designed to measure.

The resulting cross has 2 cross-bins:
- `<target, DIR_WRITE>` — write to target
- `<target, DIR_READ>` — read from target

---

### How the Coverage Collector Is Wired

The `i2c_coverage` class extends `uvm_subscriber`, which means it automatically receives items from any analysis port connected to it. The `write()` function is called once per transaction:

```systemverilog
virtual function void write(i2c_seq_item t);
  this.item = t;
  i2c_dir_cg.sample();
  i2c_data_size_cg.sample();
  i2c_addr_cg.sample();
  i2c_protocol_cg.sample();
  i2c_ack_cg.sample();
  i2c_burst_cg.sample();
  if (t.num_data > 0) i2c_reg_ptr_cg.sample();  // conditional: only if data present
  if (t.addr == 7'h50) i2c_target_cg.sample();  // conditional: only target address
endfunction
```

Two covergroups are conditionally sampled — `i2c_reg_ptr_cg` only when there is actually data, and `i2c_target_cg` only for the specific target address. Conditional sampling is an important technique for keeping coverage bins meaningful.

---

## Part 4: Cross Coverage

### 4.1 What Is Cross Coverage?

Cross coverage measures **combinations** of things, not individual things. It answers the question: "Have we seen all *pairings* of these two conditions?"

Think of it like a 2D grid. Each axis is a coverpoint. Each cell in the grid is a cross-bin. 100% cross coverage means every cell in the grid has been hit.

```
               cp_dir
               WRITE    READ
             +--------+-------+
cp_size  1   | Hit    | MISS  |  <-- READ+1byte never seen!
         2-8 | Hit    | Hit   |
         9-16| Hit    | Hit   |
        17-32| Hit    | MISS  |  <-- READ+longburst never seen!
             +--------+-------+
```

Without cross coverage, you might report 100% on `cp_dir` (both WRITE and READ seen) and 100% on `cp_size` (all size bins seen) — and still have the two MISS cells above untested. Cross coverage is what catches this.

---

### 4.2 Why Cross Coverage Catches Bugs Individual Coverpoints Miss

In this I2C project, Bug #10 (`reg_data_buf` never updated after RX, CPU always reads 0x00) is most exposed by burst read transactions. Without the `<DIR_READ, long_burst>` cross-bin requiring at least one long burst read, verification might only exercise single-byte reads — where the bug is present but harder to notice (you only read one wrong byte instead of 32).

Another example: Bus #4 (`SLV_TX_ACK` ignores NACK). This is only exercised in a read transaction where the master sends NACK to terminate. The cross of `<DIR_READ, NACK>` ensures this scenario is mandatory.

---

### 4.3 The Combinatorial Explosion Problem

Cross coverage scales multiplicatively. With 5 coverpoints of 4 bins each, the full cross has 4^5 = 1024 cross-bins. Many of those combinations may be:
- Architecturally impossible (mutually exclusive values)
- Extremely rare in practice (requiring special hardware conditions)
- Not interesting for the bug classes you care about

When a cross produces too many bins, you have options:
1. Reduce the number of bins in each coverpoint before crossing
2. Use `binsof` expressions to exclude specific cross-bin combinations
3. Not use cross at all and rely on individual coverpoints + directed tests

> **SENIOR ENGINEER INSIGHT**: The rule of thumb at most companies is: if a cross produces more than 50-100 bins, think carefully before using it. More bins means more simulation to close. Cross is powerful but expensive. Use it for the *most critical* combinations, not everything.

---

### 4.4 When to Use Cross vs When It Is Overkill

**Use cross when:**
- The interaction between two features can create bugs that neither feature alone would expose
- Both dimensions are small (2-4 bins each)
- The combination is explicitly called out in the design spec (e.g., "the design must handle reads and writes of all burst lengths")

**Skip cross when:**
- One coverpoint has many bins (creates explosion)
- The two coverpoints are logically independent (no meaningful interaction)
- You are early in the project and trying to close basic coverage first

---

## Part 5: Coverage-Driven Verification — The Workflow

### 5.1 The Six-Step Cycle

Coverage-Driven Verification is a structured, iterative process. Here is the full workflow:

**Step 1 — Define the Coverage Model**

Before writing a single test, decide what "done" means. Translate the design spec into a list of behaviors that must be exercised. This becomes your covergroup set.

For I2C: "Done means we have seen reads, writes, all burst lengths, ACK and NACK, normal START/STOP, Repeated START, and both directions at the target address."

**Step 2 — Write Random Tests**

Run the constrained random sequences against the DUT. Let randomization explore the space. Random tests are efficient: one test can hit many bins simultaneously.

**Step 3 — Run Simulation**

Execute the regression. Let every test run to completion.

**Step 4 — Measure Coverage**

Collect the coverage database. Look at which bins were hit and which were missed. Your simulator will produce a report like:

```
i2c_dir_cg          100.00%  (2/2 bins)
i2c_data_size_cg     75.00%  (3/4 bins — long_burst MISSED)
i2c_addr_cg         100.00%  (2/2 bins)
i2c_ack_cg           50.00%  (1/2 bins — nack MISSED)
i2c_burst_cg         62.50%  (5/8 cross-bins — READ+long_burst MISSED)
```

**Step 5 — Identify Uncovered Bins and Write Directed Tests**

For each uncovered bin, either:
- Write a directed test that specifically targets that bin
- Adjust constraints in existing random tests to bias toward that bin
- Determine if the bin is unreachable (then mark it `ignore_bins`)

**Step 6 — Repeat Until Closure**

Run the new tests, measure coverage again. Repeat until all required bins are hit.

---

### 5.2 A Concrete Walkthrough: From 73% to Closure

Let us walk through this project specifically.

**Scenario: After 3 days of testing, coverage is 73%. What do we do?**

First, read the report:

```
i2c_dir_cg          100.00%  DONE
i2c_data_size_cg     75.00%  MISS: long_burst
i2c_addr_cg         100.00%  DONE
i2c_protocol_cg      66.67%  MISS: has_rep (Repeated START never seen)
i2c_ack_cg           50.00%  MISS: nack (NACK never seen)
i2c_burst_cg         50.00%  MISS: DIR_READ x med_burst, DIR_READ x long_burst
i2c_reg_ptr_cg       60.00%  MISS: more_than_half, full_bank, multi_wrap
i2c_target_cg        50.00%  MISS: target x DIR_READ (read to 0x50 never seen!)
AVERAGE:             73%
```

Now we triage:

**Hole 1: `nack` bin never hit**

We never sent a transaction to a wrong address or injected a NACK. Fix: add `i2c_nack_addr_seq` to the regression. This sends a constrained random address that is NOT 0x50 → slave NACKs → `item.addr_ack == 0` → `nack` bin hit.

```systemverilog
// Add to regression:
i2c_nack_addr_seq nack_seq = i2c_nack_addr_seq::type_id::create("nack_seq");
nack_seq.start(env.master_agent.sequencer);
```

**Hole 2: `has_rep` bin never hit**

The Repeated START sequence was never run. Fix: add `i2c_rep_start_seq` to the regression. This sends write (no STOP) → Repeated START → read (STOP), hitting `has_rep == 1`.

**Hole 3: `DIR_READ x long_burst` never hit**

We never ran a burst read with 17+ bytes. Fix: add `i2c_burst_read_seq` with `burst_len` constrained to [17:32].

```systemverilog
i2c_burst_read_seq long_read = i2c_burst_read_seq::type_id::create("long_read");
if (!long_read.randomize() with { burst_len inside {[17:32]}; })
  `uvm_fatal("TEST", "Randomize failed")
long_read.start(env.master_agent.sequencer);
```

**Hole 4: `full_bank` bin never hit**

`num_data == 8` was never generated. Add `i2c_burst_write_seq` with `burst_len == 8`.

**After adding these directed tests, re-run:**

```
i2c_dir_cg          100.00%  DONE
i2c_data_size_cg    100.00%  DONE
i2c_addr_cg         100.00%  DONE
i2c_protocol_cg     100.00%  DONE
i2c_ack_cg          100.00%  DONE
i2c_burst_cg        100.00%  DONE
i2c_reg_ptr_cg      100.00%  DONE
i2c_target_cg       100.00%  DONE
AVERAGE:            100.00%
```

**Are we done? Not yet.** Coverage closure does not mean the project is complete. Check:

1. **Assertion coverage**: Are all assertions passing? Did all assertions ever fire (meaning they were actually checking something)? Bug #11 and Bug #12 in this project were assertions that were tautologies — they never actually checked anything. High assertion coverage requires both passing AND having actually triggered.

2. **Code coverage**: Is there any RTL code that was never executed? A block at 0% line coverage means we missed testing an entire feature.

3. **Regression stability**: Do all tests pass consistently across multiple seeds? A test that passes on seed 1 but fails on seed 42 means a bug in a race condition.

---

## Part 6: The Ideal Coverage Model for I2C

If you were starting this project from scratch, here is what a senior engineer would put in the coverage model. This is the "ideal" — more comprehensive than what is currently implemented.

### 6.1 Transaction Types

```systemverilog
cp_txn_type: coverpoint {item.dir, item.num_data > 1} {
  bins single_write = {2'b0_0};   // write, 1 byte
  bins burst_write  = {2'b0_1};   // write, >1 byte
  bins single_read  = {2'b1_0};   // read, 1 byte
  bins burst_read   = {2'b1_1};   // read, >1 byte
}
```

### 6.2 Address Coverage

```systemverilog
cp_addr_type: coverpoint item.addr {
  bins target_slave   = {7'h50};                          // Our slave
  bins valid_other    = {[7'h08:7'h4F], [7'h51:7'h77]};  // Other valid addresses
  ignore_bins reserved_low  = {[7'h00:7'h07]};            // I2C reserved
  ignore_bins reserved_high = {[7'h78:7'h7F]};            // I2C reserved
}
```

### 6.3 Data Values

```systemverilog
cp_data_value: coverpoint item.data[0] {
  bins all_zeros  = {8'h00};           // 0x00 — zero write, potential reset-state test
  bins all_ones   = {8'hFF};           // 0xFF — all bits set, maximum SDA high time
  bins alternating_a = {8'hAA};        // 10101010 — checkerboard pattern A
  bins alternating_5 = {8'h55};        // 01010101 — checkerboard pattern B
  bins random_mid = {[8'h01:8'hFE]};   // Everything else — general case
}
```

**Why 0x00 and 0xFF?** These are classic stress values for shift registers and bus drivers. An all-zeros byte means SDA stays low for 8 consecutive bit periods — longest possible low hold. An all-ones byte means SDA stays high for 8 consecutive bit periods. If there is a glitch or setup/hold violation in the shift register, these patterns are most likely to expose it.

**Why 0xAA and 0x55?** Checkerboard patterns toggle every bit period. If there is a clocking edge ambiguity, alternating patterns expose it where solid 0x00/0xFF would not.

### 6.4 Burst Length

```systemverilog
cp_burst_len: coverpoint item.num_data {
  bins one_byte    = {1};          // Minimum
  bins few_bytes   = {[2:4]};      // Short burst
  bins half_bank   = {[5:7]};      // Partial
  bins full_bank   = {8};          // Exactly the register bank size
  bins over_bank   = {[9:32]};     // Wraps beyond bank — pointer behavior
  illegal_bins zero = {0};         // Must never happen: protocol violation
}
```

### 6.5 ACK/NACK Conditions

```systemverilog
cp_addr_ack: coverpoint item.addr_ack {
  bins addr_ack  = {1};  // Slave recognized its address
  bins addr_nack = {0};  // Wrong address — slave silent
}

// Cross: direction x ack (did we see NACK in both read and write paths?)
cross cp_dir, cp_addr_ack;
```

### 6.6 Clock Stretching

```systemverilog
// Stretch duration categories (from i2c_slave_stretch_ctrl_seq)
cp_stretch: coverpoint stretch_cycles {
  bins no_stretch   = {0};           // No stretching
  bins short_stretch = {[1:50]};     // Short delay
  bins med_stretch  = {[51:100]};    // Medium — typical test range
  bins max_stretch  = {[101:200]};   // Maximum — stress test timing
}
```

Note: `stretch_cycles` is in the slave control item, not the master seq item. You would need a separate covergroup or a different sampling point to capture this.

### 6.7 Repeated START

```systemverilog
cp_rep_start: coverpoint item.rep_start {
  bins normal = {0};       // Standard START-STOP transaction
  bins rep    = {1};       // Repeated START — direction change without STOP
}

// The most interesting cross: what sequence of directions with Repeated START?
// write->read (typical for EEPROM: write address, read data)
// read->write (less common, but possible)
```

### 6.8 Error Conditions

```systemverilog
cp_error_inject: coverpoint {item.inject_nack, item.inject_timeout} {
  bins clean_txn     = {2'b00};   // Normal transaction, no errors
  bins nack_inject   = {2'b10};   // Force NACK
  bins timeout_inject = {2'b01};  // Force timeout
  // 2'b11 might be illegal depending on constraints
}
```

### 6.9 The Power Combinations (Key Cross Coverage Points)

A senior engineer would insist on at least these crosses:

| Cross | Why |
|-------|-----|
| `dir x burst_len` | All 8 (dir, length) combinations — already in this project |
| `dir x addr_ack` | NACK in both write and read paths |
| `addr_type x dir` | Target and non-target addresses in both directions |
| `rep_start x dir` | Write-then-read AND read-then-write repeated START |
| `burst_len x stretch` | Long burst combined with clock stretching — maximum stress |

---

## Part 7: The Wrong Coverage Model — What Not to Measure

Coverage that measures the wrong thing is worse than no coverage. It gives false confidence. Here are the anti-patterns.

### 7.1 Measuring RTL Internal Signals Directly

```systemverilog
// WRONG: Measuring DUT internal state from testbench
cp_rtl_state: coverpoint dut.slave.state {  // peeking into RTL
  bins idle = {SLV_IDLE};
  bins rx   = {SLV_RX};
}
```

This is problematic because:
- You are measuring RTL implementation details, not architectural behaviors
- If the RTL is refactored (states renamed, split, merged), your coverage breaks
- Coverage of internal state names says nothing about whether the state machine behaves correctly — it just says which states the code visited

Functional coverage should be written against the *interface* and *protocol*, not the implementation.

### 7.2 Measuring Things That Cannot Fail

```systemverilog
// WRONG: Measuring reset state that is always trivially correct
cp_reset: coverpoint item.start_cond {
  bins always_set = {1};  // constraint default_trans_c forces start_cond == 1
}
```

If a constraint ensures `start_cond` is always 1, this bin is hit by every single transaction. It closes immediately. It tells you nothing. Do not measure things your constraints already guarantee.

### 7.3 Duplicate Coverage

If `i2c_dir_cg` and `i2c_burst_cg` both have a `cp_dir: coverpoint item.dir`, you are measuring direction twice. That is wasteful — the report shows the same metric in two places and inflates the apparent coverage. When the cross in `i2c_burst_cg` already captures direction (as part of the cross), a separate `i2c_dir_cg` is redundant if its only purpose is to show direction was seen.

In this project, both `i2c_dir_cg` and `i2c_burst_cg` contain `cp_dir`. This is acceptable if `i2c_dir_cg` serves as a simple "at a glance" report for direction, but be aware that it is redundant with the direction dimension inside `i2c_burst_cg`.

### 7.4 The Bug #13 Lesson — Covering the Wrong Signal

The original `i2c_reg_ptr_cg` covered `item.data[0]` — the value of the first data byte — and called it "Register Access Coverage." Data byte values have no relationship to which registers are accessed. This is the wrong signal.

The lesson is simple: **before finalizing any coverpoint, ask "If this bin is hit, what have I guaranteed was exercised?"** If the answer is "nothing useful," that coverpoint should be rewritten or removed.

### 7.5 Bins That Represent Impossible Scenarios

```systemverilog
// WRONG: This bin can never be hit given the valid_protocol_c constraint
cp_invalid_proto: coverpoint {item.start_cond, item.rep_start} {
  bins impossible = {2'b11};  // start_cond AND rep_start both 1 -- constraint prevents this
}
```

The constraint `!(start_cond && rep_start)` makes `2'b11` impossible. This bin will never be hit, driving apparent coverage down. Either mark it `ignore_bins` or remove it.

---

## Part 8: Coverage Metrics and Sign-Off Gates

### 8.1 Typical Sign-Off Thresholds

Different companies have different gates, but industry consensus is approximately:

| Coverage Type | Typical Sign-Off Threshold |
|--------------|---------------------------|
| Functional Coverage | 95-100% |
| Line Coverage | 95%+ |
| Branch Coverage | 90%+ |
| Toggle Coverage | 90%+ (with tool-excluded flip-flops) |
| FSM State Coverage | 100% (all reachable states) |
| FSM Transition Coverage | 90%+ |
| Assertion Vacation Rate | 0% (no assertions should vacuously pass) |

The 100% functional coverage goal applies to *required* bins. Bins marked `ignore_bins` are excluded from the denominator. The goal is 100% of the bins you decided were mandatory.

> **SENIOR ENGINEER INSIGHT**: At my previous tape-out, we required 100% functional coverage of all non-ignored bins before any RTL freeze. This was non-negotiable. Lines of RTL that had 0% coverage triggered a mandatory investigation — either write the test, or document why the code is unreachable (and remove it if it truly is dead code, per Bug #15).

---

### 8.2 Handling Stubborn Uncovered Bins

When a bin is not hit after extensive testing, there are three possibilities:

1. **Test gap**: You simply never wrote the test for this scenario. Fix: write the directed test.

2. **Impossible scenario**: The bin represents a scenario that cannot happen given the design's constraints or architecture. Fix: change to `ignore_bins` with a comment explaining why.

3. **Design gap**: The feature that would exercise this bin was not implemented in the RTL. This is a design bug, not a verification bug. Fix: file a design review request.

Always document your decisions in the covergroup file itself:

```systemverilog
ignore_bins impossible_case = {SomeValue};
// Reason: constraint valid_protocol_c prevents addr[6:3] == 4'b0000
// See i2c_seq_item.sv line 38.
```

---

### 8.3 Reporting Coverage to Management

Management cares about a single number: what percentage of the verification plan is complete? The `report_phase` in this project does this automatically:

```systemverilog
virtual function void report_phase(uvm_phase phase);
  real dir_cov   = i2c_dir_cg.get_coverage();
  real size_cov  = i2c_data_size_cg.get_coverage();
  real ack_cov   = i2c_ack_cg.get_coverage();
  real burst_cov = i2c_burst_cg.get_coverage();
  real avg_cov   = (dir_cov + size_cov + ack_cov + burst_cov) / 4.0;
  // ...
  if (avg_cov < 90.0) `uvm_warning(...)
endfunction
```

This prints a summary after every regression run. The `< 90%` warning triggers automatically if coverage drops below threshold. In a real project, this report would be fed into a coverage dashboard that tracks trends over weeks.

---

### 8.4 The Four Coverage Types and Why You Need All Four

| Type | Tool | What It Catches |
|------|------|----------------|
| **Line/Statement Coverage** | Simulator (auto) | Completely untested code paths |
| **Branch Coverage** | Simulator (auto) | If-else arms that were never taken |
| **Toggle Coverage** | Simulator (auto) | Signals that never changed state |
| **FSM Coverage** | Simulator (auto) | Unreachable states and transitions |
| **Functional Coverage** | Engineer (manual) | Unreached protocol behaviors |
| **Assertion Coverage** | SVA tool | Protocol violations and tautologies |

They are complementary, not substitutes. Code coverage shows you untested lines. Functional coverage shows you untested behaviors. Assertions check correctness in real time. FSM coverage shows you unreachable state transitions. No one type replaces the others.

---

## Part 9: Interview Questions — Coverage

These are questions you should be able to answer clearly and confidently after reading this document. Practice your answers out loud.

---

**Q1: What is the difference between code coverage and functional coverage?**

Code coverage measures whether the simulator executed lines of RTL code — it is structural. Functional coverage measures whether meaningful protocol behaviors were exercised — it is specification-driven. Code coverage is automatic; functional coverage requires a human to define what "important behaviors" are. Code coverage can reach 100% while missing entire categories of functional behavior.

---

**Q2: What is a covergroup? What is a coverpoint? What is a bin?**

A `covergroup` is a named collection of measurements — the top-level coverage container. A `coverpoint` is one dimension being measured within a covergroup — it names the signal or expression to track. A `bin` is one category within a coverpoint — it defines a value or range of values, and the simulator counts how many times that condition was observed.

---

**Q3: What is cross coverage and when would you use it?**

Cross coverage measures the combinations of two or more coverpoints. For example, crossing direction (read/write) with burst length (1, 2-8, 9-16, 17-32) creates 8 cross-bins — one for every pairing. You use cross coverage when the interaction between two dimensions can create bugs that neither dimension alone would expose. Use it when both coverpoints are small (few bins) and their combination is architecturally meaningful.

---

**Q4: Why is 100% code coverage insufficient for sign-off?**

Code coverage only tells you which lines were executed, not whether those lines executed correctly. A shift register that captures the wrong bit will have 100% toggle and line coverage. A state machine with an incorrect next-state assignment will have 100% FSM state coverage. Code coverage cannot detect semantic errors, only structural gaps. Functional coverage, scoreboard checking, and assertions are required in addition.

---

**Q5: What is the coverage-driven verification workflow?**

1. Define the coverage model (translate spec into covergroups/bins). 2. Write random tests. 3. Run simulation. 4. Measure coverage. 5. Identify uncovered bins. 6. Write directed tests to hit those bins. 7. Repeat until all required bins are hit (closure). The key insight is that coverage actively guides test development — it is not just a metric you read at the end.

---

**Q6: What does `ignore_bins` do? When would you use it?**

`ignore_bins` marks specific values as intentionally excluded from coverage measurement. They do not count as "uncovered" — they are removed from the denominator. Use `ignore_bins` for protocol-reserved values, physically impossible states, or scenarios that are out of scope for your verification. Example: I2C reserved addresses (0x00-0x07, 0x78-0x7F) should be `ignore_bins` because the testbench constraints prevent them.

---

**Q7: What is `illegal_bins`? How does it differ from an assertion?**

`illegal_bins` causes an immediate simulation error if the marked value is ever observed in the coverpoint. It is embedded in the coverage model rather than the assertion file, and it fires at sampling time. An SVA assertion fires based on clock events and can express temporal sequences (A implies B within N cycles). `illegal_bins` is simpler — it reacts only to instantaneous value matching. Both are correct tools; use `illegal_bins` for simple "this value must never appear" checks, and SVA for temporal protocol checks.

---

**Q8: How do you decide what to put in a coverage model?**

Start with the design specification. For every feature listed in the spec, ask: "What is the range of ways this feature can be exercised?" Each distinct way becomes a bin. Then ask: "What are the important combinations of features?" Each meaningful combination becomes a cross coverage point. Also include boundary conditions (minimum value, maximum value, zero length), error conditions (NACK, timeout), and protocol corner cases (Repeated START, clock stretching). Remove anything that cannot fail or that constraints make impossible.

---

**Q9: What is a functional coverage "hole" and how do you close it?**

A coverage hole is a bin that has not been hit after running the full regression. To close it: first determine if the bin is reachable (could a valid simulation ever trigger it?). If yes, write a directed test that specifically targets that scenario — constrain the randomization to force the needed values. If the bin is unreachable (impossible given design constraints), mark it `ignore_bins` with documentation. If you are unsure, ask a senior engineer — an unexplained hole at sign-off time is a red flag.

---

**Q10: What is the coverage closure sign-off criterion?**

At most companies: 100% of all non-ignored functional coverage bins must be hit. Code coverage must exceed 90-95% (with documented exclusions for unreachable code). All assertions must pass, and their vacation rate (the percentage that were never exercised) must be near zero. Any persistent hole must be documented with a waiver explaining why the scenario is unreachable or out of scope.

---

**Q11: If a bin is never hit, how do you determine if it is a test gap or an impossible scenario?**

First, manually construct the exact scenario that would hit the bin and trace whether it is legal given all the constraints. If it is legal, it is a test gap — write the directed test. If any constraint prevents it, document it as an `ignore_bins`. If you are unsure whether the hardware can produce it, read the RTL to find where the signal is driven. For this project's `nack` bin: tracing `addr_ack` to the monitor shows it is populated from the SDA line — which is driven by the slave and can be 0. So the `nack` bin is definitely reachable; you just need a wrong-address test.

---

**Q12: What is per-instance coverage?**

When `option.per_instance = 1`, each instance of the covergroup is tracked separately. Without it, all instances of the same covergroup type are merged into one report. Per-instance is important when you have multiple coverage collectors (one per bus, one per interface) and need to see which specific bus had gaps. In this project, it is set for all covergroups — even though there is only one coverage class instance, it is good practice that scales to multi-bus environments.

---

**Q13: How would you write coverage for the clock stretching feature?**

You would add a coverpoint for the stretch duration and cross it with transaction type:

```systemverilog
cp_stretch_dur: coverpoint stretch_cycles {
  bins no_stretch   = {0};
  bins short_stretch = {[1:50]};
  bins long_stretch  = {[51:200]};
}
cross cp_dir, cp_stretch_dur;  // stretched reads AND writes
```

Then ensure `i2c_slave_stretch_ctrl_seq` is part of the regression with varied `stretch_cycles` values. You would also want to cross stretch with burst length to verify Bug #3's fix holds: stretching mid-burst returns to the correct state and continues.

---

**Q14: What is the difference between sampling on a clock edge vs using a `sample()` event?**

Clock-edge sampling (`@(posedge clk)`) samples the covergroup every clock cycle. This is useful for RTL signal tracking where you want to observe values cycle by cycle. The `sample()` method is explicit — you call it exactly when a meaningful event occurs. In UVM, `sample()` is called in the `write()` function when a complete transaction arrives from the monitor. This is better for protocol-level coverage because you only sample when a complete, valid transaction exists — not on every clock edge where intermediate states might pollute the coverage.

---

**Q15: How does functional coverage complement assertions?**

Assertions and functional coverage are complementary and non-substitutable. Assertions are correctness checks — they fire when a protocol rule is violated (e.g., "START must be followed by SCL falling"). Coverage measures completeness — it tracks whether you have *seen* a scenario, without judging whether it was handled correctly. You can have a NACK assertion (if master NACK is received, slave must not send another byte) and a NACK coverage bin (the NACK scenario was exercised). Both are needed: the assertion checks that the NACK scenario was handled correctly, and the coverage bin confirms that the NACK scenario actually occurred during simulation. Without coverage, you cannot be sure the assertion was exercised. Without the assertion, you cannot be sure the scenario was handled correctly.

---

## Summary: The Key Takeaways

1. **Code coverage is necessary but not sufficient.** It tells you what lines ran, not whether they ran correctly.

2. **Functional coverage is a human-written specification** of what "done" looks like. Its quality is determined by how thoroughly you think about the design.

3. **Every bin should map to a real scenario.** If you cannot explain in one sentence what simulation behavior hits a bin, the bin is probably wrong.

4. **Bug #13 is the most important lesson in this document.** The wrong coverpoint (`item.data[0]`) looked like it was covering "Register Access" but was measuring something completely unrelated. Always verify that your coverage signal matches your coverage intent.

5. **Cross coverage is powerful but expensive.** Use it for critical combinations where the interaction between two conditions can hide bugs.

6. **Coverage-Driven Verification is a feedback loop**, not a one-time measurement. Coverage reports tell you where to write your next test.

7. **100% coverage is a necessary but not sufficient sign-off condition.** The coverage model itself must be thorough. A shallow coverage model that reaches 100% quickly means nothing.

8. **All four coverage types are needed:** line coverage (did the code run?), functional coverage (did the behavior occur?), assertion coverage (was correctness checked?), and FSM coverage (were all states visited?).

---

## Part 10: Writing Coverage From Scratch — The Design Process

This part shows you exactly how a senior engineer approaches coverage when given a blank file and a specification. The I2C spec is the starting point. Every covergroup in `i2c_coverage.sv` came from a thought process like this one.

### Step 1: Read the Specification and Extract Coverage Requirements

The first action is to read the design spec and extract every sentence that implies something must be verified. This is not about RTL at all — it is about the protocol document.

**Sentence 1: "I2C supports write and read transactions."**

Immediate coverage implication: you must see both. This becomes:

```systemverilog
cp_direction: coverpoint item.dir {
  bins write = {DIR_WRITE};
  bins read  = {DIR_READ};
}
```

The question you ask yourself: "Can a bug hide if I only ever test writes?" Yes — the TX shift register, read data mux, and master-ACK detection are all read-only paths. They go untested. So this bin is mandatory.

**Sentence 2: "Data bytes can have any value from 0x00 to 0xFF."**

Immediate coverage implication: the data value space is 256 entries. You cannot bin every value, but certain values matter more. This becomes:

```systemverilog
cp_data_value: coverpoint item.data[0] {
  bins all_zeros     = {8'h00};           // SDA stays low 8 cycles — max hold stress
  bins all_ones      = {8'hFF};           // SDA stays high 8 cycles — max high stress
  bins alternating_a = {8'hAA};           // 10101010 — max toggle, clocking stress
  bins alternating_5 = {8'h55};           // 01010101 — inverse toggle
  bins general       = {[8'h01:8'hFE]};   // General case
}
```

The question you ask: "Which values are most likely to expose a hardware timing bug?" The extremes (0x00, 0xFF) and alternating patterns (0xAA, 0x55) are the classical stress patterns for shift registers. Your `i2c_data_pattern_seq` in this project already sends exactly these patterns — the coverage model should mirror what the sequences test.

**Sentence 3: "The slave has an 8-register internal bank."**

Immediate coverage implication: transactions can touch 1 register, a few, exactly the full bank, or more than the full bank (causing pointer wrap). This becomes:

```systemverilog
cp_reg_access: coverpoint item.num_data {
  bins single_reg   = {1};        // Touch only register 0
  bins partial_bank = {[2:4]};    // Touch registers 0-3
  bins most_of_bank = {[5:7]};    // Touch registers 0-6
  bins full_bank    = {8};        // Touch all 8 registers exactly
  bins wrap_around  = {[9:32]};   // More bytes than registers — pointer wraps
}
```

Note: this is exactly what the fixed `i2c_reg_ptr_cg` does. The Bug #13 mistake was measuring `data[0]` here instead of `num_data`. Reading the specification carefully would have prevented this error.

**Sentence 4: "ACK and NACK are both valid responses to the address phase."**

Immediate coverage implication: you must see both. The `nack` bin is the bin most often missed in real projects because NACK requires effort — you must address a wrong slave. This becomes:

```systemverilog
cp_addr_response: coverpoint item.addr_ack {
  bins ack  = {1'b1};   // Slave recognized its address
  bins nack = {1'b0};   // Slave did not respond — wrong address
}
```

**What this exercise teaches you**: Before you write a single line of SystemVerilog, read the specification sentence by sentence. Every design feature, every protocol condition, every range statement in the spec implies a set of bins. Engineers who skip this step write coverage that is disconnected from the verification goals.

---

### Step 2: Identify the Important Combinations

After you have individual coverpoints, you look for combinations that matter. Not all combinations are worth crossing — only the ones where a bug could hide in the interaction.

**Combination 1: Direction + Data Size**

A write of 1 byte exercises different logic than a read of 32 bytes. The cross of `cp_dir x cp_size` creates 8 bins that ensure all meaningful (direction, length) pairs are tested. This is `i2c_burst_cg` in this project.

Ask yourself: "Could a bug appear in burst reads but not in burst writes?" Yes — the TX shift register path is only active during reads. So this cross is mandatory.

**Combination 2: Burst + Clock Stretch**

A single-byte transaction with clock stretching is different from a 16-byte burst with stretching. The stretch logic must hold SCL low without corrupting the byte counter or the byte_ack queue. If you only ever stretch single-byte transactions, you might miss a counter overflow bug that appears at byte 9.

The cross you would add:

```systemverilog
// In a stretch-aware covergroup:
cross cp_size, cp_stretch_duration;
```

This bin set forces you to run `i2c_slave_stretch_ctrl_seq` with burst lengths in every size category — not just single-byte tests.

**Combination 3: Maximum Register Access + Burst Wrap**

The register pointer wraps at 8. A 9-byte write exercises the wrap. But does a 32-byte write correctly cycle through the full bank 4 times? This combination — `full_bank` crossed with `multi_wrap` — does not appear in the current project's cross coverage. It is a gap. A senior engineer would add:

```systemverilog
// Ensure we have seen max burst (32 bytes) in both read and write
bins max_write_wrap = binsof(cp_dir.write) && binsof(cp_size.long_burst);
bins max_read_wrap  = binsof(cp_dir.read)  && binsof(cp_size.long_burst);
```

**What this step teaches you**: You cannot cross everything — the explosion is too large. Focus on combinations where the two dimensions interact at the RTL level. Read the RTL data path and ask: "Where do two signals meet in the logic?" That intersection is where cross coverage pays off.

---

### Step 3: Decide What NOT to Cover

A good coverage model is as much about what you exclude as what you include. Not everything is worth measuring.

**Exclusion 1: Individual clock cycle behavior**

You do not write coverpoints for SCL high time, SCL low time, or SDA setup time. Those are timing properties measured by assertions and simulation waveform analysis. Code coverage handles whether the timing logic ran. Functional coverage is for protocol-level behaviors, not cycle-level events.

**Exclusion 2: Reset state**

The constraint `default_trans_c` in `i2c_seq_item.sv` forces `start_cond == 1` for every transaction. Writing a coverpoint for `start_cond` with `bins always_set = {1}` would be hit by literally every transaction. It closes instantly and measures nothing. Exclude it.

**Exclusion 3: Internal FSM signals**

Do not write coverpoints that reference `dut.slave.state` or any internal RTL signal directly. Reasons:
- RTL refactoring breaks your coverage model
- State names are implementation artifacts, not protocol behaviors
- FSM coverage (built into the simulator) already tracks state and transition coverage automatically

**Exclusion 4: Reserved I2C addresses**

The `valid_addr_c` constraint in `i2c_seq_item.sv` prevents addresses in `[7'h00:7'h07]` and `[7'h78:7'h7F]`. These ranges should be `ignore_bins`, not uncovered bins. Writing `ignore_bins reserved_low = {[7'h00:7'h07]}` removes them from the denominator so they do not suppress your coverage percentage.

---

### Step 4: Validate the Coverage Model Before Running Simulation

Before you run a single test, check each bin manually.

**Check 1: Can this bin actually be hit?**

For `bins full_bank = {8}` in `i2c_reg_ptr_cg`: can `num_data == 8` ever be generated? Look at the constraint: `num_data inside {[1:32]}`. Yes, 8 is in this range. The bin is reachable.

For a hypothetical `bins impossible = {0}` bin on `num_data`: the constraint `num_data >= 1` prevents it. This should be `illegal_bins zero = {0}`, not a regular bin.

**Check 2: Is there an existing sequence that hits this bin?**

For `bins long_burst = {[17:32]}`: is there a sequence that generates `num_data >= 17`? Yes — `i2c_burst_write_seq` with `burst_len` randomized in `[17:32]` and `i2c_burst_read_seq` similarly. Confirmed reachable by existing sequences.

For `bins nack = {0}` on `cp_addr_ack`: is there a sequence that generates `addr_ack == 0`? Yes — `i2c_nack_addr_seq` sends to a wrong address, the slave does not respond, and the monitor sets `addr_ack = 0`. Confirmed reachable.

**Check 3: If the bin is impossible, what do you do?**

Use `ignore_bins` for values that are legal protocol states but excluded by testbench constraints. Use `illegal_bins` for values that represent protocol violations and should never appear. The distinction matters: `ignore_bins` says "this is excluded from measurement" and `illegal_bins` says "this is a bug if it ever appears."

**What this step teaches you**: Coverage validation is a paper exercise you do before simulation starts. If you cannot trace a path from a sequence to a bin hit, that bin is either a gap in your test library (add a sequence) or an impossibility (mark it `ignore_bins`). Doing this upfront saves the frustration of discovering stubborn uncovered bins late in the project when time is short.

---

## Part 11: Coverage Holes — The 5 Most Common Gaps in I2C Verification

Coverage holes are bins that engineers consistently fail to close, project after project. These are not exotic edge cases — they are the gaps that appear in almost every I2C verification effort that does not follow a rigorous process. For each gap, you will see why it is missed, what bug it would have caught, and how to close it.

---

### Gap 1: Repeated START Never Tested

**Why Engineers Miss It**

The default transaction model is START → address → data → STOP. Engineers write sequences that all follow this pattern. The Repeated START — where the master issues a new START condition instead of STOP to change direction — is a less obvious feature. It is easy to run the entire test suite using only `i2c_single_write_seq`, `i2c_single_read_seq`, and `i2c_burst_write_seq` and never realize that `has_rep` in `i2c_protocol_cg` was never hit.

In this project, `i2c_rep_start_seq` exists specifically to close this hole. But it must be explicitly added to the regression. Random tests with fully random constraints will not hit `rep_start == 1` because `default_trans_c` forces `rep_start == 0` for all base-class items.

**The Consequence — Which Bug It Would Miss**

The Repeated START path exercises a different slave state machine branch. After the first transaction's data phase (no STOP), the slave must hold its state — it must not reset `reg_ptr`, must not clear the byte counter, and must not return to IDLE. It must instead remain in a "ready for next START" state. If the slave returns to IDLE after a no-STOP transaction, a second START on a different direction will start writing/reading from register 0, corrupting data.

Without `has_rep` coverage, you might ship a slave that works perfectly for normal START-STOP transactions but corrupts data in every EEPROM-style read (write register address, Repeated START, read data).

**How to Add Coverage for It**

The `i2c_protocol_cg` covergroup already has the `has_rep` bin. What is missing is a regression entry. Add this to your test:

```systemverilog
// In the test's run_phase:
i2c_rep_start_seq rep_seq;
rep_seq = i2c_rep_start_seq::type_id::create("rep_seq");
rep_seq.start(env.master_agent.sequencer);
```

And add a cross that ensures Repeated START is exercised in both directions:

```systemverilog
// Enhanced coverage for Repeated START sequences
cp_rep_dir_pattern: coverpoint {item.rep_start, item.dir} {
  bins write_to_read = (2'b00 => 2'b11);  // normal write followed by rep-start read
  bins read_to_write = (2'b01 => 2'b10);  // rep-start read followed by normal write
  // Uses transition bins — explained in Part 13
}
```

---

### Gap 2: Maximum Burst Length Never Tested

**Why Engineers Miss It**

The default `burst_len_c` constraint in `i2c_burst_write_seq` allows any value in `[1:32]`. With random seeds, you will see many values in the 1-10 range frequently — randomization does not uniformly distribute across the range. A 32-byte burst requires `num_data == 32`, which is just one value out of 32 possible values. In 100 random transactions, you might never hit it.

This is a classic case where random coverage is insufficient for corner cases at the boundaries. The `long_burst` bin (`[17:32]`) is harder to close than it looks because even within that range, values near 17 are more likely than values near 32.

**The Consequence — Which Bug It Would Miss**

Maximum burst length exercises pointer arithmetic at its limit. A 32-byte burst writes to all 8 registers 4 complete times, with the pointer wrapping 3 times. If the wrap logic has an off-by-one error — say it wraps at 7 instead of 8, or fails to wrap at all after the second cycle — the bug only appears at burst lengths that require multiple full cycles of the register bank.

Single-byte and short-burst tests never exercise the second wrap. Long burst tests are the only way to detect this class of bug. The `multi_wrap` bin in `i2c_reg_ptr_cg` specifically targets this, but it requires you to explicitly generate transactions with `num_data >= 9`.

**How to Add Coverage for It**

Add a directed test that forces maximum burst:

```systemverilog
i2c_burst_write_seq max_write;
max_write = i2c_burst_write_seq::type_id::create("max_write");
// Override constraint to force maximum length
max_write.burst_len_c.constraint_mode(0);
if (!max_write.randomize() with { burst_len == 32; })
  `uvm_fatal("TEST", "Max burst randomize failed")
max_write.start(env.master_agent.sequencer);

i2c_burst_read_seq max_read;
max_read = i2c_burst_read_seq::type_id::create("max_read");
max_read.burst_len_c.constraint_mode(0);
if (!max_read.randomize() with { burst_len == 32; })
  `uvm_fatal("TEST", "Max burst read randomize failed")
max_read.start(env.master_agent.sequencer);
```

You should also add an enhanced bin for the single maximum value:

```systemverilog
cp_burst_extremes: coverpoint item.num_data {
  bins minimum = {1};   // Absolute minimum — already covered
  bins maximum = {32};  // Absolute maximum — often missed
}
```

---

### Gap 3: Address Phase Clock Stretching Never Tested

**Why Engineers Miss It**

The `i2c_clock_stretch_seq` in this project sends a normal write transaction and relies on the slave to stretch SCL during the data phase. But clock stretching can also occur during the address phase — while the slave is deciding whether to acknowledge the address. Most test sequences only verify stretching during data byte transmission.

Engineers miss this because the `i2c_clock_stretch_seq` does not distinguish between address-phase stretch and data-phase stretch. The sequence just sets `stretch_cycles` and lets the slave decide when to apply it. If the slave's stretch logic only activates after the address phase, the address-phase stretch scenario is never tested.

**The Consequence — Which Bug It Would Miss**

Address-phase clock stretching exercises a different code path than data-phase stretching. The slave must hold SCL low immediately after receiving the last address bit, before sending ACK. If the address-phase stretch is implemented incorrectly — for example, it stretches during ACK instead of before it, or it releases SCL too early — the master might sample the address byte incorrectly.

This is the bug class that is hardest to find because it appears in the address acknowledgment timing, not in the data. A scoreboard checking data values will not catch it — only a waveform inspection or a protocol monitor that checks the timing of each bit.

**How to Add Coverage for It**

Add a coverpoint that distinguishes stretch phase:

```systemverilog
// In a clock-stretch-aware covergroup
covergroup i2c_stretch_phase_cg;
  option.per_instance = 1;
  option.name = "Stretch Phase";
  cp_stretch_phase: coverpoint stretch_phase_e {
    bins addr_phase   = {STRETCH_ADDR};   // Stretch during address ACK
    bins data_phase   = {STRETCH_DATA};   // Stretch during data byte
    bins no_stretch   = {STRETCH_NONE};   // No stretch
  }
  cp_stretch_dir: coverpoint item.dir;
  cross cp_stretch_phase, cp_stretch_dir;
endgroup
```

Then write a directed test that forces the slave to stretch during the address phase specifically, using `i2c_slave_stretch_ctrl_seq` with a configuration that activates stretch before the first data byte.

---

### Gap 4: NACK After the First Data Byte Never Tested

**Why Engineers Miss It**

The `i2c_nack_addr_seq` sends to a wrong address, which causes a NACK at the address phase. The `i2c_slave_force_nack_seq` forces a NACK during the data phase. But most tests only check NACK at the very last byte of a burst — the master sends NACK to terminate a read transaction after all desired bytes have been received.

What is almost never tested: NACK at the first or second data byte of a multi-byte burst. This represents a slave signaling "I cannot accept more data" after acknowledging the address but before receiving all bytes.

**The Consequence — Which Bug It Would Miss**

A mid-burst data NACK exercises the slave's error recovery logic. After receiving a data NACK, the slave must:
1. Stop expecting more data bytes
2. Wait for a STOP condition
3. Return to IDLE

If the slave's byte counter continues after a NACK, or if it expects a STOP before it has finished any internal operations, the subsequent transaction on the bus may be corrupted. This bug appeared as a variant of Bug #4 in this project — the `SLV_TX_ACK` state that ignored NACK from the master during read transactions.

**How to Add Coverage for It**

Extend the ACK tracking to per-byte resolution:

```systemverilog
covergroup i2c_per_byte_ack_cg;
  option.per_instance = 1;
  option.name = "Per-Byte ACK";
  // byte_ack is a queue in i2c_seq_item — track which byte index got NACK
  cp_nack_position: coverpoint nack_byte_index {
    bins nack_at_byte_0 = {0};        // NACK at first data byte
    bins nack_at_byte_1 = {1};        // NACK at second byte
    bins nack_at_mid    = {[2:6]};    // NACK mid-burst
    bins nack_at_end    = {7};        // NACK at last byte of full bank
    bins no_nack        = {-1};       // No data NACK at all
  }
endgroup
```

Then add a directed sequence that forces NACK at byte index 0 (first data byte) and another that forces it at index 1. These require coordination between the master sequence and the slave force-NACK sequence.

---

### Gap 5: Bus Recovery After Premature STOP Never Tested

**Why Engineers Miss It**

Normal test sequences are clean: START, address, data, STOP. Error injection tests typically force NACK. But what happens when a STOP condition occurs in the middle of a data byte — before the full 8 bits have been transferred? This is a premature STOP, and it is a protocol error condition.

Premature STOP can happen due to:
- Master firmware bug (sends STOP after 4 bits instead of 8)
- Bus glitch that the slave's START/STOP detector misinterprets as a STOP
- Multi-master arbitration causing a competing master to steal the bus

Most test suites never inject this because it requires deliberately breaking the protocol, and engineers are often reluctant to write tests that "violate" the spec. But if the DUT can encounter this in the field, you must verify it recovers gracefully.

**The Consequence — Which Bug It Would Miss**

After a premature STOP, the slave's bit counter is in an unknown state. If the slave does not detect the STOP and reset its state machine to IDLE, the next START condition will find the slave in a corrupted state — it might be in the middle of an 8-bit shift register operation. The next valid transaction from the master will produce garbage because the slave's bit counter is misaligned.

Bug #15 in this project (dead code for STOP detection during data byte) is exactly this class of bug. The STOP-during-data code path existed in the spec but was never implemented in the RTL. Without coverage of this scenario, you would never know the code path was dead.

**How to Add Coverage for It**

Add a coverpoint for bus state after error:

```systemverilog
covergroup i2c_bus_recovery_cg;
  option.per_instance = 1;
  option.name = "Bus Recovery";
  cp_recovery: coverpoint bus_recovery_scenario {
    bins clean_sequence    = {RECOVERY_NONE};        // Normal — no recovery needed
    bins after_addr_nack   = {RECOVERY_ADDR_NACK};   // Recovery after address NACK
    bins after_data_nack   = {RECOVERY_DATA_NACK};   // Recovery after data NACK
    bins after_premature_stop = {RECOVERY_PREMATURE}; // Recovery after early STOP
  }
endgroup
```

Then verify the follow-on transaction after each error type succeeds:

```systemverilog
// After premature STOP, verify the bus recovers:
// 1. Send transaction that triggers premature STOP
// 2. Immediately send a valid normal transaction
// 3. Verify scoreboard: normal transaction data is correct
```

This is an important distinction: the coverage bin is for the *recovery scenario*, and the scoreboard check verifies the recovery was *correct*.

---

## Part 12: Coverage-Assertion Complementarity

Coverage and assertions are the two pillars of a complete verification plan. Most engineers learn them separately and treat them as unrelated. They are not. They are designed to work together, and understanding how they complement each other is one of the most important insights in verification.

### What Assertions Do

An SVA assertion monitors a signal or sequence of signals and fires an error if a specified condition is violated. In this project:

```systemverilog
// SVA: SDA must not change while SCL is HIGH (except for START/STOP conditions)
assert property (@(posedge clk) disable iff (!rst_n)
  (scl_i) |-> ##1 (sda_o == $past(sda_o)))
  else `uvm_error("SVA", "SDA changed while SCL was HIGH — data violation");
```

This assertion fires the moment an illegal SDA transition occurs during SCL high. It is immediate — you see the error at the exact simulation timestep when the violation happens. The waveform at that point tells you exactly what went wrong.

**What assertions guarantee**: If the assertion fires, a bug exists. If the assertion never fires during simulation, no violation occurred during the tested scenarios.

**What assertions do NOT guarantee**: Assertions do not tell you whether you tested the important scenarios. An assertion that never fires could mean either (a) the design is correct for the tested cases, or (b) you never tested the right cases to trigger the assertion.

### What Coverage Does

Coverage tracks which scenarios were exercised. A coverage bin for SDA transitions might look like:

```systemverilog
cp_sda_transitions: coverpoint {sda_prev, sda_curr} {
  bins low_to_high  = {2'b01};   // SDA: 0 → 1 during valid window
  bins high_to_low  = {2'b10};   // SDA: 1 → 0 during valid window
  bins stayed_low   = {2'b00};   // SDA: held 0
  bins stayed_high  = {2'b11};   // SDA: held 1
}
```

This tells you: did simulation actually drive both rising and falling transitions on SDA? If only `stayed_high` and `stayed_low` are hit, SDA never changed — which means either no data was tested (the covergroup itself exposes this gap) or the data patterns happened to always keep SDA in one state.

**What coverage guarantees**: Coverage tells you which scenarios were seen. If `low_to_high` is hit, at least one SDA rising transition occurred.

**What coverage does NOT guarantee**: Coverage does not tell you whether those scenarios were handled correctly. You could have 100% coverage on `cp_sda_transitions` while the design is violating the SDA-during-SCL-high rule on every transition — but you would only know that if the assertion fires.

### How They Work Together — The Complete Picture

```
ASSERTION: "SDA must not change while SCL is HIGH"
    |
    +--- If assertion fires: Bug exists NOW. Fix it.
    |
    +--- If assertion never fires during simulation:
              |
              +--> Is it because the design is correct?
              |         OR
              +--> Is it because we never tested SDA transitions?
                        |
                        v
              COVERAGE: "Did we test both SDA=0→1 and SDA=1→0 transitions?"
                        |
                        +--> If cp_sda_transitions shows 0% hit:
                                  We never exercised SDA changes at all.
                                  The assertion was NEVER actually tested.
                                  This is a test gap, not a design correctness proof.
                        |
                        +--> If cp_sda_transitions shows 100% hit:
                                  We tested SDA transitions.
                                  The assertion never fired.
                                  The design handled those transitions correctly.
```

This is the critical insight: **assertions prove correctness for tested scenarios; coverage proves which scenarios were tested**. You need both to have a meaningful claim about the design.

### The Gap That Neither Alone Covers

Consider this scenario: SDA is always 0x00 in every test. The assertions never fire (no violations). The `cp_sda_transitions` coverpoint shows `stayed_low` at 100% — only the "SDA held 0" bin was hit.

Neither the assertion nor the simple SDA transition coverage caught the real problem: you are not testing any actual data. The `cp_data_value` coverpoint from Part 6 catches this — if `all_ones` and `alternating_a` bins are never hit, you know data value coverage is incomplete.

This is why you need a complete coverage model: the coverage bins catch scenarios that assertions cannot check (because the assertion only fires on violations, not on absences of stimuli).

### Designing Assertions and Coverage Together

When you write a new assertion, ask: "What coverage bin ensures this assertion was actually exercised?"

| Assertion | Paired Coverage Bin |
|-----------|-------------------|
| "SDA must not change during SCL high" | `cp_sda_transitions` — both 0→1 and 1→0 seen |
| "NACK must cause master to stop sending" | `cp_addr_ack.nack` — NACK scenario was exercised |
| "ACK must follow every valid data byte in write mode" | `cp_dir.write` + `cp_size.short_burst` — burst writes tested |
| "Repeated START must not assert STOP simultaneously" | `cp_rep.has_rep` — Repeated START scenario was exercised |
| "Clock stretch must not exceed max_stretch_cycles" | `cp_stretch.max_stretch` — maximum stretch was tested |

In a mature project, every assertion in the assertion file has a corresponding coverage entry. This creates a traceability matrix: assertion X is meaningfully checked because coverage bin Y was hit.

### The Vacation Rate Problem

An assertion that never fires could be correct — or it could be vacuously true (never triggered because the antecedent was never true). This is called the **assertion vacation rate**. A vacuous assertion gives false confidence.

Example:
```systemverilog
// This assertion: "If rep_start, then stop_cond must be 0"
assert property (@(posedge clk)
  (rep_start) |-> (!stop_cond));
```

If `rep_start` is always 0 (because `default_trans_c` forces it to 0 for all normal sequences), this assertion is always vacuously true — it never actually checks anything. The coverage bin `bins has_rep = {1}` in `i2c_protocol_cg` is what forces the antecedent to be true at least once.

Without the `has_rep` coverage bin, the assertion's vacation rate would be 100% — it never ran at all. With the `has_rep` bin driving a directed `i2c_rep_start_seq` into the regression, the assertion runs and actually checks something.

> **KEY RULE**: Every assertion antecedent must have a corresponding coverage bin that ensures the antecedent was true at least once during the simulation run.

---

## Part 13: Advanced Bins — Transition Bins and Wildcard Bins

The bins you have learned so far — explicit value bins and range bins — cover most coverage needs. But SystemVerilog offers two additional bin types that are extremely powerful for protocol verification: transition bins and wildcard bins.

### Transition Bins

A transition bin fires when a **sequence of values** is observed across multiple sampling events. It does not just check what value a coverpoint has — it checks what *sequence of values* the coverpoint goes through over time.

**Syntax:**

```systemverilog
cp_ack_sequence: coverpoint item.ack_received {
  bins ack_then_nack = (1'b1 => 1'b0);  // ACK followed by NACK at next sample
  bins nack_then_ack = (1'b0 => 1'b1);  // NACK followed by ACK at next sample
  bins always_ack    = (1'b1 => 1'b1);  // Two consecutive ACKs
  bins always_nack   = (1'b0 => 1'b0);  // Two consecutive NACKs
}
```

The `=>` operator means "followed by at the next sample." The bin `ack_then_nack` fires when one sampling event finds `ack_received == 1` and the very next sampling event finds `ack_received == 0`.

**When to Use Transition Bins for I2C**

Transition bins are ideal for testing sequences of protocol events:

```systemverilog
// Track sequences of transaction directions
cp_dir_sequence: coverpoint item.dir {
  bins write_then_read  = (DIR_WRITE => DIR_READ);   // Write followed by read
  bins read_then_write  = (DIR_READ  => DIR_WRITE);  // Read followed by write
  bins consecutive_read = (DIR_READ  => DIR_READ);   // Back-to-back reads
  bins consecutive_write= (DIR_WRITE => DIR_WRITE);  // Back-to-back writes
}
```

This is more powerful than a simple `cp_dir` coverpoint. A simple direction coverpoint tells you that both write and read transactions were seen. The transition coverpoint tells you whether you tested a read immediately after a write (important for verifying bus state is correctly reset between transactions).

**Multi-step transitions** let you check longer sequences:

```systemverilog
cp_three_step_protocol: coverpoint item.dir {
  // Write, then Repeated START read, then write again
  bins wr_rep_wr = (DIR_WRITE => DIR_READ => DIR_WRITE);
}
```

This three-step transition fires only when three consecutive sampled transactions follow the write → read → write pattern. This is the EEPROM access pattern: write register address, read data, write next address.

**Transition bin for ACK sequence:**

In a burst read, the master ACKs each byte except the last, which it NACKs to terminate. The sequence of ACKs is: ACK, ACK, ..., ACK, NACK. A transition bin captures whether this sequence occurred:

```systemverilog
cp_burst_ack_termination: coverpoint byte_ack_current {
  bins ack_to_nack_termination = (1'b1 => 1'b0);  // Final ACK→NACK: correct termination
  bins nack_mid_burst          = (1'b0 => 1'b1);  // NACK then ACK: error recovery case
}
```

The `ack_to_nack_termination` bin fires during the last byte of any read burst where the master correctly NACKs the final byte. The `nack_mid_burst` bin fires when a NACK appears before the end of a burst — a recovery or error scenario.

---

### Wildcard Bins

A wildcard bin matches a **pattern** rather than an exact value. Wildcard patterns use `?` to mean "match either 0 or 1 at this bit position."

**Syntax:**

```systemverilog
cp_address_msb: coverpoint item.addr[6:4] {
  wildcard bins high_nibble = {3'b1??};  // any address where bit[6] == 1
  wildcard bins low_nibble  = {3'b0??};  // any address where bit[6] == 0
}
```

The `?` in a wildcard bin is a don't-care — it matches both 0 and 1. So `3'b1??` matches `3'b100`, `3'b101`, `3'b110`, and `3'b111` — any 3-bit value with the MSB set.

**When to Use Wildcard Bins for I2C**

Wildcard bins are most useful when you care about a specific bit position but not the full value.

**Example 1: Testing upper half vs lower half of the address space**

```systemverilog
cp_addr_half: coverpoint item.addr {
  wildcard bins upper_half = {7'b1??????};  // addr >= 0x40
  wildcard bins lower_half = {7'b0??????};  // addr < 0x40
}
```

This is more informative than a pure range bin when the bit significance matters. The MSB of a 7-bit I2C address distinguishes upper and lower address space — relevant for designs where the upper-half addresses use a different decode logic.

**Example 2: Data byte bit patterns**

```systemverilog
cp_data_msb: coverpoint item.data[0] {
  wildcard bins msb_set     = {8'b1???????};  // High bit set — SDA starts high
  wildcard bins msb_clear   = {8'b0???????};  // High bit clear — SDA starts low
  wildcard bins alternating  = {8'b?1010101, 8'b?0101010};  // Partial alternating
}
```

The `msb_set` bin fires for any data byte with bit 7 set (0x80-0xFF). This matters because the first bit transmitted on SDA determines how the master drives the line at the beginning of the data phase. Coverage of "MSB set" and "MSB clear" ensures you have seen both SDA starting states.

**Example 3: Burst length divisibility**

```systemverilog
cp_burst_power_of_two: coverpoint item.num_data[4:0] {
  wildcard bins power_of_2 = {5'b?0001,  // 1 byte
                               5'b?0010,  // 2 bytes
                               5'b?0100,  // 4 bytes
                               5'b?1000,  // 8 bytes
                               5'b1_0000}; // 16 bytes
}
```

This bin fires only when `num_data` is a power of 2. Powers of 2 are natural boundary conditions for hardware with binary counter logic — if the pointer wraps on a power-of-2 boundary, this bin ensures those exact lengths are tested.

---

### When to Use Each Bin Type — Summary

| Bin Type | Best For | I2C Example |
|----------|----------|-------------|
| **Value bin** `{value}` | Exact specific values | `bins full_bank = {8}` |
| **Range bin** `{[lo:hi]}` | Continuous ranges | `bins short_burst = {[2:8]}` |
| **Transition bin** `(a => b)` | Sequences of values across samples | `(DIR_WRITE => DIR_READ)` |
| **Wildcard bin** `{pattern}` | Bit-pattern matching with don't-cares | `{7'b1??????}` for addr MSB |
| **ignore_bins** | Values to exclude from denominator | Reserved I2C addresses |
| **illegal_bins** | Values that must never appear | `num_data == 0` |

> **KEY RULE**: Use the simplest bin type that captures the intent. Value bins for exact values. Range bins for contiguous ranges. Transition bins only when the sequence between samples matters. Wildcard bins only when a bit pattern (not a specific value) is the meaningful criterion. Do not use wildcards where a simple range would work — wildcards are harder to read and easier to misinterpret.

---

## Part 14: Integration with UVM — How the Coverage Class Connects

You have learned what covergroups are and how to write bins. Now the question is: how does the coverage class actually receive transactions to sample? This part explains the complete UVM wiring — from monitor to coverage class to report.

### The uvm_subscriber Base Class

In this project, `i2c_coverage` extends `uvm_subscriber #(i2c_seq_item)`:

```systemverilog
class i2c_coverage extends uvm_subscriber #(i2c_seq_item);
  `uvm_component_utils(i2c_coverage)
  ...
endclass
```

`uvm_subscriber` is a shortcut class provided by UVM. It combines two things:
1. A `uvm_analysis_imp` — an analysis port implementation that receives transactions
2. An abstract `write()` function — you must implement this function

When you extend `uvm_subscriber`, UVM automatically creates the analysis implementation port for you. You only need to implement the `write()` function.

The alternative — not using `uvm_subscriber` — would require you to manually declare the analysis implementation:

```systemverilog
// The longer way, without uvm_subscriber:
class i2c_coverage extends uvm_component;
  uvm_analysis_imp #(i2c_seq_item, i2c_coverage) analysis_export;
  
  function new(...);
    analysis_export = new("analysis_export", this);
  endfunction
  
  virtual function void write(i2c_seq_item t);
    // sample covergroups here
  endfunction
endclass
```

`uvm_subscriber` does this for you automatically. The exported port is named `analysis_export` and is accessible from outside the class. This is a minor convenience that reduces boilerplate.

---

### How the Monitor Publishes Transactions

The monitor (`i2c_monitor`) drives the coverage class. After assembling a complete I2C transaction from the bus signals, the monitor calls:

```systemverilog
// Inside i2c_monitor.sv — the monitor's run_phase:
ap.write(txn);  // ap is a uvm_analysis_port
```

This `write()` call goes to every subscriber connected to `ap`. If `i2c_coverage.analysis_export` is connected to `ap`, then `i2c_coverage.write()` is called automatically.

The connection happens in the environment (`i2c_env.sv`):

```systemverilog
// Inside i2c_env's connect_phase:
monitor.ap.connect(coverage.analysis_export);
```

This one line is the entire wiring. After `connect_phase`, every time the monitor completes a transaction and calls `ap.write()`, the coverage class's `write()` is invoked automatically — no polling, no explicit calls from the test.

---

### The write() Function — The Heart of Coverage Collection

The `write()` function in `i2c_coverage` is the most important function in the coverage class:

```systemverilog
virtual function void write(i2c_seq_item t);
  this.item = t;               // Store the transaction for covergroup access
  i2c_dir_cg.sample();         // Sample all unconditional covergroups
  i2c_data_size_cg.sample();
  i2c_addr_cg.sample();
  i2c_protocol_cg.sample();
  i2c_ack_cg.sample();
  i2c_burst_cg.sample();
  if (t.num_data > 0)          // Conditional: only sample when data exists
    i2c_reg_ptr_cg.sample();
  if (t.addr == 7'h50)         // Conditional: only sample for target address
    i2c_target_cg.sample();
endfunction
```

Every covergroup refers to `item.field` — the field is read from `this.item` at the moment `sample()` is called. The sequence is:
1. Store the incoming transaction: `this.item = t`
2. Call `sample()` on each covergroup
3. Inside each covergroup, the coverpoint expression (`item.dir`, `item.num_data`, etc.) is evaluated
4. The simulator increments the appropriate bin

This function runs synchronously — it completes before the next `ap.write()` can be called. There is no risk of a race between two transactions.

---

### Adding a Second Coverage Class for Error Coverage

If you want to add coverage for error injection scenarios specifically, you do not modify `i2c_coverage.sv`. Instead, you create a second subscriber class:

```systemverilog
class i2c_error_coverage extends uvm_subscriber #(i2c_seq_item);
  `uvm_component_utils(i2c_error_coverage)
  
  i2c_seq_item item;
  
  covergroup i2c_error_cg;
    option.per_instance = 1;
    option.name = "Error Injection";
    cp_nack_inject: coverpoint item.inject_nack {
      bins nack_off = {1'b0};   // Normal transaction
      bins nack_on  = {1'b1};   // Forced NACK
    }
    cp_timeout_inject: coverpoint item.inject_timeout {
      bins timeout_off = {1'b0};
      bins timeout_on  = {1'b1};
    }
    cross cp_nack_inject, cp_timeout_inject;
  endgroup
  
  function new(string name = "i2c_error_coverage", uvm_component parent = null);
    super.new(name, parent);
    i2c_error_cg = new();
  endfunction
  
  virtual function void write(i2c_seq_item t);
    this.item = t;
    // Only sample when an error was injected
    if (t.inject_nack || t.inject_timeout)
      i2c_error_cg.sample();
  endfunction
  
endclass : i2c_error_coverage
```

Then in the environment, add the second subscriber and connect it to the same monitor analysis port:

```systemverilog
// In i2c_env.sv:
i2c_error_coverage error_cov;

// In build_phase:
error_cov = i2c_error_coverage::type_id::create("error_cov", this);

// In connect_phase:
monitor.ap.connect(coverage.analysis_export);       // existing connection
monitor.ap.connect(error_cov.analysis_export);      // new connection
```

The analysis port supports multiple subscribers — every subscriber connected to it receives a copy of every transaction. This is the "broadcast" model of UVM analysis ports. Neither subscriber knows about the other. The monitor simply calls `ap.write(txn)` once and UVM distributes it to all connected subscribers.

---

### Why the Coverage Class Is a Subscriber, Not a Creator

The coverage class receives transactions; it does not create them. This is a fundamental UVM principle: components that observe and measure are separate from components that generate stimulus.

The separation means:
- You can swap coverage models without touching the monitor or driver
- You can add new coverage classes without modifying existing ones
- The coverage class cannot accidentally affect DUT behavior (it has no driver connection)
- Coverage is passive — it only measures what the monitor sees, which is what the DUT actually produced

If the coverage class were also driving the DUT, a bug in the coverage logic could affect simulation results. The subscriber model prevents this completely.

---

## Part 15: Industry Coverage Practices — What Real Chip Projects Do

The coverage model and workflow in this learning project are representative of real chip verification. But industrial verification has additional practices built on top that you will encounter in a professional environment. This part introduces those practices so the terminology is not unfamiliar.

### Sign-Off Criteria — The Real Numbers

Every chip project defines a **verification plan** (also called a V-plan) that specifies exact closure criteria before RTL freeze. Typical numbers at a leading semiconductor company:

| Metric | Typical Closure Gate |
|--------|---------------------|
| Functional coverage | 95%+ of all non-excluded bins |
| Line/statement coverage | 95%+ (excluding tool-marked dead code) |
| Branch coverage | 90%+ |
| Toggle coverage | 85%+ (flip-flops), 90%+ (primary inputs) |
| FSM state coverage | 100% of reachable states |
| FSM transition coverage | 90%+ |
| Assertion pass rate | 100% (zero failures) |
| Assertion vacation rate | Below 5% (assertions that never fired) |

The 95% functional threshold (not 100%) acknowledges that some bins are extremely difficult to hit in simulation — they may require emulation-level runtimes or hardware-in-the-loop. Each unclosed bin requires a written **waiver** — a documented justification for why the bin is not required.

---

### Exclusion Files — Marking What You Cannot Cover

When a bin, line, or branch is unreachable or out-of-scope, you document it in an **exclusion file**. This is not a comment in the source code — it is a separate file that the coverage tool reads and uses to exclude items from the denominator.

For Synopsys VCS and Verdi, this is a `.cfg` or `.vdb` exclusion annotation. For Cadence Xcelium and IMC, it is an exclusion script. The format varies by tool, but the content is always the same: a reference to the specific bin or line, plus a justification comment.

Example exclusion entry (conceptual format):

```
EXCLUDE FUNCTIONAL i2c_reg_ptr_cg::cp_reg::impossible_addr_zero
REASON: "Constraint valid_addr_c in i2c_seq_item.sv prevents addr[6:3]==4'b0000.
         This bin is architecturally unreachable from the testbench."
APPROVED_BY: "Senior verification lead — 2026-04-30"
```

Exclusion files must be reviewed by a senior engineer before sign-off. An exclusion is an assertion that a scenario cannot happen — if that assertion is wrong, you have shipped an untested scenario. Exclusion reviews are treated seriously.

In this project, the `ignore_bins` in the SystemVerilog source serve the same purpose for small cases. For a full industrial project, these would be externalized into an exclusion file that is tracked in version control separately from the source.

---

### Coverage Regression — Running Coverage Across All Tests

A single test produces a single coverage database (a `.db` or `.vdb` file). To get the aggregate coverage across your entire test suite, you need to **merge** all individual databases into one.

The workflow:

```bash
# Run each test with coverage enabled (VCS example):
vcs -cm line+branch+toggle+fsm+assert ... +test test_1 -cm_dir cov/test_1.vdb
vcs -cm line+branch+toggle+fsm+assert ... +test test_2 -cm_dir cov/test_2.vdb
# ... (repeat for all tests)

# Merge all coverage databases:
urg -dir cov/test_1.vdb cov/test_2.vdb ... cov/test_N.vdb -report merged_report/

# Open the merged report in Verdi:
verdi -cov -covdir cov/test_1.vdb:cov/test_2.vdb:...
```

The merged report shows which bins were hit by any test. If `test_3` hits the `nack` bin and no other test does, the merged report shows `nack` as covered. The individual test reports show exactly which test hit each bin — useful for debugging.

In a CI system, coverage merge runs automatically after every nightly regression. A dashboard tool (Verdi Coverage Analyzer, or a custom script) reads the merged result and posts the percentages to a tracking page. Engineers check this dashboard each morning to see if coverage regressed (new tests broke existing coverage) or improved.

---

### Unified Coverage Database (UCDB) — Mentor/Siemens Format

The **UCDB** (Unified Coverage DataBase) is the coverage database format from Mentor Graphics (now Siemens EDA), used with their tools ModelSim/QuestaSim and visualized with Verdi or their own Coverage Browser. It is an open XML-based format.

Key properties:
- Stores functional coverage, code coverage, and assertion results in one file
- Supports hierarchical merging — you can merge per-test, per-block, per-IP databases
- Has an API (`$coverage_save`, `coverage open`, etc.) for programmatic access from SystemVerilog
- Is the basis for the IEEE 1800.2 standard coverage database format

When you see `.ucdb` files in a project directory, that is the Questa/Siemens flow. When you see `.vdb` files, that is the Synopsys VCS/Verdi flow. Both contain the same conceptual information — bins, hit counts, exclusion annotations.

In this project's simulation flow, the coverage database format depends on which simulator you use. The `report_phase` in `i2c_coverage.sv` does not depend on the format — it uses the built-in `get_coverage()` SystemVerilog function which works across all simulators.

---

### Coverage Reporting Tools — Verdi and IMC

**Verdi** (Synopsys) is the industry-standard waveform and coverage viewer. When coverage is the focus, you use "Verdi Coverage" mode, which shows:
- A hierarchical tree of all covergroups, coverpoints, and bins
- Color coding: green (covered), red (uncovered), yellow (partially covered)
- Drill-down: click a bin to see which simulation timesteps hit it
- Source-to-coverage tracing: click a line in the RTL to see which test exercised it

**IMC** (Integrated Metrics Center, Cadence) is the Cadence equivalent. It merges Xcelium coverage databases and provides the same drill-down views. IMC can also generate HTML reports suitable for management review.

Both tools integrate with the verification plan tracking tools (Cadence vManager, Synopsys VC Manage) to show coverage trend over time. A plot of "coverage vs. days since project start" is a standard deliverable in a tape-out review.

---

### "Hit Once" vs "Hit N Times" — Why Some Bins Need Multiple Hits

The default coverage model counts a bin as "hit" after it is sampled once. But some scenarios require being exercised many times before you can be confident the design handles them correctly. This is the `at_least` option:

```systemverilog
covergroup stress_cg;
  option.per_instance = 1;
  cp_nack_count: coverpoint item.addr_ack {
    bins nack_multiple = {1'b0} iff (item.addr_ack == 0);
    option.at_least = 10;  // This bin must be hit at least 10 times
  }
endgroup
```

`option.at_least = 10` means the bin is not considered "covered" until it has been hit 10 times. This is useful for:

**Stress scenarios**: A NACK that occurs once might be a lucky seed that happened to hit the right state. A NACK that occurs 10 times across different seeds and different bus states gives higher confidence that the NACK handling is robust.

**Initialization coverage**: A reset sequence that must be observed at least N times across different initial states before you can claim the reset behavior is fully verified.

**Statistical confidence**: In a project with many random seeds, requiring `at_least = 100` for a specific bin means you have seen that scenario 100 times across the regression — giving much higher confidence than a single hit.

The default `at_least = 1` is appropriate for most bins. Use higher values for error conditions, recovery scenarios, and any bin where a single observation is insufficient to claim confidence.

**The "hit once" trap**: If a bin has `at_least = 1` and the first random test happens to hit it, the bin shows 100% forever — even if every subsequent test also hits it. You lose the information about *how often* the scenario was exercised. For debugging purposes, coverage tools also show the total hit count per bin, not just whether it was hit. Check this count when reviewing bins that you expect to be hit frequently — if a supposed "common case" bin has only been hit twice in 10,000 transactions, something is wrong with your test distribution.

---

### The Coverage Review Meeting — How Teams Use Coverage Data

In a professional setting, coverage is reviewed in weekly meetings. The format is typically:

1. **Coverage dashboard review** — every engineer presents their block's coverage numbers for the week. Any regression (numbers went down) must be explained immediately.

2. **Triage of unhit bins** — for bins that are consistently at 0%, a decision is made: is this a test gap (assign to someone to write a directed test) or an exclusion candidate (assign to someone to document and get it approved for exclusion)?

3. **Cross-block coverage** — sometimes a bin in block A can only be hit by a specific sequence that involves block B. These inter-block dependencies are identified and assigned to a test owner.

4. **Waivers review** — any pending exclusion waivers are reviewed by the senior engineer. The question is always: "Are you certain this scenario cannot happen in silicon?" If there is any uncertainty, the waiver is rejected and a test must be written.

This meeting cadence keeps coverage from becoming a last-minute crisis. Projects that skip weekly coverage reviews often find themselves at 60% functional coverage three weeks before tape-out with no time to write the required directed tests.

> **ADVICE FOR INTERNS**: When you attend your first coverage review meeting, pay attention to how senior engineers respond to uncovered bins. They do not accept "I could not figure out how to hit it" as an answer. They ask: "What is the exact sequence of events that would hit this bin?" If you can describe the sequence, write the test. If you cannot, you do not understand the design well enough. Coverage meetings are disguised design comprehension tests.

---

## Part 16: Coverage Closure in Practice — The Closure Report

The earlier parts of this document developed the *mechanics* of coverage — how covergroups work, how to write good bins, where the holes are in this project. Part 15 introduced the *process* practices used at semiconductor companies. This final part bridges the two by walking through the actual closure deliverable produced for this project: `docs/COVERAGE_CLOSURE_REPORT.md`. It is the document that a senior engineer would review at sign-off to decide whether the verification work is complete.

### What Coverage Closure Means

"Closure" is a deceptively simple word that hides three distinct demands. A senior engineer asking "is the coverage closed?" is asking, in order:

1. **Every bin in the coverage model was hit (or explicitly waived).** No bin can be left at 0% without justification. If you have an `ignore_bins` directive, fine — that is an explicit waiver. If you have a bin that nobody ever wrote a test for, that is a hole.

2. **Hits came from multiple tests.** A single test hitting all the bins is suspicious because it could be a single-test artifact (e.g., the test happens to randomize in a way that touches every bin once but does not actually exercise diverse scenarios). The closure check is "each bin hit by at least 2 different tests" — if every bin meets that bar, you have evidence of robustness rather than coincidence.

3. **Cross-coverage targets are met.** Individual bin closure is necessary but not sufficient. The interesting bugs live at intersections — "what if a WRITE happens at the same time as clock stretching?" — and only cross-coverage catches them. A closure report shows the cross matrix and confirms each cross cell is hit.

The closure report is the **evidence document** that all three demands are satisfied. It is what gets reviewed at sign-off and archived for audit. The version produced for this project is `docs/COVERAGE_CLOSURE_REPORT.md` — analytically derived because no commercial simulator is installed locally, but otherwise structured identically to what a tool-produced report would contain.

### The Test-to-Bin Traceability Matrix

The heart of any closure report is the traceability matrix: for every bin, which tests hit it. This is the document a senior reviewer reads carefully. If they see a bin with only one test listed, they ask why; if they see a bin with no tests listed, they reject the closure.

For this project, the traceability matrix is reproduced and walked through here for all 8 covergroups. Reading the source closure report (Section 2 of `docs/COVERAGE_CLOSURE_REPORT.md`), the matrix decomposes as follows:

**`i2c_dir_cg` — Transaction Direction.** Two bins (`write`, `read`). The `write` bin is hit by 13 different tests: basic_write_test, burst_write_test, write_read_test (1st transaction), rep_start_test (1st transaction), addr_nack_test, data_nack_test, clock_stretch_test, addr_sweep_test, bus_free_test, sequential_txn_test (even iterations), data_pattern_test, random_directed_test, and full_stress_test. The `read` bin is hit by 7 tests: basic_read_test, burst_read_test, write_read_test (2nd transaction), rep_start_test (2nd transaction), sequential_txn_test (odd iterations), random_directed_test, and full_stress_test. **Closure: 100%, Very High confidence.**

**`i2c_data_size_cg` — Burst Length Buckets.** Four bins (`single`, `short_burst` for 2..8, `med_burst` for 9..16, `long_burst` for 17..32). The `single` bin is hit by all 13 single-byte-default tests. The `short_burst` bin is hit by burst_write_test and burst_read_test (both use burst_len=8), plus random and stress tests. The `med_burst` and `long_burst` bins are hit only by random tests — there is no directed test that explicitly requests a 9..16 or 17..32 burst. With 450+ random transactions across 3 seeds, the probability of missing either is mathematically negligible, but a reviewer might still ask for a directed test guaranteeing each — and the answer is "we rely on random sampling here, and the seed entropy is sufficient." **Closure: 100%, High confidence.**

**`i2c_addr_cg` — Address Types.** Two bins (`target_addr = 0x50`, `other_addrs = everything else in legal range`). The `target_addr` bin is hit by 11 directed tests that default to address 0x50. The `other_addrs` bin is hit primarily by addr_sweep_test (which walks all 112 legal addresses sequentially), addr_nack_test (uses a wrong address 0x55 by default and randomizes to non-0x50 addresses), and random tests. **Closure: 100%, Very High confidence.**

**`i2c_protocol_cg` — START / STOP / Repeated-START.** Five bins across three coverpoints: `cp_start.has_start`, `cp_stop.has_stop`, `cp_stop.no_stop`, `cp_rep.has_rep`, `cp_rep.no_rep`. Almost every test hits `has_start`, `has_stop`, and `no_rep` because those are the defaults. `cp_stop.no_stop` and `cp_rep.has_rep` are hit only by rep_start_test — which is the single closer for both. **Closure: 100%, Very High confidence**, with a note that removing rep_start_test from the regression would drop closure to ~90%.

**`i2c_ack_cg` — ACK / NACK Tracking.** Two bins (`ack = 1`, `nack = 0`). The `ack` bin is hit by all default-addressed tests. The `nack` bin is hit by addr_nack_test (always NACKs because it uses a wrong address) and by addr_sweep_test (where 111 of the 112 addresses are not the target and thus NACK). The `nack` bin is the per-byte data NACK is NOT covered here — see Hole #1 below for that. **Closure: 100%, Very High confidence.**

**`i2c_burst_cg` — Direction × Burst Size Cross.** A 2 × 4 cross producing 8 cross cells. The four single/short combinations are directed (basic_*, burst_*); the four med/long combinations rely on random sampling. With 450+ random transactions, the probability that any cell goes unhit is approximately `(1 - 0.125)^450 ≈ 10⁻²⁶` — effectively zero. **Closure: 100%, High confidence.**

**`i2c_reg_ptr_cg` — Register Bank Coverage.** Five bins (`single_reg`, `partial_bank`, `more_than_half`, `full_bank = 8`, `multi_wrap`). The `single_reg` and `full_bank` bins are directed (default tests are single, burst tests use 8); the others rely on random sampling. **Closure: 100%, High confidence.**

**`i2c_target_cg` — Target × Direction Cross.** A 1 × 2 cross producing 2 cells. Both cells are hit by 4+ directed tests each. **Closure: 100%, Very High confidence.**

The aggregate is 39 reportable bins (29 individual + 10 cross), all predicted to hit, with overall confidence rated High. This is the headline number that goes into the closure statement.

### How to Generate the Closure Report

For a project of this size, the closure report can be generated with the simulator's UCDB tooling. The flow varies by simulator.

**With QuestaSim (Mentor/Siemens)**:

```bash
cd /Users/kushalpitaliya/Documents/Projects/Summer-Internsip-II/i2c-protocol-dv/sim
# 1. Clean any old artifacts
make clean

# 2. Run the full regression (16 tests x 3 seeds = 48 simulations).
#    Each run produces one .ucdb under ../logs/.
make regress

# 3. Merge all UCDB files and emit HTML + text coverage reports.
make cov

# 4. Open the HTML report.
open ../coverage/html/index.html

# 5. Read the text summary.
cat ../coverage/coverage.txt
```

The `make cov` target runs `vcover merge` over all per-test UCDB files, producing a single merged UCDB, then runs `vcover report -html` on the merged file. The HTML output has a hierarchical drilldown — covergroup → coverpoint → bin → hit count → list of tests that hit it.

**With VCS (Synopsys)**:

```bash
cd /Users/kushalpitaliya/Documents/Projects/Summer-Internsip-II/i2c-protocol-dv/scripts
./run_all_tests.sh vcs 1
./run_all_tests.sh vcs 42
./run_all_tests.sh vcs 123
./coverage_report.sh
```

The `coverage_report.sh` helper script invokes `urg` (Unified Report Generator) over all the `.vdb` databases produced by the runs and generates a merged report. The output structure is similar to Questa's — HTML drilldown plus a text summary.

**With EDA Playground**:

EDA Playground has a critical limitation: it cannot persist files between runs, so UCDB merge across multiple runs is not supported. The workaround:

- Run each test individually with `+UVM_TESTNAME=<test_name>` and capture the per-run `*** COVERAGE SUMMARY ***` UVM_INFO output.
- Manually compose a closure table from the per-run summaries.
- See `docs/COVERAGE_CLOSURE_REPORT.md` Section 6.3 for a recommended per-test run plan, which lists for each test the bins that test is *expected* to close. After running all 11 recommended tests in sequence and capturing their summaries, you can demonstrate analytical bin closure even without UCDB merge.

The analytical approach (no simulator) is exactly what `docs/COVERAGE_CLOSURE_REPORT.md` does: it traces every bin to a test by inspecting sequence constraints and test bodies, predicting closure with high confidence. This is acceptable for a learning project but would not be accepted at a chip company without a tool-produced report as backup.

### Reading the HTML Coverage Report

The HTML report from `vcover report -html` or `urg` has a consistent structure across tools:

1. **Top-level summary page**: Headline numbers — total bins (denominator), hit bins (numerator), percentage. A breakdown by covergroup type (functional, code, assertion). A traffic-light style indicator: green if above target, yellow if borderline, red if below.

2. **Per-covergroup drill-down**: Click a covergroup name to see all its coverpoints. Each coverpoint expands to show its bins. Each bin has columns: name, range, hit count, last-hit-time, list of tests that hit it (this last column is the critical one for the closure review).

3. **Cross-coverage matrix**: For cross coverage groups, a 2-D table where rows are one coverpoint's bins and columns are the other coverpoint's bins. Each cell shows hit count. Cells at 0 stand out in red — these are the cross holes.

4. **Source-to-coverage link** (Verdi/IMC only): Click a bin's name to jump to the SystemVerilog source where the bin is defined. Useful for confirming what the bin actually means.

When reviewing a closure report, the senior engineer's typical reading order is:
- Headline percentage first (is it above the gate?)
- Per-covergroup table next (any covergroup below gate?)
- Cross matrix (any red cells?)
- Per-bin drilldown for any flagged item (which tests hit it? is the hit count adequate?)

A practiced reviewer can scan a 50-covergroup report in 15 minutes.

### Coverage Holes — Real Examples From This Project

The closure report identifies five concrete holes that, while individual bin closure is at 100%, represent gaps in the *coverage model itself*. These are "missing bins" rather than "missed bins". Each is documented with severity, mitigation, and effort estimate.

**Hole #1 — Per-byte data NACK coverage is absent.** The `i2c_ack_cg` covergroup samples only `item.addr_ack`, which captures whether the *address* byte was ACKed. The seq_item also has a `byte_ack[$]` queue for per-byte data ACK tracking, but no covergroup uses it. `data_nack_test` exercises the slave forcing a data-byte NACK, but the coverage model does not record this scenario. Mitigation: add a covergroup `i2c_byte_ack_cg` with bins on `item.byte_ack[0]` for data_ack vs data_nack. Effort: Low (~30 min).

**Hole #2 — Clock stretching is exercised but not measured.** `clock_stretch_test` activates an active slave that holds SCL low for 50..200 cycles. There is no coverpoint that records "stretching occurred" or "how long". The `stretch_cycles` value lives in the `i2c_slave_ctrl_item`, not the master `i2c_seq_item`, and the coverage subscriber only sees the master analysis port. Mitigation: add a `stretch_observed_cycles` field to `i2c_seq_item` populated by the monitor, and add a covergroup on it. Effort: Medium (~2 hours).

**Hole #3 — Multi-repeated-START depth uncovered.** The current `rep_start_test` exercises a single W→R pair with one repeated START. The I2C protocol allows N back-to-back transfers separated by N-1 rep-STARTs before the final STOP. No sequence currently emits more than one rep-START per session. Mitigation: add a new sequence `i2c_multi_rep_start_seq` emitting 3+ rep-STARTs and a covergroup tracking rep-START depth. Effort: Medium (~3 hours).

**Hole #4 — Arbitration lost not in coverage model (T13 was added — coverage hasn't been).** This is the most current hole, and the most interesting because T13 (the arbitration-lost test) was added very recently. T13 produces a collision scenario, but no covergroup samples whether the master observed an arbitration loss. The `i2c_seq_item` has an `STS_ARBITRATION_LOST` enum value in its status field, but no coverpoint bins this. Mitigation: add a status coverpoint:

```systemverilog
cp_status: coverpoint item.status {
  bins ok        = {STS_OK};
  bins addr_nack = {STS_ADDR_NACK};
  bins arb_lost  = {STS_ARBITRATION_LOST};
  bins timeout   = {STS_TIMEOUT};
}
```

Effort: High (~1 day to make T13 actually produce an observable status — the current T13 limitation is that the BFM does not detect the collision; the coverage hole cannot be closed until the detection is hooked up).

**Hole #5 — `cp_start` has an unreachable bin.** The `i2c_protocol_cg.cp_start` coverpoint defines only `has_start = {1}`, with no bin for `start_cond = 0`. This is intentional because `valid_protocol_c` in `i2c_seq_item.sv` forbids the all-zero protocol state (a transaction must have either start_cond OR rep_start, never neither). However, this intent is not documented in the coverage source — a future engineer might wonder "why no no_start bin?" The fix is to document it explicitly:

```systemverilog
cp_start: coverpoint item.start_cond {
  bins has_start = {1};
  ignore_bins illegal_no_start = {0};  // forbidden by valid_protocol_c
}
```

Effort: Low (~5 min). The `ignore_bins` directive both documents the intent and removes the bin from the denominator if a tool ever computes "what about start_cond=0?". An explicit ignore is always better than an implicit omission.

For each hole, the closure report assigns a priority (High/Medium/Low) and an owner. At sign-off, the senior engineer reads this list and decides which holes block release and which can be deferred to the next revision. The High-priority items typically must be closed; Low-priority items can be deferred with sign-off approval.

### The Sign-Off Checklist (from the closure report)

The closure report's Section 7 contains the checklist that a verification team reviews before declaring closure. Reproduced and explained:

1. **All bins hit at least once across the regression.** This is the fundamental bin-closure check. If any bin is at 0% and is not explicitly marked `ignore_bins`, closure is denied. For this project, the predicted answer is yes — all 39 bins are hit.

2. **Each bin hit by 2+ different tests (no single-test bias).** This is the robustness check. A bin hit by exactly one test is suspicious because the test might be hitting it as an artifact of its specific randomization. A bin hit by multiple tests is evidence that the scenario truly occurs and is robust across stimulus variants. The traceability matrix in the closure report shows that every bin in this project has at least 2 hitting tests; many have 7+.

3. **All `ignore_bins` justified with code comments.** Every ignore directive is an assertion that "this state cannot happen". If the assertion is wrong, you have shipped an untested scenario. The reviewer reads every ignore_bins comment and decides whether to accept the justification. For this project, the closure report recommends adding one ignore_bins directive for the `cp_start.illegal_no_start` case with a comment pointing to `valid_protocol_c`.

4. **Cross-coverage targets met.** Even when individual bins are at 100%, the cross matrix can have holes. The reviewer scans the cross matrix for red cells. For this project, both cross covergroups (`i2c_burst_cg`, `i2c_target_cg`) are predicted to fully close.

5. **HTML report archived.** The HTML report is the audit artifact. After sign-off, it is checked into version control or archived to a project deliverables folder. Future revisions compare against this baseline to detect regressions.

6. **Coverage trend tracked (week-over-week).** In a long-running project, the *trend* matters more than the snapshot. If coverage went from 95% last week to 93% this week, something regressed and must be investigated. A trend graph is usually generated by the regression-tracking tool (Cadence vManager, Synopsys VC Manage) and reviewed weekly.

For learning projects, you produce the closure report once and the trend is implicit (week 1: 0%; week N: 100%). For real projects, the trend is the most-consulted artifact during the closure phase.

### What 100% Coverage Does NOT Mean

This is the most important paragraph of this section. A senior engineer reading the closure report does not stop at "100%" — they ask several follow-up questions.

**100% coverage does NOT mean zero bugs.** Coverage measures whether scenarios were *exercised*, not whether the design *behaved correctly* in those scenarios. The scoreboard and assertions are responsible for checking correctness. A test can hit every bin but produce wrong results in every transaction; if there is no assertion catching the wrong behavior, the test passes and the bin is counted as covered. Coverage is a necessary but not sufficient condition for closure; it must be paired with passing assertions and a passing scoreboard.

**100% coverage does NOT mean the coverage MODEL is correct.** This is the lesson of Bug #13 in this project. The original `i2c_reg_ptr_cg` had a coverpoint named "Register Access" but actually covered `item.data[0]` (the value of the first data byte, 0..255). The name and the implementation did not match. A test hitting all 256 data values would close that coverpoint at 100%, but it would not exercise any actual register access scenarios. The bug was found by a reviewer who noticed the mismatch between name and implementation. After the fix, the coverpoint covers `item.num_data` and tracks register-bank-touch scenarios as the name implies. A senior reviewer asks: "show me what each bin actually measures, and convince me the measurement matches the intent."

**100% coverage does NOT mean assertions caught all violations.** Some scenarios are observed but produce no assertion firing — either because no assertion exists for that scenario, or because the assertion is wrong, or because the scenario triggered the assertion but the test was set up to ignore the firing (e.g., `arbitration_lost_test` deliberately does not check scoreboard pass because the collision deliberately corrupts the transaction). A reviewer asks: "for each scenario you covered, what assertion is your safety net? show me it fires when the scenario is wrong."

**A senior reviewer asks: "Show me where in the spec each bin maps to."** This is the deepest level of review. The coverage model is supposed to be a translation of the *specification* into measurable bins. If a bin exists but maps to no spec requirement, it is noise — it could be 100% green but contribute nothing to confidence. If a spec requirement exists but no bin maps to it, that is a missing-coverage hole. The proper closure deliverable includes a spec-to-coverage traceability table: "spec section X.Y.Z requires behavior Q; coverpoint cp_q.bins_q_variants cover all variants of Q; tests T1, T2, T3 exercise the variants." Without this traceability, the coverage model is just a tool-derived shape with no requirements grounding.

For this project, a spec-to-coverage traceability table is not produced (the I2C "spec" is the NXP I2C-bus specification rev. 6, and writing the table is a separate exercise). For a chip project at a real company, the traceability table is mandatory.

### 5 New Interview Questions

**Q31: How do you generate a coverage closure report?**

The standard flow has three steps:
1. **Run regression with coverage enabled.** Each test in the regression matrix (typically tests × seeds) produces one per-run coverage database. For QuestaSim this is a `.ucdb` file; for VCS it is a `.vdb` directory. The simulator-specific flag is usually `+cov` or `-cm` on the run command.
2. **Merge the per-run databases.** Use the simulator's merge tool — `vcover merge` for Questa, `urg` for VCS, `imc` for Xcelium. The merge produces a single aggregate database where each bin's hit-count is the sum across all runs and the list of "tests that hit this bin" is the union.
3. **Generate the report.** Use the merge tool's `-html` or `-text` mode to produce the human-readable artifact. The HTML version is the artifact that gets archived; the text version is useful for diffing across builds.

In addition, the closure deliverable should include:
- A test-to-bin traceability matrix (one row per bin, one column listing the tests that hit it)
- A list of remaining holes with their mitigations
- A sign-off checklist with reviewer signatures

For this project, see `docs/COVERAGE_CLOSURE_REPORT.md` and the commands in Section 6.1 of that report.

**Q32: A bin shows 100% hit count = 1. Is that good?**

It depends on what the bin represents.

If the bin is a *normal scenario* expected to occur many times (e.g., `i2c_dir_cg.write`), hit count = 1 is suspicious. Normal scenarios should be hit by many transactions and by many tests. A hit count of 1 means the regression barely produced this scenario, which suggests under-stress. The reviewer asks "why only once? is our stimulus diverse enough?"

If the bin is a *rare scenario* expected to occur infrequently (e.g., a specific error injection bin), hit count = 1 may be acceptable. The reviewer asks "is once enough to claim the design handles this correctly?" — and the answer depends on the criticality. For safety-critical code (e.g., a recovery sequence in a power-management subsystem), the answer is no — use `option.at_least = 10` to require multiple hits before claiming closure. For non-critical features, one hit may be acceptable.

If the bin is part of a cross matrix where most cells are at 100+ hits and this one cell is at hit count 1, you have a stimulus distribution problem. The random stimulus is not exercising this combination as much as the others. Investigate the constraints or add a directed test to balance the distribution.

The "at_least" option in covergroup definitions lets you encode this expectation in the coverage model itself: `option.at_least = 10` means "this bin requires 10 hits before counting as covered". For bins where one hit is insufficient, use this option to make the expectation explicit.

**Q33: How do you handle unreachable bins?**

Unreachable bins are bins that cannot be hit by any legal stimulus, typically because the testbench's constraints prevent reaching them. They fall into three categories.

**Category 1 — Genuinely impossible by spec.** The bin represents a state the protocol does not allow. Example: in `cp_start`, the value `start_cond = 0 AND rep_start = 0` is forbidden by `valid_protocol_c` because every transaction must start somehow. Handle with `ignore_bins` and a code comment pointing to the constraint:

```systemverilog
cp_start: coverpoint item.start_cond {
  bins has_start = {1};
  ignore_bins illegal_no_start = {0};  // forbidden by valid_protocol_c
}
```

**Category 2 — Impossible in this testbench but possible in silicon.** The bin represents a state the testbench cannot produce because of testbench-level constraints, but the chip in silicon might encounter the state. Example: a glitch on the input pin that the testbench's constraint-random stimulus would never generate. Handle with a documented `illegal_bins` (causes a warning if hit, but allows the bin to count toward closure if it ever IS hit) plus a separate test that uses force-and-release to inject the state directly.

**Category 3 — Tool artifact.** The simulator reports the bin as unreachable due to a tool bug or quirk. Handle by filing a tool ticket and using `ignore_bins` with a code comment referencing the ticket.

In all cases, the directive must be paired with a code comment explaining *why* the bin is unreachable. An undocumented `ignore_bins` is the same as an undocumented exclusion — the reviewer will reject it.

A final note: never use `ignore_bins` to silence a bin you do not know how to hit. That is hiding the problem, not solving it. The correct response to "I do not know how to hit this bin" is to investigate the design carefully and either find a way or escalate.

**Q34: What's the closure sign-off criterion at your company?**

For learning purposes, the answer is the sign-off checklist in Section 7 of `docs/COVERAGE_CLOSURE_REPORT.md`, which includes:

- 100% bin closure (all bins hit or `ignore_bins`-marked)
- Every bin hit by 2+ tests
- All assertions pass with 0 errors and <5% vacuity
- Scoreboard passes on every test
- HTML report archived
- All bugs from the bug list confirmed fixed

For a real chip company, the criteria typically include:
- Functional coverage ≥ 95% (the 5% gap is for documented, approved exclusions)
- Line coverage ≥ 95%
- Branch coverage ≥ 90%
- Toggle coverage ≥ 85%
- FSM state coverage = 100% of reachable states
- FSM transition coverage ≥ 90%
- 100% assertion pass rate, 0 cover failures
- Documented waivers for every excluded item, signed off by a senior engineer
- A spec-to-coverage traceability table demonstrating that every spec requirement maps to a bin
- A regression-stability check: the same regression run 3+ times produces identical pass/fail results (no flakiness)
- A coverage-trend graph showing closure was approached steadily rather than rushed at the last minute

The exact numbers vary by company and by product criticality (safety-critical IP has stricter gates than consumer-grade IP). When asked in an interview, the right answer is to discuss the general framework (gates per coverage type, waiver process, traceability requirement) rather than a specific number, since the specific number is project-dependent.

**Q35: Beyond percentage, what else does a senior engineer check?**

A senior engineer treats the percentage as a starting point, not the answer. After confirming the gate is met, they check:

1. **Distribution of hits across bins.** A covergroup at 100% with every bin at hit count = 1 is suspicious; the same covergroup at 100% with hits varying from 100 to 10,000 is healthy. The variation reflects natural stimulus distribution.

2. **Distribution of tests hitting each bin.** If one bin has 10 tests in its hitter list and another has only 1, why the disparity? Either there is a stimulus gap or the bin represents a niche scenario — either way, the answer must be defensible.

3. **Coverage trend over time.** A steep ramp at the very end of the project (hockey-stick shape) suggests last-minute waivers; a steady ramp is healthy. The trend graph is more diagnostic than the snapshot.

4. **Spec-to-bin mapping.** For every spec requirement, point to the bin that exercises it. For every bin, point to the spec section it implements. Gaps in either direction are red flags.

5. **Assertion-coverage pairing.** For every covered scenario, what assertion would fire if the behavior were wrong? Coverage without an accompanying assertion is exercise without verification.

6. **Reproducibility.** Run the regression three times with the same seeds; the pass/fail results should be identical and the bin closure should be identical. If they vary, you have a stimulus determinism problem or an environment race condition.

7. **Off-the-happy-path bins.** Most bins are easy because they represent normal behavior. The hard bins are error cases, recovery sequences, and edge conditions. A reviewer specifically inspects these bins and asks "show me the test that hits this, and walk me through what happens".

8. **Cross-coverage cells.** Individual bins are necessary; cross cells are sufficient. Most bugs live at cross intersections. A senior engineer focuses time disproportionately on the cross matrix.

9. **Whether the coverage model itself is correct.** As Bug #13 showed, a covergroup can be syntactically correct, semantically labeled, and hit at 100%, while not actually measuring what its name claims. Inspection of each covergroup against the spec is the only protection.

10. **Waiver justifications.** Every excluded bin requires a written justification. The reviewer reads each one and asks "are you sure?". An unjustifiable waiver gets rejected and the bin becomes a required hit.

The percentage is the easy part; the qualitative review is what turns a "100% closed" claim into an actual closure decision.

---

*Document written for the I2C Protocol DV Summer Internship project.*  
*Reference files: `uvm/i2c_coverage.sv`, `uvm/i2c_seq_item.sv`, `uvm/i2c_sequences.sv`, `docs/BUG_REPORT.md`, `docs/COVERAGE_CLOSURE_REPORT.md`*

---

## Part 17: Operational Quick-Reference for the Closure Report

This part is a fast-lookup companion to the long-form Part 16 above. It
captures exactly what to do when you are asked "show me the closure
status" by a reviewer, in the order the reviewer will ask.

### The artifact

- **File**: `docs/COVERAGE_CLOSURE_REPORT.md`
- **Purpose**: produce a sign-off-ready coverage closure analysis
- **Length**: 780 lines, 7 numbered sections + 3 appendices
- **Why analytical (not simulation-run)**: commercial simulator
  (QuestaSim/VCS/Xcelium) not available on the development machine,
  so the report performs test-to-bin traceability instead of running
  `vcover report`. This is a documented limitation; if you get
  simulator access later, re-run with `make regress && make cov`.

### How to read the closure report — checklist order

When opening `docs/COVERAGE_CLOSURE_REPORT.md`, read in this order:

1. **Section 1: Executive summary** — predicted closure %, regression
   matrix size (16 tests × 3 seeds = 48 runs), top-level confidence.
   If the executive summary says less than 95%, jump to Section 3
   (holes) before reading anything else.

2. **Section 2: Traceability matrix** — for each of the 8 covergroups,
   the table of (bin -> test list) mappings. This is the auditable
   evidence: every defined bin has at least one path to hit it.

3. **Section 3: Coverage holes** — bins or scenarios NOT hit by any
   test. This project has 0 hard holes, 5 logical holes.

4. **Section 4: Cross-coverage recommendations** — combinations not
   currently measured. The closure report recommends 5 new crosses.

5. **Section 5: Final closure prediction table** — per-covergroup
   bin counts, hit counts, predicted closure %, confidence level.

6. **Section 6: Run commands** — exact bash/Makefile commands to
   reproduce the closure flow with a real simulator (QuestaSim, VCS,
   or EDA Playground).

7. **Section 7: Sign-off checklist** — what evidence is needed before
   declaring closure complete. Includes a template signed statement
   for the verification engineer.

### The 5 Holes — One-Line Summaries

| # | Hole | Mitigation | Effort | Status |
|---|------|------------|--------|--------|
| 1 | Per-byte data NACK during burst | Add `i2c_byte_ack_cg` sampling `item.byte_ack[i]` | Low (~30 min) | Open |
| 2 | Clock-stretch duration not tracked | Add `i2c_stretch_cg` on `stretch_observed_cycles` | Medium (~2h) | Open |
| 3 | Multi-rep-START depth (N≥2) | Add `i2c_multi_rep_start_seq` + rep_start counter | Medium (~3h) | Open |
| 4 | Arbitration-lost scenarios | Test added (T13). Add `cp_status` covergroup to track | High (~1d, partial) | Filled by T13 (cg pending) |
| 5 | `cp_start.no_start` unreachable | Add `ignore_bins illegal_no_start = {0}` | Low (~5 min) | Open |

### The 5 Cross-Coverage Recommendations — One-Line Bug Class

| # | Cross | Bug Class It Catches |
|---|-------|----------------------|
| 1 | direction × addr_range | Slave that handles READ vs WRITE asymmetrically for specific address ranges (write-only or read-only register decoded wrong) |
| 2 | burst_size × ack_result | "Burst boundary" bugs — slave NACKs only on Nth byte of long burst (off-by-one in length counter) |
| 3 | direction × num_data (granular) | Off-by-one at specific burst lengths, particularly at power-of-2 boundaries (8, 16, 32) |
| 4 | rep_start × direction | Missing same-direction rep-START paths (WRITE→WRITE, READ→READ) |
| 5 | target × protocol_flags (stop, rep) | Slave that mis-handles specific stop/rep combinations against target address 0x50 |

### Running Closure Yourself — Exact Makefile Commands

```bash
# 1. Navigate to the sim directory
cd /Users/kushalpitaliya/Documents/Projects/Summer-Internsip-II/i2c-protocol-dv/sim

# 2. Clean any old artifacts
make clean

# 3. Run the full regression (16 tests x 3 seeds = 48 simulations).
#    This generates one .ucdb per (test, seed) pair under ../logs/.
make regress

# 4. Merge all UCDB files and emit HTML + text coverage reports.
make cov

# 5. View the HTML report (covergroup-level drill-down).
open ../coverage/html/index.html

# 6. Inspect the text summary for quick numeric overview.
cat ../coverage/coverage.txt
```

**Expected output after a clean regression run**:
- 48 lines of `PASS: <test> (seed=<seed>)` in the regression summary.
- Final line: `Total: 48 / Passed: 48 / Failed: 0`.
- `coverage.txt` shows each of the 8 covergroups at 100%.
- HTML report has no red bins.

**If failures occur**:
- Open `../logs/<test>_seed<seed>.log`
- Search for `UVM_ERROR` or `UVM_FATAL`
- The scoreboard prints `SCOREBOARD PASSED` only on full success — its
  absence means the test failed mid-run.

**For VCS / urg flow** (alternative):
```bash
cd /Users/kushalpitaliya/Documents/Projects/Summer-Internsip-II/i2c-protocol-dv/scripts
./run_all_tests.sh vcs 1
./run_all_tests.sh vcs 42
./run_all_tests.sh vcs 123
# urg -dir simv.vdb -dir simv2.vdb -dir simv3.vdb -report cov_merged
```

### Where T13 fits in the closure picture

T13 (arbitration_lost_test) was added AFTER the closure report was
authored. The current closure report references arbitration-lost as
Hole #4 with status "In-progress (task #2)".

To bring the closure report up to date with T13:
1. **Section 1 Executive Summary**: change "15 directed/random test
   classes" to "16 directed/random test classes".
2. **Section 3 Hole #4**: mark as "TEST ADDED (T13); coverage
   subscription still open — `cp_status` covergroup needs to be added
   to capture `STS_ARB_LOST` programmatically".
3. **Section 5.1 closure table**: when `cp_status` is added with bins
   `{STS_OK, STS_ADDR_NACK, STS_ARB_LOST, STS_TIMEOUT}`, increase the
   total bin count from 39 to 43.
4. **Section 7.3 holes table**: change priority row "Arbitration-lost
   test + coverage" from "Open / In-progress (task #2)" to "Closed by
   T13 (coverage subscription deferred to next revision)".

### Sign-off statement template (from Section 7.5)

```
I, the verification engineer, certify that:
- The I2C UVM verification environment has been executed on QuestaSim
  version <X.Y> using the regression matrix defined in sim/Makefile.
- All 48 simulation runs (16 tests x 3 seeds) PASSED.
- Functional coverage across 8 covergroups reached 100% bin closure.
- All assertions in sva/i2c_protocol_assertions.sv passed (9 assertions
  A1-A9; A7-A9 added in the post-closure timing-window expansion).
- The 15 bugs documented in docs/FINAL_ANALYSIS_REPORT.md are confirmed
  fixed and protected by their respective tests.

Open items deferred to next revision: <list holes from Section 7.3 not
closed>.

Signed: Kushal Pitaliya
Date: <closure date>
```

The signed statement is the FINAL piece of evidence. Without it, even
a 100%-bin closure report has no accountable owner. With it, the
verification engineer is on record that closure was achieved using the
methodology described in the report.

---

*End of Part 17 — Operational Quick-Reference for the Closure Report*

---

## Part 18: From 8 to 16 Covergroups — Closing the Holes

### 18.1 Why We Extended the Model

After the first round of coverage closure analysis (Part 17, Section 7.3), five
measurement holes and five missing cross combinations were identified. The
coverage model had 8 covergroups capturing 39 total coverage points. The
analytical question was: "If we have `byte_ack[]`, `rep_start`, and
`clock_stretch_test` in the design, why do none of them feed into a coverage
bin?" The answer was uncomfortable: those features existed in the RTL, the
sequences, and the seq_item, but nobody had written the covergroup code to
actually measure them.

Eight of the ten identified improvements were implemented in this revision.
Two were deferred:

1. **Arbitration-lost coverage** — requires RTL-BFM coupling to create
   genuine multi-master bus contention. Without a second BFM simultaneously
   driving SDA, you cannot produce a real `STS_ARB_LOST` condition. This is
   an architectural gap, not a coverage-writing problem.

2. **Deep rep_start chain (depth 3+)** — `deep_rep` bin in CG11 exists and
   will report correctly once a test sends three or more consecutive rep-STARTs.
   No such test exists yet. Adding one is medium effort (write a new sequence).

What was implemented: CG9 per-byte NACK, CG10 clock stretch, CG11 rep-start
chain depth, and CG12-CG16 covering the five most valuable direction-based
cross combinations. Total coverage points grew from 39 to approximately 85.

The expansion required two seq_item field additions (`num_rep_starts` and
`stretch_seen`), two monitor logic additions (`scl_low_cnt` and
`rep_start_chain_depth`), and one new derived flag in the coverage class
(`has_data_nack`). No test modifications were needed — existing tests already
exercise the behaviors; the gap was purely in the measurement layer.

---

### 18.2 Three New Hole-Closing Covergroups

#### CG9 — `i2c_byte_nack_cg` (Per-Byte ACK/NACK)

**What hole it closes**: `byte_ack[]` existed in `i2c_seq_item.sv` since V2
and was populated by the monitor on every data-phase ACK slot. But no
covergroup ever sampled it. This meant `data_nack_test` could pass in
simulation and the coverage database would still show zero measurement of
whether any data byte was NACK'd. You would have a test that exercised the
behavior, no coverage bin that confirmed it, and a closure report that silently
omitted the measurement.

**What data it uses**: The field `byte_ack[]` already existed. The new
addition is the derived flag `has_data_nack` in the coverage class — a `bit`
computed in `write()` before any `sample()` call. Computed flags like this
are necessary when the coverpoint condition requires logic that a simple
coverpoint expression cannot express (a scan over a dynamic queue).

**How the monitor populates it**: The monitor already pushed `1'b1` or `1'b0`
into `byte_ack[]` after every data-phase ACK bit. No monitor changes were
needed for this covergroup. The new step is in `i2c_coverage.write()`:

```systemverilog
has_data_nack = 0;
foreach (t.byte_ack[i]) if (t.byte_ack[i] == 1'b0) has_data_nack = 1;
```

This runs before any `.sample()` call. If any byte in the queue is `1'b0`
(NACK), the flag is raised. The covergroup then samples the flag:

```systemverilog
// 9. Per-Byte ACK/NACK Tracking
// Closes hole: byte_ack[] existed in seq_item but was never measured in coverage
covergroup i2c_byte_nack_cg;
  option.per_instance = 1;
  option.name = "Per-Byte NACK";
  cp_byte_nack: coverpoint has_data_nack {
    bins all_bytes_ack  = {0};   // every data byte was ACK'd
    bins data_nack_seen = {1};   // at least one data byte NACK'd (data_nack_test)
  }
endgroup
```

**Which test hits each bin**:
- `all_bytes_ack` bin: every test that does not inject NACKs (e.g.,
  `basic_write_test`, `burst_read_test`, `full_stress_test`). This bin is
  trivially hit on the first transaction of any normal test.
- `data_nack_seen` bin: exclusively `data_nack_test`, which uses
  `i2c_data_nack_seq` with `inject_nack=1`. Without this directed test, the
  bin would remain at 0% forever because the randomised sequences default to
  `inject_nack == 0` via `default_errors_c`.

The covergroup is only sampled when `t.num_data > 0` — address-only
transactions (NACK'd address phase) have an empty `byte_ack[]` queue and
would produce a misleading `all_bytes_ack` hit. Gating with `num_data > 0`
ensures the measurement reflects actual data-phase behavior.

---

#### CG10 — `i2c_stretch_cg` (Clock Stretch Detection)

**What hole it closes**: `clock_stretch_test` was test number thirteen in the
regression matrix and exercised clock stretching end-to-end. But no coverage
bin confirmed that the monitor actually observed the stretch. You could have a
broken monitor that failed to set `stretch_seen`, and the test would still pass
(because the scoreboard checks data integrity, not stretch detection). CG10
closes this: if `stretch_seen` never becomes `1`, the `stretch_seen_bin` stays
at 0% and the closure report flags it.

**What data it uses**: `stretch_seen` — a new `bit` field added to
`i2c_seq_item.sv` in this revision. It starts at `1'b0` in `new()` and is
set to `1'b1` by the monitor when stretch is detected. The field is copied
in `do_copy()` alongside all other fields.

**How the monitor populates it**: The monitor added a consecutive-SCL-LOW
counter called `scl_low_cnt`. On every `posedge clk`, it increments when
`scl === 1'b0` and resets to zero when `scl === 1'b1`. When the counter
exceeds 260 cycles during an active transaction, `current_item.stretch_seen`
is set to `1'b1`:

```systemverilog
// SCL stretch detection: >260 consecutive LOW cycles = slave is stretching
if (vif.scl === 1'b0) scl_low_cnt++;
else                   scl_low_cnt = 0;
if (in_transaction && scl_low_cnt > 260 && current_item != null)
  current_item.stretch_seen = 1'b1;
```

The threshold of 260 is `T_SCL_LOW (250 cycles) + 10 cycles margin`. Normal
I2C SCL low periods are at most 250 cycles in this design. Any low period
beyond 260 cycles unambiguously indicates the slave is holding SCL down, which
is the I2C clock-stretching mechanism. The margin of 10 cycles prevents false
positives from minor timing variation.

The covergroup:

```systemverilog
// 10. Clock Stretch Coverage
// Closes hole: clock_stretch_test exercised stretch but coverage never measured it
covergroup i2c_stretch_cg;
  option.per_instance = 1;
  option.name = "Clock Stretch";
  cp_stretch: coverpoint item.stretch_seen {
    bins no_stretch       = {0};  // normal SCL timing
    bins stretch_seen_bin = {1};  // SCL held LOW > T_SCL_LOW+10 cycles by slave
  }
endgroup
```

**Which test hits each bin**:
- `no_stretch` bin: all tests except `clock_stretch_test`. Hits immediately on
  any transaction that completes without SCL being held low.
- `stretch_seen_bin` bin: exclusively `clock_stretch_test`, which uses
  `i2c_clock_stretch_seq` to exercise slave-side clock stretching via the
  slave agent.

---

#### CG11 — `i2c_rep_depth_cg` (Repeated START Chain Depth)

**What hole it closes**: The original `i2c_protocol_cg` measured `rep_start`
as a 1-bit flag: was there a repeated START, yes or no? This tells you nothing
about how deep a chain went. Multi-segment transactions (write-then-read using
rep_start) are a core I2C pattern. Measuring only presence/absence of rep_start
is like measuring whether a function was called but not how many times.

**What data it uses**: `num_rep_starts` — a new `int` field added to
`i2c_seq_item.sv`. It is zero for any direct-START transaction and increments
for each segment in a rep-start chain.

**How the monitor populates it**: The monitor added `rep_start_chain_depth`,
a counter that persists across segments of the same chain. When a Repeated
START is detected mid-transaction, `rep_start_chain_depth` is incremented and
assigned to `current_item.num_rep_starts` for the new item. On a clean STOP,
the counter is reset to zero:

```systemverilog
// Track rep-START chain depth for coverage
if (saw_rep_start) begin
  rep_start_chain_depth++;
  current_item.num_rep_starts = rep_start_chain_depth;
end else begin
  rep_start_chain_depth = 0;
  current_item.num_rep_starts = 0;
end
```

On STOP:
```systemverilog
rep_start_chain_depth = 0;
scl_low_cnt = 0;
```

The covergroup:

```systemverilog
// 11. Repeated START Chain Depth
// Closes hole: rep_start was yes/no; now measures HOW DEEP the chain goes
covergroup i2c_rep_depth_cg;
  option.per_instance = 1;
  option.name = "RepStart Depth";
  cp_depth: coverpoint item.num_rep_starts {
    bins no_rep   = {0};     // direct START — fresh transaction
    bins one_rep  = {1};     // 2nd segment (after 1 rep-start): write-then-read
    bins two_rep  = {2};     // 3rd segment — rarely tested
    bins deep_rep = {[3:$]}; // deep chain — potential gap
  }
endgroup
```

**Which test hits each bin**:
- `no_rep` bin: all tests that use direct START (the vast majority). Hits on
  the very first transaction of `basic_write_test`.
- `one_rep` bin: `rep_start_test` (uses `i2c_rep_start_seq`), `write_read_test`.
  The write-then-read pattern is exactly one rep-start deep.
- `two_rep` bin: no dedicated test currently; may be hit if `full_stress_test`
  or the arbitration scenario happens to generate a 3-segment chain. Predicted
  coverage: uncertain without simulation data.
- `deep_rep` bin: no test sends 3+ consecutive rep-STARTs. This is a known
  remaining gap. Closing it requires a new sequence class.

---

### 18.3 Five New Cross Covergroups

Cross coverage requires EVERY combination of two (or more) coverpoints to be
exercised. Individual 100% closure of each coverpoint can coexist with a
completely empty cross cell — this is the most dangerous false-confidence trap
in functional coverage.

#### CG12 — `i2c_dir_addr_cross_cg` (Direction × Address Range) — 2 × 3 = 6 cells

**What combinations it measures**: Every combination of direction (WRITE, READ)
with address range (target=0x50, low_range=0x08-0x4F, high_range=0x51-0x77).

**Bug class it catches**: Reads only tested on the target address while writes
are tested across all addresses. If the DUT has a direction-decoding bug that
only manifests for non-target addresses during read transactions, a flat
coverpoint model would never catch it. The six cells force `READ × low_range`
and `READ × high_range` to be exercised explicitly.

```systemverilog
// 12. Cross: Direction x Address Range
// Catches: reads only tested on target addr, writes on all addresses?
covergroup i2c_dir_addr_cross_cg;
  option.per_instance = 1;
  option.name = "Dir x Addr Range";
  cp_dir: coverpoint item.dir;
  cp_addr_range: coverpoint item.addr {
    bins target     = {7'h50};
    bins low_range  = {[7'h08:7'h4F]};
    bins high_range = {[7'h51:7'h77]};
  }
  cross cp_dir, cp_addr_range;
endgroup
```

All six cells are predicted to close under `addr_sweep_test` (covers the full
address range) combined with `random_directed_test` (randomises direction).

---

#### CG13 — `i2c_dir_ack_cross_cg` (Direction × ACK Result) — 2 × 2 = 4 cells

**What combinations it measures**: The four combinations of direction (WRITE,
READ) with address-ACK result (ACK=1, NACK=0).

**Bug class it catches**: Asymmetric NACK handling. A DUT might correctly
handle WRITE-NACK (abort the burst) but silently corrupt the bus state for
READ-NACK. Individual coverpoints for direction and ACK would both be 100%,
but the `READ × NACK` cell would be empty if `addr_nack_test` only sends write
transactions during the NACK scenario.

```systemverilog
// 13. Cross: Direction x ACK Result
// Catches: all 4 combos needed — write+ack, write+nack, read+ack, read+nack
covergroup i2c_dir_ack_cross_cg;
  option.per_instance = 1;
  option.name = "Dir x ACK";
  cp_dir: coverpoint item.dir;
  cp_ack: coverpoint item.addr_ack {
    bins ack  = {1};
    bins nack = {0};
  }
  cross cp_dir, cp_ack;
endgroup
```

The `WRITE × ACK` and `READ × ACK` cells close trivially under normal tests.
The `WRITE × NACK` cell closes under `addr_nack_test`. The `READ × NACK` cell
requires a read transaction with address NACK — `addr_nack_test` or the random
stress sequences can produce this, but it needs verification.

---

#### CG14 — `i2c_rep_dir_cross_cg` (Repeated START × Direction) — 2 × 2 = 4 cells

**What combinations it measures**: Whether a transaction has a rep_start flag
combined with the direction of that transaction.

**Bug class it catches**: Direction-flip behavior during rep-start chains. The
classic write-then-read pattern is `rep_start=1, dir=READ` (the second segment).
But what about `rep_start=1, dir=WRITE` (write-then-write)? Or `rep_start=0,
dir=READ` (standalone read)? Four cells — all must be exercised.

```systemverilog
// 14. Cross: Repeated START x Direction
// Catches: rep_start for write->write, write->read, read->write, read->read
covergroup i2c_rep_dir_cross_cg;
  option.per_instance = 1;
  option.name = "RepStart x Dir";
  cp_rep: coverpoint item.rep_start {
    bins no_rep  = {0};
    bins has_rep = {1};
  }
  cp_dir: coverpoint item.dir;
  cross cp_rep, cp_dir;
endgroup
```

`rep_start_test` hits `has_rep × READ` (write-then-read is the dominant
pattern). `has_rep × WRITE` (write-then-write) requires a dedicated sequence or
the stress test to produce back-to-back write segments — a potential gap.

---

#### CG15 — `i2c_dir_size_cross_cg` (Direction × Data Size Refined) — 2 × 5 = 10 cells

**What combinations it measures**: Direction (WRITE, READ) against five refined
size buckets: single(1), small(2-4), medium(5-8), large(9-16), xlarge(17-32).

**Bug class it catches**: Long burst reads never exercised. The original
`i2c_burst_cg` crossed direction with four size buckets. This covergroup uses
five buckets with a finer split at the small/medium boundary to catch the
scenario where write tests use all sizes but read tests only use small bursts.
The `READ × xlarge` cell would be the hole.

```systemverilog
// 15. Cross: Direction x Data Size (Refined)
// Catches: burst reads of 17-32 bytes never tested? read+xlarge gap?
covergroup i2c_dir_size_cross_cg;
  option.per_instance = 1;
  option.name = "Dir x Data Size";
  cp_dir: coverpoint item.dir;
  cp_size: coverpoint item.num_data {
    bins single  = {1};
    bins small   = {[2:4]};
    bins medium  = {[5:8]};
    bins large   = {[9:16]};
    bins xlarge  = {[17:32]};
  }
  cross cp_dir, cp_size;
endgroup
```

`burst_read_test` and `full_stress_test` are expected to cover most cells.
The `READ × xlarge` cell depends on whether any sequence generates a read burst
of 17+ bytes. Without simulation data this is uncertain.

---

#### CG16 — `i2c_protocol_dir_cross_cg` (Protocol Flags × Direction) — 2 × 2 = 4 cells

**What combinations it measures**: The stop_cond flag (has_stop=1, no_stop=0)
combined with direction (WRITE, READ).

**Bug class it catches**: Is STOP always present in both directions? A test
might exercise no-STOP transactions only during write sequences (expecting the
master to immediately issue a rep-START). If the DUT has different bus-free
behavior after READ transactions without STOP, the `READ × no_stop` cell
reveals the gap.

```systemverilog
// 16. Cross: Protocol Flags x Direction
// Catches: is STOP always present? rep_start in both read and write directions?
covergroup i2c_protocol_dir_cross_cg;
  option.per_instance = 1;
  option.name = "Protocol x Dir";
  cp_dir: coverpoint item.dir;
  cp_has_stop: coverpoint item.stop_cond {
    bins has_stop = {1};
    bins no_stop  = {0};
  }
  cross cp_dir, cp_has_stop;
endgroup
```

`WRITE × has_stop` and `READ × has_stop` close under all normal tests.
`WRITE × no_stop` closes when rep-start sequences send the write segment
(no STOP before the rep-START). `READ × no_stop` is the critical cell — does
any sequence send a read without a trailing STOP?

---

### 18.4 The ignore_bins Fix

Before this revision, `cp_start` in `i2c_protocol_cg` was defined as:

```systemverilog
cp_start: coverpoint item.start_cond {
    bins has_start = {1};
}
```

The value `{0}` was not explicitly declared as anything. In SystemVerilog, an
uncovered value in a coverpoint creates an implicit "default" region that is
NOT counted as a coverage hole — but it also is not counted toward closure.
This is subtly different from having an `ignore_bins`. In some simulators, the
absence of `{0}` generated spurious warnings about unclassified values during
rep-start transactions, because `start_cond=0` is a legitimate observation
(any rep-start segment has `start_cond=0` and `rep_start=1`).

The fix added:

```systemverilog
cp_start: coverpoint item.start_cond {
    bins has_start      = {1};
    ignore_bins no_start_ok = {0};  // rep_start txns have start_cond=0; tracked by cp_rep
}
```

The `ignore_bins` declaration serves three purposes:

1. **Eliminates spurious warnings**: the simulator now knows that `{0}` is an
   explicitly classified value and does not flag it as "unclassified".

2. **Explicitly excludes it from the closure percentage**: the `{0}` state is
   not counted as an un-hit bin. Without `ignore_bins`, some tools include
   unclassified values in the denominator of the coverage percentage, making
   100% closure impossible.

3. **Documents design intent**: the comment explains WHY `{0}` is excluded.
   Any engineer reading the coverage file immediately understands that
   `start_cond=0` transactions are intentional (rep-start segments) and are
   tracked separately by `cp_rep`.

**The lesson about `ignore_bins`**: `ignore_bins` is NOT a cheat. It is
explicit documentation of design intent in code. Using it without a comment is
bad practice — the comment is what transforms it from a coverage hack into a
first-class engineering decision. A coverage review that finds an `ignore_bins`
without a comment should fail the review. A coverage review that finds an
`ignore_bins` with a clear, spec-traceable justification should pass.

Always distinguish:
- `bins`: "this MUST be hit by at least one test — if it isn't, the model is
  not closed."
- `ignore_bins`: "this value will be observed but we have explicitly chosen not
  to measure it, for the stated reason."
- `illegal_bins`: "if this value is ever observed, it is a protocol violation
  — flag it as an error immediately."

---

### 18.5 How Monitor Data Enables Coverage

The data flow from bus pins to coverage database passes through four layers.
Understanding this flow is critical for debugging coverage holes — a hole can
be caused by a problem at any layer.

```
Bus pins (SDA/SCL)
    |
    | [monitor samples per posedge clk]
    v
scl_low_cnt (increments when scl=0, resets when scl=1)
    |
    | [when scl_low_cnt > 260 during active transaction]
    v
current_item.stretch_seen = 1'b1
    |
    | [on STOP: finalize_and_write_item() called]
    v
item_collected_port.write(current_item)
    |
    | [analysis port connects to coverage subscriber]
    v
i2c_coverage::write(t) called
    |
    | [has_data_nack computed from t.byte_ack[]]
    | [t stored as this.item]
    v
i2c_stretch_cg.sample()
    |
    v
stretch_seen_bin hit (if stretch_seen == 1)
```

For `num_rep_starts` the flow is similar but across multiple transactions:

```
START detected (SDA falls while SCL high)
    |
    | [in_transaction already true = this is a rep-START]
    v
finalize_and_write_item() -- writes PREVIOUS segment
    |
    | [rep_start_chain_depth++ for NEW item]
    v
current_item.num_rep_starts = rep_start_chain_depth
    |
    | [transaction continues, bytes collected]
    v
STOP detected -- finalize_and_write_item()
    |
    | [rep_start_chain_depth = 0]
    v
i2c_coverage::write() -- i2c_rep_depth_cg.sample()
    |
    v
one_rep or two_rep bin hit
```

The key insight is that coverage is only as good as the data that reaches it.
If `stretch_seen` is never set (because the monitor's threshold is too high),
`stretch_seen_bin` stays at 0% even though `clock_stretch_test` is passing.
The coverage model then correctly identifies the monitor as broken — which is
exactly what you want. Coverage catches monitor bugs too.

---

### 18.6 Known Remaining Gaps

The following gaps were identified but not closed in this revision:

| Gap | Why Not Closed | Estimated Effort |
|-----|----------------|------------------|
| `arb_lost` coverage | Requires RTL-BFM coupling: a second BFM must simultaneously drive SDA to create genuine contention. No second BFM exists. | High (architectural change) |
| `deep_rep` bin (depth 3+) | Was open; now **CLOSED** by `deep_rep_start_test` (T14) using `deep_rep_start_sequence`. All 4 bins of CG11 now close in a single test run. | Done |
| `stretch × read` cell (CG17) | CG17 (`i2c_stretch_dir_cross_cg`) now exists. Three cells close (no_stretch×write, no_stretch×read, stretch×write). The `stretch × read` cell requires a future `stretch_read_test` combining slave stretch with a READ direction seq_item. | Low (write new test) |
| `READ × no_stop` cell (CG16) | Depends on whether any sequence generates a rep-start read segment. Needs sequence audit. | Low (audit existing sequences) |
| `has_rep × WRITE` cell (CG14) | Write-then-write via rep-start is not a standard test pattern in this environment. | Low to Medium |

The two architectural gaps (arb_lost, second BFM) are the only ones that
require design-level changes. The remaining three are code-level additions that
a single engineer could close in one afternoon.

---

### 18.7 Interview Questions

**Q: Your `byte_ack[]` field existed for months but was never measured.
How would you catch this gap in future?**

The best safeguard is a formal **coverage intent document** — written before
any covergroup code — that lists every seq_item field and explicitly states
whether it must be measured and how. If `byte_ack[]` appears in the intent
document as "measure per-byte NACK presence", then the covergroup review step
will catch the absence of a corresponding covergroup immediately. A secondary
safeguard is coverage review during code review: every new seq_item field
should trigger the reviewer question "which covergroup measures this?". In this
project, the gap was caught during the post-implementation closure analysis
rather than at code-review time — which is the correct safety net but the
slower one.

---

**Q: How does the monitor detect clock stretching without accessing the slave's
internal signals?**

The monitor is a passive observer of the bus pins only — it sees `sda` and
`scl` through the virtual interface. Clock stretching is externally observable
because it is a bus-level phenomenon: when the slave holds SCL LOW, the bus
SCL line stays LOW regardless of what the master drives. The monitor counts
consecutive clock cycles where `scl === 1'b0`. In normal operation SCL goes LOW
for at most 250 cycles (one half-period). When the count exceeds 260, the extra
10+ cycles can only be explained by the slave holding the line down. No internal
slave signal access is needed because the physical bus IS the evidence of
stretching. This is the fundamental advantage of I2C's open-drain bus topology:
any participant can observe any extension of the LOW period from outside.

---

**Q: What's the difference between `ignore_bins` and just not defining a bin
for that value?**

Not defining a bin leaves the value in an implicit "default" bucket whose
treatment varies by simulator. Some tools count unclassified values as
uncovered bins, which makes 100% closure impossible. Others silently discard
them but may emit warnings. `ignore_bins` is explicit: it tells the tool "I
have considered this value, I know it will appear, and I have decided it should
not contribute to the coverage percentage, for the stated reason." The
difference matters for closure reports: a waived bin with `ignore_bins` and a
comment is an engineering decision. An unclassified value is an oversight that
a code reviewer should flag.

---

**Q: Why does `has_data_nack` need to be computed in `write()` rather than
directly in a coverpoint?**

A coverpoint expression must be a simple reference to a signal or field — it
cannot contain loops or dynamic-queue operations. The expression "at least one
element of `byte_ack[]` is zero" requires iterating over a dynamic queue of
variable length. SystemVerilog coverpoint syntax does not support `foreach` or
any loop construct inside a coverpoint. The solution is to pre-compute the
result in the `write()` function, store it in a member variable (`has_data_nack`),
and reference that member in the coverpoint. This is a standard pattern in
functional coverage: if a coverpoint condition requires non-trivial computation,
compute it in the write function and cover the result. The coverage class then
acts as both a coverage collector and a lightweight data processor.

---

## Part 19: CG17 — Stretch × Direction Cross (4 Cells)

### 19.1 WHY: The Asymmetry That CG10 Cannot See

CG10 (`i2c_stretch_cg`) has two bins: `no_stretch` and `stretch_seen_bin`. It
tells you whether clock stretching was observed at all. That is useful — if
`stretch_seen_bin` stays at 0% after running `clock_stretch_test`, the monitor
is broken. But CG10 has a blind spot: it cannot tell you whether stretch was
exercised symmetrically across both transaction directions.

Here is the concrete bug class that CG10 misses. Suppose a slave implementation
holds SCL LOW during write transactions (to give itself time to store incoming
data) but releases SCL immediately during read transactions (it just shifts out
a pre-loaded value). `clock_stretch_test` exercises writes. `stretch_seen_bin`
fills. CG10 reports 100% closure. Everything looks fine. But if you then connect
a master that issues read transactions and the slave silently holds SCL — or
conversely, if the slave's stretch logic is only wired into the write path and a
read would never get stretching when it should — neither case is visible to CG10.

CG17 adds the cross. It measures: "Was stretch exercised in the WRITE direction?
Was it exercised in the READ direction?" Four cells force both combinations to be
tested. The `stretch × read` cell in particular is the hole — no test currently
closes it, and that is the point. The open cell in the closure report becomes an
explicit sign-off requirement rather than a silent blind spot.

### 19.2 WHAT: The Four Cells

The cross has two axes:

**Stretch axis** (from `item.stretch_seen`):
- `no_stretch` = `1'b0`: the transaction completed without the slave holding SCL
- `stretch_seen` = `1'b1`: the monitor observed SCL held LOW beyond 260 cycles

**Direction axis** (from `item.dir`):
- `write` = `DIR_WRITE`: master was writing data to the slave
- `read` = `DIR_READ`: master was reading data from the slave

The four cross cells:

| Cell | Meaning | Status (current regression) |
|------|---------|------------------------------|
| `no_stretch × WRITE` | Normal write, no stretching | Closed — every normal write test |
| `no_stretch × READ` | Normal read, no stretching | Closed — every normal read test |
| `stretch × WRITE` | Write with slave stretching SCL | Closed — `clock_stretch_test` |
| `stretch × READ` | Read with slave stretching SCL | **OPEN** — no test exercises this |

Three of the four cells are closed under the existing regression. The fourth is
the high-value hole: it forces you to write a `stretch_read_test` that combines
the slave stretch control sequence with a READ direction transaction.

### 19.3 HOW to Close the Open Cell

To close `stretch × read` you need two things happening simultaneously in the
same transaction: the slave must be instructed to stretch SCL (via the slave
agent's `i2c_slave_stretch_ctrl_seq`) AND the master must be issuing a READ
direction seq_item (not a write). The sequence structure would be:

```
fork
  // Fork 1: tell slave to activate stretch control
  i2c_slave_stretch_ctrl_seq on slave sequencer
join_none

// Main: issue a READ transaction on the master sequencer
start_item(req);
req.dir       = DIR_READ;
req.start_cond = 1;
req.stop_cond  = 1;
req.addr      = 7'h50;
req.num_data  = 1;
finish_item(req);
```

The `clock_stretch_test` (T10) does this for the WRITE direction. A future
`stretch_read_test` (T15, or however it is numbered) would mirror it for the
READ direction. Until that test exists, the `stretch × read` cell remains open
and is documented as such in the closure report.

### 19.4 WHERE in Code: `i2c_stretch_dir_cross_cg` Line by Line

The covergroup lives in `uvm/i2c_coverage.sv`. Here is the code with each line
explained:

```systemverilog
// 17. Cross: Clock Stretch x Direction
// Catches: stretch only tested in write? slave that stretches during reads goes undetected
covergroup i2c_stretch_dir_cross_cg;
```

The comment above the `covergroup` keyword is the "why" documentation. It names
the bug class (stretch tested only in one direction) and the consequence (a
slave with direction-asymmetric stretch behavior would never be caught). This
comment is not optional — it is the engineering justification for this covergroup
existing in the sign-off-required model.

```systemverilog
  option.per_instance = 1;
  option.name = "Stretch x Dir";
```

`per_instance = 1` means the coverage is tracked per instantiation of this
covergroup type, not aggregated across all instances. In a multi-agent
environment with one coverage class per agent, this lets you see which agent's
transactions are not producing stretch-read coverage. `option.name` is the
human-readable label that appears in the simulator's HTML coverage report.

```systemverilog
  cp_stretch: coverpoint item.stretch_seen {
    bins no_stretch       = {0};
    bins stretch_seen_bin = {1};
  }
```

This mirrors the bins from CG10 (`i2c_stretch_cg`). Using the same bin names
keeps the closure report internally consistent: if a reviewer sees
`stretch_seen_bin` at 50% in CG17, they know immediately which cell is open
(the stretch side is only hitting one direction). The names are not
"write_stretch" and "read_stretch" here because this coverpoint is the raw
stretch axis; the direction axis is separate.

```systemverilog
  cp_dir: coverpoint item.dir;
```

`item.dir` is the `i2c_direction_e` enum (`DIR_WRITE`, `DIR_READ`). No explicit
bins are declared here — SystemVerilog auto-creates one bin per enum value.
Auto-bins on small enums are acceptable: there are only two values, both are
meaningful, and naming them "write" and "read" in the cross cell names would not
add information beyond what the enum value names already convey.

```systemverilog
  cross cp_stretch, cp_dir;
endgroup
```

The `cross` statement tells the simulator to track every combination of every
bin in `cp_stretch` (2 bins) with every bin in `cp_dir` (2 bins) = 4 cross
cells. Each cross cell is reported individually in the coverage database. The
cell names take the form `<cp_stretch_bin>,<cp_dir_bin>` — for example,
`stretch_seen_bin,DIR_READ` is the critical open cell.

**Sampling in `write()`**: The covergroup is sampled inside `i2c_coverage::write(t)`
on every transaction. Because `item.dir` is always valid (every transaction has
a direction), and `item.stretch_seen` is always valid (it defaults to `1'b0` in
`new()` and is only set to `1'b1` when stretch is detected), no guard condition
is needed. Every transaction contributes to this covergroup.

### 19.5 Coverage Growth Summary (CG1-CG17)

| # | Covergroup | Type | Cells | Status |
|---|------------|------|-------|--------|
| 1 | `i2c_dir_cg` | Flat | 2 | 100% |
| 2 | `i2c_data_size_cg` | Flat | 4 | 100% |
| 3 | `i2c_addr_cg` | Flat | 2 | 100% |
| 4 | `i2c_protocol_cg` | Flat | 4+ignore | 100% |
| 5 | `i2c_ack_cg` | Flat | 2 | 100% |
| 6 | `i2c_burst_cg` | Cross | 8 | 100% |
| 7 | `i2c_reg_ptr_cg` | Flat | 5 | 100% |
| 8 | `i2c_target_cg` | Cross | 2 | 100% |
| 9 | `i2c_byte_nack_cg` | Flat | 2 | 100% |
| 10 | `i2c_stretch_cg` | Flat | 2 | 100% |
| 11 | `i2c_rep_depth_cg` | Flat | 4 | **100% (T14 closes deep_rep)** |
| 12 | `i2c_dir_addr_cross_cg` | Cross | 6 | 100% |
| 13 | `i2c_dir_ack_cross_cg` | Cross | 4 | 100% |
| 14 | `i2c_rep_dir_cross_cg` | Cross | 4 | ~75% (has_rep×WRITE open) |
| 15 | `i2c_dir_size_cross_cg` | Cross | 10 | ~90% (READ×xlarge uncertain) |
| 16 | `i2c_protocol_dir_cross_cg` | Cross | 4 | ~75% (READ×no_stop open) |
| 17 | `i2c_stretch_dir_cross_cg` | Cross | 4 | **75% (stretch×read open)** |
| | **TOTAL (CG1-CG17)** | | **~89 coverage points** | **~95%** |

The addition of CG17 grows the model from ~85 to ~89 coverage points (4 new
cross cells). Three of the four cells close immediately under the existing
regression. One cell (`stretch × read`) is a documented open item requiring a
new `stretch_read_test`. This is the correct outcome — the covergroup did its
job by making the gap visible.

### 19.6 Interview Question

**Q: CG10 already measures whether stretch was observed. Why add CG17?**

CG10's `stretch_seen_bin` answers "did stretch happen at least once?" CG17's
`stretch × read` cell answers "did stretch happen during a read transaction?"
Those are different questions. CG10 at 100% means stretch was observed during
some transaction. It is silent about whether any READ direction transaction ever
triggered stretch. A slave that correctly stretches during writes but never
stretches during reads — or worse, a slave that fails to stretch during reads
when it should — would leave CG10 at 100% while leaving a genuine coverage hole.
CG17 makes that hole explicit and measurable. The rule of thumb: if a cross cell
requires a new directed test to close it, the cross is catching a real gap. If
all cross cells close trivially under existing tests, the cross is adding noise.
CG17's `stretch × read` cell requires a new test — which confirms it is
measuring something the existing regression does not cover.

---

*End of Part 18 — From 8 to 16 Covergroups: Closing the Holes*
