//=============================================================================
// File          : i2c_ral_seq.sv
// Description   : UVM RAL sequences for the I2C master register interface.
//               : Contains 4 sequences demonstrating different RAL access patterns.
//
// SEQUENCE LIST:
//   1. i2c_ral_base_seq         — base class; fetches reg_model from config_db
//   2. i2c_reg_reset_check_seq  — verify all registers reset to 0x00
//   3. i2c_reg_program_master_seq — program I2C master for a WRITE transaction
//   4. i2c_ctrl_field_seq       — demonstrate field-level read-modify-write
//
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_RAL_SEQ_SV
`define I2C_RAL_SEQ_SV


// ============================================================================
// 1. BASE SEQUENCE — i2c_ral_base_seq
// ============================================================================
// All RAL sequences inherit from this class to share the register model handle.
//
// TEACHING NOTE — pre_body() vs body():
//   pre_body() runs BEFORE body() every time the sequence is started.
//   It's the right place to fetch config_db handles that your body() needs.
//   This way derived classes don't need to repeat the config_db lookup.
// ============================================================================
class i2c_ral_base_seq extends uvm_sequence #(i2c_cpu_seq_item);

    `uvm_object_utils(i2c_ral_base_seq)

    // Handle to the shared register model
    i2c_master_reg_block reg_model;

    function new(string name = "i2c_ral_base_seq");
        super.new(name);
    endfunction

    // Fetch the register model before body() runs
    task pre_body();
        if (!uvm_config_db #(i2c_master_reg_block)::get(
                m_sequencer, "", "reg_model", reg_model)) begin
            `uvm_fatal("NO_REG_MODEL",
                {get_type_name(), ": reg_model not found in config_db. ",
                 "Check that i2c_ral_env.build_phase sets it."})
        end
        `uvm_info(get_type_name(),
            "pre_body: reg_model retrieved from config_db", UVM_LOW)
    endtask

endclass : i2c_ral_base_seq


