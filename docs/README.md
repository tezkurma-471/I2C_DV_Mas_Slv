# I2C Protocol — RTL Design + Full UVM Verification

> **Author:** Kushal Pitaliya | **Reference:** NXP UM10204 Rev. 7.0 | **Target:** 95%+ Coverage

---

## Overview

Complete I2C Master/Slave RTL with full UVM testbench, SVA assertions, and functional coverage. This project demonstrates industry-style ASIC verification methodology from spec study through coverage closure.

**Protocol:** I2C (Inter-Integrated Circuit) — 2-wire synchronous serial bus with open-drain signaling, 7-bit addressing, clock stretching, and ACK/NACK handshaking.

**V2 Highlights:** Self-checking scoreboard, per-byte ACK/NACK tracking, force_data_nack test hook, saved_state for proper stretch return, 6 functional covergroups with crosses, 9 real bugs found and fixed.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    TOP TESTBENCH (top_tb.sv)              │
│  ┌────────────────────────────────────────────────────┐ │
│  │  I2C Interface (i2c_if.sv)                          │ │
│  │  Wire SDA/SCL with pullup + driver proxy signals   │ │
│  └─────────────┬─────────────────────┬───────────────┘ │
│                │                     │                  │
│  ┌─────────────▼─────┐   ┌───────────▼─────────────┐  │
│  │  I2C Master RTL   │   │   I2C Slave RTL         │  │
│  │  (APB-like IF)    │   │   (8-register bank)     │  │
│  │  Byte-level FSM   │   │   Clock stretching      │  │
│  └───────────────────┘   │   force_data_nack hook  │  │
│                          └─────────────────────────┘  │
│  ┌──────────────────────────────────────────────────┐  │
│  │           UVM Testbench (V2)                      │  │
│  │  Driver → Monitor → Scoreboard (self-checking)    │  │
│  │  Slave Agent (ACTIVE for error tests)             │  │
│  │  6 Covergroups + 7 SVA Assertions                │  │
│  │  Sequencer ← 15 Test Classes                     │  │
│  └──────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

---

## DUT Features

- **I2C Master Controller**: Byte-level FSM, APB-like register interface, SCL generation, START/STOP/Repeated START, ACK/NACK handling, clock stretch timeout
- **I2C Slave Controller**: 7-bit address matching, 8-register bank, burst read/write, clock stretching support, TX shift register for read mode, force_data_nack test hook, saved_state for stretch return
- **SVA Assertions**: 7 protocol assertions (A1-A7) — START/STOP conditions, data stability, ACK timing, bus free, clock stretch bounded

---

## Directory Structure

```
i2c-protocol-dv/
├── rtl/
│   ├── i2c_pkg.sv                 # Shared types, parameters, enums
│   ├── i2c_master_controller.sv   # Master FSM core
│   ├── i2c_master.sv              # Master wrapper
│   ├── i2c_slave_controller.sv   # Slave FSM core (V2)
│   └── i2c_slave.sv               # Slave wrapper (V2)
├── tb/
│   ├── i2c_if.sv                  # Interface with pull-up modeling
│   ├── i2c_slave_if.sv            # Slave control interface (V2)
│   └── top_tb.sv                  # Top-level testbench (V2)
├── uvm/
│   ├── i2c_seq_item.sv            # Transaction object (V2: addr_ack, byte_ack)
│   ├── i2c_sequences.sv           # Reusable sequence library (V2: 16 sequences)
│   ├── i2c_master_driver.sv       # Pin-level BFM driver
│   ├── i2c_monitor.sv             # Bus reconstructor (V2: per-byte ACK)
│   ├── i2c_master_agent.sv        # Master agent (driver + monitor + sequencer)
│   ├── i2c_slave_driver.sv        # Slave control driver (V2: force_data_nack)
│   ├── i2c_slave_monitor.sv       # Slave status monitor
│   ├── i2c_slave_agent.sv         # Slave agent (PASSIVE default, ACTIVE for error tests)
│   ├── i2c_virtual_sequencer.sv   # Virtual sequencer
│   ├── i2c_virtual_sequence.sv    # Virtual sequences
│   ├── i2c_scoreboard.sv          # Self-checking scoreboard (V2)
│   ├── i2c_coverage.sv            # 6 functional covergroups (V2)
│   ├── i2c_env.sv                 # Environment container (V2)
│   ├── i2c_base_test.sv           # Base test + pass/fail reporting (V2)
│   └── i2c_tests.sv               # 15 test classes (V2)
├── sva/
│   └── i2c_protocol_assertions.sv # A1-A7 assertions
├── sim/
│   └── Makefile                   # QuestaSim build system (V2: regress, cov, gui)
├── eda_playground/
│   ├── i2c_pkg.sv                 # Shared package
│   ├── rtl.sv                     # Consolidated RTL
│   ├── if_sva.sv                  # Consolidated interfaces + assertions
│   ├── i2c_tb_pkg.sv              # Consolidated UVM package (V2)
│   └── top_tb.sv                  # Top-level testbench (V2)
└── docs/
    ├── README.md                  # This file
    ├── VERIFICATION_PLAN.md       # Verification plan (V2)
    ├── BUG_REPORT.md              # Bug report (V2)
    └── FINAL_REPORT.md            # Final report (V2)
```

---

## Test Plan (15 Tests)

