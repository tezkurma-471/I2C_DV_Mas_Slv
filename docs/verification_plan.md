# I2C Protocol Verification Plan

## 1. Introduction

### 1.1 Project Scope

This document defines the verification plan for an I2C protocol RTL + UVM verification project. The objective is to validate an I2C slave controller implementation against the NXP I2C-bus specification (UM10204 Rev. 7.0) using a UVM 1.2 testbench on QuestaSim (EDA Playground).

### 1.2 DUT Description

The Device Under Test (DUT) is an I2C slave controller with the following characteristics:

- **Slave address**: 0x50 (7-bit addressing mode)
- **Address width**: 7-bit
- **Register bank**: 8 registers (8-bit each), auto-incrementing pointer
- **Clock stretching**: Slave may hold SCL low to delay the master
- **force_data_nack**: Test hook that forces the slave to NACK a data byte when asserted
- **Supported operations**: Single/burst write, single/burst read, repeated START

A master controller RTL module exists in the project but is **not** verified in this environment. The testbench uses a Bus Functional Model (BFM) driver in place of the master RTL.

### 1.3 Reference Specification

NXP Semiconductors, "I2C-bus specification and user manual", UM10204 Rev. 7.0 (1 October 2021).

### 1.4 Verification Targets

| Metric                | Target           |
|-----------------------|------------------|
| Functional coverage   | 95%+             |
| Number of tests       | 15 self-checking |
| Protocol compliance   | UM10204 Rev. 7.0 |
| Language              | SystemVerilog IEEE 1800-2012 + UVM 1.2 |
| Simulator             | QuestaSim (EDA Playground) |

---

## 2. DUT Features to Verify

| # | Feature | Description |
|---|---------|-------------|
| F1 | 7-bit address matching | Slave ACKs address 0x50; NACKs all other addresses |
| F2 | Write transactions (single byte) | Master writes one data byte to slave register |
| F3 | Write transactions (burst) | Master writes multiple data bytes in a single transaction |
| F4 | Read transactions (single byte) | Master reads one data byte from slave register |
| F5 | Read transactions (burst) | Master reads multiple data bytes in a single transaction |
| F6 | Repeated START (Sr) | Write followed by Sr then read (or vice versa) without an intervening STOP |
| F7 | STOP condition | Slave correctly releases bus on STOP |
| F8 | Clock stretching | Slave holds SCL low to throttle the master; master waits until SCL is released |
| F9 | Data NACK injection | force_data_nack test hook causes slave to NACK a data byte |
| F10 | Register bank integrity | 8 registers, auto-incrementing pointer, rollover/wrap behavior |
| F11 | Bus free after STOP | SDA and SCL both high after STOP condition |
| F12 | Master ACK/NACK during read | TX_ACK state checks sda_i; slave stops driving data after master sends NACK |

---

## 3. Test Plan

| # | Test | Category | Feature Verified | Pass Criteria |
|---|------|----------|-----------------|---------------|
| 1 | basic_write_test | Directed | F1, F2 | Scoreboard: address ACK received; written data matches shadow register |
| 2 | basic_read_test | Directed | F1, F4 | Scoreboard: read data matches shadow register value |
| 3 | burst_write_test | Directed | F2, F3, F10 | Scoreboard: all 8 bytes written to consecutive registers |
| 4 | burst_read_test | Directed | F4, F5, F10 | Scoreboard: all 8 bytes read back match shadow registers |
| 5 | write_read_test | Directed | F2, F4, F10 | Scoreboard: read data matches previously written data |
| 6 | rep_start_test | Protocol | F6 | Monitor detects Repeated START; no STOP between write and read phases |
| 7 | addr_nack_test | Error | F1 | Scoreboard: addr_ack=0 for every address that is not 0x50 |
| 8 | data_nack_test | Error | F9 | Slave NACKs data byte when force_data_nack is asserted; monitor sees byte_ack=0 |
| 9 | clock_stretch_test | Protocol | F8 | Slave holds SCL low; SCL remains low for stretch_cycles before releasing |
| 10 | random_directed_test | Random | F1-F5, F10 | Scoreboard: all transactions pass; coverage bins hit for R/W, address, byte count |
| 11 | addr_sweep_test | Sweep | F1 | Scoreboard: only address 0x50 produces ACK across full sweep 0x08-0x77 |
| 12 | bus_free_test | Protocol | F11 | SDA=1 and SCL=1 observed after STOP condition |
| 13 | sequential_txn_test | Directed | F2, F4, F10 | Scoreboard: 10 back-to-back transactions all pass |
| 14 | data_pattern_test | Data | F2, F4 | All walk-1, walk-0, 0x00, and 0xFF patterns written and read back correctly |
| 15 | full_stress_test | Stress | F1-F6, F10 | Scoreboard: 100 random transactions all pass; coverage targets met |

---

## 4. Coverage Model

### 4.1 i2c_transaction_cg

Captures structural coverage of I2C transactions.

| Coverpoint | Bins | Description |
|------------|------|-------------|
| rw_dir | READ, WRITE | Read vs. write direction |
| addr_range | RESERVED_LOW[0x00-0x07], VALID_LOW[0x08-0x27], VALID_MID[0x28-0x47], TARGET[0x50], VALID_HIGH[0x48-0x77], RESERVED_HIGH[0x78-0x7F] | Address space partitioning |
| byte_count | SINGLE[1], BURST_SMALL[2-4], BURST_MID[5-7], BURST_FULL[8] | Number of data bytes per transaction |
| has_start | 1 | START detected |
| has_stop | 1 | STOP detected |
| addr_ack | ACK, NACK | Address acknowledgment |
| Cross: rw_dir x addr_ack | READ_ACK, READ_NACK, WRITE_ACK, WRITE_NACK | Direction vs. acknowledgment cross |

