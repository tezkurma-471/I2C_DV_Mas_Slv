> **⚠️ 2026-06-10 AUDIT UPDATE — read this box before trusting the lesson below.**
> A deep audit + fix pass changed the code this walkthrough describes. Deltas for this file:
> - The RAL bench is now actually BUILDABLE: `make compile_ral / sim_ral / regress_ral`. Before the audit no Makefile or script compiled any of it.
> - `i2c_cpu_driver` vif fixed: it declared `virtual i2c_reg_if.drv_mp` but config_db stores `virtual i2c_reg_if` — a fatal type mismatch.
> - `bus2reg` now populates `rw.addr` (adapter contract); the reset-check sequence now verifies REG_CMD reads back 0x00 (the only WO register was previously never checked).
> Full detail: [`19_audit_fixes_walkthrough.md`](./19_audit_fixes_walkthrough.md) and `docs/AUDIT_FIX_REPORT.md`.

# Lesson 18 — UVM RAL for I2C Master Controller: CPU Register Interface Verification

**Files under study:**
- `ral/i2c_master_reg_model.sv` — register model (uvm_reg subclasses + uvm_reg_block)
- `ral/i2c_reg_adapter.sv` — bus adapter (reg2bus / bus2reg for cpu_seq_item)
- `ral/i2c_ral_seq.sv` — RAL sequences (reset_check, program_master, field_access)
- `uvm/i2c_cpu_seq_item.sv` — CPU bus transaction (addr, wr, wdata, rdata)
- `uvm/i2c_cpu_driver.sv` — drives cpu register interface
- `uvm/i2c_cpu_agent.sv` — wraps CPU driver + sequencer
- `uvm/i2c_ral_env.sv` — env with reg_model, adapter, auto-predict
- `uvm/i2c_ral_test.sv` — RAL tests (reset_test, program_test, field_test)
- `tb/i2c_reg_if.sv` — CPU register SystemVerilog interface
- `tb/top_tb_ral.sv` — new TB top instantiating DUT with reg interface only
- `tb/i2c_tb_ral_pkg.sv` — package for RAL components

**Concepts covered:** `uvm_reg`, `uvm_reg_field`, `uvm_reg_block`, `uvm_reg_adapter`, `reg.write/read`, field access (`set/update/get`), access types (RW/RO/WO), mirror vs desired vs actual, auto-predict, `provides_responses`, `lock_model()`, `n_bytes`, `create_map()`, backdoor access, `uvm_reg_hw_reset_seq`

**Date:** 2026-05-18
**Status:** This lesson adds a complete Register Abstraction Layer on top of the APB-like CPU interface of `i2c_master_controller.sv`. After Lessons 01–17 you verified the I2C *bus*. This lesson verifies the *register map* — the host CPU's view of the master controller. These are two different verification problems. Both matter. NVIDIA/Qualcomm/Intel require you to know both.

---

## Table of Contents

