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
//=============================================================================
// GENERATED FILE — do not edit. Rebuild with scripts/build_eda_playground.sh
// Source of truth: rtl/ tb/ uvm/ sva/ in the project tree.
//=============================================================================
//=============================================================================
// File          : i2c_master_controller.sv
// Description   : Synthesizable I2C Master Byte-Level Controller (FIXED)
//               : Generates START, STOP, data bytes, handles ACK/NACK and
//               : clock stretching. Interfaces with a host CPU via an APB-like
//               : register interface.
// Language      : SystemVerilog (IEEE 1800-2012)
//=============================================================================

`ifndef I2C_MASTER_CONTROLLER_SV
`define I2C_MASTER_CONTROLLER_SV

module i2c_master_controller (
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

  // Import package
  import i2c_pkg::*;

  //---------------------------------------------------------------------------
  // Internal Signals & State Machine Declaration
  //---------------------------------------------------------------------------

  // Open-Drain IO Buffers
  logic sda_o, scl_o;
  logic sda_i, scl_i;

  // Tri-state assignment for open-drain behavior
  // driving 0 asserts (pulls down), driving 1 releases (pull-up wins with 'z')  
  assign sda = (sda_o == 1'b0) ? 1'b0 : 1'bz;
  assign scl = (scl_o == 1'b0) ? 1'b0 : 1'bz;

  // SCL/SDA are asynchronous (other masters / stretching slaves drive them).
  // Two-flop synchronizers protect the edge detectors and FSM.
  logic scl_meta, scl_sync;
  logic sda_meta, sda_sync;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_meta <= 1'b1;
      scl_sync <= 1'b1;
      sda_meta <= 1'b1;
      sda_sync <= 1'b1;
    end else begin
      scl_meta <= scl;
      scl_sync <= scl_meta;
      sda_meta <= sda;
      sda_sync <= sda_meta;
    end
  end

  assign sda_i = sda_sync;
  assign scl_i = scl_sync;

  // SCL Edge Detection for Sampling
  logic scl_d;
  logic scl_rise;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_d <= 1'b1;
    end else begin
      scl_d <= scl_i;
    end
  end

  assign scl_rise = ( scl_i && !scl_d);

  //---------------------------------------------------------------------------
  // Internal State Machine
  //---------------------------------------------------------------------------
  typedef enum logic [4:0] {
    STATE_IDLE,
    STATE_START_1,
    STATE_START_2,
    STATE_TX_BIT,
    STATE_RX_BIT,
    STATE_ACK_WAIT,
    STATE_ACK_SEND,
    STATE_BYTE_HOLD,   // SCL held LOW between bytes — keeps bus ownership
    STATE_STOP_1,      // setup: SCL low, SDA low
    STATE_STOP_2,      // SCL rises (SDA still low)
    STATE_STOP_3,      // SDA rises while SCL high = STOP on the wire
    STATE_REP_START_1, // setup: SCL high, SDA high
    STATE_REP_START_2  // SDA falls while SCL high = Sr on the wire
  } state_e;

  state_e state, next_state;

  //---------------------------------------------------------------------------
  // Registers for Host Interface
  //---------------------------------------------------------------------------
  logic [7:0] reg_data_buf;
  logic [7:0] reg_addr;
  logic [7:0] reg_ctrl;
  logic [7:0] reg_cmd;
  logic [7:0] reg_status;
  logic [7:0] reg_irq_en;

  logic       cmd_valid;
  i2c_cmd_e   current_cmd;

  //---------------------------------------------------------------------------
  // Bit Counter & Timing Control
  //---------------------------------------------------------------------------
  logic [2:0] bit_cnt;

  // Timer with one-shot clear to avoid infinite loop
  localparam int TIMER_W = $clog2(T_SCL_PERIOD);
  localparam logic [TIMER_W-1:0] TIMER_LAST       = TIMER_W'(T_SCL_PERIOD - 1);
  localparam logic [TIMER_W-1:0] SCL_LOW_TICKS    = TIMER_W'(T_SCL_LOW);
  localparam logic [TIMER_W-1:0] SCL_HI_END_TICKS = TIMER_W'(T_SCL_LOW + T_SCL_HIGH - 1);

  logic [TIMER_W-1:0] timer;
  logic               timer_clr;
  logic               timer_expired;

  // Slave is stretching: we released SCL but the wire is still LOW.
  // While this is true the bit timer freezes, so every SCL-high window
  // (including the ACK sample window) starts only once the slave lets go.
  logic scl_stretched;

  // Clock stretch detection
  logic [15:0] stretch_cnt;

  // Registered ACK sample (sampled on SCL rising edge)
  logic ack_received;

  // Arbitration-loss flag (set in the always_ff near the bottom of the file;
  // declared here because the FSM combinational block reads it)
  logic arb_lost_reg;

  //---------------------------------------------------------------------------
  // Shift Register
  //---------------------------------------------------------------------------
  logic [7:0] shift_reg;

  //---------------------------------------------------------------------------
  // Host Interface Logic (Simple APB-like Register Map)
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_data_buf <= 8'h00;
      reg_addr     <= 8'h00;
      reg_ctrl     <= 8'h00;
      reg_cmd      <= 8'h00;
      reg_irq_en   <= 8'h00;
      cmd_valid    <= 1'b0;
    end else begin
      if (cpu_wr) begin
        case (cpu_addr)
          REG_DATA:    reg_data_buf <= cpu_wdata;
          REG_ADDR:    reg_addr     <= cpu_wdata;
          REG_CTRL:    reg_ctrl     <= cpu_wdata;
          REG_CMD:     reg_cmd      <= cpu_wdata;
          REG_IRQ_EN:  reg_irq_en   <= cpu_wdata;
          default:     ;
        endcase
      end

      // FIX BUG #10: Capture received byte into reg_data_buf when RX completes.
      // Without this, CPU reads 0x00 via REG_DATA after every read transaction
      // because shift_reg is never forwarded to the CPU-visible register.
      if (state == STATE_RX_BIT && next_state == STATE_ACK_SEND) begin
        reg_data_buf <= shift_reg;
      end

      // Command valid pulse when CMD register is written
      if (cpu_wr && (cpu_addr == REG_CMD)) begin
        cmd_valid <= 1'b1;
      end else begin
        cmd_valid <= 1'b0;
      end
    end
  end

  // CPU read logic
  always_comb begin
    case (cpu_addr)
      REG_CTRL:   cpu_rdata = reg_ctrl;
      REG_STATUS: cpu_rdata = reg_status;
      REG_DATA:   cpu_rdata = reg_data_buf;
      REG_ADDR:   cpu_rdata = reg_addr;
      REG_IRQ_EN: cpu_rdata = reg_irq_en;
      REG_IRQ_ST: cpu_rdata = reg_status;
      default:    cpu_rdata = 8'h00;
    endcase
  end

  // Map reg_cmd to enumeration
  assign current_cmd = i2c_cmd_e'(reg_cmd[3:0]);

  //---------------------------------------------------------------------------
  // Timer / Clock Divider for SCL Generation (FIXED BUG #2, #3)
  //---------------------------------------------------------------------------

  assign scl_stretched = (scl_o == 1'b1) && (scl_i == 1'b0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      timer     <= '0;
      timer_expired <= 1'b0;
    end else if (timer_clr) begin
      timer     <= '0;
      timer_expired <= 1'b0;
    end else if (scl_stretched) begin
      // Freeze bit timing while the slave stretches SCL. Without this the
      // FSM paced itself purely on the timer and would e.g. exit ACK_WAIT
      // (reading a never-sampled ack_received == 0 -> "NACK") even though
      // the 9th SCL pulse never actually happened on the wire.
      timer_expired <= 1'b0;
    end else begin
      if (timer == TIMER_LAST) begin
        timer     <= '0;
        timer_expired <= 1'b1;
      end else begin
        timer     <= timer + 1'b1;
        timer_expired <= 1'b0;
      end
    end
  end

  // Reset timer on state change. Combinational is safe here: timer_clr is
  // only consumed synchronously, and all FSM inputs are registered (the bus
  // inputs go through 2-flop synchronizers), so no glitch can be latched.
  assign timer_clr = (state != next_state);

  //---------------------------------------------------------------------------
  // Clock Stretch Detection
  // FIX: only count cycles where the SLAVE is holding SCL low against our
  // release (scl_o==1, wire low). The old version counted the master's own
  // SCL-low half-periods as "stretching".
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stretch_cnt <= '0;
    end else if (scl_stretched && state != STATE_IDLE) begin
      stretch_cnt <= stretch_cnt + 1'b1;
    end else begin
      stretch_cnt <= '0;
    end
  end

  assign timeout = (stretch_cnt >= 16'(MAX_CLK_STRETCH));

  //---------------------------------------------------------------------------
  // SCL Generation Logic (FIXED BUG #2: SCL now toggles correctly)
  //---------------------------------------------------------------------------

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_o <= 1'b1; // Release SCL
    end else begin
      case (state)
        // IDLE / Start: SCL High
        STATE_IDLE:         scl_o <= 1'b1;
        STATE_START_1:      scl_o <= 1'b1;               // SCL High during START setup
        STATE_START_2:      scl_o <= 1'b0;               // SCL Low after START

        // TX/RX Bit: Toggle SCL with proper timing
        STATE_TX_BIT: begin
          if (timer < SCL_LOW_TICKS)        scl_o <= 1'b0; // SCL Low (data setup)
          else if (timer <= SCL_HI_END_TICKS) scl_o <= 1'b1; // SCL High (sample window)
          else                              scl_o <= 1'b0;
        end
        STATE_RX_BIT: begin
          if (timer < SCL_LOW_TICKS)        scl_o <= 1'b0; // Drive data / slave setup
          else if (timer <= SCL_HI_END_TICKS) scl_o <= 1'b1; // Sample window
          else                              scl_o <= 1'b0;
        end

        STATE_ACK_WAIT:     scl_o <= (timer < SCL_LOW_TICKS) ? 1'b0 : 1'b1; // 9th bit ACK/NACK
        STATE_ACK_SEND:     scl_o <= (timer < SCL_LOW_TICKS) ? 1'b0 : 1'b1;

        // Holding the bus between bytes: SCL LOW keeps every slave frozen
        // mid-transaction and prevents any implicit STOP when SDA releases.
        STATE_BYTE_HOLD:    scl_o <= 1'b0;

        // STOP: SCL must rise BEFORE SDA rises (FIX: the old 2-phase STOP
        // raised both on the same edge — a same-cycle race at the slave).
        STATE_STOP_1:       scl_o <= 1'b0;
        STATE_STOP_2:       scl_o <= 1'b1;               // SCL rises, SDA still low
        STATE_STOP_3:       scl_o <= 1'b1;               // SDA rises now -> STOP

        // Repeated START: SDA must fall while SCL is ALREADY high (FIX: the
        // old REP_START_2 dropped SCL and SDA on the same edge, so no Sr
        // condition ever appeared on the wire).
        STATE_REP_START_1:  scl_o <= 1'b1;               // SCL High, SDA high
        STATE_REP_START_2:  scl_o <= 1'b1;               // SCL stays high for Sr edge

        default:            scl_o <= 1'b1;
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // SDA Output Logic (FIXED: handshaking correctly)
  //---------------------------------------------------------------------------

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sda_o <= 1'b1; // Release SDA
    end else begin
      case (state)
        STATE_IDLE:            sda_o <= 1'b1;            // Bus idle (pulled up)
        STATE_START_1:         sda_o <= 1'b0;           // SDA falls for START
        STATE_START_2:         sda_o <= 1'b0;           // Keep SDA LOW
        STATE_TX_BIT:          sda_o <= shift_reg[7];   // MSB first
        STATE_BYTE_HOLD:       sda_o <= 1'b1;           // Release SDA (SCL is LOW — safe)
        STATE_ACK_WAIT:        sda_o <= 1'b1;           // Release SDA to let slave ACK
        STATE_ACK_SEND: begin
          // FIX: Differentiate ACK vs NACK based on command
          if (current_cmd == CMD_READ_NACK)
            sda_o <= 1'b1;       // Drive NACK (HIGH) — signals last byte to slave
          else
            sda_o <= 1'b0;       // Drive ACK (LOW) — request more data from slave
        end
        STATE_STOP_1:          sda_o <= 1'b0;           // SDA LOW (setup)
        STATE_STOP_2:          sda_o <= 1'b0;           // hold LOW while SCL rises
        STATE_STOP_3:          sda_o <= 1'b1;           // SDA rises while SCL high
        STATE_REP_START_1:     sda_o <= 1'b1;           // SDA High before falling
        STATE_REP_START_2:     sda_o <= 1'b0;           // SDA falls while SCL high = Sr
        default:               sda_o <= 1'b1;
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Shift Register (FIXED: RX logic regenerates)
  //---------------------------------------------------------------------------

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shift_reg <= 8'h00;
    end else begin
      // Load data for transmission — only while the FSM is parked (IDLE or
      // BYTE_HOLD). A REG_DATA write mid-byte must not clobber the shifter.
      if (cpu_wr && (cpu_addr == REG_DATA) &&
          (state == STATE_IDLE || state == STATE_BYTE_HOLD)) begin
        shift_reg <= cpu_wdata;
      end
      // Shift IN on SCL rising edge during RX
      else if (state == STATE_RX_BIT && scl_rise) begin
        shift_reg <= {shift_reg[6:0], sda_i}; // LSB-in, MSB aligned
      end
      // Shift OUT on timer expiry during TX (advance to next bit)
      else if (state == STATE_TX_BIT && timer_expired) begin
        shift_reg <= {shift_reg[6:0], 1'b0}; // Shift left (MSB already on bus)
      end
    end
  end

  //---------------------------------------------------------------------------
  // Main State Machine - Sequential
  //---------------------------------------------------------------------------

  wire timer_done;
  assign timer_done = timer_expired;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= STATE_IDLE;
      ack       <= 1'b0;
      nack      <= 1'b0;
      done      <= 1'b0;
      busy      <= 1'b0;
      bus_error <= 1'b0;
    end else begin
      state     <= next_state;
      busy      <= (next_state != STATE_IDLE);

      // FIX: bit_cnt is driven exclusively by its own always_ff below.
      // DO NOT drive bit_cnt here — that caused a multi-driver violation.

      // Assert done for one cycle when STOP completes
      done <= (state == STATE_STOP_3 && next_state == STATE_IDLE);

      // FIX: ack/nack are now sticky — they persist until a new command starts
      if (state == STATE_ACK_WAIT && timer_expired) begin
        ack       <= ack_received;
        nack      <= ~ack_received;
        // FIX: bus_error should NOT fire on NACK — NACK is a valid protocol response.
        // bus_error should only fire on timeout (actual protocol violation).
        bus_error <= 1'b0;
      end else if ((state == STATE_IDLE || state == STATE_BYTE_HOLD) && cmd_valid) begin
        // Clear sticky status when a new command begins (from IDLE or from
        // the between-bytes hold state)
        ack       <= 1'b0;
        nack      <= 1'b0;
        bus_error <= 1'b0;
      end
      // Bus error on timeout (SCL held low beyond MAX_CLK_STRETCH)
      if (timeout) bus_error <= 1'b1;
    end
  end

  //---------------------------------------------------------------------------
  // Main State Machine - Combinational Next-State Logic (FIXED BUG #3: multi-driver removed)
  //---------------------------------------------------------------------------

  always_comb begin
    // Default: hold current state
    next_state = state;

    // Clock stretching escape hatch in combinational logic
    if (timeout) begin
      next_state = STATE_IDLE;
    end else begin
      case (state)
        //=====================================================================
        // STATE_IDLE
        //=====================================================================
        STATE_IDLE: begin
          // FIX: from IDLE we do not own the bus, so the ONLY legal command
          // is CMD_START. (The old FSM happily clocked data bits onto SDA
          // with no START condition — an invalid I2C transaction.)
          if (cmd_valid && current_cmd == CMD_START) begin
            next_state = STATE_START_1;
          end else begin
            next_state = STATE_IDLE;
          end
        end

        //=====================================================================
        // STATE_START_1 & _2
        //=====================================================================
        STATE_START_1: if (timer_done) next_state = STATE_START_2;
        STATE_START_2: if (timer_done) next_state = STATE_TX_BIT;

        //=====================================================================
        // STATE_TX_BIT
        // Shift out 8 data bits (MSB first).
        // After 8 bits, wait for ACK.
        // T13: On arb_lost, abandon transaction and return to IDLE — we release
        // the bus so the winning master can continue.
        //=====================================================================
        STATE_TX_BIT: begin
          if (arb_lost_reg) begin
            next_state = STATE_IDLE;
          end else if (timer_done) begin
            if (bit_cnt == 3'd7) begin
              next_state = STATE_ACK_WAIT;
            end else begin
              next_state = STATE_TX_BIT;
            end
          end else begin
            next_state = STATE_TX_BIT;
          end
        end

        //=====================================================================
        // STATE_ACK_WAIT
        // Release SDA and sample ACK/NACK on 9th SCL cycle.
        // T13: If arb_lost was latched on the way in, return to IDLE.
        //=====================================================================
        STATE_ACK_WAIT: begin
          if (arb_lost_reg) begin
            next_state = STATE_IDLE;
          end else if (timer_done) begin
            if (ack_received) begin
              // FIX: byte complete — HOLD the bus (SCL low) and wait for the
              // CPU's next command. The old FSM returned to IDLE here, which
              // released SCL+SDA mid-transaction and forged a STOP on the
              // wire, breaking every multi-byte write.
              next_state = STATE_BYTE_HOLD;
            end else begin
              next_state = STATE_STOP_1; // NACK -> abort with STOP
            end
          end else begin
            next_state = STATE_ACK_WAIT;
          end
        end

        //=====================================================================
        // STATE_RX_BIT
        // Sample 8 bits from SDA on SCL rising edges.
        //=====================================================================
        STATE_RX_BIT: begin
          if (timer_done) begin
            if (bit_cnt == 3'd7) begin
              next_state = STATE_ACK_SEND;
            end else begin
              next_state = STATE_RX_BIT;
            end
          end else begin
            next_state = STATE_RX_BIT;
          end
        end

        //=====================================================================
        // STATE_ACK_SEND
        // Master drives ACK (LOW) or NACK (HIGH) after receiving byte.
        //=====================================================================
        STATE_ACK_SEND: begin
          // FIX: as above — keep bus ownership after a received byte.
          if (timer_done) next_state = STATE_BYTE_HOLD;
        end

        //=====================================================================
        // STATE_BYTE_HOLD
        // Between bytes of one transaction: SCL held LOW, SDA released.
        // The CPU decides what happens next (next byte, Sr, or STOP).
        //=====================================================================
        STATE_BYTE_HOLD: begin
          if (cmd_valid) begin
            case (current_cmd)
              CMD_WRITE:     next_state = STATE_TX_BIT;
              CMD_READ_ACK:  next_state = STATE_RX_BIT;
              CMD_READ_NACK: next_state = STATE_RX_BIT;
              CMD_STOP:      next_state = STATE_STOP_1;
              CMD_REP_START: next_state = STATE_REP_START_1;
              CMD_ABORT:     next_state = STATE_IDLE;
              default:       next_state = STATE_BYTE_HOLD;
            endcase
          end else begin
            next_state = STATE_BYTE_HOLD;
          end
        end

        //=====================================================================
        // STATE_STOP_1 & _2
        //=====================================================================
        STATE_STOP_1: if (timer_done) next_state = STATE_STOP_2;
        STATE_STOP_2: if (timer_done) next_state = STATE_STOP_3;
        STATE_STOP_3: if (timer_done) next_state = STATE_IDLE;

        //=====================================================================
        // STATE_REP_START_1 & _2
        //=====================================================================
        STATE_REP_START_1: if (timer_done) next_state = STATE_REP_START_2;
        // After the Sr edge, reuse START_2 to bring SCL low before clocking
        // out the (re-)addressed byte.
        STATE_REP_START_2: if (timer_done) next_state = STATE_START_2;

        default: next_state = STATE_IDLE;

      endcase
    end
  end

  // FIX BUG #2: ack_received registered on SCL rising edge during STATE_ACK_WAIT
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ack_received <= 1'b0;
    end else if (state == STATE_ACK_WAIT && scl_rise) begin
      ack_received <= (sda_i == 1'b0); // Sample SDA on SCL rising edge
    end else if (state != STATE_ACK_WAIT) begin
      ack_received <= 1'b0;
    end
  end

  //---------------------------------------------------------------------------
  // Bit Counter Logic (FIXED: clear on state entry, increment on timer expiry)
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bit_cnt <= 3'd0;
    end else begin
      if (next_state != state) begin
        bit_cnt <= 3'd0; // Reset on state transition
      end else if ((state == STATE_TX_BIT || state == STATE_RX_BIT) && timer_done) begin
        bit_cnt <= bit_cnt + 1'b1;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Arbitration Loss Detection (T13)
  // During data transmit phase, if we release SDA (drive sda_o=1) but the bus
  // is LOW (sda_i=0), some other master is also transmitting and won the bit
  // (wired-AND: 0 wins). We lost arbitration. Only check during the SCL HIGH
  // window when bits are valid on the bus.
  //
  // On arb_lost: FSM returns to IDLE without driving STOP — releasing the bus
  // is the correct multi-master courtesy (the winning master continues).
  //---------------------------------------------------------------------------
  // sda_i/scl_i are 2-flop-synchronized (2 clk behind the wire), so the
  // wired-AND comparison must use an equally delayed copy of our own drive
  // value. Comparing raw sda_o against the delayed sda_i fires a false
  // arb-loss on every 0->1 data-bit transition.
  logic sda_o_d1, sda_o_d2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sda_o_d1 <= 1'b1;
      sda_o_d2 <= 1'b1;
    end else begin
      sda_o_d1 <= sda_o;
      sda_o_d2 <= sda_o_d1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arb_lost_reg <= 1'b0;
    end else if (state == STATE_IDLE) begin
      arb_lost_reg <= 1'b0;  // clear on idle
    end else if ((state == STATE_TX_BIT) && (sda_o_d2 == 1'b1) && (sda_i == 1'b0) && (scl_i == 1'b1)) begin
      arb_lost_reg <= 1'b1;
    end
  end

  assign arb_lost = arb_lost_reg;

  //---------------------------------------------------------------------------
  // Status & Interrupt Logic
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_status <= 8'h00;
    end else begin
      case (state)
        STATE_IDLE:      reg_status <= {5'd0, STS_IDLE};
        // Between bytes: report the outcome of the byte that just finished
        // so the CPU can poll for ACK/NACK before issuing the next command.
        STATE_BYTE_HOLD: reg_status <= nack ? {5'd0, STS_NACK} : {5'd0, STS_ACK};
        STATE_STOP_3:    reg_status <= {5'd0, STS_DONE};
        default:         reg_status <= {5'd0, STS_BUSY};
      endcase
      // Overrides, highest priority last
      if (timeout)      reg_status <= {5'd0, STS_TIMEOUT};
      if (arb_lost_reg) reg_status <= {5'd0, STS_ARB_LOST};
    end
  end

  // IRQ Logic (registered)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_irq <= 1'b0;
    end else begin
      // Bit positions match i2c_pkg::i2c_irq_e (IRQ_DONE=0 ... IRQ_ARB_LOST=5)
      cpu_irq <= |({reg_irq_en[IRQ_DONE]      & done,
                    reg_irq_en[IRQ_ACK]       & ack,
                    reg_irq_en[IRQ_NACK]      & nack,
                    reg_irq_en[IRQ_TIMEOUT]   & timeout,
                    reg_irq_en[IRQ_BUS_ERROR] & bus_error,
                    reg_irq_en[IRQ_ARB_LOST]  & arb_lost_reg});
    end
  end

endmodule

`endif

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

//=============================================================================
// File          : i2c_slave_controller.sv (FIXED)
// Description   : Synthesizable I2C Slave Controller (FIXED)
//               : Implements 7-bit address matching, ACK/NACK generation,
//               : 8-register bank access, and clock stretching support.
// Language      : SystemVerilog (IEEE 1800-2012)
//=============================================================================

`ifndef I2C_SLAVE_CONTROLLER_SV
`define I2C_SLAVE_CONTROLLER_SV

module i2c_slave_controller
#(
  // Configurable slave address (7-bit)
  parameter logic [6:0] SLAVE_ADDR = 7'h50  // Default: 0x50
)
(
  // System
  input  logic        clk,
  input  logic        rst_n,

  // I2C Physical Interface (Open-Drain)
  inout  wire         scl,
  inout  wire         sda,

  // CPU-like register interface (for the 8 internal registers)
  output logic [7:0]  reg_bank    [0:7],
  output logic        reg_updated [0:7],
  output logic        addr_match,
  output logic        active,

  // Clock stretching control (to test stretch behavior)
  input  logic        stretch_en,
  input  logic [15:0] stretch_cycles,
  input  logic        force_data_nack,

  // Status outputs
  output logic        rx_data_valid,
  output logic [7:0]  rx_data,
  output logic        tx_ack,
  output logic        tx_nack,
  output logic        bus_error
);

  import i2c_pkg::*;

  //*******************************************************************
  // Internal Signals
  //*******************************************************************

  // Open-Drain IO Buffers
  logic sda_o, sda_i;
  logic scl_i;
  logic scl_o; // FIX: SCL can be driven low for clock stretching

  assign sda = (sda_o == 1'b0) ? 1'b0 : 1'bz;
  // FIX: SCL is also open-drain, drive 0 for stretch, z to release
  assign scl = (scl_o == 1'b0) ? 1'b0 : 1'bz;

  // SCL/SDA are asynchronous to clk (driven by an external master). Two-flop
  // synchronizers guard the edge detectors and FSM against metastability.
  // All downstream logic sees the bus with 2 cycles of latency, which is
  // negligible against the shortest legal SCL phase.
  logic scl_meta, scl_sync;
  logic sda_meta, sda_sync;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_meta <= 1'b1;
      scl_sync <= 1'b1;
      sda_meta <= 1'b1;
      sda_sync <= 1'b1;
    end else begin
      scl_meta <= scl;
      scl_sync <= scl_meta;
      sda_meta <= sda;
      sda_sync <= sda_meta;
    end
  end

  assign sda_i = sda_sync;
  assign scl_i = scl_sync;

  // FSM States
  typedef enum logic [3:0] {
    SLV_IDLE,
    SLV_START,
    SLV_ADDR,
    SLV_ACK,
    SLV_RX,
    SLV_RX_ACK,
    SLV_TX,
    SLV_TX_ACK,
    SLV_STRETCH
  } slv_state_e;

  slv_state_e state, next_state;
  slv_state_e saved_state;

  // Address & Data
  logic [6:0] rx_addr;
  logic       rx_rw;
  logic [3:0] bit_cnt;
  logic [7:0] shift_reg;
  logic [2:0] reg_ptr;

  // TX Shift Register for read mode
  logic [7:0] tx_shift_reg;

  // Address match flag
  logic       addr_matched;

  // Clock stretch
  logic [15:0] stretch_timer;
  logic       stretch_active;
  logic       stretch_en_d;    // FIX: edge detect to prevent infinite re-trigger
  logic       stretch_en_rise;
  logic       stretch_pending; // armed request waiting for a transaction

  // Internal register bank
  logic [7:0] internal_regs [0:7];
  logic       internal_updated [0:7];

  // Interrupt / status signals
  logic       active_int;

  // FIX: Latched data byte to avoid sampling ACK as data bit
  logic [7:0] latched_rx_byte;
  logic       rx_write_done;
  logic       reg_ptr_inc_done;

  //*******************************************************************
  // SCL Edge Detection
  //*******************************************************************
  logic scl_d, scl_rise, scl_fall;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) scl_d <= 1'b1;
    else        scl_d <= scl_i;
  end

  assign scl_rise = ( scl_i && !scl_d);
  assign scl_fall = (!scl_i &&  scl_d);

  //*******************************************************************
  // START / STOP Detection
  //*******************************************************************
  logic sda_d;
  logic start_cond;
  logic stop_cond;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sda_d <= 1'b1;
    else        sda_d <= sda_i;
  end

  // START: SDA falls while SCL is HIGH
  assign start_cond = (sda_i == 1'b0 && sda_d == 1'b1 && scl_i == 1'b1);
  // STOP: SDA rises while SCL is HIGH
  assign stop_cond  = (sda_i == 1'b1 && sda_d == 1'b0 && scl_i == 1'b1);

  //*******************************************************************
  // Bit Counter
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bit_cnt <= 4'd0;
    end else if (start_cond || stop_cond) begin
      bit_cnt <= 4'd0;
    end else if (state == SLV_ACK || state == SLV_RX_ACK || state == SLV_TX_ACK) begin
      bit_cnt <= 4'd0;
    end else if (scl_rise) begin
      bit_cnt <= bit_cnt + 1'b1;
    end
  end

  //*******************************************************************
  // Shift Register
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shift_reg <= 8'h00;
    end else if (scl_rise) begin
      // FIX: Only shift during ADDR and RX, not TX (TX is outgoing, self-read is wasteful)
      if (state == SLV_ADDR || state == SLV_RX) begin
        shift_reg <= {shift_reg[6:0], sda_i};
      end
    end
  end

  //*******************************************************************
  // Address Latching
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_addr      <= 7'h00;
      rx_rw        <= 1'b0;
      addr_matched <= 1'b0;
    end else if (state == SLV_ADDR && bit_cnt == 4'd7 && scl_rise) begin
      // After 8 clock rises, shift_reg[6:0] has the 7-bit address (non-blocking reads OLD value)
      rx_addr      <= shift_reg[6:0];
      rx_rw        <= sda_i;  // R/W bit is the 8th bit, currently on SDA
      addr_matched <= (shift_reg[6:0] == SLAVE_ADDR);
    end
  end

  assign addr_match = addr_matched;

  //*******************************************************************
  // Register Pointer
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_ptr <= 3'd0;
      reg_ptr_inc_done <= 1'b0;
    end else if (state != SLV_ACK && next_state == SLV_ACK && addr_matched) begin
      // Reset on ENTRY to SLV_ACK only (not every cycle in the state) so a
      // stretch-resume into SLV_ACK cannot zero the pointer mid-transaction.
      reg_ptr <= 3'd0;
    end else if (state == SLV_RX_ACK && active_int && rx_rw == 1'b0 && !reg_ptr_inc_done) begin
      reg_ptr <= reg_ptr + 1'b1;
      reg_ptr_inc_done <= 1'b1;
    end else if (state == SLV_TX_ACK && active_int && rx_rw == 1'b1 && !reg_ptr_inc_done) begin
      reg_ptr <= reg_ptr + 1'b1;
      reg_ptr_inc_done <= 1'b1;
    end else if (state != SLV_RX_ACK && state != SLV_TX_ACK) begin
      reg_ptr_inc_done <= 1'b0;
    end
  end

  //*******************************************************************
  // FIX: Latched RX Byte
  // Latch the rx_byte on scl_fall after all 8 data bits are received  
  // This avoids using the ACK bit (9th) as the 8th data bit
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      latched_rx_byte <= 8'h00;
    end else if (state == SLV_RX && bit_cnt == 4'd7 && scl_rise) begin
      latched_rx_byte <= {shift_reg[6:0], sda_i}; // Correct: last data bit captured on last scl_rise
    end
  end

  //*******************************************************************
  // Register Bank Logic (8 registers) (FIXED)
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 8; i++) begin
        internal_regs[i]    <= 8'h00;
        internal_updated[i] <= 1'b0;
      end
      rx_write_done <= 1'b0;  // FIX: properly reset to avoid X-pessimism
    end else begin
      // Clear update strobes
      for (int i = 0; i < 8; i++) begin
        internal_updated[i] <= 1'b0;
      end

      if (state == SLV_RX_ACK && active_int && (rx_rw == 1'b0) && !rx_write_done) begin
        internal_regs[reg_ptr]    <= latched_rx_byte;
        internal_updated[reg_ptr] <= 1'b1;
        rx_write_done             <= 1'b1;
      end else if (state != SLV_RX_ACK) begin
        rx_write_done <= 1'b0;
      end
    end
  end

  // Assign outputs
  always_comb begin
    for (int i = 0; i < 8; i++) begin
      reg_bank[i]    = internal_regs[i];
      reg_updated[i] = internal_updated[i];
    end
  end

  //*******************************************************************
  // TX Shift Register (FIXED: added for read mode)
  // Load with data from reg_bank when entering read mode
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_shift_reg <= 8'h00;
    end else if (state == SLV_ACK && addr_matched && rx_rw == 1'b1) begin
      // First byte: load from reg_ptr (which is 0 after SLV_ACK)
      tx_shift_reg <= internal_regs[reg_ptr];
    end else if (state == SLV_TX_ACK && scl_fall && sda_i == 1'b0 && active_int) begin
      // Master ACK'd: load NEXT register byte (reg_ptr already incremented by one-shot guard)
      tx_shift_reg <= internal_regs[reg_ptr];
    end else if (state == SLV_TX && scl_fall) begin
      // Shift out next bit (MSB first)
      tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};
    end
  end

  //*******************************************************************
  // SDA Output Logic (Open-Drain) (FIXED for TX)
  //*******************************************************************
  // I2C data-validity rule (UM10204 3.1.3): SDA may only change while SCL is
  // LOW. In the driving states we therefore gate every sda_o update on
  // scl_i == 0 and HOLD the current value through the SCL-high window.
  // Non-driving states release unconditionally (the bus is already past the
  // window where a release could forge a START/STOP).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sda_o <= 1'b1;
    end else begin
      case (state)
        // ACK: drive SDA LOW during 9th clock
        SLV_ACK: begin
          if (scl_i == 1'b0) begin
            if (addr_matched) sda_o <= 1'b0; // ACK (match found)
            else              sda_o <= 1'b1; // NACK (no match)
          end
        end

        // RX ACK: send ACK for received byte
        SLV_RX_ACK: begin
          if (scl_i == 1'b0) begin
            if (active_int && !force_data_nack) sda_o <= 1'b0; // ACK
            else                                 sda_o <= 1'b1; // NACK
          end
        end

        // FIX TX: Slave drives DATA bit from tx_shift_reg in read mode
        SLV_TX: begin
          if (scl_i == 1'b0) begin
            if (active_int) begin
              sda_o <= tx_shift_reg[7]; // MSB first from shift register
            end else begin
              sda_o <= 1'b1;
            end
          end
        end

        // FIX (EP live-run): HOLD sda_o while stretching. A slave that
        // stretches the clock during an ACK/data bit must keep SDA stable —
        // it has only paused the clock, not released the bus. The old code
        // let SLV_STRETCH fall into `default: sda_o <= 1` and RELEASED the
        // ACK mid-stretch, so a monitor sampling at the SCL rising edge read
        // a NACK and derailed. Empty statement = the flop holds its value.
        SLV_STRETCH: /* hold sda_o */ ;

        default: sda_o <= 1'b1; // Release SDA (open-drain high)
      endcase
    end
  end

  //*******************************************************************
  // SCL Output Logic (for Clock Stretching)
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_o <= 1'b1;
    end else if (stretch_active) begin
      scl_o <= 1'b0;
    end else begin
      scl_o <= 1'b1;
    end
  end

  //*******************************************************************
  // Active Signal (Transaction in progress for this slave)
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_int <= 1'b0;
    end else if (stop_cond) begin
      active_int <= 1'b0;
    end else if (state == SLV_ACK) begin
      active_int <= addr_matched;
    end
  end

  assign active = active_int;

  //*******************************************************************
  // Clock Stretching (FIXED: edge-detect stretch_en to prevent infinite re-trigger)
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) stretch_en_d <= 1'b0;
    else        stretch_en_d <= stretch_en;
  end
  assign stretch_en_rise = stretch_en && !stretch_en_d;

  // FIX (post-audit): the old logic required stretch_en_rise AND active_int
  // in the same cycle. Testbenches arm stretch_en BEFORE the transaction
  // begins (active_int == 0), so the edge was swallowed and the slave never
  // actually stretched. A pending latch keeps the armed request until a
  // transaction is active, while still preventing level re-triggering.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stretch_timer   <= 16'd0;
      stretch_active  <= 1'b0;
      stretch_pending <= 1'b0;
    end else begin
      if (stretch_en_rise) begin
        stretch_pending <= 1'b1;  // arm on rising edge only (no re-trigger)
      end

      if (stretch_active) begin
        if (stretch_timer >= stretch_cycles) begin
          stretch_active <= 1'b0;
        end else begin
          stretch_timer <= stretch_timer + 1'b1;
        end
      end else if (stretch_pending && active_int) begin
        stretch_active  <= 1'b1;
        stretch_pending <= 1'b0;
        // FIX BUG #15: start at 1 so >= fires after exactly stretch_cycles.
        stretch_timer   <= 16'd1;
      end
    end
  end

  //*******************************************************************
  // Main FSM - Sequential
  //*******************************************************************
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= SLV_IDLE;
      saved_state <= SLV_IDLE;
    end else begin
      // Capture the resume point exactly on the transition INTO SLV_STRETCH.
      // (The old `stretch_active && state != SLV_STRETCH` form could capture
      // one cycle late and resume into an already-advanced state.)
      if (next_state == SLV_STRETCH && state != SLV_STRETCH)
        saved_state <= state;
      state <= next_state;
    end
  end

  //*******************************************************************
  // Main FSM - Combinational Next-State Logic
  //*******************************************************************
  always_comb begin
    next_state = state;

    if (start_cond) begin
      next_state = SLV_START;
    end else if (stop_cond) begin
      next_state = SLV_IDLE;
    end else begin
      case (state)
      //==================================================================
      // SLV_IDLE: Waiting for a START condition from the master.
      // NOTE: start_cond is already checked above the case statement,
      // so this branch only handles the no-start case.
      //==================================================================
      SLV_IDLE: begin
        next_state = SLV_IDLE;
      end

      //==================================================================
      // SLV_START: Master generated START. Begin sampling address.
      //==================================================================
      SLV_START: begin
        next_state = SLV_ADDR;
      end

      //==================================================================
      // SLV_ADDR: Shift in 7-bit address + R/W bit.
      //==================================================================
      SLV_ADDR: begin
        if (bit_cnt == 4'd8 && scl_fall) begin
          // After 8 bits (address + R/W), check for match
          next_state = SLV_ACK;
        end else begin
          next_state = SLV_ADDR;
        end
      end

      //==================================================================
      // SLV_ACK: Drive ACK (SDA LOW) if address matches, else stay quiet.
      //==================================================================
      SLV_ACK: begin
        if (scl_fall) begin
          if (addr_matched) begin
            if (rx_rw == 1'b1) next_state = SLV_TX;  // Master is reading
            else                next_state = SLV_RX;  // Master is writing
          end else begin
            next_state = SLV_IDLE; // Addr mismatch, ignore transaction
          end
        end else begin
          next_state = SLV_ACK;
        end
      end

      //==================================================================
      // SLV_RX: Receive a data byte from the master.
      //==================================================================
      SLV_RX: begin
        if (bit_cnt == 4'd8 && scl_fall) begin
          next_state = SLV_RX_ACK;
        end else begin
          next_state = SLV_RX;
        end
      end

      //==================================================================
      // SLV_RX_ACK: Send ACK after receiving a byte.
      // NOTE: START/STOP are handled by the priority override at the top
      // of this block — no per-state checks needed (the old inner branches
      // were unreachable dead code).
      //==================================================================
      SLV_RX_ACK: begin
        if (scl_fall) begin
          next_state = SLV_RX; // Ready for another byte
        end else begin
          next_state = SLV_RX_ACK;
        end
      end

      //==================================================================
      // SLV_TX: Transmit a data byte to the master (read mode).
      //==================================================================
      SLV_TX: begin
        if (bit_cnt == 4'd8 && scl_fall) begin
          next_state = SLV_TX_ACK;
        end else begin
          next_state = SLV_TX;
        end
      end

      //==================================================================
      // SLV_TX_ACK: Wait for ACK/NACK from the master.
      //==================================================================
      SLV_TX_ACK: begin
        if (scl_fall) begin
          if (sda_i == 1'b0) next_state = SLV_TX;
          else                next_state = SLV_IDLE;
        end else begin
          next_state = SLV_TX_ACK;
        end
      end

      //==================================================================
      // SLV_STRETCH: Active when slave holds SCL low.
      //==================================================================
      SLV_STRETCH: begin
        // Exit when stretch timer expires or stretch disabled
        if (!stretch_active) begin
          next_state = saved_state;
        end else begin
          next_state = SLV_STRETCH;
        end
      end

      default: next_state = SLV_IDLE;

      endcase
    end

    // If stretch is active, hold in STRETCH state regardless
    if (stretch_active && active_int) next_state = SLV_STRETCH;
  end

  //*******************************************************************
  // Status & Interrupts
  //*******************************************************************
  // One-cycle strobe: internal_updated[i] pulses for exactly one clk on the
  // cycle a byte is committed to the register bank (the old level-version
  // stayed high for the whole multi-cycle SLV_RX_ACK state and would
  // double-push into any external FIFO).
  always_comb begin
    rx_data_valid = 1'b0;
    for (int i = 0; i < 8; i++) begin
      if (internal_updated[i]) rx_data_valid = 1'b1;
    end
  end
  assign rx_data       = latched_rx_byte; // FIX: use latched byte instead of shift_reg
  assign tx_ack        = (state == SLV_TX_ACK && sda_i == 1'b0 && active_int);
  assign tx_nack       = (state == SLV_TX_ACK && sda_i == 1'b1 && active_int);
  assign bus_error     = 1'b0; // Simplified for this project
  // Note: force_data_nack is an input port for test injection

endmodule

`endif

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
//=============================================================================
// GENERATED FILE — do not edit. Rebuild with scripts/build_eda_playground.sh
// Source of truth: rtl/ tb/ uvm/ sva/ in the project tree.
//=============================================================================
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

//=============================================================================
// File          : i2c_protocol_assertions.sv (FIXED v2)
// Description   : SystemVerilog Assertions for I2C Protocol Compliance
//               : A1-A9 — fixed timing for BFM compatibility, removed
//               : redundant assertions, added missing semicolons.
//               : A7: Bus must remain FREE for the FULL T_BUF window after STOP
//               :     (stronger than A2 which only checks the bus is HIGH at
//               :     some point inside the window).
//               : A8: SDA hold time after SCL falls — SDA must remain stable
//               :     for T_HD_DAT cycles after SCL fall in data/ack phase.
//               : A9: SDA setup time before SCL rises — SDA must have been
//               :     stable for T_SU_DAT cycles before each SCL rising edge
//               :     in data/ack phase (catches glitches that could corrupt
//               :     the sampled bit value).
// Language      : SystemVerilog (IEEE 1800-2012) + SVA
//=============================================================================

`ifndef I2C_PROTOCOL_ASSERTIONS_SV
`define I2C_PROTOCOL_ASSERTIONS_SV

module i2c_protocol_assertions (
  input logic        clk,
  input logic        rst_n,
  // I2C Signals (wired-AND / open-drain behavior assumed)
  inout wire         scl,
  inout wire         sda
);

  import i2c_pkg::*;

  // FIX (post-audit): failures used $error, which the UVM report server does
  // NOT count — a log could be full of SVA failures while the test printed
  // "UVM_ERROR : 0" and the regression grep called it a PASS. All assertion
  // failures now go through uvm_report_error so they fail the test.
  function automatic void sva_fail(string id, string msg);
    uvm_pkg::uvm_report_error(id, msg);
  endfunction

  // Local signals for assertion sampling
  logic sda_samp, scl_samp;
  logic sda_d, scl_d;
  logic sda_fall, sda_rise;
  logic scl_fall;

  // Bit counter for 9th-bit assertions
  logic [3:0] bit_counter;
  logic       in_data_phase;
  logic       in_ack_phase;

  // Sample on clock edges (2-stage pipeline for clean edge detection)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sda_samp <= 1'b1;
      scl_samp <= 1'b1;
    end else begin
      sda_samp <= sda;
      scl_samp <= scl;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sda_d <= 1'b1;
      scl_d <= 1'b1;
    end else begin
      sda_d <= sda_samp;
      scl_d <= scl_samp;
    end
  end

  assign sda_fall = (sda_d == 1'b1 && sda_samp == 1'b0);
  assign sda_rise = (sda_d == 1'b0 && sda_samp == 1'b1);
  assign scl_fall = (scl_d == 1'b1 && scl_samp == 1'b0);

  // Rising-edge detector on SCL — needed for A9 (SDA setup time check).
  logic scl_rise_a8;
  assign scl_rise_a8 = (scl_d == 1'b0 && scl_samp == 1'b1);

  //=============================================================================
  // Bit Counter for ACK and data phase assertions
  //=============================================================================
  logic start_cond_asserted;
  logic stop_cond_asserted;
  assign start_cond_asserted = (scl_samp == 1'b1 && sda_fall);
  assign stop_cond_asserted  = (scl_samp == 1'b1 && sda_rise);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bit_counter  <= 4'd0;
      in_data_phase <= 1'b0;
      in_ack_phase  <= 1'b0;
    end else begin
      if (stop_cond_asserted) begin
        // FIX: phases were never cleared at STOP, leaving A3/A4/A6 armed on
        // an idle bus between transactions.
        bit_counter   <= 4'd0;
        in_data_phase <= 1'b0;
        in_ack_phase  <= 1'b0;
      end else if (start_cond_asserted) begin
        bit_counter   <= 4'd0;
        in_data_phase <= 1'b1;
        in_ack_phase  <= 1'b0;
      end else if (in_data_phase && scl_fall) begin
        bit_counter <= bit_counter + 1'b1;
        if (bit_counter == 4'd7) begin
          in_data_phase <= 1'b0;
          in_ack_phase  <= 1'b1;
        end
      end else if (in_ack_phase && scl_fall) begin
        in_ack_phase  <= 1'b0;
        in_data_phase <= 1'b1;
        bit_counter   <= 4'd0;
      end
    end
  end



  //=============================================================================
  // A1: After START condition, SCL must go LOW within a bounded window.
  // FIX BUG #11: Previous version was a tautology — antecedent included
  // scl_samp==1'b1 and the consequent re-checked it, so it always passed.
  // New version: after START (SDA falls while SCL high), the master must
  // lower SCL within T_HD_STA+T_SCL_PERIOD cycles to begin clocking data.
  // This catches invalid START conditions where SCL never falls.
  //=============================================================================
  property p_start_cond;
    @(posedge clk)
    disable iff (!rst_n)
    (scl_samp == 1'b1 && sda_fall) |-> ##[1:(T_HD_STA + T_SCL_PERIOD)] (scl_samp == 1'b0);
  endproperty

  assert_start: assert property (p_start_cond)
    else sva_fail("I2C-SVA-A1",
                  $sformatf("SCL did not fall after START within %0d cycles at time %t",
                            T_HD_STA + T_SCL_PERIOD, $time));

  //=============================================================================
  // A2: REMOVED (post-audit).
  // The old A2 used ##[1:T_BUF] — an EXISTENTIAL delay satisfied if the bus
  // was high at ANY single cycle in the window, i.e. near-vacuous. A7 below
  // checks the bus stays free for the WHOLE T_BUF window, which is the real
  // UM10204 requirement; A2 added nothing on top of it.
  //=============================================================================

  //=============================================================================
  // A3: SDA stable during SCL high (Data Validity Window)
  // FIX: Now covers BOTH data phase AND ack phase (not just data_phase).
  // SDA must remain stable while SCL is HIGH, except during START or STOP.
  //=============================================================================
  property p_sda_stable_scl_high;
    @(posedge clk)
    disable iff (!rst_n)
    ((in_data_phase || in_ack_phase) && scl_samp == 1'b1 && !start_cond_asserted && !stop_cond_asserted) |-> $stable(sda_samp);
  endproperty

  assert_sda_stable: assert property (p_sda_stable_scl_high)
    else sva_fail("I2C-SVA-A3", $sformatf("SDA changed while SCL high at time %t", $time));

  //=============================================================================
  // A4: ACK/NACK bit is driven by receiver during 9th clock cycle
  // SDA must not be floating/Z during the ACK phase.
  //=============================================================================
  property p_ack_driven;
    @(posedge clk)
    disable iff (!rst_n)
    (in_ack_phase && scl_samp == 1'b1) |->
    (!$isunknown(sda_samp));
  endproperty

  assert_ack_driven: assert property (p_ack_driven)
    else sva_fail("I2C-SVA-A4", $sformatf("ACK/NACK bit is X/Z at time %t", $time));

  //=============================================================================
  // A5: Clock stretch bounded
  // FIX: Uses the counter directly instead of ##[0:N] sequence delay.
  // This avoids spawning 1000 pending threads per assertion evaluation.
  //=============================================================================
  logic [15:0] scl_low_counter;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_low_counter <= 16'd0;
    end else begin
      if (scl_samp == 1'b0) begin
        scl_low_counter <= scl_low_counter + 1'b1;
      end else begin
        scl_low_counter <= 16'd0;
      end
    end
  end

  property p_clk_stretch_bounded;
    @(posedge clk)
    disable iff (!rst_n)
    (scl_samp == 1'b0) |-> (scl_low_counter < MAX_CLK_STRETCH);
  endproperty

  assert_clk_stretch: assert property (p_clk_stretch_bounded)
    else sva_fail("I2C-SVA-A5",
                  $sformatf("Clock stretch exceeded %0d cycles at time %t", MAX_CLK_STRETCH, $time));

  //=============================================================================
  // A6: No unknown values on SDA/SCL during active bus operation
  // Replaces the redundant A7 (which was identical to A3 without phase guard).
  // This catches X/Z propagation on the bus — a sign of multi-driver conflict.
  //=============================================================================
  property p_no_unknown_bus;
    @(posedge clk)
    disable iff (!rst_n)
    (in_data_phase || in_ack_phase) |-> (!$isunknown(sda_samp) && !$isunknown(scl_samp));
  endproperty

  assert_no_unknown: assert property (p_no_unknown_bus)
    else sva_fail("I2C-SVA-A6",
                  $sformatf("X/Z detected on bus during active transfer at time %t", $time));

  //=============================================================================
  // A7: Bus must remain FREE (both lines HIGH) for the full T_BUF window after STOP.
  // Stronger version of A2: A2 only checks the bus is HIGH at some point within
  // T_BUF. A7 checks the bus stays HIGH for the WHOLE T_BUF window.
  // Catches: premature START before bus recovery, slave glitches during idle.
  //=============================================================================
  property p_bus_free_full_tbuf;
    @(posedge clk)
    disable iff (!rst_n)
    stop_cond_asserted |-> ##1 (sda_samp == 1'b1 && scl_samp == 1'b1)[*T_BUF];
  endproperty

  assert_bus_free_tbuf: assert property (p_bus_free_full_tbuf)
    else sva_fail("I2C-SVA-A7",
                  $sformatf("Bus did not remain free for full T_BUF=%0d cycles after STOP at time %t",
                            T_BUF, $time));

  //=============================================================================
  // A8: SDA Hold Time After SCL Falls (Glitch Window Check)
  // FIX (post-audit): two changes.
  //  1. ##1 added — the old version started the $stable window ON the trigger
  //     cycle, where sda_samp is structurally guaranteed stable (off-by-one
  //     that shrank the real window).
  //  2. The enforced hold is a structural minimum (2 cycles), not T_HD_DAT.
  //     UM10204 specifies t_HD;DAT min = 0; the DUT slave responds ~3 cycles
  //     after SCL falls (2-flop synchronizer + gated update), which is legal
  //     behavior that a T_HD_DAT(5)-cycle check would falsely flag on every
  //     ACK and read-data bit. 2 cycles still catches the dangerous case:
  //     SDA moving with/just after the SCL edge (START/STOP forgery, bit
  //     corruption at the sampling edge).
  //=============================================================================
  localparam int SVA_HOLD_MIN = 2;

  property p_sda_hold_after_scl_fall;
    @(posedge clk)
    disable iff (!rst_n)
    ((in_data_phase || in_ack_phase) && scl_fall && !start_cond_asserted && !stop_cond_asserted)
      |-> ##1 $stable(sda_samp)[*SVA_HOLD_MIN];
  endproperty

  assert_sda_hold: assert property (p_sda_hold_after_scl_fall)
    else sva_fail("I2C-SVA-A8",
                  $sformatf("SDA changed within the %0d-cycle hold window after SCL fall at time %t",
                            SVA_HOLD_MIN, $time));

  //=============================================================================
  // A9: SDA Setup Time Before SCL Rises (Glitch Window Check)
  // I2C spec T_SU_DAT: SDA must be stable for at least T_SU_DAT cycles BEFORE
  // SCL rises. The slave will sample sda_samp at the rising edge of SCL.
  // If SDA changes within the setup window, the slave could sample the wrong
  // value. We check: at the cycle of scl_rise, SDA must have been stable for
  // the previous T_SU_DAT cycles. T_SU_DAT = 5 in i2c_pkg.sv, so we compare
  // sda_samp against its value T_SU_DAT cycles in the past — if they match,
  // SDA has been stable across that window.
  //=============================================================================
  property p_sda_setup_before_scl_rise;
    @(posedge clk)
    disable iff (!rst_n)
    ((in_data_phase || in_ack_phase) && scl_rise_a8 && !start_cond_asserted && !stop_cond_asserted)
      |-> ($past(sda_samp, T_SU_DAT) == sda_samp);
  endproperty

  assert_sda_setup: assert property (p_sda_setup_before_scl_rise)
    else sva_fail("I2C-SVA-A9",
                  $sformatf("SDA changed within T_SU_DAT=%0d setup window before SCL rise at time %t",
                            T_SU_DAT, $time));

endmodule

`endif