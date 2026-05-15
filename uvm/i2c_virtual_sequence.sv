//=============================================================================
// File          : i2c_virtual_sequence.sv
// Description   : UVM Virtual Sequence Library for I2C Environment.
//               : Coordinates master traffic and slave stretch/NACK behaviors.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_VIRTUAL_SEQUENCE_SV
`define I2C_VIRTUAL_SEQUENCE_SV

//-----------------------------------------------------------------------------
// Base Virtual Sequence
//-----------------------------------------------------------------------------
class i2c_base_vseq extends uvm_sequence;

  `uvm_object_utils(i2c_base_vseq)
  `uvm_declare_p_sequencer(i2c_virtual_sequencer)

  function new(string name = "i2c_base_vseq");
    super.new(name);
  endfunction

endclass : i2c_base_vseq

//-----------------------------------------------------------------------------
// Clock Stretch Virtual Sequence
// Coordinates the master sending a write transaction while the slave stretches.
//-----------------------------------------------------------------------------
class i2c_stretch_vseq extends i2c_base_vseq;

  `uvm_object_utils(i2c_stretch_vseq)

  function new(string name = "i2c_stretch_vseq");
    super.new(name);
  endfunction

  task body();
    i2c_single_write_seq master_write;
    i2c_slave_ctrl_item  slave_ctrl;

    `uvm_info(get_type_name(), "Starting i2c_stretch_vseq", UVM_LOW)

    // 1. Configure the slave to stretch the clock
    slave_ctrl = i2c_slave_ctrl_item::type_id::create("slave_ctrl");
    start_item(slave_ctrl, -1, p_sequencer.slave_seqr);
    slave_ctrl.stretch_en_off_c.constraint_mode(0);
    slave_ctrl.force_nack_off_c.constraint_mode(0);
    if (!slave_ctrl.randomize() with {
      stretch_en == 1'b1;
      stretch_cycles == 16'd50; // Stretch for 50 cycles
    }) `uvm_fatal("VSEQ", "Randomization failed for slave_ctrl")
    finish_item(slave_ctrl, -1);

    // 2. Send master traffic
    master_write = i2c_single_write_seq::type_id::create("master_write");
    master_write.start(p_sequencer.master_seqr);

    `uvm_info(get_type_name(), "Finished i2c_stretch_vseq", UVM_LOW)
  endtask

endclass : i2c_stretch_vseq

`endif
