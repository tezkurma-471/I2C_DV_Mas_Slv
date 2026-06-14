# 01 — The Project Story & The Thinking Behind Every Decision

This file is the narrative spine of the project. Interviews are won by people
who can explain **why**, not just **what**. Each section below gives the
decision, the reasoning that led to it, the alternatives that were rejected,
and the interview-grade one-liner.

---

## Part A — What the project is

**Goal:** verify a synthesizable I2C slave controller (7-bit address `0x50`,
8-register auto-incrementing memory, clock-stretching, force-NACK test hooks)
against the NXP UM10204 I2C specification, using a full UVM 1.2 environment.

**Inventory:**
- `rtl/` — slave controller + wrapper (the DUT), master controller + wrapper
  (synthesizable, used by the RAL bench and the smoke test, deliberately NOT
  in the UVM bus bench).
- `uvm/` — master agent (active BFM), slave agent (reactive, error
  injection), monitor, queued scoreboard, 17-covergroup collector, virtual
  sequencer/sequence, 19 tests; plus a CPU register agent for RAL.
- `sva/` — 8 live protocol assertions bound to the bus in `top_tb`.
- `ral/` — `uvm_reg` model of the master's CSR map + adapter + sequences,
  on its own top (`top_tb_ral`).
- `tb/` — interfaces (open-drain modeling), two UVM tops, and
  `tb_rtl_smoke.sv` — a pure-SV master↔slave integration test that runs on
  free Icarus Verilog (`make smoke`).
- `sim/`, `scripts/` — Questa Makefile (regression, coverage merge, RAL,
  smoke), multi-tool compile script, playground-bundle generator.

**Two-phase history (own this in interviews):**
1. *Build phase* — design + bench + 15 documented bug fixes (`BUG_REPORT.md`).
2. *Audit phase (2026-06)* — a deliberate adversarial re-review that found and
   fixed deeper problems **in the verification itself** (`docs/AUDIT_FIX_REPORT.md`).
   This phase is the better story: anyone can build a bench; few people can
   prove theirs works.

---

## Part B — The thinking process, decision by decision

### B1. "What am I actually verifying?" — scoping before coding

**Thinking:** The first decision in any DV effort is the DUT boundary. I chose
*block-level* verification of the **slave** alone. The master RTL exists, but
connecting master-RTL to slave-RTL and calling it a testbench is a trap: when
something fails you can't attribute blame — bad stimulus or bad response? A
**BFM (bus functional model) master inside the UVM driver** gives me stimulus
I control completely and can corrupt deliberately.

**Rejected alternative:** instantiate both RTL blocks and "verify the system."
Rejected because error injection (wrong addresses, NACKs, mid-byte
corruption) is nearly impossible through a well-behaved RTL master, and a
master bug would invalidate every slave result.

**One-liner:** *"One DUT per bench. The stimulus side must be something I
trust more than the DUT — that means a BFM, not another unverified RTL block."*

**The honest cost — and how the audit repaid it:** the master RTL was
therefore never simulated at all. The audit closed that hole with
`tb_rtl_smoke.sv`: master-RTL ↔ slave-RTL on real wires under Icarus. It
immediately found three master bugs (implicit STOP between bytes, Sr never on
the wire, STOP same-edge race). Lesson learned and worth saying out loud:
**"deliberately excluded" must not silently become "never tested anywhere."**

### B2. Modeling the physical layer — open-drain or bust

**Thinking:** I2C is wired-AND: any device can pull a line low; nobody may
drive it high. If the TB models SDA as a plain `logic` driven both ways, a
whole class of bugs (drive fights, ACK overlap, arbitration) becomes
*unrepresentable*. So the interface uses real electrical semantics:

```systemverilog
wire sda;
assign (weak1, highz0) sda = 1'b1;                          // pull-up resistor
assign (strong0, weak1) sda = (sda_drv == 1'b0) ? 1'b0 : 1'bz;  // open-drain driver
```

`strong0` beats `weak1`, so a slave ACK (pull low) wins over the released
line — exactly like silicon. A second hook (`sda_drv_x`) lets a "competing
master" pull the line for the arbitration test.

**One-liner:** *"If the bus model can't express a drive fight, the bench
can't detect one. I made contention representable first, then checkable."*

### B3. Stimulus architecture — transactions, not wiggles

**Thinking:** sequences speak in intent ("write 4 bytes to 0x50"), the driver
owns *all* pin timing. That separation is what makes 19 tests cheap — each
test is just policy: which sequence, how many, slave active or passive.

