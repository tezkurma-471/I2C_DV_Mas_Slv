//=============================================================================
// GENERATED FILE — do not edit. Rebuild with scripts/build_eda_playground.sh
// Source of truth: rtl/ tb/ uvm/ sva/ in the project tree.
//=============================================================================
//=============================================================================
// File          : i2c_pkg.sv
// Description   : Common package for I2C RTL and verification components
// Language      : SystemVerilog (IEEE 1800-2012)
// Protocol Ref  : NXP UM10204 Rev. 7.0 (I2C-bus specification)
//=============================================================================
// This package declares shared parameters, enums, and types used throughout
// the design and testbench. All timing values are expressed in terms of the
// system clock period for maximum portability across target FPGAs.
//=============================================================================
`ifndef I2C_PKG_SV
`define I2C_PKG_SV

package i2c_pkg;

  //-----------------------------------------------------------------------------
  // Section 1 : General Parameters
  //---------------------------------------------------------------------------
  // I2C can operate in Standard (100 kHz), Fast (400 kHz), Fast-Plus (1 MHz),
  // High-speed (3.4 MHz), and Ultra-Fast (5 MHz) modes. The clock divider 
  // logic in the master uses these parameters to set the SCL period.
  //
  // NOTE : All timing constants are based on a 50 MHz system clock.
  //        Adjust the 'CLK_FREQ_MHZ' value for other clock frequencies.
  //-----------------------------------------------------------------------------

  parameter int CLK_FREQ_MHZ     = 50;    // System clock frequency (MHz)

  // Clock Divider Counts for Standard Mode (100 kHz SCL at 50 MHz)
  // Formula: Number of clk ticks = (t_target / t_clk) = (t_target * CLK_FREQ_MHZ)
  parameter int T_SCL_PERIOD     = 500;   // 10 us / 20 ns = 500 clocks
  parameter int T_SCL_HIGH       = 250;   // SCL high time (approx 5 us)
  parameter int T_SCL_LOW        = 250;   // SCL low time  (approx 5 us)

  // Setup and Hold Times (in terms of system clock cycles)
  // These are critical for START/STOP generation and data validity.
  parameter int T_SU_STA         = 10;   // Setup time for START cond.
  parameter int T_HD_STA         = 10;   // Hold time for START cond.
  parameter int T_SU_STO         = 10;   // Setup time for STOP cond.
  parameter int T_HD_DAT         = 5;    // Data hold time
  parameter int T_SU_DAT         = 5;    // Data setup time
  parameter int T_BUF            = 20;   // Bus free time between STOP and START

  // Clock Stretching
  parameter int MAX_CLK_STRETCH  = 1000; // Max master wait for SCL release (in clk)

  // Data Widths
  parameter int DATA_WIDTH       = 8;
  parameter int ADDR_WIDTH       = 7;

  //-----------------------------------------------------------------------------
  // Section 2 : Enumerations
  //-----------------------------------------------------------------------------
  // Command opcodes written by the host CPU to initiate transactions.
  // The master FSM decodes these to perform the corresponding bus action.
  //---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    CMD_NOP       = 4'h0,  // No operation (idle)
    CMD_START     = 4'h1,  // Generate START condition
    CMD_STOP      = 4'h2,  // Generate STOP condition
    CMD_WRITE     = 4'h3,  // Write a data byte (8 bits + wait for ACK/NACK)
    CMD_READ_ACK  = 4'h4,  // Read a byte and send ACK (continue reading)
    CMD_READ_NACK = 4'h5,  // Read a byte and send NACK (last byte)
    CMD_REP_START = 4'h6,  // Generate Repeated START (Sr)
    CMD_ABORT     = 4'h7   // Abort current transaction and release bus
  } i2c_cmd_e;

  // Transaction direction
  typedef enum logic {
    DIR_WRITE = 1'b0,
    DIR_READ  = 1'b1
  } i2c_dir_e;

  // Operational status returned by the master/slave to the CPU.
  typedef enum logic [2:0] {
    STS_IDLE      = 3'b000,  // Ready for new command
    STS_BUSY      = 3'b001,  // Transaction in progress
    STS_ACK       = 3'b010,  // Acknowledge received/sent
    STS_NACK      = 3'b011,  // Negative acknowledge received/sent
    STS_ARB_LOST  = 3'b100,  // Arbitration lost (not used in single-master)
    STS_TIMEOUT   = 3'b101,  // Clock stretching timeout
    STS_DONE      = 3'b110,  // Transaction completed successfully
    STS_ERR       = 3'b111   // Generic error state
  } i2c_status_e;

  // Interrupt sources — values are the BIT POSITIONS in REG_IRQ_EN, and they
  // match the enable concatenation in i2c_master_controller's IRQ logic.
  // (The old enum listed sources that did not exist in the RTL and did not
  // line up with the implemented enable bits.)
  typedef enum logic [2:0] {
    IRQ_DONE      = 3'd0,
    IRQ_ACK       = 3'd1,
    IRQ_NACK      = 3'd2,
    IRQ_TIMEOUT   = 3'd3,
    IRQ_BUS_ERROR = 3'd4,
    IRQ_ARB_LOST  = 3'd5
  } i2c_irq_e;

  //-----------------------------------------------------------------------------
  // Section 3 : Typedefs
  //-----------------------------------------------------------------------------
  // Address byte: [7:1] = 7-bit slave address, [0] = R/W bit
  typedef logic [7:0] addr_byte_t;

  // Data byte
  typedef logic [7:0] data_byte_t;

  // Register map offsets for a simple APB-like interface
  typedef enum logic [2:0] {
    REG_CTRL   = 3'h0,  // Control register (enable, mode)
    REG_CMD    = 3'h1,  // Command register (write command here)
    REG_STATUS = 3'h2,  // Status register (read-only)
    REG_DATA   = 3'h3,  // Data TX/RX buffer
    REG_ADDR   = 3'h4,  // Address register (for auto-addressing)
    REG_IRQ_EN = 3'h5,  // Interrupt enable
    REG_IRQ_ST = 3'h6   // Interrupt status (mirrors STATUS; NOT clear-on-read —
                        // the register interface has no read strobe)
  } i2c_reg_e;

  //-----------------------------------------------------------------------------
  // Section 4 : General-Purpose Functions
  //-----------------------------------------------------------------------------
  // Function to build an address byte from a 7-bit address and direction
  function automatic addr_byte_t build_addr_byte(
    logic [6:0] addr,
    i2c_dir_e   dir
  );
    return {addr, dir}; // {7-bit address, R/W bit}
  endfunction

  // Function to check if an address byte is valid (for general call / reserved)
  function automatic logic is_valid_addr(addr_byte_t addr_byte);
    // 0000_XXX and 1111_XXX are reserved as per UM10204
    return !((addr_byte[7:4] == 4'b0000) || (addr_byte[7:4] == 4'b1111));
  endfunction

endpackage : i2c_pkg

`endif
