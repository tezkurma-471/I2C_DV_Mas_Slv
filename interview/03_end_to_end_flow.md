# 03 — End-to-End Flow: One Transaction Through Every File

This file answers the single most common interview request: **"walk me
through your testbench."** Read it until you can reproduce the whole journey
on a whiteboard from memory.

---

## 1. The map (draw this first in any interview)

```
                 +--------------------------------------------------+
                 |                    top_tb.sv                      |
                 |  clk/rst gen        i2c_if (sda, scl wires,       |
                 |                     pullups, open-drain drivers)  |
                 |  i2c_slave DUT <======== sda/scl ========> u_sva  |
                 |       |                                  (A1..A9) |
                 |  i2c_slave_if (stretch_en, force_nack, active...) |
                 |  config_db: "i2c_vif", "i2c_slave_vif"  run_test()|
                 +--------------------------------------------------+
                                        |
                          +------------------------------+
                          |   uvm_test (i2c_base_test++)  |
                          |       i2c_env                 |
                          |  +--------------------------+ |
   seq --> sequencer --> driver(BFM) ==> i2c_if pins      | master agent (ACTIVE)
                          |   monitor  <== i2c_if pins    |
                          |  +--------------------------+ |
   ctrl_seq -> sequencer -> slave_driver ==> i2c_slave_if | slave agent (reactive,
                          |   slave_monitor <= slave_if   |  PASSIVE by default)
                          |  +--------------------------+ |
                          |  scoreboard (exp_q / act_q)   |
                          |  coverage (17 covergroups)    |
                          |  v_sequencer (master+slave)   |
                          +------------------------------+

TLM: driver.req_analysis_port  ----------> scoreboard.expected_export
     monitor.item_collected_port --+-----> scoreboard.actual_export
                                   +-----> coverage.analysis_export
```

Second top, same idea, smaller: `top_tb_ral.sv` = master RTL + `i2c_reg_if`
+ cpu agent + RAL model (no slave, no bus agents).

---

## 2. Build & run flow (what happens before time 0)

1. `make sim TEST=write_read_test` → `vlog` compiles in dependency order:
   `i2c_pkg` → RTL → SVA module → interfaces → `i2c_tb_pkg` (which
   `\`include`s every UVM class in order: item → scoreboard → monitor →
   driver → ... → tests) → `top_tb`.
2. `vsim top_tb +UVM_TESTNAME=write_read_test`. At time 0, `top_tb`'s
   initial blocks: put both virtual interfaces into `uvm_config_db` with
   scope `(null, "*")`, then call `run_test()`.
3. `run_test()` reads `+UVM_TESTNAME`, asks the **factory** for that test
   class, and starts the UVM **phase machine**.

**Phases you must narrate confidently:**
- `build_phase` (top-down): test creates env; env creates agents,
  scoreboard, coverage, v_sequencer. **Crucial ordering trick:** tests that
  need the slave agent ACTIVE call
  `uvm_config_db::set(this,"env.slave_agent","is_active",UVM_ACTIVE)`
  *before* `super.build_phase()` — set must precede the get that happens
  inside the env/agent build.
- `connect_phase` (bottom-up): the three TLM connections above, plus
  v_sequencer handle wiring (slave_seqr only if the agent is active).
- `run_phase` (the only time-consuming task phase): test raises an
  **objection**, starts sequences, drops the objection; UVM ends the phase
  when all objections are gone.
- `check_phase`: scoreboard asserts both queues drained.
- `report_phase`: scoreboard verdict line, coverage summary (average of ALL
  17 covergroups vs 90%), base test converts the UVM_ERROR count into
  "TEST PASSED/FAILED".

---

## 3. The hero trace: `write_read_test`, byte 0xA5 to register 0

### Step 1 — Test starts a sequence
`write_read_test.run_phase`: `raise_objection` →
`i2c_write_read_seq.start(env.master_agent.sequencer)`.

### Step 2 — Sequence randomizes intent
`body()` creates an `i2c_seq_item`, `start_item(item)` (arbitration for the
sequencer), `item.randomize() with { addr==0x50; dir==DIR_WRITE; num_data==1;
data[0]==0xA5; start_cond==1; stop_cond==1; }`, `finish_item(item)` — which
blocks until the driver finishes the bus transaction (handshake, see step 4).

### Step 3 — Sequencer→driver handshake
Driver loop: `seq_item_port.get_next_item(req)` pulls the item;
`item_done()` at the end releases `finish_item`. One outstanding item at a
time — that's why the driver can safely write results INTO the same item.

