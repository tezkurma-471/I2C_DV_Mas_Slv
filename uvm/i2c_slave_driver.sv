//=============================================================================
// File          : i2c_slave_driver.sv
// Description   : UVM Driver for I2C Slave Control
//               : Reactively controls stretch_en, stretch_cycles,
//               : and force_data_nack based on sequence items.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_SLAVE_DRIVER_SV
`define I2C_SLAVE_DRIVER_SV

class i2c_slave_ctrl_item extends uvm_sequence_item;

  `uvm_object_utils(i2c_slave_ctrl_item)

  rand bit         stretch_en;
  rand logic [15:0] stretch_cycles;
  rand bit         force_data_nack;

  constraint stretch_cycles_c {
    stretch_cycles inside {[16'd1 : 16'd500]};
  }

  constraint stretch_en_off_c {
    stretch_en == 1'b0;
  }

  constraint force_nack_off_c {
    force_data_nack == 1'b0;
  }

  function new(string name = "i2c_slave_ctrl_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("slave_ctrl: stretch_en=%0b stretch_cycles=%0d force_nack=%0b",
                     stretch_en, stretch_cycles, force_data_nack);
  endfunction

endclass

class i2c_slave_driver extends uvm_driver #(i2c_slave_ctrl_item);

  `uvm_component_utils(i2c_slave_driver)

  virtual i2c_slave_if vif;

  // T13: Optional bus-level interface handle used when this driver acts as
  // a "competing master" to provoke arbitration loss. Only fetched when
  // compete_mode is set by the test via config_db; otherwise unused.
  virtual i2c_if       bus_vif;

  // T13: Competing-master mode controls (set by test via config_db)
  bit  compete_mode    = 1'b0;
  int  compete_at_bit  = 3;

  function new(string name = "i2c_slave_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual i2c_slave_if)::get(this, "", "i2c_slave_vif", vif)) begin
      `uvm_fatal(get_type_name(), "i2c_slave_vif not found in config_db")
    end
    // T13: Pull competing-master config (optional — defaults disable feature)
    void'(uvm_config_db#(bit)::get(this, "", "compete_mode",   compete_mode));
    void'(uvm_config_db#(int)::get(this, "", "compete_at_bit", compete_at_bit));
    if (compete_mode) begin
      if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", bus_vif)) begin
        `uvm_fatal(get_type_name(),
                   "compete_mode set but i2c_vif not found in config_db")
      end
      `uvm_info(get_type_name(),
                $sformatf("T13: compete_mode ENABLED, will collide at bit %0d",
                          compete_at_bit), UVM_LOW)
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.stretch_en      <= 1'b0;
    vif.stretch_cycles  <= 16'd0;
    vif.force_data_nack <= 1'b0;

    // T13: Spawn competing-master driver as a background process when enabled.
    // It runs concurrently with the normal slave-control behavior so existing
    // sequences (stretch, force_nack) are unaffected.
    if (compete_mode) begin
      fork
        drive_competition();
      join_none
    end

    forever begin
      seq_item_port.get_next_item(req);
      `uvm_info(get_type_name(), $sformatf("Applying: %s", req.convert2string()), UVM_MEDIUM)

      vif.stretch_en      <= req.stretch_en;
      vif.stretch_cycles  <= req.stretch_cycles;
      vif.force_data_nack <= req.force_data_nack;

      // FIX: Wait for slave to become active FIRST, then wait for transaction to complete.
      // Original bug: wait(active===0) passed immediately if slave wasn't yet active,
      // causing control signals to be cleared before the master even started.
      if (req.stretch_en) begin
        wait (vif.active === 1'b1);  // FIX: Wait for transaction to START
        wait (vif.active === 1'b0);  // Then wait for transaction to END
        vif.stretch_en      <= 1'b0;
        vif.stretch_cycles  <= 16'd0;
      end

      if (req.force_data_nack) begin
        wait (vif.active === 1'b1);  // FIX: Wait for transaction to START
        wait (vif.active === 1'b0);  // Then wait for transaction to END
        vif.force_data_nack <= 1'b0;
      end

      seq_item_port.item_done();
    end
  endtask

  //---------------------------------------------------------------------------
  // T13: Competing-master driver task
  // Waits for the master under test to issue START, then counts SCL pulses
  // until reaching `compete_at_bit`. At that point, pulls SDA low for one
  // SCL high window, which collides with the master's transmitted bit.
  // If the master is driving SDA HIGH at that moment, it sees sda_i=0 and
  // detects arbitration loss.
  //---------------------------------------------------------------------------
  virtual task drive_competition();
    `uvm_info(get_type_name(), "T13: competing master task started", UVM_MEDIUM)
    // Ensure released to start
    bus_vif.sda_drv_x <= 1'b1;

    // Wait for START condition: SDA falls while SCL is HIGH
    @(negedge bus_vif.sda);
    if (bus_vif.scl !== 1'b1) begin
      // Not a real START — wait again
      wait (bus_vif.sda === 1'b1 && bus_vif.scl === 1'b1);
      @(negedge bus_vif.sda);
    end
    `uvm_info(get_type_name(), "T13: detected START — counting SCL bits", UVM_MEDIUM)

    // Skip past addr byte + 1 ACK bit (8+1 = 9 SCL cycles already counted
    // implicitly via compete_at_bit). We count rising edges of SCL.
    for (int i = 0; i < compete_at_bit; i++) begin
      @(posedge bus_vif.scl);
    end

    // At the chosen bit position: drive SDA LOW during the next SCL HIGH
    @(negedge bus_vif.scl);             // wait for SCL to go LOW (bit change)
    bus_vif.sda_drv_x <= 1'b0;          // pull SDA LOW (compete)
    `uvm_info(get_type_name(),
              $sformatf("T13: pulling SDA LOW at bit %0d", compete_at_bit),
              UVM_LOW)
    @(posedge bus_vif.scl);             // hold through SCL HIGH window
    @(negedge bus_vif.scl);
    bus_vif.sda_drv_x <= 1'b1;          // release
    `uvm_info(get_type_name(), "T13: released SDA after collision", UVM_MEDIUM)
  endtask

endclass : i2c_slave_driver

`endif
