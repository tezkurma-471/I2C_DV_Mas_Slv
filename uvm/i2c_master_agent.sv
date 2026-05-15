//=============================================================================
// File          : i2c_master_agent.sv
// Description   : UVM Agent for I2C Master — wraps driver, monitor, sequencer.
//               : Active agent: drives stimulus AND observes the bus.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_MASTER_AGENT_SV
`define I2C_MASTER_AGENT_SV

class i2c_master_agent extends uvm_agent;

  `uvm_component_utils(i2c_master_agent)

  //-------------------------------------------------------------------------
  // Sub-components
  //-------------------------------------------------------------------------
  i2c_driver              driver;
  i2c_monitor             monitor;
  uvm_sequencer #(i2c_seq_item) sequencer;

  //-------------------------------------------------------------------------
  // TLM Analysis Port — broadcasts items observed by the monitor.
  // The environment connects this to the scoreboard's actual_export.
  //-------------------------------------------------------------------------
  uvm_analysis_port #(i2c_seq_item) analysis_port;

  //-------------------------------------------------------------------------
  // Constructor
  //-------------------------------------------------------------------------
  function new(string name = "i2c_master_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  //-------------------------------------------------------------------------
  // Build Phase — create sub-components
  //-------------------------------------------------------------------------
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Only instantiate driver and sequencer for ACTIVE agent
    // (UVM_ACTIVE is the default; pass UVM_PASSIVE to disable driving)
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = i2c_driver::type_id::create("driver",    this);
      sequencer = uvm_sequencer #(i2c_seq_item)::type_id::create("sequencer", this);
    end
    monitor       = i2c_monitor::type_id::create("monitor", this);
    analysis_port = new("analysis_port", this);
  endfunction

  //-------------------------------------------------------------------------
  // Connect Phase — wire driver↔sequencer; forward monitor's port
  //-------------------------------------------------------------------------
  function void connect_phase(uvm_phase phase);
    // Wire sequencer output to driver input (TLM seq_item_port)
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
    // Forward monitor observations to the agent's analysis port
    // (environment then connects this to scoreboard)
    monitor.item_collected_port.connect(analysis_port);
  endfunction

endclass : i2c_master_agent

`endif
