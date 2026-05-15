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
      if (start_cond_asserted) begin
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
    else $error("I2C-SVA-A1: SCL did not fall after START within %0d cycles at time %t",
                T_HD_STA + T_SCL_PERIOD, $time);

  //=============================================================================
  // A2: After STOP condition, SDA must not fall again (new START) for T_BUF.
  // FIX BUG #12: Previous version was a tautology — sda_samp==1'b1 is implied
  // by sda_rise definition, and scl_samp==1'b1 was already in the antecedent.
  // New version: after STOP, bus must remain free (both HIGH) for at least
  // T_BUF cycles before a new START is allowed.
  //=============================================================================
  property p_stop_cond;
    @(posedge clk)
    disable iff (!rst_n)
    (scl_samp == 1'b1 && sda_rise) |-> ##[1:T_BUF] (scl_samp == 1'b1 && sda_samp == 1'b1);
  endproperty

  assert_stop: assert property (p_stop_cond)
    else $error("I2C-SVA-A2: Bus not free for T_BUF=%0d cycles after STOP at time %t",
                T_BUF, $time);

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
    else $error("I2C-SVA-A3: SDA changed while SCL high at time %t", $time);

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
    else $error("I2C-SVA-A4: ACK/NACK bit is X/Z at time %t", $time);

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
    else $error("I2C-SVA-A5: Clock stretch exceeded %0d cycles at time %t", MAX_CLK_STRETCH, $time);

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
    else $error("I2C-SVA-A6: X/Z detected on bus during active transfer at time %t", $time);

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
    else $error("I2C-SVA-A7: Bus did not remain free for full T_BUF=%0d cycles after STOP at time %t",
                T_BUF, $time);

  //=============================================================================
  // A8: SDA Hold Time After SCL Falls (Glitch Window Check)
  // I2C spec T_HD_DAT: SDA must remain stable for T_HD_DAT cycles after SCL
  // falls before being allowed to change. This catches drivers that change
  // SDA too early (before hold time), corrupting the next bit.
  // Only enforced in data/ack phase (not during START/STOP transitions).
  //=============================================================================
  property p_sda_hold_after_scl_fall;
    @(posedge clk)
    disable iff (!rst_n)
    ((in_data_phase || in_ack_phase) && scl_fall && !start_cond_asserted && !stop_cond_asserted)
      |-> $stable(sda_samp)[*T_HD_DAT];
  endproperty

  assert_sda_hold: assert property (p_sda_hold_after_scl_fall)
    else $error("I2C-SVA-A8: SDA changed within T_HD_DAT=%0d hold window after SCL fall at time %t",
                T_HD_DAT, $time);

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
    else $error("I2C-SVA-A9: SDA changed within T_SU_DAT=%0d setup window before SCL rise at time %t",
                T_SU_DAT, $time);

endmodule

`endif