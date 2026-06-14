//=============================================================================
// File          : i2c_tb_ral_pkg.sv
// Description   : UVM package for all RAL testbench components.
//               : Separate from i2c_tb_pkg.sv to avoid pulling in the full
//               : bus-level testbench (slave agent, scoreboard, etc.) when
//               : only register-level testing is needed.
//
// INCLUDE ORDER MATTERS:
//   Components must be included BEFORE anything that uses them.
//   Dependency chain:
//     seq_item → reg_model → adapter → driver → agent → seq → env → tests
//
// HOW TO USE:
//   In top_tb_ral.sv:
//     import i2c_tb_ral_pkg::*;
//   Then run:
//     vsim top_tb_ral +UVM_TESTNAME=i2c_ral_reset_test
//     vsim top_tb_ral +UVM_TESTNAME=i2c_ral_program_test
//     vsim top_tb_ral +UVM_TESTNAME=i2c_ral_field_test
//
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_TB_RAL_PKG_SV
`define I2C_TB_RAL_PKG_SV

package i2c_tb_ral_pkg;

    // UVM base library
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // I2C RTL types (i2c_reg_e, i2c_cmd_e, i2c_dir_e, i2c_status_e, etc.)
    import i2c_pkg::*;

    // ----------------------------------------------------------------
    // 1. Transaction item — the bus-level transaction type
    //    (must be first; everything else depends on it)
    // ----------------------------------------------------------------
    `include "uvm/i2c_cpu_seq_item.sv"

    // ----------------------------------------------------------------
    // 2. Register model — the RAL register block + all register classes
    //    (depends on i2c_cpu_seq_item for field configuration)
    // ----------------------------------------------------------------
    `include "ral/i2c_master_reg_model.sv"

    // ----------------------------------------------------------------
    // 3. Register adapter — translates reg ops ↔ seq items
    //    (depends on both seq_item and reg model types)
    // ----------------------------------------------------------------
    `include "ral/i2c_reg_adapter.sv"

    // ----------------------------------------------------------------
    // 4. CPU Driver — drives i2c_reg_if based on seq items
    //    (depends on seq_item)
    // ----------------------------------------------------------------
    `include "uvm/i2c_cpu_driver.sv"

    // ----------------------------------------------------------------
    // 5. CPU Agent — packages driver + sequencer
    //    (depends on driver and seq_item)
    // ----------------------------------------------------------------
    `include "uvm/i2c_cpu_agent.sv"

    // ----------------------------------------------------------------
    // 6. RAL Sequences — reset check, program master, field access
    //    (depends on reg model, adapter, seq_item)
    // ----------------------------------------------------------------
    `include "ral/i2c_ral_seq.sv"

    // ----------------------------------------------------------------
    // 7. RAL Environment — wires everything together
    //    (depends on agent, reg model, adapter)
    // ----------------------------------------------------------------
    `include "uvm/i2c_ral_env.sv"

    // ----------------------------------------------------------------
    // 8. RAL Tests — 3 tests using the RAL env + sequences
    //    (depends on env and sequences — must be last)
    // ----------------------------------------------------------------
    `include "uvm/i2c_ral_test.sv"

endpackage : i2c_tb_ral_pkg

`endif
