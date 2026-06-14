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
// Coordinates the slave stretching SCL while the master drives a WRITE and
// then a READ transaction — the read leg closes the has_stretch x DIR_READ
// cross in i2c_stretch_dir_cross_cg.
//
// FIX (post-audit): the old version called finish_item(slave_ctrl) inline.
// The slave driver only calls item_done() AFTER the bus transaction
// completes (wait active 1->0), and the master traffic was started after
// finish_item — a guaranteed deadlock. The ctrl leg now runs in a fork.
//-----------------------------------------------------------------------------
class i2c_stretch_vseq extends i2c_base_vseq;

  `uvm_object_utils(i2c_stretch_vseq)

  function new(string name = "i2c_stretch_vseq");
    super.new(name);
  endfunction

  task arm_stretch(string name);
    i2c_slave_ctrl_item slave_ctrl;
    slave_ctrl = i2c_slave_ctrl_item::type_id::create(name);
    start_item(slave_ctrl, -1, p_sequencer.slave_seqr);
    slave_ctrl.stretch_en_off_c.constraint_mode(0);
    if (!slave_ctrl.randomize() with {
      stretch_en      == 1'b1;
      stretch_cycles  == 16'd300;
      force_data_nack == 1'b0;
    }) `uvm_fatal("VSEQ", "Randomization failed for slave_ctrl")
    finish_item(slave_ctrl, -1);
  endtask

  task body();
    i2c_single_write_seq master_write;
    i2c_single_read_seq  master_read;

    `uvm_info(get_type_name(), "Starting i2c_stretch_vseq", UVM_LOW)

    if (p_sequencer.slave_seqr == null) begin
      `uvm_fatal("VSEQ",
                 "slave_seqr is null — start this vseq with the slave agent UVM_ACTIVE")
    end

    // Leg 1: WRITE under stretch
    fork
      arm_stretch("stretch_for_write");
    join_none
    #200;  // let the ctrl item reach the slave driver before traffic starts
    master_write = i2c_single_write_seq::type_id::create("master_write");
    master_write.start(p_sequencer.master_seqr);

    // Leg 2: READ under stretch (covers stretch x DIR_READ)
    fork
      arm_stretch("stretch_for_read");
    join_none
    #200;
    master_read = i2c_single_read_seq::type_id::create("master_read");
    master_read.start(p_sequencer.master_seqr);

    wait fork;  // drain the ctrl legs

    `uvm_info(get_type_name(), "Finished i2c_stretch_vseq", UVM_LOW)
  endtask

endclass : i2c_stretch_vseq

`endif
