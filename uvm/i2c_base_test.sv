//=============================================================================
// File          : i2c_base_test.sv
// Description   : UVM Base Test — uses i2c_write_read_seq from the library.
//               : V2: Proper pass/fail reporting in report_phase.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_BASE_TEST_SV
`define I2C_BASE_TEST_SV

class i2c_base_test extends uvm_test;

  `uvm_component_utils(i2c_base_test)

  i2c_env env;

  function new(string name = "i2c_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = i2c_env::type_id::create("env", this);
  endfunction

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

endclass : i2c_base_test

`endif