### Step 4 — Driver converts intent to wire activity (BFM)
For our item: `send_start()` (SDA falls under SCL-high after `T_SU_STA`,
holds `T_HD_STA`, then SCL low) → `send_byte(0xA0)` (8 bits MSB-first; per
bit: SCL low, hold `BIT_HOLD`, set SDA, setup `BIT_SETUP`,
`scl_release_wait()` — release SCL and wait for the WIRE to go high
(stretch-aware!), high for `SCL_HIGH_N`) → `wait_for_ack(got)` (release SDA,
9th clock, sample mid-high) → records `item.addr_ack = got`. ACK=1 here →
continue: `send_byte(0xA5)`, `wait_for_ack` → `byte_ack.push_back(1)` →
`send_stop()` (SDA low under SCL low, SCL high first, then SDA rises = STOP,
then `T_BUF`+ idle cycles). Finally
`req_analysis_port.write(item)` → **expected stream**, then `item_done()`.

If the address had been NACK'd: data deleted, STOP sent, item still
published — the scoreboard knows what a NACK-abort must look like (zero data
bytes on the wire).

### Step 5 — Meanwhile, the DUT (slave RTL)
Synchronized SDA/SCL → `start_cond` pulse → FSM SLV_START→SLV_ADDR; shifts 8
bits on SCL rises; at the 8th rise latches `{addr,rw}` and compares to
parameter `SLAVE_ADDR` → `addr_matched=1`; FSM →SLV_ACK at the 8th fall;
drives SDA low **only while SCL is low** (gated), holds it through the 9th
high; `reg_ptr` reset to 0 on SLV_ACK entry. Then SLV_RX: 8 rises shift
0xA5; `latched_rx_byte` captured at rise 8 (so the ACK bit can't corrupt
data); SLV_RX_ACK commits `internal_regs[0] <= 0xA5` exactly once
(`rx_write_done` one-shot), increments `reg_ptr`, drives ACK. STOP event →
FSM →SLV_IDLE, `active` falls.

### Step 6 — Meanwhile, the monitor (independent witness)
Sampling every clk: sees the same START event (its own edge detectors),
shifts the same bits off the wire, records `addr=0x50, dir=WRITE,
addr_ack=1`, pushes data byte 0xA5 + `byte_ack=1`, and at the STOP event
finalizes → `item_collected_port.write(mon_item)` → **actual stream** (and
the same object fans out to coverage — analysis ports support N subscribers).

