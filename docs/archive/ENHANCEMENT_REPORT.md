# I2C PROTOCOL DV — COMPREHENSIVE ENHANCEMENT REPORT
## Project Status: Phase 3 Complete | Phases 4-8 Incomplete
## Date: 2026-05-10

---

# PART 1: CURRENT STATE SUMMARY

## 1.1 What's Done (Phases 1-3)

| Component | Status | Quality |
|---|---|---|
| `rtl/i2c_pkg.sv` | COMPLETE | Good — clean types, params, enums |
| `rtl/i2c_master_controller.sv` | COMPLETE (fixed) | Good — SCL toggle, timer, ack_registered all fixed |
| `rtl/i2c_master.sv` | COMPLETE (fixed) | Good — clean wrapper, no broken interface |
| `rtl/i2c_slave_controller.sv` | COMPLETE (fixed) | Good — latched_rx_byte, tx_shift_reg, scl_o for stretch |
| `rtl/i2c_slave.sv` | COMPLETE | Good — parameterized wrapper |
| `sva/i2c_protocol_assertions.sv` | PARTIAL | A1-A7 implemented but has SVA/UVM mixing bug |
| `sim/Makefile` | EXISTS | Only runs base_test in regression |
| `docs/` | EMPTY | No documentation yet |

## 1.2 What's Partially Done (Phase 4 UVM scaffolding exists but broken)

