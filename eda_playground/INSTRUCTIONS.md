# EDA Playground Setup Guide -- I2C UVM Verification

This guide walks you through running the I2C protocol verification testbench on **EDA Playground** (online simulator). The flat files in `eda_playground/` are **generated** from the canonical `rtl/ tb/ uvm/ sva/` sources by `scripts/build_eda_playground.sh` — never edit them by hand; rerun the script after any source change so the bundle cannot diverge from the real tree.

---

## Section 1: EDA Playground Setup — VERIFIED WORKING CONFIG (2026-06-12)

> **This exact configuration ran 8/8 tests green on 2026-06-12.** Use it as-is.

Open **https://edaplayground.com** and configure the project settings as follows:

| Setting       | Value                                                              |
| ------------- | ------------------------------------------------------------------ |
| Language      | **SystemVerilog/Verilog**                                          |
| Simulator     | **Aldec Riviera-PRO 2025.04** (verified) — Questa also works if available |
| Top Module    | **top_tb** (auto-detected)                                         |
| Libraries     | **UVM 1.2** (checked)                                              |

Do NOT check UVM 1.1 or OVM -- this project targets UVM 1.2.

**Two hard constraints discovered the hard way:**
1. **Each editor pane has a 100,000-character limit.** That is why the bundle
   is two combined files (`ep_design.sv` ~76k, `ep_testbench.sv` ~84k), not
   the 5 logical files.
2. **Riviera is stricter than Questa.** It rejects `small`/`medium`/`large`
   as covergroup bin names (reserved trireg charge-strength keywords) and
   enforces constraint satisfiability exactly. The sources are already fixed
   for this — but remember it if you ever regenerate after edits.

### Two-pane layout

| EDA Playground pane | Paste this file | Contents |
| --- | --- | --- |
| **design.sv** (RIGHT pane) | `eda_playground/ep_design.sv` | `i2c_pkg` + all RTL + interfaces + SVA (compiled FIRST) |
| **testbench.sv** (LEFT pane) | `eda_playground/ep_testbench.sv` | UVM tb package (comment-stripped to fit 100k) + `top_tb` |

EDA Playground always compiles `design.sv` before `testbench.sv`, which gives
exactly the package-visibility order the 5-file layout enforced via tabs.

---

## Section 2: File Upload Order — 5-file layout (REFERENCE ONLY — use Section 1's two-pane layout instead)

> The 5-file split below is kept for simulators **without** a per-file size
> limit (e.g., a local tool reading `eda_playground/` directly). On
> edaplayground.com, use the two combined files from Section 1.

Files must be added in this exact order. SystemVerilog packages must be visible to all later files, so `i2c_pkg.sv` always comes first.

| Tab | Filename         | Source File                       | Why this position?                                              |
| --- | ---------------- | --------------------------------- | --------------------------------------------------------------- |
| 1   | `i2c_pkg.sv`     | `eda_playground/i2c_pkg.sv`       | Package -- must be visible to all later files                   |
| 2   | `rtl.sv`         | `eda_playground/rtl.sv`           | RTL modules; imports `i2c_pkg`                                  |
| 3   | `if_sva.sv`      | `eda_playground/if_sva.sv`        | Interfaces + SVA assertions; imports `i2c_pkg`                  |
| 4   | `i2c_tb_pkg.sv`  | `eda_playground/i2c_tb_pkg.sv`    | UVM classes, sequences, tests; imports `i2c_pkg` + `uvm_pkg`    |
| 5   | `top_tb.sv`      | `eda_playground/top_tb.sv`        | Top testbench; imports everything                               |

### Compile Order Diagram

```
                  +-----------------+
                  |  i2c_pkg.sv     |    (Tab 1: types, enums, params)
                  +--------+--------+
                           |
            +--------------+--------------+
            |                             |
            v                             v
   +-----------------+         +-------------------+
   |    rtl.sv       |         |   if_sva.sv       |    (Tabs 2 & 3)
   |  (RTL modules)  |         |  (Interfaces +    |
   +-----------------+         |   Assertions)     |
                               +-------------------+
            |                             |
            +--------------+--------------+
                           |
                           v
                  +------------------+
                  |  i2c_tb_pkg.sv   |    (Tab 4: all UVM classes flat)
                  +--------+---------+
                           |
                           v
                  +------------------+
                  |   top_tb.sv      |    (Tab 5: top module)
                  +------------------+
```

If you reorder these tabs, compilation will fail with messages like "unknown package i2c_pkg" or "type i2c_dir_e not declared". The order above mirrors what `sim/Makefile` enforces locally.

---

## Section 3: How to Add Each File

For each file (Tabs 1 to 5):

1. Click the **`+`** button next to the existing tabs in the file pane.
2. In the popup, type the filename **exactly** as shown in the table -- no `.txt` suffix, no extra characters. Spelling matters because `+incdir` lookups are filename-based.
3. Open the corresponding source file from `eda_playground/` in your editor and **copy the entire content**.
4. Paste it into the new EDA Playground tab.
5. Confirm the tab title in EDA Playground matches the expected filename.
6. Repeat for the remaining files (5 files total).

