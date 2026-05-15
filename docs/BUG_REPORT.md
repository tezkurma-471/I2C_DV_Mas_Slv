# I2C Protocol Verification -- Bug Report

## Overview

This document catalogs all bugs discovered and resolved during UVM verification of the I2C slave and master controller RTL. Bugs range from critical data-corruption issues to UVM testbench configuration problems. Each entry includes the affected file, severity, detailed description, root cause, applied fix, and verification status.

---

## Bug #1: Shift Register Captures ACK Bit as Data

- **File**: `rtl/i2c_slave_controller.sv`
- **Severity**: Critical

### Description

The original code used the `{shift_reg[6:0], sda_i}[7:1]` pattern, which incorrectly included the ACK/NACK bit (9th bit on SDA) as the 8th data bit. This caused data corruption on every received byte because the shift register sampled the ACK signal as though it were data.

### Root Cause

The shift register was read on `scl_rise`, but the 9th `scl_rise` corresponds to the ACK clock cycle where `sda_i` carries the ACK/NACK response, not valid data. The design conflated the data and ACK phases of the shift operation.

### Fix

Added a `latched_rx_byte` register that captures the assembled data byte on `scl_fall` after the 8th data bit, before the ACK phase begins:

```systemverilog
latched_rx_byte <= {shift_reg[6:0], sda_i};
```

This ensures the captured byte reflects only the 8 data bits and excludes the ACK clock.

### Verification

All write tests pass with scoreboard data integrity checks confirming correct byte reception.

---

## Bug #2: Slave TX Mode Drove High-Z (No TX Shift Register)

- **File**: `rtl/i2c_slave_controller.sv`
- **Severity**: Critical

### Description

In read mode, the slave had no dedicated TX shift register. It reused the RX `shift_reg`, which was being shifted during TX, causing incorrect data output on SDA. Effectively, the slave drove high-Z or garbage during read transactions.

### Root Cause

Missing hardware -- no TX path existed for driving data onto SDA during read transactions. The RX shift register alone cannot serve double duty because its contents are being consumed (shifted out) while new TX data should be held steady.

### Fix

Added `tx_shift_reg` that is loaded from `internal_regs[reg_ptr]` upon entering `SLV_ACK` when `rx_rw == 1'b1` (read direction). The register shifts out MSB-first during the `SLV_TX` state:

```systemverilog
tx_shift_reg <= internal_regs[reg_ptr];
// In SLV_TX state:
tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};
sda_o <= tx_shift_reg[7];
```

### Verification

Read tests pass with scoreboard read data checks confirming correct byte transmission.

---

## Bug #3: Clock Stretch Returns to SLV_IDLE Instead of Previous State

- **File**: `rtl/i2c_slave_controller.sv`
- **Severity**: Major

### Description

After clock stretching, the slave FSM always returned to `SLV_IDLE` regardless of what it was doing before the stretch. This broke read transactions that were stretched mid-byte -- the slave would lose its place and not complete the read operation.

### Root Cause

The `SLV_STRETCH` state's next-state logic unconditionally transitioned to `SLV_IDLE` when the stretch completed, discarding any context about the prior FSM state.

### Fix

Added a `saved_state` register that captures `state` before entering `SLV_STRETCH`. When the stretch completes, the FSM returns to the saved state:

```systemverilog
saved_state <= state;  // on entering SLV_STRETCH
next_state = saved_state;  // when stretch completes
```

Additionally, stretch activation now only occurs when `active_int` is set, preventing spurious stretches during idle periods.

### Verification

`clock_stretch_test` with `stretch_cycles=100` passes, confirming the slave correctly resumes its prior state after stretching.

---

## Bug #4: TX_ACK State Doesn't Check Master ACK/NACK

- **File**: `rtl/i2c_slave_controller.sv`
- **Severity**: Major

### Description

After transmitting a byte in read mode, the `SLV_TX_ACK` state didn't check whether the master sent ACK (`sda_i=0`) or NACK (`sda_i=1`). It always continued sending, violating the I2C specification which requires the slave to stop transmitting after a master NACK.

### Root Cause

The original FSM had no conditional check on `sda_i` in the `SLV_TX_ACK` state. The transition was unconditional back to `SLV_TX`.

### Fix

Added a check on `sda_i` in `SLV_TX_ACK`:

```systemverilog
if (sda_i == 1'b0)
    next_state = SLV_TX;   // Master ACK -- continue sending
else
    next_state = SLV_IDLE;  // Master NACK -- stop sending
```

### Verification

Read tests with NACK termination work correctly, and the slave ceases transmission upon master NACK.

---

## Bug #5: Stretch Activation During Idle Causes False Stretches

- **File**: `rtl/i2c_slave_controller.sv`
- **Severity**: Moderate

### Description

The clock stretch logic activated whenever `stretch_en` was high, even when the slave was idle (not participating in a transaction). This could cause SCL to be held low when no transaction was occurring, potentially interfering with other devices on the bus.