| # | Test | Type | Description | Self-Checking |
|---|------|------|-------------|---------------|
| 1 | basic_write_test | Directed | Write 1 byte to slave 0x50 | Scoreboard |
| 2 | basic_read_test | Directed | Read 1 byte from slave 0x50 | Scoreboard |
| 3 | burst_write_test | Directed | Write 8 bytes sequentially | Scoreboard |
| 4 | burst_read_test | Directed | Read 8 bytes sequentially | Scoreboard |
| 5 | write_read_test | Directed | Write then read back and verify | Scoreboard |
| 6 | rep_start_test | Protocol | Repeated START (write + Sr + read) | Monitor |
| 7 | addr_nack_test | Error | Send to non-existent address (0x55) | Scoreboard |
| 8 | data_nack_test | Error | Slave NACKs data byte (force_data_nack) | Monitor + Scoreboard |
| 9 | clock_stretch_test | Protocol | Slave holds SCL low for 100 cycles | Scoreboard |
| 10 | random_directed_test | Random | 50 random transactions | Scoreboard |
| 11 | addr_sweep_test | Sweep | Sweep all valid addresses 0x08-0x77 | Scoreboard |
| 12 | bus_free_test | Protocol | Verify SDA=SCL=1 after STOP | Inline check |
| 13 | sequential_txn_test | Directed | 10 back-to-back transactions | Scoreboard |
| 14 | data_pattern_test | Data | Walk-1, 0xAA/0x55, 0x00/0xFF patterns | Scoreboard |
| 15 | full_stress_test | Stress | 100 random transactions | Scoreboard |

---

## SVA Assertions

| ID | Assertion | Description |
|---|---|---|
| A1 | START condition | SDA falls while SCL HIGH → SCL stays HIGH |
| A2 | STOP condition | SDA rises while SCL HIGH → SCL stays HIGH |
| A3 | Data stability | SDA stable while SCL HIGH (data phase) |
| A4 | ACK timing | Receiver drives SDA LOW during 9th clock |
| A5 | Bus free | Both SDA/SCL HIGH after STOP |
| A6 | Clock stretch bounded | SCL released within MAX_CLK_STRETCH cycles |
| A7 | No SDA glitch | SDA stable while SCL HIGH (any phase) |

---

## How to Run

### QuestaSim
```bash
cd sim
make compile                       # Compile all sources
make sim TEST=basic_write_test     # Run a single test
make quick                         # Run all 15 tests (1 seed each)
make regress                       # Full regression (15 tests x 3 seeds)
make cov                           # Generate merged coverage report
make gui TEST=basic_write_test     # Run with GUI waveform viewer
make clean                         # Clean build artifacts
```

### EDA Playground
1. Open EDA Playground
2. Upload 5 files from `eda_playground/` directory
3. Select QuestaSim as simulator
4. Set `+UVM_TESTNAME=basic_write_test` as runtime option
5. Click Run

### VCS
```bash
./scripts/compile.sh vcs
./simv +UVM_TESTNAME=basic_write_test
```

### Xcelium
```bash
./scripts/compile.sh xcelium
```

### Full Regression
```bash
./scripts/run_all_tests.sh questa
```

---

## Coverage Model

6 covergroups targeting 95%+ functional coverage:

1. **i2c_transaction_cg** — R/W, address range, byte count, START/STOP, addr_ack, crosses (rw x addr, rw x bytes, start x stop, rw x addr_ack)
2. **i2c_data_cg** — 0x00, 0xFF, 0x55, 0xAA, walk-1, walk-0
3. **i2c_protocol_cg** — START, STOP, Rep-START, addr_ack, byte_ack, crosses
4. **i2c_error_cg** — NACK injection x timeout injection cross
5. **i2c_address_cg** — Reserved low, valid low/mid/high, reserved high
6. **i2c_transition_cg** — Write=>Read, Read=>Write, Write=>Write, Read=>Read

---

## Bugs Found and Fixed (9 Total)

1. **Shift register captures ACK bit as data** — Fixed with `latched_rx_byte` on `scl_fall`
2. **Slave TX mode drove high-Z** — Added `tx_shift_reg` loaded from register bank
3. **Clock stretch returns to SLV_IDLE** — Added `saved_state` for proper FSM return
4. **TX_ACK doesn't check master ACK/NACK** — Added `sda_i` check in SLV_TX_ACK
5. **Stretch activation during idle** — Added `active_int` guard
6. **SLV_RX_ACK doesn't respect force_data_nack** — Added test hook port
7. **Slave agent ACTIVE/PASSIVE config_db override failed** — Env uses check-before-set pattern
8. **Multi-driver on next_state in master** — Moved to `always_comb` only
9. **SCL permanently LOW during TX in master** — Fixed timer comparison logic

See `docs/BUG_REPORT.md` for full details.

---

## Key Learnings

- Open-drain bus modeling requires `wire` with pullups, not `logic`
- UVM scoreboard needs dual analysis ports via `` `uvm_analysis_imp_decl`` macros
- Monitor must skip ACK/NACK bits (9th bit) to avoid byte misalignment
- SVA modules cannot use UVM macros — use `$error` instead
- Clock stretch FSM must save and restore state, not return to IDLE
- UVM config_db override requires careful path resolution — env should use check-before-set
- Test hooks (like `force_data_nack`) enable testing error paths without modifying core behavior

---

*Built as a portfolio project for placement/internship interviews.*
