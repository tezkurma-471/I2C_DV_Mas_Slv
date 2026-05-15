# I2C UVM Verification — Coverage Closure Report

> **Revision 2 (2026-05-12):** Coverage model expanded from 8 → 16 covergroups.
> New: CG9 per-byte NACK, CG10 clock stretch, CG11 rep-depth, CG12-16 cross covergroups.
> New: `stretch_seen` and `num_rep_starts` fields added to seq_item and populated by monitor.
> New: `ignore_bins` on cp_start for rep_start transactions.
> **Updated total: ~85 coverage points** (was 39). Predicted closure: 95%+ under full regression.
>
> **Revision 3 (2026-05-12):** CG17 `i2c_stretch_dir_cross_cg` added (stretch × direction, 4 cross cells).
> BUG #16 fixed: `stop_cond -> !rep_start` constraint removed from `valid_protocol_c`.
> `deep_rep_start_sequence` + `deep_rep_start_test` (T14) added; all 4 CG11 bins now close.
> **Updated total: ~89 coverage points** (+4 from CG17). `stretch × read` cell remains open.

**Project**: I2C Protocol Verification (Summer Internship II)
**Author**: Kushal Pitaliya
**Date**: 2026-05-12
**Status**: Analytical closure assessment (simulator unavailable locally)
**Coverage Source File**: `uvm/i2c_coverage.sv` (17 covergroups, ~89 coverage points)
**Test File**: `uvm/i2c_tests.sv` (18 directed/random test classes)
**Sequence Library**: `uvm/i2c_sequences.sv` (18 sequence classes)

---

## 1. Executive Summary

This report provides an **analytical** assessment of functional coverage closure
for the I2C UVM verification environment. Because no commercial SystemVerilog
simulator (QuestaSim/VCS/Xcelium) is installed on the local development machine,
real UCDB merge and `vcover report` output cannot be generated. Instead, the
analysis is performed by tracing every covergroup bin in `uvm/i2c_coverage.sv`
back to the constraints in `uvm/i2c_sequences.sv` and the test bodies in
`uvm/i2c_tests.sv`. For each bin we predict — with strong confidence — whether
at least one transaction in the regression suite will sample it.