The seq item carries protocol *framing* as first-class fields
(`start_cond/stop_cond/rep_start`) with a constraint encoding legality
(`start XOR rep_start`, every segment begins with one of them). Repeated-START
chains are then just consecutive items: `{start, no stop}` → `{rep_start, stop}`.

**Audit lesson layered on top:** the convenience constraint `default_trans_c`
(start=1, stop=1, rep=0) silently fenced rep-START out of *random* stimulus —
1000 "random" stress items, zero Sr. Fixed by having random/stress sequences
explicitly run Sr chains ~25% of the time. **One-liner:** *"Default
constraints are stimulus policy; every policy must be audited against the
coverage model or your holes become permanent."*

### B4. The driver — a BFM that earns the assertions

**Thinking (post-audit version):** a BFM has two customers: the DUT and the
*checkers*. The original BFM ran ~5 clocks/bit with SDA moving on the same
edge as SCL — fast, but it made the protocol SVAs (hold/setup/bus-free
windows) mathematically unsatisfiable, which silently turned them into noise.
The rewritten BFM honors the spec constants from `i2c_pkg`
(`T_HD_DAT`, `T_SU_DAT`, `T_SU_STA/T_HD_STA/T_SU_STO`, `T_BUF`) plus margin
for the SVA sampling pipeline. It also:
- waits on the **wire** after releasing SCL (`scl_release_wait()`), making it
  genuinely clock-stretch aware, with a bounded timeout that errors loudly;
- records `addr_ack`/`byte_ack[]` into the item (facts travel with the
  transaction);
- **aborts on NACK** — address NACK → STOP with no data; data NACK → trim the
  item to bytes actually driven, so the expected stream matches the wire.

**One-liner:** *"The BFM's timing is part of the verification contract: if
the stimulus can't legally satisfy the assertions, the assertions are dead."*

### B5. Observation — a paranoid, independent monitor

**Thinking:** the monitor must reconstruct transactions **only** from SDA/SCL
edges — no peeking at the driver or DUT internals. If monitor and driver
shared logic, a common-mode bug would pass the scoreboard while the bus was
garbage. The monitor detects START/Sr/STOP as events (SDA edge qualified by
SCL high), shifts bits on SCL rises, captures per-byte ACKs, finalizes the
current item at Sr (chains become separate items, matching the driver's
view), and flags `stretch_seen` when SCL stays low beyond a threshold scaled
to the BFM's normal low phase.

**One-liner:** *"Checkers must observe, never echo. The monitor is the
prosecution's independent witness."*

### B6. Checking — the scoreboard as a court, not a counter

**Thinking (this is THE section to master):** the original scoreboard
*looked* complete and was 80% dead: writes incremented `match_count` without
comparing one byte; the shadow memory was built from driver *intent*. The
rewrite is organized around one question — *what facts do I have, and which
pairs of facts must agree?*

- **Two queues** (expected from driver, actual from monitor), matched
  pairwise when both sides have an entry → arrival-order independent.
- **Intent vs wire:** addr, dir, payload byte-for-byte, both directions.
- **ACK consistency:** driver-sampled vs monitor-observed; and protocol
  legality (only 0x50 may ACK).
- **Wire vs reference model:** shadow register bank built **from the monitor
  stream**, reads checked against it (DUT resets its pointer at every address
  ACK, so reads stream from reg 0 with mod-8 wrap — model mirrors that).
- **End-of-test:** `check_phase` flags leftovers in either queue (lost/extra
  transactions); `report_phase` cross-checks counts and prints the verdict.
- **Escape hatch with a leash:** `allow_bus_corruption`, settable only via
  config_db, used by exactly one test (arbitration) whose competing master
  corrupts the wire on purpose.

**One-liner:** *"My scoreboard separates three kinds of truth — intent,
wire, and model — and every check is a disagreement between two of them."*

### B7. Assertions — temporal spec, enforced

**Thinking:** SVAs encode the *bus rulebook* independent of any test: START
leads to clocking (A1), SDA stable under SCL-high (A3), ACK slot driven (A4),
stretch bounded (A5), no X/Z mid-packet (A6), full T_BUF bus-free after STOP
(A7), hold/setup windows at SCL edges (A8/A9). Three audit-era principles:
1. **Failures must be counted** — `uvm_report_error`, not `$error`.
2. **Encode the spec, not your wish** — A8 enforces a structural 2-cycle
   hold, not `T_HD_DAT=5`, because UM10204's t_HD;DAT min is 0 and the slave
   legally responds ~3 cycles after SCL falls through its synchronizers.
