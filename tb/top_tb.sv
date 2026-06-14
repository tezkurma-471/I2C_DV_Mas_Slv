//=============================================================================
// File          : top_tb.sv
// Description   : Top-level testbench for I2C Protocol Verification
//               : V2: Added force_data_nack connection.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef TOP_TB_SV
`define TOP_TB_SV

`include "uvm_macros.svh"
import uvm_pkg::*;
import i2c_pkg::*;
import i2c_tb_pkg::*;

module top_tb;
  // NOTE: The DUT is the I2C SLAVE. The master RTL (i2c_master_controller.sv)
  // is NOT instantiated here — the UVM driver BFM (i2c_master_driver.sv)
  // directly generates protocol-compliant bus activity. This is standard
  // block-level verification methodology.

  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    #200 rst_n = 1'b1;
  end

  i2c_if i2c_bus_if (.clk(clk), .rst_n(rst_n));
  i2c_slave_if i2c_slv_if (.clk(clk), .rst_n(rst_n));

  i2c_slave #(.SLAVE_ADDR(7'h50)) slave_dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .scl           (i2c_bus_if.scl),
    .sda           (i2c_bus_if.sda),
    .stretch_en    (i2c_slv_if.stretch_en),
    .stretch_cycles(i2c_slv_if.stretch_cycles),
    .force_data_nack(i2c_slv_if.force_data_nack),
    .reg_bank      (i2c_slv_if.reg_bank),
    .reg_updated   (i2c_slv_if.reg_updated),
    .addr_match    (i2c_slv_if.addr_match),
    .active        (i2c_slv_if.active),
    .rx_data_valid (i2c_slv_if.rx_data_valid),
    .rx_data       (i2c_slv_if.rx_data),
    .tx_ack        (i2c_slv_if.tx_ack),
    .tx_nack       (i2c_slv_if.tx_nack),
    .bus_error     (i2c_slv_if.bus_error)
  );

  i2c_protocol_assertions u_sva (
    .clk   (clk),
    .rst_n (rst_n),
    .scl   (i2c_bus_if.scl),
    .sda   (i2c_bus_if.sda)
  );

  initial begin
    uvm_config_db #(virtual i2c_if)::set(null, "*", "i2c_vif", i2c_bus_if);
    uvm_config_db #(virtual i2c_slave_if)::set(null, "*", "i2c_slave_vif", i2c_slv_if);
    run_test();  // FIX: no default — +UVM_TESTNAME controls test selection
  end

  // Waveform dump only on request (+DUMP). Unconditional $dumpvars spams
  // "no read access" PLI noise on simulators that restrict signal access by
  // default (e.g. Riviera EDU on EDA Playground) and slows long tests.
  initial begin
    if ($test$plusargs("DUMP")) begin
      $dumpfile("waves.vcd");
      $dumpvars(0, top_tb);
    end
  end

  initial begin
    #50_000_000;  // FIX: 50ms timeout (was 10ms, too short for stress tests)
    $error("TIMEOUT: Simulation exceeded 50ms");
    $finish;
  end

endmodule : top_tb

`endif
