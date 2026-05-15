//=============================================================================
// File          : i2c_slave_if.sv
// Description   : SystemVerilog Interface for I2C Slave Control & Status
//               : Carries stretch control inputs and status outputs from
//               : the slave DUT, enabling the UVM slave agent to observe
//               : and reactively control the slave.
// Language      : SystemVerilog (IEEE 1800-2012)
//=============================================================================

`ifndef I2C_SLAVE_IF_SV
`define I2C_SLAVE_IF_SV

interface i2c_slave_if (
  input logic clk,
  input logic rst_n
);

  logic        stretch_en;
  logic [15:0] stretch_cycles;
  logic        force_data_nack;

  logic [7:0]  reg_bank     [0:7];
  logic        reg_updated  [0:7];
  logic        addr_match;
  logic        active;
  logic        rx_data_valid;
  logic [7:0]  rx_data;
  logic        tx_ack;
  logic        tx_nack;
  logic        bus_error;

  initial begin
    stretch_en     = 1'b0;
    stretch_cycles = 16'd0;
    force_data_nack = 1'b0;
  end

  clocking slave_cb @(posedge clk);
    default input #1step output #1;
    output stretch_en;
    output stretch_cycles;
    output force_data_nack;
    input  reg_bank;
    input  reg_updated;
    input  addr_match;
    input  active;
    input  rx_data_valid;
    input  rx_data;
    input  tx_ack;
    input  tx_nack;
    input  bus_error;
  endclocking

  clocking monitor_cb @(posedge clk);
    default input #1step;
    input reg_bank;
    input reg_updated;
    input addr_match;
    input active;
    input rx_data_valid;
    input rx_data;
    input tx_ack;
    input tx_nack;
    input bus_error;
  endclocking

  modport slave_mp   (clocking slave_cb,   input clk, rst_n);
  modport monitor_mp (clocking monitor_cb,  input clk, rst_n);

endinterface : i2c_slave_if

`endif
