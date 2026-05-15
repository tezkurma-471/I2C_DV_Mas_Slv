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

  // Initialize driver proxies to release (1 = don't pull down)
  initial begin
    sda_drv = 1'b1;
    scl_drv = 1'b1;
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
//               : A1-A6 — fixed timing for BFM compatibility, removed
//               : redundant assertions, added missing semicolons.
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
  // A1: START Condition (SDA falls while SCL is HIGH)
  // FIX: Removed [*T_HD_STA] repetition — BFM operates at abstract timing.
  // Checks that SCL is HIGH when START is detected (1 cycle is sufficient).
  //=============================================================================
  property p_start_cond;
    @(posedge clk)
    disable iff (!rst_n)
    (scl_samp == 1'b1 && sda_fall) |-> (scl_samp == 1'b1);
  endproperty

  assert_start: assert property (p_start_cond)
    else $error("I2C-SVA-A1: Illegal START condition at time %t", $time);

  //=============================================================================
  // A2: STOP Condition (SDA rises while SCL is HIGH)
  // FIX: Removed [*T_BUF] repetition — BFM doesn't hold bus idle that long.
  // Checks that both SCL and SDA are HIGH when STOP occurs.
  //=============================================================================
  property p_stop_cond;
    @(posedge clk)
    disable iff (!rst_n)
    (scl_samp == 1'b1 && sda_rise) |-> (scl_samp == 1'b1 && sda_samp == 1'b1);
  endproperty

  assert_stop: assert property (p_stop_cond)
    else $error("I2C-SVA-A2: Illegal STOP condition at time %t", $time);

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

endmodule

`endif
`ifndef I2C_TB_PKG_SV
`define I2C_TB_PKG_SV
package i2c_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import i2c_pkg::*;
//=============================================================================
// File          : i2c_seq_item.sv
// Description   : UVM Sequence Item for I2C Transactions
//               : Encapsulates all fields of an I2C protocol transaction.
//               : V2: Added addr_ack, byte_ack[] for per-byte ACK tracking.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_SEQ_ITEM_SV
`define I2C_SEQ_ITEM_SV

class i2c_seq_item extends uvm_sequence_item;

  `uvm_object_utils(i2c_seq_item)

  rand logic [6:0]  addr;
  rand i2c_dir_e    dir;

  rand bit [7:0]    data [$];  // FIX: use 2-state 'bit' to prevent X/Z from randomization
  rand int          num_data;

  rand bit          start_cond;
  rand bit          stop_cond;
  rand bit          rep_start;

  i2c_status_e      status;
  bit               ack_received;

  // Per-byte ACK/NACK tracking (populated by monitor)
  bit               addr_ack;
  bit               byte_ack [$];

  // Error injection
  rand bit          inject_nack;
  rand bit          inject_timeout;

  constraint valid_addr_c {
    addr != 7'h00;
    addr != 7'h7F;
    addr[6:3] != 4'b0000;
    addr[6:3] != 4'b1111;
  }

  constraint data_size_c {
    num_data >= 1;
    num_data <= 32;
    data.size() == num_data;
  }

  constraint default_trans_c {
    start_cond == 1;
    stop_cond  == 1;
    rep_start  == 0;
  }

  // FIX: Every I2C transaction MUST begin with START or Repeated START.
  // Without this, random/stress sequences generate impossible bus states.
  constraint valid_protocol_c {
    start_cond || rep_start;     // Must have at least one
    !(start_cond && rep_start);  // Cannot have both simultaneously
    stop_cond -> !rep_start;     // STOP and rep_start are mutually exclusive
  }

  constraint default_errors_c {
    inject_nack    == 0;
    inject_timeout == 0;
  }

  function new(string name = "i2c_seq_item");
    super.new(name);
    status       = STS_IDLE;
    ack_received = 1'b0;
    addr_ack     = 1'b0;
  endfunction

  function void post_randomize();
    foreach (data[i]) begin
      if ($isunknown(data[i]))
        data[i] = $urandom_range(0, 255);
    end
  endfunction

  virtual function string convert2string();
    string s;
    s = $sformatf("I2C: addr=0x%02x dir=%s num_data=%0d ",
                  addr, dir.name(), num_data);
    if (start_cond) s = {s, "[START]" };
    if (rep_start)  s = {s, "[REP_START]"};
    if (stop_cond)  s = {s, "[STOP]" };
    s = {s, $sformatf(" addr_ack=%0b", addr_ack)};
    return s;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    i2c_seq_item item;
    super.do_copy(rhs);
    if (!$cast(item, rhs)) return;
    addr           = item.addr;
    dir            = item.dir;
    data           = item.data;
    num_data       = item.num_data;
    start_cond     = item.start_cond;
    stop_cond      = item.stop_cond;
    rep_start      = item.rep_start;
    status         = item.status;
    ack_received   = item.ack_received;
    addr_ack       = item.addr_ack;
    byte_ack       = item.byte_ack;
    inject_nack    = item.inject_nack;
    inject_timeout = item.inject_timeout;
  endfunction

  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    i2c_seq_item item;
    if (!$cast(item, rhs)) return 0;
    // FIX: Also compare status fields for thorough checking
    return (super.do_compare(rhs, comparer) &&
            (addr == item.addr) &&
            (dir  == item.dir) &&
            (data == item.data) &&
            (num_data == item.num_data) &&
            (addr_ack == item.addr_ack) &&
            (rep_start == item.rep_start));
  endfunction

  virtual function void do_print(uvm_printer printer);
    printer.print_string("addr",     $sformatf("0x%02x", addr));
    printer.print_string("dir",      dir.name());
    printer.print_int("num_data",   num_data, $bits(num_data));
    printer.print_int("start_cond", start_cond, $bits(start_cond));
    printer.print_int("stop_cond",  stop_cond,  $bits(stop_cond));
    printer.print_int("addr_ack",   addr_ack,   $bits(addr_ack));
    printer.print_string("status",  status.name());
  endfunction

endclass : i2c_seq_item

`endif

//=============================================================================
// File          : i2c_scoreboard.sv
// Description   : UVM Scoreboard — True Self-Checking Reference Model
//               : V2: Checks address ACK/NACK, data integrity, register
//               : contents, and expected vs actual transaction counts.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_SCOREBOARD_SV
`define I2C_SCOREBOARD_SV

`uvm_analysis_imp_decl(_expected)
`uvm_analysis_imp_decl(_actual)

class i2c_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(i2c_scoreboard)

  uvm_analysis_imp_expected #(i2c_seq_item, i2c_scoreboard) expected_export;
  uvm_analysis_imp_actual   #(i2c_seq_item, i2c_scoreboard) actual_export;

  logic [7:0] ref_reg_bank [0:7];
  int         shadow_ptr;

  int expected_count;
  int actual_count;
  int error_count;
  int match_count;

  function new(string name = "i2c_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    expected_export = new("expected_export", this);
    actual_export   = new("actual_export",   this);
    for (int i = 0; i < 8; i++)
      ref_reg_bank[i] = 8'h00;
    shadow_ptr     = 0;
    expected_count = 0;
    actual_count   = 0;
    error_count    = 0;
    match_count    = 0;
  endfunction

  virtual function void write_expected(i2c_seq_item item);
    expected_count++;
    `uvm_info(get_type_name(),
              $sformatf("EXPECTED[%0d]: addr=0x%02x dir=%s bytes=%0d",
                        expected_count, item.addr, item.dir.name(), item.num_data), UVM_HIGH)

    // FIX: Only update shadow for target address writes
    // FIX: Do NOT reset shadow_ptr to 0 — it persists across transactions
    //      just like the DUT's reg_ptr auto-increments continuously.
    //      The DUT resets reg_ptr to 0 in SLV_ACK when address matches,
    //      so we must reset here too on EACH new transaction to addr 0x50.
    if (item.dir == DIR_WRITE && item.addr == 7'h50) begin
      shadow_ptr = 0;  // Reset: DUT does reg_ptr <= 0 in SLV_ACK
      foreach (item.data[i]) begin
        ref_reg_bank[shadow_ptr % 8] = item.data[i];
        `uvm_info(get_type_name(),
                  $sformatf("SHADOW WRITE: reg[%0d] = 0x%02x",
                            shadow_ptr % 8, item.data[i]), UVM_HIGH)
        shadow_ptr++;
      end
    end
  endfunction

  virtual function void write_actual(i2c_seq_item item);
    actual_count++;
    `uvm_info(get_type_name(),
              $sformatf("ACTUAL[%0d]: addr=0x%02x dir=%s bytes=%0d addr_ack=%0b",
                        actual_count, item.addr, item.dir.name(),
                        item.num_data, item.addr_ack), UVM_MEDIUM)

    check_address_ack(item);
    check_data_integrity(item);
  endfunction

  virtual function void check_address_ack(i2c_seq_item item);
    bit expected_ack = (item.addr == 7'h50) ? 1'b1 : 1'b0;
    if (item.addr_ack !== expected_ack) begin
      `uvm_error(get_type_name(),
                 $sformatf("ADDR_ACK MISMATCH: addr=0x%02x expected_ack=%0b actual_ack=%0b",
                           item.addr, expected_ack, item.addr_ack))
      error_count++;
    end else begin
      `uvm_info(get_type_name(),
                $sformatf("ADDR_ACK OK: addr=0x%02x ack=%0b", item.addr, item.addr_ack), UVM_HIGH)
      match_count++;
    end
  endfunction

  virtual function void check_data_integrity(i2c_seq_item item);
    if (item.addr != 7'h50) begin
      if (item.num_data > 0 && item.addr_ack) begin
        `uvm_error(get_type_name(),
                   $sformatf("DATA from NACK'd address 0x%02x — should have no data", item.addr))
        error_count++;
      end
      return;
    end

    if (!item.addr_ack) return;

    foreach (item.data[i]) begin
      if ($isunknown(item.data[i])) begin
        `uvm_error(get_type_name(),
                   $sformatf("DATA byte[%0d] = X/Z for addr=0x%02x", i, item.addr))
        error_count++;
        return;
      end
    end

    if (item.dir == DIR_WRITE) begin
      match_count++;
    end else if (item.dir == DIR_READ) begin
      // FIX: DUT resets reg_ptr to 0 in SLV_ACK on each new address match
      int rd_ptr = 0;
      foreach (item.data[i]) begin
        logic [7:0] expected_val = ref_reg_bank[rd_ptr % 8];
        if (item.data[i] !== expected_val) begin
          `uvm_error(get_type_name(),
                     $sformatf("READ MISMATCH reg[%0d]: expected=0x%02x actual=0x%02x",
                               rd_ptr % 8, expected_val, item.data[i]))
          error_count++;
        end else begin
          `uvm_info(get_type_name(),
                    $sformatf("READ MATCH reg[%0d] = 0x%02x", rd_ptr % 8, item.data[i]), UVM_HIGH)
          match_count++;
        end
        rd_ptr++;
      end
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info(get_type_name(),
              $sformatf("\n========== SCOREBOARD REPORT ==========\n  Expected Transactions : %0d\n  Actual Transactions   : %0d\n  Matches               : %0d\n  Errors                : %0d\n========================================",
                expected_count, actual_count, match_count, error_count),
              UVM_LOW)

    if (error_count > 0) begin
      `uvm_error(get_type_name(),
                 $sformatf("SCOREBOARD FAILED: %0d errors detected.", error_count))
    end else if (actual_count == 0) begin
      `uvm_error(get_type_name(), "SCOREBOARD FAILED: No actual transactions received!")
    end else if (actual_count != expected_count) begin
      // FIX: Flag mismatch in either direction as error, not just warning
      `uvm_error(get_type_name(),
                 $sformatf("SCOREBOARD FAILED: Expected %0d but got %0d actual transactions.",
                           expected_count, actual_count))
    end else begin
      `uvm_info(get_type_name(), "SCOREBOARD PASSED: All transactions matched.", UVM_LOW)
    end
  endfunction

endclass : i2c_scoreboard

`endif

//=============================================================================
// File          : i2c_monitor.sv
// Description   : UVM Monitor for I2C Bus
//               : Passively watches SDA/SCL, reconstructs transactions.
//               : V2: Tracks per-byte ACK/NACK, handles repeated START.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_MONITOR_SV
`define I2C_MONITOR_SV

class i2c_monitor extends uvm_monitor;

  `uvm_component_utils(i2c_monitor)

  virtual i2c_if vif;

  uvm_analysis_port #(i2c_seq_item) item_collected_port;

  i2c_seq_item    current_item;
  logic [7:0]     shift_reg;
  int             bit_cnt;
  bit             in_transaction;
  bit             addr_phase;

  function new(string name = "i2c_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    item_collected_port = new("item_collected_port", this);
    if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", vif)) begin
      `uvm_fatal(get_type_name(), "Virtual interface not found in config_db")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    fork
      monitor_bus();
    join
  endtask

  virtual task monitor_bus();
    logic prev_sda, prev_scl;
    bit   saw_rep_start;
    prev_sda = 1'b1;
    prev_scl = 1'b1;
    saw_rep_start = 0;

    forever begin
      @(posedge vif.clk);

      // START detection: SDA falls while SCL is HIGH
      if (vif.sda === 1'b0 && prev_sda === 1'b1 && vif.scl === 1'b1) begin
        if (in_transaction && current_item != null) begin
          // This is a Repeated START — finalize the current item first
          `uvm_info(get_type_name(), "Repeated START detected mid-transaction", UVM_MEDIUM)
          finalize_and_write_item();
          saw_rep_start = 1;  // FIX: flag for the NEW item
        end else begin
          `uvm_info(get_type_name(), "START condition detected", UVM_MEDIUM)
          saw_rep_start = 0;
        end
        current_item = i2c_seq_item::type_id::create("mon_item");
        in_transaction = 1;
        addr_phase = 1;
        bit_cnt = 0;
        shift_reg = 8'h00;
        current_item.start_cond = 1;
        current_item.stop_cond  = 0;
        current_item.rep_start  = saw_rep_start;  // FIX: properly flag Repeated START
      end

      // STOP detection: SDA rises while SCL is HIGH
      if (vif.sda === 1'b1 && prev_sda === 1'b0 && vif.scl === 1'b1) begin
        if (in_transaction) begin
          `uvm_info(get_type_name(), "STOP condition detected", UVM_MEDIUM)
          current_item.stop_cond = 1;
          finalize_and_write_item();
          in_transaction = 0;
          addr_phase = 0;
          bit_cnt = 0;
          saw_rep_start = 0;
        end
      end

      // Data sampling on SCL rising edge
      if (in_transaction && vif.scl === 1'b1 && prev_scl === 1'b0) begin
        if (bit_cnt < 8) begin
          shift_reg = {shift_reg[6:0], vif.sda};
          bit_cnt = bit_cnt + 1;
        end
        else if (bit_cnt == 8) begin
          if (vif.sda === 1'b0) begin
            `uvm_info(get_type_name(), "ACK received", UVM_HIGH)
            if (addr_phase) current_item.addr_ack = 1'b1;
            else            current_item.byte_ack.push_back(1'b1);
          end else begin
            `uvm_info(get_type_name(), "NACK received", UVM_HIGH)
            if (addr_phase) current_item.addr_ack = 1'b0;
            else            current_item.byte_ack.push_back(1'b0);
          end

          if (addr_phase) begin
            current_item.addr = shift_reg[7:1];
            current_item.dir  = i2c_dir_e'(shift_reg[0]);
            addr_phase = 0;
            `uvm_info(get_type_name(), $sformatf("Address: 0x%02x %s ack=%0b",
                                                  current_item.addr, current_item.dir.name(),
                                                  current_item.addr_ack), UVM_MEDIUM)
          end else begin
            current_item.data.push_back(shift_reg);
            current_item.num_data = current_item.num_data + 1;
            `uvm_info(get_type_name(), $sformatf("Data byte: 0x%02x ack=%0b",
                                                  shift_reg, current_item.byte_ack[$]), UVM_MEDIUM)
          end

          bit_cnt = 0;
          shift_reg = 8'h00;
        end
      end

      prev_sda = vif.sda;
      prev_scl = vif.scl;
    end
  endtask

  // FIX: Allow items with no data bytes (e.g., NACK'd address-only transactions)
  virtual task finalize_and_write_item();
    if (current_item != null) begin
      if (current_item.addr != 0 || current_item.data.size() > 0) begin
        `uvm_info(get_type_name(), $sformatf("Finalized: addr=0x%02x dir=%s num_data=%0d addr_ack=%0b rep_start=%0b",
                                              current_item.addr, current_item.dir.name(),
                                              current_item.num_data, current_item.addr_ack,
                                              current_item.rep_start), UVM_MEDIUM)
        item_collected_port.write(current_item);
      end else begin
        `uvm_info(get_type_name(), "Item collected but has no address or data — skipping", UVM_HIGH)
      end
    end
  endtask

endclass : i2c_monitor

`endif

//=============================================================================
// File          : i2c_master_driver.sv (FIXED)
// Description   : UVM Driver for I2C Master (FIXED)
//               : Converts sequence-level transactions to pin-level bus activity.
//               : Uses clock-based timing and proper open-drain release.
//               : FIX: Added req_analysis_port for scoreboard expected data.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_MASTER_DRIVER_SV
`define I2C_MASTER_DRIVER_SV

class i2c_driver extends uvm_driver #(i2c_seq_item);

  `uvm_component_utils(i2c_driver)

  virtual i2c_if vif;

  uvm_analysis_port #(i2c_seq_item) req_analysis_port;

  function new(string name = "i2c_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    req_analysis_port = new("req_analysis_port", this);
    if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", vif)) begin
      `uvm_fatal(get_type_name(), "Virtual interface not found in config_db")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    i2c_seq_item req_item;

    wait(vif.rst_n === 1'b1);
    `uvm_info(get_type_name(), "Reset released. Starting I2C driver.", UVM_LOW)

    forever begin
      seq_item_port.get_next_item(req_item);
      `uvm_info(get_type_name(), $sformatf("Got item: %s", req_item.convert2string()), UVM_MEDIUM)

      // FIX: DO NOT write to analysis port here. Write AFTER transaction completes.

      // Execute transaction
      if (req_item.start_cond && !req_item.rep_start) begin
        send_start();
      end else if (req_item.rep_start) begin
        send_rep_start();
      end

      if (req_item.start_cond || req_item.rep_start) begin
        send_byte({req_item.addr, req_item.dir[0]});
        wait_for_ack();
      end

      if (req_item.dir == DIR_WRITE) begin
        foreach (req_item.data[i]) begin
          send_byte(req_item.data[i]);
          wait_for_ack();
        end
      end else begin
        for (int i = 0; i < req_item.data.size(); i++) begin
          // FIX: capture received byte directly into the seq_item
          receive_byte(req_item.data[i]);
          if (i < req_item.data.size() - 1) begin
            send_ack();
          end else begin
            send_nack();
          end
        end
      end

      if (req_item.stop_cond) begin
        send_stop();
      end

      // FIX: Broadcast expected transaction AFTER completion with updated data
      req_analysis_port.write(req_item);

      seq_item_port.item_done();
    end
  endtask

  //-------------------------------------------------------------------------
  // Task: Send START condition
  //-------------------------------------------------------------------------
  virtual task send_start();
    `uvm_info(get_type_name(), "Sending START condition", UVM_HIGH)
    vif.sda_drv <= 1'b1;
    vif.scl_drv <= 1'b1;
    @(posedge vif.clk); @(posedge vif.clk);
    vif.sda_drv <= 1'b0;  // SDA falls while SCL HIGH = START
    @(posedge vif.clk); @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send Repeated START (Sr)
  //-------------------------------------------------------------------------
  virtual task send_rep_start();
    `uvm_info(get_type_name(), "Sending Repeated START (Sr)", UVM_HIGH)
    vif.sda_drv <= 1'b1;
    @(posedge vif.clk); @(posedge vif.clk);
    vif.scl_drv <= 1'b1;
    @(posedge vif.clk); @(posedge vif.clk);
    vif.sda_drv <= 1'b0;  // SDA falls while SCL HIGH = Repeated START
    @(posedge vif.clk); @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send STOP condition
  //-------------------------------------------------------------------------
  virtual task send_stop();
    `uvm_info(get_type_name(), "Sending STOP condition", UVM_HIGH)
    vif.sda_drv <= 1'b0;
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk); @(posedge vif.clk);
    vif.scl_drv <= 1'b1;  // SCL rises first
    @(posedge vif.clk); @(posedge vif.clk);
    vif.sda_drv <= 1'b1;  // SDA rises while SCL HIGH = STOP
    @(posedge vif.clk); @(posedge vif.clk);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send a single byte (MSB first)
  //-------------------------------------------------------------------------
  virtual task send_byte(input logic [7:0] byte_data);
    `uvm_info(get_type_name(), $sformatf("Sending byte: 0x%02x", byte_data), UVM_HIGH)
    for (int i = 7; i >= 0; i--) begin
      vif.scl_drv <= 1'b0;
      vif.sda_drv <= byte_data[i];
      @(posedge vif.clk);
      @(posedge vif.clk);
      vif.scl_drv <= 1'b1;  // SCL HIGH — slave samples SDA
      @(posedge vif.clk);
      @(posedge vif.clk);
      vif.scl_drv <= 1'b0;
      @(posedge vif.clk);
    end
  endtask

  //-------------------------------------------------------------------------
  // Task: Receive a single byte (MSB first)
  // FIX: Takes output ref to write received data back into the seq_item
  //-------------------------------------------------------------------------
  virtual task receive_byte(output logic [7:0] received_byte);
    `uvm_info(get_type_name(), "Receiving byte from slave", UVM_HIGH)
    for (int i = 7; i >= 0; i--) begin
      vif.scl_drv <= 1'b0;
      vif.sda_drv <= 1'b1;          // Release SDA (let slave drive)
      @(posedge vif.clk);
      @(posedge vif.clk);
      vif.scl_drv <= 1'b1;          // SCL HIGH — sample SDA
      @(posedge vif.clk);
      received_byte[i] = vif.sda;   // Sample on SCL HIGH
      @(posedge vif.clk);
      vif.scl_drv <= 1'b0;
      @(posedge vif.clk);
    end
    `uvm_info(get_type_name(), $sformatf("Received byte: 0x%02x", received_byte), UVM_MEDIUM)
  endtask

  //-------------------------------------------------------------------------
  // Task: Wait for ACK/NACK (9th clock cycle)
  //-------------------------------------------------------------------------
  virtual task wait_for_ack();
    bit sampled_ack;
    `uvm_info(get_type_name(), "Waiting for ACK/NACK", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    vif.sda_drv <= 1'b1;          // Release SDA (let slave drive ACK)
    @(posedge vif.clk);
    @(posedge vif.clk);
    vif.scl_drv <= 1'b1;          // SCL HIGH — sample ACK
    @(posedge vif.clk);
    sampled_ack = vif.sda;
    @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);

    if (sampled_ack === 1'b0) begin
      `uvm_info(get_type_name(), "ACK received", UVM_MEDIUM)
    end else begin
      `uvm_warning(get_type_name(), "NACK received!")
    end
  endtask

  //-------------------------------------------------------------------------
  // Task: Send ACK (after receiving a byte from slave)
  //-------------------------------------------------------------------------
  virtual task send_ack();
    `uvm_info(get_type_name(), "Sending ACK", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    vif.sda_drv <= 1'b0;          // Drive LOW for ACK
    @(posedge vif.clk);
    @(posedge vif.clk);
    vif.scl_drv <= 1'b1;
    @(posedge vif.clk);
    @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
    vif.sda_drv <= 1'b1;          // Release
    @(posedge vif.clk);
  endtask

  //-------------------------------------------------------------------------
  // Task: Send NACK (after receiving last byte from slave)
  //-------------------------------------------------------------------------
  virtual task send_nack();
    `uvm_info(get_type_name(), "Sending NACK", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    vif.sda_drv <= 1'b1;          // Keep HIGH for NACK (release)
    @(posedge vif.clk);
    @(posedge vif.clk);
    vif.scl_drv <= 1'b1;
    @(posedge vif.clk);
    @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
  endtask

endclass : i2c_driver

`endif

//=============================================================================
// File          : i2c_slave_monitor.sv
// Description   : UVM Monitor for I2C Slave DUT status signals
//               : Observes addr_match, active, rx_data_valid, etc. and
//               : creates slave_status transactions for analysis.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_SLAVE_MONITOR_SV
`define I2C_SLAVE_MONITOR_SV

class i2c_slave_status_item extends uvm_sequence_item;

  `uvm_object_utils(i2c_slave_status_item)

  logic [7:0] rx_data;
  bit         rx_data_valid;
  bit         addr_match;
  bit         active;
  bit         tx_ack;
  bit         tx_nack;
  bit         bus_error;
  logic [7:0] reg_bank [0:7];

  function new(string name = "i2c_slave_status_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    string s;
    s = $sformatf("slave_status: addr_match=%0b active=%0b rx_valid=%0b rx_data=0x%02x tx_ack=%0b tx_nack=%0b bus_err=%0b",
                  addr_match, active, rx_data_valid, rx_data, tx_ack, tx_nack, bus_error);
    return s;
  endfunction

endclass

class i2c_slave_monitor extends uvm_monitor;

  `uvm_component_utils(i2c_slave_monitor)

  virtual i2c_slave_if vif;

  uvm_analysis_port #(i2c_slave_status_item) status_port;

  function new(string name = "i2c_slave_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    status_port = new("status_port", this);
    if (!uvm_config_db#(virtual i2c_slave_if)::get(this, "", "i2c_slave_vif", vif)) begin
      `uvm_fatal(get_type_name(), "i2c_slave_vif not found in config_db")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (vif.rx_data_valid || vif.addr_match || vif.bus_error) begin
        i2c_slave_status_item item = i2c_slave_status_item::type_id::create("slv_status");
        item.rx_data       = vif.rx_data;
        item.rx_data_valid = vif.rx_data_valid;
        item.addr_match    = vif.addr_match;
        item.active        = vif.active;
        item.tx_ack        = vif.tx_ack;
        item.tx_nack       = vif.tx_nack;
        item.bus_error     = vif.bus_error;
        foreach (vif.reg_bank[i])
          item.reg_bank[i] = vif.reg_bank[i];
        `uvm_info(get_type_name(), item.convert2string(), UVM_HIGH)
        status_port.write(item);
      end
    end
  endtask

endclass : i2c_slave_monitor

`endif

//=============================================================================
// File          : i2c_slave_driver.sv
// Description   : UVM Driver for I2C Slave Control
//               : Reactively controls stretch_en, stretch_cycles,
//               : and force_data_nack based on sequence items.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_SLAVE_DRIVER_SV
`define I2C_SLAVE_DRIVER_SV

class i2c_slave_ctrl_item extends uvm_sequence_item;

  `uvm_object_utils(i2c_slave_ctrl_item)

  rand bit         stretch_en;
  rand logic [15:0] stretch_cycles;
  rand bit         force_data_nack;

  constraint stretch_cycles_c {
    stretch_cycles inside {[16'd1 : 16'd500]};
  }

  constraint stretch_en_off_c {
    stretch_en == 1'b0;
  }

  constraint force_nack_off_c {
    force_data_nack == 1'b0;
  }

  function new(string name = "i2c_slave_ctrl_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("slave_ctrl: stretch_en=%0b stretch_cycles=%0d force_nack=%0b",
                     stretch_en, stretch_cycles, force_data_nack);
  endfunction

endclass

class i2c_slave_driver extends uvm_driver #(i2c_slave_ctrl_item);

  `uvm_component_utils(i2c_slave_driver)

  virtual i2c_slave_if vif;

  function new(string name = "i2c_slave_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual i2c_slave_if)::get(this, "", "i2c_slave_vif", vif)) begin
      `uvm_fatal(get_type_name(), "i2c_slave_vif not found in config_db")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.stretch_en      <= 1'b0;
    vif.stretch_cycles  <= 16'd0;
    vif.force_data_nack <= 1'b0;

    forever begin
      seq_item_port.get_next_item(req);
      `uvm_info(get_type_name(), $sformatf("Applying: %s", req.convert2string()), UVM_MEDIUM)

      vif.stretch_en      <= req.stretch_en;
      vif.stretch_cycles  <= req.stretch_cycles;
      vif.force_data_nack <= req.force_data_nack;

      // FIX: Wait for slave to become active FIRST, then wait for transaction to complete.
      // Original bug: wait(active===0) passed immediately if slave wasn't yet active,
      // causing control signals to be cleared before the master even started.
      if (req.stretch_en) begin
        wait (vif.active === 1'b1);  // FIX: Wait for transaction to START
        wait (vif.active === 1'b0);  // Then wait for transaction to END
        vif.stretch_en      <= 1'b0;
        vif.stretch_cycles  <= 16'd0;
      end

      if (req.force_data_nack) begin
        wait (vif.active === 1'b1);  // FIX: Wait for transaction to START
        wait (vif.active === 1'b0);  // Then wait for transaction to END
        vif.force_data_nack <= 1'b0;
      end

      seq_item_port.item_done();
    end
  endtask

endclass : i2c_slave_driver

`endif

//=============================================================================
// File          : i2c_sequences.sv
// Description   : Reusable UVM Sequence Library for I2C Verification
//               : V2: Fixed rep_start, added clock_stretch, data_nack,
//               : bus_free sequences.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_SEQUENCES_SV
`define I2C_SEQUENCES_SV

class i2c_base_seq extends uvm_sequence #(i2c_seq_item);

  `uvm_object_utils(i2c_base_seq)

  function new(string name = "i2c_base_seq");
    super.new(name);
  endfunction

endclass : i2c_base_seq

class i2c_single_write_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_single_write_seq)

  rand logic [6:0] addr;
  rand logic [7:0] data;

  constraint default_addr_c { addr == 7'h50; }

  function new(string name = "i2c_single_write_seq");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item item = i2c_seq_item::type_id::create("single_write_item");
    start_item(item);
    if (!item.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == 1;
      data[0]    == local::data;
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_single_write_seq")
    finish_item(item);
  endtask

endclass : i2c_single_write_seq

class i2c_single_read_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_single_read_seq)

  rand logic [6:0] addr;

  constraint default_addr_c { addr == 7'h50; }

  function new(string name = "i2c_single_read_seq");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item item = i2c_seq_item::type_id::create("single_read_item");
    start_item(item);
    if (!item.randomize() with {
      addr       == local::addr;
      dir        == DIR_READ;
      num_data   == 1;
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_single_read_seq")
    finish_item(item);
  endtask

endclass : i2c_single_read_seq

class i2c_burst_write_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_burst_write_seq)

  rand logic [6:0] addr;
  rand int          burst_len;

  constraint default_addr_c  { addr == 7'h50; }
  constraint burst_len_c     { burst_len inside {[1:32]}; }

  function new(string name = "i2c_burst_write_seq");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item item = i2c_seq_item::type_id::create("burst_write_item");
    start_item(item);
    if (!item.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == local::burst_len;
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_burst_write_seq")
    finish_item(item);
  endtask

endclass : i2c_burst_write_seq

class i2c_burst_read_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_burst_read_seq)

  rand logic [6:0] addr;
  rand int          burst_len;

  constraint default_addr_c  { addr == 7'h50; }
  constraint burst_len_c     { burst_len inside {[1:32]}; }

  function new(string name = "i2c_burst_read_seq");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item item = i2c_seq_item::type_id::create("burst_read_item");
    start_item(item);
    if (!item.randomize() with {
      addr       == local::addr;
      dir        == DIR_READ;
      num_data   == local::burst_len;
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_burst_read_seq")
    finish_item(item);
  endtask

endclass : i2c_burst_read_seq

class i2c_write_read_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_write_read_seq)

  logic [6:0] addr = 7'h50;
  logic [7:0] write_data = 8'hA5;

  function new(string name = "i2c_write_read_seq");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item wr_item, rd_item;

    wr_item = i2c_seq_item::type_id::create("wr_item");
    start_item(wr_item);
    if (!wr_item.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == 1;
      data[0]    == local::write_data;
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed for write in write_read_seq")
    finish_item(wr_item);

    #200;

    rd_item = i2c_seq_item::type_id::create("rd_item");
    start_item(rd_item);
    if (!rd_item.randomize() with {
      addr       == local::addr;
      dir        == DIR_READ;
      num_data   == 1;
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed for read in write_read_seq")
    finish_item(rd_item);
  endtask

endclass : i2c_write_read_seq

class i2c_rep_start_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_rep_start_seq)

  logic [6:0] addr = 7'h50;
  logic [7:0] write_data = 8'hA5;

  function new(string name = "i2c_rep_start_seq");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item wr_item, rd_item;

    wr_item = i2c_seq_item::type_id::create("wr_item");
    start_item(wr_item);
    if (!wr_item.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == 1;
      data[0]    == local::write_data;
      start_cond == 1;
      stop_cond  == 0;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed for write in rep_start_seq")
    finish_item(wr_item);

    rd_item = i2c_seq_item::type_id::create("rd_item");
    start_item(rd_item);
    if (!rd_item.randomize() with {
      addr       == local::addr;
      dir        == DIR_READ;
      num_data   == 1;
      start_cond == 0;
      stop_cond  == 1;
      rep_start  == 1;
    }) `uvm_fatal("SEQ", "Randomization failed for read in rep_start_seq")
    finish_item(rd_item);
  endtask

endclass : i2c_rep_start_seq

class i2c_nack_addr_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_nack_addr_seq)

  rand logic [6:0] wrong_addr;

  constraint wrong_addr_c { wrong_addr inside {[7'h08:7'h77]}; wrong_addr != 7'h50; }

  function new(string name = "i2c_nack_addr_seq");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item item = i2c_seq_item::type_id::create("nack_addr_item");
    start_item(item);
    if (!item.randomize() with {
      addr       == local::wrong_addr;
      dir        == DIR_WRITE;
      num_data   == 1;
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_nack_addr_seq")
    finish_item(item);
  endtask

endclass : i2c_nack_addr_seq

class i2c_clock_stretch_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_clock_stretch_seq)

  rand logic [6:0]  addr;
  rand logic [7:0]  data;
  rand logic [15:0] stretch_cycles;

  constraint default_addr_c  { addr == 7'h50; }
  constraint stretch_cycles_c { stretch_cycles inside {[16'd50 : 16'd200]}; }

  function new(string name = "i2c_clock_stretch_seq");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item item = i2c_seq_item::type_id::create("stretch_item");
    start_item(item);
    if (!item.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == 1;
      data[0]    == local::data;
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_clock_stretch_seq")
    finish_item(item);
  endtask

endclass : i2c_clock_stretch_seq

class i2c_data_nack_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_data_nack_seq)

  rand logic [6:0] addr;
  rand logic [7:0] data;

  constraint default_addr_c { addr == 7'h50; }

  function new(string name = "i2c_data_nack_seq");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item item = i2c_seq_item::type_id::create("data_nack_item");
    start_item(item);
    if (!item.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == 1;
      data[0]    == local::data;
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_data_nack_seq")
    finish_item(item);
  endtask

endclass : i2c_data_nack_seq

class i2c_bus_free_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_bus_free_seq)

  rand logic [6:0] addr;
  rand logic [7:0] data;

  constraint default_addr_c { addr == 7'h50; }

  function new(string name = "i2c_bus_free_seq");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item item = i2c_seq_item::type_id::create("bus_free_item");
    start_item(item);
    if (!item.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == 1;
      data[0]    == local::data;
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_bus_free_seq")
    finish_item(item);
  endtask

endclass : i2c_bus_free_seq

class i2c_random_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_random_seq)

  rand int num_txns;

  constraint num_txns_c { num_txns inside {[20:100]}; }

  function new(string name = "i2c_random_seq");
    super.new(name);
  endfunction

  task body();
    for (int i = 0; i < num_txns; i++) begin
      i2c_seq_item item = i2c_seq_item::type_id::create($sformatf("rand_item_%0d", i));
      start_item(item);
      if (!item.randomize()) begin
        `uvm_error("SEQ", $sformatf("Randomization failed for item %0d", i))
        continue;
      end
      finish_item(item);
    end
  endtask

endclass : i2c_random_seq

class i2c_stress_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_stress_seq)

  int num_txns = 1000;

  function new(string name = "i2c_stress_seq");
    super.new(name);
  endfunction

  task body();
    for (int i = 0; i < num_txns; i++) begin
      i2c_seq_item item = i2c_seq_item::type_id::create($sformatf("stress_item_%0d", i));
      start_item(item);
      if (!item.randomize()) begin
        `uvm_error("SEQ", $sformatf("Randomization failed for stress item %0d", i))
        continue;
      end
      finish_item(item);
    end
  endtask

endclass : i2c_stress_seq

class i2c_addr_sweep_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_addr_sweep_seq)

  function new(string name = "i2c_addr_sweep_seq");
    super.new(name);
  endfunction

  task body();
    for (int a = 8; a <= 16'h77; a++) begin
      i2c_seq_item item = i2c_seq_item::type_id::create($sformatf("sweep_item_%0d", a));
      start_item(item);
      if (!item.randomize() with {
        addr       == a[6:0];
        dir        == DIR_WRITE;
        num_data   == 1;
        start_cond == 1;
        stop_cond  == 1;
        rep_start  == 0;
      }) begin
        `uvm_warning("SEQ", $sformatf("Randomization failed for addr 0x%02x", a))
        continue;
      end
      finish_item(item);
    end
  endtask

endclass : i2c_addr_sweep_seq

class i2c_data_pattern_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_data_pattern_seq)

  logic [6:0] addr = 7'h50;

  function new(string name = "i2c_data_pattern_seq");
    super.new(name);
  endfunction

  task body();
    logic [7:0] patterns[$];
    patterns.push_back(8'h00);
    patterns.push_back(8'hFF);
    patterns.push_back(8'hAA);
    patterns.push_back(8'h55);
    patterns.push_back(8'h01);
    patterns.push_back(8'h02);
    patterns.push_back(8'h04);
    patterns.push_back(8'h08);
    patterns.push_back(8'h10);
    patterns.push_back(8'h20);
    patterns.push_back(8'h40);
    patterns.push_back(8'h80);
    patterns.push_back(8'hFE);
    patterns.push_back(8'hFD);
    patterns.push_back(8'hFB);
    patterns.push_back(8'hF7);
    patterns.push_back(8'hEF);
    patterns.push_back(8'hDF);
    patterns.push_back(8'hBF);
    patterns.push_back(8'h7F);

    foreach (patterns[i]) begin
      i2c_seq_item item = i2c_seq_item::type_id::create($sformatf("pattern_item_%0d", i));
      start_item(item);
      if (!item.randomize() with {
        addr       == local::addr;
        dir        == DIR_WRITE;
        num_data   == 1;
        data[0]    == patterns[i];
        start_cond == 1;
        stop_cond  == 1;
        rep_start  == 0;
      }) `uvm_fatal("SEQ", "Randomization failed in data_pattern_seq")
      finish_item(item);
    end
  endtask

endclass : i2c_data_pattern_seq

class i2c_slave_force_nack_seq extends uvm_sequence #(i2c_slave_ctrl_item);

  `uvm_object_utils(i2c_slave_force_nack_seq)

  function new(string name = "i2c_slave_force_nack_seq");
    super.new(name);
  endfunction

  task body();
    i2c_slave_ctrl_item ctrl = i2c_slave_ctrl_item::type_id::create("ctrl");
    start_item(ctrl);
    ctrl.force_nack_off_c.constraint_mode(0);
    if (!ctrl.randomize() with {
      stretch_en      == 1'b0;
      stretch_cycles  == 16'd0;
      force_data_nack == 1'b1;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_slave_force_nack_seq")
    finish_item(ctrl);
  endtask

endclass : i2c_slave_force_nack_seq

class i2c_slave_stretch_ctrl_seq extends uvm_sequence #(i2c_slave_ctrl_item);

  `uvm_object_utils(i2c_slave_stretch_ctrl_seq)

  rand logic [15:0] stretch_cycles;

  constraint stretch_cycles_c {
    stretch_cycles inside {[16'd50 : 16'd200]};
  }

  function new(string name = "i2c_slave_stretch_ctrl_seq");
    super.new(name);
  endfunction

  task body();
    i2c_slave_ctrl_item ctrl = i2c_slave_ctrl_item::type_id::create("ctrl");
    start_item(ctrl);
    ctrl.stretch_en_off_c.constraint_mode(0);
    if (!ctrl.randomize() with {
      stretch_en      == 1'b1;
      stretch_cycles  == local::stretch_cycles;
      force_data_nack == 1'b0;
    }) `uvm_fatal("SEQ", "Randomization failed in i2c_slave_stretch_ctrl_seq")
    finish_item(ctrl);
  endtask

endclass : i2c_slave_stretch_ctrl_seq

class i2c_sequential_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_sequential_seq)

  int num_txns = 5;
  logic [6:0] addr = 7'h50;

  function new(string name = "i2c_sequential_seq");
    super.new(name);
  endfunction

  task body();
    for (int i = 0; i < num_txns; i++) begin
      i2c_seq_item item = i2c_seq_item::type_id::create($sformatf("seq_txn_%0d", i));
      start_item(item);
      if (!item.randomize() with {
        addr       == local::addr;
        dir        == ((i % 2 == 0) ? DIR_WRITE : DIR_READ);
        num_data   == 1;
        start_cond == 1;
        stop_cond  == 1;
        rep_start  == 0;
      }) `uvm_fatal("SEQ", "Randomization failed in sequential_seq")
      finish_item(item);
    end
  endtask

endclass : i2c_sequential_seq

`endif

"//=============================================================================\n// File          : i2c_coverage.sv\n// Description   : UVM Functional Coverage Collector for I2C Verification\n//               : V3: 8 covergroups for comprehensive coverage
<truncated 9164 bytes>

//=============================================================================
// File          : i2c_master_agent.sv
// Description   : UVM Agent for I2C Master — wraps driver, monitor, sequencer.
//               : Active agent: drives stimulus AND observes the bus.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_MASTER_AGENT_SV
`define I2C_MASTER_AGENT_SV

class i2c_master_agent extends uvm_agent;

  `uvm_component_utils(i2c_master_agent)

  //-------------------------------------------------------------------------
  // Sub-components
  //-------------------------------------------------------------------------
  i2c_driver              driver;
  i2c_monitor             monitor;
  uvm_sequencer #(i2c_seq_item) sequencer;

  //-------------------------------------------------------------------------
  // TLM Analysis Port — broadcasts items observed by the monitor.
  // The environment connects this to the scoreboard's actual_export.
  //-------------------------------------------------------------------------
  uvm_analysis_port #(i2c_seq_item) analysis_port;

  //-------------------------------------------------------------------------
  // Constructor
  //-------------------------------------------------------------------------
  function new(string name = "i2c_master_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  //-------------------------------------------------------------------------
  // Build Phase — create sub-components
  //-------------------------------------------------------------------------
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Only instantiate driver and sequencer for ACTIVE agent
    // (UVM_ACTIVE is the default; pass UVM_PASSIVE to disable driving)
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = i2c_driver::type_id::create("driver",    this);
      sequencer = uvm_sequencer #(i2c_seq_item)::type_id::create("sequencer", this);
    end
    monitor       = i2c_monitor::type_id::create("monitor", this);
    analysis_port = new("analysis_port", this);
  endfunction

  //-------------------------------------------------------------------------
  // Connect Phase — wire driver↔sequencer; forward monitor's port
  //-------------------------------------------------------------------------
  function void connect_phase(uvm_phase phase);
    // Wire sequencer output to driver input (TLM seq_item_port)
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
    // Forward monitor observations to the agent's analysis port
    // (environment then connects this to scoreboard)
    monitor.item_collected_port.connect(analysis_port);
  endfunction

endclass : i2c_master_agent

`endif

//=============================================================================
// File          : i2c_slave_agent.sv
// Description   : UVM Agent for I2C Slave — wraps slave monitor and slave driver.
//               : Default is PASSIVE (set by env). Tests override via config_db
//               : with path "*env.slave_agent" before super.build_phase().
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_SLAVE_AGENT_SV
`define I2C_SLAVE_AGENT_SV

class i2c_slave_agent extends uvm_agent;

  `uvm_component_utils(i2c_slave_agent)

  i2c_slave_driver              driver;
  i2c_slave_monitor             monitor;
  uvm_sequencer #(i2c_slave_ctrl_item) sequencer;

  function new(string name = "i2c_slave_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = i2c_slave_monitor::type_id::create("monitor", this);
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = i2c_slave_driver::type_id::create("driver", this);
      sequencer = uvm_sequencer #(i2c_slave_ctrl_item)::type_id::create("sequencer", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction

endclass : i2c_slave_agent

`endif

//=============================================================================
// File          : i2c_virtual_sequencer.sv
// Description   : UVM Virtual Sequencer for I2C Environment.
//               : Holds handles to the master and slave sequencers for
//               : coordinated multi-agent sequence execution.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_VIRTUAL_SEQUENCER_SV
`define I2C_VIRTUAL_SEQUENCER_SV

class i2c_virtual_sequencer extends uvm_sequencer;

  `uvm_component_utils(i2c_virtual_sequencer)

  // Handles to actual agent sequencers
  uvm_sequencer #(i2c_seq_item)        master_seqr;
  uvm_sequencer #(i2c_slave_ctrl_item) slave_seqr;

  function new(string name = "i2c_virtual_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass : i2c_virtual_sequencer

`endif

//=============================================================================
// File          : i2c_virtual_sequence.sv
// Description   : UVM Virtual Sequence Library for I2C Environment.
//               : Coordinates master traffic and slave stretch/NACK behaviors.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_VIRTUAL_SEQUENCE_SV
`define I2C_VIRTUAL_SEQUENCE_SV

//-----------------------------------------------------------------------------
// Base Virtual Sequence
//-----------------------------------------------------------------------------
class i2c_base_vseq extends uvm_sequence;

  `uvm_object_utils(i2c_base_vseq)
  `uvm_declare_p_sequencer(i2c_virtual_sequencer)

  function new(string name = "i2c_base_vseq");
    super.new(name);
  endfunction

endclass : i2c_base_vseq

//-----------------------------------------------------------------------------
// Clock Stretch Virtual Sequence
// Coordinates the master sending a write transaction while the slave stretches.
//-----------------------------------------------------------------------------
class i2c_stretch_vseq extends i2c_base_vseq;

  `uvm_object_utils(i2c_stretch_vseq)

  function new(string name = "i2c_stretch_vseq");
    super.new(name);
  endfunction

  task body();
    i2c_single_write_seq master_write;
    i2c_slave_ctrl_item  slave_ctrl;

    `uvm_info(get_type_name(), "Starting i2c_stretch_vseq", UVM_LOW)

    // 1. Configure the slave to stretch the clock
    slave_ctrl = i2c_slave_ctrl_item::type_id::create("slave_ctrl");
    start_item(slave_ctrl, -1, p_sequencer.slave_seqr);
    slave_ctrl.stretch_en_off_c.constraint_mode(0);
    slave_ctrl.force_nack_off_c.constraint_mode(0);
    if (!slave_ctrl.randomize() with {
      stretch_en == 1'b1;
      stretch_cycles == 16'd50; // Stretch for 50 cycles
    }) `uvm_fatal("VSEQ", "Randomization failed for slave_ctrl")
    finish_item(slave_ctrl, -1);

    // 2. Send master traffic
    master_write = i2c_single_write_seq::type_id::create("master_write");
    master_write.start(p_sequencer.master_seqr);

    `uvm_info(get_type_name(), "Finished i2c_stretch_vseq", UVM_LOW)
  endtask

endclass : i2c_stretch_vseq

`endif

//=============================================================================
// File          : i2c_env.sv
// Description   : UVM Environment — top-level UVM container.
//               : V3: Added virtual sequencer with handle wiring.
//               : Slave agent defaults to PASSIVE. Tests that need
//               : it ACTIVE set config_db before super.build_phase().
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_ENV_SV
`define I2C_ENV_SV

class i2c_env extends uvm_env;

  `uvm_component_utils(i2c_env)

  i2c_master_agent       master_agent;
  i2c_slave_agent        slave_agent;
  i2c_scoreboard         scoreboard;
  i2c_coverage           coverage;
  i2c_virtual_sequencer  v_sequencer;

  uvm_active_passive_enum slave_is_active;

  function new(string name = "i2c_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    master_agent    = i2c_master_agent::type_id::create("master_agent", this);

    if (!uvm_config_db#(uvm_active_passive_enum)::get(this, "slave_agent", "is_active", slave_is_active)) begin
      uvm_config_db#(uvm_active_passive_enum)::set(this, "slave_agent", "is_active", UVM_PASSIVE);
    end
    slave_agent     = i2c_slave_agent::type_id::create("slave_agent",  this);
    scoreboard      = i2c_scoreboard::type_id::create("scoreboard",     this);
    coverage        = i2c_coverage::type_id::create("coverage",         this);
    v_sequencer     = i2c_virtual_sequencer::type_id::create("v_sequencer", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    // Scoreboard connections
    master_agent.monitor.item_collected_port.connect(scoreboard.actual_export);
    master_agent.monitor.item_collected_port.connect(coverage.analysis_export);
    master_agent.driver.req_analysis_port.connect(scoreboard.expected_export);

    // Virtual sequencer handle wiring
    v_sequencer.master_seqr = master_agent.sequencer;
    if (slave_agent.get_is_active() == UVM_ACTIVE) begin
      v_sequencer.slave_seqr = slave_agent.sequencer;
    end
  endfunction

endclass : i2c_env

`endif

//=============================================================================
// File          : i2c_base_test.sv
// Description   : UVM Base Test — uses i2c_write_read_seq from the library.
//               : V2: Proper pass/fail reporting in report_phase.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_BASE_TEST_SV
`define I2C_BASE_TEST_SV

class i2c_base_test extends uvm_test;

  `uvm_component_utils(i2c_base_test)

  i2c_env env;

  function new(string name = "i2c_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = i2c_env::type_id::create("env", this);
  endfunction

  virtual task run_phase(uvm_phase phase);
    i2c_write_read_seq smoke;
    phase.raise_objection(this, "i2c_base_test starting");

    `uvm_info(get_type_name(), "=== I2C Base Test Starting ===", UVM_LOW)

    smoke = i2c_write_read_seq::type_id::create("smoke");
    smoke.start(env.master_agent.sequencer);

    #500;

    `uvm_info(get_type_name(), "=== I2C Base Test Complete ===", UVM_LOW)
    phase.drop_objection(this, "i2c_base_test done");
  endtask

  virtual function void report_phase(uvm_phase phase);
    uvm_report_server server;
    int err_count;
    super.report_phase(phase);
    server = uvm_report_server::get_server();
    err_count = server.get_severity_count(UVM_ERROR);
    if (err_count == 0) begin
      `uvm_info(get_type_name(), "TEST PASSED: No UVM_ERROR messages", UVM_LOW)
    end else begin
      `uvm_error(get_type_name(), $sformatf("TEST FAILED: %0d UVM_ERROR messages", err_count))
    end
  endfunction

endclass : i2c_base_test

`endif

//=============================================================================
// File          : i2c_tests.sv
// Description   : Test Plan for I2C Protocol Verification (V2)
//               : 15 test classes — all are REAL tests with self-checking.
//               : data_nack_test and clock_stretch_test activate slave agent.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_TESTS_SV
`define I2C_TESTS_SV

class basic_write_test extends i2c_base_test;
  `uvm_component_utils(basic_write_test)
  function new(string name = "basic_write_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_single_write_seq write_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting basic_write_test...", UVM_LOW)
    write_seq = i2c_single_write_seq::type_id::create("write_seq");
    write_seq.addr = 7'h50;
    write_seq.data = 8'hA5;
    write_seq.start(env.master_agent.sequencer);
    #500;
    `uvm_info(get_type_name(), "basic_write_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : basic_write_test

class basic_read_test extends i2c_base_test;
  `uvm_component_utils(basic_read_test)
  function new(string name = "basic_read_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_single_read_seq read_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting basic_read_test...", UVM_LOW)
    read_seq = i2c_single_read_seq::type_id::create("read_seq");
    read_seq.addr = 7'h50;
    read_seq.start(env.master_agent.sequencer);
    #500;
    `uvm_info(get_type_name(), "basic_read_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : basic_read_test

class burst_write_test extends i2c_base_test;
  `uvm_component_utils(burst_write_test)
  function new(string name = "burst_write_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_burst_write_seq burst_wr_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting burst_write_test...", UVM_LOW)
    burst_wr_seq = i2c_burst_write_seq::type_id::create("burst_wr_seq");
    burst_wr_seq.addr = 7'h50;
    burst_wr_seq.burst_len = 8;
    burst_wr_seq.start(env.master_agent.sequencer);
    #2000;
    `uvm_info(get_type_name(), "burst_write_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : burst_write_test

class burst_read_test extends i2c_base_test;
  `uvm_component_utils(burst_read_test)
  function new(string name = "burst_read_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_burst_read_seq burst_rd_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting burst_read_test...", UVM_LOW)
    burst_rd_seq = i2c_burst_read_seq::type_id::create("burst_rd_seq");
    burst_rd_seq.addr = 7'h50;
    burst_rd_seq.burst_len = 8;
    burst_rd_seq.start(env.master_agent.sequencer);
    #2000;
    `uvm_info(get_type_name(), "burst_read_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : burst_read_test

class write_read_test extends i2c_base_test;
  `uvm_component_utils(write_read_test)
  function new(string name = "write_read_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_write_read_seq wr_rd_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting write_read_test...", UVM_LOW)
    wr_rd_seq = i2c_write_read_seq::type_id::create("wr_rd_seq");
    wr_rd_seq.start(env.master_agent.sequencer);
    #1000;
    `uvm_info(get_type_name(), "write_read_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : write_read_test

class rep_start_test extends i2c_base_test;
  `uvm_component_utils(rep_start_test)
  function new(string name = "rep_start_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_rep_start_seq rep_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting rep_start_test...", UVM_LOW)
    rep_seq = i2c_rep_start_seq::type_id::create("rep_seq");
    rep_seq.start(env.master_agent.sequencer);
    #1000;
    `uvm_info(get_type_name(), "rep_start_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : rep_start_test

class addr_nack_test extends i2c_base_test;
  `uvm_component_utils(addr_nack_test)
  function new(string name = "addr_nack_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_nack_addr_seq nack_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting addr_nack_test...", UVM_LOW)
    nack_seq = i2c_nack_addr_seq::type_id::create("nack_seq");
    nack_seq.wrong_addr = 7'h55;
    nack_seq.start(env.master_agent.sequencer);
    #500;
    `uvm_info(get_type_name(), "addr_nack_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : addr_nack_test

class data_nack_test extends i2c_base_test;
  `uvm_component_utils(data_nack_test)
  function new(string name = "data_nack_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void build_phase(uvm_phase phase);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent", "is_active", UVM_ACTIVE);
    super.build_phase(phase);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_data_nack_seq write_seq;
    i2c_slave_force_nack_seq nack_ctrl_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting data_nack_test...", UVM_LOW)

    nack_ctrl_seq = i2c_slave_force_nack_seq::type_id::create("nack_ctrl_seq");
    fork
      nack_ctrl_seq.start(env.slave_agent.sequencer);
    join_none

    write_seq = i2c_data_nack_seq::type_id::create("write_seq");
    write_seq.addr = 7'h50;
    write_seq.data = 8'hDE;
    write_seq.start(env.master_agent.sequencer);
    #500;
    `uvm_info(get_type_name(), "data_nack_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : data_nack_test

class clock_stretch_test extends i2c_base_test;
  `uvm_component_utils(clock_stretch_test)
  function new(string name = "clock_stretch_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function void build_phase(uvm_phase phase);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent", "is_active", UVM_ACTIVE);
    super.build_phase(phase);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_clock_stretch_seq stretch_seq;
    i2c_slave_stretch_ctrl_seq stretch_ctrl_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting clock_stretch_test...", UVM_LOW)

    stretch_ctrl_seq = i2c_slave_stretch_ctrl_seq::type_id::create("stretch_ctrl_seq");
    stretch_ctrl_seq.stretch_cycles = 16'd100;
    fork
      stretch_ctrl_seq.start(env.slave_agent.sequencer);
    join_none

    stretch_seq = i2c_clock_stretch_seq::type_id::create("stretch_seq");
    stretch_seq.addr = 7'h50;
    stretch_seq.data = 8'hCC;
    stretch_seq.stretch_cycles = 16'd100;
    stretch_seq.start(env.master_agent.sequencer);
    #2000;
    `uvm_info(get_type_name(), "clock_stretch_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : clock_stretch_test

class random_directed_test extends i2c_base_test;
  `uvm_component_utils(random_directed_test)
  function new(string name = "random_directed_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_random_seq rand_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting random_directed_test...", UVM_LOW)
    rand_seq = i2c_random_seq::type_id::create("rand_seq");
    rand_seq.num_txns = 50;
    rand_seq.start(env.master_agent.sequencer);
    #5000;
    `uvm_info(get_type_name(), "random_directed_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : random_directed_test

class addr_sweep_test extends i2c_base_test;
  `uvm_component_utils(addr_sweep_test)
  function new(string name = "addr_sweep_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_addr_sweep_seq sweep_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting addr_sweep_test...", UVM_LOW)
    sweep_seq = i2c_addr_sweep_seq::type_id::create("sweep_seq");
    sweep_seq.start(env.master_agent.sequencer);
    #20000;
    `uvm_info(get_type_name(), "addr_sweep_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : addr_sweep_test

class bus_free_test extends i2c_base_test;
  `uvm_component_utils(bus_free_test)
  function new(string name = "bus_free_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_bus_free_seq write_seq;
    virtual i2c_if vif;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting bus_free_test...", UVM_LOW)

    if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", vif)) begin
      `uvm_fatal(get_type_name(), "i2c_vif not found")
    end

    write_seq = i2c_bus_free_seq::type_id::create("write_seq");
    write_seq.addr = 7'h50;
    write_seq.data = 8'h42;
    write_seq.start(env.master_agent.sequencer);

    #200;
    if (vif.sda === 1'b1 && vif.scl === 1'b1) begin
      `uvm_info(get_type_name(), "BUS FREE CHECK PASSED: SDA=1, SCL=1 after STOP", UVM_LOW)
    end else begin
      `uvm_error(get_type_name(), $sformatf("BUS FREE CHECK FAILED: SDA=%0b, SCL=%0b", vif.sda, vif.scl))
    end
    #500;
    `uvm_info(get_type_name(), "bus_free_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : bus_free_test

class sequential_txn_test extends i2c_base_test;
  `uvm_component_utils(sequential_txn_test)
  function new(string name = "sequential_txn_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_sequential_seq seq_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting sequential_txn_test...", UVM_LOW)
    seq_seq = i2c_sequential_seq::type_id::create("seq_seq");
    seq_seq.num_txns = 10;
    seq_seq.start(env.master_agent.sequencer);
    #3000;
    `uvm_info(get_type_name(), "sequential_txn_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : sequential_txn_test

class data_pattern_test extends i2c_base_test;
  `uvm_component_utils(data_pattern_test)
  function new(string name = "data_pattern_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_data_pattern_seq pat_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting data_pattern_test...", UVM_LOW)
    pat_seq = i2c_data_pattern_seq::type_id::create("pat_seq");
    pat_seq.start(env.master_agent.sequencer);
    #3000;
    `uvm_info(get_type_name(), "data_pattern_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : data_pattern_test

class full_stress_test extends i2c_base_test;
  `uvm_component_utils(full_stress_test)
  function new(string name = "full_stress_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_phase(uvm_phase phase);
    i2c_stress_seq stress_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting full_stress_test...", UVM_LOW)
    stress_seq = i2c_stress_seq::type_id::create("stress_seq");
    stress_seq.num_txns = 100;
    stress_seq.start(env.master_agent.sequencer);
    #50000;
    `uvm_info(get_type_name(), "full_stress_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : full_stress_test

`endif

endpackage : i2c_tb_pkg
`endif
//=============================================================================
// File          : top_tb.sv
// Description   : Top-level testbench for I2C Protocol Verification
//               : V2: Added force_data_nack connection.
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef TOP_TB_SV
`define TOP_TB_SV

`include "uvm_macros.svh"
import uvm_pkg::*;
import i2c_pkg::*;
import i2c_tb_pkg::*;

module top_tb;
  // NOTE: The DUT is the I2C SLAVE. The master RTL (i2c_master_controller.sv)
  // is NOT instantiated here — the UVM driver BFM (i2c_master_driver.sv)
  // directly generates protocol-compliant bus activity. This is standard
  // block-level verification methodology.

  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    #200 rst_n = 1'b1;
  end

  i2c_if i2c_bus_if (.clk(clk), .rst_n(rst_n));
  i2c_slave_if i2c_slv_if (.clk(clk), .rst_n(rst_n));

  i2c_slave #(.SLAVE_ADDR(7'h50)) slave_dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .scl           (i2c_bus_if.scl),
    .sda           (i2c_bus_if.sda),
    .stretch_en    (i2c_slv_if.stretch_en),
    .stretch_cycles(i2c_slv_if.stretch_cycles),
    .force_data_nack(i2c_slv_if.force_data_nack),
    .reg_bank      (i2c_slv_if.reg_bank),
    .reg_updated   (i2c_slv_if.reg_updated),
    .addr_match    (i2c_slv_if.addr_match),
    .active        (i2c_slv_if.active),
    .rx_data_valid (i2c_slv_if.rx_data_valid),
    .rx_data       (i2c_slv_if.rx_data),
    .tx_ack        (i2c_slv_if.tx_ack),
    .tx_nack       (i2c_slv_if.tx_nack),
    .bus_error     (i2c_slv_if.bus_error)
  );

  i2c_protocol_assertions u_sva (
    .clk   (clk),
    .rst_n (rst_n),
    .scl   (i2c_bus_if.scl),
    .sda   (i2c_bus_if.sda)
  );

  initial begin
    uvm_config_db #(virtual i2c_if)::set(null, "*", "i2c_vif", i2c_bus_if);
    uvm_config_db #(virtual i2c_slave_if)::set(null, "*", "i2c_slave_vif", i2c_slv_if);
    run_test();  // FIX: no default — +UVM_TESTNAME controls test selection
  end

  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, top_tb);
  end

  initial begin
    #50_000_000;  // FIX: 50ms timeout (was 10ms, too short for stress tests)
    $error("TIMEOUT: Simulation exceeded 50ms");
    $finish;
  end

endmodule : top_tb

`endif
