> **⚠️ 2026-06-10 AUDIT UPDATE — read this box before trusting the lesson below.**
> A deep audit + fix pass changed the code this walkthrough describes. Deltas for this file:
> - 19 bus-level tests now (added `stretch_read_test` T15 running the virtual sequence with slave ACTIVE).
> - `arbitration_lost_test` sets `allow_bus_corruption` on the scoreboard — its competing master corrupts the wire on purpose, which the new byte-comparing scoreboard would otherwise (correctly) flag.
> - `clock_stretch_test` no longer sets the removed `stretch_seq.stretch_cycles` field.
> Full detail: [`19_audit_fixes_walkthrough.md`](./19_audit_fixes_walkthrough.md) and `docs/AUDIT_FIX_REPORT.md`.

# Lesson 17 — `i2c_base_test.sv` + `i2c_tests.sv` Deep Walkthrough

**Files under study:**
- `uvm/i2c_base_test.sv` (1.8 KB, 57 lines)
- `uvm/i2c_tests.sv` (16 KB, 412 lines, 17 derived test classes)

**Concepts covered:** UVM test class, `run_test`, factory registration, build_phase, run_phase, raise/drop objection mechanism, `+UVM_TESTNAME` plusarg, factory override at test level, `config_db` from the test scope, `report_phase` summary, timeout via `uvm_root.set_timeout`, smoke vs regression vs stress, designing new tests

**Date:** 2026-05-17

---

## Table of Contents

