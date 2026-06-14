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
