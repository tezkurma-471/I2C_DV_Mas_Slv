# Audit & Fix Report — 2026-06-10 (updated 2026-06-12: EDA Playground shakedown, 8/8 GREEN)

A full senior-DV-style audit of this repository was performed (4 parallel review
passes over RTL, UVM stimulus/check path, UVM infrastructure/coverage, and
SVA/RAL/interfaces), every critical finding was re-verified against source
before being accepted, and **all confirmed findings were fixed**. RTL fixes are
proven by a new pure-SV integration smoke test (`make smoke`, Icarus Verilog,
no license needed) that runs the RTL master against the RTL slave over real
open-drain wires: burst write with bus held between bytes, burst read-back,
address NACK abort, clock stretching, and repeated START — **all passing**.

**2026-06-12 update:** the full UVM layer was then run on a commercial
simulator (EDA Playground, Riviera-PRO 2025.04, UVM 1.2). The first shakedown
run shook out **5 more findings** — including one genuine RTL bug the smoke
test could not see — all fixed and re-proven. Final state: **8/8 tests green,
UVM_ERROR=0, SCOREBOARD PASSED on every run.** See §8.

This document is the change log and the interview-defense guide: every entry
says what was broken, why it mattered, and what the fix was.

---

## 1. Verification-integrity fixes (the ones that matter most)

### 1.1 SVA failures were invisible to pass/fail
**Was:** assertions used `$error`, which the UVM report server does not count;
the regression pass criterion was literally `grep "SCOREBOARD PASSED"`. A log
could be full of protocol violations while the run counted as PASS.
**Worse:** the assertion windows (`T_BUF=20`, `T_HD_DAT=5`, `T_SU_DAT=5`)
were mathematically impossible for the old BFM (~5 clk/bit, 4–6 idle cycles
between transactions), so A7/A8/A9 were guaranteed to fire on legal traffic.
**Fix:**
- All assertion failures route through `uvm_pkg::uvm_report_error` → they now
  increment `UVM_ERROR` and fail the test (`sva/i2c_protocol_assertions.sv`).
- The BFM was re-timed to honor the spec constants (see 1.4), so the windows
  are now meaningful.
- The Makefile/regress pass criteria additionally fail any run whose log
  contains a real `UVM_ERROR` line.
- A2 was removed: its `##[1:T_BUF]` existential delay made it near-vacuous and
  fully subsumed by A7. A8 got the missing `##1` (off-by-one) and now enforces
  a structural 2-cycle hold (UM10204 t_HD;DAT min is 0; the slave legitimately
  responds ~3 cycles after SCL falls through its synchronizers).
- Phase tracking (`in_data_phase`/`in_ack_phase`) is now cleared at STOP.

### 1.2 Write-data checking was dead in the scoreboard
**Was:** for WRITE transactions `write_actual` executed `match_count++` and
compared nothing. A DUT that corrupted every write byte passed every
write-only test. The shadow bank was built from driver *intent*, not from the
wire.
**Fix:** full scoreboard rewrite (`uvm/i2c_scoreboard.sv`):
- Expected (driver) and actual (monitor) items go into in-order queues and are
  matched pairwise when both sides are present — arrival order no longer
  matters.
- Byte-for-byte data comparison for BOTH directions, plus addr/dir/ACK
  consistency checks.
- Shadow register bank is built from the MONITOR stream (what was really on
  the wire); reads are checked against it.
- `check_phase` flags unconsumed leftovers in either queue (lost/extra
  transactions).
- `allow_bus_corruption` config knob for the one test that corrupts the bus on
  purpose (arbitration_lost_test).

### 1.3 The README described clock-stretch handling that did not exist
**Was:** README §6.2 quoted a "wait for SCL to actually go high" loop; no such
code existed anywhere. The driver open-loop toggled `scl_drv` on fixed counts
and never read `vif.scl` back — a stretching slave was simply ignored.
**Additionally:** the slave RTL armed stretch only on `stretch_en_rise` while
`active_int` was already high; testbenches raise `stretch_en` *before* the
transaction, so the edge was swallowed and **the DUT never actually stretched
in any UVM run**. The clock_stretch_test was verifying nothing.
**Fix:**
- Driver: `scl_release_wait()` releases SCL and waits for the wire to go high,
  bounded by `MAX_CLK_STRETCH` with a `uvm_error` on timeout
  (`uvm/i2c_master_driver.sv`). The README's claim is now true.
- Slave RTL: a `stretch_pending` latch holds the armed request until a
  transaction is active (`rtl/i2c_slave_controller.sv`) — still edge-armed, so
  the original "infinite re-trigger" bug cannot return.
- Monitor stretch detection threshold rescaled to the new BFM timing (>64
  consecutive SCL-low cycles).