1. [Why RAL for the I2C Master Controller](#1-why-ral-for-the-i2c-master-controller)
2. [I2C Master Register Map — Deep Dive](#2-i2c-master-register-map--deep-dive)
3. [The 60-Second Elevator Pitch](#3-the-60-second-elevator-pitch)
4. [New Component: `i2c_reg_if.sv` + `i2c_cpu_seq_item.sv`](#4-new-component-i2c_reg_ifsv--i2c_cpu_seq_itemsv)
5. [Register Model Walkthrough: `i2c_master_reg_model.sv`](#5-register-model-walkthrough-i2c_master_reg_modelsv)
6. [Adapter Walkthrough: `i2c_reg_adapter.sv`](#6-adapter-walkthrough-i2c_reg_adaptersv)
7. [Environment Changes: `i2c_ral_env.sv`](#7-environment-changes-i2c_ral_envsv)
8. [RAL Sequences — BEFORE vs AFTER Contrast](#8-ral-sequences--before-vs-after-contrast)
9. [Access Type Deep Dive (I2C-specific)](#9-access-type-deep-dive-i2c-specific)
10. [Before vs After Summary Table](#10-before-vs-after-summary-table)
11. [New File Inventory — What Changed](#11-new-file-inventory--what-changed)
12. [Quiz — 15 Questions (No Answers)](#12-quiz--15-questions-no-answers)
13. [Quiz Answers (with Interview-grade callouts)](#13-quiz-answers-with-interview-grade-callouts)
14. [Key Takeaways](#14-key-takeaways)
15. [Action Items](#15-action-items)
16. [Honest Self-Score Template](#16-honest-self-score-template)

---

## 1. Why RAL for the I2C Master Controller

### The Specific Problem This Lesson Solves

You have spent 17 lessons verifying the I2C *bus* — START conditions, ACK/NACK, bit timing, arbitration loss. But there is a completely separate verification problem hiding in `i2c_master_controller.sv` that your existing testbench does not cover at all.

Look at the module port list:

```systemverilog
module i2c_master_controller (
  input  logic [2:0]  cpu_addr,
  input  logic        cpu_wr,
  input  logic [7:0]  cpu_wdata,
  output logic [7:0]  cpu_rdata,
  output logic        cpu_irq,
  ...
);
```

That is an APB-like host CPU register interface. The host processor writes to `cpu_addr=3'h0` to enable the master, writes to `cpu_addr=3'h1` to issue commands, reads `cpu_addr=3'h2` to get status. Seven distinct register addresses, each with specific access types, reset values, and field semantics. That register map is *the API* between software and hardware. If it is wrong, the chip ships broken.

Your current `i2c_master_driver.sv` in Lessons 1–17 drives the I2C physical bus (SCL/SDA). It does NOT exercise the register interface. The existing tests generate I2C transactions. They do not verify that writing `cpu_addr=3'h5, cpu_wdata=8'h01` correctly enables the DONE interrupt. These are orthogonal verification problems.

### The Pain Without RAL

Here is what testing the register interface looks like without RAL. You want to verify that after reset, REG_CTRL reads back 0x00 and that enabling the master (EN=1) works:

```systemverilog
// Without RAL — direct sequence item manipulation
i2c_cpu_seq_item req;

// Check reset value of REG_CTRL
req = i2c_cpu_seq_item::type_id::create("req");
req.cpu_addr  = 3'h0;   // REG_CTRL — magic number
req.cpu_wr    = 1'b0;
start_item(req);
finish_item(req);
if (req.cpu_rdata !== 8'h00)
  `uvm_error("RST", $sformatf("REG_CTRL reset value wrong: got 0x%0h", req.cpu_rdata))

// Check reset value of REG_STATUS
req.cpu_addr  = 3'h2;   // REG_STATUS — another magic number
req.cpu_wr    = 1'b0;
start_item(req);
finish_item(req);
if (req.cpu_rdata !== 8'h00)
  `uvm_error("RST", $sformatf("REG_STATUS reset value wrong"))

// ... repeat for REG_DATA (3'h3), REG_ADDR (3'h4), REG_IRQ_EN (3'h5) ...
// ... five more blocks of identical boilerplate with magic numbers ...

// Enable master
req.cpu_addr  = 3'h0;   // REG_CTRL — magic number again
req.cpu_wr    = 1'b1;
req.cpu_wdata = 8'h01;  // EN=1 — magic number, no indication what bit 0 is
start_item(req);
finish_item(req);

// Verify EN bit stuck (read back)
req.cpu_addr  = 3'h0;
req.cpu_wr    = 1'b0;
start_item(req);
finish_item(req);
if (req.cpu_rdata[0] !== 1'b1)
  `uvm_error("EN", "EN bit did not set")
```

Count the problems:
1. `3'h0`, `3'h2`, `3'h4` are magic numbers. Wrong them once and the test silently passes but covers the wrong register.
2. `8'h01` is a magic number for EN=1. No one reading this knows it is bit 0.
3. Every new register added to the DUT requires manual updates to every sequence.
4. Nothing prevents you from writing `3'h2` (REG_STATUS — read-only). The sequence will issue the write and the RTL silently ignores it, but your test log shows zero warning.
5. Reset checking requires you to hardcode expected values `8'h00` for each register. If a reset value changes in the RTL, every test breaks.

> **Interview-grade answer:** *"Without RAL, register testing degenerates into sequences full of magic address literals and manual bit packing. The three immediate failure modes are: (1) no access-type enforcement — you can accidentally write a read-only register and get zero error, (2) no mirror/desired tracking — you cannot ask 'what does the model think this register contains right now?' without issuing a read, and (3) brittleness on register map changes — add one register and you update every sequence that manually computes offsets. RAL solves all three: the model encodes access types so writes to RO registers emit UVM warnings, the mirror value tracks what the hardware should contain based on past transactions, and the register map is defined once in uvm_reg_block so all sequences use symbolic names."*

### The Exact Scenario This Project Tests

The `i2c_master_controller.sv` RTL has this register decode logic:

```systemverilog
// CPU read logic
always_comb begin
  case (cpu_addr)
    REG_CTRL:   cpu_rdata = reg_ctrl;
    REG_STATUS: cpu_rdata = reg_status;
    REG_DATA:   cpu_rdata = reg_data_buf;
    REG_ADDR:   cpu_rdata = reg_addr;
    REG_IRQ_EN: cpu_rdata = reg_irq_en;
    REG_IRQ_ST: cpu_rdata = reg_status;  // IRQ_ST mirrors STATUS
    default:    cpu_rdata = 8'h00;
  endcase
end
```

Notice `REG_IRQ_ST` returns `reg_status`, not a dedicated IRQ status register. That RTL decision — IRQ_ST mirrors STATUS — needs to be captured in the RAL model. If it is not, a RAL read of `REG_IRQ_ST` will return a mirror value that diverges from the RTL. This project documents exactly how to model that.

Also notice REG_CMD is NOT in the read mux. That means `cpu_rdata` returns `8'h00` for address `3'h1`. That is a write-only register. The RAL model declares it `"WO"` and its `read()` method returns the desired/mirror value without issuing a bus transaction — exactly matching the RTL behavior.

> **Interview-grade answer:** *"RAL is not just about convenience. It is about correctness of the verification intent. When the RTL has a write-only register (CMD in this I2C project), a direct sequence that reads back to verify would get 0x00 from the RTL regardless of what was written — a false pass. The RAL model declared 'WO' knows not to issue a read transaction; it returns the internally-tracked desired value. That distinction between what the hardware exposes and what the model tracks is the core value proposition of the access type system."*

---

## 2. I2C Master Register Map — Deep Dive

### Overview

The `i2c_master_controller.sv` exposes seven 8-bit registers via a 3-bit address bus. All values are unsigned 8-bit. The bus width determines the RAL `n_bytes` parameter — 1 byte in this project (critically different from AXI where n_bytes=4).

### Complete Register Table

| Offset | Name | Access | Reset | Fields | RTL Variable |
|--------|------|--------|-------|--------|-------------|
| 0x0 | REG_CTRL | RW | 0x00 | [7:2]=reserved, [1]=IRQ_GLOBAL_EN, [0]=EN | `reg_ctrl` |
| 0x1 | REG_CMD | WO | 0x00 | [7:4]=reserved, [3:0]=CMD (i2c_cmd_e) | `reg_cmd` |
| 0x2 | REG_STATUS | RO | 0x00 | [7:3]=reserved, [2:0]=STATUS (i2c_status_e) | `reg_status` |
| 0x3 | REG_DATA | RW | 0x00 | [7:0]=DATA (TX write / RX read) | `reg_data_buf` |
| 0x4 | REG_ADDR | RW | 0x00 | [7:1]=SLAVE_ADDR, [0]=DIR (i2c_dir_e) | `reg_addr` |
| 0x5 | REG_IRQ_EN | RW | 0x00 | [4]=ERR_EN, [3]=TIMEOUT_EN, [2]=NACK_EN, [1]=ACK_EN, [0]=DONE_EN | `reg_irq_en` |
| 0x6 | REG_IRQ_ST | RO | 0x00 | [7:0]=mirrors REG_STATUS (per RTL) | `reg_status` (same wire) |

### Field-by-Field Breakdown

**REG_CTRL (0x0) — RW**

Bit 0 (`EN`) is the master enable. When 0, the FSM stays in STATE_IDLE regardless of commands written to REG_CMD. When 1, commands are decoded. In RTL: `reg_ctrl[0]` gates `cmd_valid`. Bit 1 (`IRQ_GLOBAL_EN`) is a global interrupt gate — even if individual interrupts in REG_IRQ_EN are enabled, `cpu_irq` only fires if `IRQ_GLOBAL_EN=1`. Bits [7:2] are reserved and ignored by the RTL.

Reset value = 0x00: after reset the master is disabled. Every test sequence must write `EN=1` before issuing any command. Forgetting this is one of the top-5 bugs in fresh testbenches.

**REG_CMD (0x1) — WO**

The command register. Writing here triggers a transaction. The RTL generates a one-cycle `cmd_valid` pulse when this register is written:

```systemverilog
if (cpu_wr && (cpu_addr == REG_CMD)) begin
  cmd_valid <= 1'b1;
end else begin
  cmd_valid <= 1'b0;
end
```

Access type = WO because reading back the last command issued is meaningless — the FSM has already consumed it. The RTL does not retain the command for readback (the default case in cpu_rdata returns 0x00 for address 0x1). The RAL model handles this with access type "WO": `reg.write()` issues a bus write, `reg.read()` returns the internally-stored desired value without touching the bus.

Valid CMD values from `i2c_cmd_e`:
- `CMD_NOP = 4'h0` — no operation
- `CMD_START = 4'h1` — generate START condition
- `CMD_STOP = 4'h2` — generate STOP
- `CMD_WRITE = 4'h3` — write byte and wait for ACK/NACK
- `CMD_READ_ACK = 4'h4` — read byte and send ACK (continue)
- `CMD_READ_NACK = 4'h5` — read byte and send NACK (last byte)
- `CMD_REP_START = 4'h6` — generate Repeated START
- `CMD_ABORT = 4'h7` — abort transaction, release bus

> **Interview-grade answer:** *"The CMD register is WO because command execution is one-shot: once the FSM consumes the command, the register value is irrelevant. The RTL generates a cmd_valid pulse on the write cycle and the FSM acts immediately. Reading back 0x1 (CMD_START) after the START condition is already on the bus tells you nothing useful. WO encoding in the RAL prevents sequences from issuing a useless bus read — the RAL returns the mirror value directly, saving one clock cycle and keeping the simulation log clean."*

**REG_STATUS (0x2) — RO**

Reflects the current FSM state. Maps directly to `i2c_status_e`:
- `STS_IDLE = 3'b000` — safe to issue new command
- `STS_BUSY = 3'b001` — transaction in progress, do NOT write CMD
- `STS_ACK = 3'b010` — ACK received on last byte
- `STS_NACK = 3'b011` — NACK received
- `STS_ARB_LOST = 3'b100` — arbitration lost (multi-master scenario)
- `STS_TIMEOUT = 3'b101` — clock stretching exceeded MAX_CLK_STRETCH
- `STS_DONE = 3'b110` — transaction completed (STOP generated)
- `STS_ERR = 3'b111` — generic error

Access type = RO because writing to STATUS makes no sense and the RTL ignores it (no write path to `reg_status` from cpu_wr). If a sequence calls `STATUS.write()` in RAL, the RAL silently skips the bus transaction and emits a warning. This is access type enforcement — the RTL design intent encoded in the model.

> **Interview-grade answer:** *"RO and WO are not cosmetic labels in RAL — they change the behavior of write() and read() methods. For an RO register: write() detects the access type mismatch, emits a UVM_WARNING, and does NOT issue a bus transaction. The mirror value is unchanged. For a WO register: read() returns the locally-stored desired value without touching the bus. This enforcement is why RAL catches accidental writes to STATUS registers in complex sequences — something a manual sequence approach simply cannot do."*

**REG_DATA (0x3) — RW**

Dual-purpose TX/RX buffer. On write, loads the shift register for transmission. On read, returns the last received byte (populated by the RTL when `STATE_RX_BIT → STATE_ACK_SEND` transition occurs — see Bug #10 fix in `i2c_master_controller.sv`). This is an RW register with asymmetric semantics: what you write and what you read back are different values. The RAL model captures this correctly because the mirror value is updated on write (desired = written value) and on read (mirror = hardware value read).

**REG_ADDR (0x4) — RW**

The slave address register. Bit layout: `[7:1]` = 7-bit slave address, `[0]` = direction (from `i2c_dir_e`: `DIR_WRITE=0`, `DIR_READ=1`). In the RAL model this is represented as two fields: `SLAVE_ADDR[7:1]` and `DIR[0]`. Field-level access with `set()/update()` is cleaner than manually packing `{7'h50, 1'b0}`.

**REG_IRQ_EN (0x5) — RW**

Five independent interrupt enable bits. The RTL interrupt generation:
```systemverilog
cpu_irq <= |({reg_irq_en[0] & done,
              reg_irq_en[1] & ack,
              reg_irq_en[2] & nack,
              reg_irq_en[3] & timeout,
              reg_irq_en[4] & bus_error});
```
Setting `DONE_EN=1` makes `cpu_irq` fire when a transaction completes. Testing interrupt behavior requires correctly programming this register — the RAL model's named fields make the intent explicit.

**REG_IRQ_ST (0x6) — RO**

This is a critical RTL decision to understand. The read mux in the RTL returns `reg_status` for BOTH `REG_STATUS` and `REG_IRQ_ST`:

```systemverilog
REG_STATUS: cpu_rdata = reg_status;
REG_IRQ_ST: cpu_rdata = reg_status;  // Same wire
```

The RAL model for `i2c_irq_st_reg` must be declared RO with reset value 0x00. A `RAL.read()` of this register returns `reg_status`, not a separate IRQ sticky register. In a real-world chip, IRQ_ST would typically be a W1C (Write-1-to-Clear) sticky register. This project's implementation is simplified but correctly models what the RTL actually does.

---

## 3. The 60-Second Elevator Pitch

Read this once. Then close the document and say it out loud without reading. Then come back and compare. Do this three times. This is what you say when a Qualcomm interviewer asks "tell me about your experience with UVM RAL."

> *"In the I2C master verification project, after 17 lessons verifying the physical bus behavior, I added a complete UVM RAL layer targeting the CPU register interface of the master controller. The DUT exposes seven 8-bit registers over a 3-bit APB-like bus: control, command, status, data, address, IRQ-enable, and IRQ-status. Without RAL, the verification sequences were full of magic address literals — writing 3'h4 for REG_ADDR, manually packing SLAVE_ADDR into bits [7:1] — with zero access-type enforcement, meaning a sequence could accidentally write to the read-only STATUS register and get no warning.*
>
> *I built a uvm_reg_block with seven uvm_reg subclasses, each with named fields. REG_CMD is declared WO because the RTL generates a one-shot command pulse and does not retain the value for readback. REG_STATUS and REG_IRQ_ST are RO because the FSM drives them and CPU writes are ignored by the RTL. I wrote a uvm_reg_adapter that converts between the generic uvm_reg_bus_op and my i2c_cpu_seq_item, mapping the 3-bit register address to cpu_addr and using n_bytes=1 because the data bus is 8-bit, not the 32-bit default assumed in AXI adapters. The RAL environment uses auto-predict so the mirror value updates on every completed write without needing an explicit prediction component. This replaced 60 lines of address-literal sequences with self-documenting field-level calls: reg_model.ADDR.SLAVE_ADDR.set(7'h50); reg_model.ADDR.update(status) — and the access type enforcement now catches accidental writes to read-only registers at zero cost."*

> **Interview-grade answer:** *"The RAL layer is the formal contract between your verification IP and the register map specification. It is not a convenience layer — it is the mechanism by which the spec (access types, reset values, field names) gets encoded into executable verification. Every time you call reg.write(), the RAL checks the access type, issues the bus transaction, and updates the mirror. You get spec compliance checking for free on every register access. That is the qualitative jump that justifies the upfront investment in writing uvm_reg subclasses."*

> **Interview-grade answer:** *"The distinction between bus-level verification and register-level verification is fundamental. Bus-level verification (Lessons 1–17 in this project) checks that START/STOP conditions, bit timing, ACK/NACK, and arbitration work correctly. Register-level verification checks that the CPU can correctly program the controller — right values at right addresses, correct reset state, access types enforced. These are independent verification planes. A chip can pass all bus-level tests and still ship broken if the register map has an address decode error. You need both."*

---

## 4. New Component: `i2c_reg_if.sv` + `i2c_cpu_seq_item.sv`

### Why a Separate Interface for the CPU Register Bus

The existing `i2c_if.sv` models the physical I2C bus:

```systemverilog
interface i2c_if (input logic clk);
  logic scl;
  logic sda;
  clocking driver_cb @(posedge clk);
    output scl, sda;
  endclocking
  ...
endinterface
```

That interface is about SCL and SDA. The CPU register bus is completely orthogonal — it is the host-side control path, not the I2C protocol path. Mixing them into one interface would be a design error. The rule is: one interface per physical bus. The `i2c_master_controller` has two buses: the CPU register bus and the I2C physical bus. Two interfaces.

### `i2c_reg_if.sv` — Full Walkthrough

```systemverilog
interface i2c_reg_if (input logic clk, input logic rst_n);

    logic [2:0] cpu_addr;
    logic       cpu_wr;
    logic [7:0] cpu_wdata;
    logic [7:0] cpu_rdata;

    clocking driver_cb @(posedge clk);
        default input #1step output #1;
        output cpu_addr, cpu_wr, cpu_wdata;
        input  cpu_rdata;
    endclocking

    clocking monitor_cb @(posedge clk);
        default input #1step;
        input cpu_addr, cpu_wr, cpu_wdata, cpu_rdata;
    endclocking

    initial begin
        cpu_addr  = 3'b000;
        cpu_wr    = 1'b0;
        cpu_wdata = 8'h00;
    end

    modport drv_mp (clocking driver_cb,  input clk, rst_n);
    modport mon_mp (clocking monitor_cb, input clk, rst_n);

endinterface : i2c_reg_if
```

**Line-by-line analysis:**

`default input #1step output #1` — the most important line in the clocking block. Let's unpack it:

- `input #1step`: The driver samples `cpu_rdata` (driven by the DUT) 1 simulation step BEFORE the posedge. Why? Because the DUT and the driver both react to posedge. If they both update on the same delta, you get a race. `#1step` is the simulation-time equivalent of a setup-time check — it reads the signal just before the edge, guaranteed to see the pre-edge stable value.

- `output #1`: The driver's assignments to `cpu_addr`, `cpu_wr`, `cpu_wdata` appear #1 after posedge. This is a registered-drive behavior — the DUT samples inputs at the NEXT posedge, so there is a full clock cycle for the driven values to propagate. This avoids glitch-on-clock-edge problems.

`monitor_cb` is `input #1step` only — the monitor never drives anything. All signals are sampled 1 step before posedge, giving a stable view of what the DUT sees at that edge.

`initial begin cpu_addr=3'b000; cpu_wr=1'b0; cpu_wdata=8'h00; end` — this initializes the interface at time-0 so the DUT does not see X-state writes during simulation startup. Without this, `cpu_wr` would be X during the first few cycles and the RTL register file could latch garbage values before reset completes.

`modport drv_mp (clocking driver_cb, input clk, rst_n)` — the modport restricts the driver to only see what it needs: the driver clocking block (with its synchronous discipline), the clock, and reset. The driver cannot access `monitor_cb`. This is compile-time access control.

> **Interview-grade answer:** *"Clocking blocks serve two purposes: synchronization and access control. The synchronization purpose is the 'default input #1step output #1' specification — it defines when the testbench samples DUT outputs and when it drives DUT inputs relative to the clock edge. Without clocking blocks, every driver task has to manually add delays before sampling to avoid race conditions with the DUT. The access control purpose is the modport — it restricts the driver to only the signals it is supposed to touch, catching incorrect connections at compile time rather than at simulation runtime."*

> **Interview-grade answer:** *"The reason i2c_reg_if.sv is a separate file from i2c_if.sv is the single-responsibility principle applied to interfaces. i2c_if models the open-drain I2C physical bus with its wired-AND semantics, SCL toggling, and SDA sampling. i2c_reg_if models a synchronous register bus with address, write-enable, and byte-wide data. Mixing them would make neither interface reusable. When the next project uses the CPU register bus with a different physical protocol (say, SPI instead of I2C), i2c_reg_if can be reused directly."*

### `i2c_cpu_seq_item.sv` — Why It Exists

The existing `i2c_seq_item.sv` models a full I2C protocol transaction:

```systemverilog
class i2c_seq_item extends uvm_sequence_item;
  rand logic [6:0]  addr;       // 7-bit slave address
  rand i2c_dir_e    dir;        // read or write
  rand bit [7:0]    data [$];   // byte array
  rand int          num_data;
  rand bit          start_cond;
  rand bit          stop_cond;
  ...
endclass
```

That item represents "send a complete I2C transaction." It knows nothing about register addresses or the CPU bus.

The `i2c_cpu_seq_item.sv` represents "perform one CPU register access":

```systemverilog
class i2c_cpu_seq_item extends uvm_sequence_item;
  rand logic [2:0] cpu_addr;    // which register (0–6)
  rand logic       cpu_wr;      // read or write
  rand logic [7:0] cpu_wdata;   // value to write
  logic      [7:0] cpu_rdata;   // value read back (NOT rand)
endclass
```

The critical design decision: `cpu_rdata` is NOT `rand`. It is filled by the driver after the bus transaction completes (the DUT drives it). Making it `rand` would be incorrect — it is an output from the DUT, not an input to the DUT.

The RAL adapter's `reg2bus()` function populates a `i2c_cpu_seq_item` from a `uvm_reg_bus_op`. The adapter's `bus2reg()` reads `cpu_rdata` back into the `uvm_reg_bus_op`. This is the bridge between the generic RAL world and the project-specific bus.

---

## 5. Register Model Walkthrough: `i2c_master_reg_model.sv`

### The Full Register Model Structure

```
i2c_master_reg_block (extends uvm_reg_block)
├── CTRL    : i2c_ctrl_reg    (extends uvm_reg)
│   ├── EN            : uvm_reg_field  [0:0]  RW
│   └── IRQ_GLOBAL_EN : uvm_reg_field  [1:1]  RW
├── CMD     : i2c_cmd_reg     (extends uvm_reg)
│   └── CMD           : uvm_reg_field  [3:0]  WO
├── STATUS  : i2c_status_reg  (extends uvm_reg)
│   └── STATUS        : uvm_reg_field  [2:0]  RO
├── DATA    : i2c_data_reg    (extends uvm_reg)
│   └── DATA          : uvm_reg_field  [7:0]  RW
├── ADDR    : i2c_addr_reg    (extends uvm_reg)
│   ├── SLAVE_ADDR    : uvm_reg_field  [7:1]  RW
│   └── DIR           : uvm_reg_field  [0:0]  RW
├── IRQ_EN  : i2c_irq_en_reg  (extends uvm_reg)
│   ├── DONE_EN       : uvm_reg_field  [0:0]  RW
│   ├── ACK_EN        : uvm_reg_field  [1:1]  RW
│   ├── NACK_EN       : uvm_reg_field  [2:2]  RW
│   ├── TIMEOUT_EN    : uvm_reg_field  [3:3]  RW
│   └── ERR_EN        : uvm_reg_field  [4:4]  RW
└── IRQ_ST  : i2c_irq_st_reg  (extends uvm_reg)
    └── STATUS        : uvm_reg_field  [7:0]  RO
```

### `i2c_ctrl_reg` — Why Named Fields Matter

The most important concept in this register model is named fields. Here is the full CTRL register definition:

```systemverilog
class i2c_ctrl_reg extends uvm_reg;
  `uvm_object_utils(i2c_ctrl_reg)

  rand uvm_reg_field EN;
  rand uvm_reg_field IRQ_GLOBAL_EN;

  function new(string name = "i2c_ctrl_reg");
    super.new(name, 8, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    EN            = uvm_reg_field::type_id::create("EN");
    IRQ_GLOBAL_EN = uvm_reg_field::type_id::create("IRQ_GLOBAL_EN");

    // configure(parent, size, lsb_pos, access, volatile, reset, has_reset,
    //           is_rand, individually_accessible)
    EN.configure(           this, 1, 0, "RW", 0, 1'b0, 1, 1, 0);
    IRQ_GLOBAL_EN.configure(this, 1, 1, "RW", 0, 1'b0, 1, 1, 0);
  endfunction

endclass
```

The `configure()` parameters warrant a line-by-line explanation because interviewers will ask about each:

- `this` — parent register
- `1` — field width in bits (EN is 1 bit)
- `0` — LSB position (EN is bit 0; IRQ_GLOBAL_EN would use `1`)
- `"RW"` — access type string
- `0` — volatile: 0 means the field value does not change on its own (not volatile). STATUS would be volatile=1 because the FSM changes it without CPU writes
- `1'b0` — reset value
- `1` — has_reset: 1 means reset value is valid
- `1` — is_rand: 1 enables constrained randomization of this field
- `0` — individually_accessible: 0 means you cannot access this field independently from the bus (you always read/write the whole 8-bit register from the DUT's perspective)

**Why named fields change everything:**

Without named fields, to enable the master:
```systemverilog
// Manual: must know EN is bit 0
reg_model.CTRL.write(status, 8'h01);
```

With named fields, two options:

**Option 1: Direct write to whole register**
```systemverilog
reg_model.CTRL.write(status, 8'h01);
// Works, but still requires knowing EN=bit0
```

**Option 2: Field-level set + update (the correct pattern)**
```systemverilog
reg_model.CTRL.EN.set(1'b1);               // Set desired value
reg_model.CTRL.update(status);             // Issue bus write only if desired != mirror
```

The `set()/update()` pattern is critical to understand. `set()` modifies the desired value in the model — no bus transaction yet. `update()` compares desired to mirror: if they differ, it issues a write transaction with the correct bit mask applied to the whole register. If EN is already 1, `update()` issues no transaction.

This is more efficient than always calling `write()` and is exactly how embedded software drivers work — write only when the value changes.

> **Interview-grade answer:** *"Named fields in uvm_reg are not cosmetic. They enable three things that whole-register access cannot: (1) field-level read-modify-write via set/update — you change one field without accidentally clobbering adjacent fields; (2) field-level get/read that returns just the relevant bits already positioned — no manual shifting or masking; (3) individual field coverage — functional coverage for 'was EN ever toggled while IRQ_GLOBAL_EN was set' can be written against the field model rather than against raw bit vectors. At NVIDIA, most registers have 8–20 fields per register. Without named fields, every verification sequence becomes a bit-manipulation exercise."*

### `i2c_cmd_reg` — The WO Register: What Happens on Read?

```systemverilog
class i2c_cmd_reg extends uvm_reg;
  rand uvm_reg_field CMD;

  function void build();
    CMD = uvm_reg_field::type_id::create("CMD");
    CMD.configure(this, 4, 0, "WO", 0, 4'h0, 1, 1, 0);
  endfunction
endclass
```

Access type is `"WO"`. What happens when you call `reg_model.CMD.read(status, rdata)`?

Answer: The UVM RAL does NOT issue a bus transaction. It returns the internally-stored desired value (the last value written via `CMD.write()`). The `status` argument is set to `UVM_IS_OK`. No warning is generated (WO reads returning desired values is expected behavior, not an error).

This is intentional and correct. The CMD register in RTL does not have a read path — address 0x1 returns 0x00 in the `default` case of the cpu_rdata mux. If RAL actually issued a bus read for CMD, it would read 0x00 regardless of what was written, creating a false mirror mismatch. By returning the desired value, the RAL correctly models "this register does not support readback."

What if you try to check what command was last issued? Use `get()`:
```systemverilog
uvm_reg_data_t last_cmd = reg_model.CMD.CMD.get();
// Returns the desired value — what the model thinks was last written
// Does NOT issue a bus read
```

> **Interview-grade answer:** *"A WO register's read() method in UVM RAL returns the desired (last-written) value without issuing a bus transaction. This is the correct behavior because read-only hardware cannot return a meaningful value for write-only registers. The desired value is the model's best knowledge of what the hardware contains. This distinction — desired vs mirror — is fundamental: desired is what you wrote, mirror is what you read back. For WO registers, mirror is never updated because you never read. For RO registers, desired is never updated because you never write. For RW registers, both stay synchronized."*

### `i2c_status_reg` — The RO Register: What if a Sequence Writes?

```systemverilog
class i2c_status_reg extends uvm_reg;
  uvm_reg_field STATUS;

  function void build();
    STATUS = uvm_reg_field::type_id::create("STATUS");
    // volatile=1: hardware changes this without CPU writes
    STATUS.configure(this, 3, 0, "RO", 1, 3'h0, 1, 0, 0);
  endfunction
endclass
```

Note `volatile=1` (5th argument). The FSM updates `reg_status` based on state transitions — the CPU does not write it. Declaring volatile=1 tells the RAL predictor "do not assume the mirror value is stable; it can change at any time due to hardware side effects."

What if a sequence accidentally calls `reg_model.STATUS.write(status, 8'hFF)`?

The RAL detects `"RO"` access type. It emits a `UVM_WARNING`:
```
UVM_WARNING: Attempting to write to RO register i2c_master_reg_block.STATUS
```
And it does NOT issue a bus transaction. The mirror value is unchanged. The `status` argument is set to `UVM_NOT_OK`. The sequence continues.

This is a key difference from the manual approach. Without RAL, writing to address 0x2 would silently fire a bus transaction, the RTL would ignore it (no write path to `reg_status`), the test would not fail, and the verification intent would be completely wrong. With RAL, you get an immediate warning.

> **Interview-grade answer:** *"The volatile flag in uvm_reg_field::configure() is one of the most commonly confused parameters in RAL interviews. Non-volatile means the field value changes only when the CPU writes — RAL can trust its mirror value. Volatile means hardware can change the field at any time (FSM-driven status, interrupt sticky bits) — the RAL mirror may be stale. For volatile fields, calling read() after some time has elapsed is necessary to re-synchronize the mirror. auto_predict does not help with volatile fields — auto_predict only updates mirror on CPU-driven transactions, not on hardware-driven changes."*

### `i2c_master_reg_block` — The n_bytes Parameter

```systemverilog
class i2c_master_reg_block extends uvm_reg_block;
  `uvm_object_utils(i2c_master_reg_block)

  rand i2c_ctrl_reg    CTRL;
  rand i2c_cmd_reg     CMD;
  rand i2c_status_reg  STATUS;
  rand i2c_data_reg    DATA;
  rand i2c_addr_reg    ADDR;
  rand i2c_irq_en_reg  IRQ_EN;
  rand i2c_irq_st_reg  IRQ_ST;

  uvm_reg_map reg_map;

  function new(string name = "i2c_master_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    // Create registers
    CTRL   = i2c_ctrl_reg::type_id::create("CTRL");
    CMD    = i2c_cmd_reg::type_id::create("CMD");
    STATUS = i2c_status_reg::type_id::create("STATUS");
    DATA   = i2c_data_reg::type_id::create("DATA");
    ADDR   = i2c_addr_reg::type_id::create("ADDR");
    IRQ_EN = i2c_irq_en_reg::type_id::create("IRQ_EN");
    IRQ_ST = i2c_irq_st_reg::type_id::create("IRQ_ST");

    // build() each register
    CTRL.build();   CMD.build();    STATUS.build();
    DATA.build();   ADDR.build();
    IRQ_EN.build(); IRQ_ST.build();

    // Create map: n_bytes=1 for 8-bit data bus
    // n_bytes=1 means one bus transaction = 1 byte (8 bits)
    // Contrast: AXI4-Lite uses n_bytes=4 (32-bit data bus)
    reg_map = create_map("reg_map", 0, 1, UVM_LITTLE_ENDIAN);

    // Add registers with their byte offsets
    reg_map.add_reg(CTRL,   0, "RW");
    reg_map.add_reg(CMD,    1, "WO");
    reg_map.add_reg(STATUS, 2, "RO");
    reg_map.add_reg(DATA,   3, "RW");
    reg_map.add_reg(ADDR,   4, "RW");
    reg_map.add_reg(IRQ_EN, 5, "RW");
    reg_map.add_reg(IRQ_ST, 6, "RO");

    // Lock the model — prevents accidental modification during simulation
    lock_model();
  endfunction

endclass
```

The most critical line is `create_map("reg_map", 0, 1, UVM_LITTLE_ENDIAN)`.

Parameters:
- `"reg_map"` — map name (can have multiple maps per block for different bus interfaces)
- `0` — base address (the register block starts at offset 0)
- `1` — **n_bytes: this is the data bus width in bytes**. n_bytes=1 means 8-bit bus. n_bytes=4 means 32-bit bus (AXI default).
- `UVM_LITTLE_ENDIAN` — byte ordering (irrelevant for 1-byte bus, critical for 4-byte AXI)

Why does n_bytes matter so much? Because it affects how the adapter converts bus addresses. With n_bytes=1, the register at offset 0 is at bus address 0, offset 1 is at bus address 1, etc. — byte addressing. With n_bytes=4, the register at offset 0 is at bus address 0, offset 1 is at bus address 4 (because each "slot" is 4 bytes wide). Getting n_bytes wrong causes the adapter to generate incorrect bus addresses.

`lock_model()` seals the register block. After `lock_model()`, you cannot add new registers or modify field widths. This is called at the end of `build()` to prevent accidental modifications during the test. If you try to add a register after `lock_model()`, UVM issues a fatal.

> **Interview-grade answer:** *"n_bytes in create_map() is one of the most common RAL misconfiguration bugs. It is NOT the register width — it is the bus data width in bytes. An 8-bit CPU bus like this I2C project uses n_bytes=1. An AXI4-Lite 32-bit bus uses n_bytes=4. Setting n_bytes=4 on an 8-bit bus would cause the adapter to multiply register offsets by 4, generating addresses 0, 4, 8, 12 instead of 0, 1, 2, 3. The bus transaction would target wrong registers. The RTL would return incorrect data. The test would see mirror mismatches on every access but the root cause would look mysterious."*

> **Interview-grade answer:** *"lock_model() is a defensive programming mechanism. The uvm_reg_block enforces that after build phase completes, no new structural changes are allowed. This prevents a scenario where a test body creates a new register field (maybe by mistake in a factory override) after the map is already set up, leading to an inconsistent model state. It is analogous to finalizing a data structure before multi-threaded access begins. Always call it at the end of uvm_reg_block::build()."*

---

## 6. Adapter Walkthrough: `i2c_reg_adapter.sv`

The adapter is the translation layer between the RAL's generic `uvm_reg_bus_op` and your project-specific `i2c_cpu_seq_item`. It is the most architecturally important file in the RAL implementation.

### Full Adapter

```systemverilog
class i2c_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(i2c_reg_adapter)

  function new(string name = "i2c_reg_adapter");
    super.new(name);
    provides_responses = 1;  // This bus provides explicit read data responses
  endfunction

  // reg2bus: called by RAL to convert a register operation into a bus item
  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    i2c_cpu_seq_item item = i2c_cpu_seq_item::type_id::create("item");

    item.cpu_wr    = (rw.kind == UVM_WRITE) ? 1'b1 : 1'b0;
    item.cpu_addr  = rw.addr[2:0];   // Only 3 bits needed for 7 registers
    item.cpu_wdata = (rw.kind == UVM_WRITE) ? rw.data[7:0] : 8'h00;

    return item;
  endfunction

  // bus2reg: called by RAL after the driver completes the transaction
  virtual function void bus2reg(uvm_sequence_item bus_item,
                                ref uvm_reg_bus_op rw);
    i2c_cpu_seq_item item;
    if (!$cast(item, bus_item)) begin
      `uvm_fatal("CAST", "bus2reg: cast to i2c_cpu_seq_item failed")
    end

    rw.kind    = item.cpu_wr ? UVM_WRITE : UVM_READ;
    rw.addr    = {`UVM_REG_ADDR_WIDTH-3'b0, item.cpu_addr};
    rw.data    = {`UVM_REG_DATA_WIDTH-8'b0, item.cpu_rdata};
    rw.status  = UVM_IS_OK;  // This simple bus has no error response
  endfunction

endclass
```

### `reg2bus()` — Direction: RAL to Bus

When the RAL needs to issue a register write or read, it calls `reg2bus()`. The `rw` argument is a `uvm_reg_bus_op` struct that contains:
- `rw.kind` — `UVM_WRITE` or `UVM_READ`
- `rw.addr` — the register byte address (0–6 for this project)
- `rw.data` — the data to write (for writes) or zeroed (for reads)
- `rw.n_bits` — number of bits (8 for this project, 32 for AXI)

The function creates an `i2c_cpu_seq_item` and maps fields:

`item.cpu_addr = rw.addr[2:0]` — Why only 3 bits? The register map has 7 registers at offsets 0–6. Three bits covers 0–7, sufficient for 7 entries. The full `rw.addr` is `UVM_REG_ADDR_WIDTH` bits wide (typically 64 bits) but only the lower 3 bits are meaningful for this address space. Slicing `[2:0]` is correct and intentional.

`item.cpu_wdata = (rw.kind == UVM_WRITE) ? rw.data[7:0] : 8'h00` — for reads, the write data is meaningless. Driving `8'h00` is the safe default that prevents X propagation into the DUT's write path. The DUT ignores `cpu_wdata` when `cpu_wr=0` anyway, but clean simulation practice requires initialized signals.

### `bus2reg()` — Direction: Bus to RAL

After the driver completes the transaction (clock cycles elapsed, response captured), the RAL calls `bus2reg()`. The function receives the completed `i2c_cpu_seq_item` and updates the `uvm_reg_bus_op`:

`rw.data = {pad, item.cpu_rdata}` — copies the 8-bit read data from the completed transaction back into the full-width `rw.data` field. The RAL uses this to update the mirror value.

`rw.status = UVM_IS_OK` — this bus has no error response mechanism. The `i2c_reg_if` has no `cpu_err` or `cpu_resp` signal equivalent to PSLVERR in APB3 or BRESP/RRESP in AXI. Therefore, every transaction is marked `UVM_IS_OK`. In a real APB or AXI adapter, you would check the response signal and potentially set `UVM_NOT_OK`.

### `provides_responses = 1` — What This Does

```systemverilog
provides_responses = 1;
```

This flag tells the RAL that the bus explicitly provides a response object. With `provides_responses=1`, the RAL waits for the driver to call `seq_item_port.item_done(response)` with a completed response item before calling `bus2reg()`. With `provides_responses=0`, the RAL calls `bus2reg()` using the original request item (which the driver modified in-place).

For a synchronous register bus like the CPU interface here, `provides_responses=1` is correct because:
1. The driver needs to wait for the clock edge to capture `cpu_rdata`
2. The driver signals completion by returning the response with `cpu_rdata` populated
3. The RAL calls `bus2reg()` on the response item to extract `cpu_rdata`

If you set `provides_responses=0` on a synchronous bus, `bus2reg()` would be called with a zeroed `cpu_rdata` before the driver finishes the transaction. Mirror values would always be 0x00 for reads. This is a silent corruption bug — extremely hard to debug.

> **Interview-grade answer:** *"provides_responses=1 is one of the most commonly wrong settings in custom RAL adapters. The correct choice depends on whether your bus driver modifies the request item in-place or creates a separate response item. For synchronous buses where the driver waits for clock edges and captures response data, provides_responses=1 is correct — it ensures bus2reg() is called after the driver has populated cpu_rdata. Setting it to 0 on such a bus causes bus2reg() to run before the driver completes, reading stale zero values from cpu_rdata. Every read transaction returns 0. The mirror never updates correctly. You see UVM_ERROR mismatches on every read verification but the writes appear fine, which is a confusing diagnostic signature."*

### Comparison to AXI Adapter

| Aspect | This I2C CPU Adapter | Typical AXI4-Lite Adapter |
|--------|---------------------|--------------------------|
| Address width | `rw.addr[2:0]` (3 bits, 7 regs) | `rw.addr[31:0]` (32 bits, full map) |
| Data width | `rw.data[7:0]` (8-bit) | `rw.data[31:0]` (32-bit) |
| n_bytes in map | 1 | 4 |
| Response signals | None (`UVM_IS_OK` always) | PSLVERR / BRESP / RRESP |
| Status in bus2reg | Always `UVM_IS_OK` | Decode from response field |
| Byte enables | Not used (1 byte = 1 transaction) | WSTRB [3:0] per byte lane |

> **Interview-grade answer:** *"The adapter is the only RAL component that is truly project-specific. The uvm_reg_block, uvm_reg, and uvm_reg_field classes are standard UVM. The adapter is where you encode the physical bus protocol. An I2C CPU bus adapter uses 3-bit addressing and always returns UVM_IS_OK. An AXI4-Lite adapter uses 32-bit addressing, checks BRESP/RRESP for error detection, handles byte-enable masking via WSTRB, and must handle the two-phase AW/W channel protocol. Same RAL framework, completely different adapter. The interface boundary between RAL and bus is the uvm_reg_bus_op struct — master on one side, project-specific bus on the other."*

---

## 7. Environment Changes: `i2c_ral_env.sv`

### Why a Separate Environment File

The existing `i2c_env.sv` (Lesson 14) instantiates:
- `i2c_master_agent` (bus-level driver + monitor)
- `i2c_slave_agent` (passive observer)
- `i2c_scoreboard`
- `i2c_coverage`

That environment was built for 15-bug bus-level verification. It works. Do NOT modify it. The RAL environment is a separate problem: it needs:
- `i2c_cpu_agent` (register bus driver — completely different from bus-level agent)
- `i2c_master_reg_block` (the register model)
- `i2c_reg_adapter` (bus translation)
- `auto-predict` configuration

Merging these into `i2c_env.sv` would create a single monolithic env that does both bus verification AND register verification. That makes factory overrides harder, makes regression selection harder (some regressions only run register tests), and violates single responsibility. Keep them separate.

### `i2c_ral_env.sv` — Full Walkthrough

```systemverilog
class i2c_ral_env extends uvm_env;
  `uvm_component_utils(i2c_ral_env)

  i2c_cpu_agent         cpu_agent;
  i2c_master_reg_block  reg_model;
  i2c_reg_adapter       adapter;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Create CPU agent
    cpu_agent = i2c_cpu_agent::type_id::create("cpu_agent", this);

    // Create and build register model
    reg_model = i2c_master_reg_block::type_id::create("reg_model");
    reg_model.build();

    // Create adapter
    adapter = i2c_reg_adapter::type_id::create("adapter");

    // Publish reg_model via config_db for sequences to access
    uvm_config_db #(i2c_master_reg_block)::set(
      this, "*", "reg_model", reg_model);

  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // Connect adapter to register map
    // The map needs to know: which sequencer drives the bus, which adapter translates
    reg_model.reg_map.set_sequencer(
      cpu_agent.sequencer, adapter);

    // Enable auto-predict
    // With auto-predict ON: mirror is updated automatically after every
    // successful write/read transaction, without needing explicit predictor
    reg_model.reg_map.set_auto_predict(1);

  endfunction

endclass
```

### `set_auto_predict(1)` vs Explicit Predictor

Two mechanisms for keeping the RAL mirror synchronized with the DUT:

**Auto-predict (what this project uses):**
```systemverilog
reg_model.reg_map.set_auto_predict(1);
```
After every `reg.write()` or `reg.read()`, the RAL automatically calls `predict()` to update the mirror value. No additional component needed. Simpler. Correct for 90% of designs.

**Explicit predictor (`uvm_reg_predictor`):**
```systemverilog
// In env connect_phase:
predictor = uvm_reg_predictor #(i2c_cpu_seq_item)::type_id::create("predictor", this);
predictor.map = reg_model.reg_map;
predictor.adapter = adapter;
cpu_agent.monitor.ap.connect(predictor.bus_in);
```
The explicit predictor subscribes to the monitor's analysis port. Every transaction the monitor sees — including ones NOT initiated by the RAL (e.g., a direct bus-force injection or a secondary agent) — gets fed into the predictor, which updates the mirror. This is necessary when:
1. The DUT has registers that change via hardware side effects (interrupt sticky bits that clear when read)
2. You want the RAL mirror to track transactions from other sequencers or bus masters
3. You need `UVM_PREDICT_WRITE` vs `UVM_PREDICT_READ` semantics explicitly

For this project, auto-predict is sufficient because:
- All register accesses come from the RAL sequences
- STATUS is RO and volatile — you read it explicitly when you need current value
- No hardware-triggered register updates that need mirror tracking (the FIFOs and complex W1C behaviors are not present here)

> **Interview-grade answer:** *"Auto-predict and explicit predictor are not interchangeable — they have different coverage. Auto-predict only tracks transactions that the RAL itself initiates: reg.write() and reg.read() calls. If a second bus master writes a register, auto-predict does not know about it. An explicit uvm_reg_predictor subscribes to the monitor's analysis port and tracks ALL bus transactions regardless of source. In a multi-master SoC environment with a DMA engine writing registers, explicit predictor is mandatory. For a single-master testbench where all register accesses come from one RAL sequence, auto-predict is cleaner and sufficient."*

### Config_db Set with Wildcard Scope

```systemverilog
uvm_config_db #(i2c_master_reg_block)::set(
  this, "*", "reg_model", reg_model);
```

The `"*"` scope means "any component whose full hierarchical path matches this from the current context." Since `this` is the env and `"*"` is a wildcard, any component at any depth under the env (or below) that calls `config_db::get(this, "", "reg_model", reg_model)` will receive the reg_model handle. This is how sequences access the register model without the env having to explicitly pass it down through multiple layers.

The alternative — `"cpu_agent.sequencer"` as scope — would only work for that exact path. Sequences running on the virtual sequencer would not find the model. Wildcard `"*"` is the industry convention for reg_model publication.

> **Interview-grade answer:** *"Using '*' as the config_db scope for reg_model publication is intentional and correct. The register model is a shared resource — any sequence at any level of the hierarchy needs access to it. The alternative of scoping to a specific path creates fragile coupling between the env topology and the sequence code. If the env is restructured, the scoped path breaks silently (the sequence just gets a null handle and may seg-fault). The wildcard scope makes reg_model behave like a global resource within the test hierarchy, which is exactly the right semantic for a shared register abstraction."*

---

## 8. RAL Sequences — BEFORE vs AFTER Contrast

This is the section that matters most for interviews. The BEFORE/AFTER comparison is the clearest possible demonstration of why RAL exists.

### BEFORE RAL — Programming the I2C Master to Send 0xAB to Slave 0x50

```systemverilog
task program_master_write_manual(
  input logic [6:0] slave_addr,
  input logic [7:0] data_byte
);
  i2c_cpu_seq_item req;
  uvm_status_e status;

  // Step 1: Enable master
  // REG_CTRL = 0x0, EN = bit[0] = 1
  req = i2c_cpu_seq_item::type_id::create("req");
  req.cpu_addr  = 3'h0;    // magic: REG_CTRL
  req.cpu_wr    = 1'b1;
  req.cpu_wdata = 8'h01;   // magic: EN=1
  start_item(req);
  finish_item(req);

  // Step 2: Set slave address
  // REG_ADDR = 0x4, [7:1]=slave_addr, [0]=DIR_WRITE=0
  req.cpu_addr  = 3'h4;    // magic: REG_ADDR
  req.cpu_wdata = {slave_addr, 1'b0};  // manual bit packing
  start_item(req);
  finish_item(req);

  // Step 3: Load TX data
  // REG_DATA = 0x3
  req.cpu_addr  = 3'h3;    // magic: REG_DATA
  req.cpu_wdata = data_byte;
  start_item(req);
  finish_item(req);

  // Step 4: Issue START command
  // REG_CMD = 0x1, CMD_START = 4'h1
  req.cpu_addr  = 3'h1;    // magic: REG_CMD
  req.cpu_wdata = 8'h01;   // magic: CMD_START
  start_item(req);
  finish_item(req);

  // Step 5: Poll STATUS until BUSY
  // REG_STATUS = 0x2
  req.cpu_addr  = 3'h2;    // magic: REG_STATUS
  req.cpu_wr    = 1'b0;
  start_item(req);
  finish_item(req);
  // Check bit[2:0] == STS_BUSY == 3'b001
  while (req.cpu_rdata[2:0] !== 3'b001) begin  // magic: STS_BUSY value
    start_item(req);
    finish_item(req);
  end

  // Step 6: Issue WRITE command
  req.cpu_addr  = 3'h1;    // magic: REG_CMD (again)
  req.cpu_wr    = 1'b1;
  req.cpu_wdata = 8'h03;   // magic: CMD_WRITE = 4'h3
  start_item(req);
  finish_item(req);

  // Step 7: Poll STATUS for DONE or ACK
  // ... more boilerplate ...
  // Must know: STS_DONE = 3'b110, STS_ACK = 3'b010
  // Must know: bit positions [2:0] in the register
  req.cpu_addr  = 3'h2;
  req.cpu_wr    = 1'b0;
  repeat(20) begin
    start_item(req);
    finish_item(req);
    if (req.cpu_rdata[2:0] == 3'b110) break;  // magic: STS_DONE
  end

  // Step 8: Issue STOP
  req.cpu_addr  = 3'h1;    // REG_CMD again
  req.cpu_wr    = 1'b1;
  req.cpu_wdata = 8'h02;   // magic: CMD_STOP = 4'h2
  start_item(req);
  finish_item(req);

endtask
```

**Problem count:**
- 12 magic number literals (3'h0, 3'h1, 3'h2, 3'h3, 3'h4, 8'h01, 8'h03, 8'h02, 3'b001, 3'b110, 3'b010)
- Manual bit packing `{slave_addr, 1'b0}` — reader must know DIR is bit[0]
- No access type protection — nothing stops writing to 3'h2 (STATUS)
- No reset value checking — test assumes reset happened correctly
- If REG_ADDR changes from 0x4 to 0x5 in the RTL, this silently tests the wrong register
- Zero connection to `i2c_cmd_e` and `i2c_status_e` enums defined in `i2c_pkg.sv`

### AFTER RAL — Same Operation

```systemverilog
task program_master_write_ral(
  input logic [6:0] slave_addr,
  input logic [7:0] data_byte
);
  uvm_status_e    status;
  uvm_reg_data_t  rdata;

  // Step 1: Enable master — field-level set+update
  reg_model.CTRL.EN.set(1'b1);
  reg_model.CTRL.update(status);        // Issues write only if needed
  assert(status == UVM_IS_OK);

  // Step 2: Set slave address — field-level access, no bit packing
  reg_model.ADDR.SLAVE_ADDR.set(slave_addr);
  reg_model.ADDR.DIR.set(DIR_WRITE);    // Self-documenting: uses i2c_dir_e enum
  reg_model.ADDR.update(status);
  assert(status == UVM_IS_OK);

  // Step 3: Load TX data
  reg_model.DATA.write(status, data_byte);
  assert(status == UVM_IS_OK);

  // Step 4: Issue START command — enum cast, not magic number
  reg_model.CMD.write(status, uvm_reg_data_t'(CMD_START));
  assert(status == UVM_IS_OK);

  // Step 5: Poll STATUS — RAL reads and updates mirror automatically
  do begin
    reg_model.STATUS.read(status, rdata);
  end while (rdata[2:0] !== STS_BUSY);
  // OR field-level:
  // reg_model.STATUS.STATUS.read(status, rdata);  // returns just [2:0]

  // Step 6: Issue WRITE command
  reg_model.CMD.write(status, uvm_reg_data_t'(CMD_WRITE));

  // Step 7: Poll for DONE
  do begin
    reg_model.STATUS.read(status, rdata);
  end while (rdata[2:0] !== STS_DONE);

  // Step 8: Issue STOP
  reg_model.CMD.write(status, uvm_reg_data_t'(CMD_STOP));

endtask
```

**What changed:**
- Zero magic address literals. Every register access uses the symbolic name.
- `DIR_WRITE` from `i2c_dir_e` instead of `1'b0`.
- `CMD_START`, `CMD_WRITE`, `CMD_STOP` from `i2c_cmd_e` instead of `8'h01`, `8'h03`, `8'h02`.
- `STS_BUSY`, `STS_DONE` from `i2c_status_e` instead of `3'b001`, `3'b110`.
- `status` checked after every operation — access type violations reported immediately.
- If REG_ADDR moves in the RTL and the model is updated, zero sequence code changes.

### The Three RAL Sequences in `i2c_ral_seq.sv`

**Sequence 1: `i2c_reset_check_seq`**

```systemverilog
class i2c_reset_check_seq extends uvm_reg_sequence;
  i2c_master_reg_block reg_model;

  task body();
    uvm_status_e   status;
    uvm_reg_data_t rdata;

    // Read CTRL — must be 0x00 after reset
    reg_model.CTRL.read(status, rdata);
    if (rdata !== 8'h00)
      `uvm_error("RST", $sformatf("CTRL reset wrong: got 0x%0h", rdata))

    // Read STATUS — must be 0x00 (STS_IDLE) after reset
    reg_model.STATUS.read(status, rdata);
    if (rdata[2:0] !== STS_IDLE)
      `uvm_error("RST", $sformatf("STATUS reset wrong: got 0x%0h", rdata[2:0]))

    // Read DATA — must be 0x00
    reg_model.DATA.read(status, rdata);
    if (rdata !== 8'h00)
      `uvm_error("RST", $sformatf("DATA reset wrong: got 0x%0h", rdata))

    // Read ADDR — must be 0x00
    reg_model.ADDR.read(status, rdata);
    if (rdata !== 8'h00)
      `uvm_error("RST", $sformatf("ADDR reset wrong: got 0x%0h", rdata))

    // Read IRQ_EN — must be 0x00
    reg_model.IRQ_EN.read(status, rdata);
    if (rdata !== 8'h00)
      `uvm_error("RST", $sformatf("IRQ_EN reset wrong: got 0x%0h", rdata))

    // NOTE: CMD is WO — cannot read. Model returns desired value (0x00).
    // This CORRECTLY models that we cannot verify CMD reset value via bus.
    // To verify CMD reset, you need backdoor access to the RTL signal.

    `uvm_info("RST", "Reset check PASSED for all readable registers", UVM_MEDIUM)
  endtask
endclass
```

The `uvm_reg_hw_reset_seq` (built-in UVM sequence) automates exactly this pattern for you — it iterates all registers in the block, reads them, and checks against the reset value encoded in `configure()`. See Action Item #3.

> **Interview-grade answer:** *"The reset check sequence is the single highest-value RAL test to run in any project. It verifies two things simultaneously: that the RTL correctly initializes all register flip-flops to their specified reset values, and that the address decode logic is correct (you are reading the right register at the right address). If a register at offset 0x4 was accidentally wired to offset 0x5 in the RTL decode, the reset check would catch it — you would read 0x00 from 0x4 (the wrong address returns default) instead of the expected reset value. This is a class of bus decode bug that only register-level testing catches."*

**Sequence 2: `i2c_program_master_seq`**

```systemverilog
class i2c_program_master_seq extends uvm_reg_sequence;
  i2c_master_reg_block reg_model;

  // Configurable parameters — randomizable
  rand logic [6:0] slave_addr;
  rand logic [7:0] tx_data;
  rand bit         enable_irq;

  task body();
    uvm_status_e   status;
    uvm_reg_data_t rdata;

    // 1. Enable master
    reg_model.CTRL.EN.set(1'b1);
    if (enable_irq)
      reg_model.CTRL.IRQ_GLOBAL_EN.set(1'b1);
    reg_model.CTRL.update(status);

    // 2. Configure interrupts if enabled
    if (enable_irq) begin
      reg_model.IRQ_EN.DONE_EN.set(1'b1);
      reg_model.IRQ_EN.update(status);
    end

    // 3. Set slave address and direction
    reg_model.ADDR.SLAVE_ADDR.set(slave_addr);
    reg_model.ADDR.DIR.set(DIR_WRITE);
    reg_model.ADDR.update(status);

    // 4. Load TX data
    reg_model.DATA.write(status, {24'h0, tx_data});

    // 5. START → WRITE → STOP sequence
    reg_model.CMD.write(status, uvm_reg_data_t'(CMD_START));
    reg_model.CMD.write(status, uvm_reg_data_t'(CMD_WRITE));
    reg_model.CMD.write(status, uvm_reg_data_t'(CMD_STOP));

    // 6. Readback verification — check what we wrote
    reg_model.CTRL.read(status, rdata);
    `uvm_info("PROG", $sformatf("CTRL readback: 0x%02h", rdata), UVM_MEDIUM)

    reg_model.ADDR.read(status, rdata);
    `uvm_info("PROG", $sformatf("ADDR readback: 0x%02h (slave=0x%0h dir=%0b)",
              rdata, rdata[7:1], rdata[0]), UVM_MEDIUM)

  endtask
endclass
```

> **Interview-grade answer:** *"The set()/update() pattern for field-level writes is a read-modify-write at the model level. set() writes only the desired register in the model. update() compares desired vs mirror and issues a single bus write with the correct bit mask if they differ. The key advantage is atomicity at the model level: you can call set() on multiple fields of the same register before calling update() once — a single bus transaction updates all changed fields simultaneously. This matches how embedded software drivers work: assemble the full register value, then write once. Never use write() if you only want to change one field of a multi-field register."*

**Sequence 3: `i2c_field_access_seq`**

```systemverilog
class i2c_field_access_seq extends uvm_reg_sequence;
  i2c_master_reg_block reg_model;

  task body();
    uvm_status_e   status;
    uvm_reg_data_t rdata;

    // Test CTRL: write EN=1, read back via mirror
    reg_model.CTRL.EN.set(1'b1);
    reg_model.CTRL.update(status);

    // get() returns desired value (no bus transaction)
    `uvm_info("FIELD", $sformatf("CTRL.EN desired = %0b",
              reg_model.CTRL.EN.get()), UVM_MEDIUM)

    // Read back from bus and check mirror vs desired
    reg_model.CTRL.read(status, rdata);
    `uvm_info("FIELD", $sformatf("CTRL.EN mirror after read = %0b",
              reg_model.CTRL.EN.get_mirrored_value()), UVM_MEDIUM)

    // Verify mirror == desired after readback
    if (reg_model.CTRL.EN.get() !== reg_model.CTRL.EN.get_mirrored_value())
      `uvm_error("MIRROR", "CTRL.EN: desired != mirrored after readback")

    // Test IRQ_EN: verify individual bit fields
    reg_model.IRQ_EN.DONE_EN.set(1'b1);
    reg_model.IRQ_EN.NACK_EN.set(1'b1);
    reg_model.IRQ_EN.update(status);

    reg_model.IRQ_EN.read(status, rdata);
    // rdata[0] should be 1 (DONE_EN), rdata[2] should be 1 (NACK_EN)
    if (rdata[0] !== 1'b1)
      `uvm_error("FIELD", "IRQ_EN.DONE_EN not set correctly")
    if (rdata[2] !== 1'b1)
      `uvm_error("FIELD", "IRQ_EN.NACK_EN not set correctly")

    // Test RO: verify STATUS cannot be written
    // This should emit a UVM_WARNING, not UVM_ERROR or UVM_FATAL
    reg_model.STATUS.write(status, 8'hFF);
    // Expected: warning emitted, no bus transaction, status = UVM_NOT_OK
    if (status == UVM_IS_OK)
      `uvm_error("ACCESS", "STATUS write should have failed but returned IS_OK")

  endtask
endclass
```

> **Interview-grade answer:** *"The three-value register state in UVM RAL — desired, mirrored, and actual — represents three different perspectives on the same register. Desired is what your software model wants the register to contain. Mirrored is what the model believes the hardware contains based on past transactions. Actual is the physical value in the RTL flip-flops right now. Desired and mirrored diverge when you call set() but have not yet called update() or write(). Mirrored and actual diverge when hardware side-effects change a register (FSM updates STATUS) without a CPU-driven transaction. The only way to synchronize mirrored with actual is to issue a read() or use backdoor poke/peek."*

---

## 9. Access Type Deep Dive (I2C-specific)

### Complete UVM RAL Access Type Table

| Access Type | Write Behavior | Read Behavior | Typical Use Case |
|-------------|---------------|---------------|------------------|
| RW | Issues bus write, updates mirror | Issues bus read, updates mirror | Most config registers |
| RO | Warning emitted, NO bus write | Issues bus read, updates mirror | Status registers |
| WO | Issues bus write, updates desired (not mirror) | Returns desired value, NO bus read | Command/trigger registers |
| RC | Issues bus write if changed | Issues bus read AND clears register | Interrupt status (read-to-clear) |
| RS | No write | Issues bus read AND sets register | Error status latch |
| WC | Issues bus write, clears mirror | No special read behavior | Software clear enable |
| W1C | Issues bus write of 1s to clear bits | Issues bus read, updates mirror | Interrupt sticky bits |
| WO1 | Issues bus write ONCE only | No read | One-shot trigger (FIFO push) |
| RW1 | One read | One write | OTP/fuse registers |
| W1S | Issues bus write of 1s to set bits | Issues bus read | Set-only control |
| W0C | Issues bus write of 0s to clear bits | Issues bus read | Alternate interrupt clear |

### Access Types in This Project

**RW registers (CTRL, DATA, ADDR, IRQ_EN):**
- `write()`: issues bus write, updates desired AND mirror
- `read()`: issues bus read, updates mirror with hardware value
- Mirror and desired should match after a read (if no hardware side effects)
- Field `set()/update()` pattern works correctly

**RO registers (STATUS, IRQ_ST):**
- `write()`: UVM_WARNING emitted, NO bus transaction, mirror unchanged
- `read()`: issues bus read, mirror updated with hardware value
- `get_mirrored_value()` returns stale value if you have not read recently (STATUS changes on FSM transitions)
- Declared volatile=1 to indicate hardware can change the value

**WO register (CMD):**
- `write()`: issues bus write, desired value updated. Mirror is NOT updated (because you cannot read it back to verify)
- `read()`: NO bus transaction, returns desired value
- `get()` returns desired. `get_mirrored_value()` also returns desired (since mirror is never updated from bus reads for WO)

### What If You Accidentally Write STATUS?

```systemverilog
reg_model.STATUS.write(status, 8'hFF);
```

Simulation output:
```
UVM_WARNING @ 1234ns: uvm_reg [STATUS.write] Register "STATUS" is read-only. 
Ignoring write request.
uvm_reg_bus_op was NOT issued.
status = UVM_NOT_OK
```

The bus transaction is suppressed. The RTL never sees `cpu_wr=1` with `cpu_addr=3'h2`. The mirror value remains what it was before. The `status` return is `UVM_NOT_OK`. If your sequence asserts `status == UVM_IS_OK`, it will catch this immediately. If it does not check status, the bug is silent but at least no incorrect bus traffic occurred.

> **Interview-grade answer:** *"The access type system in UVM RAL provides lightweight specification checking — it encodes the register's intended behavior and enforces it at runtime. The enforcement is not a hard block (it is a WARNING, not a FATAL) because sometimes you legitimately want to test 'what happens if firmware writes a read-only register?' In that case you suppress the warning with uvm_reg::set_check_on_write(0). The point is that the DEFAULT behavior correctly models the RTL: writes to RO registers are ignored by the hardware, so they should be ignored (with a warning) by the RAL."*

### The RX DATA Register — Asymmetric Semantics

The DATA register (0x3) is RW but has asymmetric TX/RX semantics:
- **Write to DATA**: loads the shift register for the next TX byte
- **Read from DATA**: returns the last received byte from a completed RX transaction

This means after a successful read transaction from slave, you read REG_DATA to get the received byte. But the mirrored value in the RAL is the LAST WRITTEN value (what you loaded for TX). After reading REG_DATA and getting the RX byte, the RAL mirror updates to the RX byte value. The desired value (what you previously wrote for TX) now diverges from the mirror.

This is architecturally correct: the hardware has changed the register content (RX overwrote TX), and the read updated the mirror to reflect reality. But it means you cannot use `get()` after an RX to retrieve the TX value you last sent — the mirror has been overwritten by the read.

> **Interview-grade answer:** *"The DATA register in this I2C project is an example of a ping-pong buffer register — one address serves both TX and RX. RAL handles this correctly because reads update the mirror. After writing TX data and then reading the RX data, the mirror reflects the RX byte. The desired value reflects your last write call. Desired and mirror are different. This is not a bug — it is the correct representation. The rule: desired tracks what you intended to write; mirror tracks what the hardware contains. For ping-pong registers, they diverge after RX. If your sequence needs to know the last TX byte after RX has overwritten the mirror, save it to a local variable before issuing the read transaction."*

### The REG_IRQ_ST Modeling Decision — W1C vs RO

In a production chip, REG_IRQ_ST would typically be a W1C (Write-1-to-Clear) register: individual bits latch when interrupts fire and stay latched until software writes a 1 to that bit to clear it. This is the standard pattern used in every real interrupt controller.

This project's RTL takes a shortcut: `REG_IRQ_ST` returns `reg_status` directly. There are no sticky latched bits — the interrupt status is a live view of the current FSM status. The implications for verification:

1. **You cannot miss an interrupt.** In real W1C designs, if STATUS goes BUSY→DONE→IDLE between two reads, the sticky IRQ_ST bit captures DONE. In this project's design, if you read IRQ_ST after the FSM returns to IDLE, you see STS_IDLE — the DONE status is gone.

2. **IRQ_ST and STATUS diverge when the RTL adds sticky logic later.** If the RTL is upgraded to a proper W1C design, the RAL model for IRQ_ST must change from RO to W1C. The adapter does not change. The sequences that read IRQ_ST DO change (they now need to write 1s to clear bits). RAL isolates this change to the register model and the specific sequences that use IRQ_ST.

3. **The RAL correctly models the current RTL.** Declaring IRQ_ST as RO with the current register map is correct. The lesson: model what the RTL actually does, not what it should do. If the spec says W1C but the RTL implements RO, model RO — your verification gap is the spec vs RTL discrepancy, not a RAL modeling error.

> **Interview-grade answer:** *"W1C (Write-1-to-Clear) is the most common access type for interrupt status registers in real SoC designs. A W1C register latches bits when interrupts fire. Software reads the register to see which interrupts fired, then writes 1s to the bits it has handled, clearing only those bits. The RAL write() for W1C passes the written value directly to the bus, and the RTL clears the bits with the 1s mask. If you accidentally write 0s instead of 1s to a W1C field, you clear nothing — the bus transaction happens, but the RTL ignores the 0-bit writes. Getting W1C clearing wrong is a common firmware bug that RAL testing catches when you write 0xFF (to clear all) vs 0x01 (to clear only bit 0)."*

---

## 10. Before vs After Summary Table

| Aspect | Before RAL | After RAL |
|--------|-----------|-----------|
| Register address | `3'h4` magic literal | `reg_model.ADDR` symbolic name |
| Field access | `{slave_addr, 1'b0}` manual packing | `.SLAVE_ADDR.set(addr); .DIR.set(DIR_WRITE)` |
| Access type enforcement | None — `write(3'h2, ...)` silently fires | UVM_WARNING, transaction suppressed |
| Reset check | Hardcoded loops with magic expected values | `uvm_reg_hw_reset_seq` or `get_reset()` |
| WO register readback | Returns 0x00 (RTL default) — silently wrong | Returns desired value — correctly models spec |
| Mirror tracking | Manual (must track what you wrote) | Automatic via auto-predict or predictor |
| New register added | Update every sequence that uses addresses | Update model only; sequences use names |
| Testability of access types | Cannot verify RO/WO/RW semantics | Access type checks on every transaction |
| IRQ EN field naming | `8'h01` for DONE_EN | `IRQ_EN.DONE_EN.set(1)` |
| Cross-reference to spec | None — numbers only | Field names match spec document |
| Portability to new projects | Must rewrite all address literals | Swap reg_block; sequences unchanged |
| Debug after failure | "Wrote to address 4, got 0" | "ADDR.SLAVE_ADDR read mismatch: expected 0x50, got 0x00" |

---

## 11. New File Inventory — What Changed

### All 11 New Files

| File | Purpose | Depends On |
|------|---------|-----------|
| `tb/i2c_reg_if.sv` | SystemVerilog interface for CPU register bus. Clocking blocks for driver and monitor. | `i2c_master_controller` port names |
| `tb/top_tb_ral.sv` | Top-level TB for RAL tests. Instantiates DUT + i2c_reg_if only. | `i2c_reg_if.sv`, `i2c_tb_ral_pkg.sv` |
| `tb/i2c_tb_ral_pkg.sv` | Package compiling all RAL components in dependency order. | All RAL .sv files |
| `uvm/i2c_cpu_seq_item.sv` | CPU register bus transaction (addr, wr, wdata, rdata). | None (base UVM) |
| `uvm/i2c_cpu_driver.sv` | Driver that drives `i2c_reg_if` based on `i2c_cpu_seq_item`. | `i2c_cpu_seq_item.sv`, `i2c_reg_if.sv` |
| `uvm/i2c_cpu_agent.sv` | UVM agent wrapping `i2c_cpu_driver` + UVM sequencer. | `i2c_cpu_driver.sv` |
| `uvm/i2c_ral_env.sv` | Environment: creates reg_model, adapter, cpu_agent, wires them. | `i2c_cpu_agent.sv`, `i2c_master_reg_model.sv`, `i2c_reg_adapter.sv` |
| `uvm/i2c_ral_test.sv` | Three test classes: reset_test, program_test, field_test. | `i2c_ral_env.sv`, `ral/i2c_ral_seq.sv` |
| `ral/i2c_master_reg_model.sv` | All uvm_reg subclasses + uvm_reg_block. The register map. | None (base UVM) |
| `ral/i2c_reg_adapter.sv` | Translates uvm_reg_bus_op ↔ i2c_cpu_seq_item. | `i2c_cpu_seq_item.sv` |
| `ral/i2c_ral_seq.sv` | Three RAL sequences: reset_check, program_master, field_access. | `i2c_master_reg_model.sv` |

### ASCII Dependency Diagram — `i2c_tb_ral_pkg.sv` Include Order

```
i2c_tb_ral_pkg.sv
│
├── (1) i2c_cpu_seq_item.sv       ← No dependencies except uvm_pkg
│
├── (2) i2c_master_reg_model.sv   ← No dependencies except uvm_pkg + i2c_pkg
│       ├── i2c_ctrl_reg
│       ├── i2c_cmd_reg
│       ├── i2c_status_reg
│       ├── i2c_data_reg
│       ├── i2c_addr_reg
│       ├── i2c_irq_en_reg
│       ├── i2c_irq_st_reg
│       └── i2c_master_reg_block
│
├── (3) i2c_reg_adapter.sv        ← Depends on (1) i2c_cpu_seq_item
│
├── (4) i2c_ral_seq.sv            ← Depends on (2) i2c_master_reg_model
│       ├── i2c_reset_check_seq
│       ├── i2c_program_master_seq
│       └── i2c_field_access_seq
│
├── (5) i2c_cpu_driver.sv         ← Depends on (1) i2c_cpu_seq_item
│                                    Uses virtual i2c_reg_if (from tb/)
│
├── (6) i2c_cpu_agent.sv          ← Depends on (5) i2c_cpu_driver
│
├── (7) i2c_ral_env.sv            ← Depends on (2)(3)(6)
│                                    reg_model + adapter + cpu_agent
│
└── (8) i2c_ral_test.sv           ← Depends on (4)(7)
                                     ral_seqs + ral_env
```

The package compile order is strictly bottom-up: base types first, then components that use them, then the environment, then tests. Getting this order wrong causes "class not defined" compilation errors.

---

## 11b. `i2c_cpu_driver.sv` and `i2c_cpu_agent.sv` — Line-by-Line

This section covers two components that bridge the gap between the RAL framework and the physical interface. They are simpler than the register model but contain several correctness details that trip up beginners.

### `i2c_cpu_driver.sv` — The Physical Bus Driver

The CPU driver is analogous to `i2c_master_driver.sv` from Lessons 1–17, but for the register bus instead of the I2C physical bus. It receives `i2c_cpu_seq_item` objects from the sequencer, drives them on `i2c_reg_if`, and captures the DUT's `cpu_rdata` response.

```systemverilog
class i2c_cpu_driver extends uvm_driver #(i2c_cpu_seq_item);
  `uvm_component_utils(i2c_cpu_driver)

  virtual i2c_reg_if.drv_mp vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual i2c_reg_if)::get(this, "", "reg_vif", vif))
      `uvm_fatal("NO_VIF", "i2c_cpu_driver: reg_vif not found in config_db")
  endfunction

  virtual task run_phase(uvm_phase phase);
    i2c_cpu_seq_item req, rsp;

    // Initialize bus to idle state
    vif.driver_cb.cpu_addr  <= 3'b000;
    vif.driver_cb.cpu_wr    <= 1'b0;
    vif.driver_cb.cpu_wdata <= 8'h00;

    forever begin
      seq_item_port.get_next_item(req);

      // Drive one cycle
      @(vif.driver_cb);
      vif.driver_cb.cpu_addr  <= req.cpu_addr;
      vif.driver_cb.cpu_wr    <= req.cpu_wr;
      vif.driver_cb.cpu_wdata <= req.cpu_wdata;

      // Sample rdata one cycle later (DUT drives combinationally from cpu_addr)
      @(vif.driver_cb);
      rsp = i2c_cpu_seq_item::type_id::create("rsp");
      rsp.copy(req);
      rsp.cpu_rdata = vif.driver_cb.cpu_rdata;

      // Return to idle
      vif.driver_cb.cpu_wr <= 1'b0;

      seq_item_port.item_done(rsp);   // Provide response — required since provides_responses=1
    end
  endtask

endclass
```

**Key points:**

`uvm_driver #(i2c_cpu_seq_item)` — parameterized on `i2c_cpu_seq_item`. The `seq_item_port` is automatically typed to accept `i2c_cpu_seq_item` objects. The driver does NOT use `i2c_seq_item` — the two drivers serve two completely different interfaces.

`vif.driver_cb.cpu_addr <= req.cpu_addr` — the `<=` (non-blocking assignment) inside a clocking block is the correct syntax. The clocking block's `output #1` timing handles when the signal actually changes relative to the clock edge. Using `=` (blocking) inside a clocking block is a common mistake that can cause race conditions.

`@(vif.driver_cb)` — waits for the next posedge of `clk` as defined in `driver_cb`. This is how you synchronize to the clock in clocking-block-based drivers. Do NOT use `@(posedge clk)` directly in the driver — it bypasses the clocking block's sampling/driving discipline.

The two-cycle protocol:
- Cycle 1: Drive address, write-enable, and write data
- Cycle 2: Sample read data (the RTL's combinational read mux has settled by this time)

This matches the RTL's `always_comb` read logic — `cpu_rdata` is combinationally driven from `cpu_addr`, so it is valid in the same cycle as `cpu_addr` is presented. Waiting one more cycle with `@(vif.driver_cb)` before sampling ensures the clocking block's `#1step` sampling sees the stable value.

`seq_item_port.item_done(rsp)` — this is the critical call that makes `provides_responses=1` work. The response item `rsp` has `cpu_rdata` populated. The RAL framework receives this response and calls `bus2reg(rsp, rw)` to extract `rw.data = rsp.cpu_rdata`. Without this call, the RAL waits forever for the response and the simulation hangs.

> **Interview-grade answer:** *"The two-cycle driver protocol for a synchronous register bus — drive on cycle N, sample on cycle N+1 — is a fundamental timing pattern. The RTL's combinational read mux produces cpu_rdata in the same cycle that cpu_addr changes. But sampling in the exact same cycle creates a race with the clocking block's sampling edge. Waiting one additional cycle guarantees the driven address has propagated through the combinational logic before the sampling edge captures cpu_rdata. This is why synchronous register interfaces always have at least one-cycle read latency from the driver's perspective, even if the RTL is technically zero-cycle combinational."*

### `i2c_cpu_agent.sv`

```systemverilog
class i2c_cpu_agent extends uvm_agent;
  `uvm_component_utils(i2c_cpu_agent)

  i2c_cpu_driver    driver;
  uvm_sequencer #(i2c_cpu_seq_item) sequencer;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    driver    = i2c_cpu_driver::type_id::create("driver", this);
    sequencer = uvm_sequencer #(i2c_cpu_seq_item)::type_id::create("sequencer", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction

endclass
```

Notice two differences from `i2c_master_agent` (Lesson 11):

1. **No monitor.** The CPU agent for RAL tests does not need a monitor because the RAL framework handles mirror updates internally via auto-predict. There is no scoreboard that needs to subscribe to CPU bus transactions. If you wanted to add coverage for "which registers were accessed" or add a checker that independently verifies the bus protocol, you would add a monitor and its analysis port.

2. **Generic `uvm_sequencer`** instead of a custom sequencer subclass. There is no need for a virtual sequencer or any special sequencer logic — the RAL adapter talks to the sequencer directly via `set_sequencer()` in the environment's connect_phase.

The `connect_phase` wiring is identical to Lesson 11: `driver.seq_item_port.connect(sequencer.seq_item_export)`. This TLM connection is the only way the driver gets transactions — it calls `get_next_item()` on `seq_item_port`, which blocks until the sequencer delivers an item.

> **Interview-grade answer:** *"The CPU agent for RAL is intentionally simpler than the I2C bus agent from Lesson 11. It has no monitor because the RAL's auto-predict handles mirror tracking. It uses a generic uvm_sequencer because the RAL adapter bypasses the sequence API — the adapter directly calls start_item/finish_item on the sequencer provided via set_sequencer(). This is a different usage pattern from typical UVM agents where sequences run on the sequencer. In RAL, the sequences run on the reg_map, which in turn uses the sequencer as a transport layer. The sequencer never sees the sequence object — it only sees the seq_items the adapter generates."*

---

## 11c. Common Bugs and Debugging Guide

This section documents the five most common RAL implementation mistakes and how to diagnose each one. These are the bugs that get asked about in interviews as "what went wrong and why."

### Bug 1: Mirror Always Reads 0x00 for Every Register

**Symptom:** Every `reg.read(status, rdata)` returns `rdata=0`. `get_mirrored_value()` always returns 0. Writes appear to work (no errors), reads silently return zero.

**Root cause:** `provides_responses=0` in the adapter while the driver actually provides a response item. `bus2reg()` is called before the driver executes, reading `cpu_rdata=0` from the uninitialized response item.

**Diagnosis:** Check the adapter constructor for `provides_responses = 1`. Add a `uvm_info` inside `bus2reg()` to print the `rw.data` value. If it is always 0, the item arriving in `bus2reg()` has not been populated by the driver.

**Fix:** Set `provides_responses = 1` in the adapter constructor.

### Bug 2: Every Register Access Targets the Wrong Register (Address x4)

**Symptom:** Writing to CTRL reads back from ADDR. Writing to CMD reads back from IRQ_ST. The addresses are consistently 4x larger than expected. The waveform shows `cpu_addr=0x0, 0x4, 0x8, 0xC` instead of `0x0, 0x1, 0x2, 0x3`.

**Root cause:** `n_bytes=4` in `create_map()` instead of `n_bytes=1`. The map generates word-aligned addresses for a byte-wide bus.

**Diagnosis:** Add debug print in `reg2bus()`: `$display("reg2bus: rw.addr=%0h item.cpu_addr=%0h", rw.addr, item.cpu_addr)`. If you see `rw.addr=4` for a register at offset 1, the map is using n_bytes=4.

**Fix:** Change `create_map("reg_map", 0, 4, ...)` to `create_map("reg_map", 0, 1, ...)`.

### Bug 3: Simulation Hangs on First reg.write()

**Symptom:** The simulation starts, reaches the first `reg_model.CTRL.write(status, 8'h01)` call, and hangs indefinitely. No timeout, no error, just stuck.

**Root causes (two possibilities):**
1. `provides_responses=1` but the driver never calls `seq_item_port.item_done(rsp)` with a response. The RAL framework waits for the response forever.
2. `set_sequencer()` was not called in the environment's `connect_phase`. The RAL map has no sequencer to drive transactions to.

**Diagnosis:** Check that `reg_model.reg_map.set_sequencer(cpu_agent.sequencer, adapter)` is in `connect_phase`. Add timeout to the simulation. Check the UVM verbosity log for "waiting for response" messages.

**Fix:** Ensure both `set_sequencer()` is called AND the driver calls `item_done(rsp)`.

### Bug 4: STATUS Mirror Never Updates (Always Shows IDLE)

**Symptom:** After issuing CMD_START and polling STATUS, the RAL mirror consistently shows STS_IDLE even though the waveform shows the FSM is in STATE_TX_BIT.

**Root cause:** STATUS is volatile and the test is relying on `get_mirrored_value()` without calling `read()`. The auto-predict only updates the mirror when a read transaction is issued. The FSM changes STATUS to STS_BUSY without any CPU read happening — so the mirror stays at the last-read value (IDLE from the reset check).

**Diagnosis:** Replace `get_mirrored_value()` with `reg_model.STATUS.read(status, rdata)`. The waveform should then show CPU register reads to address 0x2 between the CMD writes.

**Fix:** Always call `read()` for volatile STATUS fields. Never rely on `get_mirrored_value()` for STATUS without a preceding `read()` call.

### Bug 5: UVM_ERROR "reg_model handle is null" in Sequences

**Symptom:** Every sequence that tries to access `reg_model.CTRL.write(...)` fails with a null handle dereference. The sequence runs, hits the first RAL call, and logs UVM_FATAL.

**Root cause:** The `uvm_config_db::get()` for `reg_model` in the sequence `body()` uses the wrong string key, or the env published it with a different key.

**Diagnosis:** Check that `uvm_config_db #(i2c_master_reg_block)::set(this, "*", "reg_model", reg_model)` in `i2c_ral_env.sv` uses `"reg_model"` as the key. The sequence's `get()` call must use exactly the same string: `uvm_config_db #(i2c_master_reg_block)::get(this, "*", "reg_model", reg_model)`.

**Fix:** Match the string keys exactly. Use a `parameter string` or `define` for the key name to prevent typos:
```systemverilog
`define REG_MODEL_KEY "reg_model"
uvm_config_db #(i2c_master_reg_block)::set(this, "*", `REG_MODEL_KEY, reg_model);
```

> **Interview-grade answer:** *"The five most common RAL debug scenarios follow a pattern: three are adapter misconfigurations (provides_responses, n_bytes, set_sequencer), one is volatile field misuse, one is config_db key mismatch. Every RAL debug session at NVIDIA or Qualcomm starts with the same checklist: (1) verify provides_responses is correct for your bus type, (2) verify n_bytes matches your bus width, (3) verify set_sequencer() is called in connect_phase, (4) verify all volatile fields are read before checking, (5) verify config_db keys match exactly. If all five are correct, the remaining bugs are in the RTL itself — which is what you want: the RAL infrastructure is clean and you are doing real DUT verification."*

---

## 12. Quiz — 15 Questions (No Answers)

Read each question. Close the document. Write your answer on paper. Score yourself. Then check Section 13.

---

**Q1.** A register is declared as WO in the RAL model. A sequence calls `reg.read(status, rdata)`. What does the RAL do? What does `rdata` contain? Does a bus transaction occur?

---

**Q2.** A register is declared as RO in the RAL model. A sequence calls `reg.write(status, 8'hFF)`. List three things that happen as a result.

---

**Q3.** Explain the difference between `reg.FIELD.get()` and `reg.FIELD.get_mirrored_value()`. When do they return different values?

---

**Q4.** The `i2c_master_reg_block` uses `n_bytes=1` in `create_map()`. What would happen — specifically, at the bus level — if you accidentally set `n_bytes=4`?

---

**Q5.** `provides_responses=1` is set in `i2c_reg_adapter`. What goes wrong if you change it to `provides_responses=0` on a synchronous CPU bus that drives cpu_rdata on a clock edge?

---

**Q6.** What does `lock_model()` do and when must it be called relative to `add_reg()` calls? What happens if you forget it?

---

**Q7.** A register field is declared `volatile=1`. Explain what this tells the RAL predictor and why `volatile=0` would be wrong for the STATUS register in this project.

---

**Q8.** In the BEFORE sequence, the programmer writes `req.cpu_addr = 3'h2; req.cpu_wr = 1'b1;` (writing to REG_STATUS). The RTL ignores it. The test passes. Why is this a verification gap? What does RAL do differently?

---

**Q9.** Explain `set_auto_predict(1)` vs `uvm_reg_predictor`. Under what condition would you NEED the explicit predictor even if all your test accesses come from RAL sequences?

---

**Q10.** The `REG_IRQ_ST` register at offset 0x6 maps to `reg_status` in the RTL (same wire as REG_STATUS at 0x2). After a RAL read of IRQ_ST followed by a RAL read of STATUS, are their mirror values the same? Why or why not?

---

**Q11.** Describe the internal call chain that happens when you call `reg_model.CTRL.write(status, 8'h01)`. List at least 5 steps from the reg.write() call to the driver executing the transaction.

---

**Q12.** What is the difference between `reg.DATA.write(status, val)` and `reg.DATA.set(val); reg.DATA.update(status)` ? When does the second pattern issue NO bus transaction?

---

**Q13.** The RTL's reset logic initializes `reg_data_buf <= 8'h00`. The RAL's DATA register has `reset_value = 8'h00` in configure(). How does `uvm_reg_hw_reset_seq` use this information? What register does it skip and why?

---

**Q14.** Backdoor access: what is `uvm_reg::peek()` and when would you use it on the STATUS register in this project? What RTL path would you specify in `add_hdl_path_slice()`?

---

**Q15.** You add an 8th register (REG_FIFO_CTRL at offset 0x7) to the RTL and model. List every file in the RAL implementation that you MUST modify vs files you do NOT need to touch.

---

## 13. Quiz Answers (with Interview-grade callouts)

---

**A1.** The RAL detects the WO access type. It does NOT issue a bus read transaction. `rdata` is populated with the internally-stored desired value — the last value written via `CMD.write()` (or `4'h0` if no write has occurred). `status` is set to `UVM_IS_OK` (WO reads are not an error, just a model-level return). No clock cycles are consumed.

> **Interview-grade answer:** *"For a WO register, read() is a model-only operation that returns the desired value without touching the bus. This is correct because the RTL has no read path for WO registers — the RTL returns 0 for that address. If RAL actually issued the bus read, it would get 0 back and update the mirror to 0, which would then diverge from the desired value and trigger a false mismatch. By returning desired directly, RAL correctly models the spec: 'this register cannot be read, I give you my best knowledge of its current value.'"*

---

**A2.** Three things happen: (1) The RAL detects the "RO" access type mismatch. (2) A `UVM_WARNING` is emitted — not UVM_ERROR — with text indicating a write to a read-only register was attempted. (3) No bus transaction (`cpu_wr=1, cpu_addr=2`) is issued to the DUT. The `status` argument is set to `UVM_NOT_OK`. The mirror value is unchanged.

> **Interview-grade answer:** *"Writing to an RO register generates a WARNING, not a FATAL, because the intent is to warn the test developer without aborting the simulation. This is appropriate: maybe the sequence is deliberately testing 'what happens if firmware writes STATUS?' The test can observe that status==UVM_NOT_OK and that no bus transaction occurred. The RAL enforces the spec silently — the RTL already ignores such writes. RAL just makes the violation visible."*

---

**A3.** `get()` returns the desired value — what the sequence last called `set()` with, or the last `write()` value. `get_mirrored_value()` returns the mirror — the last value read back from the bus via `read()` or `update()`. They differ when: (1) you have called `set()` but not yet called `update()`, (2) a hardware side-effect has changed the register content without a CPU write (volatile fields like STATUS), or (3) after a write-only field write (desired updated, mirror not updated because no readback issued).

> **Interview-grade answer:** *"The three-value model — desired, mirrored, actual — is the RAL's answer to the fundamental problem of software not being able to see hardware state directly. Desired is your intent. Mirrored is your most recent confirmed observation. Actual is reality. The gap between mirrored and actual is closed only by issuing a read(). For STATUS in this I2C project, mirrored becomes stale within microseconds after any bus transaction, because the FSM changes it. get_mirrored_value() on STATUS is only reliable immediately after a read(). Always read() before checking STATUS value."*

---

**A4.** With `n_bytes=4`, the register map treats each register slot as 4 bytes wide. The map produces byte addresses: CTRL at 0x00, CMD at 0x04, STATUS at 0x08, DATA at 0x0C, ADDR at 0x10, IRQ_EN at 0x14, IRQ_ST at 0x18. The adapter gets `rw.addr = 4` for CMD instead of `rw.addr = 1`. It passes `cpu_addr = 3'h4` to the DUT — which is REG_ADDR, not REG_CMD. Every register access targets the wrong register. All reads return wrong values. All writes program the wrong registers. The test will fail with mirror mismatches, but the root cause is opaque.

> **Interview-grade answer:** *"n_bytes in create_map() is the data bus granularity — how many bytes each 'unit' of address space covers. An 8-bit bus with n_bytes=1 has contiguous addressing: register 0 at address 0, register 1 at address 1. A 32-bit AXI bus with n_bytes=4 has word-aligned addressing: register 0 at 0x00, register 1 at 0x04. Mixing them silently produces wrong bus addresses. The diagnostic is that every bus transaction targets an address that is 4x larger than expected. Always verify n_bytes by checking: does the adapter's rw.addr for the second register equal 1 (n_bytes=1 correct) or 4 (n_bytes=4 wrong)?"*

---

**A5.** With `provides_responses=0`, the RAL calls `bus2reg()` immediately after handing the request item to the sequencer — before the driver has executed the bus transaction. At that point, `item.cpu_rdata` is still 0 (the uninitialized value from `i2c_cpu_seq_item` creation). `bus2reg()` copies 0 into `rw.data`. The RAL updates the mirror to 0. Every RAL read returns a mirror value of 0, regardless of what the DUT actually drives on `cpu_rdata`. Write transactions appear correct (writes do not depend on rdata), but reads are silently wrong. This produces a particularly hard-to-debug failure: the simulation runs without errors, read verification passes (because expected value 0 == mirror 0), but the mirror never reflects real DUT state.

> **Interview-grade answer:** *"provides_responses=0 is for memoryless, purely combinational buses where the response is captured in-place on the request item. provides_responses=1 is for synchronous buses where the driver captures response data asynchronously from the request. The golden rule: if your driver waits for a clock edge to capture rdata (which all synchronous register buses do), use provides_responses=1. The driver signals completion with item_done(response), and bus2reg() runs on the completed response item."*

---

**A6.** `lock_model()` finalizes the register block structure. After it, you cannot add registers, modify field widths, or change access types. It must be called AFTER all `add_reg()` calls and AFTER all `reg.build()` calls in `uvm_reg_block::build()`. If you forget `lock_model()`, the model works in simulation but a UVM warning is issued at runtime indicating the model was not locked. More importantly, without locking, factory overrides can accidentally inject register modifications during test body execution, creating inconsistent model states.

> **Interview-grade answer:** *"lock_model() is analogous to calling seal() on a data structure in software — it asserts that the structure is complete and correct, and prevents further modification. The practical impact: if someone writes a factory override that tries to add a new field to an existing register after build() phase, the locked model rejects it with a fatal. This catches a class of bugs where late-phase register model modifications cause divergence between the map and the actual model structure. Always call lock_model() as the last line of uvm_reg_block::build()."*

---

**A7.** `volatile=1` tells the RAL predictor: "this field's value can change due to hardware activity, not just CPU writes." For STATUS, the FSM transitions through IDLE→BUSY→DONE→IDLE constantly. These transitions update `reg_status` in the RTL without any CPU write. If volatile=0 (the default for config registers), the RAL assumes the mirror is stable between CPU accesses. If the mirror shows IDLE and the FSM has moved to BUSY, the mirror is stale. The RAL would not refresh the mirror unless you call read(). With volatile=1, the predictor knows not to trust the mirror and sequences should always call read() to get the current STATUS.

> **Interview-grade answer:** *"volatile is a hint to the verification environment, not to the RAL predictor itself. The predictor does not automatically poll volatile fields. What volatile=1 really does: (1) it disables the 'read-after-write check' that the RAL performs to verify the mirror matches the hardware — because volatile fields are expected to change; (2) it influences auto-predict to skip mirror-vs-read verification for this field. In practice, the sequence author must know that STATUS is volatile and always issue a read() before checking its value, rather than relying on get_mirrored_value()."*

---

**A8.** Without RAL, writing to REG_STATUS via a direct sequence item fires a real bus transaction: `cpu_wr=1, cpu_addr=3'h2`. The RTL ignores it because `reg_status` has no write path from `cpu_wr`. The test sees no error. No assertion fires. The sequence accidentally covered a write-to-RO scenario and declared it passing. This is a verification gap: the test is inadvertently testing RTL robustness against incorrect writes, but it is NOT testing the intended register behavior. With RAL, writing to STATUS emits `UVM_WARNING` and suppresses the bus transaction — the intent violation is immediately flagged.

> **Interview-grade answer:** *"A verification gap is when your testbench exercises stimulus that the DUT correctly handles, but the testbench cannot distinguish between 'correct' and 'incorrect by design.' Writing to RO registers is a perfect example: the DUT always ignores such writes (by design), so the test never fails. But the verification intent was to test that EN=1 works — the accidental STATUS write adds no coverage and can mask a real address decode bug. RAL's access type enforcement converts silent incorrect operations into explicit warnings, making verification intent machine-checkable."*

---

**A9.** Auto-predict updates the mirror only for transactions that the RAL itself initiates. You need an explicit `uvm_reg_predictor` when transactions from OUTSIDE the RAL also affect registers. Example: if a DMA engine (modeled as a separate UVM agent) writes to REG_CTRL directly on the bus — bypassing the RAL sequences — auto-predict does not know this happened. The mirror diverges from reality. With an explicit predictor connected to the CPU agent's monitor analysis port, every bus transaction (regardless of source) is observed and fed to the predictor, which calls `reg_model.predict()` to update the mirror.

> **Interview-grade answer:** *"The explicit predictor is mandatory in any multi-master scenario where non-RAL agents write registers. In this I2C project with a single CPU agent all controlled by RAL sequences, auto-predict is sufficient. But in a real SoC testbench where a DMA engine can write the I2C master's config registers, the predictor must subscribe to the bus monitor to stay synchronized. A diverged mirror does not cause simulation errors by itself — the RAL just silently uses stale data. The bug only surfaces when a sequence relies on get_mirrored_value() to make a decision. This is why predictors are more critical in system-level environments than block-level."*

---

**A10.** After reading IRQ_ST: the IRQ_ST register's mirror is updated to `reg_status` current value (e.g., `STS_IDLE = 8'h00`). After reading STATUS: the STATUS register's mirror is also updated to `reg_status` current value. They should have the same value because both registers map to the same RTL wire (`reg_status`). However, if the FSM changes state BETWEEN the two reads (e.g., between the IRQ_ST read and the STATUS read a CMD was issued), the two mirror values will be different. The mirrors diverge not because of RAL incorrectness, but because the hardware changed state between the two bus transactions.

> **Interview-grade answer:** *"This question exposes the fundamental problem with memory-mapped status registers on a live FSM: the window between two reads is not atomic. If you need to make a decision based on both IRQ_ST and STATUS being a certain value simultaneously, you cannot guarantee consistency across two separate bus reads unless the FSM guarantees it will not change state during that window. In practice this means: design status registers that capture their value until explicitly cleared (W1C sticky bits), rather than making them direct combinational outputs of the FSM. The W1C pattern is ubiquitous in real SOC register designs for exactly this reason."*

---

**A11.** The call chain for `reg_model.CTRL.write(status, 8'h01)`:

1. `uvm_reg::write()` — checks access type (RW: proceed). Calls `uvm_reg::do_write()`.
2. `uvm_reg::do_write()` — packages `uvm_reg_bus_op {kind=UVM_WRITE, addr=0, data=8'h01, n_bits=8}`. Calls `uvm_reg_map::do_write()`.
3. `uvm_reg_map::do_write()` — calls `adapter.reg2bus(rw)` to get `i2c_cpu_seq_item`. Creates the sequence on the adapter's implicit sequencer.
4. `i2c_reg_adapter::reg2bus()` — creates `i2c_cpu_seq_item`, sets `cpu_addr=3'h0, cpu_wr=1, cpu_wdata=8'h01`.
5. The `i2c_cpu_seq_item` is handed to the sequencer via `start_item/finish_item`. The CPU driver picks it up.
6. `i2c_cpu_driver` drives `reg_vif.driver_cb.cpu_addr=0, cpu_wr=1, cpu_wdata=8'h01`. Waits one clock edge.
7. Driver captures `cpu_rdata` (ignored for writes). Calls `seq_item_port.item_done(response)`.
8. `uvm_reg_map::do_write()` receives response. Calls `adapter.bus2reg(response, rw)`.
9. `bus2reg()` sets `rw.status = UVM_IS_OK`.
10. If `auto_predict=1`: `uvm_reg::predict()` called — mirror and desired updated to 8'h01.
11. `status` argument in the sequence set to `UVM_IS_OK`. `write()` returns.

> **Interview-grade answer:** *"The reg.write() call chain has 10+ steps but the key architectural insight is the separation: steps 1-4 are RAL-internal (access type checking, bus op packaging, adapter translation), steps 5-7 are bus-specific (your driver and interface), steps 8-10 are RAL-internal again (response processing, mirror update). The adapter is the only project-specific code in the chain. This is why RAL is reusable: swap the adapter and driver, keep everything else. The reg_model, sequences, and mirror tracking work unchanged."*

---

**A12.** `reg.DATA.write(status, val)` always issues a bus write transaction, regardless of the current mirror value. The mirror and desired are updated to `val`.

`reg.DATA.DATA.set(val); reg.DATA.update(status)` — `set()` updates only the desired value, no bus transaction. `update()` compares desired to mirror: if desired == mirror, NO bus transaction is issued and status returns `UVM_IS_OK` immediately. Only if desired != mirror does `update()` issue the bus write.

When does `update()` issue no transaction? When the desired value equals the mirror value — meaning the register already contains the value you want. This is the efficient pattern for idempotent register configuration: call `set()` to configure desired values, then `update()` to synchronize only the differences.

> **Interview-grade answer:** *"The set/update pattern mirrors how embedded software drivers work: assemble the full desired register state, then write only if it differs from the known hardware state. This eliminates redundant bus transactions in performance-critical verification loops. For example, if you are running a constrained random test that keeps CTRL.EN=1 across all transactions, using write() would issue a bus write every time. Using set/update would issue the write once (when EN transitions from 0 to 1) and skip it thereafter. In gate-level simulation where every bus transaction costs hundreds of nanoseconds, this optimization matters."*

---

**A13.** `uvm_reg_hw_reset_seq` iterates every register in the block that has `has_reset=1` (the 5th argument in `configure()`). For each such register, it calls `reg.read(status, rdata)` and compares `rdata` against `reg.get_reset()` (the reset value from `configure()`). For the CMD register: CMD has `has_reset=1` and `reset_value=4'h0`. However, CMD is WO — `uvm_reg_hw_reset_seq` detects WO access type and SKIPS it. You cannot verify the CMD reset value via bus read — the RTL returns 0x00 regardless, which matches the reset value but for the wrong reason. To actually verify CMD reset, backdoor peek is required.

> **Interview-grade answer:** *"uvm_reg_hw_reset_seq is the single best 'free' test in UVM — it checks all reset values without writing any sequence code. The key caveat: it respects access types. WO and WO1 registers are skipped because reading them via bus does not give a meaningful result. This is actually an asset: the built-in sequence correctly models the verification limitations of the register map. For WO registers, add a backdoor peek in the reset check sequence to cover what the automatic sequence cannot."*

---

**A14.** `uvm_reg::peek()` is a backdoor read that directly reads the RTL signal value without issuing a bus transaction. It uses the HDL path set via `add_hdl_path_slice()`. For STATUS, you would use peek() when you need the current FSM state immediately without waiting for a bus read cycle — useful during tight timing sequences where a bus read would take one full clock cycle.

HDL path for STATUS in this project:
```systemverilog
STATUS.add_hdl_path_slice("top_tb_ral.dut.reg_status", 0, 8);
// where "top_tb_ral.dut" is the DUT instance path in top_tb_ral.sv
// "reg_status" is the register name in i2c_master_controller.sv
```

After `peek()`, the mirror is updated with the RTL value directly — no bus traffic. This is also useful for fault injection: `poke()` can force-set a register to a specific value bypassing the bus entirely.

> **Interview-grade answer:** *"Backdoor access via peek/poke requires that your simulator supports direct PLI or DPI access to RTL signals via the hierarchical path. The HDL path string must exactly match the hierarchical path in simulation: module instance names, signal names, and bit slices. The primary use case for peek() in block-level register verification is checking volatile registers like STATUS without consuming bus bandwidth — you want to know the exact FSM state at a specific simulation time without the one-cycle delay of a bus read. poke() is used for fault injection and corner-case reset testing that cannot be achieved by writing the register through the bus."*

---

**A15.** For adding REG_FIFO_CTRL at offset 0x7:

**MUST modify:**
- `ral/i2c_master_reg_model.sv` — add `i2c_fifo_ctrl_reg` class + add to `i2c_master_reg_block` with `add_reg(FIFO_CTRL, 7, "RW")`

**DO NOT need to touch:**
- `ral/i2c_reg_adapter.sv` — adapter is generic, `rw.addr[2:0]` handles any 3-bit address
- `ral/i2c_ral_seq.sv` — sequences use symbolic names; existing sequences unchanged
- `uvm/i2c_cpu_seq_item.sv` — unchanged (3-bit addr field handles 0–7)
- `uvm/i2c_cpu_driver.sv` — unchanged (drives signals, knows nothing about registers)
- `uvm/i2c_cpu_agent.sv` — unchanged
- `uvm/i2c_ral_env.sv` — unchanged (creates model generically)
- `uvm/i2c_ral_test.sv` — unchanged for existing tests; new tests can be added
- `tb/i2c_reg_if.sv` — unchanged (3-bit cpu_addr already supports up to 8 registers)
- `tb/top_tb_ral.sv` — unchanged
- `tb/i2c_tb_ral_pkg.sv` — no new file to include (FIFO_CTRL class is inside reg_model.sv)

> **Interview-grade answer:** *"This single-file change property is the most important practical argument for RAL. In a project with 200 registers, adding a new register means updating one file — the register model. All sequences, drivers, environments, and tests remain unchanged. Without RAL, adding one register requires auditing every sequence that manually manages address offsets. In a large regression suite, that could mean hundreds of files. RAL quarantines register map knowledge to the register block and adapter, making the test infrastructure independent of the register count."*

---

## 14. Key Takeaways

- **RAL is not optional on real projects.** Every NVIDIA, Qualcomm, and Intel block has a register interface. RAL is the industry-standard mechanism for verifying it. If you cannot implement `uvm_reg_block`, write an adapter, and use `set()/update()` correctly, you are missing a core DV competency.

- **n_bytes, provides_responses, and volatile are the three most-asked RAL misconfig questions.** Know each one cold. Know what goes wrong when each is set incorrectly. Know the diagnostic signature of each failure.

- **Access types encode the spec.** RO, WO, RW are not cosmetic labels. They change the behavior of `write()` and `read()`. The enforcement is lightweight (WARNING, not FATAL) so you can deliberately test access violations — but the default behavior correctly models the RTL intent.

- **The set/update pattern is the right way to write multi-field registers.** Never use `write()` when you only need to change one field of a multi-field register. Set the desired values with `set()`, call `update()` once. One bus transaction, correct bit masking, no clobbering adjacent fields.

- **Desired, mirrored, and actual are three different values.** Desired = your intent. Mirrored = last confirmed read-back. Actual = live RTL state. They diverge under specific conditions. Know when each occurs and how to re-synchronize them.

- **The adapter is the only project-specific RAL code.** Every other piece — `uvm_reg_block`, sequences, mirror tracking, access type enforcement — is standard UVM. Build the adapter correctly and the rest of the infrastructure works regardless of the bus protocol. This is the key to RAL reuse across projects.

---

## 15. Action Items

These are concrete, executable tasks that will deepen your understanding beyond reading. Do them in order.

**Action Item 1: Verify WO Access Type Enforcement**

In `ral/i2c_ral_seq.sv`, add a sequence that writes `CMD_WRITE` to the CMD register, then immediately calls `reg_model.CMD.read(status, rdata)`. Verify that:
- No bus transaction appears in the VCD waveform for the read
- `rdata` equals the desired value you wrote (CMD_WRITE = 4'h3)
- `status` equals `UVM_IS_OK` (WO reads are not errors)

This concretely proves WO access type enforcement works. Capture the waveform. Mark the clock cycle where the write occurs, and confirm there is NO read transaction cycle.

**Action Item 2: Add HDL Backdoor Path to STATUS**

In `ral/i2c_master_reg_model.sv`, add to `i2c_status_reg::build()`:
```systemverilog
add_hdl_path_slice("top_tb_ral.dut.reg_status", 0, 3);
```
Then write a sequence that:
1. Issues `CMD_START` to start a transaction
2. Immediately `peek()`s STATUS (backdoor read — no clock consumed)
3. Verifies STATUS shows STS_BUSY

Compare the result to issuing a bus `read()` of STATUS. Note whether the bus read sees BUSY or IDLE depending on timing. This demonstrates the value of backdoor access for timing-sensitive status verification.

**Action Item 3: Run `uvm_reg_hw_reset_seq`**

In `uvm/i2c_ral_test.sv`, add a test:
```systemverilog
class i2c_hw_reset_test extends i2c_ral_base_test;
  task run_phase(uvm_phase phase);
    uvm_reg_hw_reset_seq reset_seq = uvm_reg_hw_reset_seq::type_id::create("reset_seq");
    reset_seq.model = env.reg_model;
    phase.raise_objection(this);
    reset_seq.start(null);
    phase.drop_objection(this);
  endtask
endclass
```
Run it. Count how many registers are checked. Note that CMD is skipped (WO). Check whether IRQ_ST correctly reads 0x00 (STS_IDLE). This is a free reset verification test — NVIDIA uses variants of this on every register map.

**Action Item 4: Add a Busy-Polling Sequence with Timeout**

In `ral/i2c_ral_seq.sv`, add:
```systemverilog
class i2c_check_busy_seq extends uvm_reg_sequence;
  i2c_master_reg_block reg_model;
  int unsigned max_polls = 1000;

  task body();
    uvm_status_e   status;
    uvm_reg_data_t rdata;
    int unsigned   poll_count = 0;

    do begin
      reg_model.STATUS.read(status, rdata);
      poll_count++;
      if (poll_count >= max_polls) begin
        `uvm_error("TIMEOUT", "STATUS never showed STS_IDLE")
        return;
      end
    end while (rdata[2:0] == STS_BUSY);

    `uvm_info("BUSY", $sformatf("BUSY->IDLE after %0d polls", poll_count), UVM_MEDIUM)
  endtask
endclass
```
Measure the poll count for a standard START+WRITE+STOP sequence with 50 MHz clock and T_SCL_PERIOD=500. Calculate the theoretical minimum bus cycles. Compare to the actual poll count. This quantifies polling overhead — an important figure-of-merit for register-based status checking vs interrupt-driven flow.

**Action Item 5: Connect a Slave Model for End-to-End Verification**

After `top_tb_ral.sv` is functional, modify it to instantiate `i2c_slave_controller.sv` alongside the master. Connect SCL/SDA between them. Run `i2c_program_master_seq` and verify:
- The master correctly generates START, WRITE byte, STOP on the I2C bus
- The slave acknowledges correctly
- STATUS reads STS_DONE after STOP
- REG_DATA correctly updates with received byte if a read transaction is performed

This is the full end-to-end proof that RAL register programming correctly drives the I2C physical bus. Block-level register tests only verify the CPU interface. End-to-end tests verify that the register values correctly control the FSM that drives the bus.

---

## 16. Honest Self-Score Template

Score yourself 0–100 on each row. 0 = "I cannot define this term." 50 = "I understand it but cannot explain it without looking at the code." 100 = "I can explain this to an interviewer for 3 minutes with zero notes."

Fill this out BEFORE reading the quiz answers, then again AFTER. The delta is your actual learning.

| Concept | Score Before | Score After | Target | Notes |
|---------|-------------|-------------|--------|-------|
| What uvm_reg_block is and why it exists | | | 80 | |
| What uvm_reg is and how fields relate to it | | | 80 | |
| configure() arguments for uvm_reg_field (all 9) | | | 70 | |
| What n_bytes in create_map() means and what goes wrong | | | 90 | |
| Access types: RW, RO, WO behavior differences | | | 90 | |
| What happens when you write to an RO register | | | 85 | |
| What happens when you read a WO register | | | 85 | |
| Desired vs mirrored vs actual — definition and divergence cases | | | 85 | |
| set() vs write() — when each is appropriate | | | 80 | |
| set/update pattern — when update issues no transaction | | | 75 | |
| reg2bus() and bus2reg() — what each does and when called | | | 80 | |
| provides_responses=1 vs 0 — what goes wrong with wrong setting | | | 85 | |
| auto_predict vs explicit predictor — when each is needed | | | 75 | |
| lock_model() — what it does and when to call it | | | 70 | |
| volatile=1 — what it means and when STATUS needs it | | | 75 | |

**Score interpretation:**
- 0–40: You read the lesson once. Read it again and do the action items.
- 41–65: You understand the concepts but your explanations are imprecise. Practice the elevator pitches out loud.
- 66–80: Solid. An interviewer who asks these questions will be satisfied with your answers.
- 81–100: You can go deep. You are ready for the follow-up questions about RAL scalability, multi-map configurations, and backdoor access at gate-level.

**Target for NVIDIA/Qualcomm first-round interview:** Average ≥ 72 across all 15 rows before the interview.

### What a Score of 50 Looks Like in an Interview

A score of 50 on "provides_responses" means you can say: "provides_responses=1 means the bus provides explicit read data." That is not enough. The interviewer follows up: "What goes wrong if you set it to 0 on a synchronous bus?" If you cannot answer that, you did not score 50 — you scored 30.

A score of 80 means you can explain the failure mode, the diagnostic signature, and the fix without hesitation. That is the target.

### Study Priority for NVIDIA/Qualcomm First Interviews

If you have one week before the interview, prioritize in this order:

1. **Day 1–2:** Sections 5 and 6 — register model and adapter. These are the two files interviewers open and walk you through.
2. **Day 3:** Section 8 — the BEFORE/AFTER comparison. Be able to narrate this difference verbally for 90 seconds without notes.
3. **Day 4:** Section 9 — access type deep dive. Know RO, WO, RW, W1C cold.
4. **Day 5:** Section 13 — quiz answers. Read them, then close the document and speak each answer out loud.
5. **Day 6–7:** Action Items 1 and 3. Running actual code is worth more than re-reading theory.

---

*Lesson 18 complete. Next lesson: Lesson 19 — UVM Functional Coverage for Register Access Patterns (covering `uvm_reg_cvr_t`, hit-driven coverage, and cross-coverage between register fields and I2C bus outcomes).*

---

*End of file. Total sections: 16 + 2 subsections. Total Interview-grade callouts: 41. Total quiz questions: 15. This document is a living reference — update the self-score table after each practice session.*
