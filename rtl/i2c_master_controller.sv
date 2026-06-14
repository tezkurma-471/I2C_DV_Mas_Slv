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