3. **Delete vacuous checks** — old A2's `##[1:T_BUF]` was existential
   ("high at ANY cycle in the window") — always true, pure noise, subsumed
   by A7.

### B8. Coverage — the contract for "when am I done?"

**Thinking:** 17 covergroups: direction, burst sizes, address ranges,
protocol flags, per-byte NACKs, stretch, rep-chain depth, and seven crosses
(the interesting bugs live in crosses: stretch×read, rep×dir, dir×size...).
Two audit lessons: (1) the report threshold must average **all** groups —
averaging 4 of 17 hid every hole in the other 13; (2) every cross must have a
*named test that can hit it* — stretch×read had none until
`stretch_read_test` was added. Coverage numbers are only honest per
regression run (`make cov`); the README no longer carries an evergreen
"100%" claim.

### B9. The RAL bench — register verification as its own discipline

**Thinking:** the master's CSR map (CTRL/CMD/STATUS/DATA/ADDR/IRQ_EN/IRQ_ST)
gets a `uvm_reg` model on a separate top: reset values, access policies
(RW/RO/WO — including reading the WO CMD register back as 0), and field-level
RMW without disturbing sibling fields. Separate top because register-path
unit testing doesn't need the bus bench — smaller compile, clearer intent.
Audit note to own honestly: this bench was dead code (compiled by nothing,
with a fatal vif type mismatch) until the audit wired it into the Makefile.

### B10. Infrastructure is part of verification

**Thinking:** a flow that *cannot* produce its coverage report (save/merge
path mismatch), or a script frozen at 15 of 18 tests, lies to you just as
effectively as a dead checker. Fixes: single source of truth for paths,
regression fails on any real `UVM_ERROR` line, run_all_tests.sh pinned to the
Makefile list, and `eda_playground/` made *generated* so it can't drift.
**One-liner:** *"I treat the Makefile as DUT #2. The audit found it had
never produced a coverage report — nobody noticed because nobody asserted
the artifact exists."*

### B11. The audit mindset itself (your best 5 minutes in any interview)

The method, step by step:
1. **State the claims** (README: 16 tests, 8 covergroups, 100% coverage,
   stretch-aware BFM) and grep-verify every one. Three were false. A claim
   you can't reproduce is a bug.
2. **Walk the kill-chain** for each failure class: corruption → monitor →
   compare → uvm_error → count → script → exit code. Fix every broken link.
3. **Mutation thinking:** "if I flip this byte / drop this ACK / hold SCL,
   which named check goes red?" No answer = no coverage, whatever the report
   says.
4. **Independent evidence:** new free-simulator smoke test with a different
   bench style — it found bugs the UVM bench *structurally couldn't* see.
5. **Verify the review:** several plausible audit findings were FALSE
   (address-latch "MSB drop" — disproven by NBA semantics; stretch-counter
   "false timeout" — disproven by its per-phase reset; monitor "race" —
   deterministic one-cycle-late, not a race). Tracing why they were wrong is
   the judgment interviews are probing for.

---

## Part C — Honest boundaries (rehearse these; they build trust)

1. **The UVM layer HAS now run on a commercial simulator** (EDA Playground,
   Riviera-PRO 2025.04, UVM 1.2 — 2026-06-12): 8/8 tests green, UVM_ERROR=0,
   scoreboard matched on every run. Locally I proved the RTL layer (Icarus
   smoke, 33 checks) and Verilator lint. Tell the shakedown story proudly:
   the FIRST run was 4/8 — it flushed out three never-executed constraint
   conflicts, a reserved-keyword portability bug, and one real RTL bug
   (stretch releasing the ACK) — see war story 7. The remaining honest gap:
   the full 19×3 regression with merged coverage still needs a licensed
   Questa (EDA Playground runs are isolated; no UCDB merge).
2. **Coverage** is reported per regression; I don't quote an evergreen
   percentage.
3. **Design-choice caveat I can defend:** the slave commits a force-NACK'd
   byte to its register bank (NACK and storage are independent here). The
   scoreboard models the DUT as built; whether a NACKing receiver *should*
   discard is a spec-interpretation discussion I'm happy to have.
4. **`i2c_reg_if` is not real APB** — single-cycle strobe, no
   PSEL/PENABLE/PREADY. Fine for this DUT; I'd add the handshake before
   connecting a real APB master.
5. **What I'd do next with more time:** mutation-test the bench
   (deliberately break RTL, confirm reds), reference-model the slave as a
   separate predictor class, formal (SymbiYosys) on the START/STOP detector
   and FSM deadlock-freedom, and a second slave instance for multi-slave
   addressing coverage.