// ============================================================================
// 2. RESET CHECK SEQUENCE — i2c_reg_reset_check_seq
// ============================================================================
// After reset, all writable registers must read back as 0x00.
// This is the simplest possible RAL test and should always pass first.
//
// BEFORE RAL — you would write something like this for each register:
//   i2c_cpu_seq_item item = i2c_cpu_seq_item::type_id::create("item");
//   item.cpu_addr  = 3'h0;  // REG_CTRL
//   item.cpu_wr    = 0;
//   item.start_item(item); item.finish_item(item);
//   if (item.cpu_rdata !== 8'h00) `uvm_error(...)
//   // ... repeat for all 7 registers with different cpu_addr values
//   // No tracking of what you expected vs got, manual error checking
//
// WITH RAL:
//   reg_model.reset();           // tells RAL: mirror should be 0x00 for all regs
//   reg_model.CTRL.read(status, rdata);   // reads from DUT
//   // RAL automatically compares rdata with mirror (if check=UVM_CHECK)
//   // Plus you get self-documenting code: "read CTRL" not "cpu_addr=3'h0"
// ============================================================================
class i2c_reg_reset_check_seq extends i2c_ral_base_seq;

    `uvm_object_utils(i2c_reg_reset_check_seq)

    function new(string name = "i2c_reg_reset_check_seq");
        super.new(name);
    endfunction

    task body();
        uvm_status_e  status;
        uvm_reg_data_t rdata;
        int            errors;

        `uvm_info(get_type_name(), "=== Reset Check Sequence Starting ===", UVM_LOW)

        // ----------------------------------------------------------------
        // Step 1: Tell RAL "we just came out of reset — mirror = reset values"
        // ----------------------------------------------------------------
        // reg_model.reset() sets the RAL shadow/mirror register for every field
        // to its configured reset value (all 0x00 in our case).
        // This synchronises the RAL model's internal state with the DUT's state
        // right after hardware reset asserts+deasserts.
        // ----------------------------------------------------------------
        reg_model.reset();

        errors = 0;

        // ----------------------------------------------------------------
        // Step 2: Read each register and check against 0x00
        // ----------------------------------------------------------------
        // .read(status, rdata) performs:
        //   1. Calls adapter.reg2bus() to create an i2c_cpu_seq_item
        //   2. Sends it to the CPU agent's sequencer
        //   3. Driver wiggles cpu_addr/cpu_wr, samples cpu_rdata
        //   4. Returns rdata to us here
        //
        // We pass UVM_CHECK as the check arg to ask RAL to compare rdata
        // with the mirror.  Any mismatch becomes a UVM_ERROR automatically.
        // ----------------------------------------------------------------

        // REG_CTRL (0x0) — RW — expect 0x00
        reg_model.CTRL.read(status, rdata, UVM_FRONTDOOR, reg_model.default_map, this);
        if (rdata !== 8'h00) begin
            `uvm_error(get_type_name(),
                $sformatf("CTRL reset check FAIL: expected 0x00, got 0x%02h", rdata))
            errors++;
        end else
            `uvm_info(get_type_name(), "CTRL  = 0x00 PASS", UVM_LOW)

        // REG_CMD (0x1) — WO — reads must return 0x00.
        // FIX (post-audit): CMD was the only register this sequence skipped,
        // so its write-only behavior was never verified.
        reg_model.CMD.read(status, rdata, UVM_FRONTDOOR, reg_model.default_map, this);
        if (rdata !== 8'h00) begin
            `uvm_error(get_type_name(),
                $sformatf("CMD WO check FAIL: write-only reg read 0x%02h, expected 0x00", rdata))
            errors++;
        end else
            `uvm_info(get_type_name(), "CMD    = 0x00 (WO) PASS", UVM_LOW)

        // REG_STATUS (0x2) — RO — expect 0x00
        reg_model.STATUS.read(status, rdata, UVM_FRONTDOOR, reg_model.default_map, this);
        if (rdata !== 8'h00) begin
            `uvm_error(get_type_name(),
                $sformatf("STATUS reset check FAIL: expected 0x00, got 0x%02h", rdata))
            errors++;
        end else
            `uvm_info(get_type_name(), "STATUS = 0x00 PASS", UVM_LOW)

        // REG_DATA (0x3) — RW — expect 0x00
        reg_model.DATA.read(status, rdata, UVM_FRONTDOOR, reg_model.default_map, this);
        if (rdata !== 8'h00) begin
            `uvm_error(get_type_name(),
                $sformatf("DATA reset check FAIL: expected 0x00, got 0x%02h", rdata))
            errors++;
        end else
            `uvm_info(get_type_name(), "DATA   = 0x00 PASS", UVM_LOW)

        // REG_ADDR (0x4) — RW — expect 0x00
        reg_model.ADDR.read(status, rdata, UVM_FRONTDOOR, reg_model.default_map, this);
        if (rdata !== 8'h00) begin
            `uvm_error(get_type_name(),
                $sformatf("ADDR reset check FAIL: expected 0x00, got 0x%02h", rdata))
            errors++;
        end else
            `uvm_info(get_type_name(), "ADDR   = 0x00 PASS", UVM_LOW)

        // REG_IRQ_EN (0x5) — RW — expect 0x00
        reg_model.IRQ_EN.read(status, rdata, UVM_FRONTDOOR, reg_model.default_map, this);
        if (rdata !== 8'h00) begin
            `uvm_error(get_type_name(),
                $sformatf("IRQ_EN reset check FAIL: expected 0x00, got 0x%02h", rdata))
            errors++;
        end else
            `uvm_info(get_type_name(), "IRQ_EN = 0x00 PASS", UVM_LOW)

        // REG_IRQ_ST (0x6) — RO — reads back reg_status = STS_IDLE = 0x00
        reg_model.IRQ_ST.read(status, rdata, UVM_FRONTDOOR, reg_model.default_map, this);
        if (rdata !== 8'h00) begin
            `uvm_error(get_type_name(),
                $sformatf("IRQ_ST reset check FAIL: expected 0x00, got 0x%02h", rdata))
            errors++;
        end else
            `uvm_info(get_type_name(), "IRQ_ST = 0x00 PASS", UVM_LOW)

        // REG_CTRL re-read to confirm RW works (write then read)
        reg_model.CTRL.write(status, 8'h03, UVM_FRONTDOOR, reg_model.default_map, this);
        reg_model.CTRL.read( status, rdata, UVM_FRONTDOOR, reg_model.default_map, this);
        if (rdata !== 8'h03) begin
            `uvm_error(get_type_name(),
                $sformatf("CTRL write/read-back FAIL: expected 0x03, got 0x%02h", rdata))
            errors++;
        end else
            `uvm_info(get_type_name(), "CTRL write/read-back = 0x03 PASS", UVM_LOW)

        // Summary
        if (errors == 0)
            `uvm_info(get_type_name(), "=== Reset Check PASSED ===", UVM_LOW)
        else
            `uvm_error(get_type_name(),
                $sformatf("=== Reset Check FAILED: %0d errors ===", errors))

    endtask

endclass : i2c_reg_reset_check_seq


// ============================================================================
// 3. PROGRAM MASTER SEQUENCE — i2c_reg_program_master_seq
// ============================================================================
// Programs the I2C master controller for a WRITE transaction to slave 0x50.
//
// ---- BEFORE RAL (raw item manipulation) ----
//   // Step 1: Enable master
//   item = i2c_cpu_seq_item::type_id::create("item");
//   item.cpu_addr = 3'h0; item.cpu_wr = 1; item.cpu_wdata = 8'h01;
//   item.start_item(item); item.finish_item(item);
//
//   // Step 2: Set address byte (addr=0x50, dir=WRITE → 0xA0)
//   item.cpu_addr = 3'h4; item.cpu_wr = 1; item.cpu_wdata = 8'hA0;
//   item.start_item(item); item.finish_item(item);
//   // PROBLEM: you have to manually pack {SLAVE_ADDR[6:0], DIR}
//   // into a byte.  Easy to get wrong.  No self-documentation.
//
// ---- WITH RAL ----
//   reg_model.CTRL.EN.set(1);          // set individual field value in mirror
//   reg_model.CTRL.update(status);     // write only changed bits to DUT
//   reg_model.ADDR.SLAVE_ADDR.set(7'h50);
//   reg_model.ADDR.DIR.set(DIR_WRITE); // dir=0
//   reg_model.ADDR.update(status);     // packs fields automatically
// ============================================================================
class i2c_reg_program_master_seq extends i2c_ral_base_seq;

    `uvm_object_utils(i2c_reg_program_master_seq)

    function new(string name = "i2c_reg_program_master_seq");
        super.new(name);
    endfunction

    task body();
        uvm_status_e   status;
        uvm_reg_data_t rdata;

        `uvm_info(get_type_name(),
            "=== Program Master Sequence Starting (WRITE to slave 0x50) ===",
            UVM_LOW)

        // ----------------------------------------------------------------
        // Step 1: Enable the I2C master
        // ----------------------------------------------------------------
        // .set() updates the RAL MIRROR only (no bus access yet)
        // .update() compares mirror vs DUT-assumed value; writes if different
        // This implements read-modify-write atomically — EN is set WITHOUT
        // disturbing IRQ_GLOBAL_EN even though they share the same byte.
        // ----------------------------------------------------------------
        reg_model.CTRL.EN.set(1'b1);
        reg_model.CTRL.update(status, UVM_FRONTDOOR, reg_model.default_map, this);
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "CTRL.update failed")
        else
            `uvm_info(get_type_name(), "Step 1: Master enabled (CTRL.EN=1)", UVM_LOW)

        // ----------------------------------------------------------------
        // Step 2: Configure target slave address + direction
        // ----------------------------------------------------------------
        // RAL packs SLAVE_ADDR[7:1] and DIR[0] automatically.
        // Without RAL, you must manually compute:
        //   cpu_wdata = {SLAVE_ADDR[6:0], DIR} = {7'h50, 1'b0} = 8'hA0
        // With RAL, each field is set independently — no bit-packing error.
        // ----------------------------------------------------------------
        reg_model.ADDR.SLAVE_ADDR.set(7'h50);       // target slave address
        reg_model.ADDR.DIR.set(i2c_dir_e'(DIR_WRITE));  // direction = WRITE
        reg_model.ADDR.update(status, UVM_FRONTDOOR, reg_model.default_map, this);
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "ADDR.update failed")
        else
            `uvm_info(get_type_name(),
                "Step 2: Slave addr=0x50, DIR=WRITE programmed", UVM_LOW)

        // ----------------------------------------------------------------
        // Step 3: Load transmit data
        // ----------------------------------------------------------------
        // .write() directly sends the value to the DUT (no .set/.update needed)
        // Use .write() when you don't need field-level granularity.
        // Use .set() + .update() when you want to change one field at a time.
        // ----------------------------------------------------------------
        reg_model.DATA.write(status, 8'hAB, UVM_FRONTDOOR,
                             reg_model.default_map, this);
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "DATA.write failed")
        else
            `uvm_info(get_type_name(), "Step 3: TX data=0xAB loaded", UVM_LOW)

        // ----------------------------------------------------------------
        // Step 4: Issue START command
        // ----------------------------------------------------------------
        // CMD register is WO — writing CMD_START=0x1 triggers FSM.
        // RAL knows CMD is WO and will not attempt readback after write.
        // ----------------------------------------------------------------
        reg_model.CMD.write(status, {4'h0, CMD_START}, UVM_FRONTDOOR,
                            reg_model.default_map, this);
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "CMD.write(START) failed")
        else
            `uvm_info(get_type_name(), "Step 4: CMD=CMD_START written", UVM_LOW)

        // ----------------------------------------------------------------
        // Step 5: Poll STATUS — read it and log
        // ----------------------------------------------------------------
        // STATUS is RO + volatile. RAL won't try to write it.
        // In a real test you'd poll until STATUS != STS_IDLE/STS_BUSY.
        // Here we just read once to demonstrate the flow.
        //
        // NOTE: Since the SCL/SDA bus has no slave in RAL tests, the master
        // FSM will not complete a real I2C transaction.  The goal here is
        // to verify the REGISTER PROGRAMMING path, not the bus behavior.
        // ----------------------------------------------------------------
        reg_model.STATUS.read(status, rdata, UVM_FRONTDOOR,
                              reg_model.default_map, this);
        `uvm_info(get_type_name(),
            $sformatf("Step 5: STATUS = 0x%02h (STS_IDLE=0, STS_BUSY=1)", rdata),
            UVM_LOW)

        `uvm_info(get_type_name(),
            "=== Program Master Sequence Complete ===", UVM_LOW)

    endtask

endclass : i2c_reg_program_master_seq


// ============================================================================
// 4. FIELD-LEVEL ACCESS SEQUENCE — i2c_ctrl_field_seq
// ============================================================================
// Demonstrates the KEY advantage of RAL: field-level access without needing
// manual read-modify-write.
//
// SCENARIO: CTRL register has two fields — EN[0] and IRQ_GLOBAL_EN[1].
//
// ---- WITHOUT RAL (write EN without touching IRQ_GLOBAL_EN) ----
//   // Must do: read → mask → OR → write  (3 bus transactions)
//   item.cpu_addr = 3'h0; item.cpu_wr = 0;            // READ
//   item.start_item(item); item.finish_item(item);
//   old_val = item.cpu_rdata;
//   new_val = (old_val & 8'hFE) | 8'h01;              // MASK (clear bit0) | SET bit0
//   item.cpu_addr = 3'h0; item.cpu_wr = 1;            // WRITE
//   item.cpu_wdata = new_val;
//   item.start_item(item); item.finish_item(item);
//   // 2 bus accesses, manual bit manipulation, error-prone
//
// ---- WITH RAL ----
//   reg_model.CTRL.EN.set(1);          // 1 mirror update
//   reg_model.CTRL.update(status);     // 1 bus write (with correct mask)
//   // RAL automatically reads CTRL, masks bit0, OR's with 1, writes back
//   // IRQ_GLOBAL_EN is untouched.
// ============================================================================
class i2c_ctrl_field_seq extends i2c_ral_base_seq;

    `uvm_object_utils(i2c_ctrl_field_seq)

    function new(string name = "i2c_ctrl_field_seq");
        super.new(name);
    endfunction

    task body();
        uvm_status_e   status;
        uvm_reg_data_t rdata;

        `uvm_info(get_type_name(),
            "=== Field-Level Access Sequence Starting ===", UVM_LOW)

        // ----------------------------------------------------------------
        // Setup: enable both EN and IRQ_GLOBAL_EN
        // ----------------------------------------------------------------
        reg_model.CTRL.write(status, 8'h03, UVM_FRONTDOOR,
                             reg_model.default_map, this);
        `uvm_info(get_type_name(),
            "Setup: CTRL written as 0x03 (EN=1, IRQ_GLOBAL_EN=1)", UVM_LOW)

        // Readback to confirm
        reg_model.CTRL.read(status, rdata, UVM_FRONTDOOR,
                            reg_model.default_map, this);
        `uvm_info(get_type_name(),
            $sformatf("Readback: CTRL = 0x%02h (expect 0x03)", rdata), UVM_LOW)

        // ----------------------------------------------------------------
        // Test: Set ONLY EN=0, leave IRQ_GLOBAL_EN untouched
        // ----------------------------------------------------------------
        // .set() updates the local mirror WITHOUT touching the bus.
        // .update() compares mirror vs current presumed value and writes
        //           ONLY the byte if it changed — but the byte write
        //           contains BOTH fields (RAL packs them correctly).
        //
        // Result: CTRL becomes {rsvd[7:2], IRQ_GLOBAL_EN=1, EN=0} = 0x02
        // Without RAL you'd risk accidentally clearing IRQ_GLOBAL_EN to 0.
        // ----------------------------------------------------------------
        reg_model.CTRL.EN.set(1'b0);
        reg_model.CTRL.update(status, UVM_FRONTDOOR, reg_model.default_map, this);
        `uvm_info(get_type_name(),
            "Field write: CTRL.EN set to 0 (IRQ_GLOBAL_EN should stay 1)", UVM_LOW)

        // Readback and verify
        reg_model.CTRL.read(status, rdata, UVM_FRONTDOOR,
                            reg_model.default_map, this);
        if (rdata !== 8'h02)
            `uvm_error(get_type_name(),
                $sformatf("FAIL: CTRL expected 0x02, got 0x%02h "
                          "(IRQ_GLOBAL_EN may have been cleared incorrectly)", rdata))
        else
            `uvm_info(get_type_name(),
                "PASS: CTRL = 0x02 (EN=0, IRQ_GLOBAL_EN=1 preserved)", UVM_LOW)

        // ----------------------------------------------------------------
        // Bonus: Use get_mirrored_value() — reads RAL's internal shadow
        // ----------------------------------------------------------------
        // .get_mirrored_value() returns what RAL THINKS the register contains
        // WITHOUT doing a bus transaction.  Useful for checking in scoreboards.
        // ----------------------------------------------------------------
        begin
            uvm_reg_data_t mirror_val;
            mirror_val = reg_model.CTRL.get_mirrored_value();
            `uvm_info(get_type_name(),
                $sformatf("RAL mirror value: CTRL = 0x%02h (no bus access)", mirror_val),
                UVM_LOW)
        end

        `uvm_info(get_type_name(),
            "=== Field-Level Access Sequence Complete ===", UVM_LOW)

    endtask

endclass : i2c_ctrl_field_seq

`endif