### 4.2 i2c_data_cg

Captures data value coverage.

| Coverpoint | Bins | Description |
|------------|------|-------------|
| data_value | ZERO[0x00], ALL_ONES[0xFF], ALT_LO[0x55], ALT_HI[0xAA], WALK1_0[0x01], WALK1_1[0x02], WALK1_2[0x04], WALK1_3[0x08], WALK1_4[0x10], WALK1_5[0x20], WALK1_6[0x40], WALK1_7[0x80], WALK0_0[0xFE], WALK0_1[0xFD], WALK0_2[0xFB], WALK0_3[0xF7], WALK0_4[0xEF], WALK0_5[0xDF], WALK0_6[0xBF], WALK0_7[0x7F] | Key data patterns |

### 4.3 i2c_protocol_cg

Captures protocol-level events.

| Coverpoint | Bins | Description |
|------------|------|-------------|
| start_cond | START | START condition detected |
| stop_cond | STOP | STOP condition detected |
| rep_start | REP_START | Repeated START detected |
| ack_response | ACK, NACK | Per-byte acknowledgment |
| byte_ack | BYTE_ACK, BYTE_NACK | Data byte ACK/NACK |
| Cross: ack_response x rep_start | ACK_WITH_SR, NACK_WITH_SR, ACK_NO_SR, NACK_NO_SR | Ack vs. Repeated START cross |

### 4.4 i2c_error_cg

Captures error injection coverage.

| Coverpoint | Bins | Description |
|------------|------|-------------|
| inject_nack | 0, 1 | force_data_nack value |
| inject_timeout | 0, 1 | Clock stretch / timeout injection |
| Cross: inject_nack x inject_timeout | NACK_ONLY, TIMEOUT_ONLY, BOTH, NEITHER | Error injection cross |

### 4.5 i2c_address_cg

Captures address space coverage.

| Coverpoint | Bins | Description |
|------------|------|-------------|
| addr_value | RESERVED_LOW[0x00-0x07], VALID_LOW[0x08-0x27], VALID_MID[0x28-0x47], TARGET[0x50], VALID_HIGH[0x48-0x77], RESERVED_HIGH[0x78-0x7F] | Address value ranges per UM10204 |

### 4.6 i2c_transition_cg

Captures transaction-to-transaction transition coverage.

| Coverpoint | Bins | Description |
|------------|------|-------------|
| rw_transition | WR_TO_RD, RD_TO_WR, WR_TO_WR, RD_TO_RD | Transition between consecutive transaction directions |

---

## 5. Scoreboard Checks

The UVM scoreboard performs the following checks on every transaction:

| # | Check | Description |
|---|-------|-------------|
| S1 | Address ACK/NACK | Address 0x50 must produce ACK; all other addresses must produce NACK |
| S2 | Data integrity (write) | Data bytes from write transactions are stored in a shadow register bank at the auto-incrementing pointer offset |
| S3 | Data integrity (read) | Data bytes from read transactions are compared against the shadow register bank; mismatches are reported as errors |
| S4 | Transaction count | Expected transaction count (driven by sequence) is compared against actual transaction count observed by the monitor; mismatch is reported |
| S5 | No data from NACK'd addresses | If an address is NACK'd, no subsequent data bytes shall appear in the scoreboard for that transaction |

---

## 6. SVA Assertions

| Assertion | Description | Purpose |
|-----------|-------------|---------|
| A1 | assert_start_valid | START is only detected when SDA falls while SCL is high |
| A2 | assert_stop_valid | STOP is only detected when SDA rises while SCL is high |
| A3 | assert_sda_stable_during_scl_high | SDA does not change while SCL is high (except during START/STOP) |
| A4 | assert_addr_ack_after_addr_byte | An ACK or NACK is driven on SDA within one SCL cycle after the 8-bit address byte |
| A5 | assert_bus_free_after_stop | Both SDA and SCL are high within a finite window after STOP |
| A6 | assert_no_data_after_addr_nack | No data phase occurs after the slave NACKs the address byte |
| A7 | assert_clock_stretch_release | If SCL is held low by the slave (clock stretch), it is eventually released high |

---

## 7. Limitations

1. **Master RTL not tested**: The testbench uses a BFM driver; the master controller RTL is not instantiated or verified.
2. **No multi-master / arbitration testing**: Only a single master is present in the testbench; bus arbitration and clock synchronization are not verified.
3. **No 10-bit addressing**: The DUT and testbench support only 7-bit addressing mode.
4. **No general call support**: The general call address (0x00) is not functionally verified; it is treated as a reserved address that produces a NACK.
5. **force_data_nack is a test hook**: The force_data_nack signal is a verification-only injection mechanism and is not part of the I2C specification.
6. **No HS-mode testing**: Only Standard-mode (100 kHz) and Fast-mode (400 kHz) timing are considered; High-speed mode (3.4 MHz) is out of scope.
7. **No electrical-level checks**: Signal integrity, rise/fall times, and bus capacitance are not verified in simulation.