### Step 7 — Scoreboard: the verdict machinery
`write_expected` and `write_actual` each push into their queue and call
`try_match()`; when both queues are non-empty, `compare_pair(exp, act)`:
addr==addr, dir==dir, addr_ack consistent (driver-sampled vs
monitor-observed), payload sizes equal, **bytes equal** (intent vs wire —
this is the check that was dead before the audit), and since
`addr==0x50 && addr_ack`: WRITE → shadow update `ref_reg_bank[0]=0xA5` (from
the MONITOR's bytes, i.e., the wire).

### Step 8 — The read-back closes the loop
Second item: `dir==DIR_READ, num_data==1`. Driver sends START + 0xA1, gets
ACK, `receive_byte()` (releases SDA; slave's `tx_shift_reg` — loaded from
`internal_regs[reg_ptr=0]` at address ACK — drives 0xA5 bit by bit under
SCL-low gating; driver samples each bit mid-high) → driver writes the byte
back into `item.data[0]`, sends **NACK** (last byte), STOP. Monitor captures
the same byte. Scoreboard pair-checks driver-captured vs monitor-observed,
then monitor-observed vs `ref_reg_bank[0]` → 0xA5 === 0xA5 === 0xA5. If the
DUT had stored a corrupted byte, the wire would show it, and the
shadow-compare goes red.

### Step 9 — All the while, the SVA module
`u_sva` watches the raw wires through its own 2-stage sampling pipeline:
START/STOP windows, SDA stability under SCL-high (A3), ACK slot driven (A4),
hold/setup at every SCL edge (A8/A9), full `T_BUF` quiet window after the
STOP (A7). Any violation → `uvm_report_error` → counted → test FAILS, even
if the scoreboard was happy. Two judges, different jurisdictions: scoreboard
judges *data*, SVA judges *timing/protocol shape*.

### Step 10 — End of test
Objection dropped → `check_phase` (queues empty?) → `report_phase`
(SCOREBOARD PASSED + coverage summary + TEST PASSED) → regression script
double-checks the log has no real `UVM_ERROR` line before declaring PASS.

---

## 4. Variations on the hero trace (know how each differs)

| Test | What changes in the flow |
|---|---|
| `rep_start_test` / `deep_rep_start_test` | Items chain: `{start, no stop}` then `{rep_start, stop}`. Driver's `send_rep_start()` raises SCL (stretch-aware), then drops SDA under SCL-high. Monitor finalizes the current item at the Sr and starts a new one with `rep_start=1`, tracking chain depth for CG11. |
| `addr_nack_test` | Address 0x55 → slave silent → `wait_for_ack` returns 0 → driver aborts with STOP, deletes payload. Scoreboard: NACK'd address must show ZERO data bytes; only 0x50 may ever ACK. |
| `data_nack_test` | Slave agent ACTIVE; ctrl item sets `force_data_nack` (driver applies to `i2c_slave_if`, waits active 1→0, clears). Master sees byte-0 NACK → trims item to 1 byte. Counts and bytes still match end-to-end. |
| `clock_stretch_test` / `stretch_read_test` | Ctrl item arms `stretch_en` (RTL latches it as `stretch_pending`, fires at address ACK, holds SCL low N cycles). BFM's `scl_release_wait` genuinely waits. T15 runs the **virtual sequence**: forked ctrl leg + write leg, re-arm, read leg — closing stretch×READ coverage. |
| `arbitration_lost_test` | Slave driver in compete mode pulls `sda_drv_x` low at bit 3; wired-AND corrupts the wire **by design**, so the test sets `allow_bus_corruption` on the scoreboard via config_db. |
| `full_stress_test` / `random_directed_test` | 100/50 items, ~25% as Sr chains (`do_rep_chain`), rest fully randomized under the item constraints. |
| RAL tests | Different top. Sequence calls `reg_model.CTRL.read(...)` → adapter `reg2bus` makes an `i2c_cpu_seq_item` → cpu driver wiggles `cpu_addr/cpu_wr/cpu_wdata` through the clocking block, samples `cpu_rdata` → `bus2reg` (now with `rw.addr`) returns data → RAL compares against the mirror. Reset values, WO-CMD readback, field-level RMW. |

---

## 5. The five UVM mechanics you must explain without hesitation

1. **config_db** — typed (type is part of the key!), scope string + field
   name; `set` before the consumer's `get` (build order matters); used here
   for: virtual interfaces from top, `is_active` from tests, compete-mode
   knobs, `allow_bus_corruption`. The RAL bench's old bug — handle typed
   `virtual i2c_reg_if.drv_mp` vs db typed `virtual i2c_reg_if` — is the
   canonical "type is part of the key" war story.
2. **Factory** — `type_id::create()` everywhere so tests can override
   components/items without editing the env; `+UVM_TESTNAME` itself is a
   factory lookup.
3. **TLM analysis ports** — 1-to-N broadcast `write()` function calls;
   monitor feeds scoreboard AND coverage; `uvm_analysis_imp_decl(_expected)`
   gives one component two differently-named `write_*` imps.
4. **Sequencer/driver handshake** — `start_item/finish_item` ↔
   `get_next_item/item_done`; `finish_item` blocking until `item_done` is
   what lets the driver return data inside the request item. (And the slave
   driver deliberately delays `item_done` until the transaction completes —
   which is exactly why the old vseq's inline `finish_item` deadlocked.)
5. **Objections** — phase ends when the count hits zero; tests raise before
   starting sequences, drop after a small drain delay.

---

## 6. The independent evidence layer (say this unprompted)

`make smoke` — `tb/tb_rtl_smoke.sv`, pure SV on Icarus: RTL master and RTL
slave on real pulled-up wires; CPU-model tasks program the master register
interface (poll-after-settle!) and check: 4-byte burst write with **SCL held
low between bytes** and `active` never dropping (the implicit-STOP
regression trap), 4-byte read-back equality, address-NACK auto-STOP,
mid-byte clock stretch with no timeout, a write-write-Sr-read-read chain,
and (T6, added after the Riviera shakedown) a stretch armed *before* START
so it fires exactly at the address ACK — pinning the SLV_STRETCH ACK-release
bug locally. 33 checks, all green, no license. It exists because the UVM
bench *deliberately* excludes the master RTL — and it caught three real
master bugs within an hour of existing, then served as the local repro rig
for the stretch-ACK bug the commercial-simulator run exposed.
