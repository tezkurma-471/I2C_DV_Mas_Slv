//=============================================================================
// File          : i2c_ral_test.sv
// Description   : UVM tests for the I2C RAL register interface.
//               : Three tests, each exercising a different RAL sequence.
//               : All extend uvm_test directly (NOT i2c_base_test) because
//               : they use i2c_ral_env, not i2c_env.
//
// TESTS:
//   1. i2c_ral_reset_test   — reset value check on all 7 registers
//   2. i2c_ral_program_test — program master for a WRITE transaction
//   3. i2c_ral_field_test   — field-level read-modify-write demo
//
// USAGE (with top_tb_ral.sv):
//   vsim top_tb_ral +UVM_TESTNAME=i2c_ral_reset_test
//   vsim top_tb_ral +UVM_TESTNAME=i2c_ral_program_test
//   vsim top_tb_ral +UVM_TESTNAME=i2c_ral_field_test
//
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_RAL_TEST_SV
`define I2C_RAL_TEST_SV


// ============================================================================
// SHARED HELPER: report_phase
// ============================================================================
// All three tests use the same pass/fail reporting logic.
// Implemented as a macro-like pattern inside each class to avoid needing
// a separate base class (keeping the file self-contained).
// ============================================================================


// ============================================================================
// TEST 1: i2c_ral_reset_test
// ============================================================================
// Verifies that all readable registers reset to 0x00 after hardware reset.
// This is the "sanity check" — if this fails, nothing else will work.
// ============================================================================
class i2c_ral_reset_test extends uvm_test;

    `uvm_component_utils(i2c_ral_reset_test)

    i2c_ral_env env;

    function new(string name = "i2c_ral_reset_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // build_phase — create the RAL environment
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = i2c_ral_env::type_id::create("env", this);
    endfunction

    // run_phase — raise objection, create + start sequence, drop objection
    task run_phase(uvm_phase phase);
        i2c_reg_reset_check_seq seq;
        phase.raise_objection(this, "i2c_ral_reset_test starting");

        `uvm_info(get_type_name(), "=== RAL Reset Test Starting ===", UVM_LOW)

        // Allow a few cycles for DUT reset to complete
        #200;

        seq = i2c_reg_reset_check_seq::type_id::create("seq");
        // Start the sequence on the CPU agent's sequencer
        // The RAL framework redirects register ops to this sequencer via the adapter
        seq.start(env.cpu_agent.sequencer);

        `uvm_info(get_type_name(), "=== RAL Reset Test Complete ===", UVM_LOW)
        phase.drop_objection(this, "i2c_ral_reset_test done");
    endtask

    // report_phase — pass/fail summary
    function void report_phase(uvm_phase phase);
        uvm_report_server server;
        int err_count;
        super.report_phase(phase);
        server    = uvm_report_server::get_server();
        err_count = server.get_severity_count(UVM_ERROR);
        if (err_count == 0)
            `uvm_info(get_type_name(), "TEST PASSED: No UVM_ERROR messages", UVM_LOW)
        else
            `uvm_error(get_type_name(),
                $sformatf("TEST FAILED: %0d UVM_ERROR messages", err_count))
    endfunction

endclass : i2c_ral_reset_test


// ============================================================================
// TEST 2: i2c_ral_program_test
// ============================================================================
// Programs the I2C master controller registers for a WRITE transaction.
// Demonstrates register programming via RAL instead of manual seq items.
// ============================================================================
class i2c_ral_program_test extends uvm_test;

    `uvm_component_utils(i2c_ral_program_test)

    i2c_ral_env env;

    function new(string name = "i2c_ral_program_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = i2c_ral_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        i2c_reg_program_master_seq seq;
        phase.raise_objection(this, "i2c_ral_program_test starting");

        `uvm_info(get_type_name(), "=== RAL Program Test Starting ===", UVM_LOW)

        #200;  // wait for DUT reset

        seq = i2c_reg_program_master_seq::type_id::create("seq");
        seq.start(env.cpu_agent.sequencer);

        `uvm_info(get_type_name(), "=== RAL Program Test Complete ===", UVM_LOW)
        phase.drop_objection(this, "i2c_ral_program_test done");
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server server;
        int err_count;
        super.report_phase(phase);
        server    = uvm_report_server::get_server();
        err_count = server.get_severity_count(UVM_ERROR);
        if (err_count == 0)
            `uvm_info(get_type_name(), "TEST PASSED: No UVM_ERROR messages", UVM_LOW)
        else
            `uvm_error(get_type_name(),
                $sformatf("TEST FAILED: %0d UVM_ERROR messages", err_count))
    endfunction

endclass : i2c_ral_program_test


// ============================================================================
// TEST 3: i2c_ral_field_test
// ============================================================================
// Demonstrates field-level read-modify-write access.
// Shows that setting one field does not corrupt adjacent fields.
// ============================================================================
class i2c_ral_field_test extends uvm_test;

    `uvm_component_utils(i2c_ral_field_test)

    i2c_ral_env env;

    function new(string name = "i2c_ral_field_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = i2c_ral_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        i2c_ctrl_field_seq seq;
        phase.raise_objection(this, "i2c_ral_field_test starting");

        `uvm_info(get_type_name(), "=== RAL Field Test Starting ===", UVM_LOW)

        #200;  // wait for DUT reset

        seq = i2c_ctrl_field_seq::type_id::create("seq");
        seq.start(env.cpu_agent.sequencer);

        `uvm_info(get_type_name(), "=== RAL Field Test Complete ===", UVM_LOW)
        phase.drop_objection(this, "i2c_ral_field_test done");
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server server;
        int err_count;
        super.report_phase(phase);
        server    = uvm_report_server::get_server();
        err_count = server.get_severity_count(UVM_ERROR);
        if (err_count == 0)
            `uvm_info(get_type_name(), "TEST PASSED: No UVM_ERROR messages", UVM_LOW)
        else
            `uvm_error(get_type_name(),
                $sformatf("TEST FAILED: %0d UVM_ERROR messages", err_count))
    endfunction

endclass : i2c_ral_field_test

`endif
