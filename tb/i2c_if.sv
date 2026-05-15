//=============================================================================
// File          : i2c_if.sv
// Description   : SystemVerilog Interface for I2C Bus
//               : Models open-drain wired-AND behavior with pull-ups.
//               : Uses wire type for correct multi-driver resolution.
// Language      : SystemVerilog (IEEE 1800-2012)
//=============================================================================

`ifndef I2C_IF_SV
`define I2C_IF_SV

interface i2c_if (
  input logic clk,
  input logic rst_n
);

  //-------------------------------------------------------------------------
  // Bus Signals — wire for proper multi-driver (wired-AND) resolution
  // Pull-up resistors modeled via pullup primitives
  //-------------------------------------------------------------------------
  wire sda;
  wire scl;

  // Model pull-up resistors (open-drain idle = HIGH)
  assign (weak1, highz0) sda = 1'b1;
  assign (weak1, highz0) scl = 1'b1;

  //-------------------------------------------------------------------------
  // Driver proxy signals (active-low drive)
  // Driver sets proxy; continuous assignment to wire with drive strength
  //-------------------------------------------------------------------------
  logic sda_drv;
  logic scl_drv;

  // Strong0 pull-down, weak1 release (simulates open-drain)
  assign (strong0, weak1) sda = (sda_drv == 1'b0) ? 1'b0 : 1'bz;
  assign (strong0, weak1) scl = (scl_drv == 1'b0) ? 1'b0 : 1'bz;

  //-------------------------------------------------------------------------
  // T13: Competing-master driver hook
  // A second open-drain pull-down used by the slave driver in
  // "compete_as_master" mode to provoke arbitration loss on the master
  // under test. Defaults to 1 (released) so it has no effect on normal
  // tests. Only the arbitration_lost_test wiggles sda_drv_x.
  //-------------------------------------------------------------------------
  logic sda_drv_x;

  assign (strong0, weak1) sda = (sda_drv_x == 1'b0) ? 1'b0 : 1'bz;

  // Optional monitoring hook for arb_lost (not driven inside the interface;
  // tests/monitors may sample if the master RTL is wired in).
  logic arb_lost;

  // Initialize driver proxies to release (1 = don't pull down)
  initial begin
    sda_drv   = 1'b1;
    scl_drv   = 1'b1;
    sda_drv_x = 1'b1;  // T13: competing master released by default
    arb_lost  = 1'b0;
  end

  //-------------------------------------------------------------------------
  // Clocking Block — Driver
  // Synchronized to posedge clk. Output skew #1 for setup margin.
  //-------------------------------------------------------------------------
  clocking driver_cb @(posedge clk);
    default input #1step output #1;
    output sda_drv;
    output scl_drv;
    input  sda;
    input  scl;
  endclocking

  //-------------------------------------------------------------------------
  // Clocking Block — Monitor
  // Passive: input only. #1step samples just before clock edge (settled).
  //-------------------------------------------------------------------------
  clocking monitor_cb @(posedge clk);
    default input #1step;
    input sda;
    input scl;
  endclocking

  //-------------------------------------------------------------------------
  // Task: Wait for bus free (both SDA and SCL HIGH)
  //-------------------------------------------------------------------------
  task automatic wait_bus_free();
    @(posedge clk);
    wait (sda === 1'b1 && scl === 1'b1);
  endtask

  //-------------------------------------------------------------------------
  // Task: Wait N clock cycles
  //-------------------------------------------------------------------------
  task automatic wait_n_clocks(input int n);
    repeat(n) @(posedge clk);
  endtask

  //-------------------------------------------------------------------------
  // Modports
  //-------------------------------------------------------------------------
  modport master_mp  (clocking driver_cb,  input clk, rst_n);
  modport monitor_mp (clocking monitor_cb, input clk, rst_n);
  modport dut_mp     (inout sda, inout scl, input clk, rst_n);

endinterface : i2c_if

`endif
