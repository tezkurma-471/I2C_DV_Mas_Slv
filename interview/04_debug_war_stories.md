# 04 — Debug War Stories (STAR format, ≤3 minutes each)

"Tell me about a hard bug" is guaranteed. Each story below is structured
Situation → Task → Action → Result, ends with the lesson, and is 100% true to
this repo — you can open the files and show the fix live.

---

## Story 1 — The scoreboard that could not fail (my favorite opener)

**S:** The bench had 17 passing tests and a "self-checking scoreboard." I
audited it with one question: *if the DUT corrupts one write byte, which line
of code turns red?*
**T:** Trace the kill-chain: corruption → monitor → compare → uvm_error →
count → script → exit code.
**A:** Read `check_data_integrity` and found, for writes:
`if (dir==DIR_WRITE) match_count++;` — no comparison at all. The monitor's
real wire bytes were dropped on the floor; the shadow memory was built from
the *driver's intent*, so even read-backs compared the DUT against what we
*meant*, not what *happened*. I rewrote it: both streams queued, matched
pairwise when both present (arrival-order independent), byte-for-byte compare
in both directions, shadow built from the monitor, `check_phase` flagging
leftover queue entries.
**R:** Write-path corruption now produces a named `uvm_error` within one
transaction. The rewrite also forced clarity on NACK flows (the driver now
trims items to bytes actually driven, so expected matches the wire even on
aborts).
**Lesson:** *"All tests pass" is a claim, not evidence. I now mutation-think
every checker: name the test and the line that catches each failure class.*

## Story 2 — Assertions firing into the void

