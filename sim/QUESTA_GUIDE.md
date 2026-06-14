# QuestaSim Beginner Guide — running this project on the college PC

Written for someone who has **never opened QuestaSim before**. Follow top to
bottom. Total time first run: ~30–60 min depending on the machine.

The three helper scripts in this folder do everything — **no `make`, no
Linux, no bash needed**. They run inside Questa's own command shell (Tcl), so
they work identically on Windows and Linux:

| Script | What it does |
|---|---|
| `questa_one.do` | Compile everything + run ONE test |
| `questa_regress.do` | Compile once + run all 19 bus tests (+3 RAL) with a PASS/FAIL summary |
| `questa_cov.do` | Merge all coverage databases → HTML report |

---

## Step 1 — Get the project onto the PC

```
git clone https://github.com/k-pitaliya/i2c-protocol-dv.git
```

If git isn't installed: download the repo ZIP from GitHub in a browser
(green **Code** button → Download ZIP) and extract it somewhere simple like
`C:\i2c-protocol-dv` (avoid paths with spaces — EDA tools hate them).

## Step 2 — Open QuestaSim

Find **Questa Sim** (or "ModelSim") in the Start menu and open it. You'll see
a window with several panes. The only one you need is the **Transcript** pane
at the bottom — that's a command prompt that accepts both Tcl commands and
Questa commands. You'll type everything there.

Sanity check — type this in the Transcript and press Enter:

```tcl
vsim -version
```

It should print something like `QuestaSim-64 vsim 202x.x ...`. Write that
version down (good resume detail).

## Step 3 — Move into the project's sim/ folder

In the Transcript (note: **forward slashes**, even on Windows):

```tcl
cd C:/i2c-protocol-dv/sim
pwd
```

`pwd` must answer with the `.../i2c-protocol-dv/sim` path. Everything below
assumes you are in this folder.

## Step 4 — First single test (the checkpoint)

```tcl
do questa_one.do basic_write_test
```

What happens: it builds a `work` library, compiles ~10 files (takes a
minute), then runs the test. **Success looks like**, near the end:

```
SCOREBOARD PASSED: All transactions matched.
TEST PASSED: No UVM_ERROR messages
UVM_ERROR :    0
```

If you instead get an error, find it in the Troubleshooting table at the
bottom — the two most common are both about UVM setup and have one-line
fixes.

> Do not proceed to Step 5 until this single test is green.

## Step 5 — Quick regression (19 + 3 tests, one seed)

```tcl
do questa_regress.do
```

This compiles both benches once, then runs **19 bus-level tests + 3 RAL
tests** back-to-back, ~22 simulations. It ends with a summary like:

```
 PASS    basic_write_test             seed=1
 PASS    basic_read_test              seed=1
 ...
 Total: 22   Passed: X   Failed: Y
```

**Expect a few failures the first time.** Eleven of these tests (and all 3
RAL tests) have NEVER run on any simulator — only 8 were proven on
Riviera-PRO. A failure is data, not disaster: the log for each test is in
`logs/<test>_seed1.log`. Copy the failing logs home for debugging.

## Step 6 — Full regression (only if Step 5 is green or near-green)

```tcl
do questa_regress.do full
```

Same thing but 3 seeds per bus test = **60 simulations**. This takes a
while; start it and let it run.

## Step 7 — The merged coverage report (the prize)

```tcl
do questa_cov.do
```

This merges every `.ucdb` saved by the regression into
`coverage/merged.ucdb` and writes:

- `coverage/html/index.html` — open in a browser. **Screenshot the summary
  page** — this is the artifact EDA Playground can never give you.
- `coverage/coverage.txt` — text version.

## Step 8 — What to take home

Copy these to USB/Drive/GitHub before you leave:

1. the whole `logs/` folder (proof of regression, and the failing logs for debug)
2. the whole `coverage/` folder (merged.ucdb + html + txt)
3. a screenshot of the Transcript's final regression summary
4. note the exact Questa version string from Step 2

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `mtiUvm` / `uvm_pkg not found` at compile | Install's precompiled UVM library not visible | Open `questa_one.do`, comment out the first `vlog` block, uncomment the fallback `vlog` block right below it (compiles UVM 1.2 from source with `+define+UVM_NO_DPI`). Then also remove `-L mtiUvm` from the `vsim` line. Same edit in `questa_regress.do`. |
| `cannot find uvm_macros.svh` | UVM source dir not auto-found | Find the folder `verilog_src\uvm-1.2\src` inside the Questa install directory, then run: `set UVM_SRC {C:/path/to/verilog_src/uvm-1.2/src}` and re-run the do file. |
| `unknown command: do` or nothing happens | You typed into the wrong pane | Use the **Transcript** pane (bottom), not the editor. |
| `vlib: cannot create work` / permission denied | Project sits in a read-only or network-restricted folder | Move the project to something like `C:\i2c-protocol-dv` or your user folder. |
| Paths with errors mentioning `\i` or garbled paths | Backslashes in `cd` | Always use forward slashes in the Transcript: `cd C:/...` |
| A test seems hung (no output for minutes) | Possible stimulus/DUT deadlock — itself a finding | Press the **Break** button (or type Ctrl+C in the transcript), then `quit -sim`. Note which test; save whatever log exists. |
| License error at startup | College license server issue | Nothing in this repo can fix that — ask the lab admin. |
| Compile warnings (vlog-2583, vopt-...) | Normal | Ignore warnings; only Errors stop the build. |

## What the pass criteria mean (same as sim/Makefile)

A test PASSES only if **both**:
1. its log has **no real `UVM_ERROR` line** (the summary count line
   `UVM_ERROR :  N` is excluded from the check), and
2. it printed `SCOREBOARD PASSED` (bus tests; `arbitration_lost_test` uses
   its own `T13 ... PASS` marker, RAL tests use `TEST PASSED`).

Assertion (SVA) failures are routed through `uvm_report_error`, so they fail
a test through criterion 1 — they are not log decoration.