- Verified in the smoke test: a stretch pulse mid-byte freezes the master and
  the byte still lands correctly.

### 1.4 BFM re-timed to the spec constants; ACK results recorded; NACK aborts
**Was:** ~5 clk/bit with SDA changing on the same edge SCL fell; ACK sampled
into a local variable and discarded (`req_item.addr_ack` never set); after a
NACK the driver kept driving the remaining bytes onto an un-owned bus.
**Fix:** (`uvm/i2c_master_driver.sv`)
- Per-bit timing: `T_HD_DAT`/`T_SU_DAT` + SVA-pipeline margin; START/Sr/STOP
  honor `T_SU_STA`/`T_HD_STA`/`T_SU_STO`; STOP is followed by a `T_BUF`
  bus-free wait.
- `addr_ack`/`byte_ack[]`/`ack_received` are written back into the item.
- Address NACK → abort with STOP, no data driven, item payload cleared.
- Data NACK → transfer ends at the NACK'd byte; item trimmed to what was
  actually driven so the expected stream matches the wire.

---

## 2. RTL fixes

### 2.1 Slave (`rtl/i2c_slave_controller.sv`)
| Fix | Detail |
|---|---|
| CDC synchronizers | SCL/SDA double-flopped before all edge detection/FSM use (were raw pad passthroughs). |
| SDA gating | `sda_o` updates in driving states (ACK/RX_ACK/TX) now gated on SCL low and HELD through SCL high — UM10204 data-validity rule. |
| Stretch resume | `saved_state` captured exactly on the transition INTO `SLV_STRETCH` (was a cycle-late capture that could resume into the wrong state). |
| Stretch arming | `stretch_pending` latch (see 1.3). |
| `reg_ptr` reset | On ENTRY to `SLV_ACK` only, not every cycle in the state. |
| Dead code | Unreachable `SLV_STOP` state and shadowed inner START/STOP branches removed. |
| `rx_data_valid` | Now a one-cycle strobe (pulse on register-bank commit), was a multi-hundred-cycle level. |