| Component | Status | Key Issue |
|---|---|---|
| `uvm/i2c_seq_item.sv` | EXISTS | Works but queue randomization is fragile |
| `uvm/i2c_master_driver.sv` | EXISTS | Drives bus via logic, not wired-AND — open-drain broken |
| `uvm/i2c_monitor.sv` | EXISTS | Doesn't skip ACK bits — causes byte misalignment |
| `uvm/i2c_scoreboard.sv` | EXISTS | Connected wrong — seq_item_port not for scoreboard |
| `uvm/i2c_master_agent.sv` | EXISTS | Works but no slave agent |
| `uvm/i2c_env.sv` | EXISTS | TLM wiring is wrong (see CRITICAL #3) |
| `uvm/i2c_base_test.sv` | EXISTS | Works as smoke test |
| `uvm/i2c_tests.sv` | EXISTS | 15 tests defined, many are broken/skeletal |
| `tb/i2c_if.sv` | EXISTS | logic vs wire mismatch with DUT |
| `tb/top_tb.sv` | EXISTS | BFM mode only, no master RTL verification |
| `tb/i2c_tb_pkg.sv` | EXISTS | References MISSING file `i2c_sequences.sv` |

## 1.3 What's NOT Done (Phases 4-8)

| Missing Component | Phase | Impact |
|---|---|---|
| `uvm/i2c_sequences.sv` | Phase 4 | **COMPILATION BLOCKER** — tb_pkg includes it |
| `uvm/i2c_coverage.sv` | Phase 7 | No functional coverage at all |
| `uvm/i2c_slave_agent.sv` | Phase 4 | No slave-side UVM verification |
| `uvm/i2c_slave_monitor.sv` | Phase 4 | No slave response tracking |
| `uvm/i2c_slave_driver.sv` | Phase 4 | No slave BFM/reactive slave |
| `uvm/i2c_virtual_sequencer.sv` | Phase 4 | No multi-agent coordination |
| `uvm/i2c_virtual_sequence.sv` | Phase 4 | No coordinated master+slave sequences |
| `uvm/i2c_reg_model/` | Phase 4 | No UVM Register Model for master's APB-like interface |
| `scripts/run_regression.py` | Phase 8 | No automated regression |
| `docs/README.md` | Phase 8 | No project documentation |
| `docs/testplan.md` | Phase 5 | No formal test plan document |
| `docs/coverage_plan.md` | Phase 7 | No coverage closure plan |

---

# PART 2: CRITICAL BUGS (Compilation/Simulation Blockers)

## CRITICAL #1: MISSING FILE `i2c_sequences.sv`
**File:** `tb/i2c_tb_pkg.sv:35`
**Impact:** COMPILATION FAILURE — the package includes a file that doesn't exist.
```
`include "i2c_sequences.sv"  // ← FILE DOES NOT EXIST
```
**Fix:** Create `uvm/i2c_sequences.sv` with reusable sequence classes (basic_write_seq, basic_read_seq, burst_write_seq, burst_read_seq, random_seq, stress_seq).

## CRITICAL #2: SVA Module Uses `uvm_error` Macro
**File:** `sva/i2c_protocol_assertions.sv:101,114,128,143,156,173,187`
**Impact:** COMPILATION FAILURE — `uvm_error` is a UVM macro that requires `uvm_pkg` context. SVA modules are NOT UVM components and cannot use UVM macros.
```systemverilog
assert_start: assert property (p_start_cond)
  else `uvm_error("I2C-SVA-A1", ...)  // ← INVALID IN MODULE CONTEXT
```
**Fix:** Replace all `\`uvm_error` with `$error` or `$display` in the SVA module:
```systemverilog
assert_start: assert property (p_start_cond)
  else $error("I2C-SVA-A1: Illegal START condition at time %t", $time);
```

## CRITICAL #3: Scoreboard TLM Wiring Is Wrong
**File:** `uvm/i2c_env.sv:46`
**Impact:** Scoreboard never receives expected data. `seq_item_port` is for driver-sequencer communication, NOT for sending to the scoreboard.
```systemverilog
master_agent.driver.seq_item_port.connect(scoreboard.expected_export);  // ← WRONG
```
**Fix:** The driver should have an `uvm_analysis_port` that broadcasts a copy of each sent item. Connect THAT to the scoreboard:
```systemverilog
// In driver: add uvm_analysis_port #(i2c_seq_item) req_analysis_port;
// In driver run_phase: after executing, write to req_analysis_port
// In env connect_phase:
master_agent.driver.req_analysis_port.connect(scoreboard.expected_export);
```
Or better: add an analysis port to the agent and have the driver write to it.

## CRITICAL #4: Monitor Doesn't Skip ACK Bits — Causes Byte Misalignment
**File:** `uvm/i2c_monitor.sv:113-153`
**Impact:** The monitor samples EVERY SCL rising edge (including the 9th ACK bit). After 8 data bits + 1 ACK = 9 edges, the counter resets to 0, but the ACK bit gets counted as the first bit of the next byte. This causes:
- Byte 1: bits 0-7 (correct)
- ACK bit counted as bit 0 of byte 2 (wrong!)
- Byte 2 starts with bit 1 of the actual data (shifted by 1)

**Fix:** The monitor must skip every 9th SCL rising edge. Add a bit counter that resets after 9 (8 data + 1 ACK):
```systemverilog
if (bit_cnt == 9) begin  // After 8 data + 1 ACK
  bit_cnt = 0;
  // Don't sample this bit — it's the ACK
end else if (bit_cnt == 8) begin
  // This is the ACK/NACK bit — skip it
  bit_cnt = bit_cnt + 1;
end else begin
  // Data bit — sample normally
  shift_reg = {shift_reg[6:0], vif.sda};
  bit_cnt = bit_cnt + 1;
  if (bit_cnt == 8) begin
    // Complete byte assembled
    ...
  end
end
```

## CRITICAL #5: Driver/Interface Open-Drain Conflict
**File:** `uvm/i2c_master_driver.sv`, `tb/i2c_if.sv`
**Impact:** The interface declares `logic sda, scl` (single-driver). The DUT declares `inout wire scl, sda` (multi-driver wired-AND). Connecting `logic` to `inout wire` creates a resolution conflict. The driver's `vif.sda <= 1'bz` on a `logic` type doesn't release the bus — `logic` defaults to X, not Z.

**Fix:** The interface should use `wire` with pull-up, and the driver should use a separate proxy:
```systemverilog
// In i2c_if:
wire sda, scl;
pullup(sda); pullup(scl);  // Model pull-up resistors

// Driver drives through weak0/strong0 assignments:
// Use a proxy signal that the driver sets, and assign to the wire
logic sda_drv, scl_drv;
assign (weak0, weak1) sda = sda_drv;
assign (weak0, weak1) scl = scl_drv;
```
Or use the current `logic` approach but ensure the driver explicitly sets `1'b1` (not `1'bz`) to release the bus, and the DUT's open-drain assignments handle the wired-AND through simulation resolution.

## CRITICAL #6: Test 11 (multi_slave_test) — Invalid SystemVerilog Syntax
**File:** `uvm/i2c_tests.sv:308`
**Impact:** COMPILATION FAILURE
```systemverilog
foreach (7'h[i]) begin  // ← INVALID SYNTAX
```
**Fix:**
```systemverilog
for (int i = 0; i < 128; i++) begin
  if (i == 'h00 || i == 'h7F) continue;
  ...
end
```

---

# PART 3: MAJOR FUNCTIONAL GAPS

## MAJOR #1: No Clock Stretching Test Infrastructure
**Impact:** Test 8 (clock_stretch_test) cannot work. The slave wrapper hardcodes `stretch_en(1'b0)`. Even though `top_tb.sv` has `tb_stretch_en` and `tb_stretch_cycles` signals, they are NOT connected to the slave — they're declared but unused.

**Fix:** Connect `tb_stretch_en` and `tb_stretch_cycles` to the slave instance, and drive them from a config or sequence:
```systemverilog
// In top_tb: already has tb_stretch_en/tb_stretch_cycles
// Just connect to slave:
i2c_slave #(.SLAVE_ADDR(7'h50)) slave_dut (
  .stretch_en(tb_stretch_en),      // ← was 1'b0
  .stretch_cycles(tb_stretch_cycles), // ← was 16'd0
  ...
);
```
Also add UVM config_db mechanism to control these from sequences.

## MAJOR #2: No Functional Coverage
**Impact:** Phase 7 entirely missing. No covergroups, no coverage collectors, no coverage closure strategy. Cannot measure verification completeness.

**Fix:** Create `uvm/i2c_coverage.sv` with 6 covergroups:
1. `cg_addr` — address + direction cross
2. `cg_data` — data byte values
3. `cg_trans_type` — start/stop/rep_start/error
4. `cg_num_bytes` — 0-32 byte counts
5. `cg_status` — idle/busy/ack/nack/timeout
6. `cg_stretch` — enabled/disabled/timeout

## MAJOR #3: No Slave Agent / Reactive Slave
**Impact:** Only the master side has UVM components. The slave is RTL-only. Tests like data_nack_test (Test 7) need to inject NACK behavior from the slave, but there's no UVM mechanism to control the slave's response.

**Fix:** Create:
- `uvm/i2c_slave_agent.sv` — wraps slave monitor + reactive driver
- `uvm/i2c_slave_driver.sv` — reactive driver that controls stretch_en and can inject NACK
- `uvm/i2c_slave_monitor.sv` — monitors slave-side state (reg_bank writes, TX data)

## MAJOR #4: No Virtual Sequencer for Multi-Agent Coordination
**Impact:** Cannot coordinate master and slave agents for complex scenarios (e.g., master writes while slave stretches clock, or master reads while slave prepares specific data).

**Fix:** Create:
- `uvm/i2c_virtual_sequencer.sv` — holds handles to both master and slave sequencers
- `uvm/i2c_virtual_sequence.sv` — coordinates master/slave sequences

## MAJOR #5: Master RTL Is Never Tested
**Impact:** `top_tb.sv` uses "Option B" (BFM mode) — the UVM driver directly drives SDA/SCL, bypassing the master RTL entirely. The master controller RTL is never exercised.

**Fix:** Create "Option A" testbench variant:
- Instantiate `i2c_master` in `top_tb.sv`
- Replace the pin-level driver with a register-level driver that writes to the master's CPU interface
- Or create a dual-mode testbench that can switch between BFM and RTL

## MAJOR #6: Bad Test Implementations
**Impact:** Several tests are skeletal or broken:

| Test | Issue |
|---|---|
| Test 7 (data_nack_test) | `inject_nack` flag has no mechanism to make slave NACK |
| Test 8 (clock_stretch_test) | `inject_timeout` has no mechanism to trigger stretching |
| Test 11 (multi_slave_test) | Invalid syntax, only 1 slave instantiated |
| Test 12 (bus_free_test) | Uses `#T_BUF` delay which is a parameter, not a time value |
| Test 14 (bad_cmd_test) | Empty test body — does nothing |
| Test 15 (full_stress_test) | Double-raises objection (super.run_phase already raises) |

## MAJOR #7: No UVM Register Model
**Impact:** The master has a register interface (REG_CTRL, REG_CMD, REG_STATUS, etc.) but there's no UVM register model (uvm_reg). This means:
- No register-level testing
- No register access from sequences
- No register coverage
- No automated register bit-bashing tests

**Fix:** Create `uvm/i2c_reg_model/` directory with:
- `i2c_reg_block.sv` — uvm_reg_block with all registers
- `i2c_reg_adapter.sv` — converts reg access to bus transactions
- `i2c_reg_predictor.sv` — mirrors register state

---

# PART 4: MODERATE ISSUES

## MOD #1: Makefile Regression Only Runs 1 Test
**File:** `sim/Makefile:72`
```makefile
TESTS = i2c_base_test  # ← Only one test!
```
**Fix:**
```makefile
TESTS = i2c_base_test basic_write_test basic_read_test burst_write_test \
        burst_read_test rep_start_test addr_nack_test data_nack_test \
        clock_stretch_test random_directed_test random_err_test \
        bus_free_test sequential_txn_test full_stress_test
```

## MOD #2: No VCS/Xcelium Support in Makefile
**File:** `sim/Makefile`
**Fix:** Add VCS and Xcelium compile/sim targets.

## MOD #3: No Simulation Log Parsing
**Fix:** Add a script that parses transcript/vsim.log for UVM_FATAL/UVM_ERROR counts and generates a pass/fail summary.

## MOD #4: `i2c_seq_item.sv` — Queue Randomization Fragility
**File:** `uvm/i2c_seq_item.sv:27-28`
```systemverilog
rand logic [7:0]  data [$];  // Queue
rand int          num_data;
```
**Issue:** Randomizing a queue with `data.size() == num_data` constraint is fragile across simulators. Some solvers handle it, some don't.
**Fix:** Change to dynamic array `rand logic [7:0] data[];` which is more universally supported, or use `post_randomize()` to resize and fill.

## MOD #5: Monitor Event Sensitivity List Is Inefficient
**File:** `uvm/i2c_monitor.sv:81`
```systemverilog
@(negedge vif.scl or negedge vif.sda or posedge vif.sda);
```
**Issue:** This sensitivity list can cause spurious wake-ups. It also doesn't detect events when SCL is low (which is fine for START/STOP but limits debug).
**Fix:** Use clock-synchronized sampling:
```systemverilog
forever begin
  @(posedge vif.clk);
  // Detect edges by comparing current vs previous values
end
```

## MOD #6: SVA Assertion A3/A7 May Fire Falsely
**File:** `sva/i2c_protocol_assertions.sv:121-128,180-187`
**Issue:** Both A3 (SDA stable during SCL high in data phase) and A7 (no SDA glitch during SCL high) will fire during START/STOP conditions, since SDA changes while SCL is HIGH during those conditions. The `in_data_phase` flag mitigates A3, but A7 has no such guard.
**Fix:** Add `!start_cond_asserted && !stop_cond_asserted` disable condition to A7.

## MOD #7: No Reset Test
**Issue:** No test verifies that the master/slave resets correctly mid-transaction.
**Fix:** Add `reset_test` that starts a write, asserts reset mid-way, then verifies both devices return to IDLE.

## MOD #8: No Arbitration Test
**Issue:** Single-master only. No multi-master arbitration testing (acknowledged as future work but should be noted in test plan).

---

# PART 5: PHASE-BY-PHASE ROADMAP TO COMPLETION

## Phase 4: UVM Environment (PRIORITY: IMMEDIATE)

### Step 4.1: Fix Compilation Blockers (1-2 hours)
1. Create `uvm/i2c_sequences.sv` with base sequences
2. Fix `sva/i2c_protocol_assertions.sv` — replace `\`uvm_error` with `$error`
3. Fix `uvm/i2c_tests.sv:308` — invalid `foreach` syntax

### Step 4.2: Fix Core UVM Infrastructure (2-3 hours)
1. Fix monitor ACK-bit skipping logic
2. Fix scoreboard TLM wiring in `i2c_env.sv`
3. Fix driver/interface open-drain conflict
4. Add driver analysis port for scoreboard expected data

### Step 4.3: Create Missing UVM Components (3-4 hours)
1. Create `uvm/i2c_coverage.sv` (functional coverage subscriber)
2. Create `uvm/i2c_slave_agent.sv` (passive initially)
3. Create `uvm/i2c_slave_monitor.sv` (observes slave state)
4. Create `uvm/i2c_virtual_sequencer.sv`
5. Create `uvm/i2c_virtual_sequence.sv`

### Step 4.4: Create Reusable Sequences (2-3 hours)
1. `i2c_basic_write_seq` — single byte write
2. `i2c_basic_read_seq` — single byte read
3. `i2c_burst_write_seq` — multi-byte write
4. `i2c_burst_read_seq` — multi-byte read
5. `i2c_random_seq` — randomized transactions
6. `i2c_error_seq` — error injection (NACK, stretch)
7. `i2c_stress_seq` — high-throughput

### Step 4.5: Integrate Coverage into Environment (1-2 hours)
1. Instantiate `i2c_coverage` in `i2c_env`
2. Connect monitor analysis port to coverage
3. Add coverage subscriber to `i2c_tb_pkg.sv`

## Phase 5: Test Plan Completion (3-4 hours)
1. Fix all 15 test implementations
2. Make each test use proper sequences (not inline item creation)
3. Add proper pass/fail checks in each test
4. Add missing tests: reset_test, arb_lost_test, general_call_test
5. Create formal test plan document

## Phase 6: SVA Assertion Hardening (1-2 hours)
1. Fix A7 false-firing during START/STOP
2. Add more assertions: address byte format, repeated START timing, bus free time
3. Consider adding covers to assertions (cover property)

## Phase 7: Coverage Closure (2-3 hours)
1. Create coverage plan document
2. Implement 6 covergroups in `i2c_coverage.sv`
3. Run regression with coverage
4. Identify coverage holes
5. Add targeted tests/sequences to close holes
6. Target: >95% functional coverage

## Phase 8: GitHub Polish (1-2 hours)
1. Create `docs/README.md` with architecture, how-to-run, results
2. Create `docs/testplan.md`
3. Create `docs/coverage_plan.md`
4. Add `scripts/run_regression.py`
5. Clean up guide files (consolidate or remove duplicates)
6. Add `.gitignore` for work/, *.wlf, *.vcd, etc.
7. Add LICENSE

---

# PART 6: FILE-BY-FILE ACTION ITEMS

| File | Action | Priority | Effort |
|---|---|---|---|
| `uvm/i2c_sequences.sv` | **CREATE** — reusable sequence library | P0 | 2h |
| `sva/i2c_protocol_assertions.sv` | FIX — replace \`uvm_error with $error | P0 | 15m |
| `uvm/i2c_tests.sv` | FIX — Test 11 syntax, Test 14 body, Test 15 objection | P0 | 1h |
| `uvm/i2c_monitor.sv` | FIX — skip ACK bits in byte reconstruction | P0 | 1h |
| `uvm/i2c_env.sv` | FIX — scoreboard TLM wiring | P0 | 30m |
| `uvm/i2c_master_driver.sv` | FIX — open-drain handling, add analysis port | P0 | 1h |
| `tb/i2c_if.sv` | FIX — wire vs logic, pull-up modeling | P0 | 1h |
| `tb/top_tb.sv` | FIX — connect stretch signals | P1 | 30m |
| `uvm/i2c_coverage.sv` | **CREATE** — 6 covergroups | P1 | 2h |
| `uvm/i2c_slave_agent.sv` | **CREATE** — passive slave agent | P1 | 1h |
| `uvm/i2c_slave_monitor.sv` | **CREATE** — slave state observer | P1 | 1h |
| `uvm/i2c_virtual_sequencer.sv` | **CREATE** — multi-agent coord | P2 | 30m |
| `uvm/i2c_virtual_sequence.sv` | **CREATE** — coordinated sequences | P2 | 1h |
| `uvm/i2c_scoreboard.sv` | ENHANCE — better ref model, read-back | P1 | 1h |
| `uvm/i2c_seq_item.sv` | FIX — change queue to dyn array | P1 | 30m |
| `rtl/i2c_slave.sv` | FIX — expose stretch_en through wrapper | P1 | 15m |
| `sim/Makefile` | FIX — add all 15 tests, VCS/Xcelium support | P2 | 30m |
| `scripts/run_regression.py` | **CREATE** — automated regression | P2 | 1h |
| `docs/README.md` | **CREATE** — project documentation | P3 | 1h |
| `docs/testplan.md` | **CREATE** — formal test plan | P3 | 30m |
| `.gitignore` | **CREATE** — build artifacts | P3 | 5m |

---

# PART 7: RISK ASSESSMENT

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Monitor byte misalignment causes false failures | HIGH | HIGH | Fix ACK bit skipping first |
| Open-drain simulation mismatch | HIGH | MEDIUM | Test with real pull-up modeling |
| Coverage never closes without proper sequences | CERTAIN | MEDIUM | Build sequences before tests |
| Master RTL never tested (BFM mode) | CERTAIN | HIGH | Create Option A testbench |
| Multi-slave test impossible (1 slave in TB) | CERTAIN | LOW | Add 2nd slave instance |

---

# PART 8: RECOMMENDED EXECUTION ORDER

```
Week 1: Get it compiling & basic sim working
├── Day 1: Fix P0 compilation blockers (sequences.sv, SVA uvm_error, test 11 syntax)
├── Day 2: Fix monitor ACK skip + scoreboard wiring + driver analysis port
├── Day 3: Fix interface open-drain + top_tb stretch signals + slave wrapper
└── Day 4: Verify base_test passes end-to-end (write + read + scoreboard check)

Week 2: Build out UVM infrastructure
├── Day 5: Create i2c_coverage.sv with all 6 covergroups
├── Day 6: Create slave agent + slave monitor
├── Day 7: Create virtual sequencer + sequences
├── Day 8: Fix all 15 test implementations with proper sequences
└── Day 9: Run regression, fix failures

Week 3: Coverage closure + polish
├── Day 10: Run coverage, identify holes, add targeted tests
├── Day 11: Add register model (optional, stretch goal)
├── Day 12: Create Option A testbench (master RTL verification)
├── Day 13: Documentation (README, testplan, coverage plan)
└── Day 14: Final regression, GitHub polish, submit
```

---

**BOTTOM LINE:** The project has a solid RTL foundation (Phases 1-3 are done correctly with all known bugs fixed). The UVM scaffolding exists but has 6 critical bugs that prevent compilation/simulation and 7 major functional gaps. The path to completion is clear: fix compilation blockers first, then fix core UVM infrastructure, then build missing components, then close coverage.

**Estimated total effort to completion: 60-80 hours across 2-3 weeks.**