When all 5 tabs are populated, you are ready to run.

---

## Section 4: Run a Specific Test

With Riviera-PRO selected, set the **"Run options"** field (the verified
working invocation) to:

```
vsim +UVM_TESTNAME=basic_write_test; run -all; exit
```

To run a different test, replace `basic_write_test` with one of the names below — one test per run (EDA Playground sessions are isolated; there is no cross-run coverage merge). There are **19** available tests:

| #   | Test Name                | Description                                                  |
| --- | ------------------------ | ------------------------------------------------------------ |
| T0  | `i2c_base_test`          | Smoke test -- exercises infrastructure only                  |
| T1  | `basic_write_test`       | Single-byte write to slave                                   |
| T2  | `basic_read_test`        | Single-byte read from slave                                  |
| T3  | `burst_write_test`       | 8-byte burst write                                           |
| T4  | `burst_read_test`        | 8-byte burst read                                            |
| T5  | `write_read_test`        | Write followed by Read (separate transactions)               |
| T6  | `rep_start_test`         | Write then Read with Repeated START                          |
| T7  | `addr_nack_test`         | Master addresses wrong slave -- expects NACK                 |
| T8  | `data_nack_test`         | Slave NACKs a data byte -- expects clean abort               |
| T9  | `clock_stretch_test`     | Slave stretches SCL -- master must wait                      |
| T10 | `random_directed_test`   | 50 randomized transactions                                   |
| T11 | `addr_sweep_test`        | Sweep all 7-bit addresses 0x08..0x77                         |
| T12 | `bus_free_test`          | Verifies bus is FREE (HIGH) after STOP                       |
| --- | `sequential_txn_test`    | 10 back-to-back transactions                                 |
| --- | `data_pattern_test`      | Walking-1, walking-0, all corner patterns                    |
| --- | `full_stress_test`       | 100-transaction stress run                                   |
| **T13** | **`arbitration_lost_test`** | **Competing master pulls SDA low mid-byte -- expects master to detect arb_lost and abort** |
| **T14** | **`deep_rep_start_test`** | **4-segment repeated-START chain (W→W→W→R); closes CG11 bins two_rep/deep_rep, CG14 rep+write cell, CG16 write+no_stop cell** |
| **T15** | **`stretch_read_test`** | **Virtual sequence: clock-stretched write THEN clock-stretched read via v_sequencer (slave agent ACTIVE) — the test that exposed the SLV_STRETCH ACK-release RTL bug** |

Then click **Run** (green play button).

---

## Section 5: Expected Output

For most functional tests (T1..T12), a successful run looks like:

```
UVM_INFO @ ... basic_write_test ... Starting basic_write_test...
UVM_INFO @ ... i2c_driver ... Got item: I2C Seq Item: addr=0x50 dir=DIR_WRITE ...
UVM_INFO @ ... i2c_monitor ... START condition detected
UVM_INFO @ ... i2c_monitor ... Address: 0x50 DIR_WRITE
UVM_INFO @ ... i2c_monitor ... Data byte: 0xa5
UVM_INFO @ ... i2c_monitor ... STOP condition detected
UVM_INFO @ ... SCOREBOARD PASSED: All transactions matched.
```

Coverage report at the end shows which bins were hit during this single run.

---

## Section 6: Common Errors and Fixes

| Error Message                              | Cause                              | Fix                                                                  |
| ------------------------------------------ | ---------------------------------- | -------------------------------------------------------------------- |
| `unknown package i2c_pkg`                  | Wrong file order                   | Ensure `i2c_pkg.sv` is Tab 1                                         |
| `class i2c_seq_item already defined`       | Double-compilation                 | Use the flattened `i2c_tb_pkg.sv` from `eda_playground/` only        |
| `Virtual interface not found`              | config_db mismatch                 | Confirm **UVM 1.2** is selected in Libraries                         |
| Simulation hangs forever                   | UVM testname missing               | Make sure `+UVM_TESTNAME=<name>` is in Compile & Run Options         |
| SVA `I2C-SVA-A6` fires on every transaction | Normal SCL low vs stretch threshold | Tune `T_SCL_LOW` / `MAX_CLK_STRETCH` in `i2c_pkg.sv`                  |
| `arb_lost not declared`                    | EDA file out of date               | Re-copy `rtl.sv` from latest `eda_playground/`                        |
| `sda_drv_x undefined`                      | Interface change missing           | Re-copy `if_sva.sv` from latest `eda_playground/`                     |
| `arbitration_lost_test not found`          | TB pkg out of date                 | Re-copy `i2c_tb_pkg.sv` from latest `eda_playground/`                 |

If a re-copy is needed, you must replace the **entire** tab content, not just append. The latest project state is always in `eda_playground/` of the repository.

---

## Section 7: Running the T13 Arbitration-Lost Test Step-by-Step

T13 is a newer test that uses a different pass criterion. Follow these steps:

