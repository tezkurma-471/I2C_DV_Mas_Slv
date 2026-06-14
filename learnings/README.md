# I2C Project — Learnings Folder

This folder captures **session-by-session deep-dive notes** from mentor walkthroughs of the I2C verification project.

## Purpose

Each file documents:
- The **module/concept** being studied
- **Architectural understanding** (what + why)
- **Quiz Q&A** with honest scoring
- **Senior-engineer-grade answers** to each question (the answer NVIDIA/Qualcomm/Intel interview panels want to hear)
- **Interview traps and gotchas** specific to the concept
- **Action items** for follow-up

## How to use this folder

1. Read each `NN_*.md` file in numerical order.
2. After reading, **close the file** and try to answer the quiz questions out loud, as if in an interview.
3. If you get stuck, re-read. Repeat until the answers are reflexive.
4. Whenever you find a gap in your understanding, add it to `gaps.md` (create when needed).

## File index

> **⚠️ 2026-06-10:** a deep audit + fix pass changed many of the files these
> lessons describe. Affected lessons carry an **AUDIT UPDATE** banner at the
> top listing exactly what changed; [Lesson 19](./19_audit_fixes_walkthrough.md)
> covers the audit itself and is now the most interview-relevant lesson here.
> For interview prep, also see the `../interview/` folder.
>
> **✅ 2026-06-12:** the suite then ran on a commercial simulator for the
> first time (EDA Playground, Riviera-PRO 2025.04) — the shakedown found 4
> more bugs (incl. a real RTL one: stretch releasing the ACK), all fixed;
> final result **8/8 tests green, UVM_ERROR=0**. Lesson 19 §10 tells the
> story; `../docs/AUDIT_FIX_REPORT.md` §8 has the formal log.

| File | Topic | Status |
|---|---|---|
| [01_i2c_pkg_walkthrough.md](./01_i2c_pkg_walkthrough.md) | I2C package — params, enums, functions, include guards | ✅ (banner: IRQ enum redefined) |
| [02_i2c_wrappers_walkthrough.md](./02_i2c_wrappers_walkthrough.md) | i2c_master.sv / i2c_slave.sv thin wrappers | ✅ |
| [03_i2c_master_controller_walkthrough.md](./03_i2c_master_controller_walkthrough.md) | Master FSM deep-dive | ✅ (banner: BYTE_HOLD, 3-phase STOP/Sr, sync, stretch freeze) |
| [04_i2c_slave_controller_walkthrough.md](./04_i2c_slave_controller_walkthrough.md) | Slave FSM deep-dive | ✅ (banner: CDC sync, SDA gating, stretch_pending) |
| [05_i2c_protocol_assertions_walkthrough.md](./05_i2c_protocol_assertions_walkthrough.md) | SVA protocol checks | ✅ (banner: uvm_report_error, A2 removed, A8 fixed) |
| [06_i2c_interfaces_walkthrough.md](./06_i2c_interfaces_walkthrough.md) | i2c_if / i2c_slave_if, open-drain modeling | ✅ |
| [07_i2c_tb_top_walkthrough.md](./07_i2c_tb_top_walkthrough.md) | top_tb.sv wiring, config_db, run_test | ✅ |
| [08_i2c_seq_item_walkthrough.md](./08_i2c_seq_item_walkthrough.md) | Sequence item, constraints | ✅ (banner: ACKs now driver-populated) |
| [09_i2c_drivers_walkthrough.md](./09_i2c_drivers_walkthrough.md) | Master BFM + slave ctrl driver | ✅ (banner: driver rewritten — spec timing, stretch wait, NACK abort) |
| [10_i2c_monitors_walkthrough.md](./10_i2c_monitors_walkthrough.md) | Bus monitor + slave monitor | ✅ (banner: stretch threshold) |
| [11_i2c_agents_walkthrough.md](./11_i2c_agents_walkthrough.md) | Master/slave agents, active vs passive | ✅ |
| [12_i2c_scoreboard_walkthrough.md](./12_i2c_scoreboard_walkthrough.md) | Scoreboard / reference model | ✅ (banner: REWRITTEN — read it) |
| [13_i2c_coverage_walkthrough.md](./13_i2c_coverage_walkthrough.md) | 17 covergroups + crosses | ✅ (banner: report avg fixed) |
| [14_i2c_env_walkthrough.md](./14_i2c_env_walkthrough.md) | Environment, TLM connections | ✅ |
| [15_i2c_sequences_walkthrough.md](./15_i2c_sequences_walkthrough.md) | Sequence library | ✅ (banner: rep-chains in random/stress) |
| [16_i2c_virtual_seq_walkthrough.md](./16_i2c_virtual_seq_walkthrough.md) | Virtual sequencer/sequence | ✅ (banner: deadlock fixed, now used by T15) |
| [17_i2c_tests_walkthrough.md](./17_i2c_tests_walkthrough.md) | Test library | ✅ (banner: 19 tests) |
| [18_i2c_ral_walkthrough.md](./18_i2c_ral_walkthrough.md) | RAL: reg model, adapter, cpu agent | ✅ (banner: now buildable, vif fix) |
| [19_audit_fixes_walkthrough.md](./19_audit_fixes_walkthrough.md) | **The 2026-06 audit — verifying the verification** (+ §10: the Riviera shakedown, 8/8 green) | ✅ start here for interviews |

## Mentor-mode protocol (how these sessions run)

1. Mentor explains a module/concept top-down (architecture → details).
2. Mentor asks 5-10 quiz questions.
3. Student answers honestly — **"I don't know" is acceptable and preferred over bluffing.**
4. Mentor scores each answer, gives the senior-engineer-grade answer.
5. Notes are committed here for permanent reference.

**Why this matters:** The point isn't to "finish" the project. The point is to be able to **articulate every line** in an interview. Verification engineers are hired for clarity of thought, not for having a fancy GitHub repo.
