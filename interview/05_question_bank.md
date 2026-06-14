# 05 — Interview Question Bank (with answers)

~125 questions across eight sections (Section H — the 2026-06-12 Riviera
shakedown — is the freshest and most differentiating material). Practice OUT
LOUD. Mark every question
you stumble on and re-drill it. Questions marked ★ are ones this specific
project makes you unusually well-equipped to answer — steer interviews
toward them.

---

## Section A — I2C Protocol (asked first, almost always)

**A1. Why is I2C open-drain?**
So any device can safely assert the bus (pull low) without drive fights —
two pushes-pull drivers shorting 1-against-0 would burn current and give
undefined logic. Wired-AND also *enables* the protocol's cleverest features:
arbitration (0 wins, losers detect it) and clock stretching (slowest device
wins SCL) come free from the electrical layer.

**A2. Define START, STOP, repeated START.**
START: SDA falls while SCL high. STOP: SDA rises while SCL high. Sr: a new
START issued without an intervening STOP — keeps bus ownership between two
transfers (classic: write register pointer, Sr, read data — atomic against
other masters).

**A3. Why must SDA be stable while SCL is high?**
Because an SDA edge under SCL-high *is defined as* START or STOP. Data
toggling there would forge bus events. Hence: data changes only under
SCL-low; receivers sample on SCL-high.

**A4. Walk me through one complete write byte on the wire.**
START → 8 data bits MSB-first (each: SDA set under SCL-low, master raises
SCL, receiver samples, SCL falls) → 9th clock: transmitter releases SDA,
receiver pulls low (ACK) or leaves high (NACK) → next byte or STOP.

**A5. Who drives what during a read from a slave?**
Master: SCL always (subject to stretching), plus ACK/NACK after each
received byte. Slave: data bits. The master NACKs the LAST byte to tell the
slave to stop driving, then issues STOP. ★Trap: that NACK is protocol, not
an error — my scoreboard and monitor treat master-NACK-on-last-read-byte as
normal.

**A6. What is clock stretching and how does a master support it correctly?**
A slave holds SCL low to pause the master. The master must, after RELEASING
SCL, verify the wire actually went high before timing the high phase —
released ≠ high under wired-AND. ★In my project the BFM does
`scl_release_wait()` with a MAX_CLK_STRETCH bound, and the RTL master
freezes its bit timer whenever `scl_o==1 && scl_i==0`.

