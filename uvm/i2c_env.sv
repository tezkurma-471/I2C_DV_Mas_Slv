//=============================================================================
// File          : i2c_env.sv
// Description   : UVM Environment — top-level UVM container.
//               : V3: Added virtual sequencer with handle wiring.
//               : Slave agent defaults to PASSIVE. Tests that need
//               : it ACTIVE set config_db before super.build_phase().
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_ENV_SV
`define I2C_ENV_SV

class i2c_env extends uvm_env;

  `uvm_component_utils(i2c_env)

  i2c_master_agent       master_agent;
  i2c_slave_agent        slave_agent;
  i2c_scoreboard         scoreboard;
  i2c_coverage           coverage;
  i2c_virtual_sequencer  v_sequencer;

  uvm_active_passive_enum slave_is_active;

  function new(string name = "i2c_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    master_agent    = i2c_master_agent::type_id::create("master_agent", this);

    if (!uvm_config_db#(uvm_active_passive_enum)::get(this, "slave_agent", "is_active", slave_is_active)) begin
      uvm_config_db#(uvm_active_passive_enum)::set(this, "slave_agent", "is_active", UVM_PASSIVE);
    end
    slave_agent     = i2c_slave_agent::type_id::create("slave_agent",  this);
    scoreboard      = i2c_scoreboard::type_id::create("scoreboard",     this);
    coverage        = i2c_coverage::type_id::create("coverage",         this);
    v_sequencer     = i2c_virtual_sequencer::type_id::create("v_sequencer", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    // Scoreboard connections
    master_agent.monitor.item_collected_port.connect(scoreboard.actual_export);
    master_agent.monitor.item_collected_port.connect(coverage.analysis_export);
    master_agent.driver.req_analysis_port.connect(scoreboard.expected_export);

    // Virtual sequencer handle wiring
    v_sequencer.master_seqr = master_agent.sequencer;
    if (slave_agent.get_is_active() == UVM_ACTIVE) begin
      v_sequencer.slave_seqr = slave_agent.sequencer;
    end
  endfunction

endclass : i2c_env

`endif
