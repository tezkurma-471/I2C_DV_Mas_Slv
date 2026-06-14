# Interview Pack — I2C Protocol DV Project

This folder is your **single source for interview preparation** on this
project. If you can speak everything in these files without looking, you can
defend this project against any DV interview panel.

## The 30-second elevator pitch (memorize verbatim, then make it yours)

> "I built and verified an I2C slave controller end to end: synthesizable RTL
> for both master and slave, a full UVM 1.2 environment with an active master
> BFM, a reactive slave agent for error injection, a queued intent-vs-wire
> scoreboard, 17 covergroups, 9 protocol assertions, and a RAL bench for the
> master's register map. The part I'm proudest of isn't the build — it's the
> audit. I went back as a skeptic, asked 'if the DUT corrupted a byte, what
> exact chain turns that into a red FAIL?', and found that chain broken in
> multiple places: a scoreboard that never compared write data, assertions
> whose failures UVM never counted, and a clock-stretch feature that had never
> actually triggered. I fixed all of it, built a license-free RTL smoke test
> as independent evidence — which immediately caught three more RTL bugs,
> including a repeated-START that never appeared on the wire — then ran the
> full suite on a commercial simulator for the first time, where the first
> shakedown flushed out four more bugs, one of them a real protocol bug:
> the slave released its ACK during a clock stretch. All eight tests are
> green on Riviera-PRO now, and I documented every finding, fix, and even
> the review findings I *rejected* after tracing them against LRM scheduling
> semantics."

That last sentence is the differentiator. Bug counts impress juniors;
**judgment** (knowing which findings were false) impresses panels.

## Files in this folder

| File | What it gives you | When to study |
|---|---|---|
| [01_project_story_and_thinking.md](./01_project_story_and_thinking.md) | The full narrative: what was built, WHY each design decision was made, and the thinking process at every stage | First — this is your storyline |
| [02_i2c_protocol_cheatsheet.md](./02_i2c_protocol_cheatsheet.md) | Every protocol fact you must know cold, mapped to where this repo implements/verifies it | Second — protocol questions come first in real interviews |
| [03_end_to_end_flow.md](./03_end_to_end_flow.md) | One write+read transaction traced through every file: test → sequence → driver → wires → DUT → monitor → scoreboard → coverage, plus UVM mechanics (phases, config_db, TLM, objections) | Third — this answers "walk me through your testbench" |
| [04_debug_war_stories.md](./04_debug_war_stories.md) | Seven debugging stories in interview-ready STAR format (story 7 = the Riviera shakedown stretch-ACK bug) | Fourth — every panel asks "tell me about a hard bug" |
| [05_question_bank.md](./05_question_bank.md) | ~120 questions with answers: protocol, SV, UVM, assertions, coverage, project-grilling, behavioral | Continuously — quiz yourself out loud |

## Supporting material elsewhere in the repo

- `docs/AUDIT_FIX_REPORT.md` — the formal findings→fixes log (bring-to-interview artifact).
- `learnings/19_audit_fixes_walkthrough.md` — the audit as a lesson, with its own quiz.
- `learnings/01..18` — per-file deep dives (each carries an AUDIT UPDATE banner where code changed).
- `docs/learning/08_INTERVIEW_QUESTIONS.md` — earlier question set (superseded by 05_question_bank.md but still useful).

## How to prepare (a realistic plan)

1. **Day 1–2:** Read 01 and 03. Then, WITHOUT the docs, draw the testbench
   block diagram on paper and trace a write transaction out loud. Repeat
   until fluent.
2. **Day 3:** Memorize the protocol cheatsheet (02). Practice drawing the
   START/Sr/STOP waveforms by hand — interviewers hand you a marker.
3. **Day 4:** War stories (04). Practice telling each in under 3 minutes.
4. **Day 5+:** Question bank (05), 20 questions per session, OUT LOUD.
   Saying "I don't know" in practice is how you find what to fix.
5. **Before the interview:** run `make smoke` once and skim the output so
   "I verified the RTL with a free-simulator integration test" is a live,
   recent memory — and re-read the *Honest Boundaries* section of file 01 so
   you never overclaim.

## The one rule

**Never claim more than the repo shows.** This project's own history proves
why: the README once claimed a clock-stretch loop that didn't exist in the
code, and a "100% coverage" that was structurally impossible. The audit fixed
the claims along with the code. If an interviewer asks something you didn't
do, the winning answer is: "I didn't do that — here's how I would."