**S:** Nine protocol SVAs, README bragging about them — and pass criteria of
`grep "SCOREBOARD PASSED"`.
**T:** Verify assertion failures can actually fail a run.
**A:** Two independent breaks. (1) Failures used `$error`, which UVM's report
server doesn't count — `UVM_ERROR: 0` co-existing with a log full of
violations. (2) Worse: the BFM ran ~5 clk/bit with 4–6 idle cycles after
STOP, while the assertions demanded `T_BUF=20` bus-free and `T_HD_DAT=5`
hold — **mathematically guaranteed false failures on every legal
transaction**, which trains everyone to ignore the channel. Fixes: route
failures through `uvm_report_error`; make regression fail on any real
UVM_ERROR log line; re-time the BFM to the spec constants; delete the
vacuous A2 (`##[1:T_BUF]` is existential — true if the bus is high at ANY
one cycle); fix A8's off-by-one and re-derive its window from the spec
(t_HD;DAT min is 0 — a 5-cycle demand would flag *compliant* slaves).
**R:** Assertions are now live tripwires with zero false-alarm rate against
legal stimulus.
**Lesson:** An assertion that always fires (or can't be counted) is worse
than no assertion — it anesthetizes the team.

## Story 3 — The clock stretch that never happened

**S:** `clock_stretch_test` existed and "passed" for months.
**T:** Prove stretching actually occurred.
**A:** Read the RTL trigger: `stretch_en_rise && active_int` — same-cycle
requirement. The slave agent raises `stretch_en` when the ctrl item arrives,
*before* the transaction starts (`active_int==0`): edge swallowed, level
never re-examined (that level-check had been removed earlier to fix a real
infinite-retrigger bug — the fix overcorrected). Meanwhile the BFM never read
SCL back, so nothing would have waited anyway. Fixed both sides:
`stretch_pending` latch in RTL (edge-armed, fires when active, no
retrigger), and `scl_release_wait()` in the BFM (release, wait on the WIRE,
bounded by MAX_CLK_STRETCH with a loud error). Verified in the Icarus smoke
test by pulsing stretch mid-byte: master freezes, byte still lands.
**R:** First genuinely verified stretch in the project's history; plus a new
`stretch_read_test` closing the stretch×READ coverage cross.
**Lesson:** A test passing proves nothing about a feature firing. Coverage
must *sample the mechanism* (stretch_seen), not just run a test named after it.

## Story 4 — The repeated START that never existed (found by my own smoke test)

**S:** I built a free-simulator smoke test (Icarus, RTL master ↔ RTL slave on
real wires) because the UVM bench deliberately excludes the master RTL. Test
T5 (write-write-Sr-read) hung.
**T:** Find why the slave never re-addressed.
**A:** FSM trace showed the slave treating the second address byte as DATA.
Root cause in the master: `REP_START_2` set `scl_o<=0` **and** `sda_o<=0` on
the same edge. An Sr is "SDA falls while SCL is high" — by the time the
slave's (synchronized, equally delayed) view updates, SCL is already low: the
qualifier fails, **no event exists on the wire**. STOP had the mirror bug
(both lines rising together — a same-cycle race that happened to decode in
sim but is a real-silicon coin flip). Fix: proper phase sequencing — Sr: SDA
falls while SCL still high, then SCL drops; STOP: 3 phases, SCL rises first.
**R:** T5 green; and a master that had "passed review" twice was proven
protocol-broken at the wire level.
**Lesson:** Block-level exclusion is fine, but "deliberately not in THIS
bench" must never become "not tested anywhere." Cheap independent evidence
pays for itself immediately.

## Story 5 — The bug my own fix introduced (and caught within the hour)

**S:** I added 2-flop synchronizers to the master's SCL/SDA inputs (proper
CDC). The smoke test immediately failed: the master abandoned transactions
two bits in.
**T:** Explain a transaction dying with no slave misbehavior.
**A:** State trace showed TX_BIT → IDLE: arbitration loss. But there was no
second master. Cycle analysis: on every 0→1 data-bit transition, `sda_o` is
already 1 (new bit) while the *synchronized* `sda_i` still reads the old 0
for two cycles and `scl_i` still reads stale high — the arb check
`sda_o==1 && sda_i==0 && scl_i==1` is true for ~2 cycles. **I had delayed the
inputs without delaying the self-view.** Fix: compare a 2-cycle-delayed
`sda_o_d2` so both operands of the wired-AND comparison live in the same time
frame.
**R:** Phantom arb-losses gone; the real arb test still triggers correctly.
**Lesson:** Every fix is a change, and every change is a suspect. Also the
general CDC rule: any comparison across a synchronizer boundary needs
matched delays on both sides.

## Story 6 — Reading the fingerprint: every-other-byte corruption

**S:** Smoke test, first run: 4-byte write landed as `[pat1, pat3, 0, 0]`,
and a later read returned `0xA1` — a value never written anywhere.
**T:** One root cause had to explain BOTH symptoms.
**A:** `0xA1` is `{0x50,R}` — the read **address byte**, i.e., the last
thing the CPU wrote into `REG_DATA`. That meant my TB read `reg_data_buf`
*before the read transaction finished* — the status poll was returning
stale `STS_ACK` from the *previous* byte because the FSM needs ~2 cycles to
leave BYTE_HOLD and update STATUS. Same stale-poll explains the writes: the
TB declared byte N done instantly and loaded byte N+1 into `REG_DATA` —
which (pre-fix) also reloaded the live shift register mid-transmission, so
odd bytes overwrote even bytes in flight: every-other-byte storage, exactly
as observed. Two fixes: settle-then-poll in the TB helper, and an RTL
hardening guard — `REG_DATA` loads the shifter only in IDLE/BYTE_HOLD.
**R:** 29/29 smoke checks green; plus a permanent RTL guard against a whole
class of CPU misuse.
**Lesson:** Corruption with a *pattern* is a gift — the pattern is the
mechanism's fingerprint. And TB bugs deserve the same root-cause rigor as
RTL bugs; "fix the test until it passes" without explaining every symptom is
how real bugs survive.

---

## Story 7 — The stretch that dropped its ACK (found in the first hour on a real simulator)

