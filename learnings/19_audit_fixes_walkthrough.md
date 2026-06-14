# Lesson 19 — The 2026-06-10 Audit: How a "Finished" Bench Was Hiding Dead Checkers

**Files under study:** the whole repository — this lesson is about *verifying the verification*.
**Concepts covered:** silent-pass bugs, vacuous assertions, `$error` vs `uvm_report_error`, intent-vs-wire checking, BFM timing vs assertion windows, CDC synchronizers and their side effects, NBA scheduling in debug, building independent evidence (smoke test), and how to audit your own testbench.
**Date:** 2026-06-10
**Companion document:** `docs/AUDIT_FIX_REPORT.md` (the full findings → fixes log). This lesson teaches the *thinking*; that document records the *changes*.

---

## 1. The Most Important Idea in This Lesson

> **A testbench is guilty until proven innocent. "All tests pass" is not evidence — it is a claim that needs its own verification.**

This project had 19 passing-looking tests, 17 covergroups, 9 assertions, and a
self-checking scoreboard. It *also* had:

- a scoreboard that **never compared a single write data byte**,
- assertions whose failures **could not fail a test** (`$error` is invisible to UVM),
- assertion timing windows that were **mathematically impossible** for the BFM
  (so they were guaranteed to be firing — into a log nobody graded),
- a clock-stretch feature that had **never once triggered** in any UVM run,
- a "repeated START" in the master RTL that **never appeared on the wire**,
- a coverage-merge flow that **could not have ever produced a report**.

Every one of these co-existed with green-looking runs. That is the lesson:
each checking layer can be individually dead while the suite "passes".

### The kill-chain question

For any testbench, ask: *if the DUT corrupted one data byte, what is the exact
chain of events that turns that into a red FAIL?* Walk it link by link:

```
corruption → seen by monitor? → compared by scoreboard? → produces uvm_error?
→ counted by report server? → checked by regression script? → exit code != 0?
```

