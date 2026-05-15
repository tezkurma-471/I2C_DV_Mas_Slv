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
  assign sda_i = sda;
  assign scl_i = scl;

  // SCL Edge Detection for Sampling  
  logic scl_d, sda_d;
  logic scl_rise, scl_fall;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_d <= 1'b1;
      sda_d <= 1'b1;
    end else begin
      scl_d <= scl_i;
      sda_d <= sda_i;
    end
  end

  assign scl_rise = ( scl_i && !scl_d);
  assign scl_fall = (!scl_i &&  scl_d);

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
    STATE_STOP_1,
    STATE_STOP_2,
    STATE_REP_START_1,
    STATE_REP_START_2
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
  logic [$clog2(T_SCL_PERIOD)-1:0] timer;
  logic                           timer_clr;
  logic                           timer_expired;

  // Clock stretch detection
  logic [15:0] stretch_cnt;

  // Registered ACK sample (sampled on SCL rising edge)
  logic ack_received;

  // Transaction direction
  i2c_dir_e tx_dir;

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
  assign tx_dir      = i2c_dir_e'(reg_addr[0]);

  //---------------------------------------------------------------------------
  // Timer / Clock Divider for SCL Generation (FIXED BUG #2, #3)
  //---------------------------------------------------------------------------

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      timer     <= '0;
      timer_expired <= 1'b0;
    end else if (timer_clr) begin
      timer     <= '0;
      timer_expired <= 1'b0;
    end else begin
      if (timer == T_SCL_PERIOD - 1) begin
        timer     <= '0;
        timer_expired <= 1'b1;
      end else begin
        timer     <= timer + 1'b1;
        timer_expired <= 1'b0;
      end
    end
  end

  assign timer_clr = (state != next_state); // Reset timer on state change

  //---------------------------------------------------------------------------
  // Clock Stretch Detection (FIXED: uses stretch_cnt with timeout)
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stretch_cnt <= '0;
    end else if (scl_i == 1'b0 && state != STATE_IDLE) begin
      stretch_cnt <= stretch_cnt + 1'b1;
    end else begin
      stretch_cnt <= '0;
    end
  end

  assign timeout = (stretch_cnt >= MAX_CLK_STRETCH);

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
          if (timer < T_SCL_LOW)       scl_o <= 1'b0;    // SCL Low (data setup)
          else if (timer < T_SCL_LOW + T_SCL_HIGH) scl_o <= 1'b1; // SCL High (sample window)
          else                         scl_o <= 1'b0;
        end
        STATE_RX_BIT: begin
          if (timer < T_SCL_LOW)       scl_o <= 1'b0;    // Drive data / slave setup
          else if (timer < T_SCL_LOW + T_SCL_HIGH) scl_o <= 1'b1; // Sample window
          else                         scl_o <= 1'b0;
        end

        STATE_ACK_WAIT:     scl_o <= (timer < T_SCL_LOW) ? 1'b0 : 1'b1; // 9th bit ACK/NACK
        STATE_ACK_SEND:     scl_o <= (timer < T_SCL_LOW) ? 1'b0 : 1'b1;

        // STOP
        STATE_STOP_1:       scl_o <= 1'b0;
        STATE_STOP_2:       scl_o <= 1'b1;               // SCL High for STOP

        // Repeated START
        STATE_REP_START_1:  scl_o <= 1'b1;               // SCL High, toggle SDA
        STATE_REP_START_2:  scl_o <= 1'b0;               // SCL Low after Sr

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
        STATE_ACK_WAIT:        sda_o <= 1'b1;           // Release SDA to let slave ACK
        STATE_ACK_SEND: begin
          // FIX: Differentiate ACK vs NACK based on command
          if (current_cmd == CMD_READ_NACK)
            sda_o <= 1'b1;       // Drive NACK (HIGH) — signals last byte to slave
          else
            sda_o <= 1'b0;       // Drive ACK (LOW) — request more data from slave
        end
        STATE_STOP_1:          sda_o <= 1'b0;           // SDA is LOW before rising
        STATE_STOP_2:          sda_o <= 1'b1;           // SDA rises for STOP
        STATE_REP_START_1:     sda_o <= 1'b1;           // SDA High before falling
        STATE_REP_START_2:     sda_o <= 1'b0;           // SDA falls for Sr
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
      // Load data for transmission
      if (cpu_wr && (cpu_addr == REG_DATA)) begin
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
      done <= (state == STATE_STOP_2 && next_state == STATE_IDLE);

      // FIX: ack/nack are now sticky — they persist until a new command starts
      if (state == STATE_ACK_WAIT && timer_expired) begin
        ack       <= ack_received;
        nack      <= ~ack_received;
        // FIX: bus_error should NOT fire on NACK — NACK is a valid protocol response.
        // bus_error should only fire on timeout (actual protocol violation).
        bus_error <= 1'b0;
      end else if (state == STATE_IDLE && cmd_valid) begin
        // Clear sticky status when a new command begins
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
          if (cmd_valid) begin
            case (current_cmd)
              CMD_START:    next_state = STATE_START_1;
              CMD_WRITE:    next_state = STATE_TX_BIT;
              CMD_READ_ACK: next_state = STATE_RX_BIT;
              CMD_READ_NACK:next_state = STATE_RX_BIT;
              CMD_STOP:     next_state = STATE_STOP_1;
              CMD_REP_START:next_state = STATE_REP_START_1;
              default:      next_state = STATE_IDLE;
            endcase
          end else begin
            next_state = STATE_IDLE;
          end
        end

        //=====================================================================
        // STATE_START_1 & _2
        //=====================================================================
        STATE_START_1: next_state = timer_done ? STATE_START_2 : STATE_START_1;
        STATE_START_2: next_state = timer_done ? STATE_TX_BIT  : STATE_START_2;

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
              next_state = STATE_IDLE; // Command complete
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
          next_state = timer_done ? STATE_IDLE : STATE_ACK_SEND;
        end

        //=====================================================================
        // STATE_STOP_1 & _2
        //=====================================================================
        STATE_STOP_1: next_state = timer_done ? STATE_STOP_2 : STATE_STOP_1;
        STATE_STOP_2: next_state = timer_done ? STATE_IDLE   : STATE_STOP_2;

        //=====================================================================
        // STATE_REP_START_1 & _2
        //=====================================================================
        STATE_REP_START_1: next_state = timer_done ? STATE_REP_START_2 : STATE_REP_START_1;
        STATE_REP_START_2: next_state = timer_done ? STATE_TX_BIT      : STATE_REP_START_2;

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
  logic arb_lost_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arb_lost_reg <= 1'b0;
    end else if (state == STATE_IDLE) begin
      arb_lost_reg <= 1'b0;  // clear on idle
    end else if ((state == STATE_TX_BIT) && (sda_o == 1'b1) && (sda_i == 1'b0) && (scl_i == 1'b1)) begin
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
        STATE_IDLE:                                reg_status <= STS_IDLE;
        STATE_TX_BIT, STATE_RX_BIT, STATE_ACK_WAIT: reg_status <= STS_BUSY;
        STATE_STOP_2:                              reg_status <= STS_DONE;
        default:                                   reg_status <= reg_status;
      endcase
      // Override with STS_ARB_LOST whenever arbitration loss is asserted
      if (arb_lost_reg) reg_status <= STS_ARB_LOST;
    end
  end

  // IRQ Logic (registered)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_irq <= 1'b0;
    end else begin
      cpu_irq <= |({reg_irq_en[0] & done,
                    reg_irq_en[1] & ack,
                    reg_irq_en[2] & nack,
                    reg_irq_en[3] & timeout,
                    reg_irq_en[4] & bus_error});
    end
  end

endmodule

`endif