**A7. Explain multi-master arbitration.**
Masters transmit and simultaneously monitor SDA. If you release (transmit 1)
but read 0, another master drove 0 and owns the bit — you lost: stop driving
immediately and do NOT generate STOP (the winner's transfer is live).
Arbitration is non-destructive; the winning data is unharmed. ★My
arbitration test injects a competing pull-down at bit 3 via a second
open-drain hook in the interface.

**A8. What happens if arbitration is lost during the ACK bit, or two masters
send identical bytes?**
Identical bits → no one loses yet; arbitration can extend across the whole
address+data until a difference appears. If totally identical, both
"win" harmlessly (same transaction). Loss can occur on any bit including
ACK — the loser backs off and retries after the bus frees.

**A9. Reserved addresses?**
`0000_XXX` (general call 0x00, START byte 0x01, CBUS...) and `1111_XXX`
(10-bit prefix `11110xx`, device ID). 112 usable 7-bit addresses. ★My
`valid_addr_c` constraint excludes both ranges; the sweep test walks
0x08–0x77.

**A10. 7-bit vs 10-bit addressing — how does 10-bit work?**
First byte `11110_A9_A8_RW` (a reserved-prefix pattern), second byte =
A7..A0. All 7-bit slaves see a reserved prefix and stay silent. Not
implemented in my DUT — I say that plainly and explain the mechanism.

**A11. What are the standard speed modes?**
100k (standard), 400k (fast), 1M (fast+), 3.4M (high-speed, with
current-source assist and master code preamble), 5M (ultra-fast, push-pull,
write-only — abandons wired-AND). Mine is standard-mode timing,
parameterized.

**A12. Key timing parameters and what enforces them in your bench?** ★
t_SU;STA / t_HD;STA (Sr/START windows — BFM waits, SVA A1), t_SU;DAT (250 ns
— A9), t_HD;DAT (min 0! — A8 as a structural 2-cycle check), t_BUF (bus
free STOP→START — BFM waits T_BUF, A7 checks the FULL window). Knowing
t_HD;DAT=0 and what it did to my A8 is a differentiator — tell that story.

**A13. How does I2C differ from SPI / UART?**
I2C: 2 wires, addressed multi-drop, ACK-based, multi-master, slower, half
duplex. SPI: 4+ wires, chip-selects, full duplex, much faster, no ACK or
multi-master standard. UART: asynchronous (no clock), point-to-point,
framing via start/stop bits. Pick I2C for many slow peripherals on minimal
pins; SPI for speed; UART for simple point-to-point.

**A14. SMBus vs I2C?**
SMBus adds: SCL-low timeout (~35 ms — bus can't hang forever), fixed voltage
/current specs, optional packet error check (CRC-8), alert response address.
I2C allows indefinite stretching — my MAX_CLK_STRETCH bound is the SMBus
philosophy applied to an I2C bench.

**A15. A slave NACKs a data byte mid-write. What must the master do, and
what does YOUR design do?** ★
Per spec the transfer ends: master issues STOP (or Sr). My BFM stops sending
remaining bytes, trims the transaction item to bytes actually driven (so the
scoreboard's expected stream matches the wire), and STOPs. Design note I
volunteer: my slave still *stores* the NACK'd byte — NACK and storage are
independent in this DUT; the reference model matches the DUT, and I can
argue both interpretations.

**A16. How do you recover a stuck I2C bus (slave holding SDA low)?**
Clock out up to 9 SCL pulses until the slave releases SDA mid-shift, then
generate STOP. Mention bus-clear as a thing real masters implement; mine
doesn't (honest scope statement).

**A17. Why does the slave see events 2 cycles late in your design, and does
it matter?** ★
SDA/SCL are async to the slave's 50 MHz clock → 2-flop synchronizers before
all edge detection (metastability containment). 2 clk = 40 ns, negligible
against multi-microsecond bit times; what DOES matter is internal
consistency — any compare of own-drive vs synced-input needs matched delays
(my arb-loss fix).

**A18. Draw the waveform for: write 1 byte then repeated-START read 1 byte.**
(Practice on paper: S, 0xA0, A, D, A, Sr, 0xA1, A, D(slave), NACK(master), P.
Narrate who drives SDA in every segment — that's what they're checking.)

---

## Section B — SystemVerilog (language depth)

**B1. Blocking vs non-blocking; why NBA in sequential logic?**
`=` executes immediately in statement order; `<=` schedules updates at the
end of the time slot (NBA region) so all clocked blocks see pre-edge values
— matching real flip-flops. Mixing them wrongly creates simulation/synthesis
mismatch and race conditions.

**B2. ★Your audit rejected a "bug" using NBA semantics. Explain.**
The claim: address latch `rx_addr <= shift_reg[6:0]` at the 8th SCL rise
reads stale data because the shift register updates "at the same time."
Truth: both are NBA in the same time slot, so the latch reads the OLD
shift_reg — which after 7 prior shifts holds exactly the 7 address bits,
while the R/W bit is on SDA right now. The code is correct BECAUSE of NBA
ordering. Reviewers who don't reason in scheduling regions cry wolf.

**B3. SV scheduling regions, briefly.**
Preponed (sampling for assertions/clocking blocks) → Active (blocking
assigns, evaluation) → Inactive (#0) → NBA (nonblocking updates) →
Observed (property evaluation) → Reactive (program/testbench) → Postponed
($strobe/$monitor). Knowing that SVA sampling is PREponed explains why
assertions see pre-edge values.

**B4. Is a testbench read of a DUT NBA-driven signal at @(posedge clk) a
race?** ★
No — it's deterministic: the read happens in Active, the NBA update later in
the same slot, so the reader consistently sees the previous-cycle value.
One-cycle-late ≠ nondeterministic. (Audit finding I downgraded.) Clocking
blocks are still the cleaner discipline because they make the intent
explicit and add skews.

**B5. What do clocking blocks actually do?**
Bundle signals with a clock and sampling/driving skews: inputs sampled
`#1step` before the edge (settled values), outputs driven with output skew
after the edge. They eliminate TB↔DUT races by construction and document
direction. My RAL cpu driver uses one; the bus BFM drives proxy signals
directly (deterministic here, and noted as a conscious choice).

**B6. `logic` vs `wire`; when must you use a net?**
`logic` = 4-state variable, single driver semantics. Multiple drivers (buses,
tri-state, wired-AND) require nets with resolution — my SDA/SCL are `wire`
with strength-resolved drivers; using `logic` there couldn't even represent
contention.

**B7. Drive strengths — explain `(strong0, weak1)` and the pullup idiom.** ★
Each driver contributes a strength per level; the net resolves strongest.
`assign (strong0, weak1) sda = cond ? 1'b0 : 1'bz;` = a strong pull-down or
release; `assign (weak1, highz0) sda = 1'b1;` = a resistor-like weak high.
strong0 beats weak1 → ACK wins over pull-up: silicon-accurate wired-AND.

**B8. 2-state vs 4-state types; why is the seq item payload `bit [7:0]`?**
`bit/int` are 2-state (no X/Z), `logic` 4-state. Randomizing 4-state fields
can produce X that poisons comparisons; payloads use `bit` so stimulus is
always 0/1, while wire-facing code stays 4-state to SEE X/Z problems
(`$isunknown` checks in scoreboard and A6).

**B9. Queues vs dynamic arrays vs associative arrays.**
Queue `[$]`: ordered, cheap push/pop both ends — my scoreboard pending
lists and payload. Dynamic array: fixed-at-allocation size. Associative:
sparse keyed storage (great for address-indexed memories). Know the
methods: `push_back/pop_front/size/delete`, slicing `q[0:i]` (used to trim
NACK-aborted payloads).

**B10. `rand` vs `randc`; what does `randomize() with {}` do?**
`rand` uniform over constrained space each call; `randc` cycles through all
values before repeating (exhaustion semantics, costlier). `with {}` adds
inline constraints solved together with class constraints. `local::x` in an
inline constraint refers to the sequence's variable, not the item's field —
used throughout my sequences.

**B11. What is constraint solve order? `solve a before b`?**
All constraints are solved simultaneously (declarative). `solve a before b`
biases *distribution* (pick a first, then b given a) without changing the
legal solution set. Distribution control, not legality control.

**B12. ★Tell me a real over-constraint bug.**
`default_trans_c` pinned `start=1/stop=1/rep=0` — convenient for directed
sequences, but it silently removed repeated-START from the entire random
space: 1000 stress items, zero Sr, no solver error (solver did what it was
told). Found by auditing constraints against coverage bins; fixed with
explicit Sr-chain generation and `constraint_mode(0)` per-item.

**B13. `constraint_mode()` / `rand_mode()`?**
Per-object switches: disable a named constraint block (my Sr chains disable
`default_trans_c` per item) or freeze a rand variable. Surgical, reversible,
visible at the call site.

**B14. Why check `randomize()`'s return value?**
It returns 0 on contradiction instead of erroring; ignoring it means driving
stale/garbage values silently. House style here: `if (!item.randomize()
with{...}) \`uvm_fatal/\`uvm_error`.

**B15. `function automatic` vs static?**
Static functions share one activation record (state persists/aliases across
calls — dangerous with recursion or concurrent callers); `automatic` gets
fresh locals per call. Package helper functions here are automatic.

**B16. What is `$isunknown` and where do you use it?**
True if any bit is X/Z. Scoreboard guards payloads; A4/A6 guard the bus.
X-checks are cheap and catch contention/floating bugs that value-compares
miss.

**B17. Explain `fork...join`, `join_any`, `join_none`, and `wait fork`.** ★
join: wait all; join_any: first; join_none: spawn and continue. `wait fork`
blocks until ALL children of the current process finish — my rewritten vseq
forks slave-ctrl legs with join_none and `wait fork`s at the end. Know
`disable fork` kills children (and its scope dangers).

**B18. Casting: static `'()` vs dynamic `$cast`.**
Static for known-safe conversions (enum↔bits, size). `$cast` for
downcasting class handles — returns 0 on failure; always check it
(scoreboard `do_copy`, adapter `bus2reg`).

**B19. Why include-guards (`\`ifndef/\`define`) in every file?**
Files are `\`include`d into packages; double-inclusion would redefine
classes. Guards make inclusion idempotent. (Also why my playground flattener
can simply concatenate files.)

**B20. Packed vs unpacked arrays?**
Packed = contiguous vector, sliceable/assignable as bits
(`logic [7:0] x`); unpacked = collection of elements
(`logic [7:0] mem [0:7]` — my register bank, also a port type, which some
tools are picky about).

**B21. What's a virtual interface, and the classic failure mode?** ★
A class-domain handle to an instance of an interface — the bridge from
dynamic UVM objects to static HDL. Failure mode: config_db type mismatch —
`virtual i2c_reg_if.drv_mp` (modport-typed) is a DIFFERENT type from
`virtual i2c_reg_if`; the get fails and you fatal at build. I fixed exactly
this in the RAL driver: type is part of the config_db key.

**B22. Parameterized localparams and width pitfalls.**
Comparing a 9-bit counter to a 32-bit `int` parameter triggers width
warnings and subtle truncation bugs; I sized comparison constants
(`localparam logic [TIMER_W-1:0] TIMER_LAST = TIMER_W'(T_SCL_PERIOD-1);`)
to keep Verilator -Wall clean.

**B23. What's a one-shot/strobe and why did `rx_data_valid` need to become
one?** ★
Level vs event: the old `rx_data_valid` stayed high for the whole multi-cycle
ACK state (~hundreds of cycles) — a consumer FIFO would push the same byte
hundreds of times. Now it pulses exactly on the cycle the byte commits.
Outputs that mean "event happened" must be strobes.

**B24. CDC: why two flops? Why might you also delay your own outputs?** ★
Two flops give the metastable first stage a full cycle to resolve;
probability of escape drops exponentially. And if you compare an input that
is now 2 cycles late against your own zero-delay output, you create false
mismatches — my arbitration bug. Matched delays on both compare operands.

**B25. Glitches on combinational signals — when do they matter?**
Only when consumed asynchronously (clocks, async resets, latch enables).
A combinational `timer_clr = (state != next_state)` consumed by synchronous
logic is safe — glitches settle before the edge if timing is met. I kept it
and documented why (an audit reviewer wanted it registered; I pushed back
with reasoning).

---

## Section C — UVM (methodology depth)

**C1. Why UVM at all?**
Reuse and scale: standardized component roles (driver/monitor/agent/env),
factory-based extensibility (override without editing), phase orchestration,
TLM decoupling, config_db plumbing, sequence layering. One env, 19 tests —
each test is just policy.

**C2. uvm_component vs uvm_object?**
Components are structural: live in the hierarchy, get phases, exist all
simulation (driver, monitor, env, test). Objects are data: created/destroyed
freely (transactions, sequences). Sequence = object that *runs on* a
component (sequencer).

**C3. List the main phases and what you do in each.** ★
build (top-down: create children, config_db sets/gets), connect (TLM/port
wiring, handle assignment), end_of_elaboration, start_of_simulation, run
(task; all stimulus — objections control its end), then extract/check
(scoreboard queue-drain asserts), report (verdicts/coverage summary), final.

**C4. Why must config_db::set for `is_active` happen before
`super.build_phase()` in the test?** ★
The env's build (triggered inside super.build_phase) creates the slave agent
which reads `is_active` during ITS build. set-after would be read-never. My
data_nack/clock_stretch/arb/stretch_read tests all do set-then-super.

**C5. How does the factory work and what does `type_id::create` buy you?**
Registration macros put the class in a global registry; `create` looks up
the (possibly overridden) constructor. Tests can `set_type_override` to swap
a driver for an error-injecting subclass with zero env edits. Direct `new()`
forfeits all of that.

**C6. Analysis port vs blocking put port vs TLM FIFO?**
Analysis = 1-to-N nonblocking broadcast `write()` for observers (monitor →
scoreboard+coverage). put/get = 1-to-1 with backpressure. analysis_imp with
`uvm_analysis_imp_decl(_suffix)` gives one component multiple named write
methods — my scoreboard's `write_expected`/`write_actual`.

**C7. Explain the sequencer-driver handshake fully.** ★
Sequence: `start_item` (waits for grant) → randomize → `finish_item` (sends,
BLOCKS until driver's `item_done`). Driver: `get_next_item` (blocks for
item) → drive pins → optionally fill response INTO the req handle →
`item_done`. Because finish_item blocks, the sequence can read back results
from its own item (my read data + ACK results). The slave-ctrl driver delays
item_done until the bus transaction ends — that semantic is exactly why the
old vseq's inline finish_item deadlocked.

**C8. What is a virtual sequence/sequencer and why use one?** ★
A sequence that owns no item type but coordinates sub-sequences on multiple
real sequencers via `p_sequencer` handles — cross-agent choreography. Mine
synchronizes slave stretch-arming with master traffic (fork ctrl leg, run
traffic, wait fork) — and carries a null-guard on slave_seqr since the slave
agent is passive by default.

**C9. Objections — mechanics and common bugs.**
run_phase ends when the objection count reaches zero. Bugs: dropping before
forked work completes (my old data_nack fork race), never dropping (hang
until watchdog), relying on drain delays instead of completion events.

**C10. Active vs passive agents; why is your slave agent "reactive"?**
Active = sequencer+driver+monitor (drives); passive = monitor only. My slave
agent is passive by default (the DUT *is* the slave); tests that inject
errors flip it active so its driver can wiggle backdoor controls
(stretch_en, force_data_nack) — it reacts to the DUT's `active` signal,
hence "reactive."

**C11. How would you make this env reusable at SoC level?**
Agents/items/sequences are the reusable unit: instantiate the master agent
passive on a real SoC bus to monitor+check; keep scoreboard reference model;
retarget vifs via config_db. The block-level tests stay as the regression
floor.

**C12. RAL: why bother, and what are the pieces?** ★
Register tests stop being magic-number pokes: a `uvm_reg_block` mirrors the
spec (offsets, fields, access policies, reset values); adapter translates
`uvm_reg_bus_op` ↔ bus items; frontdoor accesses go through the real bus;
`mirror/update/set/get` give RMW without read-modify-write bugs. Mine checks
reset values, WO-CMD read-as-zero, and field-level RMW isolation.

**C13. provides_responses in an adapter?**
Tells RAL the driver returns a response item (read data) and to wait for it
before completing the op. Mine sets it; the cpu driver fills `cpu_rdata`
into the item. Also: `bus2reg` must populate `rw.addr` — explicit predictors
rely on it (audit fix).

**C14. Backdoor vs frontdoor access?**
Frontdoor = through the bus (timing-accurate, exercises decode logic);
backdoor = hierarchical poke/peek (fast, no bus). Best practice: frontdoor
writes + backdoor cross-checks. Mine is frontdoor-only and I say so.

**C15. uvm_config_db vs uvm_resource_db; config_db precedence?**
config_db is the hierarchical wrapper over resource_db. Precedence: deeper
`set`s from higher components win (parent over child), last-set among
equals. Wildcards (`"*"`) from the top are the standard vif pattern.

**C16. `uvm_error` vs `uvm_fatal` vs `uvm_warning` — your policy?** ★
fatal: cannot proceed meaningfully (missing vif, cast failure). error:
checker found a DUT/bench violation — counted, test fails, sim continues to
gather more evidence. warning: suspicious but legal. Audit postscript: a
`$error` is NONE of these — it bypasses UVM accounting entirely; never use
it in a UVM bench.

**C17. How do you end a test cleanly with forked stimulus?**
Own every thread: fork with join_none only when something later waits
(wait fork / explicit event), keep drain time for in-flight bus activity,
and let check_phase catch anything that leaked (my queue-leftover checks).

**C18. What's `p_sequencer` vs `m_sequencer`?**
m_sequencer: generic handle every sequence has. p_sequencer: typed alias
created by `\`uvm_declare_p_sequencer` — needed to reach custom fields like
my virtual sequencer's master_seqr/slave_seqr.

**C19. do_copy/do_compare/convert2string — why implement them?**
Field-by-field deep copy (queues!), meaningful equality, and debuggable
printing. My item copies `data[$]` and `byte_ack[$]` explicitly — default
shallow behavior is a classic source of aliased-queue bugs.

**C20. How does +UVM_TESTNAME work?**
run_test() reads the plusarg and asks the factory for that registered test
type — string-to-class via the registry. No recompile between tests; that's
why the regression is just a shell loop over names.

**C21. Drain time / phase ready_to_end alternatives?**
My tests use small #delays post-sequence (simple, fine at this scale).
Cleaner at scale: `phase.phase_done.set_drain_time()` or overriding
`phase_ready_to_end` to hold the phase while monitors are mid-transaction.
Know both; admit mine is the simple form.

**C22. If two analysis writes arrive in the same timestep, is order
guaranteed?** ★
No — and my scoreboard is explicitly arrival-order independent (queues +
match-when-both-present) for exactly that reason. Never encode cross-port
ordering assumptions you don't own.

---

## Section D — Assertions (SVA)

**D1. Immediate vs concurrent assertions?**
Immediate: procedural, checked when executed. Concurrent: clocked temporal
properties (`assert property`) sampled in the Preponed region — they see
pre-edge values, which is why my SVA module keeps its own 2-stage sampled
copies for edge detection.

**D2. Implication |-> vs |=>; what is vacuous success?** ★
`|->` same-cycle consequent start; `|=>` next cycle. If the antecedent never
matches, the property passes VACUOUSLY — dashboards show green for a check
that never engaged. My A3's antecedent (in_data_phase, SCL high, not
START/STOP window) is itself covered by traffic, and I deleted A2 precisely
because it was effectively vacuous (existential `##[1:T_BUF]` window).

**D3. ##[m:n], [*n], [->n] — differences?**
`##[m:n]`: delay range (existential — ANY one alignment satisfying suffices).
`[*n]`: consecutive repetition (universal across the window). `[->n]`:
goto — n occurrences, possibly non-consecutive, ending at the last. A2 vs A7
is exactly existential-vs-universal: "high at some cycle" (useless) vs "high
for ALL T_BUF cycles" (the spec).

**D4. $rose/$fell/$stable/$past — and their sampling subtlety.**
All operate on PREPONED-sampled values. `$stable(x)` compares this cycle's
sample to last cycle's. ★A8's off-by-one: `scl_fall |-> $stable(sda)[*N]`
starts checking ON the trigger cycle where stability is structurally
guaranteed — you must `##1` to check the cycles that matter.

**D5. disable iff — what and why?**
Aborts in-flight property threads when the condition is true (reset).
All my properties `disable iff (!rst_n)` so reset transitions don't generate
garbage failures.

**D6. How do you keep an assertion from exploding into thousands of
threads?**
Avoid wide `##[0:big]` windows on frequent antecedents; precompute helper
state in RTL-style always blocks. My A5 uses a counter + simple compare
instead of a 1000-cycle sequence — same check, one thread.

**D7. ★Tell me about an assertion that was WRONG rather than the design.**
A8 demanded `T_HD_DAT=5` hold after SCL falls. UM10204's t_HD;DAT minimum is
0, and my slave legally changes SDA ~3 cycles after the fall (synchronizer +
gated update). The assertion punished a compliant design. Rewrote it as a
structural 2-cycle check (catches same-edge movement — the actually
dangerous case) — assertions must encode the SPEC, not the author's margin
preferences.

**D8. Where should assertion failures go in a UVM bench?**
Through the UVM report server (`uvm_report_error` or \`uvm_error in bound
checkers) so they're counted in the verdict. `$error`/`$fatal` bypass UVM
accounting — my audit's highest-impact finding.

**D9. bind vs direct instantiation of checker modules?**
`bind` injects a checker into a design scope without editing design source —
ideal for IP you don't own. Mine is directly instantiated in top_tb (I own
the bench top); same effect here, and I can explain when bind is required.

**D10. What's an assertion coverage strategy?**
Track `cover property` of the antecedents (did the check ever engage?) plus
assert pass/fail. A never-triggered assertion is a coverage hole disguised
as safety. (This is the formal-friendly answer; my bench approximates it by
ensuring stimulus exists for every assertion's trigger.)

**D11. Could these properties run under formal?**
A3/A7/A8/A9 are formal-friendly (bounded, no testbench state). The
bit-counter helper would become assume/model code. Next-step plan: SymbiYosys
on the slave's START/STOP detector and FSM deadlock-freedom — I name this as
known future work.

**D12. Why does your SVA module keep its own sda_samp/scl_samp pipeline?**
Clean glitch-filtered edge semantics independent of DUT internals, identical
sampling for all properties, and alignment margin baked into the BFM timing
budget (BIT_HOLD/SETUP include +3 for this pipeline).

---

## Section E — Coverage & closure

**E1. Code vs functional coverage?**
Code (line/branch/toggle/FSM): free, measures what executed — can be 100%
while behavior is unverified. Functional: hand-written model of WHAT MATTERS
(my 17 covergroups). You need both; functional defines done.

**E2. covergroup/coverpoint/bins/cross — quick anatomy.**
Covergroup = sampling container (mine sample in the subscriber's `write()`);
coverpoint buckets a variable into bins; cross multiplies coverpoints
(stretch×dir, rep×dir, dir×size...). `ignore_bins`/`illegal_bins` prune
impossible space — know the difference (ignore = excluded; illegal = error
if hit).

**E3. ★Tell me about a structurally unhittable bin you found.**
`has_stretch × DIR_READ`: the only stretch stimulus was a write-only
directed test, so the cross could never close — while the README claimed
100% coverage. Fixed with stretch_read_test (virtual sequence: stretch
during a read). Lesson: every cross needs a named test that can hit it.

**E4. ★Your coverage summary averaged 4 of 17 groups. Why is that bad and
what's right?**
The 90% warning threshold consulted only 4 covergroups — holes in the other
13 could never trip it: a dashboard designed to look green. Fix: average
ALL groups (and in real flows, weight + per-group goals via
`option.goal`/UCDB reports rather than a hand average).

**E5. When do you STOP verifying?**
When the vplan's coverage model is closed across the regression (merged,
multi-seed), assertions are clean, no open bugs, and remaining holes have
signed-off waivers with reasons. Coverage closure is evidence the STIMULUS
visited the space — the checkers are what make visits meaningful (my audit
in one sentence).

**E6. Sample-time bugs — where can coverage lie?**
Sampling intent instead of outcome (sampling the sequence's field rather
than the monitor's reconstruction), sampling before results are known
(byte_ack before ACK phase), conditional sample guards that exclude the
interesting case. Mine samples monitor-reconstructed items only.

**E7. How do seeds factor into closure?**
Constrained-random needs multiple seeds to explore the space (my regress: 3
seeds × 19 tests); coverage is merged across all runs. One-seed "closure" is
luck, not closure.

**E8. What's mutation testing / "verifying the verification"?** ★
Deliberately inject design bugs and confirm the suite goes red — testing the
testbench's discrimination power. My audit was the static version (tracing
kill-chains, finding the dead write-compare); planned next step is literal
mutation runs.

**E9. Toggle/FSM coverage on the RTL — anything interesting here?**
FSM coverage would have flagged SLV_STOP as unreachable (dead state removed
in the audit) — a nice example of code coverage catching dead DESIGN, while
functional coverage catches missing STIMULUS.

**E10. If coverage is at 96% the night before tapeout, what do you do?**
Triage the missing 4%: unhittable (waive with proof), hittable-but-unwritten
(write the directed test now — like my stretch_read_test), or
hittable-but-improbable (seed sweep / constraint bias). Never silently ship
the number.

---

## Section F — Project grilling (they WILL push here)

**F1. "Walk me through what happens when a test runs."**
(Deliver file 03's hero trace. Practice until 4 minutes flat.)

**F2. "How do you KNOW your scoreboard works?"** ★
Three answers, escalating: (1) it failed honestly during bring-up —
NACK-abort flows produced real count mismatches until the driver trimmed
items correctly; (2) the audit's mutation-thinking: for each failure class I
can name the comparing line that goes red; (3) admitted next step: literal
mutation testing. Never say "because tests pass."

**F3. "Why didn't you connect your RTL master to the slave in the UVM
bench?"**
Attribution. With two unverified RTL blocks, a failure doesn't tell you
which side is wrong, and error injection through a well-behaved master is
nearly impossible. BFM = stimulus I trust and can corrupt at will. The
master RTL gets its own verification: the RAL bench (register path) and the
smoke test (bus path) — which found three real bugs in it.

**F4. "Your monitor samples the system clock, not SCL. Defend that."**
The TB owns both domains (BFM timing is in system-clock cycles), sampling
every clk cannot miss multi-cycle SCL phases, and event detection is
edge-qualified exactly like the DUT's. The alternative (event-driven on SCL
edges) is also valid; mine additionally timestamps stretch durations
trivially (scl_low_cnt).

**F5. "What's the weakest part of this project?"** ★
Honest, prepared answer: the UVM layer's post-audit state is verified by
review + the bench's own self-checks but hasn't been regression-run locally
(no commercial simulator on my machine) — the RTL layer has independent sim
proof (smoke), and running `make quick` on a licensed machine is the stated
next step. Second weakness: single-slave topology; multi-slave addressing
and bus-clear are unimplemented and listed as future work. (Volunteering
weaknesses with mitigation plans reads as senior.)

**F6. "If I flip one bit in the slave's shift register RTL, what happens in
your bench?"** ★
Write path: monitor reconstructs the corrupted byte? No — the wire carries
the CORRECT byte (corruption is internal); the WRITE pair-compare passes,
but the stored value is wrong → the next READ streams it out and the
shadow-compare (`ref_reg_bank` built from the wire) fires. If no test reads
that register → caught by reg-bank coverage pressure + read-back tests in
regression. This level of specificity is the goal for any "what if" they
throw.

**F7. "Why queues in the scoreboard instead of comparing in write_actual?"**
Arrival order between two analysis ports in the same timestep isn't
guaranteed, and abort flows legitimately skew stream timing. Queues + match-
when-both-present is order-proof, and end-of-test leftovers become a
first-class check.

**F8. "What did the audit change in ONE sentence each?" (rapid fire)**
Scoreboard: write data actually compared now. SVA: failures counted, windows
satisfiable. BFM: spec-timed, stretch-aware, NACK-aborting. Slave RTL: CDC
sync, SDA gating, stretch that actually fires. Master RTL: bus held between
bytes, Sr/STOP that exist on the wire. Coverage: all 17 groups in the
verdict, unhittable cross closed. Flow: coverage merge works, regression
fails on UVM_ERROR. RAL: buildable, type-correct. Docs: claims now
grep-verifiable.

**F9. "Which bug taught you the most?"**
The synchronizer/arb-loss one (war story 5): my own correct fix created a
new bug, the smoke test caught it within the hour, and the root cause is a
general CDC law (matched delays on compared operands). It demonstrates fix
→ regress → reason discipline.

**F10. "How would you verify this slave with formal instead?"**
Properties: FSM deadlock-freedom (always eventually IDLE absent stimulus),
no SDA drive while not addressed, ACK only after address match, pointer
bounds, START/STOP detector equivalence to spec definition. Constraints: the
master side becomes assumptions (legal I2C). Tools: SymbiYosys/JasperGold.
Named as planned next credential.

**F11. "Estimate your bench's simulation throughput and what dominates it."**
Bit time ≈ 22 clk (~16 low + 6 high) → byte+ACK ≈ 200 clk ≈ 4 µs sim-time at
50 MHz; the stress test ≈ hundreds of thousands of cycles — seconds of CPU.
Dominated by event density on the open-drain wires and UVM reporting at high
verbosity; both controllable (verbosity gating; the BFM constants are
parameters, so a "fast functional mode" is a one-line knob — with the SVA
windows scaled with them).

**F12. "What would break if the slave address parameter changed to 0x42?"**
RTL: nothing (parameter). Bench: scoreboard's hardcoded 7'h50 legality
check, sequences' default addr constraints, coverage target bins. Honest
improvement I'd make: hoist TARGET_ADDR into the tb package/config — good
example of "what would you refactor."

**F13. "Prove the monitor is truly passive."**
It touches only `vif.sda/scl` reads, creates its own items, never references
the driver or DUT hierarchy; grep the file. Passive observation is what
makes scoreboard agreement MEANINGFUL — if the monitor echoed driver state,
intent-vs-wire would be intent-vs-intent.

**F14. "Your smoke test isn't UVM. Why is that a strength here?"**
Different methodology = decorrelated blind spots. The UVM bench couldn't see
master-RTL bugs by design; a 300-line plain-SV bench with a different
stimulus style found three in an hour. Independent evidence beats more of
the same evidence.

**F15. "What's your bug report discipline?"**
Symptom → minimal repro → root cause (mechanism, not patch) → fix → the
check that now catches the class → regression evidence. Every audit entry in
docs/AUDIT_FIX_REPORT.md follows it; war stories 1–6 are the spoken form.

---

## Section G — Behavioral (with project-grounded answers)

**G1. Tell me about a time you found a problem nobody asked you to find.**
The audit itself: the project was "done, all green." I re-opened it as a
skeptic, kill-chain-traced the checkers, and found the dead write-compare and
uncounted assertions. Frame: curiosity + ownership beyond the ticket.

**G2. A time you were wrong?**
My first smoke-test failure looked like an RTL bug; root cause was my OWN
testbench's polling race. I debugged my code with the same rigor as the
DUT's, found the stale-status mechanism, fixed both the TB and added an RTL
hardening guard. Frame: ego-free debugging.

**G3. A time you pushed back with data?**
Rejected three "critical" review findings (MSB-drop, stretch-timeout,
monitor-race) by tracing NBA/scheduling semantics and counter behavior —
documented the disproofs alongside the real fixes. Frame: respect for
evidence over authority of the reviewer.

**G4. How do you handle incomplete verification under deadline?**
Rank by risk-of-silent-failure: checker integrity first (a dead checker
poisons all other evidence), then protocol assertions, then coverage
breadth. Ship with an honest residual-risk list — exactly the "Honest
boundaries" section I keep in the repo.

**G5. How do you learn a new protocol fast?**
Spec → hand-drawn waveforms → write the monitor FIRST (decoding forces
understanding) → then stimulus → then checks. The monitor-first habit comes
straight from this project: the monitor's event decoding is the protocol
spec in executable form.

**G6. Why DV as a career?**
(Yours to personalize — but the strong skeleton: DV is adversarial system
thinking; the audit phase of this project is what convinced me — proving a
green dashboard wrong was more satisfying than building the dashboard.)

**G7. Where do you need to grow?**
Honest menu from this project: gate-level/SDF experience, formal tools
beyond planning (SymbiYosys next), UPF/low-power verification, and running
this methodology at SoC scale with VIP. Naming specifics beats "I work too
hard."

**G8. Walk me through how you'd start verifying a block you've never seen.**
Spec read → interface contract list → verification plan (features × checks ×
coverage) → bench skeleton (monitor first) → smoke directed test → checkers
→ constrained-random + coverage → closure + audit. Then point at this repo
as the executed instance of that exact loop.

---

## Section H — The commercial-simulator shakedown (2026-06-12, fresh material)

**H1. You said the suite passes — on what simulator, and what happened the
first time you ran it on a real one?**
Riviera-PRO 2025.04 on EDA Playground, UVM 1.2. First run: 4 of 8 tests
passed. The 4 failures decomposed into 5 findings — three constraint
conflicts in sequences that had never executed, one portability bug, and one
genuine RTL bug. After fixes: 8/8 green, UVM_ERROR=0 everywhere. Tell this
proudly, not defensively — the first run on a new tool is *supposed* to be a
shakedown, and a suite that finds bugs is a suite that works.

**H2. What was the RTL bug?**
During a clock stretch the slave released its ACK. `SLV_STRETCH` had no arm
in the SDA-output `always_ff`, so it fell into `default: sda_o <= 1'b1`.
A stretching slave has only paused the clock — it must keep holding SDA.
The fix is one case arm: `SLV_STRETCH: ;` (hold the flop).

**H3. Why didn't your smoke test or earlier UVM runs catch it?**
Two reasons, both instructive. Earlier UVM runs: stretch had literally never
fired (the original audit found it edge-armed before `active` — a dead
feature). The Icarus smoke: its only "observer" is the RTL master, which
samples SDA mid-SCL-high — *after* the slave re-grabbed the line. The UVM
passive monitor samples AT the SCL rising edge and caught the released line.
Two observers, same wire, different sample instants — the stricter one finds
the bug. I then added smoke check T6 (stretch armed pre-START so it fires at
the address ACK) to pin it locally: red before the fix, 33/33 after.

**H4. Explain the `rand addr` bug — how can a constraint "not apply"?**
A constraint participates only when its *object* is randomized. The virtual
sequence started `i2c_single_write_seq` with `seq.start()` but never called
`seq.randomize()` — so `rand logic [6:0] addr` kept its default 0 and the
`addr == 7'h50` constraint never ran. It surfaced two layers down when the
*item's* `valid_addr_c` rejected 0. Directed tests had masked it by
assigning `addr` explicitly. Fix: non-rand field with a default — if callers
never randomize the sequence, `rand` is the wrong contract.

**H5. Why did the same code compile on one simulator and not another?**
CG15 used bin names `small`, `medium`, `large` — reserved Verilog keywords
(trireg charge strengths). Questa tolerates them in bin position; Riviera's
parser rejects them. Renamed `sz_*`. Lesson: code that has only ever seen
one toolchain has a class of bugs you haven't hit yet.

**H6. Your per-test coverage was only ~40–65%. Defend that.**
That's correct behavior, not a gap. A directed test is *supposed* to hit
only its own bins — `data_nack_test` sends one 1-byte write, so Size covers
only `sz_small` (25%) and Dir only write (50%). Coverage closes across the
**merged** regression (`make regress` + `make cov`, 19 tests × 3 seeds), not
in any single run. EDA Playground runs are isolated with no UCDB merge, so
per-test numbers are all it can show. Quoting a single-test number as "the
coverage" would be the actual mistake.