**S:** First time the suite ever ran on a commercial simulator (EDA
Playground, Riviera-PRO). `clock_stretch_test` failed with a contradiction:
the driver logged "ACK received" while the monitor logged the same address
byte as `ack=0` — and then the monitor reported a repeated START that no one
ever drove.
**T:** Two trusted observers disagreed about the same physical wire. One of
them had to be sampling a wire that *changed between their sample points* —
which on an ACK bit should be impossible: the slave must hold SDA stable for
the whole SCL-high.
**A:** Lined up the sample instants. The monitor samples AT the SCL rising
edge; my driver samples mid-high. Between those two instants the only thing
happening was the slave's clock stretch ending. Went to the slave's SDA
output `always_ff`: `SLV_STRETCH` had no case arm, so it fell into
`default: sda_o <= 1'b1` — the slave **released the ACK during the stretch**
and only re-drove it after resuming. Monitor caught the released line (NACK);
driver sampled after the re-grab (ACK). The "phantom repeated START" was just
SDA falling under SCL-high when the slave re-grabbed. One missing case arm
explained all three symptoms. Fix: `SLV_STRETCH: ;` — hold the flop; a
stretching slave has only paused the clock, it must not let go of data. Then
I asked why two earlier nets missed it: stretch had never actually fired in
any old UVM run (the original audit's "stretch that never happened"), and my
Icarus smoke's only observer is the RTL master — which also samples mid-high.
So I added smoke check T6 (stretch armed before START so it fires exactly at
the address ACK) to pin the bug locally: red before the fix, 33/33 after.
**R:** Re-ran on Riviera — monitor and driver agree, scoreboard matched,
UVM_ERROR=0. The same first-shakedown session also flushed out three
constraint conflicts in sequences that had never executed and a
reserved-keyword portability bug (`small/medium/large` as bin names — trireg
charge strengths; Riviera rejects what Questa tolerates).
**Lesson:** Two observers, same wire, different sample instants — the
stricter observer is the one that finds the protocol bug. And a bench that
has only ever run on one simulator (or none) has a class of bugs you simply
cannot have hit yet; the first hour on a real constrained-random solver found
five.

---

## Bonus 30-second stories (for "any other bugs?")

- **The constraint that never existed:** a vseq started
  `i2c_single_write_seq` without calling `randomize()` — so its
  `rand addr` field silently stayed 0; the constraint pinning it to 0x50
  never ran, because **a constraint only applies when its object is
  randomized**. Blew up two layers down at the item's `valid_addr_c`. Fix:
  non-rand field with a default. Directed tests had masked it for months by
  assigning `addr` explicitly.

- **Implicit STOP between bytes:** master went ACK→IDLE after every byte,
  releasing both lines; SDA rising under SCL-high IS a STOP, so multi-byte
  writes deselected the slave after byte 0. Fix: `STATE_BYTE_HOLD`, SCL held
  low between bytes — verified by asserting the slave's `active` never drops
  mid-burst.
- **The vseq that would deadlock:** inline `finish_item` on a ctrl item whose
  driver completes only after a transaction that hadn't been started yet.
  Never noticed because no test ran it — dead code can't deadlock.
- **Coverage flow that never worked:** `make sim` saved UCDBs into `sim/`,
  `make cov` merged from `logs/`, regress saved none. Months of "we have
  coverage" with zero mergeable databases. Fix: one path variable, both ends.
- **Random that couldn't randomize:** `default_trans_c` pinned
  `rep_start==0`, so 1000 stress transactions contained zero repeated
  STARTs — silent over-constraint, found by cross-checking constraints
  against coverage bins.
- **The false positives I refused to "fix":** review claimed the address
  latch drops the MSB (disproven: NBA reads the OLD shift_reg, which holds
  exactly a6..a0 at the 8th rise) and that the stretch counter false-times-out
  (disproven: it resets every SCL-high phase). Tracing WHY findings are wrong
  is half the job.
