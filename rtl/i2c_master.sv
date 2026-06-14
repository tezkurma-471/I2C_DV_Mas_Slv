//=============================================================================
// File          : i2c_master.sv
// Description   : Top-level I2C Master wrapper
//               : Connects the controller to the open-drain IO pads.
// Language      : SystemVerilog (IEEE 1800-2012)
//=============================================================================

`ifndef I2C_MASTER_SV
`define I2C_MASTER_SV

module i2c_master (
  // System
  input  logic        clk,
  input  logic        rst_n,

  // Host CPU Interface (APB-like)
  input  logic [2:0]  cpu_addr,
  input  logic        cpu_wr,
  input  logic [7:0]  cpu_wdata,
  output logic [7:0]  cpu_rdata,
  output logic        cpu_irq,

  // I2C Physical Interface (Open-Drain, Wired-AND)
  inout  wire         scl,
  inout  wire         sda,

  // Control/Status
  output logic        busy,
  output logic        done,
  output logic        ack,
  output logic        nack,
  output logic        timeout,
  output logic        bus_error,
  output logic        arb_lost
);

  // Instantiate the master controller core
  i2c_master_controller master_core (
    .clk      (clk),
    .rst_n    (rst_n),
    .cpu_addr (cpu_addr),
    .cpu_wr   (cpu_wr),
    .cpu_wdata(cpu_wdata),
    .cpu_rdata(cpu_rdata),
    .cpu_irq  (cpu_irq),
    .scl      (scl),
    .sda      (sda),
    .busy     (busy),
    .done     (done),
    .ack      (ack),
    .nack     (nack),
    .timeout  (timeout),
    .bus_error(bus_error),
    .arb_lost (arb_lost)
  );

endmodule

`endif
