//=============================================================================
// File          : i2c_reg_if.sv
// Description   : SystemVerilog Interface for the I2C master's CPU register
//               : interface (APB-like, 3-bit addr, 8-bit data).
//               : Provides clocking blocks for the RAL driver and monitor.
// Language      : SystemVerilog (IEEE 1800-2012)
//
// TEACHING NOTE:
//   WHY a separate interface for the CPU register bus?
//   The existing i2c_if.sv models the physical I2C bus (SCL/SDA), which is
//   completely separate from the CPU register interface that the host uses
//   to program the master controller. RAL drives the CPU interface, NOT the
//   I2C bus — so we need a dedicated interface here.
//
//   Clocking blocks enforce synchronous discipline:
//   - driver_cb: inputs sampled 1step before posedge (setup check), outputs
//                driven #1 after posedge (registered drive, avoids glitch).
//   - monitor_cb: all signals sampled 1step before posedge (read what DUT sees).
//=============================================================================

`ifndef I2C_REG_IF_SV
`define I2C_REG_IF_SV

interface i2c_reg_if (input logic clk, input logic rst_n);

    // ------------------------------------------------------------------
    // CPU Register Bus Signals (match i2c_master_controller port names)
    // ------------------------------------------------------------------
    logic [2:0] cpu_addr;    // Register address — matches i2c_reg_e enum
    logic       cpu_wr;      // Write enable: 1 = write, 0 = read
    logic [7:0] cpu_wdata;   // Write data
    logic [7:0] cpu_rdata;   // Read data (driven combinationally by DUT)

    // ------------------------------------------------------------------
    // Driver Clocking Block
    // ------------------------------------------------------------------
    // "default input #1step" means the interface samples inputs (from DUT,
    // i.e. cpu_rdata) 1 simulation step before the clock edge — this avoids
    // setup-time races where the DUT and TB update on the same clock edge.
    //
    // "output #1" means the driver's output values appear #1 after posedge,
    // which is sufficient for most synchronous RTL that samples on posedge.
    // ------------------------------------------------------------------
    clocking driver_cb @(posedge clk);
        default input #1step output #1;
        output cpu_addr, cpu_wr, cpu_wdata;
        input  cpu_rdata;
    endclocking

    // ------------------------------------------------------------------
    // Monitor Clocking Block
    // ------------------------------------------------------------------
    // Monitor is purely passive (observe-only). All signals are inputs.
    // Sampling with #1step gives us what the DUT sees at that clock edge.
    // ------------------------------------------------------------------
    clocking monitor_cb @(posedge clk);
        default input #1step;
        input cpu_addr, cpu_wr, cpu_wdata, cpu_rdata;
    endclocking

    // ------------------------------------------------------------------
    // Reset Initialization
    // ------------------------------------------------------------------
    // Drive all outputs to known-safe state at time-0 so DUT doesn't
    // see spurious writes during power-on.
    // ------------------------------------------------------------------
    initial begin
        cpu_addr  = 3'b000;
        cpu_wr    = 1'b0;
        cpu_wdata = 8'h00;
    end

    // ------------------------------------------------------------------
    // Modports — restrict what each UVM component can see/drive
    // ------------------------------------------------------------------
    modport drv_mp (clocking driver_cb,  input clk, rst_n);
    modport mon_mp (clocking monitor_cb, input clk, rst_n);

endinterface : i2c_reg_if

`endif