1. [The UVM Test Class — Top of the Hierarchy](#1-the-uvm-test-class--top-of-the-hierarchy)
2. [60-Second Elevator Pitch](#2-60-second-elevator-pitch)
3. [`i2c_base_test` — Line-by-Line Walkthrough](#3-i2c_base_test--line-by-line-walkthrough)
4. [`i2c_tests.sv` — All 17 Derived Tests Explained](#4-i2c_testssv--all-17-derived-tests-explained)
5. [Raising and Dropping Objections — Controlling End-of-Test](#5-raising-and-dropping-objections--controlling-end-of-test)
6. [Configuration via `config_db` from Inside a Test](#6-configuration-via-config_db-from-inside-a-test)
7. [Factory Override at the Test Level](#7-factory-override-at-the-test-level)
8. [`report_phase` — The Final Verdict](#8-report_phase--the-final-verdict)
9. [Timeout Handling — `uvm_root::set_timeout`](#9-timeout-handling--uvm_rootset_timeout)
10. [Quiz — 17 Questions](#10-quiz--17-questions)
11. [Quiz Answers — Senior-Engineer Grade](#11-quiz-answers--senior-engineer-grade)
12. [Key Takeaways](#12-key-takeaways)
13. [Action Items — Three New Tests to Add](#13-action-items--three-new-tests-to-add)
14. [Honest Self-Score Template](#14-honest-self-score-template)

---

## 1. The UVM Test Class — Top of the Hierarchy

Before any line of code, internalize this. The **test class** sits at the very top of the UVM component tree:

```
                       +----------------------+
                       |   uvm_root (top)     |
                       +----------------------+
                                 |
                                 v
                       +----------------------+
                       |    uvm_test (YOU)    |   <-- i2c_base_test (and 16 derived)
                       +----------------------+
                                 |
                                 v
                       +----------------------+
                       |      i2c_env         |   <-- agents, scoreboard, coverage
                       +----------------------+
                          |       |        |
                          v       v        v
                  master_agent  slave_agent  scoreboard
                     |    |
                     v    v
                 driver  monitor
```

### What the test class is responsible for

A UVM test class is the **only** place in the entire testbench that should know answers to questions like:

- "Should the slave agent be ACTIVE or PASSIVE for this run?"
- "Which top-level sequence should be started on the master sequencer?"
- "What overrides should be installed in the factory before `build_phase` propagates?"
- "How long should the test run before timing out?"
- "What constitutes pass/fail for this particular scenario?"

The env should be **agnostic** of test intent. The agent should not care which sequence runs. The sequencer should not care about pass/fail criteria. Only the test class knows the *scenario*.

> **Mentor note:** The single biggest UVM design mistake freshers make is putting scenario-specific code inside the env or the agent. The test class is your *only* legal place for scenario knowledge. The moment you `if (test_name == "burst")` inside an env, you have failed UVM design review.

### Why does the test sit at the top?

Because `run_test("i2c_base_test")` — called from the `initial` block in `top.sv` — uses the **UVM factory** to instantiate the named class at the root of the component tree. Every other component (env, agents, drivers, monitors, scoreboards) gets built recursively *from* the test through `build_phase`. So the test class is the **build root**.

This means: anything you `uvm_config_db::set(this, "env.path.to.thing", ...)` in the test's `build_phase` happens **before** the env builds itself, which means the env's `build_phase` can see it via `uvm_config_db::get`. That ordering — set in parent before get in child — is the entire trick.

### Mental model: the test class is the "main" function

Think of it like this:

| C analogy | UVM analogy |
|---|---|
| `main()` | `i2c_base_test::run_phase()` |
| `argc/argv` | `+UVM_TESTNAME=<class>` and other `+plusargs` |
| Linking with library | Factory registration via `\`uvm_component_utils` |
| Static initialisers | `build_phase` and `connect_phase` |
| Process exit code | `report_phase` querying error count |

---

## 2. 60-Second Elevator Pitch

When an interviewer at NVIDIA/Qualcomm/Intel/AMD asks: *"Walk me through how your UVM tests are organised,"* say this:

> *"I have a base test class `i2c_base_test` that extends `uvm_test`, registers with the factory, builds the environment, and runs a default smoke sequence — write-then-read at slave address 0x50. Every scenario-specific test extends this base. I have 17 derived tests: basic write/read, burst write/read, write-read combo, repeated-start, address-NACK, data-NACK, clock stretching, arbitration loss, random directed, address sweep, bus-free check, sequential transactions, data-pattern (walking-ones, alternating), stress, and a deep repeated-start test for coverage closure. Each test selects its top-level sequence, configures the env via `config_db` if it needs the slave agent active or driver flags set, raises an objection, starts the sequence on the appropriate sequencer, then drops the objection. `report_phase` in the base test reads `UVM_ERROR` count from the report server and emits the pass/fail line. The test is selected at runtime via `+UVM_TESTNAME` on the simulator command line. I never need to recompile to run a different test."*

That paragraph is your interview gold. Memorise the **shape**: base test, factory, build env, set config_db, raise objection, start seq, drop objection, report_phase, +UVM_TESTNAME.

---

## 3. `i2c_base_test` — Line-by-Line Walkthrough

The base test file is short — 57 lines — but every line matters. Let us walk it.

### 3.1 Include guard (lines 8-9, 56)

```systemverilog
`ifndef I2C_BASE_TEST_SV
`define I2C_BASE_TEST_SV
...
`endif
```

Standard C-style include guard. Same rationale as covered in Lesson 01 (`i2c_pkg.sv`): if the project uses `\`include` flows (EDA Playground, older Makefiles), guards prevent duplicate class declarations. If you compile via a file list (`-f files.f` listing each file once), guards are redundant but harmless.

### 3.2 Class declaration and factory registration (lines 11-13)

```systemverilog
class i2c_base_test extends uvm_test;

  `uvm_component_utils(i2c_base_test)
```

Two pieces here, both load-bearing.

**`extends uvm_test`** — This pulls in `build_phase`, `connect_phase`, `end_of_elaboration_phase`, `run_phase`, `report_phase`, and the whole UVM phasing machinery. `uvm_test` is itself a thin extension of `uvm_component` that exists purely to mark a class as runnable via `run_test`.

**`\`uvm_component_utils(i2c_base_test)`** — This macro expands to roughly:

```systemverilog
typedef uvm_component_registry#(i2c_base_test, "i2c_base_test") type_id;
static function type_id get_type();           return type_id::get(); endfunction
virtual function uvm_object_wrapper get_object_type(); return type_id::get(); endfunction
function string get_type_name(); return "i2c_base_test"; endfunction
```

The key effect: `i2c_base_test` is now **registered with the UVM factory** under the string name `"i2c_base_test"`. That registration is what allows `run_test("i2c_base_test")` to find and instantiate the class by string.

> **Interview-grade answer:**
> *"The `uvm_component_utils` macro registers the class with the UVM factory using the class name as a string key. This registration is what makes `+UVM_TESTNAME=i2c_base_test` work — without it, the factory cannot resolve the string to a class type at runtime."*

### 3.3 Member: handle to the env (line 15)

```systemverilog
i2c_env env;
```

A handle, **not yet constructed**. It will be constructed in `build_phase` via the factory. Resist the urge to `new()` it directly — that bypasses the factory and kills your ability to override env types from a derived test.

### 3.4 Constructor (lines 17-19)

```systemverilog
function new(string name = "i2c_base_test", uvm_component parent = null);
  super.new(name, parent);
endfunction
```

UVM component constructors must take `(string name, uvm_component parent)`. Default values let the factory create the component without supplying them explicitly. `super.new` registers this instance in the UVM tree under its parent's namespace.

### 3.5 `build_phase` (lines 21-24)

```systemverilog
function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  env = i2c_env::type_id::create("env", this);
endfunction
```

Two things to note:

1. **`super.build_phase(phase)`** — always call this. It executes any base-class build logic. Skipping it is a silent bug magnet.

2. **`i2c_env::type_id::create("env", this)`** — this is the **factory create** call. It is *not* `new i2c_env(...)`. Why? Because `type_id::create` consults the factory's override table first. If a derived test has installed an override like `i2c_env::type_id::set_type_override(my_special_env::get_type())`, the factory returns `my_special_env` instead. With `new()`, you get exactly what you typed — overrides are ignored. **Always use `type_id::create` for UVM components.**

The parent argument (`this`) sets the component's hierarchical name to `uvm_test_top.env`. That hierarchical path is what `config_db` and the UVM hierarchy printer use.

### 3.6 `run_phase` (lines 26-39)

```systemverilog
virtual task run_phase(uvm_phase phase);
  i2c_write_read_seq smoke;
  phase.raise_objection(this, "i2c_base_test starting");

  `uvm_info(get_type_name(), "=== I2C Base Test Starting ===", UVM_LOW)

  smoke = i2c_write_read_seq::type_id::create("smoke");
  smoke.start(env.master_agent.sequencer);

  #500;

  `uvm_info(get_type_name(), "=== I2C Base Test Complete ===", UVM_LOW)
  phase.drop_objection(this, "i2c_base_test done");
endtask
```

This is the **canonical UVM run_phase pattern**. Memorise it. Five steps:

| Step | Code | Purpose |
|---|---|---|
| 1 | `phase.raise_objection(this, ...)` | Tells UVM "do not end the test, I am working." |
| 2 | `seq = T::type_id::create("seq")` | Factory-create the top-level sequence. |
| 3 | `seq.start(env.agent.sequencer)` | Blocking — runs the sequence to completion. |
| 4 | `#500;` (optional drain) | Lets trailing transactions finish on the bus. |
| 5 | `phase.drop_objection(this, ...)` | Releases UVM to advance past `run_phase`. |

The `virtual` keyword on `run_phase` matters: derived tests must override it, and the factory uses dynamic dispatch through the base handle.

> **Interview trap:** *"Why is `#500` after `start()`?"* The `start()` task **returns when the sequence finishes pushing the last item to the driver** — but the driver may still be wiggling pins. The drain delay lets the final STOP condition complete, the monitor finalize its observation, and the scoreboard compare its last expected vs actual. Without it, the test may pass for the wrong reason (last transaction never reached the scoreboard, so no mismatch logged).

### 3.7 `report_phase` (lines 41-52)

```systemverilog
virtual function void report_phase(uvm_phase phase);
  uvm_report_server server;
  int err_count;
  super.report_phase(phase);
  server = uvm_report_server::get_server();
  err_count = server.get_severity_count(UVM_ERROR);
  if (err_count == 0) begin
    `uvm_info(get_type_name(), "TEST PASSED: No UVM_ERROR messages", UVM_LOW)
  end else begin
    `uvm_error(get_type_name(), $sformatf("TEST FAILED: %0d UVM_ERROR messages", err_count))
  end
endfunction
```

`report_phase` runs **after** `run_phase`, `extract_phase`, and `check_phase` complete. At this point, every scoreboard has finished checking, and every `\`uvm_error` that was ever going to fire has fired. The base test queries the singleton `uvm_report_server` for the running count of `UVM_ERROR` messages.

Two subtleties to know cold:

1. **Why query the server, not maintain a local counter?** Because any component anywhere in the tree might call `\`uvm_error`. A local counter would miss errors from scoreboards, monitors, drivers — every component reports through the server. The server is the single source of truth.

2. **Why is the pass message a `UVM_INFO` but the fail message a `UVM_ERROR`?** Because the fail message must itself **increment the error count** so external pass-detection scripts (Makefile `grep`) see a non-zero error count even if it was the only one. If you used `\`uvm_info` for fail, the Makefile might still think the test passed.

> **Interview-grade answer:**
> *"`report_phase` is the canonical place to emit the final pass/fail summary. I query `uvm_report_server::get_server()` for the `UVM_ERROR` severity count — that captures errors from every component in the tree. If the count is zero, I emit `TEST PASSED` as `UVM_INFO`; otherwise I emit `TEST FAILED` as `UVM_ERROR` so external regression scripts grepping for errors will catch it."*

---

## 4. `i2c_tests.sv` — All 17 Derived Tests Explained

The file declares 17 test classes. Each one extends `i2c_base_test` and **overrides `run_phase`** to start a different top-level sequence. A few also override `build_phase` to set `config_db` values that change env behaviour.

Let us walk every one of them.

### 4.1 The boilerplate every derived test repeats

Look at any derived class — they all share this shape:

```systemverilog
class <name>_test extends i2c_base_test;
  `uvm_component_utils(<name>_test)
  function new(string name = "<name>_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    <some_sequence> seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting <name>_test...", UVM_LOW)
    seq = <some_sequence>::type_id::create("seq");
    // ... optional knob-setting on seq ...
    seq.start(env.master_agent.sequencer);
    #<drain>;
    `uvm_info(get_type_name(), "<name>_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
```

> **Mentor note:** This shape repeats 17 times because UVM is verbose. In a real production codebase, you would often write a parameterised templated base test or use a macro to cut this boilerplate. For your project, keeping it explicit is fine — it is readable, debuggable, and what an interviewer expects to see from a fresher.

### 4.2 `basic_write_test` (lines 12-29) — the simplest scenario

```systemverilog
write_seq = i2c_single_write_seq::type_id::create("write_seq");
write_seq.addr = 7'h50;
write_seq.data = 8'hA5;
write_seq.start(env.master_agent.sequencer);
```

Single transaction: write 1 byte (`8'hA5`) to slave at address `7'h50`. Drain `#500`.

**Smoke-test category.** This is your sanity check — if `basic_write_test` fails, nothing else will pass. Every regression suite runs this first.

The addressing: `7'h50` is the project's chosen slave address (defined in `i2c_pkg.sv` likely as a default). `8'hA5` (binary `1010_1010`) is a classic test pattern — alternating bits stress the bus for stuck-at faults.

### 4.3 `basic_read_test` (lines 31-47) — the mirror

```systemverilog
read_seq = i2c_single_read_seq::type_id::create("read_seq");
read_seq.addr = 7'h50;
read_seq.start(env.master_agent.sequencer);
```

Single read of 1 byte from `7'h50`. Note: no `.data` field set — for a read, the master sends the address with R/W=1 and **receives** the data; what the slave returns depends on its internal state.

> **Interview trap:** *"What if the slave is passive and never drives anything?"* Then SDA stays high (pulled up), the master reads `0xFF`, and the scoreboard's predictor must know this. Some projects make the predictor probe the slave's internal state directly. Yours uses an active slave when needed (see `data_nack_test`, `clock_stretch_test`).

### 4.4 `burst_write_test` (lines 49-66)

```systemverilog
burst_wr_seq = i2c_burst_write_seq::type_id::create("burst_wr_seq");
burst_wr_seq.addr = 7'h50;
burst_wr_seq.burst_len = 8;
burst_wr_seq.start(env.master_agent.sequencer);
#2000;
```

Writes 8 bytes back-to-back with a single START and STOP. Drain `#2000` because a burst takes proportionally longer.

**Why this matters in protocol terms:** A burst write in I2C is `START → ADDR+W → byte0 → byte1 → ... → byteN → STOP`. Between bytes, the slave issues ACK. The transaction is *atomic* — no STOP between bytes. This is how real systems (EEPROM page write, sensor multi-register configuration) operate.

### 4.5 `burst_read_test` (lines 68-85)

Same as burst_write but with reads. ACK/NACK semantics flip: the **master** must ACK every byte except the last, then NACK the last byte to signal "I am done reading." Forgetting that final NACK is a classic real-bug — the slave keeps clocking out bytes forever.

> **Coverage hook:** The burst-read sequence is where you check coverage for `master_acks_all_but_last`. If your bins are not closing, the burst length might be too short or the seq is not driving the right pattern.

### 4.6 `write_read_test` (lines 87-102)

Combines a write and a read in one test by starting `i2c_write_read_seq`. This sequence is also the **default in the base test** — it is the smoke.

Difference from `basic_write_test`+`basic_read_test`: those are two separate test runs; `write_read_test` runs both in one simulation pass, exercising bus transitions between the two transactions.

### 4.7 `rep_start_test` (lines 104-119)

```systemverilog
rep_seq = i2c_rep_start_seq::type_id::create("rep_seq");
rep_seq.start(env.master_agent.sequencer);
```

**Repeated START** (Sr) is an I2C protocol primitive where the master generates another START condition *without* releasing the bus with STOP between transactions. Use case: "write address pointer to EEPROM, then read from that pointer without releasing the bus to another master."

Wire-level: at the moment a normal START would require SDA=1 first (bus free), repeated START requires SCL=1 and SDA going 1→0 while the master still owns the bus.

### 4.8 `addr_nack_test` (lines 121-137)

```systemverilog
nack_seq.wrong_addr = 7'h55;
```

Master addresses `7'h55` instead of `7'h50`. The slave at `0x50` does **not** match → does not ACK. Master must detect the missing ACK and bail out cleanly.

Verification value: this exercises the master's **error-path FSM** — usually under-tested compared to happy-path code.

### 4.9 `data_nack_test` (lines 139-167) — FIRST test that activates the slave agent

```systemverilog
virtual function void build_phase(uvm_phase phase);
  uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent", "is_active", UVM_ACTIVE);
  super.build_phase(phase);
endfunction
```

This is where it gets interesting. The test does **two new things**:

1. **Overrides `build_phase`** to push a config_db value *before* `super.build_phase(phase)` runs (which builds the env, which builds the slave_agent). The slave_agent's `build_phase` calls `uvm_config_db::get(...)` for `is_active`; this test's set call ensures it gets `UVM_ACTIVE`.

2. **In run_phase**, starts a second sequence on the slave's sequencer in a `fork ... join_none` so it runs concurrently with the master sequence:

```systemverilog
fork
  nack_ctrl_seq.start(env.slave_agent.sequencer);
join_none

write_seq.start(env.master_agent.sequencer);  // blocking
```

The slave sequence `i2c_slave_force_nack_seq` makes the slave's driver assert NACK on a data byte. Master under test must see the NACK and respond correctly.

> **Interview trap:** *"Why `fork join_none` and not `fork join`?"* Because `fork join` would block until **both** sequences finish, but the slave sequence might wait forever for a transaction the master never sends due to a bug. `fork join_none` launches the slave sequence as a background thread and proceeds immediately. The slave thread is killed when the run_phase exits.
>
> *"Could `fork join_any` work?"* It could, but you would not want the master sequence to be killed if the slave sequence finishes first. `join_none` is the safe default for "background helper."

### 4.10 `clock_stretch_test` (lines 169-199) — slave delays SCL

```systemverilog
stretch_ctrl_seq.stretch_cycles = 16'd100;
```

I2C allows the **slave** to hold SCL low when it needs more time. This is "clock stretching." A real slave (e.g., a slow ADC) might stretch SCL for tens of microseconds while it captures a sample.

The test:
1. Activates the slave agent (same config_db pattern as data_nack).
2. Starts the slave's stretch-control sequence in a `fork join_none`.
3. Starts the master's stretch-aware write sequence.

The master must:
- Detect SCL being held low after it released it.
- Wait for SCL to return high before continuing.
- Not glitch its data during the stretch.

This is one of the **most common real-world I2C bugs** in silicon — masters that do not implement clock-stretch detection at all, and freeze when paired with a slow slave.

### 4.11 `random_directed_test` (lines 201-217)

```systemverilog
rand_seq.num_txns = 50;
```

50 randomized transactions back-to-back. "Directed-random" means: random within a constrained set of valid transaction types. Not pure chaos — the constraints in `i2c_random_seq` (which you would have seen in Lesson 16 on sequences) enforce sane address ranges, valid data, no malformed protocol.

**Why this matters:** Constrained random is the *bread and butter* of UVM. It is what coverage closure relies on. Pure directed tests close 30% of bins; constrained random closes the other 60%; the last 10% needs another directed pass.

### 4.12 `addr_sweep_test` (lines 219-234)

Sweeps every valid 7-bit address (probably `7'h08` through `7'h77` — excluding reserved). Drain `#20000` because there are 112 valid addresses.

**Coverage hook:** Closes per-address coverage bins. Cheap and high-value test.

### 4.13 `bus_free_test` (lines 236-266) — checks bus state AFTER transaction

```systemverilog
if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", vif)) begin
  `uvm_fatal(get_type_name(), "i2c_vif not found")
end
...
if (vif.sda === 1'b1 && vif.scl === 1'b1) begin
  `uvm_info(... "BUS FREE CHECK PASSED" ...)
end else begin
  `uvm_error(... "BUS FREE CHECK FAILED" ...)
end
```

Subtle pattern: the test directly **reaches into the virtual interface** to assert that after a STOP, both SDA and SCL are high (bus idle).

This is the *only* test that bypasses the agent/monitor abstraction. Why? Because the *post-condition of STOP* is a property of the wire, not of any transaction. The scoreboard sees transactions, not wire state. So the test peeks the wire directly.

> **Mentor note:** Some teams would consider this layering violation — a test should not know about `i2c_if`. The clean way is a dedicated **bus-state assertion** in the monitor or a SVA in the interface. Your codebase does it inline. Fine for project scope; mention the cleaner alternative in interviews.

### 4.14 `sequential_txn_test` (lines 268-284)

10 sequential transactions, one after another with full STOPs between them. Different from burst (which has no STOP between bytes inside one transaction). Tests bus settling, idle state, and start-stop-start sequencing.

### 4.15 `data_pattern_test` (lines 286-301)

Walking-ones, walking-zeros, alternating patterns (`0xAA`, `0x55`, `0xFF`, `0x00`). The pattern sequence is responsible for the actual values. Tests for **stuck-at faults** on the data lines.

### 4.16 `full_stress_test` (lines 303-319)

```systemverilog
stress_seq.num_txns = 100;
...
#50000;
```

100 transactions, drain 50 µs. The "regression-grade" workload. Long-running, exercises queue depths, FIFO overflows, back-to-back robustness. If this passes, your DUT is solid.

### 4.17 `arbitration_lost_test` (lines 343-378) — multi-master simulation

```systemverilog
uvm_config_db#(bit)::set(this, "env.slave_agent.driver", "compete_mode", 1'b1);
uvm_config_db#(int)::set(this, "env.slave_agent.driver", "compete_at_bit", 3);
```

Activates slave agent **and** configures its driver to "compete mode" — at SCL pulse #3, the slave driver pulls SDA low while the master is trying to drive it high. Because I2C is wired-AND, low wins, and the master detects arbitration loss.

The comment in the file is excellent — read it again:

> *"The competing-master task (inside the slave driver) waits for the master to issue START, counts SCL pulses, and at bit position `compete_at_bit` pulls SDA LOW."*

This is a **clever hack**: the slave driver is repurposed to pose as a second master. Real multi-master verification would have a second master agent, but for one corner-case test, hijacking the slave driver is pragmatic.

> **Interview gold:** *"How does the master detect arbitration loss?"* It samples SDA after each bit it transmits. If SDA reads 0 when the master drove 1, someone else is on the bus and winning. The master must back off — release SDA and SCL, abort the transaction, raise `arb_lost`.

### 4.18 `deep_rep_start_test` (lines 388-409) — coverage-closure test

```systemverilog
deep_seq = deep_rep_start_sequence::type_id::create("deep_seq");
deep_seq.addr = 7'h50;
deep_seq.start(env.master_agent.sequencer);
```

A 4-segment repeated-start chain: `W(no STOP) → W(no STOP) → W(no STOP) → R(STOP)`. The comment names the exact covergroup bins this closes — CG11, CG14, CG16.

**Lesson:** Real verification projects often need *one-off tests* whose only purpose is closing a specific coverage hole. Their names and comments should make this explicit. This test's comment block is exemplary.

### 4.19 Summary table of all 17 tests

| Test class | Category | Active slave? | Sequence | Drain | Purpose |
|---|---|---|---|---|---|
| `i2c_base_test` | smoke | No | `i2c_write_read_seq` | 500 | Default smoke |
| `basic_write_test` | smoke | No | `i2c_single_write_seq` | 500 | Sanity 1-byte write |
| `basic_read_test` | smoke | No | `i2c_single_read_seq` | 500 | Sanity 1-byte read |
| `burst_write_test` | regression | No | `i2c_burst_write_seq` | 2000 | 8-byte write burst |
| `burst_read_test` | regression | No | `i2c_burst_read_seq` | 2000 | 8-byte read burst |
| `write_read_test` | regression | No | `i2c_write_read_seq` | 1000 | Combined W+R |
| `rep_start_test` | regression | No | `i2c_rep_start_seq` | 1000 | Repeated START |
| `addr_nack_test` | error injection | No | `i2c_nack_addr_seq` | 500 | Master sees address NACK |
| `data_nack_test` | error injection | YES | `i2c_data_nack_seq` + slave-force-nack | 500 | Master sees data NACK |
| `clock_stretch_test` | corner | YES | `i2c_clock_stretch_seq` + stretch ctrl | 2000 | Slave holds SCL low |
| `random_directed_test` | random | No | `i2c_random_seq` × 50 | 5000 | Constrained random |
| `addr_sweep_test` | coverage | No | `i2c_addr_sweep_seq` | 20000 | All valid addresses |
| `bus_free_test` | corner | No | `i2c_bus_free_seq` | 700 | Bus idle after STOP |
| `sequential_txn_test` | regression | No | `i2c_sequential_seq` × 10 | 3000 | Back-to-back txns |
| `data_pattern_test` | coverage | No | `i2c_data_pattern_seq` | 3000 | Walking ones/zeros |
| `full_stress_test` | stress | No | `i2c_stress_seq` × 100 | 50000 | Long stress |
| `arbitration_lost_test` | multi-master | YES (compete mode) | `arb_lost_sequence` + slave drive | 20us | Master loses arb |
| `deep_rep_start_test` | coverage | No | `deep_rep_start_sequence` | 2000 | 4-segment rep-start |

---

## 4.20 Three under-the-hood patterns to spot in this file

Beyond the test list, three patterns recur and reward close reading.

### Pattern A — handle declaration at the top of `run_phase`

Every derived test starts `run_phase` with a declaration like `i2c_single_write_seq write_seq;`. SystemVerilog has block-scoped variables — these are scoped to the run_phase task only. Two consequences:

1. The handle vanishes when run_phase exits. The sequence object itself still exists if anything else references it (the sequencer queue, the driver's current item), but the test's handle is gone. This is fine for fire-and-forget use; if you needed to access the sequence later (e.g., in `report_phase`), you would promote it to a class member.

2. Declaration must precede any statement in the task — SV requires variable declarations at the top of begin/end blocks. If you tried to mix declarations and `phase.raise_objection(...)`, you would get a compile error.

### Pattern B — direct field assignment vs `randomize() with`

The tests set sequence knobs directly: `write_seq.addr = 7'h50; write_seq.data = 8'hA5;`. They do **not** call `write_seq.randomize() with {addr == 7'h50; data == 8'hA5;}`.

Both approaches reach the same end-state, but direct assignment is simpler when:
- The values are constants (no constraint exploration needed).
- You want absolute control without inline constraint syntax.

Randomize-with is preferred when:
- You want to constrain *one* field while letting others stay random.
- You want the SV solver to verify constraint feasibility.
- The sequence has internal constraints that should be enforced together with the test's overrides.

> **Interview-grade answer:**
> *"Direct assignment skips the constraint solver. It is fastest and most readable for fully-constrained scenarios. `randomize() with` invokes the solver, which is essential when you want to constrain some fields while randomizing others, or to make sure your test-level overrides are still consistent with the sequence's own constraints. The choice signals intent: directed test vs partial-random test."*

### Pattern C — drain delays vary by test

Note the drains: 500, 2000, 5000, 20000, 50000. They are not arbitrary — they scale with expected runtime.

| Test class | Drain (sim time units) | Reasoning |
|---|---|---|
| `basic_write_test` | 500 | One byte + STOP = ~100 ticks; 500 leaves headroom |
| `burst_*_test` | 2000 | 8 bytes × ~100 ticks = 800; 2000 generous |
| `random_directed_test` | 5000 | 50 txns at variable lengths |
| `addr_sweep_test` | 20000 | 112 addresses × startup time |
| `full_stress_test` | 50000 | 100 txns × full I2C cycle each |

**Senior insight:** Drains are *protective margins*, not exact predictions. Better than guessing: use `phase.phase_done.set_drain_time(this, ...)` declaratively, or block until the scoreboard reports its queue is empty.

A more rigorous pattern (worth proposing as a project improvement):

```systemverilog
virtual task run_phase(uvm_phase phase);
  phase.raise_objection(this);
  seq.start(seqr);
  wait (env.scoreboard.pending_count() == 0);  // synchronize on scoreboard drain
  phase.drop_objection(this);
endtask
```

This replaces the magic-number drain with a deterministic synchronization. More robust, more readable, requires the scoreboard to expose `pending_count()`.

---

## 5. Raising and Dropping Objections — Controlling End-of-Test

The objection mechanism is one of the most important — and most misunderstood — parts of UVM. Get it cold.

### 5.1 What is an objection?

A UVM phase has an internal counter: the **objection count**. The phase **cannot end** while the count is > 0. Any component can `phase.raise_objection(this)` to increment the count and `phase.drop_objection(this)` to decrement it. When the count returns to zero, the phase advances.

```
  start of run_phase
       |
       | count = 0  →  phase would end immediately
       |
   test calls raise_objection → count = 1
       |
   seq starts, runs to completion
       |
   #500 drain
       |
   test calls drop_objection → count = 0
       |
   end of run_phase → UVM moves to extract_phase
```

### 5.2 Why "objection" and not "lock"?

Because multiple components can object simultaneously. The test objects. A scoreboard might object until its queue drains. A monitor might object until it sees STOP. **All** of them must drop their objections before the phase ends.

This is exactly the right semantics. You do not want the test to exit while the scoreboard still has unchecked transactions in its inbox.

### 5.3 The classic bug — forgetting to drop

```systemverilog
phase.raise_objection(this);
some_seq.start(seqr);
// ... forgot drop_objection ...
endtask
```

Result: **simulation hangs**. UVM keeps the phase open forever waiting for the objection count to hit zero. You see the test do its work, log all transactions, then sit there. Eventually a hard timeout fires (see §9) and you get a `UVM_FATAL`.

> **Interview question:** *"You ran a test and the simulator hung at the end after all transactions completed. What is the most likely cause?"*
>
> **Interview-grade answer:**
> *"The most likely cause is a missing `phase.drop_objection(this)` in the `run_phase` of the test or some component. The simulator's phase scheduler is waiting on the objection count to reach zero. The fix is to audit every `raise_objection` and make sure every code path leads to a corresponding `drop_objection`, ideally bracketed around the work."*

### 5.4 Best-practice patterns

**Pattern 1: bracket around work** (what your base test does):
```systemverilog
phase.raise_objection(this);
// ... work ...
phase.drop_objection(this);
```

**Pattern 2: use a try/finally idiom** — UVM lacks it, but `fork ... join_none` + a wrapper task helps for complex flows.

**Pattern 3: `phase.phase_done.set_drain_time(this, 500ns)`** — instead of `#500` after the sequence, this declarative drain is cleaner because it does not block.

### 5.5 Optional description argument

```systemverilog
phase.raise_objection(this, "i2c_base_test starting");
phase.drop_objection(this, "i2c_base_test done");
```

The string argument is purely for logging. UVM's `+UVM_OBJECTION_TRACE` plusarg will print these — invaluable for debugging hangs in big component trees with dozens of objections.

---

### 5.6 Objections and runtime phases (UVM 1.2)

If you migrate to refined runtime phases (`reset_phase`, `main_phase`, etc.), each phase has its **own** objection counter. You must raise and drop on the right phase handle:

```systemverilog
virtual task reset_phase(uvm_phase phase);
  phase.raise_objection(this);
  // ... reset stimulus ...
  phase.drop_objection(this);
endtask

virtual task main_phase(uvm_phase phase);
  phase.raise_objection(this);
  // ... main stimulus ...
  phase.drop_objection(this);
endtask
```

Raising on `reset_phase` does not keep `main_phase` alive — they are independent. If you forget to drop on `reset_phase`, the test hangs in reset and never reaches main.

### 5.7 Objections from a sequence (advanced)

A `uvm_sequence` itself can manage objections via `set_automatic_phase_objection(1)` in its constructor or `starting_phase.raise_objection(this)` inside `body`. This is useful when a sequence runs at the top level (started via `default_sequence`) without a test class doing the bracketing.

Your project does *not* use this pattern — every test class brackets its own sequence start. That is the clearer pattern for a learning project; the sequence-managed pattern is for advanced reuse scenarios.

### 5.8 The "starvation" anti-pattern

Avoid raising objections from *too many* components. If your env has 5 agents and 3 scoreboards all objecting independently, end-of-test debugging becomes painful — you have to track 8 separate drop calls.

**Best practice:** one component "owns" the objection (usually the test class). Other components either:
- Use `phase.phase_done.set_drain_time(this, ns)` to declare a passive drain requirement.
- Communicate with the owning component (e.g., scoreboard exposes `pending_count()` to the test) and let the owner decide when to drop.

This pushes coordination into one place and keeps objection bookkeeping debuggable.

---

## 6. Configuration via `config_db` from Inside a Test

The test class is the **uppermost component** in the build hierarchy, so it is the *only* place that can set config_db values guaranteed to be visible to the env before the env builds itself.

### 6.1 Pattern 1: change agent active/passive

```systemverilog
virtual function void build_phase(uvm_phase phase);
  uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent", "is_active", UVM_ACTIVE);
  super.build_phase(phase);
endfunction
```

Used by `data_nack_test`, `clock_stretch_test`, `arbitration_lost_test`.

Critical detail: the `set` call is **before** `super.build_phase(phase)`. Why? Because `super.build_phase` is what runs `env = i2c_env::type_id::create(...)`, and the env's `build_phase` immediately queries config_db. Set must precede the get.

> **Order matters.** This is the #1 silent bug pattern: someone moves the set after super.build_phase, env grabs the default value, test fails inexplicably.

### 6.2 Pattern 2: drive driver-level flags

```systemverilog
uvm_config_db#(bit)::set(this, "env.slave_agent.driver", "compete_mode", 1'b1);
uvm_config_db#(int)::set(this, "env.slave_agent.driver", "compete_at_bit", 3);
```

Used by `arbitration_lost_test`. The test reaches **three levels deep** into the hierarchy. Works because config_db scope is hierarchical-string-based.

### 6.3 Pattern 3: pass virtual interface

```systemverilog
if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", vif)) begin
  `uvm_fatal(get_type_name(), "i2c_vif not found")
end
```

Used by `bus_free_test`. The vif was originally set in the top-level testbench (`top.sv`'s initial block) before `run_test` was called. The test fetches it via the global scope (`""` as inst_name).

### 6.4 Config_db scope rules — short version

| Where you `set` from | Visible to |
|---|---|
| top.sv initial (before `run_test`) | Anywhere in the tree |
| test's `build_phase` | All descendants (env, agents, drivers, etc.) below the test |
| env's `build_phase` | Agents and below (NOT the test) |
| agent's `build_phase` | Driver, monitor, sequencer of that agent |

**Universal rule:** set wins if the setter is **closer to the root** of the component tree than another setter. Test-level sets *always* override env-level sets for the same key. This is intentional — it lets tests customise envs without forking env code.

### 6.5 The wildcard trap

You can use `"*"` in the instance path:

```systemverilog
uvm_config_db#(int)::set(this, "env.*.driver", "verbosity", 400);
```

This sets `verbosity` on every driver under `env.<anything>`. Powerful, but **dangerous** — if you have both master and slave drivers and only meant one, the wildcard catches both. Audit wildcard usage in code review.

### 6.6 Type matching gotcha

`config_db` is **type-strict**. If you set `int` and get `bit`, it does not match — the get returns false. Common bug:

```systemverilog
// Set as 32-bit int:
uvm_config_db#(int)::set(this, "env.driver", "delay", 100);

// Get as logic [31:0] in driver:
logic [31:0] delay;
uvm_config_db#(logic[31:0])::get(this, "", "delay", delay);  // ← fails silently
```

You will not get a compile error. You get a runtime "not found" which the get's return code reports — but if you do not check the return code (`if (!uvm_config_db#(...)::get(...)) ...`), you proceed with `delay = 0` (the default).

> **Interview-grade answer:**
> *"`config_db` is parametrized on type — set and get must match exactly. There is no implicit conversion. Always check the return code of `get` and `uvm_fatal` if it fails — silent type mismatches are the most common config_db bug."*

### 6.7 When to use `config_db` vs class fields

Decision matrix:

| Need | Use |
|---|---|
| Pass virtual interface from top to deep components | `config_db` (only viable option for vif) |
| Pass active/passive enum to agent | `config_db` (set by test, read by agent) |
| Pass a constant configuration object to env | `config_db` (set by test, read by env at build) |
| Pass an int known at compile time across env | `parameter` on env class |
| Pass a transient value during run_phase | Direct field access or analysis port |

Rule of thumb: `config_db` for build-time configuration that varies per test. Anything else, use stronger SV mechanisms (parameters, class fields, analysis ports).

---

### 6.8 Worked example — tracing config_db through a real test run

Let us trace `data_nack_test` end-to-end to make `config_db` flow concrete.

**Step 1: top.sv sets the virtual interface**

```systemverilog
// In top.sv initial block, BEFORE run_test():
initial begin
  uvm_config_db#(virtual i2c_if)::set(null, "*", "i2c_vif", dut_if);
  run_test();
end
```

This makes `dut_if` (the vif instance to the DUT) available to *anyone* in the tree under the key `"i2c_vif"`.

**Step 2: `run_test()` resolves the test class**

UVM sees `+UVM_TESTNAME=data_nack_test`, factory looks it up, instantiates as `uvm_test_top` at the root.

**Step 3: `data_nack_test::build_phase` runs**

```systemverilog
virtual function void build_phase(uvm_phase phase);
  uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent", "is_active", UVM_ACTIVE);
  super.build_phase(phase);   // <-- triggers env construction
endfunction
```

At this point, the config_db has two entries (assuming agents check is_active):
- `uvm_test_top.env.slave_agent.is_active = UVM_ACTIVE`
- `*.i2c_vif = dut_if`

**Step 4: env's build_phase runs (called by `super.build_phase`)**

The env creates agents:
```systemverilog
master_agent = i2c_master_agent::type_id::create("master_agent", this);
slave_agent  = i2c_slave_agent::type_id::create("slave_agent",  this);
```

**Step 5: slave_agent's build_phase runs**

```systemverilog
virtual function void build_phase(uvm_phase phase);
  uvm_active_passive_enum is_active_local;
  super.build_phase(phase);
  if (!uvm_config_db#(uvm_active_passive_enum)::get(this, "", "is_active", is_active_local))
    is_active_local = UVM_PASSIVE; // default
  this.is_active = is_active_local;
  // builds driver only if active
  if (is_active == UVM_ACTIVE)
    driver = i2c_slave_driver::type_id::create("driver", this);
endfunction
```

The `get(this, "", "is_active", ...)` queries the config_db using the agent's full hierarchical name (`uvm_test_top.env.slave_agent`). It finds the entry set by the test in Step 3. Result: `is_active = UVM_ACTIVE`. Driver is built.

**Step 6: connect_phase, end_of_elaboration_phase fire**

These run after all components exist. The slave driver's vif is already grabbed via `config_db.get` earlier.

**Step 7: run_phase fires on test**

The test raises objection, forks the slave control sequence on `env.slave_agent.sequencer` (which now exists because the agent is active), starts the master sequence in the foreground.

**Step 8: report_phase, $finish**

Standard end-of-test flow.

This trace is the **mental model** an interviewer wants you to demonstrate. Walking it out loud during an interview proves you understand UVM, not just memorised macros.

---

## 7. Factory Override at the Test Level

This concept appears implicitly in your code (`type_id::create` everywhere) but no test in `i2c_tests.sv` currently uses factory override. You **must** know it for interviews.

### 7.1 The mechanism

The UVM factory has a global table:

```
{i2c_master_driver}   →  default: i2c_master_driver
{i2c_master_seq_item} →  default: i2c_master_seq_item
```

In a derived test, you can install an override:

```systemverilog
virtual function void build_phase(uvm_phase phase);
  set_type_override_by_type(i2c_master_driver::get_type(),
                            i2c_master_driver_with_glitch::get_type());
  super.build_phase(phase);
endfunction
```

Now anywhere in the env that does `i2c_master_driver::type_id::create(...)`, the factory returns the glitch-injecting subclass. The env code is **completely unchanged**.

### 7.2 Why this is powerful

You can write a single env and dozens of tests, each with a different "personality":
- `glitch_test` overrides the driver with a glitch-injector.
- `slow_monitor_test` overrides the monitor with a delayed-sample version.
- `malformed_seq_item_test` overrides `seq_item` with a subclass that bypasses constraints.

Without factory override, every variant would need its own env or its own agent. With factory override, the env and agent are *test-agnostic*.

### 7.3 Two flavours

| API | Use when |
|---|---|
| `set_type_override_by_type(...)` | Replace *all* instances of type A with type B globally. |
| `set_inst_override_by_type(...)` | Replace only the instance at hierarchical path "env.master_agent.driver". |

Instance override is rarer but useful when you want, say, the master driver glitchy and the slave driver normal.

### 7.4 Constraints override (sequence item subtype)

The most common use case in real DV:

```systemverilog
class evil_i2c_item extends i2c_master_seq_item;
  constraint c_evil { data inside {[8'hF0:8'hFF]}; } // ← force evil values
endclass

class evil_test extends i2c_base_test;
  virtual function void build_phase(uvm_phase phase);
    set_type_override_by_type(i2c_master_seq_item::get_type(),
                              evil_i2c_item::get_type());
    super.build_phase(phase);
  endfunction
endclass
```

Now the same sequence — without any change — generates `evil_i2c_item` instances with biased constraints. Pure power.

> **Interview-grade answer:**
> *"Factory override at the test level lets me change DUT-facing behaviour without modifying the env or agent. I install the override in `build_phase` before `super.build_phase`. The most common use cases are: replacing the sequence_item with a constrained subtype to bias stimulus, replacing the driver with an error-injecting variant, or replacing the scoreboard with a variant that tolerates expected mismatches. The pattern is critical for keeping the env reusable across many tests."*

---

## 8. `report_phase` — The Final Verdict

Already walked in §3.7, but here we go deeper.

### 8.1 Phase ordering

UVM phases relevant to end-of-test:

```
run_phase            ← stimulus runs here, objections control duration
  ↓
extract_phase        ← extract data from monitors/scoreboards
  ↓
check_phase          ← cross-checks
  ↓
report_phase         ← emit final summary (THIS)
  ↓
final_phase          ← cleanup
```

`report_phase` runs **once per component**, top-down. Your base test's report_phase fires when the entire test is done.

### 8.2 Querying the report server

```systemverilog
server = uvm_report_server::get_server();
err_count = server.get_severity_count(UVM_ERROR);
```

Other severities you can query:
- `UVM_INFO` — informational messages
- `UVM_WARNING` — soft issues
- `UVM_ERROR` — test failures
- `UVM_FATAL` — unrecoverable, killed the sim

**Rule:** for pass/fail, only `UVM_ERROR` matters. `UVM_FATAL` already terminated the sim before `report_phase` runs.

### 8.3 Why not count warnings as failures?

Warnings are advisory. A coverage tool might emit warnings ("low coverage on this group") that should not fail the test. A test fails if and only if functional behaviour was wrong → `UVM_ERROR`.

Some teams adopt the convention "warnings = errors in regression" by setting `set_report_severity_override(UVM_WARNING, UVM_ERROR)`. Discuss with your tech lead before flipping that switch.

### 8.4 Augmenting the report

The base test's report_phase can be extended in derived tests by overriding:

```systemverilog
virtual function void report_phase(uvm_phase phase);
  super.report_phase(phase);  // base's pass/fail print
  // additional test-specific summary:
  `uvm_info(get_type_name(), $sformatf("Stress: %0d/%0d transactions passed",
                                       passed_cnt, total_cnt), UVM_LOW)
endfunction
```

For your project, the base implementation is reused across all 17 derived tests because none override it. Clean.

---

## 9. Timeout Handling — `uvm_root::set_timeout`

If a test hangs (forgotten drop_objection, sequence stuck waiting for a response, etc.), you do **not** want simulation to run forever. Set a global timeout.

### 9.1 Where to set it

In `top.sv`'s initial block, before or after `run_test`:

```systemverilog
initial begin
  uvm_root::get().set_timeout(10ms, 1);  // 10 ms hard limit
  run_test();
end
```

The second argument (`overridable`) is `1` to let `+UVM_TIMEOUT` plusarg override at runtime.

### 9.2 Per-test timeouts

For tests with very different runtime expectations (basic_write_test → 500 ns; full_stress_test → 50 µs), set the timeout *inside* the test's `build_phase`:

```systemverilog
virtual function void build_phase(uvm_phase phase);
  uvm_top.set_timeout(200us, 1);
  super.build_phase(phase);
endfunction
```

Your codebase does **not** currently set per-test timeouts. They are inherited from `top.sv` (which I have not read here, but it likely sets a generous global like 10 ms).

> **Mentor note:** A common interview probe: *"Your stress test runs 50 µs of stimulus but the global timeout is 1 ms. What if you accidentally write a stress test that needs 2 ms?"* Answer: it times out with `UVM_FATAL`. The fix is to either bump the global, or override the timeout in the test's build_phase, or accept that the simulator caught your runaway test before the cluster bill exploded.

### 9.3 `+UVM_TIMEOUT=<time>,YES`

Plusarg form. Useful for one-off debug runs:
```
vsim +UVM_TESTNAME=full_stress_test +UVM_TIMEOUT=100ms,YES
```

---

## 10. Quiz — 17 Questions

Cover the answer section. Aim for 13/17 on first pass.

1. What is the role of `\`uvm_component_utils(i2c_base_test)` and what would break if you removed it?

2. In `build_phase`, why is `env = i2c_env::type_id::create("env", this)` used instead of `env = new("env", this)`? Give a concrete failure scenario.

3. In `run_phase`, what does `raise_objection` do mechanistically? What state inside UVM is it modifying?

4. Walk through `+UVM_TESTNAME=basic_write_test` from command line to running test. Name every step.

5. The base test's `run_phase` has `#500;` after `smoke.start(...)`. Why? What would change if you removed it?

6. Explain `data_nack_test`'s use of `fork ... join_none`. Why not `fork join` or `fork join_any`?

7. In `data_nack_test::build_phase`, the order is `set(); super.build_phase();`. What happens if you flip them?

8. How does `report_phase` decide pass vs fail? Why is the failure message a `\`uvm_error` and not `\`uvm_info`?

9. Three components in the tree all `raise_objection`. The test drops its objection. Does the phase end? Why or why not?

10. A test extends `i2c_base_test`, overrides `run_phase`, raises an objection, starts a sequence, but never drops the objection. What is the failure mode and how do you detect it from a log file?

11. Name three legitimate use cases for `set_type_override_by_type` at the test level.

12. What is the difference between a "smoke test", a "regression test", and a "stress test"? Give a definition and a concrete example from `i2c_tests.sv` for each.

13. **Design a test:** I want to verify that the master correctly recovers when SDA is glued low for 500 ns mid-transaction (a transient bus fault). Outline what components you would override, what config_db values you would set, what sequence you would start, and what you would check in `report_phase`.

14. **Design a test:** I want to verify cross-address-byte arbitration loss (master loses arbitration not in the data phase but in the address phase). How would you adapt `arbitration_lost_test`?

15. **Design a test:** I want to verify the master correctly handles 100 back-to-back burst writes interleaved with random clock-stretches by the slave. What sequence(s), what config, what timing concerns?

16. Where should you start a sequence with `fork ... join_none` in the test vs inside another sequence? What is the rule?

17. The project currently has 17 tests. If a colleague asks you to add `repeated_addr_nack_test` (master tries the same wrong address 5 times in a row), walk through every file you would touch and what change goes in each.

---

## 11. Quiz Answers — Senior-Engineer Grade

### Q1 — `\`uvm_component_utils` role

The macro does **three things**:

1. Defines a nested `type_id` typedef that points at `uvm_component_registry#(i2c_base_test, "i2c_base_test")`.
2. Provides `get_type()`, `get_object_type()`, `get_type_name()` virtual functions used by the factory.
3. Registers the class with the global UVM factory under the string `"i2c_base_test"`.

Without it, `run_test("i2c_base_test")` cannot find the class — the factory has no string→class mapping. You get a `UVM_FATAL: factory lookup failed`. Also, `i2c_base_test::type_id::create(...)` does not compile because `type_id` is not defined.

> **Interview-grade answer:**
> *"`\`uvm_component_utils` is the macro that registers a component class with the UVM factory using its string name. Without it, neither `run_test` nor `type_id::create` work — they both rely on the factory registry. It also defines the `type_id` nested typedef and `get_type_name` function used throughout UVM machinery."*

### Q2 — Why `type_id::create` instead of `new`

`type_id::create` consults the factory's override table. `new` does not. Concrete failure scenario: a derived test wants to use `evil_i2c_env` instead of `i2c_env`, so it installs `set_type_override_by_type(i2c_env::get_type(), evil_i2c_env::get_type())` in its `build_phase`. If the base test's `build_phase` does `env = new("env", this)`, the override is ignored — you get `i2c_env`. With `type_id::create`, the factory returns `evil_i2c_env`.

> **Interview-grade answer:**
> *"`type_id::create` is factory-aware — it checks the override table and returns the overridden type if one is installed. `new` is plain SystemVerilog object creation and bypasses the factory entirely. Always use `type_id::create` for UVM components; it preserves the env's ability to be customised by derived tests through factory overrides. Using `new` defeats the entire factory-override pattern."*

### Q3 — `raise_objection` mechanism

`phase.raise_objection(this, "string")` increments an internal counter on the `uvm_objection` object associated with the phase. The phase scheduler will not advance past this phase while the count is > 0. The string is purely for log output with `+UVM_OBJECTION_TRACE`.

There is also a notion of "propagation": objections propagate up to the parent phase by default, but in modern UVM 1.2/1800-2017 the propagation rules are usually invisible to you because everyone objects on the same phase handle.

### Q4 — `+UVM_TESTNAME=basic_write_test` flow

1. Simulator command line includes `+UVM_TESTNAME=basic_write_test`.
2. `top.sv`'s initial block calls `run_test()` with **no argument**.
3. `run_test()` checks for `+UVM_TESTNAME=<name>` plusarg using `$value$plusargs`.
4. If found, it passes that string to the factory.
5. Factory looks up `"basic_write_test"` in its registry — finds the entry installed by `\`uvm_component_utils(basic_write_test)`.
6. Factory calls the registered creator function, which does `new basic_write_test("uvm_test_top", null)`.
7. The returned instance becomes the root of the component tree.
8. UVM runs phases (build, connect, run, etc.) on the tree.
9. Test completes, `report_phase` fires, `$finish`.

> **Interview-grade answer:**
> *"`run_test()` with no argument reads `+UVM_TESTNAME` from the command line, asks the factory to look up that string, and uses the registered creator to instantiate the test at the root of the component tree. Every other component is then built recursively in `build_phase`. This is what lets the same compiled binary run any of 17 tests by changing only a plusarg — no recompile needed."*

### Q5 — Why `#500` after `start()`

`start()` returns when the last sequence item is consumed by the driver. The driver may still be wiggling pins to send the last byte and STOP condition. The monitor may not have observed the STOP yet. The scoreboard may not have processed its last queued comparison.

Removing `#500` would let `run_phase` end immediately after `start()`, which drops the objection prematurely, which makes the test exit before the bus settles. Symptoms: scoreboard mismatches that disappear when you add the drain back, monitors complaining about "transaction interrupted at end of test."

Cleaner alternative: `phase.phase_done.set_drain_time(this, 500ns)` — declarative drain that does not block the test thread.

### Q6 — `fork ... join_none` in `data_nack_test`

`fork join_none` spawns the slave control sequence as a background thread and **continues immediately**. The master sequence then runs to completion in the foreground.

Why not `fork join`? Because `join` waits for **all** forked processes. If the slave control sequence loops indefinitely waiting for transactions, the test never proceeds past the fork.

Why not `fork join_any`? Because `join_any` proceeds when *any* one process finishes, and would kill the surviving processes when the parent thread terminates. Subtle and not what you want.

`fork join_none` says: "kick this off, don't wait, and let it die when the parent thread ends." Correct semantics for a background helper.

> **Interview-grade answer:**
> *"`fork join_none` is the canonical idiom for spawning a background sequence on a different sequencer while the main thread continues with its own work. `join` would block until the helper finishes — wrong, since the helper often runs forever. `join_any` would couple termination semantics in confusing ways. `join_none` cleanly separates: helper runs in background, foreground does its job, when foreground exits the helper dies with its parent process."*

### Q7 — Flipping `set()` and `super.build_phase()`

```systemverilog
// WRONG order:
virtual function void build_phase(uvm_phase phase);
  super.build_phase(phase);  // ← builds env, env queries config_db, finds nothing
  uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent", "is_active", UVM_ACTIVE);
endfunction
```

`super.build_phase(phase)` runs `env = i2c_env::type_id::create("env", this)`. The env constructor and its build_phase fire synchronously inside that call. The env's build_phase queries `uvm_config_db::get(this, "", "is_active", ...)` *before* this test's set call ever happens. Result: slave_agent stays at its default (likely PASSIVE), `data_nack_test` cannot drive NACK from the slave side, test fails.

**Rule:** all config_db sets that target descendants must come **before** `super.build_phase(phase)`.

### Q8 — How `report_phase` decides pass/fail

It queries the singleton `uvm_report_server` for the running count of `UVM_ERROR` severity. If zero → pass. Else → fail.

The fail message must itself be a `\`uvm_error` because:
- The `uvm_error` macro internally calls the report server with severity `UVM_ERROR`.
- External regression infrastructure (Makefile `grep "UVM_ERROR"`) sees the error and marks the test as failed.
- If you used `\`uvm_info` for the fail print, the only error count would be from the failing component, not the summary line.

Actually it works either way if at least one other `UVM_ERROR` already fired — but the convention of "the summary is itself an error if failed" is robust and self-consistent.

### Q9 — Multiple objections

If three components raised and only the test drops, the count goes from 3 → 2. **Phase does not end.** The phase scheduler waits for the other two to drop. This is exactly the behaviour you want — the test cannot exit while the scoreboard still has pending work.

### Q10 — Forgotten drop_objection

**Failure mode:** simulation hangs after all visible test activity completes. Eventually `uvm_top.set_timeout` fires → `UVM_FATAL: TIMEOUT` → sim ends with non-zero exit code.

**Detection from log:**
- Look for "UVM_FATAL ... TIMEOUT" near the bottom of the log.
- Enable `+UVM_OBJECTION_TRACE` and rerun — you will see every raise/drop with timestamps. The component(s) that raised but never dropped show up as having an unmatched raise.
- Use `uvm_objection::display_objections()` from a final block or from inside a debug task to print pending objections.

> **Interview-grade answer:**
> *"Forgotten drop_objection causes the test to hang at end-of-stimulus. The phase scheduler waits forever for the objection count to reach zero. Detection: look for `UVM_FATAL TIMEOUT` in the log, then rerun with `+UVM_OBJECTION_TRACE` — that prints every raise and drop with timestamps and component names, making the unmatched raise obvious. Prevention: bracket every raise with a drop in the same task, or use `phase_done.set_drain_time` to avoid manual objections for simple cases."*

### Q11 — Three legitimate uses for `set_type_override_by_type`

1. **Stimulus biasing:** Replace `i2c_master_seq_item` with `evil_i2c_master_seq_item` that has tighter or perverse constraints — same sequence, different data distribution.
2. **Error injection:** Replace `i2c_master_driver` with `i2c_master_driver_with_glitch` that occasionally drives invalid pin transitions — exercises DUT robustness without touching test sequences.
3. **Coverage extension:** Replace `i2c_master_monitor` with an enhanced monitor that emits additional analysis transactions for new covergroups — adds visibility without modifying env structure.

### Q12 — Smoke vs regression vs stress

| Category | Definition | Example from `i2c_tests.sv` |
|---|---|---|
| **Smoke** | Minimum-viable sanity check; runs first; fast; "is the build alive?" | `basic_write_test`, `basic_read_test`, `i2c_base_test` |
| **Regression** | Broader functional coverage; runs nightly; catches feature breaks. | `burst_write_test`, `rep_start_test`, `sequential_txn_test` |
| **Stress** | Long-running; many transactions; tries to exhaust queues, expose race conditions, hit timing corners. | `full_stress_test` (100 txns, 50 µs drain), `random_directed_test` (50 random txns) |

> **Interview-grade answer:**
> *"Smoke tests are the absolute minimum — if they fail, the build is broken and there is no point running anything else. Regression tests are the full functional test plan run nightly; they take an hour or two and catch any feature breakage. Stress tests run thousands of transactions or use long randomized stimulus to exhaust queues and find race conditions; they often run over the weekend. The three differ in runtime, coverage breadth, and failure consequences."*

### Q13 — Design a SDA-glued-low transient fault test

**Components and config:**
- Activate slave agent: `uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent", "is_active", UVM_ACTIVE);`
- New driver mode flag: `uvm_config_db#(int)::set(this, "env.slave_agent.driver", "fault_at_us", 5);`
- New driver flag: `uvm_config_db#(int)::set(this, "env.slave_agent.driver", "fault_duration_ns", 500);`

**Sequence:** Master runs `i2c_burst_write_seq` with `burst_len=10` so the transaction is long enough to catch the fault.

**Slave-side helper:** `fork join_none` a `sda_glue_low_ctrl_seq` that, after `fault_at_us` microseconds, drives the slave driver's SDA pin low for `fault_duration_ns` nanoseconds.

**Check in run_phase:** After burst completes, peek `vif.sda === 1'b1 && vif.scl === 1'b1` (bus free); check scoreboard counters that master either recovered the transaction or cleanly aborted.

**Pass criteria in report_phase:** No `UVM_ERROR`, scoreboard reports either "transaction completed despite fault" or "transaction aborted cleanly with bus returning idle."

### Q14 — Arbitration loss in address phase

Reuse `arbitration_lost_test` but change `compete_at_bit` to a value in the address byte (bits 0-7 of the first byte after START). Set `compete_at_bit = 1` to collide at address bit 6.

Additionally, the address byte being sent must have a `1` in that position so the competing low drive actually wins. Choose master address `7'h2A = 010_1010` — bit 6 is 0, bit 5 is 1, so colliding at bit 5 is meaningful. Update both the seq's address and the `compete_at_bit` accordingly.

The master FSM's arbitration check should fire identically — arbitration is checked on **every bit**, address or data, in real I2C.

### Q15 — 100 burst writes with random clock stretches

**Sequence design:** Build a new top-level sequence `burst_with_stretch_seq` that loops 100 times. Each iteration: pick a random `burst_len` from `[2:16]`, optionally inject a stretch request via a config_db value the slave driver polls.

**Slave-side helper sequence** runs in `fork join_none` and periodically (randomized inter-arrival 1-5 µs) triggers a stretch event of random duration 100-500 SCL cycles.

**Timing concerns:**
- Drain: `100 burst_writes × avg 8 bytes × 10 µs each = ~8 ms`. Set `uvm_top.set_timeout(20ms, 1);` in this test's build_phase.
- Scoreboard ordering: stretches must not cause the scoreboard to lose track of pending transactions. Verify the scoreboard's pending queue does not grow unboundedly.

**Coverage hook:** add a cross-coverage of `burst_len × stretch_during_byte_position`.

### Q16 — Fork in test vs in sequence

| Location | Rule |
|---|---|
| Inside test's `run_phase` | Use `fork join_none` only for **helper sequences on other sequencers** that need to run concurrently with the main sequence. Never fork the main sequence itself. |
| Inside another sequence's `body` | Use `fork join_none` for spawning child sequences that are coordinated through `pre_do`/`post_do` callbacks or shared data members. Fine for protocol-level concurrency (e.g., simultaneous read+write on different channels). |

> **Interview-grade answer:**
> *"In the test, fork is for cross-sequencer coordination — main sequence on master sequencer, helper sequence on slave sequencer. Inside a sequence, fork is for protocol-level concurrency within one transaction or one sequencer. The rule of thumb: keep the test class declarative (high-level scenario) and put low-level concurrency inside sequences. If a fork in the test class is doing protocol-level work, that work probably belongs in a sequence instead."*

### Q17 — Adding `repeated_addr_nack_test`

Files to touch and changes:

1. **`uvm/i2c_seq_lib.sv`** (or wherever your sequence library lives): add a new sequence `i2c_repeated_nack_addr_seq` that loops 5 times, each time addressing the wrong slave and starting the nack sub-sequence. Add factory registration `\`uvm_object_utils`.

2. **`uvm/i2c_tests.sv`**: add a new class `repeated_addr_nack_test extends i2c_base_test`. Follow the boilerplate pattern. In `run_phase`, create the new sequence, set `seq.wrong_addr = 7'h55`, `seq.num_repeats = 5`, start on master_agent.sequencer, drain `#2500;`. Register with `\`uvm_component_utils`.

3. **`Makefile`** (if you have one): add a target `repeated_addr_nack_test:` that runs `vsim +UVM_TESTNAME=repeated_addr_nack_test`. Add to the `regression:` target if it should run nightly.

4. **`docs/TESTPLAN.md`** (if it exists): add a row describing the new test, its sequence, its purpose, and which coverage bins it closes.

5. **`coverage/i2c_coverage.sv`** (optional): if you want a new covergroup bin for "5+ consecutive address NACKs", add it.

> **Mentor note:** This is exactly the kind of "walk me through adding a test" question NVIDIA recruiters ask. The wrong answer is "I would add the test." The right answer enumerates **every file touched**, in order, with reasoning. Practice this for your own project until you can recite it cold.

---

## 12. Key Takeaways

### Conceptual

1. **The test class is the only place that should know test-specific scenarios.** Env, agents, drivers, sequencers are scenario-agnostic.
2. **`type_id::create` everywhere.** `new` defeats the factory pattern and breaks overrides.
3. **`raise_objection`/`drop_objection` is a counter, not a lock.** Multiple components object; phase ends when count returns to zero.
4. **Forgotten `drop_objection` is the #1 hang bug in UVM.** Always bracket raise with drop in the same task or use `phase_done.set_drain_time`.
5. **Config_db set must precede the get.** In `build_phase`, set before `super.build_phase()` when targeting descendants.
6. **`fork join_none` is the right idiom for background helper sequences on other sequencers.**
7. **Factory override at the test level keeps the env reusable.** Same env, different "personality" per test.
8. **`report_phase` queries the report server for `UVM_ERROR` count — that is the canonical pass/fail signal.** Failure print is itself a `\`uvm_error` so regression scripts see it.
9. **Timeout via `uvm_root::set_timeout` is your safety net.** Without it, hung tests run until the simulator licence expires.
10. **Smoke, regression, stress are not the same.** Different runtime, different coverage, different failure consequences.

### Career-critical

- **`type_id::create` vs `new`** — asked in 60% of UVM interviews. Get it cold.
- **Objection mechanism and the "test hangs" failure mode** — asked in 80% of UVM interviews.
- **Factory override use cases** — asked in 50% of UVM interviews. Have three concrete examples ready.
- **`+UVM_TESTNAME` flow end-to-end** — asked in 90% of UVM interviews. Recite from command line to phase scheduling.
- **Walking through "how would you add a new test"** — asked in nearly every NVIDIA/Qualcomm intern panel.

### What your project does well

- Clean inheritance from `i2c_base_test` with consistent boilerplate.
- Pass/fail logic centralised in base `report_phase` — no duplication across 17 tests.
- `data_nack_test` and `clock_stretch_test` correctly demonstrate the config_db + fork-join_none pattern.
- `arbitration_lost_test` shows a clever multi-master simulation using the slave driver in compete mode.
- `deep_rep_start_test` is explicitly documented as a coverage-closure test — exemplary practice.

### What your project could improve

- **No factory override in any test.** Add at least one error-injection test that overrides the driver subclass — this is interview gold and not currently demonstrated.
- **No per-test timeout configuration.** Stress and addr_sweep tests have very different runtimes from basic_write_test; per-test timeouts would tighten the safety net.
- **`bus_free_test` reaches into `vif` directly from the test.** Cleaner: SVA in the interface or a dedicated bus-state checker in the env.
- **Boilerplate repeats 17 times.** A small macro or templated base could cut this — though for project scope, the verbosity is acceptable.

---

## 13. Action Items — Three New Tests to Add

Each of these is a real engineering deliverable that strengthens the test plan and gives you concrete interview material.

### Action Item 1 — `corner_case_burst_test`

**Goal:** exercise burst-length boundary values: 1, 2, 255, 256 (i.e., min, min+1, max-1, max — assuming an 8-bit burst-length register).

**Why:** Off-by-one errors in burst-length counters are the single most common DV bug class in serial protocols. Your existing `burst_write_test` only tests length 8 — a generic middle value. The corners are unverified.

**Implementation outline:**

```systemverilog
class corner_case_burst_test extends i2c_base_test;
  `uvm_component_utils(corner_case_burst_test)
  function new(string name = "corner_case_burst_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    i2c_burst_write_seq seq;
    int corner_lens[] = '{1, 2, 255, 256};
    phase.raise_objection(this);
    foreach (corner_lens[i]) begin
      seq = i2c_burst_write_seq::type_id::create($sformatf("seq_%0d", i));
      seq.addr = 7'h50;
      seq.burst_len = corner_lens[i];
      seq.start(env.master_agent.sequencer);
      #1000;
    end
    phase.drop_objection(this);
  endtask
endclass
```

**Coverage hook:** add a covergroup with bins `len_1`, `len_2`, `len_max_minus_1`, `len_max`.

**Pass criteria:** all four bursts complete; scoreboard sees byte counts matching `burst_len`; no `UVM_ERROR`.

### Action Item 2 — `error_recovery_test`

**Goal:** inject a protocol error mid-transaction, then verify the master recovers and completes a subsequent clean transaction without manual reset.

**Why:** Real masters need to recover from transient errors automatically. Your project has individual error tests (`addr_nack_test`, `data_nack_test`) but does not verify *recovery to working state*. This is the canonical scenario asked at NVIDIA: "How does your DUT behave after an error?"

**Implementation outline:**

```systemverilog
class error_recovery_test extends i2c_base_test;
  `uvm_component_utils(error_recovery_test)
  function new(string name = "error_recovery_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent", "is_active", UVM_ACTIVE);
    super.build_phase(phase);
  endfunction

  virtual task run_phase(uvm_phase phase);
    i2c_data_nack_seq err_seq;
    i2c_slave_force_nack_seq nack_ctrl;
    i2c_single_write_seq recovery_seq;
    phase.raise_objection(this);

    // Step 1: inject NACK error
    nack_ctrl = i2c_slave_force_nack_seq::type_id::create("nack_ctrl");
    fork nack_ctrl.start(env.slave_agent.sequencer); join_none

    err_seq = i2c_data_nack_seq::type_id::create("err_seq");
    err_seq.addr = 7'h50; err_seq.data = 8'hDE;
    err_seq.start(env.master_agent.sequencer);
    #1000;

    // Step 2: send a clean transaction — must complete successfully
    recovery_seq = i2c_single_write_seq::type_id::create("recovery_seq");
    recovery_seq.addr = 7'h50; recovery_seq.data = 8'h55;
    recovery_seq.start(env.master_agent.sequencer);
    #1000;

    phase.drop_objection(this);
  endtask

  virtual function void report_phase(uvm_phase phase);
    // Override to additionally verify recovery transaction scoreboard saw the second txn.
    super.report_phase(phase);
    // ... scoreboard query for second-txn success ...
  endfunction
endclass
```

**Pass criteria:** First transaction completes with NACK detected (no UVM_ERROR, master logged the error and aborted cleanly). Second transaction completes successfully with byte `8'h55` reaching the slave's data register.

### Action Item 3 — `multi_master_simulation_test`

**Goal:** simulate a true multi-master scenario with two competing masters issuing back-to-back transactions, exercising arbitration and bus-grant fairness.

**Why:** Your existing `arbitration_lost_test` is a one-shot collision. A real multi-master bus has continuous contention. This test exposes any bias in arbitration (master always loses, master never loses), retry-storm behaviour, and bus starvation.

**Implementation outline:**

This is more involved because you need a second master. Options:

**Option A (cheap):** Reuse the slave-driver-in-compete-mode trick from `arbitration_lost_test` but have the slave drive its own master-like sequence repeatedly.

**Option B (clean):** Add a second master agent to the env. This means changing the env — significant work but the right industrial approach.

For Action Item 3, use Option A with this outline:

```systemverilog
class multi_master_simulation_test extends i2c_base_test;
  `uvm_component_utils(multi_master_simulation_test)
  function new(string name = "multi_master_simulation_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent", "is_active", UVM_ACTIVE);
    uvm_config_db#(bit)::set(this, "env.slave_agent.driver", "compete_mode", 1'b1);
    uvm_config_db#(int)::set(this, "env.slave_agent.driver", "compete_period_us", 50);
    super.build_phase(phase);
  endfunction

  virtual task run_phase(uvm_phase phase);
    i2c_random_seq master_seq;
    i2c_competing_master_seq compete_seq;
    phase.raise_objection(this);

    compete_seq = i2c_competing_master_seq::type_id::create("compete_seq");
    compete_seq.num_attempts = 20;
    fork compete_seq.start(env.slave_agent.sequencer); join_none

    master_seq = i2c_random_seq::type_id::create("master_seq");
    master_seq.num_txns = 50;
    master_seq.start(env.master_agent.sequencer);

    #20000;
    phase.drop_objection(this);
  endtask
endclass
```

**Coverage hook:** cross-cover `master_won_arbitration × bit_position_of_collision` to ensure both masters win their fair share across all bit positions.

**Pass criteria:** both masters complete some transactions; no deadlock; no UVM_ERROR from bus state; bus returns idle between contended transactions.

**Stretch:** Option B — fork the env to add a second active master agent. This is a significant refactor but the *right* industrial answer. Worth mentioning to your faculty as a project extension.

---

## 14. Honest Self-Score Template

Score yourself before re-reading the answers. Fill in dates as you re-take this quiz.

| Concept | First pass (2026-05-17) | Re-take +3 days | Re-take +1 week | Re-take +2 weeks |
|---|---|---|---|---|
| `\`uvm_component_utils` role | __ /10 | __ /10 | __ /10 | __ /10 |
| `type_id::create` vs `new` | __ /10 | __ /10 | __ /10 | __ /10 |
| `raise_objection`/`drop_objection` mechanism | __ /10 | __ /10 | __ /10 | __ /10 |
| `+UVM_TESTNAME` end-to-end flow | __ /10 | __ /10 | __ /10 | __ /10 |
| Why drain delay after `start()` | __ /10 | __ /10 | __ /10 | __ /10 |
| `fork join_none` vs `join`/`join_any` | __ /10 | __ /10 | __ /10 | __ /10 |
| Set-before-super in build_phase | __ /10 | __ /10 | __ /10 | __ /10 |
| `report_phase` pass/fail logic | __ /10 | __ /10 | __ /10 | __ /10 |
| Multi-component objection semantics | __ /10 | __ /10 | __ /10 | __ /10 |
| Hang debugging (`+UVM_OBJECTION_TRACE`) | __ /10 | __ /10 | __ /10 | __ /10 |
| Three factory-override use cases | __ /10 | __ /10 | __ /10 | __ /10 |
| Smoke vs regression vs stress definitions | __ /10 | __ /10 | __ /10 | __ /10 |
| Design SDA-fault test | __ /10 | __ /10 | __ /10 | __ /10 |
| Design address-phase arb-loss test | __ /10 | __ /10 | __ /10 | __ /10 |
| Design 100-burst + stretch test | __ /10 | __ /10 | __ /10 | __ /10 |
| Fork in test vs in sequence | __ /10 | __ /10 | __ /10 | __ /10 |
| Adding a new test — file walkthrough | __ /10 | __ /10 | __ /10 | __ /10 |
| **Total** | __ /170 | __ /170 | __ /170 | __ /170 |

**Targets:**
- First pass: 100/170 (you are learning).
- +3 days: 130/170 (concepts solidifying).
- +1 week: 150/170 (interview-ready on this topic).
- +2 weeks: 160/170 (mastery — can teach a peer).

**Reminder for tomorrow:** re-read sections 5 (objections) and 7 (factory override) without looking at the rest of the file. Those are the two highest-yield interview topics in this lesson.

---

## 15. Appendix A — Anatomy of `run_test()`

You call `run_test()` from `top.sv`. Mentally simulate what UVM does next. Knowing the internals separates engineers who *use* UVM from engineers who *understand* it.

### 15.1 The `run_test` source (simplified)

UVM's `uvm_root::run_test()` (simplified to the essentials):

```systemverilog
task uvm_root::run_test(string test_name = "");
  // Step 1: Resolve test name
  if (test_name == "") begin
    if (!$value$plusargs("UVM_TESTNAME=%s", test_name)) begin
      `uvm_warning("RNTST", "No test specified")
      test_name = ""; // fall through to no-test
    end
  end

  // Step 2: Factory lookup
  if (test_name != "") begin
    uvm_component_registry#(uvm_test)::create_component_by_name(
      test_name, "", "uvm_test_top", this);
    // The created test becomes a child of uvm_top
  end

  // Step 3: Run all phases
  m_do_phase_init();
  m_do_phases();    // build, connect, end_of_elaboration, start_of_sim, run, extract, check, report, final
  m_do_phase_done();

  // Step 4: Finish
  if (finish_on_completion)
    $finish;
endtask
```

Three eye-opening details:

1. **`run_test()` takes an optional argument.** You can hardcode `run_test("i2c_base_test")` — but doing so removes the ability to switch tests via plusarg. Best practice: always call `run_test()` with no argument and rely on `+UVM_TESTNAME`.

2. **The created test instance is named `"uvm_test_top"`** (not the class name). All hierarchical paths in the env therefore start with `uvm_test_top.env.master_agent...`. Useful for `config_db` debugging.

3. **`finish_on_completion`** is a `uvm_root` field. Setting it false lets you keep the simulator alive after all phases — useful for interactive post-mortem. Default true.

### 15.2 Plusarg precedence

If both happen:
```
run_test("i2c_base_test");   // hardcoded in top.sv
vsim +UVM_TESTNAME=basic_write_test
```

**The plusarg wins.** UVM checks plusarg first; the argument to `run_test` is only used when plusarg is absent. This is the right precedence — runtime overrides compile-time.

---

## 16. Appendix B — `run_phase` vs Other Run-Time Phases

UVM 1.2 has *twelve* runtime phases, not just `run_phase`. They split run into a refined sequence:

```
pre_reset_phase
reset_phase
post_reset_phase
pre_configure_phase
configure_phase
post_configure_phase
pre_main_phase
main_phase
post_main_phase
pre_shutdown_phase
shutdown_phase
post_shutdown_phase
```

These run **in parallel** with `run_phase`. The split lets different components synchronize via the refined phases without coupling to each other.

### 16.1 Why your project uses only `run_phase`

Pragmatic: for I2C verification at block level, the simpler model is fine. Reset and configure are handled by:
- A short pre-amble in `run_phase` (resetting the DUT, configuring registers).
- The fact that I2C has no startup handshake — the first transaction can begin the moment the bus is idle.

For SoC-level UVM testbenches with dozens of subsystems, the refined phases become essential — different subsystems reset at different times, configure at different times, etc.

### 16.2 When to consider migrating to refined phases

If your project grows to add:
- Multiple agents that need staggered reset.
- A configure step where the test programs CSR registers before any transactions.
- A shutdown step where the test verifies clean idle state.

…then refining into `reset_phase`/`configure_phase`/`main_phase`/`shutdown_phase` is the right call. For your current scope, single `run_phase` is correct.

> **Interview-grade answer:**
> *"UVM 1.2 splits run-time into 12 refined phases — reset, configure, main, shutdown, each with pre and post hooks. They run in parallel with `run_phase` and let multiple components synchronize without direct coupling. Block-level testbenches usually use just `run_phase`; SoC-level testbenches with many subsystems benefit from the refined phases for staggered reset and configure flows."*

---

## 17. Appendix C — Common UVM Test-Level Bugs (and How to Spot Them)

A field guide to the bugs you will see, written by an engineer who has seen them all. Sorted by frequency.

### 17.1 The Hung Test (forgotten `drop_objection`)

**Symptom:** Log shows all expected transactions complete, then nothing for hundreds of microseconds, then `UVM_FATAL` timeout.

**Diagnosis:** `+UVM_OBJECTION_TRACE`. Look for the last raise that has no matching drop.

**Fix:** Add `drop_objection`. Consider using `phase.phase_done.set_drain_time(this, 500ns)` to avoid manual objection management for simple tests.

### 17.2 The Phantom Pass (objection dropped too early)

**Symptom:** Test passes but a known-buggy DUT should have failed. Tell-tale: scoreboard log shows it had pending transactions when the test ended.

**Diagnosis:** Look for `drop_objection` being called *before* the sequence and drain are complete.

**Fix:** Move `drop_objection` to after the drain delay. Use `seq.wait_for_sequence_state(UVM_FINISHED)` if `start()` is non-blocking.

### 17.3 The Configuration That Did Not Take (config_db ordering)

**Symptom:** A `data_nack_test`-style test runs but the slave never NACKs. Slave agent is still passive.

**Diagnosis:** Confirm `uvm_config_db::set` happens before `super.build_phase(phase)`.

**Fix:** Move the set call to the top of `build_phase`. Always.

### 17.4 The Factory Did Not Override (used `new` instead of `type_id::create`)

**Symptom:** Test installs a factory override; override is registered correctly per `factory.print()`; but the env still uses the base type.

**Diagnosis:** Grep for `new` calls inside env/agent/driver code where `type_id::create` should be.

**Fix:** Replace every `new(...)` with `T::type_id::create(...)` for UVM components.

### 17.5 The Wrong-Sequencer Start

**Symptom:** Test runs but the master sequence never produces transactions. Driver waits forever.

**Diagnosis:** Test called `seq.start(env.slave_agent.sequencer)` instead of `env.master_agent.sequencer` — sequence is queued on the wrong sequencer.

**Fix:** Audit the `start()` call. Bonus: add an assertion in the sequence's `pre_body` that checks the sequencer type matches what the sequence expects.

### 17.6 The Race Between `fork` Threads

**Symptom:** Test passes 80% of the time, fails 20%. Different errors each run.

**Diagnosis:** Two forked threads sharing state without synchronization — classic race.

**Fix:** Use `semaphore`, `event`, or `mailbox` for explicit synchronization. Never assume one fork branch finishes before another without an explicit wait.

### 17.7 The Drain That Was Too Short

**Symptom:** Test hangs for the *first* few transactions, looks fine after warm-up.

**Wait, that is not a hang — that is just startup latency.** Real symptom: test passes most runs but fails when the simulator is loaded or when seed is unfavourable.

**Diagnosis:** Drain delay is comparable to typical transaction latency. Under congestion, the last transaction's STOP has not propagated when drop_objection fires.

**Fix:** Increase drain or use `phase_done.set_drain_time` with a generous value.

---

## 18. Appendix D — Test Class Design Patterns by Industry

How the test class is written at different companies, based on patterns visible in their public RTL/DV releases:

| Pattern | Used by | Description |
|---|---|---|
| **Base test + thin derived** | Most companies (your project) | One base test with build_phase, run_phase template, report_phase logic. Derived tests are 15-20 lines each. |
| **Sequence-as-test** | Some Cadence-influenced flows | Test is essentially a wrapper that runs a single named sequence; the sequence carries all scenario knowledge. |
| **Test-configured-via-yaml** | Large SoC teams (Intel, NVIDIA) | Test class reads a YAML/JSON config file at startup, builds the env and selects sequences based on config. One test class supports thousands of scenarios. |
| **Test-as-callback** | Older OVM/UVM 1.0 flows | Test sets callbacks on env/agent for scenario-specific behaviour. Less common in modern UVM 1.2. |

For your career: master the "Base test + thin derived" pattern first (which is what your project uses). The other patterns are variations you can read about when needed.

---

## 19. Appendix E — Command-Line Cheat Sheet

When you run any of the 17 tests, the simulator command looks like one of these:

```bash
# Basic invocation
vsim +UVM_TESTNAME=basic_write_test

# With timeout
vsim +UVM_TESTNAME=full_stress_test +UVM_TIMEOUT=100ms,YES

# With objection trace (debugging a hang)
vsim +UVM_TESTNAME=clock_stretch_test +UVM_OBJECTION_TRACE

# With verbosity tuned
vsim +UVM_TESTNAME=random_directed_test +UVM_VERBOSITY=UVM_HIGH

# Verbosity per-component (only env at HIGH, everything else MEDIUM)
vsim +UVM_TESTNAME=burst_write_test +UVM_VERBOSITY=UVM_MEDIUM \
     +uvm_set_verbosity=uvm_test_top.env,_ALL_,UVM_HIGH,run

# Override seed for reproducibility
vsim +UVM_TESTNAME=random_directed_test -sv_seed 42

# Phase trace (see every phase fire)
vsim +UVM_TESTNAME=basic_write_test +UVM_PHASE_TRACE

# Config DB trace (see every set/get)
vsim +UVM_TESTNAME=data_nack_test +UVM_CONFIG_DB_TRACE
```

Memorise the top three. The rest are for debugging when something goes wrong.

> **Interview trap:** *"How do you debug a UVM test that mysteriously fails on seed 12345 but passes on seed 0?"*
>
> **Interview-grade answer:**
> *"First, run with `-sv_seed 12345` to reproduce. Then add `+UVM_VERBOSITY=UVM_HIGH` and `+UVM_PHASE_TRACE` to see what is different. If it is a race, `+UVM_OBJECTION_TRACE` shows timing of objections. If config differs by seed, `+UVM_CONFIG_DB_TRACE` shows which set/gets happened. Reduce verbosity by component once you have narrowed down the suspect. Finally, capture a waveform and step through the failing transaction in the GUI."*

---

## 20. Appendix F — Mapping Test Categories to Coverage Goals

Each test you wrote serves a coverage purpose. Articulate it before an interview.

| Test | Primary coverage goal | Secondary goal |
|---|---|---|
| `basic_write_test` | `cmd_kind == WRITE` × `addr == 0x50` | First-byte protocol legality |
| `basic_read_test` | `cmd_kind == READ` × `addr == 0x50` | Master ACK/NACK on receive |
| `burst_write_test` | `burst_len == 8` for WRITE | No-STOP between bytes |
| `burst_read_test` | `burst_len == 8` for READ | Master NACK on last byte |
| `write_read_test` | Transition WRITE → READ | Bus state between txns |
| `rep_start_test` | `rep_depth == 1` | Sr without STOP |
| `addr_nack_test` | `master_observes_addr_nack` | Error-path FSM coverage |
| `data_nack_test` | `master_observes_data_nack` | Slave-active driver path |
| `clock_stretch_test` | `slave_stretches_scl` | Master pauses transmit |
| `random_directed_test` | Random coverage of `cmd × addr × data` | Random transition pairs |
| `addr_sweep_test` | All `addr ∈ [0x08, 0x77]` | Reserved-addr rejection |
| `bus_free_test` | `post_stop_bus_idle == 1` | Wire-level invariant |
| `sequential_txn_test` | `back_to_back_transactions > 1` | Idle-state coverage |
| `data_pattern_test` | `data ∈ {0x00, 0xAA, 0x55, 0xFF, walking}` | Stuck-at fault |
| `full_stress_test` | Long-run cross coverage | Queue depth, FIFO |
| `arbitration_lost_test` | `arb_lost == 1` × `bit_position` | Multi-master FSM |
| `deep_rep_start_test` | `rep_depth ∈ {2, 3}` | CG11 closure |

This table is **gold** for an interview. Memorise three rows minimum — pick the ones you understand deepest.

---

## 21. Appendix G — When NOT to Use a Test Class

Yes, there are scenarios where a UVM test class is overkill:

1. **Pure-RTL unit tests (no UVM).** If you are verifying a small combinatorial block with directed Verilog stimulus, a plain `initial` block in the testbench is simpler. UVM has overhead.

2. **Formal verification.** SVA properties verified by JasperGold or VC Formal do not use UVM. The "test" is the property itself.

3. **Quick exploratory tests during DUT bring-up.** When the DUT is fresh and you are not sure what to verify yet, a hand-written sequence of register pokes is faster than spinning up a test class.

4. **Performance benchmarking.** A test class adds simulation overhead. For raw throughput measurement, simpler stimulus is sometimes preferred.

For your I2C project — full UVM-based block-level DV — the test class is the right abstraction. But know the boundary, because interviewers ask "when would you NOT use UVM?" and the right answer is not "never."

---

## Final Word from the Mentor

You are at the **top of the UVM hierarchy** when you write a test class. The discipline you bring here — clean inheritance, configured-not-coded behaviour, factory-aware creation, objection bracketing, explicit pass/fail in `report_phase` — propagates downward through your entire test plan.

Sloppiness at the test class level is exponential. A missing `drop_objection` hangs every regression run. A non-virtual `run_phase` breaks every derived test. A `new` instead of `type_id::create` silently disables every future factory override. A misplaced `super.build_phase()` call breaks every config_db set in the test.

These are not "advanced topics." They are *table stakes* for any UVM-shop engineering interview. Master them now, while you have the code in front of you and the project context fresh in your mind. When you sit across from an NVIDIA panel six months from now, you should be able to:

- Recite the `+UVM_TESTNAME` flow without hesitation.
- Explain three concrete factory-override use cases.
- Diagnose a hung-test scenario from a log snippet in under thirty seconds.
- Walk through "how would you add a new test" enumerating every file touched.
- Name the difference between smoke, regression, and stress with example tests from your own project.

Get this lesson cold. The next time you write a UVM test class — at NVIDIA, at Qualcomm, at Intel, at AMD — you will write it like a senior engineer because you internalised these patterns now.

You have done good work. Keep going.

---

**End of Lesson 17. Next up: Lesson 18 — top-level testbench (`top.sv`) and DUT instantiation — how `run_test()` is invoked and how the clock/reset/vif plumbing comes together.**

