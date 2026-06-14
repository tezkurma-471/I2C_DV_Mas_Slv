//=============================================================================
// File          : i2c_master_reg_model.sv
// Description   : UVM RAL Register Model for the I2C Master Controller.
//               : Models all 7 registers in the CPU register map.
//
// TEACHING NOTE — What is UVM RAL?
//   Without RAL you write sequences that look like this:
//     item.cpu_addr  = 3'h0;   // REG_CTRL
//     item.cpu_wr    = 1;
//     item.cpu_wdata = 8'h01;  // set EN bit
//     // ... drive the item via sequencer/driver
//
//   The problem:
//     - Every test knows the raw bit positions (magic numbers)
//     - Read-modify-write is manual: read first, mask, OR, write back
//     - No shadow/mirror tracking — you can't ask "what did we last write?"
//     - No built-in reset checking
//
//   WITH RAL:
//     reg_model.CTRL.EN.set(1);   // field-level, self-documenting
//     reg_model.CTRL.update(status);  // drives only changed fields
//     // RAL handles bit masking and read-modify-write internally
//
// REGISTER ACCESS TYPES (used in add_field):
//   RW  — read/write (test can read back what it wrote)
//   RO  — read-only  (DUT drives it; writes are ignored)
//   WO  — write-only (reads return 0; no readback check in RAL)
//   RC  — read-to-clear (reading the field clears it in the DUT)
//   W1C — write-1-to-clear (writing 1 to a bit clears it)
//
// REGISTER OFFSETS match i2c_reg_e in i2c_pkg.sv:
//   REG_CTRL   = 0x0
//   REG_CMD    = 0x1
//   REG_STATUS = 0x2
//   REG_DATA   = 0x3
//   REG_ADDR   = 0x4
//   REG_IRQ_EN = 0x5
//   REG_IRQ_ST = 0x6
//
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_MASTER_REG_MODEL_SV
`define I2C_MASTER_REG_MODEL_SV

// ============================================================================
// REG 0x0 — CTRL (Control Register)
// ============================================================================
// Bits:
//   [0]   EN             : RW — master enable.  1=enabled, 0=disabled.
//   [1]   IRQ_GLOBAL_EN  : RW — master interrupt enable gate.
//   [7:2] reserved       : not modelled (RAL ignores them; reads as 0)
//
// Access RW: test can freely read back its own writes.
// ============================================================================
class i2c_ctrl_reg extends uvm_reg;

    `uvm_object_utils(i2c_ctrl_reg)

    uvm_reg_field EN;            // bit[0] — enable the I2C master
    uvm_reg_field IRQ_GLOBAL_EN; // bit[1] — global interrupt gate

    function new(string name = "i2c_ctrl_reg");
        // uvm_reg(name, n_bits, has_coverage)
        // n_bits = 8 because our bus is 8 bits wide
        super.new(name, 8, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
        // uvm_reg_field::type_id::create(name, parent, ...)
        EN = uvm_reg_field::type_id::create("EN");
        IRQ_GLOBAL_EN = uvm_reg_field::type_id::create("IRQ_GLOBAL_EN");

        // configure(parent, size, lsb_pos, access, volatile, reset_val,
        //           has_reset, is_rand, individually_accessible)
        //
        // size=1, lsb_pos=0  → occupies bit[0]
        // "RW"               → test can read/write freely
        // volatile=0         → DUT doesn't change this field on its own
        // reset=0            → resets to 0 (controller starts disabled)
        // has_reset=1        → RAL knows about this reset value
        EN.configure(           this, 1, 0, "RW", 0, 8'h0, 1, 1, 1);
        IRQ_GLOBAL_EN.configure(this, 1, 1, "RW", 0, 8'h0, 1, 1, 1);
    endfunction

endclass : i2c_ctrl_reg


// ============================================================================
// REG 0x1 — CMD (Command Register)
// ============================================================================
// Bits:
//   [3:0] CMD    : WO — command opcode (i2c_cmd_e).  Reads return 0.
//   [7:4] reserved
//
// Access WO: RAL will NOT attempt read-back verification for this register.
// This matches the DUT — reading REG_CMD returns 0x00 (see cpu_rdata mux).
// ============================================================================
class i2c_cmd_reg extends uvm_reg;

    `uvm_object_utils(i2c_cmd_reg)

    uvm_reg_field CMD;   // bits[3:0] — i2c_cmd_e opcode

    function new(string name = "i2c_cmd_reg");
        super.new(name, 8, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
        CMD = uvm_reg_field::type_id::create("CMD");
        // WO: write-only.  RAL mirror is updated on write but no readback check.
        CMD.configure(this, 4, 0, "WO", 0, 8'h0, 1, 1, 1);
    endfunction

endclass : i2c_cmd_reg


// ============================================================================
// REG 0x2 — STATUS (Status Register)
// ============================================================================
// Bits:
//   [2:0] STATUS  : RO — current i2c_status_e value driven by DUT FSM.
//   [7:3] reserved
//
// Access RO: test cannot write to this.  Only the DUT changes it.
// volatile=1: the DUT can change STATUS asynchronously (FSM updates it).
//             This tells RAL: "don't trust your mirror — always re-read."
// ============================================================================
class i2c_status_reg extends uvm_reg;

    `uvm_object_utils(i2c_status_reg)

    uvm_reg_field STATUS;  // bits[2:0] — i2c_status_e

    function new(string name = "i2c_status_reg");
        super.new(name, 8, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
        STATUS = uvm_reg_field::type_id::create("STATUS");
        // RO + volatile=1: tells RAL this field changes without CPU writes
        STATUS.configure(this, 3, 0, "RO", 1, 8'h0, 1, 0, 1);
    endfunction

endclass : i2c_status_reg


// ============================================================================
// REG 0x3 — DATA (TX/RX Data Buffer)
// ============================================================================
// Bits:
//   [7:0] DATA  : RW — byte to transmit (write), or last received byte (read)
//
// Access RW: CPU writes TX data here before CMD_WRITE.
//            After CMD_READ_ACK/NACK completes, CPU reads received byte here.
// ============================================================================
class i2c_data_reg extends uvm_reg;

    `uvm_object_utils(i2c_data_reg)

    uvm_reg_field DATA;  // bits[7:0]

    function new(string name = "i2c_data_reg");
        super.new(name, 8, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
        DATA = uvm_reg_field::type_id::create("DATA");
        // volatile=1: after a read transaction, DUT updates reg_data_buf
        //             without a CPU write — so our mirror may be stale.
        DATA.configure(this, 8, 0, "RW", 1, 8'h0, 1, 1, 1);
    endfunction

endclass : i2c_data_reg


// ============================================================================
// REG 0x4 — ADDR (Slave Address Register)
// ============================================================================
// Bits:
//   [0]   DIR        : RW — direction: 0=write, 1=read  (i2c_dir_e)
//   [7:1] SLAVE_ADDR : RW — 7-bit target slave address
//
// IMPORTANT LAYOUT: SLAVE_ADDR occupies bits[7:1], DIR is bit[0].
//   This matches how the address byte is assembled on the I2C bus:
//   {SLAVE_ADDR[6:0], DIR} = 8-bit address byte sent after START.
// ============================================================================
class i2c_addr_reg extends uvm_reg;

    `uvm_object_utils(i2c_addr_reg)

    uvm_reg_field DIR;         // bit[0]   — R/W direction
    uvm_reg_field SLAVE_ADDR;  // bits[7:1] — 7-bit address

    function new(string name = "i2c_addr_reg");
        super.new(name, 8, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
        DIR        = uvm_reg_field::type_id::create("DIR");
        SLAVE_ADDR = uvm_reg_field::type_id::create("SLAVE_ADDR");

        // DIR at lsb_pos=0, size=1
        DIR.configure(       this, 1, 0, "RW", 0, 8'h0, 1, 1, 1);
        // SLAVE_ADDR at lsb_pos=1, size=7  → occupies bits[7:1]
        SLAVE_ADDR.configure(this, 7, 1, "RW", 0, 8'h0, 1, 1, 1);
    endfunction

endclass : i2c_addr_reg


// ============================================================================
// REG 0x5 — IRQ_EN (Interrupt Enable Register)
// ============================================================================
// Bits:
//   [0] DONE_EN    : RW — enable interrupt on transaction done
//   [1] ACK_EN     : RW — enable interrupt on ACK received
//   [2] NACK_EN    : RW — enable interrupt on NACK received
//   [3] TIMEOUT_EN : RW — enable interrupt on clock-stretch timeout
//   [4] ERR_EN     : RW — enable interrupt on bus error
//   [7:5] reserved
// ============================================================================
class i2c_irq_en_reg extends uvm_reg;

    `uvm_object_utils(i2c_irq_en_reg)

    uvm_reg_field DONE_EN;
    uvm_reg_field ACK_EN;
    uvm_reg_field NACK_EN;
    uvm_reg_field TIMEOUT_EN;
    uvm_reg_field ERR_EN;

    function new(string name = "i2c_irq_en_reg");
        super.new(name, 8, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
        DONE_EN    = uvm_reg_field::type_id::create("DONE_EN");
        ACK_EN     = uvm_reg_field::type_id::create("ACK_EN");
        NACK_EN    = uvm_reg_field::type_id::create("NACK_EN");
        TIMEOUT_EN = uvm_reg_field::type_id::create("TIMEOUT_EN");
        ERR_EN     = uvm_reg_field::type_id::create("ERR_EN");

        DONE_EN.configure(   this, 1, 0, "RW", 0, 8'h0, 1, 1, 1);
        ACK_EN.configure(    this, 1, 1, "RW", 0, 8'h0, 1, 1, 1);
        NACK_EN.configure(   this, 1, 2, "RW", 0, 8'h0, 1, 1, 1);
        TIMEOUT_EN.configure(this, 1, 3, "RW", 0, 8'h0, 1, 1, 1);
        ERR_EN.configure(    this, 1, 4, "RW", 0, 8'h0, 1, 1, 1);
    endfunction

endclass : i2c_irq_en_reg


// ============================================================================
// REG 0x6 — IRQ_ST (Interrupt Status Register)
// ============================================================================
// Bits:
//   [7:0] IRQ_ST : RO — reads back reg_status (per RTL cpu_rdata mux).
//
// TEACHING NOTE: The RTL maps REG_IRQ_ST read to reg_status (same value
// as REG_STATUS).  This is a common pattern where a read-to-clear IRQ
// status shadows the operational status.  Modelled as RO here.
// volatile=1: DUT updates this without CPU involvement.
// ============================================================================
class i2c_irq_st_reg extends uvm_reg;

    `uvm_object_utils(i2c_irq_st_reg)

    uvm_reg_field IRQ_ST;  // bits[7:0]

    function new(string name = "i2c_irq_st_reg");
        super.new(name, 8, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
        IRQ_ST = uvm_reg_field::type_id::create("IRQ_ST");
        // RO + volatile: DUT drives this, reads back reg_status value
        IRQ_ST.configure(this, 8, 0, "RO", 1, 8'h0, 1, 0, 1);
    endfunction

endclass : i2c_irq_st_reg


// ============================================================================
// TOP-LEVEL REGISTER BLOCK — i2c_master_reg_block
// ============================================================================
// This is the RAL register BLOCK: the container that holds all 7 registers
// and the address map that tells UVM where each register lives.
//
// Key decisions:
//   create_map("default_map", base_offset=0, n_bytes=1, endian)
//     n_bytes=1 → 8-bit bus width (matches the DUT's 8-bit cpu_rdata/cpu_wdata)
//
//   add_reg(reg_handle, offset, rights, maps)
//     rights here is "RW" for the map-level access (not field-level).
//     The offset matches i2c_reg_e values exactly.
//
//   lock_model() — MUST be called after all registers are added.
//     This finalises the address map and prevents accidental modification.
//     Without lock_model() the simulator may warn or segfault on first access.
// ============================================================================
class i2c_master_reg_block extends uvm_reg_block;

    `uvm_object_utils(i2c_master_reg_block)

    // Register handles — one per entry in i2c_reg_e
    i2c_ctrl_reg    CTRL;    // 0x0
    i2c_cmd_reg     CMD;     // 0x1
    i2c_status_reg  STATUS;  // 0x2
    i2c_data_reg    DATA;    // 0x3
    i2c_addr_reg    ADDR;    // 0x4
    i2c_irq_en_reg  IRQ_EN;  // 0x5
    i2c_irq_st_reg  IRQ_ST;  // 0x6

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "i2c_master_reg_block");
        // uvm_reg_block(name, has_coverage)
        super.new(name, UVM_NO_COVERAGE);
    endfunction

    // ------------------------------------------------------------------
    // build() — create registers, create map, add registers to map
    // ------------------------------------------------------------------
    virtual function void build();

        // ---- Step 1: Create each register object ----
        CTRL   = i2c_ctrl_reg::type_id::create("CTRL");
        CMD    = i2c_cmd_reg::type_id::create("CMD");
        STATUS = i2c_status_reg::type_id::create("STATUS");
        DATA   = i2c_data_reg::type_id::create("DATA");
        ADDR   = i2c_addr_reg::type_id::create("ADDR");
        IRQ_EN = i2c_irq_en_reg::type_id::create("IRQ_EN");
        IRQ_ST = i2c_irq_st_reg::type_id::create("IRQ_ST");

        // ---- Step 2: Build each register's fields ----
        CTRL.build();
        CMD.build();
        STATUS.build();
        DATA.build();
        ADDR.build();
        IRQ_EN.build();
        IRQ_ST.build();

        // ---- Step 3: Configure each register (parent=this block) ----
        // configure(parent, hdl_path) — hdl_path used for backdoor access
        // For now we leave hdl_path empty (no backdoor).
        CTRL.configure(  this, null, "");
        CMD.configure(   this, null, "");
        STATUS.configure(this, null, "");
        DATA.configure(  this, null, "");
        ADDR.configure(  this, null, "");
        IRQ_EN.configure(this, null, "");
        IRQ_ST.configure(this, null, "");

        // ---- Step 4: Create the default address map ----
        // create_map(name, base_addr, n_bytes, endian, byte_addressing)
        //   n_bytes=1 : each address location is 1 byte (8-bit bus)
        //   UVM_LITTLE_ENDIAN : standard for most embedded/CPU interfaces
        default_map = create_map("default_map", 'h0, 1, UVM_LITTLE_ENDIAN);

        // ---- Step 5: Add registers to the map ----
        // add_reg(register, offset, rights)
        //   offset matches i2c_reg_e enum values
        //   rights: "RW" at map level (field-level access types take precedence)
        default_map.add_reg(CTRL,   'h0, "RW");
        default_map.add_reg(CMD,    'h1, "WO");
        default_map.add_reg(STATUS, 'h2, "RO");
        default_map.add_reg(DATA,   'h3, "RW");
        default_map.add_reg(ADDR,   'h4, "RW");
        default_map.add_reg(IRQ_EN, 'h5, "RW");
        default_map.add_reg(IRQ_ST, 'h6, "RO");

        // ---- Step 6: Lock the model ----
        // MUST be called last — finalises all internal data structures.
        lock_model();

    endfunction

endclass : i2c_master_reg_block

`endif