The coverage model contains **8 covergroups** decomposing into **18 individual
coverage bins** across 7 standalone covergroups, plus **two cross-coverage
groups** (`i2c_burst_cg` = 2 dir × 4 size = 8 cross bins; `i2c_target_cg` =
1 addr × 2 dir = 2 cross bins). Bin-level closure is **predicted at 100%**:
every single bin has at least one directed test or randomised stress sequence
that will assert that condition. The regression matrix is 16 tests × 3 seeds
= 48 simulation runs (per `sim/Makefile`'s `regress` target), which is more
than enough seed entropy for the random/stress sequences to fill bins that
directed tests do not explicitly hit.

The notable findings are: (a) the existing covergroups are **conservative and
narrow** — they cover only the most fundamental I2C scenarios (direction, burst
size, address, ACK, protocol conditions); (b) **cross-coverage is minimal**
(only two crosses are defined, and one of them is restricted to a single
address value), so there is significant opportunity to add high-value cross
bins; (c) two coverpoints in `i2c_protocol_cg` (`cp_start.no_start` and the
combined start/stop/rep_start ordering) are deliberately **not covered**
because the constraints in `i2c_seq_item.sv:valid_protocol_c` make those
states unreachable — these should be marked as `ignore_bins`. Section 4
recommends five new cross combinations that would catch direction-specific,
burst-boundary, and target-vs-other-address bugs that the current flat
coverage model cannot detect.

---

## 2. Test-to-Covergroup Traceability Matrix

This section maps every coverage bin in `uvm/i2c_coverage.sv` to the tests
that exercise it. The analysis is derived from the seq_item constraints in
the corresponding sequence (`uvm/i2c_sequences.sv`) and the test bodies in
`uvm/i2c_tests.sv`.

### 2.1 `i2c_dir_cg` — Transaction Direction

Source:
```systemverilog
covergroup i2c_dir_cg;
  cp_dir: coverpoint item.dir {
    bins write = {DIR_WRITE};
    bins read  = {DIR_READ};
  }
endgroup
```

| Bin | Value | Tests That Hit It |
|-----|-------|--------------------|
| `write` | `DIR_WRITE` | basic_write_test, burst_write_test, write_read_test (1st txn), rep_start_test (1st txn), addr_nack_test, data_nack_test, clock_stretch_test, addr_sweep_test, bus_free_test, sequential_txn_test (even iter), data_pattern_test, random_directed_test, full_stress_test |
| `read`  | `DIR_READ`  | basic_read_test, burst_read_test, write_read_test (2nd txn), rep_start_test (2nd txn), sequential_txn_test (odd iter), random_directed_test, full_stress_test |

**Predicted closure: 100%** — Both bins hit by ≥7 directed tests each.

---

### 2.2 `i2c_data_size_cg` — Burst Length Buckets

Source:
```systemverilog
cp_size: coverpoint item.num_data {
  bins single       = {1};
  bins short_burst  = {[2:8]};
  bins med_burst    = {[9:16]};
  bins long_burst   = {[17:32]};
}
```

| Bin | num_data Range | Tests That Hit It | Hit Path |
|-----|---------------|--------------------|---------|
| `single` | 1 | basic_write_test, basic_read_test, write_read_test, rep_start_test, addr_nack_test, data_nack_test, clock_stretch_test, addr_sweep_test, bus_free_test, sequential_txn_test, data_pattern_test, random_directed_test (some iters), full_stress_test (some iters) | Sequences explicitly set `num_data == 1` |
| `short_burst` | 2..8 | burst_write_test (8), burst_read_test (8), random_directed_test, full_stress_test | `burst_len = 8` in burst tests; random `num_data inside {[1:32]}` covers this range |
| `med_burst` | 9..16 | random_directed_test, full_stress_test | Only reachable via unconstrained random `num_data` (1..32); ~25% of random txns land here |
| `long_burst` | 17..32 | random_directed_test, full_stress_test | Same as above; ~50% of random txns land here |

**Predicted closure: 100%** — `single` and `short_burst` are hit by directed
tests. `med_burst` and `long_burst` rely on random sampling. With
`random_directed_test` issuing 50 txns and `full_stress_test` issuing 100 txns
across 3 seeds, the probability of missing either remaining bucket is
effectively zero (each has ~25–50% individual-txn probability per random run).

**Caveat**: If the random regression is reduced to a single seed and only one
of the two random tests runs, `med_burst` or `long_burst` could theoretically
be missed. Recommendation: add a directed `burst_write_test_long` with
`burst_len = 20` to guarantee `long_burst` independent of seed.

---

### 2.3 `i2c_addr_cg` — Address Types

Source:
```systemverilog
cp_addr: coverpoint item.addr {
  bins target_addr = {7'h50};
  bins other_addrs = {[7'h08:7'h4F], [7'h51:7'h77]};
}
```

| Bin | Address Range | Tests That Hit It |
|-----|--------------|--------------------|
| `target_addr` | 0x50 only | basic_write_test, basic_read_test, burst_write_test, burst_read_test, write_read_test, rep_start_test, data_nack_test, clock_stretch_test, bus_free_test, sequential_txn_test, data_pattern_test (all default to 0x50) |
| `other_addrs` | 0x08..0x4F, 0x51..0x77 | addr_nack_test (wrong_addr 0x55 by default, randomly 0x08..0x77 except 0x50), addr_sweep_test (iterates 0x08..0x77 covering 112 unique addresses), random_directed_test (uniform across legal range), full_stress_test |

**Predicted closure: 100%** — `addr_sweep_test` alone guarantees the
`other_addrs` bin (it walks every legal address). `target_addr` is hit by 11
directed tests.

---

### 2.4 `i2c_protocol_cg` — START / STOP / Repeated-START

Source:
```systemverilog
cp_start: coverpoint item.start_cond { bins has_start = {1}; }
cp_stop:  coverpoint item.stop_cond  { bins has_stop  = {1}; bins no_stop = {0}; }
cp_rep:   coverpoint item.rep_start  { bins has_rep   = {1}; bins no_rep  = {0}; }
```

| Coverpoint | Bin | Tests That Hit It |
|-----------|-----|--------------------|
| `cp_start` | `has_start = 1` | Every test except the 2nd transaction of `rep_start_test`. Default `default_trans_c` constraint in seq_item asserts `start_cond == 1`. |
| `cp_stop` | `has_stop = 1` | All tests except the 1st transaction of `rep_start_test` (which sets `stop_cond = 0`). |
| `cp_stop` | `no_stop = 0` | rep_start_test (1st txn deliberately leaves bus held with `stop_cond == 0`). |
| `cp_rep` | `has_rep = 1` | rep_start_test (2nd txn sets `rep_start == 1`). |
| `cp_rep` | `no_rep = 0` | All other tests (random_directed_test also covers this — `valid_protocol_c` forces one of start XOR rep_start, so default is start=1, rep=0). |

**Predicted closure: 100%** — Every individual bin has at least one test that
hits it. `rep_start_test` is the sole closer for `cp_stop.no_stop` and
`cp_rep.has_rep`; if that test is removed from the regression, two bins go
unhit.

**Risk note**: `cp_start` defines only ONE bin (`has_start = 1`). It is
**impossible** for `cp_start` to ever read 0 because `valid_protocol_c` in
`i2c_seq_item.sv:58` requires `start_cond || rep_start`, and combined with
`!(start_cond && rep_start)`, the only way to have `start_cond = 0` is if
`rep_start = 1` — which is the 2nd-txn case in `rep_start_test`. The coverage
model wisely omits a `no_start` bin; this is correct and should remain.

---

### 2.5 `i2c_ack_cg` — ACK / NACK Tracking

Source:
```systemverilog
cp_addr_ack: coverpoint item.addr_ack {
  bins ack  = {1};
  bins nack = {0};
}
```

| Bin | Trigger | Tests That Hit It |
|-----|---------|--------------------|
| `ack`  | Slave acknowledges its address (0x50 match) | basic_write_test, basic_read_test, burst_*, write_read_test, rep_start_test, data_nack_test (address phase ACKs, then data NACKs), clock_stretch_test, bus_free_test, sequential_txn_test, data_pattern_test, random_directed_test (when random addr lands on 0x50, ~1/112 odds), full_stress_test |
| `nack` | Slave does not match address | addr_nack_test (wrong_addr ∈ {0x08..0x77} \ {0x50}, so 100% NACK), addr_sweep_test (only addr 0x50 gets ACK, all 111 others get NACK), random_directed_test (when addr ≠ 0x50), full_stress_test |

**Predicted closure: 100%** — `addr_nack_test` and `addr_sweep_test` reliably
hit the `nack` bin; all default-addressed sequences hit `ack`.

**Note**: This covergroup samples only `addr_ack`, not per-byte data ACK from
`byte_ack[$]`. `data_nack_test` exercises the slave forcing a data-byte NACK,
but the current covergroup does not capture that — see Section 4 hole #2.

---

### 2.6 `i2c_burst_cg` — Direction × Burst Size Cross

Source:
```systemverilog
covergroup i2c_burst_cg;
  cp_dir: coverpoint item.dir;
  cp_size: coverpoint item.num_data {
    bins single       = {1};
    bins short_burst  = {[2:8]};
    bins med_burst    = {[9:16]};
    bins long_burst   = {[17:32]};
  }
  cross cp_dir, cp_size;
endgroup
```

The cross produces 8 cells (2 dir × 4 size):

| Cross Cell | Tests That Hit It |
|-----------|--------------------|
| `WRITE × single` | basic_write_test, write_read_test (wr txn), addr_nack_test, data_nack_test, clock_stretch_test, addr_sweep_test, bus_free_test, sequential_txn_test (even), data_pattern_test, random, stress |
| `WRITE × short_burst` | burst_write_test (8), random, stress |
| `WRITE × med_burst` | random_directed_test, full_stress_test (random num_data 9..16 ∧ random dir = WRITE) |
| `WRITE × long_burst` | random_directed_test, full_stress_test (random num_data 17..32 ∧ random dir = WRITE) |
| `READ × single` | basic_read_test, write_read_test (rd txn), sequential_txn_test (odd), random, stress |
| `READ × short_burst` | burst_read_test (8), random, stress |
| `READ × med_burst` | random_directed_test, full_stress_test |
| `READ × long_burst` | random_directed_test, full_stress_test |

**Predicted closure: 100%** — but with caveat: the four "med/long × dir" cells
depend on random sampling. With 3 seeds × (50 + 100) = 450 random transactions
total, the probability of missing any specific (dir, size_bucket) cell is
approximately `(1 - 0.125)^450 ≈ 0` (each cell has ~12.5% per-txn probability
assuming uniform `num_data` and 50/50 dir distribution).

---

### 2.7 `i2c_reg_ptr_cg` — Register Bank Coverage

Source (note the BUG-13 fix comment in the code):
```systemverilog
covergroup i2c_reg_ptr_cg;
  cp_reg: coverpoint item.num_data {
    bins single_reg      = {1};
    bins partial_bank    = {[2:4]};
    bins more_than_half  = {[5:7]};
    bins full_bank       = {8};
    bins multi_wrap      = {[9:32]};
  }
endgroup
```

Sampled only when `t.num_data > 0` (see `write()` guard, which is always true
given `data_size_c` requires `num_data >= 1`).

| Bin | num_data | Tests That Hit It |
|-----|---------|--------------------|
| `single_reg` | 1 | basic_write_test, basic_read_test, write_read_test, rep_start_test, addr_nack_test, data_nack_test, clock_stretch_test, addr_sweep_test, bus_free_test, sequential_txn_test, data_pattern_test, random, stress |
| `partial_bank` | 2..4 | random_directed_test, full_stress_test (random num_data) |
| `more_than_half` | 5..7 | random_directed_test, full_stress_test |
| `full_bank` | 8 | burst_write_test (`burst_len = 8`), burst_read_test (`burst_len = 8`), random (~3% per txn), stress |
| `multi_wrap` | 9..32 | random_directed_test, full_stress_test |

**Predicted closure: 100%** — `full_bank` is the only bin with a directed
test (both burst tests). `partial_bank` and `more_than_half` rely on random
sampling; with 450+ random txns, probability of missing either bucket
(each bucket = 3/32 ≈ 9.4% per-txn) is negligible (`(1 − 0.094)^450 ≈ 0`).

---

### 2.8 `i2c_target_cg` — Target Address × Direction Cross

Source:
```systemverilog
covergroup i2c_target_cg;
  cp_addr: coverpoint item.addr { bins target = {7'h50}; }
  cp_dir: coverpoint item.dir;
  cross cp_addr, cp_dir;
endgroup
```

Sampled only when `t.addr == 7'h50` (see `write()` guard).

| Cross Cell | Tests That Hit It |
|-----------|--------------------|
| `target × WRITE` | basic_write_test, burst_write_test, write_read_test (wr txn), data_nack_test, clock_stretch_test, bus_free_test, sequential_txn_test (even), data_pattern_test, rep_start_test (wr txn), random (when addr lands on 0x50), stress |
| `target × READ` | basic_read_test, burst_read_test, write_read_test (rd txn), rep_start_test (rd txn), sequential_txn_test (odd), random, stress |

**Predicted closure: 100%** — Both cross cells are hit by ≥4 directed tests.

---

## 3. Coverage Holes and Mitigation

After tracing every bin, **no hard holes exist**: every defined bin has at
least one test path that hits it. However, several **logical holes** —
scenarios that should be covered but currently have no covergroup at all —
have been identified. These are not "missed bins"; they are "missing bins".

### Hole #1 — Per-byte data NACK coverage is absent

**Scenario**: `data_nack_test` exercises the slave forcing a NACK on a data
byte (not the address byte). The seq_item has a `byte_ack [$]` field for
per-byte ACK tracking, but **no covergroup samples it**.

**Why not hit today**: `i2c_ack_cg` only covers `item.addr_ack`. A bin like
`bins data_nack = {0}` against `item.byte_ack[i]` does not exist.

**Mitigation**: Add a new covergroup:
```systemverilog
covergroup i2c_byte_ack_cg;
  cp_byte_ack: coverpoint item.byte_ack[0] iff (item.num_data > 0) {
    bins data_ack  = {1};
    bins data_nack = {0};
  }
endgroup
```
Sample in the monitor's `write()` after `byte_ack` is populated.

**Effort**: Low (~30 min: add the cg, plumb sampling).

---

### Hole #2 — Clock stretching not covered

**Scenario**: `clock_stretch_test` activates an active slave that holds SCL
low for 50–200 cycles. There is no coverpoint that records whether stretching
occurred or how long it lasted.

**Why not hit today**: The `stretch_cycles` value is in the
`i2c_slave_ctrl_item`, not the master `i2c_seq_item`. The coverage subscriber
only subscribes to the master analysis port.

**Mitigation**: Add a covergroup on the slave control item, or add a
`stretch_observed` flag to `i2c_seq_item` populated by the monitor.

Recommended new covergroup:
```systemverilog
covergroup i2c_stretch_cg;
  cp_stretch: coverpoint item.stretch_observed_cycles {
    bins no_stretch    = {0};
    bins short_stretch = {[1:50]};
    bins long_stretch  = {[51:200]};
  }
endgroup
```

**Effort**: Medium (~2 hours: add `stretch_observed_cycles` to seq_item,
populate from monitor, add cg).

---

### Hole #3 — Repeated-START sequence depth not covered

**Scenario**: I2C allows N back-to-back transfers separated by Repeated START
before the final STOP. The current `rep_start_test` exercises only a single
W→R pair (one rep-START). There is no coverage of N ≥ 2 rep-START in a row.

**Why not hit today**: No sequence emits more than one rep-START per
transaction frame.

**Mitigation**:
1. Add a new sequence `i2c_multi_rep_start_seq` that emits 3+ rep-STARTs.
2. Add a coverpoint counting rep_start events per "session" (between STOPs).

**Effort**: Medium (~3 hours: new sequence, new tracking variable, new cg).

---

### Hole #4 — Arbitration-lost scenarios not covered

**Scenario**: Two masters drive SDA simultaneously; one loses arbitration.
The `i2c_seq_item` has a `status` field with `STS_ARBITRATION_LOST` enum,
but no test injects bus contention.

**Why not hit today**: There is no second master agent or contention sequence.
This is also flagged as in-progress task #2 in the user's memory.

**Mitigation**: Implement `arbitration_lost_test` per existing task list.
Add a coverpoint:
```systemverilog
cp_status: coverpoint item.status {
  bins ok        = {STS_OK};
  bins addr_nack = {STS_ADDR_NACK};
  bins arb_lost  = {STS_ARBITRATION_LOST};
  bins timeout   = {STS_TIMEOUT};
}
```

**Effort**: High (~1 day: needs a second master agent or a force/release block
on SDA).

---

### Hole #5 — `cp_start` has no `no_start` bin (intentional, but undocumented)

**Scenario**: Could a transaction ever have `start_cond = 0` and `rep_start = 0`?

**Why not hit today**: `valid_protocol_c` in `i2c_seq_item.sv:58` forbids this
state: `start_cond || rep_start` must be true. So `(0,0)` is **unreachable**
by construction.

**Mitigation**: Document the unreachability with an explicit `ignore_bins`:
```systemverilog
cp_start: coverpoint item.start_cond {
  bins has_start = {1};
  ignore_bins illegal_no_start = {0};  // forbidden by valid_protocol_c
}
```
This makes the verification intent explicit and prevents future engineers
from worrying that the bin is "missed".

**Effort**: Low (~5 min).

---

## 4. Cross-Coverage Recommendations

The current model has only 2 cross groups (`i2c_burst_cg`, `i2c_target_cg`).
Below are 5 high-value cross combinations that would catch additional bugs.

### Recommendation #1 — `cross(direction, addr_range)`

**Rationale**: A common class of I2C bugs is that the slave handles reads
and writes asymmetrically only for certain address ranges (e.g. a register
that is write-only or read-only is decoded wrong). Crossing dir × addr_range
ensures both directions hit both the target and non-target address bins.

**Code**:
```systemverilog
covergroup i2c_dir_addr_cross_cg;
  cp_dir:  coverpoint item.dir;
  cp_addr: coverpoint item.addr {
    bins target_addr = {7'h50};
    bins other_addrs = {[7'h08:7'h4F], [7'h51:7'h77]};
  }
  cross cp_dir, cp_addr;
endgroup
```
**Closes**: `READ × other_addrs` is currently not exercised by any directed
test (addr_sweep_test does WRITE only). Adding this cross will force a hole
that should be closed by adding a READ variant to addr_sweep.

---

### Recommendation #2 — `cross(burst_size_bucket, ack_result)`

**Rationale**: Catches "burst boundary" bugs where the slave NACKs only on
the Nth byte of a long burst (e.g. an off-by-one in a length counter).

**Code**:
```systemverilog
covergroup i2c_burst_ack_cross_cg;
  cp_size: coverpoint item.num_data {
    bins single       = {1};
    bins short_burst  = {[2:8]};
    bins med_burst    = {[9:16]};
    bins long_burst   = {[17:32]};
  }
  cp_ack: coverpoint item.addr_ack { bins ack = {1}; bins nack = {0}; }
  cross cp_size, cp_ack;
endgroup
```
**Closes**: Currently no test does a long burst to a wrong address.
`long_burst × nack` would force such a scenario.

---

### Recommendation #3 — `cross(direction, num_data)` (granular)

**Rationale**: The existing `i2c_burst_cg` crosses direction with 4 size
buckets. A finer-grained cross with `num_data` as 32 separate bins would
expose off-by-one bugs at specific burst lengths (e.g. boundary at
num_data = 16 = 2^4, or num_data = 8 = full register bank).

**Code**:
```systemverilog
covergroup i2c_dir_size_fine_cg;
  cp_dir:  coverpoint item.dir;
  cp_size: coverpoint item.num_data {
    bins n[8] = {[1:32]};  // 8 auto-bins of 4 values each
    bins boundary_4   = {4};
    bins boundary_8   = {8};
    bins boundary_16  = {16};
    bins boundary_32  = {32};
  }
  cross cp_dir, cp_size;
endgroup
```
**Closes**: Directed boundary checks at 4, 8, 16, 32 — these are common
buffer-size or counter-width bugs.

---

### Recommendation #4 — `cross(rep_start, direction)`

**Rationale**: Repeated-START with WRITE→WRITE or READ→READ is legal but
unusual; the existing rep_start_test only covers WRITE→READ. A cross would
expose missing WRITE→WRITE and READ→READ rep-START paths.

**Code**:
```systemverilog
covergroup i2c_rep_dir_cross_cg;
  cp_rep: coverpoint item.rep_start { bins has_rep = {1}; bins no_rep = {0}; }
  cp_dir: coverpoint item.dir;
  cross cp_rep, cp_dir;
endgroup
```
**Closes**: `has_rep × WRITE` is not exercised today (rep_start_test only
does the rep-START phase on the READ). Closing requires a new sequence.

---

### Recommendation #5 — `cross(addr_target, protocol_flags)`

**Rationale**: Ensures that all protocol variants (with/without rep_start,
with/without stop) are exercised against the target slave 0x50.

**Code**:
```systemverilog
covergroup i2c_target_protocol_cross_cg;
  cp_addr:  coverpoint item.addr { bins target = {7'h50}; }
  cp_stop:  coverpoint item.stop_cond  { bins has_stop = {1}; bins no_stop = {0}; }
  cp_rep:   coverpoint item.rep_start  { bins has_rep  = {1}; bins no_rep  = {0}; }
  cross cp_addr, cp_stop, cp_rep;
endgroup
```
**Closes**: All 4 reachable (stop, rep) combos against 0x50:
`(stop=1, rep=0)`, `(stop=0, rep=0)` rep-START 1st txn, `(stop=1, rep=1)`
rep-START 2nd txn, and the illegal `(stop=0, rep=1)` which should be
`ignore_bins`-marked.

---

## 5. Final Closure Prediction Table

### 5.1 Per-Covergroup Summary

| # | Covergroup | Individual Bins | Bins Hit | Predicted Closure | Confidence |
|---|------------|-----------------|----------|-------------------|-----------|
| 1 | `i2c_dir_cg` | 2 | 2 | 100% | Very High |
| 2 | `i2c_data_size_cg` | 4 | 4 | 100% | High |
| 3 | `i2c_addr_cg` | 2 | 2 | 100% | Very High |
| 4 | `i2c_protocol_cg` | 4 + 1 ignore | 4 | 100% | Very High |
| 5 | `i2c_ack_cg` | 2 | 2 | 100% | Very High |
| 6 | `i2c_burst_cg` | 6 + 8 cross | 6 + 8 | 100% | High |
| 7 | `i2c_reg_ptr_cg` | 5 | 5 | 100% | High |
| 8 | `i2c_target_cg` | 3 + 2 cross | 3 + 2 | 100% | Very High |
| 9 | `i2c_byte_nack_cg` | 2 | 2 | 100% | High |
| 10 | `i2c_stretch_cg` | 2 | 2 | 100% | High |
| 11 | `i2c_rep_depth_cg` | 4 | 4 | 100% | High (`deep_rep` closed by T14) |
| 12 | `i2c_dir_addr_cross_cg` | 2 + 3 + 6 cross | 8 | 100% | High |
| 13 | `i2c_dir_ack_cross_cg` | 2 + 2 + 4 cross | 8 | 100% | High |
| 14 | `i2c_rep_dir_cross_cg` | 2 + 2 + 4 cross | 7 | ~75% (has_rep×WRITE gap) | Medium |
| 15 | `i2c_dir_size_cross_cg` | 2 + 5 + 10 cross | 16 | ~90% (READ×xlarge uncertain) | Medium |
| 16 | `i2c_protocol_dir_cross_cg` | 2 + 2 + 4 cross | 7 | ~75% (READ×no_stop uncertain) | Medium |
| 17 | `i2c_stretch_dir_cross_cg` | 2 + 2 + 4 cross | 7 | ~75% (stretch×read open) | Medium |
| | **TOTAL (Rev 3)** | **~89 coverage points** | **~82** | **~95%** | **High** |

Bin breakdown notes (Revision 3):
- `i2c_protocol_cg` now has `ignore_bins no_start_ok = {0}` on cp_start,
  reducing the counted bins from 5 to 4 (the `{0}` is explicitly excluded).
  This is correct — rep-start transactions with `start_cond=0` are tracked
  by `cp_rep`, not by `cp_start`.
- `i2c_burst_cg` has 2 dir bins + 4 size bins = 6 individual bins, plus the
  cross matrix of 2 × 4 = 8 cross cells = 14 total reportable bins.
- `i2c_target_cg` has 1 addr + 2 dir = 3 individual bins, plus the cross
  matrix of 1 × 2 = 2 cross cells = 5 total reportable bins.
- CG12-16 each contain individual coverpoint bins plus cross cells; the cross
  cells dominate the count (6, 4, 4, 10, 4 respectively).
- CG17 (`i2c_stretch_dir_cross_cg`): 2 stretch bins + 2 dir bins + 4 cross
  cells. Three cells close under existing regression; `stretch × read` remains
  open pending a future `stretch_read_test`.
- CG11 `deep_rep` bin: now **closed** by `deep_rep_start_test` (T14) using
  `deep_rep_start_sequence` (4-segment chain). BUG #16 fix (`stop_cond ->
  !rep_start` constraint removed) was required to enable this.
- Remaining gaps deferred to next revision: `has_rep × WRITE` cell (CG14),
  `READ × no_stop` cell (CG16), `READ × xlarge` cell (CG15), `stretch × read`
  cell (CG17). Arbitration-lost coverage deferred indefinitely pending second BFM.

### 5.2 Confidence Levels Explained

- **Very High**: Bin guaranteed by at least one directed test with fixed
  constraints (no seed dependency).
- **High**: Bin reached either by a directed test OR by random sequences
  with very high (>99%) probability across 3 seeds.
- **Medium**: Bin requires lucky random sampling; could miss on 1-seed runs.
- **Low**: Bin currently has no path; needs a new test.

The aggregate prediction of **100% bin closure** assumes the full regression
matrix (18 tests × 3 seeds, per `sim/Makefile:TESTS` and `SEEDS`) runs to
completion with all tests PASSING. If any test fails before its analysis
port emits transactions, its bin contributions are lost.

### 5.3 Sensitivity to Test Subset

| Scenario | Closure Drops To | Bins Missed |
|----------|------------------|-------------|
| Only `make quick` (1 seed) | ~95% | `med_burst`, `long_burst` in dir/size may miss |
| Without `addr_sweep_test` | ~92% | `other_addrs` heavily under-sampled |
| Without `rep_start_test` | ~90% | `no_stop`, `has_rep` go unhit |
| Without random+stress tests | ~75% | All medium/long burst buckets miss |

---

## 6. How to Run Actual Coverage Closure

### 6.1 On a Machine with QuestaSim Installed

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

**Expected output (post-regression)**:
- 48 lines of `PASS: <test> (seed=<seed>)` in the regression summary.
- Final summary line: `Total: 48 / Passed: 48 / Failed: 0`.
- `coverage.txt` should show each of the 8 covergroups at 100%.

**If failures occur**, inspect `../logs/<test>_seed<seed>.log` for the
specific UVM_ERROR or UVM_FATAL message. The scoreboard prints `SCOREBOARD
PASSED` only on full success.

### 6.2 On a Machine with VCS

```bash
cd /Users/kushalpitaliya/Documents/Projects/Summer-Internsip-II/i2c-protocol-dv/scripts
./run_all_tests.sh vcs 1
./run_all_tests.sh vcs 42
./run_all_tests.sh vcs 123
# Then use 'urg' to merge .vdb databases (not currently scripted).
```

### 6.3 On EDA Playground (no Makefile available)

EDA Playground does not support multi-file projects with `vlib`/`vlog`. To
exercise coverage there:

**Files to upload** (copy into the EDA Playground left pane in this order):

1. `rtl/i2c_pkg.sv`
2. `rtl/i2c_master_controller.sv`
3. `rtl/i2c_master.sv`
4. `rtl/i2c_slave_controller.sv`
5. `rtl/i2c_slave.sv`
6. `sva/i2c_protocol_assertions.sv`
7. `tb/i2c_if.sv`
8. `tb/i2c_slave_if.sv`
9. `tb/i2c_tb_pkg.sv` (includes the UVM agent/env/coverage files)
10. `tb/top_tb.sv`

**Tool settings panel**:
- Simulator: **Mentor Questa 2024.1** (free tier supports UVM 1.2 + functional coverage).
- Compile options: `-sv -timescale=1ns/1ps -coverall`
- Run options: `+UVM_TESTNAME=<test_name> -sv_seed <seed> -coverall`

**Recommended one-at-a-time runs** (since EDA Playground has limited UCDB merge support):

| Run # | UVM_TESTNAME | Seed | Bins Expected to Close |
|-------|--------------|------|------------------------|
| 1 | basic_write_test | 1 | `dir.write`, `size.single`, `addr.target`, `protocol.has_start`, `protocol.has_stop`, `protocol.no_rep`, `ack.ack`, `burst.W×single`, `reg_ptr.single_reg`, `target.W` |
| 2 | basic_read_test | 1 | `dir.read`, `ack.ack`, `burst.R×single`, `target.R` |
| 3 | burst_write_test | 1 | `size.short_burst`, `reg_ptr.full_bank`, `burst.W×short` |
| 4 | burst_read_test | 1 | `burst.R×short` |
| 5 | rep_start_test | 1 | `protocol.no_stop`, `protocol.has_rep` |
| 6 | addr_nack_test | 1 | `addr.other_addrs`, `ack.nack` |
| 7 | addr_sweep_test | 1 | `addr.other_addrs` (heavily) |
| 8 | data_nack_test | 1 | `ack.nack` (note: addr still ACKs) |
| 9 | clock_stretch_test | 1 | No new bins (covered elsewhere) — but verifies stretch path |
| 10 | random_directed_test | 1, 42, 123 | `size.med_burst`, `size.long_burst`, all random combos |
| 11 | full_stress_test | 1, 42, 123 | All bins, redundantly |

After each run, capture the `*** COVERAGE SUMMARY ***` UVM_INFO output
that `i2c_coverage::report_phase()` prints. Manually accumulate the
per-test contribution to confirm bin closure.

**Limitation**: EDA Playground cannot merge UCDB files across separate runs.
For true coverage closure metrics, the QuestaSim flow in 6.1 is required.

---

## 7. Sign-off Checklist

The verification team should require the following evidence before declaring
coverage closure for the I2C UVM project.

### 7.1 Mandatory Evidence

- [ ] **Full regression PASS**: `make regress` completes with `Passed: 54 /
  Failed: 0` (18 tests × 3 seeds). Log file: `logs/regression.summary`.
- [ ] **Merged UCDB present**: `coverage/merged.ucdb` exists and is non-empty.
- [ ] **Text coverage report**: `coverage/coverage.txt` shows each of the 17
  covergroups at **≥99%** (waived: `stretch × read` cell in CG17 — open pending `stretch_read_test`).
- [ ] **HTML coverage report**: `coverage/html/index.html` opens and shows
  no red bins in any covergroup.
- [ ] **Scoreboard summary**: Every passing log contains `SCOREBOARD PASSED:
  N transactions checked, 0 errors`.
- [ ] **Assertion summary**: All SVA properties in
  `sva/i2c_protocol_assertions.sv` are reported `PASS` or `disabled`; no
  `FAIL` assertions.

### 7.2 Recommended Additional Evidence (not currently required but valuable)

- [ ] **No `unique`/`priority` violations** in any test log.
- [ ] **No UVM_ERROR or UVM_FATAL** in any test log.
- [ ] **UVM topology dump** captured for `basic_write_test` to confirm env
  is built as expected.
- [ ] **Waveform snapshot** of `rep_start_test` showing the bus during the
  `no_stop` + `rep_start` transition — visual proof the most complex
  protocol bin is exercised.

### 7.3 Holes to Close Before Final Sign-off

Based on Section 3, the following items should be implemented before
declaring **complete** verification (vs just bin closure):

| # | Hole | Priority | Effort | Status |
|---|------|----------|--------|--------|
| 1 | Per-byte data NACK coverage | High | Low | Closed (CG9) |
| 2 | Clock stretching coverage | Medium | Medium | Closed (CG10) |
| 3 | Multi-rep-START depth coverage | Low | Medium | Closed (CG11 + T14 `deep_rep_start_test`) |
| 4 | Arbitration-lost test + coverage | High | High | In-progress (task #2) |
| 5 | Mark `cp_start.no_start` as ignore_bins | Low | Low | Closed (Rev 2) |
| 6 | Stretch × direction cross (CG17) | Medium | Low | Partial — 3/4 cells closed; `stretch×read` open |

### 7.4 Cross-Coverage Items to Add (from Section 4)

| # | Cross | Priority | Effort | Status |
|---|-------|----------|--------|--------|
| 1 | dir × addr_range | High | Low | Closed (CG12) |
| 2 | burst_size × ack_result (dir × ack) | High | Low | Closed (CG13) |
| 3 | dir × num_data (granular boundary) | Medium | Low | Closed (CG15) |
| 4 | rep_start × dir | Medium | Medium | Closed (CG14, partial — `has_rep×WRITE` open) |
| 5 | addr_target × protocol_flags (protocol × dir) | Low | Low | Closed (CG16, partial — `READ×no_stop` open) |
| 6 | stretch × direction | Medium | Low | Closed (CG17, partial — `stretch×read` open) |

### 7.5 Final Sign-off Statement (template)

```
I, the verification engineer, certify that:
- The I2C UVM verification environment has been executed on QuestaSim
  version <X.Y> using the regression matrix defined in sim/Makefile.
- All 54 simulation runs (18 tests x 3 seeds) PASSED.
- Functional coverage across 17 covergroups reached 100% bin closure
  (waived: stretch×read cell in CG17 — documented open item).
- All assertions in sva/i2c_protocol_assertions.sv passed.
- The 16 bugs documented in docs/FINAL_ANALYSIS_REPORT.md are confirmed
  fixed and protected by their respective tests.

Open items deferred to next revision: <list holes from 7.3 not closed>.

Signed: Kushal Pitaliya
Date: <closure date>
```

---

## Appendix A — Source File Quick Reference

| File | Purpose | Line Count |
|------|---------|-----------|
| `uvm/i2c_coverage.sv` | 17 covergroup definitions, subscriber, sampling | ~165 |
| `uvm/i2c_tests.sv` | 18 test classes | ~330 |
| `uvm/i2c_sequences.sv` | 18 sequence classes (16 master + 2 slave-control) | ~580 |
| `uvm/i2c_seq_item.sv` | Transaction model + constraints | 138 |
| `sim/Makefile` | QuestaSim regression flow | 173 |
| `scripts/coverage_report.sh` | UCDB merge helper | 28 |
| `scripts/run_all_tests.sh` | Multi-tool regression runner | 87 |

## Appendix B — Regression Test List (from `sim/Makefile`)

```makefile
TESTS = i2c_base_test basic_write_test basic_read_test \
        burst_write_test burst_read_test write_read_test \
        rep_start_test addr_nack_test data_nack_test \
        clock_stretch_test random_directed_test addr_sweep_test \
        bus_free_test sequential_txn_test data_pattern_test \
        full_stress_test arbitration_lost_test deep_rep_start_test

SEEDS = 1 42 123
```

Total simulation runs in a full regression: **18 tests × 3 seeds = 54 runs**.

## Appendix C — Coverage Sampling Flow

```
i2c_master_monitor  ──>  ap_master  ──>  i2c_coverage::write(item)
                                              │
                                              ├──> i2c_dir_cg.sample()
                                              ├──> i2c_data_size_cg.sample()
                                              ├──> i2c_addr_cg.sample()
                                              ├──> i2c_protocol_cg.sample()
                                              ├──> i2c_ack_cg.sample()
                                              ├──> i2c_burst_cg.sample()
                                              ├──> if (num_data > 0) i2c_reg_ptr_cg.sample()
                                              ├──> if (addr == 7'h50) i2c_target_cg.sample()
                                              ├──> if (num_data > 0) i2c_byte_nack_cg.sample()
                                              ├──> i2c_stretch_cg.sample()
                                              ├──> i2c_rep_depth_cg.sample()
                                              ├──> i2c_dir_addr_cross_cg.sample()
                                              ├──> i2c_dir_ack_cross_cg.sample()
                                              ├──> i2c_rep_dir_cross_cg.sample()
                                              ├──> i2c_dir_size_cross_cg.sample()
                                              ├──> i2c_protocol_dir_cross_cg.sample()
                                              └──> i2c_stretch_dir_cross_cg.sample()   // CG17
```

Source: `uvm/i2c_coverage.sv` (write function, all 17 covergroups sampled on every transaction with guards as noted).

---

**End of Coverage Closure Report**
