# I2C Protocol DV — Complete Learning Roadmap

## Who This Is For

You built this project. Now you need to *own* it — meaning you can explain every
line, defend every design decision, and answer any interview question thrown at you.
These 8 files will take you from "I wrote this code" to "I understand this code
at a senior engineer level."

---

## The 8 Files and What They Cover

| File | Topic | Difficulty |
|------|-------|-----------|
| 01 | I2C Protocol — from wire physics to waveforms | Beginner → Intermediate |
| 02 | RTL Master Controller — every line explained (incl. `arb_lost` detection) | Intermediate → Advanced |
| 03 | RTL Slave Controller — every line explained | Intermediate → Advanced |
| 04 | UVM Architecture — components, TLM, agents (incl. T13 multi-master pattern) | Intermediate → Advanced |
| 05 | SVA Assertions — formal temporal properties (now 9 assertions: A1-A9) | Advanced |
| 06 | Functional Coverage — measuring what matters (now 17 CGs; CG17 stretch×dir cross added in Part 19) | Intermediate |
| 07 | Bug Hunting Methodology — how to think like a senior | Advanced |
| 08 | Interview Questions — 90+ Q&A with explanations (incl. Section 7 on recent enhancements) | All levels |

### Companion artifact (not in `learning/` but referenced throughout)

| File | Purpose |
|------|---------|
| `docs/COVERAGE_CLOSURE_REPORT.md` | Sign-off-ready coverage closure analysis. Analytical (not simulation-run) because no commercial simulator is available locally. 780 lines covering 8 covergroups, 18 individual bins, 5 holes identified, 5 cross-coverage recommendations, sign-off checklist. Walked through in detail in `06_COVERAGE_DEEP_DIVE.md` Parts 16 and 17. |

---

## How to Use These Files

### First Pass (Week 1–2): Read, Don't Memorize
Read each file once. Don't try to memorize. Build the mental picture.

### Second Pass (Week 2–3): Active Recall
After reading each section, close the file. Write down everything you remember.
Compare to the file. What did you miss? That's what you study next.

### Third Pass (Week 3–4): Answer Interview Questions
Go to file 08. Cover the answers. Try to answer from memory.
If you can't answer, go back to the relevant deep-dive file.

### Fourth Pass (Week 4+): Teach It
Explain any concept to someone else (or to a rubber duck).
If you can't explain it simply, you don't understand it yet.

---

## The Senior Engineer Mindset — 5 Rules

### Rule 1: Protocol First, Code Second
Before reading any RTL, understand what the protocol requires.
If you know I2C says "SDA must be stable when SCL is HIGH",
you can immediately spot any RTL that changes SDA while SCL is high as a bug.

### Rule 2: Data Paths Are Everything
For every signal, ask:
- Where is it WRITTEN (source)?
- Where is it READ (sink)?
- Is there a TIMING gap between write and read?
This is how BUG #10 was found — shift_reg was written but never read into reg_data_buf.

### Rule 3: Simulate 3 Cycles in Your Head
For any counter, timer, or state machine transition, manually simulate
3–5 clock cycles. Write the values down. Off-by-one bugs live here.
This is how BUG #14 (stretch timer) was found.

### Rule 4: Check the Checkers
After verifying the DUT, verify the verification.
Can the assertion actually FAIL? Does the coverage measure the right signal?
This is how BUGs #11, #12, #13 were found.

### Rule 5: Know the WHY Behind Every Design Decision
Don't just know WHAT the code does. Know WHY it was written that way.
"Why is the bit counter reset in SLV_ACK?" 
"Because ACK is the 9th bit — not a data bit — and we need to restart counting for data."
This level of understanding impresses interviewers.

---

## Quick Reference — Key Numbers

| Parameter | Value | Meaning |
|-----------|-------|---------|
| CLK_FREQ_MHZ | 50 | 50 MHz system clock |
| T_SCL_PERIOD | 500 | 500 cycles = 10 µs = 100 kHz I2C |
| T_SCL_HIGH | 250 | SCL high for 5 µs per bit |
| T_SCL_LOW | 250 | SCL low for 5 µs per bit |
| T_HD_STA | 10 | START hold time (0.2 µs) |
| T_SU_STO | 10 | STOP setup time (0.2 µs) |
| T_BUF | 20 | Bus free time between STOP and START |
| MAX_CLK_STRETCH | 1000 | 20 µs max slave stretch before timeout |
| SLAVE_ADDR | 7'h50 | 0101_000 = address 80 decimal |

---

## Quick Reference — State Machines

### Master FSM (11 states)
```
IDLE → START_1 → START_2 → TX_BIT (×8) → ACK_WAIT → IDLE
                          → RX_BIT (×8) → ACK_SEND → IDLE
                          → STOP_1 → STOP_2 → IDLE
                          → REP_START_1 → REP_START_2 → TX_BIT
```

### Slave FSM (10 states)
```
IDLE → START → ADDR (×8) → ACK → RX (×8) → RX_ACK → (loop or STOP)
                               → TX (×8) → TX_ACK → (loop or IDLE)
                               → STRETCH → (saved_state)
                               → STOP → IDLE
```

---

## Start Here

Open **01_I2C_PROTOCOL_DEEP_DIVE.md** and read it completely before
looking at any code.

---

## Verification Inventory (Project Status as of 2026-05-12)

| Item | Count | Notes |
|------|-------|-------|
| RTL files (master + slave + pkg) | 5 | `rtl/` directory; master now has `arb_lost` detection logic |
| UVM components | ~12 | env, agents, drivers, monitors, scoreboard, coverage |
| Test classes | 18 | Was 17; T14 `deep_rep_start_test` added — see `uvm/i2c_tests.sv` |
| Sequence classes | 18 | Was 17; `deep_rep_start_sequence` added — see `uvm/i2c_sequences.sv` |
| SVA assertions | 9 | Was 6 (A1-A6 structural); now adds A7 (full T_BUF), A8 (hold), A9 (setup) — see file 05 Part 15/16. A1/A2 EDA playground parity fixed (Part 17). |
| Covergroups | 17 | CG1-CG17; CG17 is `i2c_stretch_dir_cross_cg` (stretch × direction, 4 cells) |
| Bugs found and fixed | 16 | BUG #16: invalid `stop_cond -> !rep_start` constraint removed from `valid_protocol_c` — see `uvm/i2c_seq_item.sv` |
| Sign-off artifact | 1 | `docs/COVERAGE_CLOSURE_REPORT.md` (analytical closure analysis) |