### 2.2 Master (`rtl/i2c_master_controller.sv`) — found by the new smoke test
| Fix | Detail |
|---|---|
| **Bus released between bytes** | `ACK_WAIT --ack--> IDLE` released SCL+SDA mid-transaction → implicit STOP → multi-byte writes impossible. New `STATE_BYTE_HOLD` holds SCL low between bytes; CPU chains WRITE/READ/Sr/STOP from there. |
| **Repeated START never on the wire** | `REP_START_2` dropped SDA and SCL on the same edge — no Sr condition ever appeared. Now: SDA falls while SCL is high, then SCL drops (via `START_2`). |
| **STOP same-edge race** | `STOP_2` raised SCL and SDA together. Now 3-phase: SCL rises, then SDA rises while SCL high (`STATE_STOP_3`). |
| Stretch-aware timing | Bit timer freezes whenever `scl_o==1 && scl_i==0` (slave stretching) — previously the FSM paced itself on the timer alone and read a never-sampled `ack_received=0` as NACK under stretch. |
| `stretch_cnt` | Counts only slave-held-low cycles (was counting the master's own SCL-low half-periods). |
| Arb-loss vs synchronizers | The wired-AND check now compares a 2-cycle-delayed copy of `sda_o` against the synchronized `sda_i` (raw comparison false-fired on every 0→1 data transition once synchronizers existed). |
| IDLE command gating | Only `CMD_START` accepted from IDLE (was happy to clock data bits with no START). |
| `shift_reg` clobber guard | `REG_DATA` writes load the shifter only in IDLE/BYTE_HOLD, never mid-byte. |
| IRQ logic | Bit positions now match a corrected `i2c_irq_e` (the old enum listed sources that didn't exist); `arb_lost` added to the IRQ term. |
| `REG_IRQ_ST` comment | "read to clear" comment fixed — the interface has no read strobe, the register mirrors STATUS (RAL models it as RO, which was already correct). |
| Lint | Width-clean timer comparisons (sized localparams), unused signals removed. |

**Note on the old `timer_clr` finding:** the combinational `state != next_state`
form was reviewed and deliberately kept — it is consumed synchronously and all
FSM inputs are registered after the synchronizer fix, so no glitch can be
latched. Documented in the source.

### 2.3 Proof
`make smoke` (Icarus Verilog, pure SV, no UVM): RTL master ↔ RTL slave on real
open-drain wires with pullups —
T1 4-byte burst write (checks SCL held low between bytes + slave register
contents), T2 4-byte read-back, T3 address-NACK auto-STOP, T4 clock stretch
mid-byte (no timeout, data intact), T5 write-write-Sr-read-read.
**Result: ALL TESTS PASSED.** Verilator lint: clean.

---

## 3. Coverage & sequences

| Fix | Detail |
|---|---|
| Honest counts | 17 covergroups (header said 8), 19 bus-level tests + 3 RAL tests (README said 16). |
| Threshold | `report_phase` now averages ALL 17 covergroups for the 90% warning (was 4 of 17). |
| rep-start in random | `default_trans_c` pinned start=1/stop=1/rep=0, so `i2c_random_seq`/`i2c_stress_seq` could never produce a repeated START. Both now drive 2-segment Sr chains in ~25% of iterations (`do_rep_chain` in `i2c_base_seq`). |
| stretch × read cross | Was structurally unhittable. New `stretch_read_test` (T15) runs the fixed `i2c_stretch_vseq`: stretch during a write AND during a read. |
| `i2c_stretch_vseq` deadlock | The old vseq called `finish_item(slave_ctrl)` inline; the slave driver only item_done()s after the transaction the vseq hadn't started yet. Ctrl legs now fork; `slave_seqr` null-guarded. |
| Dead knob removed | `i2c_clock_stretch_seq.stretch_cycles` was randomized and ignored — removed (the slave ctrl sequence owns the duration). |
| Stretch ranges | Slave ctrl stretch range 200–400 cycles: above the monitor's 64-cycle detection threshold, below `MAX_CLK_STRETCH=1000`. |

---

## 4. RAL flow — from dead code to buildable

| Fix | Detail |
|---|---|
| Build integration | The RAL bench was compiled by NOTHING (not Makefile, not any script). New targets: `make compile_ral`, `make sim_ral RAL_TEST=...`, `make regress_ral`. |
| Fatal type mismatch | `i2c_cpu_driver` declared `virtual i2c_reg_if.drv_mp` but config_db stores `virtual i2c_reg_if` — fixed (clocking-block discipline kept via `vif.driver_cb`). |
| `bus2reg` contract | `rw.addr` now populated (explicit predictors read it). |
| CMD register | The reset-check sequence now verifies the only WO register reads back 0x00 — it was the one register never checked. |

---

## 5. Build & flow infrastructure

| Fix | Detail |
|---|---|
| Coverage flow | `make sim` saved UCDBs into `sim/` while `make cov` merged `logs/*.ucdb`, and `make regress` saved none — the merge could NEVER have worked. All runs now save into `coverage/` and `make cov` merges from there. |
| Pass criteria | All regression loops fail a run on any real `UVM_ERROR` log line (SVA failures included) before looking for "SCOREBOARD PASSED". |
| Script sync | `run_all_tests.sh` was frozen at 15 tests; now mirrors the Makefile's 19 and uses the same pass criteria. |
| `make smoke` | Local, license-free RTL evidence (Icarus). |
| Playground bundle | `scripts/build_eda_playground.sh` regenerates `eda_playground/` from the canonical sources — the bundle can no longer silently diverge (it had). |

---

## 6. Findings audited and REJECTED (no change made — know these for interviews)

1. **"Address latch drops the MSB"** — false. At the 8th `scl_rise`
   (`bit_cnt==7`) the non-blocking read of the OLD `shift_reg[6:0]` holds
   exactly the 7 address bits while SDA carries R/W. The code was correct.
2. **"Master stretch counter false-timeouts within 5 bits"** — false. The
   counter reset every SCL-high phase, peaking at 250 ≪ 1000. (The real issue
   was that it counted the master's own low phases — fixed, see 2.2.)
3. **"Monitor/driver sampling race is non-deterministic"** — overstated. The
   monitor reads in the active region and the driver updates in NBA, so the
   monitor deterministically sees previous-cycle values. (Clocking blocks
   remain the cleaner style; not a correctness bug.)
4. **"Combinational `timer_clr` glitches the timer"** — not for synchronous
   consumption with registered inputs; kept with an explanatory comment.

---

## 7. Residual limitations (honest list)

- ~~UVM regressions require a commercial simulator; the UVM-layer changes are
  fixed-by-review, not simulation.~~ **RESOLVED 2026-06-12:** the UVM layer was
  run on EDA Playground (Riviera-PRO 2025.04) — 8/8 tests green after the
  shakedown fixes in §8. The remaining licensed-tool gap is the *full* 19×3
  regression + merged coverage (`make regress` + `make cov`), which needs
  Questa; EDA Playground runs tests in isolation and cannot merge UCDBs.
- The slave commits a force-NACK'd data byte to its register bank (NACK and
  storage are independent in this design). The scoreboard models that
  behavior; whether a NACKing receiver should discard is a spec-interpretation
  decision worth defending in review.
- `i2c_reg_if` is "APB-like" but has no PSEL/PENABLE/PREADY; it is a simple
  one-cycle strobe bus. Fine for this DUT, but do not connect a real APB
  master to it.

---

## 8. EDA Playground shakedown — 2026-06-12 (Riviera-PRO 2025.04, UVM 1.2)

First time the UVM layer ever ran on a commercial simulator. Setup: two-pane
bundle generated by `scripts/build_eda_playground.sh` (`ep_design.sv` =
pkg + RTL + interfaces + SVA → right pane; `ep_testbench.sv` = comment-stripped
tb pkg + top → left pane; each under EDA Playground's 100k-char limit).

First run: 4/8 passed (`basic_write`, `addr_nack`, `deep_rep_start`,
`random_directed`). The 4 failures decomposed into 5 findings:

| # | Finding | Class | Fix |
|---|---------|-------|-----|
| 8.1 | CG15 bin names `small`/`medium`/`large` are **reserved Verilog keywords** (trireg charge strengths). Questa-style tools tolerate them as bin names; Riviera's parser rejects them. | Portability | Renamed `sz_small/sz_medium/sz_large/sz_xlarge` in `i2c_coverage.sv`. |
| 8.2 | `rep_start_test` FATAL: `i2c_rep_start_seq` randomized with inline `stop_cond==0 / rep_start==1` while `default_trans_c` pins `stop_cond==1 / rep_start==0` — unsatisfiable. The sequence had never executed on a real solver. | Latent constraint conflict | `item.default_trans_c.constraint_mode(0)` before `randomize()`, same pattern `deep_rep_start` already used. |
| 8.3 | `data_nack_test` FATAL: `i2c_slave_force_nack_seq` demanded `stretch_cycles==0` against `stretch_cycles_c inside {[1:500]}`. | Latent constraint conflict | `ctrl.stretch_cycles_c.constraint_mode(0)` — the value is don't-care when stretching is disabled. |
| 8.4 | `stretch_read_test` FATAL: `i2c_single_write/read_seq` declared `rand addr` with a constraint, but the virtual sequence starts them **without calling `randomize()`** — so `addr` stayed 0 and the *item's* `valid_addr_c` rejected it. A constraint only exists when its object is randomized. | UVM/constraint semantics | `addr`/`data` made non-rand fields with defaults (`7'h50`, `8'hA5`); directed callers still assign them explicitly. |
| 8.5 | **`clock_stretch_test` SCOREBOARD FAIL — the real RTL bug.** `SLV_STRETCH` had no arm in the SDA-output `always_ff`, so it fell into `default: sda_o <= 1'b1`, **releasing the ACK mid-stretch**. The at-the-edge passive monitor read NACK while the mid-high-sampling driver read ACK; the mismatch derailed into a phantom repeated-START. Invisible before because stretch never actually fired in any prior UVM run (§1.3) and the Icarus smoke's "monitor" is the RTL master, which also samples mid-high. | RTL functional bug | `SLV_STRETCH: /* hold sda_o */ ;` — a stretching slave has only paused the clock; it must hold SDA. Proven by new smoke check T6 (stretch armed pre-START, fires at the address ACK — the exact failing scenario; 33/33 checks pass) **and** by the green Riviera re-run. |

Also: `$dumpvars` in `top_tb.sv` gated behind `+DUMP` — the EDU Riviera build
emits a wall of harmless `KERNEL_0085` PLI access warnings otherwise.

**Re-run results (2026-06-12), all with `UVM_ERROR: 0`, `UVM_FATAL: 0`,
`SCOREBOARD PASSED`:**

| Test | Evidence in log |
|------|-----------------|
| `rep_start_test` | Write → Sr ("Repeated START detected mid-transaction") → read-back 0xA5 → STOP; 2/2 matched. |
| `data_nack_test` | Data byte 0xDE `ack=0`, driver "Data byte 0 NACKed — ending transfer", clean STOP; 1/1 matched. |
| `clock_stretch_test` | 100-cycle stretch at address ACK (address phase 6430 ns vs ~4630 ns unstretched — the gap *is* the stretch); monitor `ack=1` ⇒ SDA held. 1/1 matched. |
| `stretch_read_test` | vseq: 300-cycle-stretch write then read (address phase ~10,000 ns); wrote 0xA5, read 0xA5; monitor flagged `stretch=1` on both transactions independently. 2/2 matched. |

Coverage note: per-test CG averages of 40–65% on these runs are **expected
and correct** — each directed test hits its own bins (e.g. all four send
1-byte payloads, so only `sz_small` hits). Coverage closes across the merged
regression (`make regress` + `make cov`), not in a single directed run.
EDA Playground cannot merge across its isolated runs.

**Takeaway worth saying in interviews:** review and a free-simulator smoke
test got the bench 90% of the way; the first hour on a real constrained-random
solver still found three never-executed constraint conflicts, one portability
landmine, and one genuine protocol bug at the corner where two observers
sample the same wire at different times. That is exactly why "it compiles and
the directed test passes" is not sign-off.
