<div align="center">
  <h1>I2C Protocol Verification Environment (UVM)</h1>
  <h3>SystemVerilog UVM Verification Suite — audited, fixed, and re-verified</h3>
  <p><strong>A coverage-driven, self-checking verification environment for an I2C Slave Controller, built against the NXP UM10204 I2C-bus specification. See <code>docs/AUDIT_FIX_REPORT.md</code> for the full 2026-06 audit and the fixes that came out of it.</strong></p>
</div>

---

## 📑 Table of Contents
1. [Executive Summary & Project Scope](#1-executive-summary--project-scope)
2. [I2C Protocol Specification & Implementation Details](#2-i2c-protocol-specification--implementation-details)
3. [Design Under Test (DUT) Microarchitecture](#3-design-under-test-dut-microarchitecture)
4. [UVM Verification Architecture & Methodology](#4-uvm-verification-architecture--methodology)
5. [Transaction Level Modeling (TLM) Deep Dive](#5-transaction-level-modeling-tlm-deep-dive)
6. [Master Bus Functional Model (BFM) Driver](#6-master-bus-functional-model-bfm-driver)
7. [Passive Bus Monitor & State Machine](#7-passive-bus-monitor--state-machine)
8. [Self-Checking Shadow-Model Scoreboard](#8-self-checking-shadow-model-scoreboard)
9. [Functional Coverage Model (17 Covergroups)](#9-functional-coverage-model-17-covergroups)
10. [SystemVerilog Assertions (SVA) Specification](#10-systemverilog-assertions-sva-specification)
11. [Test Plan (19 Bus-Level Tests + 3 RAL Tests)](#11-test-plan-19-bus-level-tests--3-ral-tests)
12. [Sequence Library Reference](#12-sequence-library-reference)
13. [Verification Engineering Challenges & Bug Fixes (Interview Defense Guide)](#13-verification-engineering-challenges--bug-fixes-interview-defense-guide)
14. [Simulation & Build Infrastructure](#14-simulation--build-infrastructure)
15. [File Manifest & Directory Structure](#15-file-manifest--directory-structure)

---

## 1. Executive Summary & Project Scope

This repository contains a full-scale, production-ready **Universal Verification Methodology (UVM) 1.2** environment. It is engineered from the ground up to verify a custom-designed, synthesizable I2C Slave Controller. 

In modern VLSI Design Verification (DV) roles at top-tier semiconductor companies (NVIDIA, Apple, Qualcomm, Broadcom), engineers are expected to build robust, reusable, and mathematically provable verification environments. This project demonstrates exact mastery of those skills. 

**Key Objectives:**
* **Functional Coverage Model:** 17 covergroups (CG1–CG17) including cross coverage for burst lengths, read/write transitions, protocol errors, repeated-START chain depth, and clock-stretch x direction. The coverage report averages ALL covergroups against a 90% threshold. (Coverage closure is measured per regression with `make cov` — no unconditional "100%" claim is made here; run the regression and read the report.)
* **True Self-Checking Scoreboard:** dual queued streams (driver intent vs monitor observation) matched in order, byte-for-byte data comparison in both directions, and a shadow register bank built from what was actually on the wire.
* **Abstract vs. Physical Decoupling:** UVM TLM separates high-level transaction goals (e.g., "Write 8 bytes to address 0x50") from the low-level pin wiggling on the open-drain SDA/SCL lines.
* **Live SVA Checks:** protocol assertions whose failures are routed through `uvm_report_error`, so an assertion failure FAILS the test — they are not log decoration.
* **License-free RTL evidence:** `make smoke` runs a pure-SV master↔slave integration test under Icarus Verilog — 33 checks (burst write/read, NACK abort, clock stretch mid-byte AND at the address ACK, repeated START).
* **Verified on a commercial simulator (2026-06-12):** the UVM suite runs green on EDA Playground (Riviera-PRO 2025.04, UVM 1.2) — 8/8 tests with `UVM_ERROR: 0` and `SCOREBOARD PASSED`. The first shakedown run flushed out 4 latent bugs (3 constraint conflicts in never-executed sequences, 1 real RTL bug: the slave releasing its ACK during a clock stretch) — all fixed and documented in `docs/AUDIT_FIX_REPORT.md` §8.

---

## 2. I2C Protocol Specification & Implementation Details

The Inter-Integrated Circuit (I2C) protocol, originally developed by Philips Semiconductor (now NXP), is a synchronous, multi-master, multi-slave, packet-switched, single-ended, serial communication bus. 

### 2.1 Physical Layer Modeling (Open-Drain)
I2C requires open-drain (or open-collector) bidirectional lines with pull-up resistors. In this verification environment, the physical layer is modeled with absolute fidelity in `i2c_if.sv` using SystemVerilog's `wire` types and drive strengths.

```systemverilog
wire sda;
wire scl;

// Model pull-up resistors (open-drain idle = HIGH)
pullup(sda);
pullup(scl);

// Strong0 pull-down, weak1 release (simulates open-drain)
assign (strong0, weak1) sda = (sda_drv == 1'b0) ? 1'b0 : 1'bz;
assign (strong0, weak1) scl = (scl_drv == 1'b0) ? 1'b0 : 1'bz;
```
This guarantees that if the Master BFM releases the bus (drives `1'bz`), the pull-up resistor smoothly transitions the bus to `1'b1`, and if the Slave DUT drives `1'b0` simultaneously (e.g., during an ACK), the `strong0` overpowers the `weak1` pull-up, resulting in a correct `0` on the bus.

### 2.2 Protocol Primitives Handled
* **START Condition (S):** High-to-low transition of SDA while SCL is HIGH.
* **STOP Condition (P):** Low-to-high transition of SDA while SCL is HIGH.
* **Repeated START (Sr):** A new START condition issued without a preceding STOP. Critical for atomic operations (e.g., switching from Write to Read without relinquishing bus arbitration).
* **ACK/NACK Phase:** The 9th clock pulse where the receiver must pull SDA low to Acknowledge (ACK). If SDA remains high, it is a Not Acknowledge (NACK).
* **Clock Stretching:** The slave pulls SCL LOW to pause the master. The master must wait until SCL goes HIGH before continuing.

---

## 3. Design Under Test (DUT) Microarchitecture

The DUT is `i2c_slave_controller.sv`. It is a fully synthesizable RTL block that acts as a generic memory-mapped peripheral on the I2C bus.

### 3.1 RTL Features
* **7-bit Addressing:** Hardcoded via parameter to `7'h50`.
* **8-Byte Internal Memory:** Implemented as `logic [7:0] reg_bank [0:7]`.
* **Auto-Incrementing Pointer:** The slave maintains an internal `bit_cnt` and `reg_ptr`. Every time a data byte is successfully received and ACK'd, the `reg_ptr` increments. Upon reaching index 7, it wraps back to 0. This allows the master to execute infinite-length burst reads or writes without continuously sending the address.

### 3.2 Finite State Machine (FSM)
The DUT operates on a 10-state FSM:
1. `SLV_IDLE`: Waiting for START.
2. `SLV_ADDR`: Shifting in 7 address bits and 1 R/W bit.
3. `SLV_ACK_ADDR`: Driving ACK if address matches.
4. `SLV_RX`: Shifting in 8 bits of write data from the master.
5. `SLV_RX_ACK`: Driving ACK after receiving write data.
6. `SLV_TX`: Shifting out 8 bits of read data to the master.
7. `SLV_TX_ACK`: Waiting for master to ACK/NACK the read data.
8. `SLV_WAIT_STOP`: Wait state for transaction finalization.
9. `SLV_STRETCH_CLK`: Pulling SCL low to process data.

### 3.3 The Role of the Master RTL
The repository includes `i2c_master_controller.sv`. **However, it is deliberately excluded from the testbench.** In standard block-level DV methodology, we verify *one* block at a time. If we connected the Master RTL to the Slave RTL, we would not know if a bug was caused by the Master generating bad stimulus, or the Slave misinterpreting it. Therefore, a highly constrained, mathematically verifiable UVM Bus Functional Model (BFM) acts as the Master.

---

## 4. UVM Verification Architecture & Methodology

The verification environment is built on UVM 1.2. The architecture guarantees a total separation of concerns.

```mermaid
graph TD
    subgraph UVM Environment [UVM Environment: i2c_env]
        subgraph Master Agent [Master Agent - ACTIVE]
            MS[uvm_sequencer] -->|seq_item port| MD[i2c_master_driver]
            MM[i2c_monitor] 
        end
        
        subgraph Slave Agent [Slave Agent - REACTIVE]
            SS[uvm_sequencer] -->|ctrl_item port| SD[i2c_slave_driver]
            SM[i2c_slave_monitor]
        end
        
        SC[i2c_scoreboard \n Shadow Reference Model]
        COV[i2c_coverage \n 17 Covergroups]
        VS[i2c_virtual_sequencer]
    end

    MD <-->|Drives SDA/SCL via i2c_if| VIF(Physical Bus Interface)
    MM -->|Observes SDA/SCL via i2c_if| VIF
    
    SD -->|Drives stretch_en/force_nack| SVIF(i2c_slave_if)
    SM -->|Observes DUT internal FSM state| SVIF

    VIF <-->|Pin Connections| DUT
    SVIF -->|Status/Control Hookups| DUT

    subgraph Design Under Test [DUT]
        DUT[i2c_slave_controller]
    end

    subgraph SystemVerilog Assertions [SVA]
        SVA[i2c_protocol_assertions]
    end
    
    VIF --> SVA

    MM -->|item_collected_port (Actual)| SC
    MD -.->|req_analysis_port (Expected)| SC
    MM -->|item_collected_port| COV
```

### 4.1 Master Agent (Active)
Configured as `UVM_ACTIVE`. It contains a Sequencer and a Driver. It is responsible for driving standard I2C traffic on the bus.

### 4.2 Slave Agent (Reactive / Passive)
By default, the Slave Agent is `UVM_PASSIVE` (it only monitors the DUT's internal state). However, for error injection tests (like `clock_stretch_test` or `data_nack_test`), the test class uses `uvm_config_db` to flip it to `UVM_ACTIVE` before the `build_phase`. When active, it uses its driver to toggle back-door control signals (`stretch_en`, `force_data_nack`) on the DUT wrapper.

---

## 5. Transaction Level Modeling (TLM) Deep Dive

In UVM, all communication is modeled via Transaction Objects. Our primary object is `i2c_seq_item`.

### 5.1 `i2c_seq_item` Breakdown
```systemverilog
class i2c_seq_item extends uvm_sequence_item;
  rand logic [6:0]      addr;
  rand i2c_dir_e        dir;        // DIR_WRITE or DIR_READ
  rand logic [7:0]      data[];     // Payload
  rand int              num_data;   // Array size
  rand bit              start_cond;
  rand bit              stop_cond;
  rand bit              rep_start;

  // Recorded by monitor/driver during execution
  logic                 addr_ack;
  logic                 byte_ack[$];
```

### 5.2 Critical Protocol Constraints
To prevent the randomizer from generating impossible bus traffic (which would falsely trigger scoreboard failures), the sequence item is heavily constrained:

```systemverilog
// Must not exceed reasonable payload bounds
constraint num_data_c {
  num_data inside {[1:32]};
  data.size() == num_data;
}

// FIX: Every I2C transaction MUST begin with START or Repeated START.
constraint valid_protocol_c {
  start_cond || rep_start;     // Must have at least one
  !(start_cond && rep_start);  // Cannot have both simultaneously
  stop_cond -> !rep_start;     // STOP and rep_start are mutually exclusive
}
```

---

## 6. Master Bus Functional Model (BFM) Driver

The `i2c_master_driver` is the heart of the stimulus application. It translates TLM to physical electrical signals.

### 6.1 State Machine Operations
The driver operates in an infinite `run_phase` loop, pulling items via `seq_item_port.get_next_item(req_item)`.
For each item, it executes the following strictly timed steps:
1. **START/Rep_START Generation:** Pulls SDA low while SCL is high.
2. **Address Phase:** Shifts out 7 bits of address + 1 R/W bit on the falling edge of SCL.
3. **Address ACK Check:** Releases SDA, clocks SCL, and samples SDA. If the slave pulls SDA low, it records `addr_ack = 1`.
4. **Data Phase (Write):** Iterates over the `req_item.data` array. Shifts out 8 bits, checks for ACK on the 9th bit.
5. **Data Phase (Read):** Releases SDA. Cycles SCL 8 times, sampling SDA on the rising edge. It writes the captured data *back* into `req_item.data[i]`. It then drives an ACK (or a NACK for the final byte).
6. **STOP Generation:** Pulls SDA low, lets SCL go high, then lets SDA go high.

### 6.2 Clock Stretching Support
Every SCL release goes through `scl_release_wait()` — the driver releases the
line and then waits for the WIRE to actually go high, so a stretching slave
genuinely pauses the master:
```systemverilog
virtual task scl_release_wait();
  int timeout_count = 0;
  vif.scl_drv <= 1'b1;
  @(posedge vif.clk);
  while (vif.scl !== 1'b1) begin
    @(posedge vif.clk);
    timeout_count++;
    if (timeout_count >= MAX_CLK_STRETCH) begin
      `uvm_error(get_type_name(), "Clock-stretch timeout")
      return;
    end
  end
endtask
```
A timeout is a `uvm_error`, not a silent continue. The driver also honors the
spec timing constants per bit (`T_HD_DAT`, `T_SU_DAT`) and the `T_BUF`
bus-free time after STOP, which is what makes the protocol SVAs meaningful.

---

## 7. Passive Bus Monitor & State Machine

The `i2c_monitor.sv` is a fully autonomous, passive observer. It does not know what sequence is running. It must deduce everything purely by looking at the `sda` and `scl` wires.

### 7.1 Event Detection Logic
The monitor uses high-speed sampling (`@(posedge vif.clk)`) to detect edge transitions:
```systemverilog
sda_fall = (sda_d == 1'b1 && vif.sda === 1'b0);
sda_rise = (sda_d == 1'b0 && vif.sda === 1'b1);
scl_high = (vif.scl === 1'b1);
```

### 7.2 Repeated START handling (`saw_rep_start`)
A major challenge in verification is parsing back-to-back packets. If the monitor sees a START condition while it is already in the `STATE_DATA` phase, it immediately triggers the `saw_rep_start` flag. It finalize the *current* transaction, broadcasts it to the scoreboard via `item_collected_port.write()`, and immediately begins parsing the new transaction without missing a single clock cycle.

---

## 8. Self-Checking Shadow-Model Scoreboard

The `i2c_scoreboard.sv` verifies data integrity and protocol compliance. It
receives "Expected" items from the Driver and "Actual" items from the Monitor,
queues both streams, and matches them pairwise in order — robust to either
stream arriving first.

### 8.1 Per-Pair Checks
1. **Framing:** address and direction must match between intent and wire.
2. **ACK consistency:** the driver-sampled ACK and the monitor-observed ACK
   must agree, and only address `0x50` may ever be ACKed.
3. **Data:** byte-for-byte comparison in BOTH directions — for writes, what
   the driver meant to send vs what the monitor saw on the wire; for reads,
   what the driver captured vs what the monitor saw the slave drive.
4. **NACK-abort:** a NACK'd address must be followed by zero data bytes.

### 8.2 The Shadow Register Model
```systemverilog
logic [7:0] ref_reg_bank [0:7];
```
The shadow is updated from the **monitor** stream (what was really on the
wire). The DUT resets its register pointer on every address ACK, so each
transaction indexes from register 0 with modulo-8 wrap; read data is checked
against the shadow byte-for-byte.

### 8.3 End-of-Test
`check_phase` flags any unmatched leftover in either queue (a lost or extra
transaction), and `report_phase` cross-checks expected vs actual counts.

---

## 9. Functional Coverage Model (17 Covergroups)

Coverage closure is the ultimate metric of verification completeness. The `i2c_coverage.sv` component samples every transaction from the monitor into 17 covergroups (CG1–CG17): direction, burst size, address ranges, protocol flags, address/byte ACK results, clock stretch, repeated-START chain depth, and seven cross covergroups (including stretch x direction and rep-START x direction). The report-phase warning fires if the average across ALL covergroups drops below 90%. The table below summarizes the main groups:

| Covergroup Name | Verification Purpose | Defined Bins & Crosses |
|-----------------|----------------------|------------------------|
| **`i2c_transaction_cg`** | Confirms basic transaction shapes exist. | `cp_rw` (Read/Write), `cp_addr` (Target vs Out-of-bounds), `cp_num_bytes` (1 to 32 bytes). Crosses R/W with Address and Payload size. |
| **`i2c_data_cg`** | Verifies bit-level flip vulnerability (crosstalk prevention). | Bins for `0x00`, `0xFF`, `0x55`, `0xAA`, Walking 1s (`0x01`, `0x02`...), Walking 0s. |
| **`i2c_protocol_cg`** | Ensures all specific bus events occurred. | START, STOP, Repeated START. Crosses START with Rep_START. |
| **`i2c_error_cg`** | Validates the system's ability to handle NACKs. | Address NACKs, Data NACKs. Crosses them to ensure mutual exclusivity handled correctly. |
| **`i2c_address_cg`** | Exhaustive address space sweep. | Divides 0x00-0x7F into Reserved Low, Valid Low, Valid Mid, Target (0x50), Valid High, Reserved High. |
| **`i2c_transition_cg`** | Tests FSM turnaround logic. | Captures sequential directions: W->W, W->R, R->W, R->R. |
| **`i2c_burst_cg`** | Stress tests pointer auto-increment logic. | Crosses `dir` with `burst_len` (ranges 1, 2-4, 5-8, 9-16, >16) and `addr_match`. |
| **`i2c_reg_ptr_cg`** | Proves all physical memory slots were utilized. | Tracks which of the 8 register indices (0-7) were successfully written to. |

---

## 10. SystemVerilog Assertions (SVA) Specification

The `i2c_protocol_assertions.sv` file binds strictly formal property checks to the physical bus. These assertions run continuously in the background and will throw immediate simulation fatal errors if the timing spec is violated.

Assertion failures are routed through `uvm_report_error`, so they increment the
`UVM_ERROR` count and fail the test (with `$error` they were invisible to the
pass/fail criteria — see `docs/AUDIT_FIX_REPORT.md` §1.1).

1. **A1 — START leads to clocking**: after SDA falls while SCL is high, SCL must fall within a bounded window.
2. **A3 — SDA stable during SCL high**: the golden rule of I2C; enforced through data AND ack phases, with START/STOP windows excluded. (The old A2 was removed: its existential `##[1:T_BUF]` window made it near-vacuous, fully subsumed by A7.)
3. **A4 — ACK/NACK driven**: the 9th clock cycle must not float to `X`/`Z`.
4. **A5 — Clock stretch bounded**: SCL may not be held low longer than `MAX_CLK_STRETCH` cycles.
5. **A6 — No X/Z on bus**: during an active packet, neither line may go unknown.
6. **A7 — Full bus-free window**: after STOP, both lines must stay high for the entire `T_BUF` window.
7. **A8 — SDA hold after SCL fall**: SDA must not move with/just after the SCL falling edge (structural 2-cycle minimum; UM10204 t_HD;DAT min is 0 and the slave legitimately responds a few cycles later through its input synchronizers).
8. **A9 — SDA setup before SCL rise**: SDA must be stable for `T_SU_DAT` cycles before each sampling edge.

---

## 11. Test Plan (19 Bus-Level Tests + 3 RAL Tests)

The UVM Test library (`i2c_tests.sv`) contains 19 bus-level tests (base + 18 derived). Each test instantiates a specific sequence, configures the environment (Active vs Passive slave), and manages UVM objections. Three additional register-level tests run on the separate RAL bench (`make regress_ral`).

| Test Class Name | Target Sequence | Test Description & Objective |
|-----------------|-----------------|------------------------------|
| `i2c_base_test` | Smoke Test Base | Instantiates basic environment. Used as a fallback smoke test. |
| `basic_write_test` | `i2c_single_write_seq` | Writes 1 byte to `0x50`. Objective: Verify Address ACK and Data ACK logic. |
| `basic_read_test` | `i2c_single_read_seq` | Reads 1 byte from `0x50`. Objective: Verify slave drives data out on SDA. |
| `burst_write_test` | `i2c_burst_write_seq` | Writes 8 continuous bytes. Objective: Verify `reg_ptr` wrapping from 7 to 0 without hanging. |
| `burst_read_test` | `i2c_burst_read_seq` | Reads 8 continuous bytes. Objective: Verify sequential memory dump logic. |
| `write_read_test` | `i2c_write_read_seq` | Writes random payload, issues STOP, issues START, reads payload. Objective: Data integrity check. |
| `rep_start_test` | `i2c_rep_start_seq` | Write phase -> Repeated START -> Read phase. Objective: FSM turnaround without STOP. |
| `addr_nack_test` | `i2c_nack_addr_seq` | Master addresses `0x55`. Objective: Verify slave stays quiet, SDA remains high (NACK). |
| `data_nack_test` | `i2c_data_nack_seq` + Slave Seq | Slave Agent actively forces a NACK mid-payload. Objective: Error recovery. |
| `clock_stretch_test` | `i2c_stretch_vseq` | Slave Agent pulls `stretch_en` high. Master is paused. Objective: SCL synchronization verification. |
| `random_directed_test`| `i2c_random_seq` | 50 fully random valid packets. Objective: Coverage closure. |
| `addr_sweep_test` | `i2c_addr_sweep_seq` | Iterates addresses 0x08 to 0x77. Objective: Fill `i2c_address_cg`. |
| `bus_free_test` | `i2c_bus_free_seq` | Manual SCL/SDA check. Objective: Prove lines return to 1'b1 after STOP condition. |
| `sequential_txn_test` | `i2c_sequential_seq` | 10 back-to-back alternating Reads and Writes. Objective: FSM transition stress testing. |
| `data_pattern_test` | `i2c_data_pattern_seq` | Injects 0x00, 0xFF, 0xAA, 0x55, walking 1s/0s. Objective: data-pattern coverage. |
| `full_stress_test` | `i2c_stress_seq` | 100 randomly constrained packets incl. ~25% repeated-START chains. Objective: Final robustness check. |
| `arbitration_lost_test` | `arb_lost_sequence` + compete-mode slave driver | A competing master pulls SDA low mid-byte (T13). Objective: wired-AND arbitration behavior. Scoreboard runs in corruption-tolerant mode (the corruption is the point). |
| `deep_rep_start_test` | `deep_rep_start_sequence` | 4-segment repeated-START chain (T14). Objective: close rep-depth coverage bins 0/1/2/3. |
| `stretch_read_test` | `i2c_stretch_vseq` (virtual sequencer) | Slave stretches SCL during a WRITE and then a READ (T15). Objective: close the stretch x DIR_READ cross. |

**RAL tests** (`make regress_ral`, separate `top_tb_ral` bench): `i2c_ral_reset_test` (reset values + CMD write-only check), `i2c_ral_program_test` (field-level master programming), `i2c_ral_field_test` (read-modify-write without disturbing sibling fields).

---

## 12. Sequence Library Reference

The `i2c_sequences.sv` file defines the specific stimulus algorithms.

* **`i2c_base_seq`**: Base class handling `req` instantiation and start/finish items.
* **`i2c_burst_write_seq`**: Uses a loop to generate a single `seq_item` with `data.size() == burst_len`.
* **`i2c_rep_start_seq`**: Generates Item 1 with `stop_cond=0`. Generates Item 2 with `rep_start=1`. This exactly models the NXP specification for atomic operations.
* **`i2c_slave_stretch_ctrl_seq`**: Runs on the Slave Sequencer. Modifies the DUT's `stretch_cycles` input via the backdoor `i2c_slave_if`.
* **`i2c_random_seq`**: Disables base constraints, allowing the UVM randomizer to pick completely erratic packet sizes, R/W transitions, and data payloads, constrained only by `valid_protocol_c`.

---

## 13. Verification Engineering Challenges & Bug Fixes (Interview Defense Guide)

The bugs below are the original (V1/V2-era) fixes. A second, deeper audit was
performed on 2026-06-10 — **read `docs/AUDIT_FIX_REPORT.md`** for the complete
findings-to-fixes log, including: dead write-data checking in the scoreboard,
SVA failures invisible to pass/fail, the master RTL releasing the bus between
bytes, a repeated-START that never appeared on the wire, clock stretch that
never actually triggered, and the broken coverage-merge flow. That document is
the primary interview-defense material; this section is kept as history.

### 🔴 Bug 1: Clock Stretch Infinite Loop (RTL Deadlock)
**The Problem:** The RTL implemented `if (stretch_en)` as a level-sensitive check inside the `SLV_ACK_ADDR` state. Because the UVM Slave Agent drove `stretch_en` high for the duration of the entire test, the RTL state machine got stuck infinitely looping into the `SLV_STRETCH_CLK` state, completely deadlocking the simulation.
**The Fix:** Engineered a rising-edge detector in the RTL: `stretch_en_rise = stretch_en && !stretch_en_d`. The stretch state only triggers once per physical pulse from the agent, guaranteeing forward progress.

### 🔴 Bug 2: UVM TLM Out-of-Sync (Driver/Scoreboard Race Condition)
**The Problem:** In the Master Driver, `req_analysis_port.write(req_item)` was being called *immediately* after `get_next_item`. When the transaction was a Read, the `req_item` had an empty data array. The scoreboard evaluated the empty array against the shadow memory and instantly failed.
**The Fix:** Moved the `req_analysis_port.write()` command to the absolute bottom of the `run_phase` loop, *after* the physical STOP condition was driven and all read data was sampled back into the `req_item`.

### 🔴 Bug 3: Shadow Register Corruption on Multi-Byte Reads
**The Problem:** The original scoreboard logic was blindly resetting `shadow_ptr = 0` at the start of *every* transaction. If the master did a 4-byte write (pointer ends at 4), and then did a Repeated START 2-byte read, the DUT would output from index 4, but the scoreboard expected index 0. Mismatch!
**The Fix:** Upgraded the scoreboard to track pointer persistence globally across transactions, perfectly mirroring the physical behavior of the silicon memory.

### 🔴 Bug 4: Active Wait Race Condition in Slave Agent
**The Problem:** The slave driver used `wait(vif.active == 0);` to reset signals. However, at time 0, `active` is already 0! The driver cleared the signals before the transaction even began.
**The Fix:** Implemented a two-phase handshake: `wait(vif.active == 1);` followed immediately by `wait(vif.active == 0);`. This ensures the driver waits for the transaction to *start* before waiting for it to *end*.

### 🔴 Bug 5: SVA Hardcoded Timing vs Abstract BFM
**The Problem:** The SVA was written as `sda ##[0:100] scl`. Because the abstract UVM BFM sometimes delays driving pins while evaluating constraints, the 100-cycle limit was violated randomly, causing false SVA failures.
**The Fix:** Removed hardcoded clock delays from assertions. Rewrote SVA to monitor pure structural transitions (e.g., checking that SDA remains completely stable *whenever* SCL is high, regardless of how many cycles that takes).

### 🔴 Bug 6: X-Propagation due to 4-State Variables
**The Problem:** The UVM randomizer sometimes assigned `1'bx` to dynamic payload arrays, poisoning the simulation.
**The Fix:** Refactored all sequence item data variables to use `bit` (2-state) instead of `logic` (4-state) where appropriate, strictly guaranteeing 0 or 1.

---

## 14. Simulation & Build Infrastructure

This repository is built for scale and continuous integration.

### 14.1 Makefile Architecture
The `Makefile` located in `sim/` provides 1-click execution.
* `make compile` / `make compile_ral`: Invokes `vlog` for the bus-level and register-level benches.
* `make sim TEST=full_stress_test` / `make sim_ral RAL_TEST=i2c_ral_reset_test`: Runs a targeted test; every run saves its UCDB into `coverage/`.
* `make smoke`: License-free RTL integration test (Icarus Verilog) — RTL master vs RTL slave on real open-drain wires.
* `make regress`: 19 tests x 3 seeds (57 simulations). A run FAILS if its log contains any real `UVM_ERROR` line (assertion failures included) — only then is `SCOREBOARD PASSED` consulted.
* `make regress_ral`: The 3 register-abstraction-layer tests.
* `make cov`: Merges every `coverage/*.ucdb` into a unified HTML + text report.

### 14.2 Multi-Vendor Support
Because different companies use different toolchains, `scripts/compile.sh` was written to support standard EDA vendors.
* **QuestaSim (Siemens):** `./scripts/compile.sh questa`
* **VCS (Synopsys):** `./scripts/compile.sh vcs`
* **Xcelium (Cadence):** `./scripts/compile.sh xcelium`

### 14.3 EDA Playground Bundle (verified working 2026-06-12)
For rapid portfolio demonstration, `scripts/build_eda_playground.sh` generates a **two-file bundle** sized for EDA Playground's 100k-character-per-file limit:
* `eda_playground/ep_design.sv` → paste into the **design.sv** (right) pane: `i2c_pkg` + RTL + interfaces + SVA (~76k chars).
* `eda_playground/ep_testbench.sv` → paste into the **testbench.sv** (left) pane: comment-stripped UVM tb package + `top_tb` (~84k chars).

Settings: SystemVerilog/Verilog, **Aldec Riviera-PRO 2025.04**, UVM 1.2 library checked, Top = `top_tb`. Run one test per session via the run options: `vsim +UVM_TESTNAME=<test_name>; run -all; exit`. All 8 demonstrated tests pass green on this configuration. The bundle is **generated** — regenerate it after any source change instead of editing it by hand (the script also emits the older 5-file split for simulators without per-file limits).

---

## 15. File Manifest & Directory Structure

An exhaustive breakdown of every file in the system.

```text
i2c-protocol-dv/
├── rtl/                        
│   ├── i2c_pkg.sv              # Standard package. Defines DIR_READ (1), DIR_WRITE (0).
│   ├── i2c_slave_controller.sv # Core RTL. Contains FSM, shift registers, stretching logic.
│   ├── i2c_slave.sv            # Wraps the controller, exposing backdoor pins for UVM.
│   ├── i2c_master_controller.sv# Synthesizable master RTL. Defines APB-to-I2C logic.
│   └── i2c_master.sv           # Master wrapper.
│
├── tb/                         
│   ├── i2c_if.sv               # Wire-AND physical interface. Driver/Monitor clocking blocks.
│   ├── i2c_slave_if.sv         # UVM-to-DUT reactive hookup. Carries stretch_cycles, force_nack.
│   ├── i2c_tb_pkg.sv           # THE PACKAGE. Controls `include order for the entire UVM suite.
│   └── top_tb.sv               # Top module. Wires physical pins. Generates 100MHz clock. 
│                               # Uses config_db to pass virtual interfaces down the hierarchy.
│
├── uvm/                        
│   ├── i2c_env.sv              # Instantiates everything. Connects TLM ports in connect_phase.
│   ├── i2c_virtual_sequencer.sv# Holds references to Master and Slave actual sequencers.
│   ├── i2c_virtual_sequence.sv # Uses p_sequencer to fire slave and master traffic synchronously.
│   ├── i2c_seq_item.sv         # TLM payload class. Contains valid_protocol_c.
│   ├── i2c_sequences.sv        # Library containing 13 extended sequence classes.
│   ├── i2c_master_driver.sv    # BFM. Executes pin wiggling. Broadcasts actual expected items.
│   ├── i2c_master_agent.sv     # Encapsulates Master Seq/Drv/Mon. Configured UVM_ACTIVE.
│   ├── i2c_monitor.sv          # Edge-detecting observer. Creates observed items.
│   ├── i2c_slave_driver.sv     # Drives backdoor force_nack signals based on Slave Sequencer.
│   ├── i2c_slave_monitor.sv    # Reads internal DUT FSM state and builds status objects.
│   ├── i2c_slave_agent.sv      # Encapsulates Slave Seq/Drv/Mon. Defaults to UVM_PASSIVE.
│   ├── i2c_scoreboard.sv       # Queued intent-vs-wire matching + shadow register bank.
│   ├── i2c_coverage.sv         # 17 covergroups crossing protocol, data, stretch, rep-depth.
│   ├── i2c_base_test.sv        # Base class containing standard timeout logic.
│   ├── i2c_tests.sv            # Library of 18 extended test classes modifying factory configs.
│   ├── i2c_cpu_*.sv            # CPU register agent for the RAL bench.
│   └── i2c_ral_env.sv / i2c_ral_test.sv  # RAL environment + 3 register tests.
│
├── sva/                        
│   └── i2c_protocol_assertions.sv # 6 `property` blocks running under `assert property`.
│
├── ral/                        
│   ├── i2c_master_reg_model.sv # uvm_reg_block model of the master's CSR map.
│   ├── i2c_reg_adapter.sv      # reg2bus / bus2reg translation.
│   └── i2c_ral_seq.sv          # Reset-check (incl. CMD WO), program, field sequences.
│
├── sim/                        
│   └── Makefile                # Compilation, regression, RAL bench, smoke, coverage.
│
├── scripts/                    
│   ├── compile.sh              # Bash script wrapper for multi-tool simulation commands.
│   ├── run_all_tests.sh        # Shell regression runner (kept in sync with Makefile TESTS).
│   ├── build_eda_playground.sh # Regenerates eda_playground/ from canonical sources.
│   └── coverage_report.sh      # Legacy coverage merger.
│
├── eda_playground/             
│   ├── INSTRUCTIONS.md         # Step-by-step guide on how to configure the web simulator.
│   ├── i2c_pkg.sv              # Flattened package.
│   ├── rtl.sv                  # Flattened Master and Slave RTL source code.
│   ├── if_sva.sv               # Flattened Physical Interfaces and SystemVerilog Assertions.
│   ├── i2c_tb_pkg.sv           # Flattened UVM architecture (2200+ lines in one file).
│   └── top_tb.sv               # Execution root.
│
├── docs/                       
│   ├── verification_plan.md    # Initial phase planning document.
│   ├── BUG_REPORT.md           # Log of initial findings prior to remediation.
│   ├── FINAL_REPORT.md         # Final assessment of the original DV phase.
│   ├── AUDIT_FIX_REPORT.md     # 2026-06 deep audit: every finding -> fix (read this).
│   └── archive/                # Deprecated guides and phase 1 notes.
│
├── .gitignore                  # Prevents committing simulation logs, VCDs, and UCDB files.
└── README.md                   # This exhaustive documentation file.
```

---

<div align="center">
  <p><i>Project Architecture and Verification completely finalized and audited for Industry-Grade Deployment.</i></p>
</div>
