//=============================================================================
// File          : i2c_master_driver.sv (FIXED v2)
// Description   : UVM Driver (master BFM) for the I2C bus.
//               : Converts sequence-level transactions to pin-level activity.
//               : V2 fixes (post-audit):
//               :  - Honors the i2c_pkg timing constants (T_HD_DAT, T_SU_DAT,
//               :    T_SU_STA/T_HD_STA/T_SU_STO, T_BUF) so the protocol SVAs
//               :    are meaningful instead of structurally violated.
//               :  - Clock-stretch aware: after releasing SCL it WAITS for the
//               :    wire to actually go high (scl_release_wait), with a
//               :    MAX_CLK_STRETCH timeout reported as a UVM error.
//               :  - Records addr_ack / byte_ack into the seq_item (the old
//               :    driver sampled ACK into a local and dropped it).
//               :  - Aborts on NACK: address NACK -> STOP, no data driven;
//               :    data NACK -> remaining bytes not driven, item trimmed to
//               :    what was actually put on the wire.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_MASTER_DRIVER_SV
`define I2C_MASTER_DRIVER_SV

class i2c_driver extends uvm_driver #(i2c_seq_item);

  `uvm_component_utils(i2c_driver)

  virtual i2c_if vif;

  uvm_analysis_port #(i2c_seq_item) req_analysis_port;

  // BFM timing in system-clock cycles. Margins of +3 cover the 2-stage
  // sampling pipeline inside the SVA module so the hold/setup assertions
  // (A8/A9) see at least the spec window.
  localparam int BIT_HOLD   = T_HD_DAT + 3;  // SDA stable after SCL falls
  localparam int BIT_SETUP  = T_SU_DAT + 3;  // SDA stable before SCL rises
  localparam int SCL_HIGH_N = 6;             // SCL high time per bit
  localparam int BUS_FREE_N = T_BUF + 6;     // bus-free time after STOP (A7)

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

      drive_item(req_item);

      // Broadcast expected transaction AFTER completion: read data has been
      // sampled back and ACK results recorded by now.
      req_analysis_port.write(req_item);

      seq_item_port.item_done();
    end
  endtask

  //-------------------------------------------------------------------------
  // Task: Drive one complete transaction (or chain segment)
  //-------------------------------------------------------------------------
  virtual task drive_item(i2c_seq_item it);
    bit         got_ack;
    logic [7:0] rdata;

    if (it.start_cond && !it.rep_start) begin
      send_start();
    end else if (it.rep_start) begin
      send_rep_start();
    end

    if (it.start_cond || it.rep_start) begin
      send_byte({it.addr, logic'(it.dir)});
      wait_for_ack(got_ack);
      it.addr_ack     = got_ack;
      it.ack_received = got_ack;
      if (!got_ack) begin
        // FIX: a NACK'd address means no slave selected — driving data bytes
        // anyway (old behavior) puts garbage on an un-owned bus.
        `uvm_info(get_type_name(),
                  $sformatf("Address 0x%02x NACKed — aborting with STOP", it.addr), UVM_MEDIUM)
        it.data.delete();
        it.num_data = 0;
        send_stop();
        return;
      end
    end

    if (it.dir == DIR_WRITE) begin
      for (int i = 0; i < it.data.size(); i++) begin
        send_byte(it.data[i]);
        wait_for_ack(got_ack);
        it.byte_ack.push_back(got_ack);
        if (!got_ack) begin
          // FIX: receiver NACKed this byte — the transfer must end here.
          // Trim the item to the bytes that were actually driven so the
          // scoreboard's expected stream matches the wire.
          `uvm_info(get_type_name(),
                    $sformatf("Data byte %0d NACKed — ending transfer", i), UVM_MEDIUM)
          it.data     = it.data[0:i];
          it.num_data = i + 1;
          break;
        end
      end
    end else begin
      for (int i = 0; i < it.data.size(); i++) begin
        receive_byte(rdata);
        it.data[i] = rdata;
        if (i < it.data.size() - 1) send_ack();
        else                        send_nack();
      end
    end

    if (it.stop_cond) begin
      send_stop();
    end
  endtask

  //-------------------------------------------------------------------------
  // Task: Release SCL and wait for the WIRE to go high.
  // This is what makes the BFM clock-stretch aware: a stretching slave keeps
  // the wired-AND SCL low and we wait for it (bounded by MAX_CLK_STRETCH).
  //-------------------------------------------------------------------------
  virtual task scl_release_wait();
    int timeout_count = 0;
    vif.scl_drv <= 1'b1;
    @(posedge vif.clk);
    while (vif.scl !== 1'b1) begin
      @(posedge vif.clk);
      timeout_count++;
      if (timeout_count >= MAX_CLK_STRETCH) begin
        `uvm_error(get_type_name(),
                   $sformatf("Clock-stretch timeout: SCL held low > %0d cycles", MAX_CLK_STRETCH))
        return;
      end
    end
  endtask

  //-------------------------------------------------------------------------
  // Task: Send START condition (bus idle: SDA/SCL both high)
  //-------------------------------------------------------------------------
  virtual task send_start();
    `uvm_info(get_type_name(), "Sending START condition", UVM_HIGH)
    vif.sda_drv <= 1'b1;
    vif.scl_drv <= 1'b1;
    repeat (T_SU_STA) @(posedge vif.clk);
    vif.sda_drv <= 1'b0;  // SDA falls while SCL HIGH = START
    repeat (T_HD_STA) @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send Repeated START (entered with SCL low after an ACK phase)
  //-------------------------------------------------------------------------
  virtual task send_rep_start();
    `uvm_info(get_type_name(), "Sending Repeated START (Sr)", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    repeat (BIT_HOLD) @(posedge vif.clk);
    vif.sda_drv <= 1'b1;             // release SDA while SCL low
    repeat (BIT_SETUP) @(posedge vif.clk);
    scl_release_wait();              // SCL high (stretch-aware), SDA high
    repeat (T_SU_STA) @(posedge vif.clk);
    vif.sda_drv <= 1'b0;             // SDA falls while SCL HIGH = Sr
    repeat (T_HD_STA) @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send STOP condition (entered with SCL low)
  //-------------------------------------------------------------------------
  virtual task send_stop();
    `uvm_info(get_type_name(), "Sending STOP condition", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    repeat (BIT_HOLD) @(posedge vif.clk);
    vif.sda_drv <= 1'b0;             // SDA low while SCL low (setup)
    repeat (BIT_SETUP) @(posedge vif.clk);
    scl_release_wait();              // SCL high first...
    repeat (T_SU_STO) @(posedge vif.clk);
    vif.sda_drv <= 1'b1;             // ...then SDA rises while SCL HIGH = STOP
    repeat (BUS_FREE_N) @(posedge vif.clk);  // T_BUF bus-free time (A7)
  endtask

  //-------------------------------------------------------------------------
  // Task: Send a single byte (MSB first)
  //-------------------------------------------------------------------------
  virtual task send_byte(input logic [7:0] byte_data);
    `uvm_info(get_type_name(), $sformatf("Sending byte: 0x%02x", byte_data), UVM_HIGH)
    for (int i = 7; i >= 0; i--) begin
      vif.scl_drv <= 1'b0;
      repeat (BIT_HOLD) @(posedge vif.clk);    // T_HD_DAT: hold SDA after SCL fall
      vif.sda_drv <= byte_data[i];
      repeat (BIT_SETUP) @(posedge vif.clk);   // T_SU_DAT: setup before SCL rise
      scl_release_wait();                      // SCL HIGH — slave samples SDA
      repeat (SCL_HIGH_N) @(posedge vif.clk);
    end
  endtask

  //-------------------------------------------------------------------------
  // Task: Receive a single byte (MSB first)
  //-------------------------------------------------------------------------
  virtual task receive_byte(output logic [7:0] received_byte);
    `uvm_info(get_type_name(), "Receiving byte from slave", UVM_HIGH)
    for (int i = 7; i >= 0; i--) begin
      vif.scl_drv <= 1'b0;
      repeat (BIT_HOLD) @(posedge vif.clk);
      vif.sda_drv <= 1'b1;                     // Release SDA (let slave drive)
      repeat (BIT_SETUP) @(posedge vif.clk);
      scl_release_wait();                      // SCL HIGH — sample window
      repeat (2) @(posedge vif.clk);
      received_byte[i] = vif.sda;              // Sample mid-high
      repeat (SCL_HIGH_N - 2) @(posedge vif.clk);
    end
    `uvm_info(get_type_name(), $sformatf("Received byte: 0x%02x", received_byte), UVM_MEDIUM)
  endtask

  //-------------------------------------------------------------------------
  // Task: Wait for ACK/NACK (9th clock) — result returned to caller
  //-------------------------------------------------------------------------
  virtual task wait_for_ack(output bit ack_result);
    `uvm_info(get_type_name(), "Waiting for ACK/NACK", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    repeat (BIT_HOLD) @(posedge vif.clk);
    vif.sda_drv <= 1'b1;                       // Release SDA (slave drives ACK)
    repeat (BIT_SETUP) @(posedge vif.clk);
    scl_release_wait();                        // SCL HIGH — sample ACK
    repeat (2) @(posedge vif.clk);
    ack_result = (vif.sda === 1'b0);
    repeat (SCL_HIGH_N - 2) @(posedge vif.clk);

    if (ack_result) `uvm_info(get_type_name(), "ACK received", UVM_MEDIUM)
    else            `uvm_info(get_type_name(), "NACK received", UVM_MEDIUM)
  endtask

  //-------------------------------------------------------------------------
  // Task: Send ACK (after receiving a byte from slave)
  //-------------------------------------------------------------------------
  virtual task send_ack();
    `uvm_info(get_type_name(), "Sending ACK", UVM_HIGH)
    drive_ack_bit(1'b0);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send NACK (after receiving the last byte from slave)
  //-------------------------------------------------------------------------
  virtual task send_nack();
    `uvm_info(get_type_name(), "Sending NACK", UVM_HIGH)
    drive_ack_bit(1'b1);
  endtask

  virtual task drive_ack_bit(input logic level);
    vif.scl_drv <= 1'b0;
    repeat (BIT_HOLD) @(posedge vif.clk);
    vif.sda_drv <= level;                      // 0 = ACK, 1 = NACK (release)
    repeat (BIT_SETUP) @(posedge vif.clk);
    scl_release_wait();
    repeat (SCL_HIGH_N) @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    repeat (BIT_HOLD) @(posedge vif.clk);
    vif.sda_drv <= 1'b1;                       // Release SDA during SCL low
    @(posedge vif.clk);
  endtask

endclass : i2c_driver

`endif
