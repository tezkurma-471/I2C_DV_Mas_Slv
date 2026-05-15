//=============================================================================
// File          : i2c_slave_agent.sv
// Description   : UVM Agent for I2C Slave — wraps slave monitor and slave driver.
//               : Default is PASSIVE (set by env). Tests override via config_db
//               : with path "*env.slave_agent" before super.build_phase().
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_SLAVE_AGENT_SV
`define I2C_SLAVE_AGENT_SV

class i2c_slave_agent extends uvm_agent;

  `uvm_component_utils(i2c_slave_agent)

  i2c_slave_driver              driver;
  i2c_slave_monitor             monitor;
  uvm_sequencer #(i2c_slave_ctrl_item) sequencer;

  function new(string name = "i2c_slave_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = i2c_slave_monitor::type_id::create("monitor", this);
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = i2c_slave_driver::type_id::create("driver", this);
      sequencer = uvm_sequencer #(i2c_slave_ctrl_item)::type_id::create("sequencer", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction

endclass : i2c_slave_agent

`endif