```
1. Make sure all 5 files are loaded correctly (Section 3).
2. In the "Compile & Run Options" textbox, paste:
   +UVM_TESTNAME=arbitration_lost_test +UVM_VERBOSITY=UVM_MEDIUM
3. Click Run.
4. Expected: a UVM_INFO line saying
   "T13: arbitration_lost_test PASS -- competing master drove SDA low and master under test should have aborted."
5. Coverage: this test increments the arbitration cross-coverage bin.
```

Notes on T13:
- The slave agent is automatically activated by the test's `build_phase` (via `is_active=UVM_ACTIVE`).
- The slave driver runs in **`compete_mode`** -- a second open-drain pull-down (`sda_drv_x`) inside the interface is used to collide with the master's TX bit.
- The collision happens at bit position 3 (configurable via `compete_at_bit`).
- The master detects sda_o=1 but sda_i=0 during SCL HIGH, raises `arb_lost`, and the FSM returns to IDLE without driving STOP.

---

## Section 8: Running the T14 Deep Repeated-START Test Step-by-Step

T14 exercises a 4-segment repeated-START chain to close coverage bins that T6 (`rep_start_test`) cannot reach.

```
1. Make sure all 5 files are loaded correctly (Section 3).
2. In the "Compile & Run Options" textbox, paste:
   +UVM_TESTNAME=deep_rep_start_test +UVM_VERBOSITY=UVM_MEDIUM
3. Click Run.
4. Expected: a UVM_INFO line saying
   "deep_rep_start_test finished — chain_depth 0/1/2/3 all exercised."
5. Coverage: this test closes CG11 bins two_rep and deep_rep, CG14 rep_start+write,
   and CG16 write+no_stop. CG17 (Stretch x Dir, 4 cells) is also sampled
   (no-stretch bins for both write and read directions).
```

Notes on T14:
- The test sends 4 seq_items in one sequence, disabling `default_trans_c` per item so protocol fields can be set freely.
- Segment order: fresh START+write (seg0) → REP_START+write (seg1) → REP_START+write (seg2) → REP_START+read+STOP (seg3).
- This exercises chain_depth bins 0, 1, 2, 3 in CG11 (`i2c_rep_depth_cg`) all in one run.
- CG17 (`i2c_stretch_dir_cross_cg`, 4 cells: no_stretch×write, no_stretch×read, has_stretch×write, has_stretch×read) is now active. T14 hits the no_stretch×write and no_stretch×read cells; `clock_stretch_test` hits has_stretch×write. The has_stretch×read cell remains an open gap requiring a future stretch+read test.

---

## Section 9: Verifying Each Test Passed

A test is considered passing when **all** of the following hold (criterion depends on test):

For functional tests (T1..T12, plus sequential/data_pattern/full_stress):
- `SCOREBOARD PASSED` line appears in the log
- **Zero** `UVM_FATAL` messages
- **Zero** `I2C-SVA-A*` assertion failures (assertion failures print as `$error("I2C-SVA-A1: ...")` and similar)
- **Zero** `UVM_ERROR` messages

For T13 (`arbitration_lost_test`):
- The line `T13: arbitration_lost_test PASS` appears in the log
- **Zero** `UVM_FATAL` / `UVM_ERROR` messages at the protocol/driver level
- Note: T13 intentionally does NOT print `SCOREBOARD PASSED` because the master aborts the transaction (no completion to score)

If you see any A*-prefixed assertion error in the log, that is a real protocol bug -- record the time and which A* fired before continuing.

---

## Section 10: Recommended Run Order for First-Time Users

Run tests in this order so failures localize to the right component:

1. `i2c_base_test`         -- smoke test, exercises only infrastructure
2. `basic_write_test`      -- simplest functional path
3. `basic_read_test`
4. `write_read_test`       -- combined direction switching
5. `burst_write_test`
6. `burst_read_test`
7. `rep_start_test`        -- protocol: Repeated START
8. `addr_nack_test`        -- protocol: NACK on address
9. `data_nack_test`        -- protocol: NACK on data
10. `clock_stretch_test`   -- protocol: clock stretch
11. `random_directed_test` -- random constrained
12. `addr_sweep_test`      -- exhaustive address coverage
13. `full_stress_test`     -- 100-transaction stress
14. `arbitration_lost_test` -- T13, uses compete_mode
15. `deep_rep_start_test`  -- T14, 4-segment rep-start chain

If `i2c_base_test` already fails, do NOT proceed -- there is a setup/wiring problem to fix first (most often file order or UVM library version).

---

## Section 11: Coverage in EDA Playground

EDA Playground runs each test in an **isolated simulation**. It does NOT merge coverage across runs the way QuestaSim's `vcover merge` does locally.

To get a coverage picture from EDA Playground:
- Run each test once
- Note the per-test coverage percent from the report at the end of each run
- Manually accumulate: for each bin, the highest hit across all tests wins
- For real coverage closure, run **locally** with `make regress` (in `sim/`) followed by `make cov`

The full coverage closure analysis with merged-coverage screenshots and bin-by-bin justification lives in `docs/COVERAGE_CLOSURE_REPORT.md` in the main repository.
