//=============================================================================
// File          : i2c_slave.sv
// Description   : Top-level I2C Slave wrapper with parameterizable address.
// Language      : SystemVerilog (IEEE 1800-2012)
//=============================================================================

`ifndef I2C_SLAVE_SV
`define I2C_SLAVE_SV

module i2c_slave
#(
  parameter logic [6:0] SLAVE_ADDR = 7'h50
)
(
  // System
  input  logic        clk,
  input  logic        rst_n,

  // I2C Physical Interface (Open-Drain)
  inout  wire         scl,
  inout  wire         sda,

  // Clock stretching control
  input  logic        stretch_en,
  input  logic [15:0] stretch_cycles,
  input  logic        force_data_nack,

  // Status outputs for testbench monitoring
  output logic [7:0]  reg_bank    [0:7],
  output logic        reg_updated [0:7],
  output logic        addr_match,
  output logic        active,
  output logic        rx_data_valid,
  output logic [7:0]  rx_data,
  output logic        tx_ack,
  output logic        tx_nack,
  output logic        bus_error
);

  i2c_slave_controller
  #(
    .SLAVE_ADDR(SLAVE_ADDR)
  )
  slave_core
  (
    .clk,
    .rst_n,
    .scl,
    .sda,
    .reg_bank,
    .reg_updated,
    .addr_match,
    .active,
    .stretch_en,
    .stretch_cycles,
    .force_data_nack,
    .rx_data_valid,
    .rx_data,
    .tx_ack,
    .tx_nack,
    .bus_error
  );

endmodule

`endif