Before the audit, this chain was broken in TWO places for writes (no compare;
script greps only "SCOREBOARD PASSED") and THREE places for protocol
violations (BFM timing made SVAs fire on legal traffic → people learn to
ignore them; `$error` not counted; script doesn't grep for it).

---

## 2. Finding Class A — Dead Checkers

### A1. The write-data compare that wasn't

Old scoreboard, `check_data_integrity`:

```systemverilog
if (item.dir == DIR_WRITE) begin
  match_count++;        // <-- that's it. That was the whole "check".
end
```

The monitor delivered the real bytes seen on SDA. The driver delivered the
intended bytes. They were never put side by side. **Mutation test thought
experiment:** flip one bit in the DUT's shift register — `basic_write_test`,
`burst_write_test`, `data_pattern_test` all still pass. Only a read-back test
catches it, indirectly, later, with a confusing READ-mismatch message.

**Fix shape (memorize the pattern):** two queues + match-when-both-present.

```systemverilog
function void write_expected(i2c_seq_item t); exp_q.push_back(t); try_match(); endfunction
function void write_actual  (i2c_seq_item t); act_q.push_back(t); try_match(); endfunction
function void try_match();
  while (exp_q.size() && act_q.size())
    compare_pair(exp_q.pop_front(), act_q.pop_front());
endfunction
```

This is arrival-order independent (analysis `write()` ordering between two
ports in the same timestep is not something to build correctness on), and
`check_phase` reports leftovers in either queue = lost/extra transactions.

Second principle in the fix: **the shadow model is built from the MONITOR
stream** (what physically happened), never from driver intent. Intent is the
*expectation*; the wire is the *fact*; the DUT's later behavior is judged
against facts.

### A2. Assertions that couldn't fail anything

`$error` prints. It does not increment UVM's error count. The pass criteria
were `grep "SCOREBOARD PASSED"`. Therefore: an assertion could fire 10,000
times and the run still "passed".

Fix: `uvm_pkg::uvm_report_error(id, msg)` in every `else` clause **and** the
regression now fails any log containing a real `UVM_ERROR` line. Belt and
suspenders — the report server counts it, and the script checks it.

### A3. Assertion windows nobody could meet

`T_BUF = 20` cycles of bus-free time after STOP — old BFM idled 4–6 cycles.
`T_HD_DAT = 5` cycles of SDA hold after SCL falls — old BFM moved SDA on the
*same edge* as SCL. A7/A8/A9 were firing on **every legal transaction**. When
an assertion always fires, humans stop reading it — which is *worse* than not
having it.

Fix: the BFM was re-timed to honor the spec constants (with margin for the
SVA's 2-stage sampling pipeline). Now the assertions encode real requirements
that real traffic satisfies — so when one fires, it means something.

One subtlety worth quoting in interviews: A8's hold check was relaxed to a
**structural 2-cycle minimum** rather than `T_HD_DAT`, because UM10204's
t_HD;DAT minimum is **0**, and our slave legitimately changes SDA ~3 cycles
after SCL falls (2-flop synchronizer + gated update). An assertion must encode
the SPEC's requirement, not your wish — otherwise it punishes legal designs.

---

## 3. Finding Class B — Features That Never Ran

### B1. Clock stretching had never happened

Slave RTL trigger: `stretch_en_rise && active_int`. Testbenches arm
`stretch_en` *before* the transaction (when `active_int==0`). Edge swallowed;
level never re-checked (that was the deliberate anti-retrigger fix from Bug
#1); **the DUT never stretched in any UVM simulation, ever**. And the old BFM
never read SCL back anyway, so even if it had stretched, nothing would have
waited.

Fix on both sides:
- RTL: `stretch_pending` latch — arm on edge, fire when a transaction becomes
  active, clear after firing. Edge-armed (no retrigger), level-delivered.
- BFM: `scl_release_wait()` — release SCL, then wait for the *wire* to go
  high, bounded by `MAX_CLK_STRETCH` with a `uvm_error` on timeout.

### B2. The virtual sequence that would deadlock

`i2c_stretch_vseq` did `finish_item(slave_ctrl)` inline. But the slave driver
only calls `item_done()` **after** the bus transaction completes
(`wait active 1→0`) — and the master traffic that would create that
transaction was started *after* `finish_item`. A→waits-for→B→waits-for→A.
It "worked" because **no test ever ran it**. Dead code can't deadlock.

Fix: fork the ctrl leg, start master traffic in the foreground, `wait fork`,
null-guard `p_sequencer.slave_seqr`. And give it a consumer:
`stretch_read_test`, which also closes the stretch×READ coverage cross that
was structurally unhittable before.

### B3. Constrained-random that wasn't random where it mattered

`default_trans_c { start_cond==1; stop_cond==1; rep_start==0; }` — so 1000
"random" stress transactions contained **zero** repeated STARTs. The
constraint that made simple sequences convenient silently fenced the
interesting protocol framing out of the random space. Fix: the random/stress
sequences explicitly run 2-segment Sr chains for ~25% of iterations with
`default_trans_c.constraint_mode(0)`.

**Interview line:** "default constraints are a stimulus *policy*; every policy
must be audited against the coverage model, or your coverage holes become
permanent."

---

## 4. Finding Class C — RTL Bugs Proven by a New, Independent Test

The UVM bench deliberately excludes the RTL master (block-level methodology).
Consequence: the master RTL was **never simulated against the slave at all**.
So the audit built `tb/tb_rtl_smoke.sv` (`make smoke`): pure SV, Icarus
Verilog (free, runs on a laptop), RTL master ↔ RTL slave over real wires with
`pullup`s. It immediately earned its keep:

1. **Implicit STOP between bytes.** After every ACKed byte, the master FSM
   went `ACK_WAIT → IDLE`, releasing SCL and SDA. SDA rising while SCL is high
   IS a STOP — every multi-byte write deselected the slave after byte 0.
   Fix: `STATE_BYTE_HOLD` — SCL held low between bytes, CPU chains
   WRITE/READ/Sr/STOP from there; from IDLE only `CMD_START` is legal.
2. **Repeated START never on the wire.** `REP_START_2` dropped SDA and SCL on
   the *same edge*. By the time the slave's (synchronized, equally-delayed)
   view updates, SCL is already low → no Sr event exists. The smoke test's T5
   hung: the slave kept shifting the "address" byte as if it were data.
   Fix: SDA falls while SCL is still high, *then* SCL drops. STOP had the
   mirror-image bug (both lines rising together) → 3-phase STOP.
3. **A bug the fix itself introduced — caught the same hour.** Adding 2-flop
   synchronizers made `sda_i` lag the wire by 2 cycles, but the arbitration
   check compared the *current* `sda_o` against the *delayed* `sda_i`:
   on every 0→1 data-bit transition the master saw "I drive 1, bus says 0,
   SCL (stale) says high" → false arbitration loss → transaction abandoned.
   Fix: compare a 2-cycle-delayed copy (`sda_o_d2`) so both sides of the
   wired-AND comparison live in the same time frame.
   **Rule: when you delay your inputs, delay your self-view too.**

Also a debugging gem from the same session: the smoke TB's own first version
had a polling race (read STATUS before the FSM had left BYTE_HOLD → saw the
*stale* ACK of the previous byte → returned instantly → clobbered `REG_DATA`
mid-byte). The corrupted data pattern (every other byte stored; a read
returning `0xA1` — exactly the address byte still sitting in `reg_data_buf`)
was fully explained by that one root cause. **When corrupted data has a
pattern, the pattern is the fingerprint of the mechanism.**

---

## 5. Finding Class D — Broken Infrastructure

- `make sim` saved UCDBs in `sim/`; `make cov` merged `logs/*.ucdb`;
  `make regress` saved none. The coverage merge had **never** worked. Fix:
  every run saves into `coverage/`, `make cov` merges from there.
- `run_all_tests.sh` was frozen at 15 tests while the Makefile had 18 —
  two regression entry points silently disagreeing. Fix: synced (19 now) with
  a comment pinning them together.
- The whole RAL bench (cpu agent, adapter, reg model, separate top) was
  compiled by **nothing** — shipped dead code, with a `virtual
  i2c_reg_if.drv_mp` vs `virtual i2c_reg_if` config_db type mismatch that
  would have been fatal on first real compile. Fix: build targets
  (`compile_ral/sim_ral/regress_ral`) + type fix + `bus2reg` now sets
  `rw.addr` + the WO CMD register finally gets its read-as-zero check.
- `eda_playground/` was hand-maintained and had drifted from the tree. Fix:
  it is now *generated* (`scripts/build_eda_playground.sh`).

---

## 6. Findings That Were REJECTED (equally important!)

The audit used multiple independent reviewers, and several confident-sounding
findings were **false positives**, disproven by tracing the actual semantics:

1. **"Address latch drops the MSB."** Claim: `rx_addr <= shift_reg[6:0]` at
   `bit_cnt==7 && scl_rise` captures stale data. Truth: with NBA semantics the
   latch reads the OLD `shift_reg`, which after 7 prior rises holds exactly
   a6..a0 in [6:0], while SDA currently carries R/W. Correct by construction.
2. **"Master stretch counter false-timeouts within 5 bits."** Claim assumed
   the counter accumulated across bits; it resets every SCL-high phase, so it
   peaked at 250 ≪ 1000. (The *real* defect was that it counted the master's
   own low phases — wrong signal, but not the claimed failure.)
3. **"Monitor/driver have a nondeterministic race."** Reads in the Active
   region vs NBA updates are *deterministic*: the reader always sees
   previous-cycle values. One-cycle-late ≠ race.

**Interview line:** "I treat review findings — human or tool — as hypotheses.
Each one gets re-verified against scheduling semantics and the actual code
before I change anything. Two of my audit's scariest-sounding findings were
wrong, and the proof of *why* they were wrong taught me more than the real
bugs did."

---

## 7. Quiz — 14 Questions

Answer out loud, then check section 8.

1. Why does `$error` inside an SVA fail block not fail a UVM test? What are the TWO independent fixes applied here?
2. Your scoreboard receives expected items from the driver and actual items from the monitor. Why is "compare immediately in `write_actual()` against the last expected item" fragile, and what is the robust pattern?
3. Why should the shadow/reference model be updated from the monitor stream rather than the driver's sequence item?
4. The old BFM drove ~5 clocks per bit. The assertions demanded `T_BUF=20` and `T_HD_DAT=5`. What is the *organizational* (not technical) damage caused by assertions that always fire?
5. UM10204 says t_HD;DAT minimum is 0. Our A8 still enforces a 2-cycle hold. Justify both halves of that sentence.
6. Explain precisely why the slave never stretched in any UVM run before the fix, even though `clock_stretch_test` "passed".
7. What is the deadlock in the old `i2c_stretch_vseq`, and why did nobody notice?
8. After adding 2-flop synchronizers to the master, the smoke test failed with phantom arbitration losses. Walk through the exact cycle-by-cycle mechanism.
9. Why did `ACK_WAIT → IDLE` between write bytes destroy multi-byte writes? What does the bus physically show?
10. The old `REP_START_2` set `scl_o<=0` and `sda_o<=0` on the same clock edge. Why does no Sr event appear at the slave, even though "SDA fell"?
11. Your stress sequence runs 1000 fully-randomized items. Coverage shows 0 hits on the rep_start bins. The constraint solver reports no failures. Where do you look first?
12. `make regress` ran 48 sims and `make cov` produced an empty report for months. Nobody noticed. What process change (not code change) prevents this class of failure?
13. In the smoke-test debug, written data landed as [pat1, pat3, 0, 0] instead of [pat0..pat3], and a read returned 0xA1. Reconstruct the root cause from those two symptoms.
14. Give the one-sentence "kill-chain" audit question you should ask of any testbench, and list the links for a data-corruption bug in THIS bench after the fixes.

---

## 8. Quiz — Senior-Grade Answers

**1.** UVM's pass/fail verdict is the report server's severity counters;
`$error` is a SystemVerilog system task that bypasses the report server
entirely, so the count stays 0. Fixes: (a) route failures through
`uvm_pkg::uvm_report_error` so they increment `UVM_ERROR`; (b) make the
regression script independently fail on any real `UVM_ERROR` log line —
defense in depth, because someone will eventually add another `$error`.

**2.** Two analysis `write()` calls for the same transaction can arrive in
either order (driver writes after its last wait; monitor writes when it sees
STOP — same timestep, ordering simulator-dependent), and under NACK/abort
flows one side may legitimately lag. Robust pattern: push both streams into
queues; a zero-argument `try_match()` pops and compares only while BOTH are
non-empty. Then end-of-test leftovers in either queue are themselves a
checkable error (`check_phase`).

**3.** The driver item is *intent*; the wire is *fact*. If the BFM has a bug
(drives the wrong bit), an intent-built shadow makes the read-back check
*confirm the corruption* instead of catching it. Building the model from the
monitor means every check is anchored to what physically happened, and the
separate intent-vs-wire compare catches BFM/DUT disagreement explicitly.

**4.** Alarm fatigue: when a checker fires on every legal run, engineers
mentally (or via scripts) filter it out, and from that day the checker
protects nothing — while management believes the bench "has assertions". A
permanently-failing check is strictly worse than no check, because it also
trains people to ignore the channel that real failures would arrive on.

**5.** *Why not enforce T_HD_DAT=5:* the spec's minimum is 0, and our slave
(2-flop sync + SCL-low-gated update) legally moves SDA ~3 cycles after the
fall; flagging it would punish a compliant design — assertions must encode
the spec, not the BFM's personal margins. *Why still 2 cycles:* a change in
the same/next cycle as the SCL edge is the dangerous structural case (it's
indistinguishable from data instability at the sampling boundary and can
forge START/STOP at receivers with different skews), and nothing legal in
this system can do it given the synchronizer latency — so it's a pure-signal,
zero-false-alarm tripwire.

**6.** The RTL armed stretch only when `stretch_en_rise && active_int` in the
SAME cycle. The slave agent raises `stretch_en` when the ctrl item arrives —
*before* the master starts the transaction, so `active_int==0` and the edge
is discarded; the signal then sits high producing no further edges. The test
still "passed" because the old BFM never read back SCL and the old scoreboard
checked almost nothing — the test verified that nothing crashed, not that
stretching occurred. Fix: edge sets `stretch_pending`; pending+active fires
the stretch and clears pending (re-trigger still impossible).

**7.** `finish_item(slave_ctrl)` blocks until the slave driver calls
`item_done()`; that driver intentionally holds the item until the bus
transaction *completes* (`wait active 1→0`); the master traffic that would
start that transaction is launched only after `finish_item` returns. Circular
wait. Nobody noticed because no test instantiated the vseq — it was
demo-ware. Lesson: every component in the repo needs at least one consumer in
the regression, or it is untested by definition.

**8.** Cycle 0: master, driving bit value 0, loads the next bit (1) →
`sda_o=1`, releasing the wire; SDA rises at cycle 0; SCL fell at cycle 0 too
(new bit period). The synchronized views lag two cycles: at cycles 1–2,
`sda_i` still reads the OLD low value and `scl_i` still reads the OLD high
value, while `sda_o` already reads 1. The check
`sda_o==1 && sda_i==0 && scl_i==1` is therefore true for ~2 cycles on every
0→1 bit transition → latched arb_lost → FSM abandons to IDLE. Fix: compare
`sda_o_d2` (the drive value as the bus *saw it* two cycles ago) so both
operands are time-aligned. General CDC rule: any compare across a
synchronizer boundary needs matched delays on both operands.

**9.** IDLE sets `scl_o<=1` and `sda_o<=1`. The slave is still holding ACK or
the bus releases from a data bit: as soon as SDA goes 0→1 while SCL is high,
every I2C device on the bus decodes STOP and deselects. The next `CMD_WRITE`
then clocked bits at a slave that was back in SLV_IDLE. The fix state
BYTE_HOLD keeps SCL LOW (slaves are frozen mid-bit and cannot misinterpret
anything) and releases SDA safely under low SCL.

**10.** An Sr is an *event*: SDA falling **while SCL is observed high**. Both
outputs changed in the same NBA window, so on the wire (and in the slave's
equally-delayed synchronized view) the cycle where `sda_d=1, sda_i=0` is the
same cycle where `scl_i` has already become 0 → the qualifier fails, no event.
"SDA fell" is not Sr; "SDA fell while SCL high" is. Sequencing fix: SDA falls
one full timer period before SCL drops.

**11.** The item class's *default constraints*. `randomize()` honors every
enabled constraint; `default_trans_c` pinned `rep_start==0`, so the solver was
doing exactly what it was told, silently. First grep in any "coverage never
hits X" triage: which constraints reference the field, and which sequences
disable them. Then check the sampling path. Solver failures are loud;
over-constraint is silent.

**12.** Make the *flow product* a checked deliverable: regression must end by
asserting the coverage report exists and is non-empty (fail otherwise), and a
periodic "audit the audit" pass must run the whole flow from `git clean`.
Generated-artifact paths should be defined once (one variable used by both
producer and consumer) — the bug existed because `sim` and `cov` each had
their own idea of where UCDBs live.

**13.** One root cause: the TB polled STATUS immediately after writing CMD,
saw the *stale* STS_ACK from the previous byte (the FSM needs ~2 cycles to
leave BYTE_HOLD and update STATUS), declared the byte done, and wrote the next
byte into REG_DATA — which (pre-guard) also loaded the live shift register
mid-transmission. So odd bytes overwrote even bytes in flight (every-other
storage), and the "read data" 0xA1 was just `reg_data_buf` still holding the
last thing the CPU wrote — the read-address byte {0x50,R}=0xA1 — because the
real read hadn't finished. Both fixes: settle-then-poll in the TB, and an RTL
guard so REG_DATA loads the shifter only in IDLE/BYTE_HOLD.

**14.** "Show me the unbroken chain from physical corruption to non-zero exit
code." Here: DUT flips a byte → monitor reconstructs it from SDA (passive,
independent) → scoreboard pops both queues and byte-compares
(`compare_pair`) → `uvm_error` → report server count > 0 → base test
report_phase flags TEST FAILED **and** regression grep sees a real UVM_ERROR
line → script exits 1. Every link now exists and each was individually broken
before the audit.

---

## 9. Key Takeaways

1. **Audit the verdict path, not just the design.** Every checker needs a
   demonstrated path to a red FAIL.
2. **Negative testing of the bench itself**: mentally (or actually) inject a
   bug and confirm the suite goes red. If you can't name the test that
   catches it, it isn't covered.
3. **Facts beat intent**: monitors and wire-derived models are the anchor of
   truth; driver data is just expectation.
4. **An always-firing or never-firing assertion is a liability.** Tune
   windows to the spec and the stimulus you actually generate.
5. **Independent evidence is cheap**: a 300-line free-simulator smoke test
   found three RTL bugs a 3000-line UVM bench missed *by design* (it excluded
   the master).
6. **Verify the review too**: a third of the audit's "critical" findings were
   false positives until traced against LRM scheduling semantics.

---

## 10. The Shakedown — first run on a real simulator (2026-06-12)

The action item below ("run the suite on a licensed tool") got done on EDA
Playground (Riviera-PRO 2025.04, UVM 1.2) — and it is now the best lesson in
this whole file. First run: **4/8 tests passed.** The 4 failures were 5
distinct findings, every one invisible to review + Icarus:

1. **Reserved keywords as bin names.** CG15 used `small`/`medium`/`large` —
   those are Verilog *trireg charge strength* keywords. One simulator's parser
   shrugs, another's rejects. Lesson: portability bugs exist that only a
   second toolchain finds. (Renamed `sz_*`.)
2. **Three constraint conflicts in sequences that had NEVER run.**
   `rep_start_seq` inlined `stop_cond==0` against `default_trans_c`'s
   `stop_cond==1` (unsatisfiable); `force_nack_seq` demanded
   `stretch_cycles==0` against `inside {[1:500]}`; and the subtlest:
   `single_write/read_seq` declared `rand addr` + constraint, but the vseq
   starts them **without randomizing** — a constraint only applies when its
   object is randomized, so `addr` silently stayed 0 until the *item's*
   `valid_addr_c` blew up downstream. Lesson: a constraint you never solve is
   a constraint you never tested. Fixes: `constraint_mode(0)` for the first
   two; non-rand fields with defaults for the third.
3. **The real RTL bug: `SLV_STRETCH` released the ACK.** No arm in the SDA
   output `always_ff`, so stretch fell into `default: sda_o <= 1'b1` —
   mid-stretch, the ACK lifted off the wire. The passive monitor (samples AT
   the SCL rising edge) read NACK; the driver (samples mid-high, after the
   FSM re-grabbed SDA) read ACK; the disagreement cascaded into a phantom
   repeated-START. Why nothing caught it earlier: stretch had never actually
   fired in any old UVM run (§ "the stretch that never happened"), and the
   smoke test's only observer is the RTL master — which also samples
   mid-high. **Two observers, same wire, different sample instants — the
   stricter one found the bug.** Fix: `SLV_STRETCH: ;` (hold). Proven by new
   smoke check T6 (stretch armed pre-START → fires at address ACK, 33/33
   pass) and the green Riviera re-run.

Re-run after fixes: **8/8 green, UVM_ERROR=0 everywhere, SCOREBOARD PASSED
on every test.** Per-test coverage of 40–65% is *expected* — directed tests
each hit their own bins; closure is a merged-regression property, not a
single-run property.

Meta-lesson to retell: review + free-simulator smoke ≈ 90%. The first hour on
a real constrained-random solver still found 5 issues, one of them a genuine
protocol bug. "Compiles and the happy path passes" is not sign-off.

---

## 11. Action Items

- [x] ~~Run the suite on a licensed tool~~ — DONE 2026-06-12 on EDA
      Playground (Riviera-PRO 2025.04): 8/8 green after the §10 fixes.
- [ ] Save the EDA Playground with a title and grab the shareable URL for the
      resume.
- [ ] Eventually: full `make regress` (19×3) + `make cov` merged coverage on
      a Questa machine — EP runs are isolated, so merged coverage closure is
      still unproven.
- [ ] Re-read `docs/AUDIT_FIX_REPORT.md` (now including §8, the shakedown)
      until you can retell every entry WITHOUT the document.
- [ ] Practice the rejected-findings stories (section 6) — they demonstrate
      judgment, which interviews value above bug counts.
- [ ] Then work through `interview/` (question bank + war stories — story 7
      is the shakedown).
