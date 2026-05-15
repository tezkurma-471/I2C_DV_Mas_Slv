//=============================================================================
// File          : i2c_master_driver.sv (FIXED)
// Description   : UVM Driver for I2C Master (FIXED)
//               : Converts sequence-level transactions to pin-level bus activity.
//               : Uses clock-based timing and proper open-drain release.
//               : FIX: Added req_analysis_port for scoreboard expected data.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_MASTER_DRIVER_SV
`define I2C_MASTER_DRIVER_SV

class i2c_driver extends uvm_driver #(i2c_seq_item);

  `uvm_component_utils(i2c_driver)

  virtual i2c_if vif;

  uvm_analysis_port #(i2c_seq_item) req_analysis_port;

  function new(string name = "i2c_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    req_analysis_port = new("req_analysis_port", this);
    if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", vif)) begin
      `uvm_fatal(get_type_name(), "Virtual interface not found in config_db")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    i2c_seq_item req_item;

    wait(vif.rst_n === 1'b1);
    `uvm_info(get_type_name(), "Reset released. Starting I2C driver.", UVM_LOW)

    forever begin
      seq_item_port.get_next_item(req_item);
      `uvm_info(get_type_name(), $sformatf("Got item: %s", req_item.convert2string()), UVM_MEDIUM)

      // FIX: DO NOT write to analysis port here. Write AFTER transaction completes.

      // Execute transaction
      if (req_item.start_cond && !req_item.rep_start) begin
        send_start();
      end else if (req_item.rep_start) begin
        send_rep_start();
      end

      if (req_item.start_cond || req_item.rep_start) begin
        send_byte({req_item.addr, logic'(req_item.dir)});
        wait_for_ack();
      end

      if (req_item.dir == DIR_WRITE) begin
        foreach (req_item.data[i]) begin
          send_byte(req_item.data[i]);
          wait_for_ack();
        end
      end else begin
        for (int i = 0; i < req_item.data.size(); i++) begin
          // FIX: capture received byte directly into the seq_item
          receive_byte(req_item.data[i]);
          if (i < req_item.data.size() - 1) begin
            send_ack();
          end else begin
            send_nack();
          end
        end
      end

      if (req_item.stop_cond) begin
        send_stop();
      end

      // FIX: Broadcast expected transaction AFTER completion with updated data
      req_analysis_port.write(req_item);

      seq_item_port.item_done();
    end
  endtask

  //-------------------------------------------------------------------------
  // Task: Send START condition
  //-------------------------------------------------------------------------
  virtual task send_start();
    `uvm_info(get_type_name(), "Sending START condition", UVM_HIGH)
    vif.sda_drv <= 1'b1;
    vif.scl_drv <= 1'b1;
    @(posedge vif.clk); @(posedge vif.clk);
    vif.sda_drv <= 1'b0;  // SDA falls while SCL HIGH = START
    @(posedge vif.clk); @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send Repeated START (Sr)
  //-------------------------------------------------------------------------
  virtual task send_rep_start();
    `uvm_info(get_type_name(), "Sending Repeated START (Sr)", UVM_HIGH)
    vif.sda_drv <= 1'b1;
    @(posedge vif.clk); @(posedge vif.clk);
    vif.scl_drv <= 1'b1;
    @(posedge vif.clk); @(posedge vif.clk);
    vif.sda_drv <= 1'b0;  // SDA falls while SCL HIGH = Repeated START
    @(posedge vif.clk); @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send STOP condition
  //-------------------------------------------------------------------------
  virtual task send_stop();
    `uvm_info(get_type_name(), "Sending STOP condition", UVM_HIGH)
    vif.sda_drv <= 1'b0;
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk); @(posedge vif.clk);
    vif.scl_drv <= 1'b1;  // SCL rises first
    @(posedge vif.clk); @(posedge vif.clk);
    vif.sda_drv <= 1'b1;  // SDA rises while SCL HIGH = STOP
    @(posedge vif.clk); @(posedge vif.clk);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send a single byte (MSB first)
  //-------------------------------------------------------------------------
  virtual task send_byte(input logic [7:0] byte_data);
    `uvm_info(get_type_name(), $sformatf("Sending byte: 0x%02x", byte_data), UVM_HIGH)
    for (int i = 7; i >= 0; i--) begin
      vif.scl_drv <= 1'b0;
      vif.sda_drv <= byte_data[i];
      @(posedge vif.clk);
      @(posedge vif.clk);
      vif.scl_drv <= 1'b1;  // SCL HIGH — slave samples SDA
      @(posedge vif.clk);
      @(posedge vif.clk);
      vif.scl_drv <= 1'b0;
      @(posedge vif.clk);
    end
  endtask

  //-------------------------------------------------------------------------
  // Task: Receive a single byte (MSB first)
  // FIX: Takes output ref to write received data back into the seq_item
  //-------------------------------------------------------------------------
  virtual task receive_byte(output logic [7:0] received_byte);
    `uvm_info(get_type_name(), "Receiving byte from slave", UVM_HIGH)
    for (int i = 7; i >= 0; i--) begin
      vif.scl_drv <= 1'b0;
      vif.sda_drv <= 1'b1;          // Release SDA (let slave drive)
      @(posedge vif.clk);
      @(posedge vif.clk);
      vif.scl_drv <= 1'b1;          // SCL HIGH — sample SDA
      @(posedge vif.clk);
      received_byte[i] = vif.sda;   // Sample on SCL HIGH
      @(posedge vif.clk);
      vif.scl_drv <= 1'b0;
      @(posedge vif.clk);
    end
    `uvm_info(get_type_name(), $sformatf("Received byte: 0x%02x", received_byte), UVM_MEDIUM)
  endtask

  //-------------------------------------------------------------------------
  // Task: Wait for ACK/NACK (9th clock cycle)
  //-------------------------------------------------------------------------
  virtual task wait_for_ack();
    bit sampled_ack;
    `uvm_info(get_type_name(), "Waiting for ACK/NACK", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    vif.sda_drv <= 1'b1;          // Release SDA (let slave drive ACK)
    @(posedge vif.clk);
    @(posedge vif.clk);
    vif.scl_drv <= 1'b1;          // SCL HIGH — sample ACK
    @(posedge vif.clk);
    sampled_ack = vif.sda;
    @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);

    if (sampled_ack === 1'b0) begin
      `uvm_info(get_type_name(), "ACK received", UVM_MEDIUM)
    end else begin
      `uvm_warning(get_type_name(), "NACK received!")
    end
  endtask

  //-------------------------------------------------------------------------
  // Task: Send ACK (after receiving a byte from slave)
  //-------------------------------------------------------------------------
  virtual task send_ack();
    `uvm_info(get_type_name(), "Sending ACK", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    vif.sda_drv <= 1'b0;          // Drive LOW for ACK
    @(posedge vif.clk);
    @(posedge vif.clk);
    vif.scl_drv <= 1'b1;
    @(posedge vif.clk);
    @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
    vif.sda_drv <= 1'b1;          // Release
    @(posedge vif.clk);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send NACK (after receiving last byte from slave)
  //-------------------------------------------------------------------------
  virtual task send_nack();
    `uvm_info(get_type_name(), "Sending NACK", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    vif.sda_drv <= 1'b1;          // Keep HIGH for NACK (release)
    @(posedge vif.clk);
    @(posedge vif.clk);
    vif.scl_drv <= 1'b1;
    @(posedge vif.clk);
    @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
  endtask

endclass : i2c_driver

`endif
