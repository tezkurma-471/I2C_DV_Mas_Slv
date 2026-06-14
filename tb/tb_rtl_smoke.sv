//=============================================================================
// File          : tb_rtl_smoke.sv
// Description   : Pure-SystemVerilog (no UVM) integration smoke test.
//               : Connects the RTL master to the RTL slave over real
//               : open-drain wires and verifies, end to end:
//               :   T1  multi-byte write with SCL held low between bytes
//               :       (STATE_BYTE_HOLD — no implicit STOP mid-transaction)
//               :   T2  multi-byte read-back, data integrity vs T1
//               :   T3  address NACK -> master auto-STOP, slave stays idle
//               :   T4  clock stretching mid-transfer (timer freeze path)
//               :   T5  repeated START write->read turnaround
//               : Runs under Icarus Verilog:  make smoke   (sim/Makefile)
//=============================================================================
`timescale 1ns/1ps

module tb_rtl_smoke;

  import i2c_pkg::*;

  //--------------------------------------------------------------------------
  // Clock / Reset
  //--------------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #10 clk = ~clk;   // 50 MHz

  //--------------------------------------------------------------------------
  // Open-drain bus with pull-ups
  //--------------------------------------------------------------------------
  wire scl, sda;
  pullup (scl);
  pullup (sda);

  //--------------------------------------------------------------------------
  // Master (CPU-driven)
  //--------------------------------------------------------------------------
  logic [2:0] cpu_addr;
  logic       cpu_wr;
  logic [7:0] cpu_wdata;
  logic [7:0] cpu_rdata;
  wire        cpu_irq, busy, done, ack, nack, timeout, bus_error, arb_lost;

  i2c_master u_master (
    .clk, .rst_n,
    .cpu_addr, .cpu_wr, .cpu_wdata, .cpu_rdata, .cpu_irq,
    .scl, .sda,
    .busy, .done, .ack, .nack, .timeout, .bus_error, .arb_lost
  );

  //--------------------------------------------------------------------------
  // Slave (DUT of the UVM bench)
  //--------------------------------------------------------------------------
  logic        stretch_en      = 1'b0;
  logic [15:0] stretch_cycles  = 16'd0;
  logic        force_data_nack = 1'b0;
  logic [7:0]  reg_bank    [0:7];
  logic        reg_updated [0:7];
  wire         addr_match, active, rx_data_valid, slv_tx_ack, slv_tx_nack, slv_bus_error;
  logic [7:0]  rx_data;

  i2c_slave #(.SLAVE_ADDR(7'h50)) u_slave (
    .clk, .rst_n,
    .scl, .sda,
    .stretch_en, .stretch_cycles, .force_data_nack,
    .reg_bank, .reg_updated, .addr_match, .active,
    .rx_data_valid, .rx_data,
    .tx_ack(slv_tx_ack), .tx_nack(slv_tx_nack), .bus_error(slv_bus_error)
  );

  //--------------------------------------------------------------------------
  // Bookkeeping
  //--------------------------------------------------------------------------
  int errors = 0;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("[%0t] SMOKE-FAIL: %s", $time, msg);
    end else begin
      $display("[%0t] SMOKE-PASS: %s", $time, msg);
    end
  endtask

  // Watch for the implicit-STOP regression: during a multi-byte write the
  // slave must stay 'active' from address ACK until the real STOP.
  logic track_active = 1'b0;
  always @(negedge active) begin
    if (track_active) begin
      errors++;
      $display("[%0t] SMOKE-FAIL: slave dropped 'active' mid-transaction (implicit STOP?)", $time);
    end
  end

  //--------------------------------------------------------------------------
  // CPU bus helpers
  //--------------------------------------------------------------------------
  task automatic cpu_write(input logic [2:0] a, input logic [7:0] d);
    @(posedge clk);
    cpu_addr  <= a;
    cpu_wdata <= d;
    cpu_wr    <= 1'b1;
    @(posedge clk);
    cpu_wr    <= 1'b0;
  endtask

  task automatic cpu_read(input logic [2:0] a, output logic [7:0] d);
    @(posedge clk);
    cpu_addr <= a;
    @(posedge clk);
    d = cpu_rdata;
  endtask

  // After a CMD write the FSM needs a few cycles to leave IDLE/BYTE_HOLD and
  // for reg_status to show BUSY. Polling before that sees the STALE status of
  // the previous byte and returns early — so every wait helper first lets the
  // command land.
  task automatic cmd_settle();
    repeat (8) @(posedge clk);
  endtask

  // Wait until the master parks in BYTE_HOLD (status = STS_ACK / STS_NACK)
  task automatic wait_byte_hold(output bit got_ack);
    logic [7:0] s;
    int guard = 0;
    cmd_settle();
    forever begin
      cpu_read(REG_STATUS, s);
      if (s[2:0] == STS_ACK)  begin got_ack = 1'b1; return; end
      if (s[2:0] == STS_NACK) begin got_ack = 1'b0; return; end
      guard++;
      if (guard > 100_000) begin
        errors++;
        $display("[%0t] SMOKE-FAIL: timeout waiting for BYTE_HOLD", $time);
        return;
      end
      repeat (10) @(posedge clk);
    end
  endtask

  // Wait for the master to finish a STOP (or NACK-abort) and go idle
  task automatic wait_idle();
    int guard = 0;
    cmd_settle();
    while (busy) begin
      @(posedge clk);
      guard++;
      if (guard > 1_000_000) begin
        errors++;
        $display("[%0t] SMOKE-FAIL: timeout waiting for IDLE", $time);
        return;
      end
    end
  endtask

  //--------------------------------------------------------------------------
  // I2C transaction helpers (CPU programming model)
  //--------------------------------------------------------------------------
  task automatic i2c_start(input logic [6:0] a, input bit read_op, output bit got_ack);
    cpu_write(REG_DATA, {a, read_op});
    cpu_write(REG_CMD,  {4'd0, CMD_START});
    wait_byte_hold(got_ack);
  endtask

  task automatic i2c_rep_start(input logic [6:0] a, input bit read_op, output bit got_ack);
    cpu_write(REG_DATA, {a, read_op});
    cpu_write(REG_CMD,  {4'd0, CMD_REP_START});
    wait_byte_hold(got_ack);
  endtask

  task automatic i2c_write_byte(input logic [7:0] d, output bit got_ack);
    cpu_write(REG_DATA, d);
    cpu_write(REG_CMD,  {4'd0, CMD_WRITE});
    wait_byte_hold(got_ack);
  endtask

  task automatic i2c_read_byte(input bit last, output logic [7:0] d);
    bit ok;
    cpu_write(REG_CMD, last ? {4'd0, CMD_READ_NACK} : {4'd0, CMD_READ_ACK});
    wait_byte_hold(ok);
    cpu_read(REG_DATA, d);
  endtask

  task automatic i2c_stop();
    cpu_write(REG_CMD, {4'd0, CMD_STOP});
    wait_idle();
  endtask

  //--------------------------------------------------------------------------
  // Test payload
  //--------------------------------------------------------------------------
  logic [7:0] pat [0:3];
  logic [7:0] rd;
  bit         a;

  initial begin
    pat[0] = 8'hA5; pat[1] = 8'h3C; pat[2] = 8'h00; pat[3] = 8'hFF;
    cpu_addr = '0; cpu_wr = 1'b0; cpu_wdata = '0;

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    //------------------------------------------------------------------
    // T1: 4-byte burst write — bus must stay owned between bytes
    //------------------------------------------------------------------
    $display("\n--- T1: multi-byte write ---");
    i2c_start(7'h50, 1'b0, a);
    check(a, "T1 address 0x50/W ACKed");
    track_active = 1'b1;
    for (int i = 0; i < 4; i++) begin
      i2c_write_byte(pat[i], a);
      check(a, $sformatf("T1 data byte %0d ACKed", i));
      check(scl === 1'b0, $sformatf("T1 SCL held LOW between bytes (after byte %0d)", i));
    end
    track_active = 1'b0;
    i2c_stop();
    check(timeout === 1'b0, "T1 no stretch timeout");
    for (int i = 0; i < 4; i++) begin
      check(reg_bank[i] === pat[i],
            $sformatf("T1 slave reg[%0d] = 0x%02x (expected 0x%02x)", i, reg_bank[i], pat[i]));
    end

    //------------------------------------------------------------------
    // T2: 4-byte read-back
    //------------------------------------------------------------------
    $display("\n--- T2: multi-byte read-back ---");
    repeat (100) @(posedge clk);
    i2c_start(7'h50, 1'b1, a);
    check(a, "T2 address 0x50/R ACKed");
    for (int i = 0; i < 4; i++) begin
      i2c_read_byte(i == 3, rd);
      check(rd === pat[i],
            $sformatf("T2 read byte %0d = 0x%02x (expected 0x%02x)", i, rd, pat[i]));
    end
    i2c_stop();

    //------------------------------------------------------------------
    // T3: address NACK -> master aborts with STOP on its own
    //------------------------------------------------------------------
    $display("\n--- T3: address NACK ---");
    repeat (100) @(posedge clk);
    cpu_write(REG_DATA, {7'h23, 1'b0});
    cpu_write(REG_CMD,  {4'd0, CMD_START});
    wait_idle();   // NACK path: ACK_WAIT -> STOP_1 -> STOP_2 -> IDLE
    check(nack === 1'b1,  "T3 NACK latched for unmatched address");
    check(active === 1'b0, "T3 slave never activated");

    //------------------------------------------------------------------
    // T4: clock stretching mid-transfer
    //------------------------------------------------------------------
    $display("\n--- T4: clock stretch ---");
    repeat (100) @(posedge clk);
    stretch_cycles = 16'd400;
    i2c_start(7'h50, 1'b0, a);
    check(a, "T4 address ACKed");
    // Trigger a stretch pulse while the first data byte is in flight
    fork
      begin
        i2c_write_byte(8'h5A, a);
        check(a, "T4 data byte ACKed despite stretch");
      end
      begin
        repeat (200) @(posedge clk);
        stretch_en = 1'b1;
        repeat (20) @(posedge clk);
        stretch_en = 1'b0;
      end
    join
    i2c_stop();
    check(timeout === 1'b0,   "T4 stretch under MAX_CLK_STRETCH -> no timeout");
    check(reg_bank[0] === 8'h5A, $sformatf("T4 reg[0] = 0x%02x (expected 0x5a)", reg_bank[0]));

    //------------------------------------------------------------------
    // T5: repeated START (write 2, Sr, read 2)
    //------------------------------------------------------------------
    $display("\n--- T5: repeated START ---");
    repeat (100) @(posedge clk);
    i2c_start(7'h50, 1'b0, a);
    check(a, "T5 address/W ACKed");
    i2c_write_byte(8'h11, a);
    i2c_write_byte(8'h22, a);
    i2c_rep_start(7'h50, 1'b1, a);
    check(a, "T5 repeated-START address/R ACKed");
    i2c_read_byte(1'b0, rd);
    check(rd === 8'h11, $sformatf("T5 Sr read byte 0 = 0x%02x (expected 0x11)", rd));
    i2c_read_byte(1'b1, rd);
    check(rd === 8'h22, $sformatf("T5 Sr read byte 1 = 0x%02x (expected 0x22)", rd));
    i2c_stop();

    //------------------------------------------------------------------
    // T6: stretch armed BEFORE the transaction -> fires at the ADDRESS ACK.
    // This is the exact scenario the UVM clock_stretch_test exercises (the
    // slave's stretch_pending latches on the early stretch_en edge and fires
    // when active_int sets at SLV_ACK). The slave must HOLD the ACK on SDA
    // through the stretch — the regression bug was SLV_STRETCH releasing it.
    //------------------------------------------------------------------
    $display("\n--- T6: clock stretch at address ACK ---");
    repeat (100) @(posedge clk);
    stretch_cycles = 16'd300;
    stretch_en = 1'b1;          // arm BEFORE start (latched as stretch_pending)
    repeat (4) @(posedge clk);
    stretch_en = 1'b0;          // single pulse — edge-armed, no re-trigger
    i2c_start(7'h50, 1'b0, a);  // stretch fires at the address ACK
    check(a, "T6 address ACKed through stretch (ACK held on SDA)");
    i2c_write_byte(8'h6B, a);
    check(a, "T6 data byte ACKed");
    i2c_stop();
    check(timeout === 1'b0, "T6 no stretch timeout");
    check(reg_bank[0] === 8'h6B, $sformatf("T6 reg[0] = 0x%02x (expected 0x6b)", reg_bank[0]));

    //------------------------------------------------------------------
    // Summary
    //------------------------------------------------------------------
    repeat (100) @(posedge clk);
    if (errors == 0) $display("\n=== RTL SMOKE: ALL TESTS PASSED ===");
    else             $display("\n=== RTL SMOKE: %0d FAILURES ===", errors);
    $finish;
  end

  // Global watchdog
  initial begin
    #50_000_000; // 50 ms
    $display("SMOKE-FAIL: global watchdog expired");
    $finish;
  end

`ifdef SMOKE_DEBUG
  initial $display("DEBUG tracer enabled");
  always @(u_master.master_core.state)
    $display("[%0t] MST state=%0d timer=%0d bit=%0d scl=%b sda=%b",
             $time, u_master.master_core.state, u_master.master_core.timer,
             u_master.master_core.bit_cnt, scl, sda);
  always @(u_slave.slave_core.state)
    $display("[%0t] SLV state=%0d bit=%0d scl=%b sda=%b am=%b",
             $time, u_slave.slave_core.state, u_slave.slave_core.bit_cnt,
             scl, sda, u_slave.slave_core.addr_matched);
`endif

endmodule
