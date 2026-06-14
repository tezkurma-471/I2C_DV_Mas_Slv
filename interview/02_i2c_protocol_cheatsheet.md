# 02 — I2C Protocol Cheatsheet (know cold, mapped to this repo)

Every fact here is something a panel can ask in the first ten minutes. Each
section ends with **Where in this repo** — tying protocol knowledge to your
own code is what separates "read about it" from "built it."

---

## 1. The two wires and the golden electrical rule

- **SDA** (data) and **SCL** (clock), both **open-drain, wired-AND** with
  pull-up resistors. Devices may only **pull low or release** — never drive
  high. Released + pull-up = logic 1. Any single device pulling low forces 0.
- Consequences: bus idle = both high; a "drive fight" is impossible by
  construction (0 always wins); arbitration and clock-stretching both fall
  out of this one electrical property.

**Where:** `tb/i2c_if.sv` (`(strong0, weak1)` drivers + `(weak1, highz0)`
pull-ups); RTL pads `assign sda = (sda_o==1'b0) ? 1'b0 : 1'bz;`.

## 2. Bus events — draw these from memory

```
        ___           ___________            ___
SCL        \_________/           \__________/
        ______
SDA           \______ D ________ X _________ ...
              ^START         ^data may change only while SCL low
```

- **START (S):** SDA falls **while SCL is high**.
- **STOP (P):** SDA rises **while SCL is high**.
- **Repeated START (Sr):** another START without an intervening STOP — keeps
  bus ownership; the atomic write-pointer-then-read idiom.
- **Data validity (the golden rule):** while SCL is high, SDA must be
  STABLE. Any SDA edge under SCL-high *is* a START or STOP by definition —
  that's why the rule exists.
- Ordering discipline for generating events: for STOP, SCL must rise
  *before* SDA rises; for Sr, SDA must fall while SCL is *already* high.
  (The master RTL originally toggled both lines on the same edge for Sr and
  STOP — so the events never existed on the wire. Found by `make smoke`.)

**Where:** detection in `i2c_slave_controller.sv` (`start_cond`/`stop_cond`
off synchronized signals), generation in the BFM (`send_start/send_rep_start/
send_stop`) and master RTL 3-phase STOP / 2-phase Sr; checked by SVA A1/A3/A7.

## 3. Byte format & ACK

- Every byte is **8 bits, MSB first**, each bit sampled on SCL **high**.
- After every byte, a **9th clock**: the transmitter RELEASES SDA; the
  receiver pulls it low = **ACK**, leaves it high = **NACK**.
- First byte after S/Sr = **address byte**: `{7-bit address, R/W}`;
  R/W=0 write, R/W=1 read. Our DUT: `0x50` → address byte `0xA0` (W) /
  `0xA1` (R).
- NACK meanings: address NACK = "nobody home" → master must STOP (or Sr).
  Data NACK on a write = receiver can't take more → transmitter stops.
  On a READ, the **master** ACKs each byte it wants more of and **NACKs the
  last byte** — that NACK is information ("I'm done"), not an error.

**Where:** BFM `send_byte/wait_for_ack/send_ack/send_nack`; slave FSM
SLV_ACK/SLV_RX_ACK/SLV_TX_ACK; per-byte ACKs recorded in
`i2c_seq_item.byte_ack[]` by BOTH driver and monitor; legality checked in the
scoreboard (only 0x50 may ACK) and SVA A4 (ACK slot never floats X/Z).

## 4. Clock stretching

- A **slave** may hold **SCL low** to pause the master (it needs time). The
  master, before using any high phase, must check the wire actually rose —
  released ≠ high under wired-AND.
- Practical bound: this bench enforces `MAX_CLK_STRETCH` (1000 clk) via the
  master's timeout counter (counting only "I released but it's still low"
  cycles) and SVA A5.

**Where:** slave `SLV_STRETCH` + `stretch_pending` arming; BFM
`scl_release_wait()`; master RTL timer-freeze on `scl_o==1 && scl_i==0`;
tests `clock_stretch_test`, `stretch_read_test`.

## 5. Multi-master arbitration