### Root Cause

The stretch activation condition was `stretch_en && !stretch_active` without checking whether the slave was actually in a transaction.

### Fix

Changed the activation condition to include the `active_int` flag:

```systemverilog
// Before:
stretch_en && !stretch_active

// After:
stretch_en && !stretch_active && active_int
```

Stretch only activates when the slave is actively participating in a transaction.

### Verification

No spurious SCL holds observed during idle periods in any test.

---

## Bug #6: SLV_RX_ACK Doesn't Respect force_data_nack

- **File**: `rtl/i2c_slave_controller.sv`
- **Severity**: Feature (test hook)

### Description

Originally, the `SLV_RX_ACK` state always sent ACK for received data bytes. There was no mechanism to force a NACK response, making it impossible to test the master's data-NACK handling path.

### Root Cause

No test injection mechanism existed for data NACK. The ACK response was hardwired.

### Fix

Added a `force_data_nack` input port. In `SLV_RX_ACK`:

```systemverilog
if (active_int && !force_data_nack)
    sda_o <= 1'b0;  // ACK
else
    sda_o <= 1'b1;  // NACK
```

### Verification

`data_nack_test` sets `force_data_nack=1` via the slave agent, and the monitor observes `byte_ack=0` (NACK) as expected.

---

## Bug #7: Slave Agent ACTIVE/PASSIVE Config_db Override Failed

- **File**: `uvm/i2c_env.sv`
- **Severity**: Major (UVM testbench)

### Description

The environment always set the slave agent to `UVM_PASSIVE` via `uvm_config_db::set(this, "slave_agent", "is_active", UVM_PASSIVE)` in `build_phase`. Tests that needed the slave agent `UVM_ACTIVE` (e.g., `data_nack_test`, `clock_stretch_test`) could not override this because the env's set happened during `super.build_phase()` and overrode the test's prior set.

### Root Cause

UVM `config_db` follows a "last set wins" policy for the same resolution path. The env's set during `build_phase` overrode the test's earlier set when both used the same resolution path, because the test's context is a parent of the env's context and the env's more-specific set took precedence.

### Fix

Changed the env to use a "check-before-set" pattern:

```systemverilog
if (!uvm_config_db#(uvm_active_passive_enum)::get(this, "slave_agent", "is_active", slave_is_active)) begin
    uvm_config_db#(uvm_active_passive_enum)::set(this, "slave_agent", "is_active", UVM_PASSIVE);
end
```

Tests use `uvm_config_db#(...)::set(this, "env.slave_agent", "is_active", UVM_ACTIVE)` before calling `super.build_phase()`. The env's `get()` finds the test's set first and skips the PASSIVE default.

### Verification

`data_nack_test` and `clock_stretch_test` successfully activate the slave agent and drive stimulus.

---

## Bug #8: Multi-Driver on next_state in Master Controller

- **File**: `rtl/i2c_master_controller.sv`
- **Severity**: Critical

### Description

The `next_state` signal was driven in both the `always_ff` sequential block and the `always_comb` combinational block, creating a multi-driver synthesis error. This is a fundamental RTL coding error that would prevent synthesis.

### Root Cause

`next_state` was assigned in the sequential FSM block as `state <= next_state` but also driven by the combinational logic. Having the same signal driven from two always blocks is illegal in SystemVerilog synthesis.

### Fix

Removed all `next_state` assignments from the `always_ff` block. The `always_comb` block is now the sole driver of `next_state`. The `always_ff` only assigns `state <= next_state`.

### Verification

Synthesis-clean with no multi-driver warnings.

---

## Bug #9: SCL Permanently LOW During TX in Master Controller

- **File**: `rtl/i2c_master_controller.sv`
- **Severity**: Critical

### Description

During `STATE_TX_BIT`, `scl_o` was assigned `1'b0` in both branches of the timer comparison, causing SCL to never go high during data transmission. This effectively halted all communication on the bus.

### Root Cause

Incorrect timer comparison logic -- the HIGH phase condition was wrong. Both the "timer not expired" and "timer expired" branches drove `scl_o` low, so SCL was never released to go high.

### Fix

Corrected to proper toggle behavior: SCL is LOW for `T_SCL_LOW` clocks and HIGH for `T_SCL_HIGH` clocks, with proper `timer_expired` handling:

```systemverilog
STATE_TX_BIT: begin
    if (!timer_expired) begin
        scl_o <= current_phase;  // Hold current level
    end else begin
        // Toggle phase and reload timer
        scl_o <= ~current_phase;
    end
end
```

### Verification

Basic write and read transactions complete successfully with correct SCL timing.

---

## Summary

