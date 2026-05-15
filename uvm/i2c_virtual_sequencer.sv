//=============================================================================
// File          : i2c_virtual_sequencer.sv
// Description   : UVM Virtual Sequencer for I2C Environment.
//               : Holds handles to the master and slave sequencers for
//               : coordinated multi-agent sequence execution.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_VIRTUAL_SEQUENCER_SV
`define I2C_VIRTUAL_SEQUENCER_SV

class i2c_virtual_sequencer extends uvm_sequencer;

  `uvm_component_utils(i2c_virtual_sequencer)

  // Handles to actual agent sequencers
  uvm_sequencer #(i2c_seq_item)        master_seqr;
  uvm_sequencer #(i2c_slave_ctrl_item) slave_seqr;

  function new(string name = "i2c_virtual_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass : i2c_virtual_sequencer

`endif