- Multiple masters may start simultaneously; they monitor SDA **while
  transmitting**. If you transmit 1 (release) but read 0, another master is
  also driving and **won the bit** — you lost arbitration: stop driving
  immediately, do NOT issue STOP (the winner's transaction is in flight).
- Losing is data-dependent: lower address/data wins bit by bit.

**Where:** master RTL arb check during `STATE_TX_BIT` (against a 2-cycle
delayed `sda_o_d2` to align with the synchronized inputs); TB hook
`sda_drv_x` in `i2c_if.sv`; `arbitration_lost_test` (T13) with the slave
driver in compete mode.

## 6. Addressing & reserved space

- 7-bit addressing: 128 codes, but `0000_XXX` and `1111_XXX` are **reserved**
  (general call, START byte, 10-bit prefix, device-ID...) → 112 usable.
- 10-bit addressing exists (`11110xx` prefix + second byte) — not implemented
  here; say so if asked, and explain the prefix mechanism.

**Where:** `valid_addr_c` constraint excludes reserved ranges;
`addr_sweep_test` walks 0x08–0x77; `i2c_addr_cg`/`i2c_dir_addr_cross_cg`.

## 7. Timing parameters (standard mode, and this bench's cycle equivalents)

| Spec param | Meaning | 100 kHz spec | This bench (50 MHz clk) |
|---|---|---|---|
| f_SCL | clock rate | ≤100 kHz | RTL master: 500 clk period |
| t_HD;STA | START hold | ≥4.0 µs | `T_HD_STA`=10 clk |
| t_SU;STA | Sr setup | ≥4.7 µs | `T_SU_STA`=10 clk |
| t_SU;STO | STOP setup | ≥4.0 µs | `T_SU_STO`=10 clk |
| t_BUF | bus free STOP→START | ≥4.7 µs | `T_BUF`=20 clk (SVA A7, BFM waits) |
| t_SU;DAT | data setup to SCL↑ | ≥250 ns | `T_SU_DAT`=5 clk (SVA A9) |
| t_HD;DAT | data hold after SCL↓ | **≥0** | structural 2-clk check (SVA A8) |

The t_HD;DAT=0 row is an interview trap you now own: the spec allows zero
hold (devices add internal hold for the SCL falling region); an assertion
demanding 5 cycles would flag *compliant* hardware — which is exactly why A8
was re-derived during the audit.

## 8. Speed grades (one breath each)

Standard 100k / Fast 400k / Fast+ 1M / High-speed 3.4M (different preamble,
current-source pull-up assist) / Ultra-fast 5M (write-only, push-pull —
abandons wired-AND). This project: standard mode timing constants,
parameterized in `i2c_pkg.sv`.

## 9. SMBus differences (common follow-up)

Fixed 10k–100k range, **SCL low timeout (~35 ms)** — a stuck I2C bus hangs
forever, SMBus recovers; optional PEC (CRC-8); ARA (alert response address).
Nice tie-in: "my MAX_CLK_STRETCH bound is the same philosophy as the SMBus
timeout — never let the bus hang unboundedly."

## 10. This DUT's behavioral contract (so you answer DUT questions precisely)

- Address match `0x50` → ACK; anything else → stay quiet (NACK by silence).
- Register pointer **resets to 0 at every address ACK**; auto-increments per
  data byte; wraps mod 8. So every read streams from reg[0] — and the
  scoreboard's reference model mirrors exactly that.
- Write path: byte latched on the 8th SCL rise (`latched_rx_byte` — avoids
  swallowing the ACK bit), committed to the bank in SLV_RX_ACK exactly once
  (`rx_write_done` one-shot).
- Read path: `tx_shift_reg` loaded at address ACK and after each master ACK;
  shifts MSB-first on SCL falls; SDA changes only under SCL low (gated).
- Inputs double-flop synchronized; all FSM/edge logic runs on the 2-cycle
  delayed view (and any compare against own outputs uses matched delays).
- Test hooks: `stretch_en/stretch_cycles` (edge-armed, pending-latched),
  `force_data_nack` (NACKs the byte but — design decision — still stores it).