| # | Bug | File | Severity |
|---|-----|------|----------|
| 1 | Shift register captures ACK as data | `i2c_slave_controller.sv` | Critical |
| 2 | No TX shift register (high-Z on SDA) | `i2c_slave_controller.sv` | Critical |
| 3 | Clock stretch returns to idle | `i2c_slave_controller.sv` | Major |
| 4 | TX_ACK ignores master NACK | `i2c_slave_controller.sv` | Major |
| 5 | False stretches during idle | `i2c_slave_controller.sv` | Moderate |
| 6 | No force_data_nack test hook | `i2c_slave_controller.sv` | Feature |
| 7 | Slave agent config_db override fails | `i2c_env.sv` | Major |
| 8 | Multi-driver on next_state | `i2c_master_controller.sv` | Critical |
| 9 | SCL stuck LOW during TX | `i2c_master_controller.sv` | Critical |
| 10 | reg_data_buf never updated after RX — CPU reads 0x00 | `i2c_master_controller.sv` | Critical |
| 11 | A1 SVA is a tautology — never fires, detects nothing | `i2c_protocol_assertions.sv` | Medium |
| 12 | A2 SVA is a tautology — never fires, detects nothing | `i2c_protocol_assertions.sv` | Medium |
| 13 | i2c_reg_ptr_cg covers data byte value, not register access | `i2c_coverage.sv` | Minor |
| 14 | Stretch timer off-by-one (N+1 cycles instead of N) | `i2c_slave_controller.sv` | Minor |
| 15 | Dead code: SLV_IDLE start_cond check unreachable | `i2c_slave_controller.sv` | Minor |

---

## Bug #10: reg_data_buf Never Updated After RX

- **File**: `rtl/i2c_master_controller.sv`
- **Severity**: Critical

### Description

When the master executes CMD_READ_ACK or CMD_READ_NACK, received bits are shifted into `shift_reg` during STATE_RX_BIT. After all 8 bits are received, the FSM transitions to STATE_ACK_SEND. However, `reg_data_buf` — the register read by the CPU via REG_DATA — is never updated from `shift_reg`. The CPU reads 0x00 after every read transaction. This makes the master RTL non-functional for all read operations.

### Root Cause

The host interface `always_ff` block only writes `reg_data_buf` when the CPU drives `cpu_wr && cpu_addr == REG_DATA`. There was no RX data path back to the CPU-visible register.

### Fix

```systemverilog
// In host interface always_ff, add:
if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND) begin
  reg_data_buf <= shift_reg;
end
```

### Verification

`write_read_test` and `burst_read_test` now return correct byte values instead of 0x00.

---

## Bug #11: A1 SVA Assertion Is a Tautology

- **File**: `sva/i2c_protocol_assertions.sv`
- **Severity**: Medium

### Description

The original A1 property: `(scl_samp == 1'b1 && sda_fall) |-> (scl_samp == 1'b1)` has the consequent identical to part of the antecedent. It always passes — zero verification coverage.

### Fix

Changed to a meaningful temporal check: after START, SCL must fall within T_HD_STA + T_SCL_PERIOD cycles:
```systemverilog
(scl_samp == 1'b1 && sda_fall) |-> ##[1:(T_HD_STA + T_SCL_PERIOD)] (scl_samp == 1'b0);
```

---

## Bug #12: A2 SVA Assertion Is a Tautology

- **File**: `sva/i2c_protocol_assertions.sv`
- **Severity**: Medium

### Description

A2: `(scl_samp == 1'b1 && sda_rise) |-> (scl_samp == 1'b1 && sda_samp == 1'b1)`. Since `sda_rise` implies `sda_samp == 1'b1`, and `scl_samp==1'b1` is in the antecedent, consequent is always true.

### Fix

Changed to verify bus-free period after STOP:
```systemverilog
(scl_samp == 1'b1 && sda_rise) |-> ##[1:T_BUF] (scl_samp == 1'b1 && sda_samp == 1'b1);
```

---

## Bug #13: i2c_reg_ptr_cg Covers Wrong Signal

- **File**: `uvm/i2c_coverage.sv`
- **Severity**: Minor

### Description

`i2c_reg_ptr_cg` was labeled "Register Access" but covered `item.data[0]` (first data byte value 0–255). This has no relation to which register is being accessed.

### Fix

Changed coverpoint to `item.num_data` with bins representing single, partial, full, and over-the-bank burst lengths. This measures how many registers each transaction touches.

---

## Bug #14: Slave Stretch Timer Off-by-One

- **File**: `rtl/i2c_slave_controller.sv`
- **Severity**: Minor

### Description

The stretch timer starts at 0 and checks `>= stretch_cycles`. For a requested stretch of N cycles, the actual duration is N+1 cycles.

### Fix

Initialize `stretch_timer <= 16'd1` on activation. Timer then counts 1→2→...→N, fires at N: exactly N cycles.

---

## Bug #15: Dead Code in SLV_IDLE Case

- **File**: `rtl/i2c_slave_controller.sv`
- **Severity**: Minor

### Description

The FSM `always_comb` block checks `start_cond` at the top level before the `case` statement. The `SLV_IDLE` case branch re-checked `start_cond`, which can never be true at that point.

### Fix

Simplified to `next_state = SLV_IDLE` (the only reachable path within the case).
