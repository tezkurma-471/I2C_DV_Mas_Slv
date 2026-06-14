//=============================================================================
// GENERATED FILE — do not edit. Rebuild with scripts/build_eda_playground.sh
// Source of truth: rtl/ tb/ uvm/ sva/ in the project tree.
//=============================================================================
// NOTE: comments stripped to fit EDA Playground's 100k-char file limit.
// The fully commented sources are in uvm/ in the project repository.
`ifndef I2C_TB_PKG_SV
`define I2C_TB_PKG_SV
package i2c_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import i2c_pkg::*;

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

  bit               addr_ack;
  bit               byte_ack [$];

  rand bit          inject_nack;
  rand bit          inject_timeout;

  int  num_rep_starts;   // rep-START chain depth: 0=direct START, 1+=chain position
  bit  stretch_seen;     // 1 if SCL was held LOW beyond T_SCL_LOW during this transaction

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

  constraint valid_protocol_c {
    start_cond || rep_start;     // Must have at least one
    !(start_cond && rep_start);  // Cannot have both simultaneously
  }

  constraint default_errors_c {
    inject_nack    == 0;
    inject_timeout == 0;
  }

  function new(string name = "i2c_seq_item");
    super.new(name);
    status         = STS_IDLE;
    ack_received   = 1'b0;
    addr_ack       = 1'b0;
    num_rep_starts = 0;
    stretch_seen   = 1'b0;
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
    s = {s, $sformatf(" addr_ack=%0b reps=%0d stretch=%0b", addr_ack, num_rep_starts, stretch_seen)};
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
    num_rep_starts = item.num_rep_starts;
    stretch_seen   = item.stretch_seen;
  endfunction

  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    i2c_seq_item item;
    if (!$cast(item, rhs)) return 0;
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

`ifndef I2C_SCOREBOARD_SV
`define I2C_SCOREBOARD_SV

`uvm_analysis_imp_decl(_expected)
`uvm_analysis_imp_decl(_actual)

class i2c_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(i2c_scoreboard)

  uvm_analysis_imp_expected #(i2c_seq_item, i2c_scoreboard) expected_export;
  uvm_analysis_imp_actual   #(i2c_seq_item, i2c_scoreboard) actual_export;

  i2c_seq_item exp_q [$];
  i2c_seq_item act_q [$];

  logic [7:0] ref_reg_bank [0:7];

  int expected_count;
  int actual_count;
  int error_count;
  int match_count;

  bit allow_bus_corruption;

  function new(string name = "i2c_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    expected_export = new("expected_export", this);
    actual_export   = new("actual_export",   this);
    for (int i = 0; i < 8; i++)
      ref_reg_bank[i] = 8'h00;
    expected_count = 0;
    actual_count   = 0;
    error_count    = 0;
    match_count    = 0;
    void'(uvm_config_db#(bit)::get(this, "", "allow_bus_corruption", allow_bus_corruption));
    if (allow_bus_corruption)
      `uvm_info(get_type_name(),
                "allow_bus_corruption set — intent-vs-wire checks suppressed", UVM_LOW)
  endfunction

  virtual function void write_expected(i2c_seq_item item);
    expected_count++;
    `uvm_info(get_type_name(),
              $sformatf("EXPECTED[%0d]: %s", expected_count, item.convert2string()), UVM_HIGH)
    exp_q.push_back(item);
    try_match();
  endfunction

  virtual function void write_actual(i2c_seq_item item);
    actual_count++;
    `uvm_info(get_type_name(),
              $sformatf("ACTUAL[%0d]: %s", actual_count, item.convert2string()), UVM_MEDIUM)
    act_q.push_back(item);
    try_match();
  endfunction

  virtual function void try_match();
    while (exp_q.size() > 0 && act_q.size() > 0) begin
      i2c_seq_item exp = exp_q.pop_front();
      i2c_seq_item act = act_q.pop_front();
      compare_pair(exp, act);
    end
  endfunction

  virtual function void compare_pair(i2c_seq_item exp, i2c_seq_item act);
    bit pair_ok = 1;

    if (allow_bus_corruption) begin
      match_count++;
      `uvm_info(get_type_name(),
                $sformatf("PAIR (corruption-tolerant): %s", act.convert2string()), UVM_MEDIUM)
      return;
    end

    if (exp.addr !== act.addr) begin
      `uvm_error(get_type_name(),
                 $sformatf("ADDR MISMATCH: drove 0x%02x, monitor saw 0x%02x", exp.addr, act.addr))
      error_count++; pair_ok = 0;
    end
    if (exp.dir != act.dir) begin
      `uvm_error(get_type_name(),
                 $sformatf("DIR MISMATCH: drove %s, monitor saw %s", exp.dir.name(), act.dir.name()))
      error_count++; pair_ok = 0;
    end

    check_address_ack(act);

    if (exp.addr_ack !== act.addr_ack) begin
      `uvm_error(get_type_name(),
                 $sformatf("ADDR_ACK INCONSISTENT: driver sampled %0b, monitor saw %0b",
                           exp.addr_ack, act.addr_ack))
      error_count++; pair_ok = 0;
    end

    if (!exp.addr_ack) begin
      if (act.data.size() > 0) begin
        `uvm_error(get_type_name(),
                   $sformatf("NACK'd address 0x%02x but %0d data byte(s) appeared on the bus",
                             act.addr, act.data.size()))
        error_count++; pair_ok = 0;
      end
    end else begin
      foreach (act.data[i]) begin
        if ($isunknown(act.data[i])) begin
          `uvm_error(get_type_name(),
                     $sformatf("DATA byte[%0d] = X/Z for addr=0x%02x", i, act.addr))
          error_count++; pair_ok = 0;
        end
      end

      if (exp.data.size() != act.data.size()) begin
        `uvm_error(get_type_name(),
                   $sformatf("PAYLOAD SIZE MISMATCH: drove %0d byte(s), monitor saw %0d",
                             exp.data.size(), act.data.size()))
        error_count++; pair_ok = 0;
      end else begin
        foreach (exp.data[i]) begin
          if (exp.data[i] !== act.data[i]) begin
            `uvm_error(get_type_name(),
                       $sformatf("%s DATA MISMATCH byte[%0d]: driver 0x%02x vs monitor 0x%02x",
                                 exp.dir.name(), i, exp.data[i], act.data[i]))
            error_count++; pair_ok = 0;
          end
        end
      end

      if (act.addr == 7'h50 && act.addr_ack) begin
        if (act.dir == DIR_READ) begin
          foreach (act.data[i]) begin
            logic [7:0] expected_val = ref_reg_bank[i % 8];
            if (act.data[i] !== expected_val) begin
              `uvm_error(get_type_name(),
                         $sformatf("READ MISMATCH reg[%0d]: shadow=0x%02x bus=0x%02x",
                                   i % 8, expected_val, act.data[i]))
              error_count++; pair_ok = 0;
            end
          end
        end else begin
          foreach (act.data[i]) begin
            ref_reg_bank[i % 8] = act.data[i];
            `uvm_info(get_type_name(),
                      $sformatf("SHADOW WRITE: reg[%0d] = 0x%02x", i % 8, act.data[i]), UVM_HIGH)
          end
        end
      end
    end

    if (pair_ok) begin
      match_count++;
      `uvm_info(get_type_name(),
                $sformatf("MATCH[%0d]: %s", match_count, act.convert2string()), UVM_HIGH)
    end
  endfunction

  virtual function void check_address_ack(i2c_seq_item item);
    bit expected_ack = (item.addr == 7'h50) ? 1'b1 : 1'b0;
    if (item.addr_ack !== expected_ack) begin
      `uvm_error(get_type_name(),
                 $sformatf("ADDR_ACK MISMATCH: addr=0x%02x expected_ack=%0b actual_ack=%0b",
                           item.addr, expected_ack, item.addr_ack))
      error_count++;
    end
  endfunction

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (exp_q.size() > 0) begin
      `uvm_error(get_type_name(),
                 $sformatf("%0d expected transaction(s) never observed on the bus", exp_q.size()))
      error_count += exp_q.size();
    end
    if (act_q.size() > 0) begin
      `uvm_error(get_type_name(),
                 $sformatf("%0d bus transaction(s) had no matching expected item", act_q.size()))
      error_count += act_q.size();
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info(get_type_name(),
              $sformatf("\n========== SCOREBOARD REPORT ==========\n  Expected Transactions : %0d\n  Actual Transactions   : %0d\n  Matched Pairs         : %0d\n  Errors                : %0d\n========================================",
                expected_count, actual_count, match_count, error_count),
              UVM_LOW)

    if (error_count > 0) begin
      `uvm_error(get_type_name(),
                 $sformatf("SCOREBOARD FAILED: %0d errors detected.", error_count))
    end else if (actual_count == 0) begin
      `uvm_error(get_type_name(), "SCOREBOARD FAILED: No actual transactions received!")
    end else if (actual_count != expected_count) begin
      `uvm_error(get_type_name(),
                 $sformatf("SCOREBOARD FAILED: Expected %0d but got %0d actual transactions.",
                           expected_count, actual_count))
    end else begin
      `uvm_info(get_type_name(), "SCOREBOARD PASSED: All transactions matched.", UVM_LOW)
    end
  endfunction

endclass : i2c_scoreboard

`endif

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
  int             scl_low_cnt;           // consecutive SCL-LOW cycle counter
  int             rep_start_chain_depth; // chain depth since last full START

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
    scl_low_cnt = 0;
    rep_start_chain_depth = 0;

    forever begin
      @(posedge vif.clk);
      if (vif.scl === 1'b0) scl_low_cnt++;
      else                   scl_low_cnt = 0;
      if (in_transaction && scl_low_cnt > 64 && current_item != null)
        current_item.stretch_seen = 1'b1;

      if (vif.sda === 1'b0 && prev_sda === 1'b1 && vif.scl === 1'b1) begin
        if (in_transaction && current_item != null) begin
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
        if (saw_rep_start) begin
          rep_start_chain_depth++;
          current_item.num_rep_starts = rep_start_chain_depth;
        end else begin
          rep_start_chain_depth = 0;
          current_item.num_rep_starts = 0;
        end
      end

      if (vif.sda === 1'b1 && prev_sda === 1'b0 && vif.scl === 1'b1) begin
        if (in_transaction) begin
          `uvm_info(get_type_name(), "STOP condition detected", UVM_MEDIUM)
          current_item.stop_cond = 1;
          finalize_and_write_item();
          in_transaction = 0;
          addr_phase = 0;
          bit_cnt = 0;
          saw_rep_start = 0;
          rep_start_chain_depth = 0;
          scl_low_cnt = 0;
        end
      end

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

`ifndef I2C_MASTER_DRIVER_SV
`define I2C_MASTER_DRIVER_SV

class i2c_driver extends uvm_driver #(i2c_seq_item);

  `uvm_component_utils(i2c_driver)

  virtual i2c_if vif;

  uvm_analysis_port #(i2c_seq_item) req_analysis_port;

  localparam int BIT_HOLD   = T_HD_DAT + 3;  // SDA stable after SCL falls
  localparam int BIT_SETUP  = T_SU_DAT + 3;  // SDA stable before SCL rises
  localparam int SCL_HIGH_N = 6;             // SCL high time per bit
  localparam int BUS_FREE_N = T_BUF + 6;     // bus-free time after STOP (A7)

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

      drive_item(req_item);

      req_analysis_port.write(req_item);

      seq_item_port.item_done();
    end
  endtask

  virtual task drive_item(i2c_seq_item it);
    bit         got_ack;
    logic [7:0] rdata;

    if (it.start_cond && !it.rep_start) begin
      send_start();
    end else if (it.rep_start) begin
      send_rep_start();
    end

    if (it.start_cond || it.rep_start) begin
      send_byte({it.addr, logic'(it.dir)});
      wait_for_ack(got_ack);
      it.addr_ack     = got_ack;
      it.ack_received = got_ack;
      if (!got_ack) begin
        `uvm_info(get_type_name(),
                  $sformatf("Address 0x%02x NACKed — aborting with STOP", it.addr), UVM_MEDIUM)
        it.data.delete();
        it.num_data = 0;
        send_stop();
        return;
      end
    end

    if (it.dir == DIR_WRITE) begin
      for (int i = 0; i < it.data.size(); i++) begin
        send_byte(it.data[i]);
        wait_for_ack(got_ack);
        it.byte_ack.push_back(got_ack);
        if (!got_ack) begin
          `uvm_info(get_type_name(),
                    $sformatf("Data byte %0d NACKed — ending transfer", i), UVM_MEDIUM)
          it.data     = it.data[0:i];
          it.num_data = i + 1;
          break;
        end
      end
    end else begin
      for (int i = 0; i < it.data.size(); i++) begin
        receive_byte(rdata);
        it.data[i] = rdata;
        if (i < it.data.size() - 1) send_ack();
        else                        send_nack();
      end
    end

    if (it.stop_cond) begin
      send_stop();
    end
  endtask

  virtual task scl_release_wait();
    int timeout_count = 0;
    vif.scl_drv <= 1'b1;
    @(posedge vif.clk);
    while (vif.scl !== 1'b1) begin
      @(posedge vif.clk);
      timeout_count++;
      if (timeout_count >= MAX_CLK_STRETCH) begin
        `uvm_error(get_type_name(),
                   $sformatf("Clock-stretch timeout: SCL held low > %0d cycles", MAX_CLK_STRETCH))
        return;
      end
    end
  endtask

  virtual task send_start();
    `uvm_info(get_type_name(), "Sending START condition", UVM_HIGH)
    vif.sda_drv <= 1'b1;
    vif.scl_drv <= 1'b1;
    repeat (T_SU_STA) @(posedge vif.clk);
    vif.sda_drv <= 1'b0;  // SDA falls while SCL HIGH = START
    repeat (T_HD_STA) @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
  endtask

  virtual task send_rep_start();
    `uvm_info(get_type_name(), "Sending Repeated START (Sr)", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    repeat (BIT_HOLD) @(posedge vif.clk);
    vif.sda_drv <= 1'b1;             // release SDA while SCL low
    repeat (BIT_SETUP) @(posedge vif.clk);
    scl_release_wait();              // SCL high (stretch-aware), SDA high
    repeat (T_SU_STA) @(posedge vif.clk);
    vif.sda_drv <= 1'b0;             // SDA falls while SCL HIGH = Sr
    repeat (T_HD_STA) @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    @(posedge vif.clk);
  endtask

  virtual task send_stop();
    `uvm_info(get_type_name(), "Sending STOP condition", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    repeat (BIT_HOLD) @(posedge vif.clk);
    vif.sda_drv <= 1'b0;             // SDA low while SCL low (setup)
    repeat (BIT_SETUP) @(posedge vif.clk);
    scl_release_wait();              // SCL high first...
    repeat (T_SU_STO) @(posedge vif.clk);
    vif.sda_drv <= 1'b1;             // ...then SDA rises while SCL HIGH = STOP
    repeat (BUS_FREE_N) @(posedge vif.clk);  // T_BUF bus-free time (A7)
  endtask

  virtual task send_byte(input logic [7:0] byte_data);
    `uvm_info(get_type_name(), $sformatf("Sending byte: 0x%02x", byte_data), UVM_HIGH)
    for (int i = 7; i >= 0; i--) begin
      vif.scl_drv <= 1'b0;
      repeat (BIT_HOLD) @(posedge vif.clk);    // T_HD_DAT: hold SDA after SCL fall
      vif.sda_drv <= byte_data[i];
      repeat (BIT_SETUP) @(posedge vif.clk);   // T_SU_DAT: setup before SCL rise
      scl_release_wait();                      // SCL HIGH — slave samples SDA
      repeat (SCL_HIGH_N) @(posedge vif.clk);
    end
  endtask

  virtual task receive_byte(output logic [7:0] received_byte);
    `uvm_info(get_type_name(), "Receiving byte from slave", UVM_HIGH)
    for (int i = 7; i >= 0; i--) begin
      vif.scl_drv <= 1'b0;
      repeat (BIT_HOLD) @(posedge vif.clk);
      vif.sda_drv <= 1'b1;                     // Release SDA (let slave drive)
      repeat (BIT_SETUP) @(posedge vif.clk);
      scl_release_wait();                      // SCL HIGH — sample window
      repeat (2) @(posedge vif.clk);
      received_byte[i] = vif.sda;              // Sample mid-high
      repeat (SCL_HIGH_N - 2) @(posedge vif.clk);
    end
    `uvm_info(get_type_name(), $sformatf("Received byte: 0x%02x", received_byte), UVM_MEDIUM)
  endtask

  virtual task wait_for_ack(output bit ack_result);
    `uvm_info(get_type_name(), "Waiting for ACK/NACK", UVM_HIGH)
    vif.scl_drv <= 1'b0;
    repeat (BIT_HOLD) @(posedge vif.clk);
    vif.sda_drv <= 1'b1;                       // Release SDA (slave drives ACK)
    repeat (BIT_SETUP) @(posedge vif.clk);
    scl_release_wait();                        // SCL HIGH — sample ACK
    repeat (2) @(posedge vif.clk);
    ack_result = (vif.sda === 1'b0);
    repeat (SCL_HIGH_N - 2) @(posedge vif.clk);

    if (ack_result) `uvm_info(get_type_name(), "ACK received", UVM_MEDIUM)
    else            `uvm_info(get_type_name(), "NACK received", UVM_MEDIUM)
  endtask

  virtual task send_ack();
    `uvm_info(get_type_name(), "Sending ACK", UVM_HIGH)
    drive_ack_bit(1'b0);
  endtask

  virtual task send_nack();
    `uvm_info(get_type_name(), "Sending NACK", UVM_HIGH)
    drive_ack_bit(1'b1);
  endtask

  virtual task drive_ack_bit(input logic level);
    vif.scl_drv <= 1'b0;
    repeat (BIT_HOLD) @(posedge vif.clk);
    vif.sda_drv <= level;                      // 0 = ACK, 1 = NACK (release)
    repeat (BIT_SETUP) @(posedge vif.clk);
    scl_release_wait();
    repeat (SCL_HIGH_N) @(posedge vif.clk);
    vif.scl_drv <= 1'b0;
    repeat (BIT_HOLD) @(posedge vif.clk);
    vif.sda_drv <= 1'b1;                       // Release SDA during SCL low
    @(posedge vif.clk);
  endtask

endclass : i2c_driver

`endif

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

  virtual i2c_if       bus_vif;

  bit  compete_mode    = 1'b0;
  int  compete_at_bit  = 3;

  function new(string name = "i2c_slave_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual i2c_slave_if)::get(this, "", "i2c_slave_vif", vif)) begin
      `uvm_fatal(get_type_name(), "i2c_slave_vif not found in config_db")
    end
    void'(uvm_config_db#(bit)::get(this, "", "compete_mode",   compete_mode));
    void'(uvm_config_db#(int)::get(this, "", "compete_at_bit", compete_at_bit));
    if (compete_mode) begin
      if (!uvm_config_db#(virtual i2c_if)::get(this, "", "i2c_vif", bus_vif)) begin
        `uvm_fatal(get_type_name(),
                   "compete_mode set but i2c_vif not found in config_db")
      end
      `uvm_info(get_type_name(),
                $sformatf("T13: compete_mode ENABLED, will collide at bit %0d",
                          compete_at_bit), UVM_LOW)
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.stretch_en      <= 1'b0;
    vif.stretch_cycles  <= 16'd0;
    vif.force_data_nack <= 1'b0;

    if (compete_mode) begin
      fork
        drive_competition();
      join_none
    end

    forever begin
      seq_item_port.get_next_item(req);
      `uvm_info(get_type_name(), $sformatf("Applying: %s", req.convert2string()), UVM_MEDIUM)

      vif.stretch_en      <= req.stretch_en;
      vif.stretch_cycles  <= req.stretch_cycles;
      vif.force_data_nack <= req.force_data_nack;

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

  virtual task drive_competition();
    `uvm_info(get_type_name(), "T13: competing master task started", UVM_MEDIUM)
    bus_vif.sda_drv_x <= 1'b1;

    @(negedge bus_vif.sda);
    if (bus_vif.scl !== 1'b1) begin
      wait (bus_vif.sda === 1'b1 && bus_vif.scl === 1'b1);
      @(negedge bus_vif.sda);
    end
    `uvm_info(get_type_name(), "T13: detected START — counting SCL bits", UVM_MEDIUM)

    for (int i = 0; i < compete_at_bit; i++) begin
      @(posedge bus_vif.scl);
    end

    @(negedge bus_vif.scl);             // wait for SCL to go LOW (bit change)
    bus_vif.sda_drv_x <= 1'b0;          // pull SDA LOW (compete)
    `uvm_info(get_type_name(),
              $sformatf("T13: pulling SDA LOW at bit %0d", compete_at_bit),
              UVM_LOW)
    @(posedge bus_vif.scl);             // hold through SCL HIGH window
    @(negedge bus_vif.scl);
    bus_vif.sda_drv_x <= 1'b1;          // release
    `uvm_info(get_type_name(), "T13: released SDA after collision", UVM_MEDIUM)
  endtask

endclass : i2c_slave_driver

`endif

`ifndef I2C_SEQUENCES_SV
`define I2C_SEQUENCES_SV

class i2c_base_seq extends uvm_sequence #(i2c_seq_item);

  `uvm_object_utils(i2c_base_seq)

  function new(string name = "i2c_base_seq");
    super.new(name);
  endfunction

  task do_rep_chain(string prefix);
    i2c_seq_item seg_a, seg_b;

    seg_a = i2c_seq_item::type_id::create({prefix, "_chainA"});
    seg_a.default_trans_c.constraint_mode(0);
    start_item(seg_a);
    if (!seg_a.randomize() with {
      addr       == 7'h50;
      num_data inside {[1:4]};
      start_cond == 1;
      stop_cond  == 0;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed for rep-chain segment A")
    finish_item(seg_a);

    seg_b = i2c_seq_item::type_id::create({prefix, "_chainB"});
    seg_b.default_trans_c.constraint_mode(0);
    start_item(seg_b);
    if (!seg_b.randomize() with {
      addr       == 7'h50;
      num_data inside {[1:4]};
      start_cond == 0;
      stop_cond  == 1;
      rep_start  == 1;
    }) `uvm_fatal("SEQ", "Randomization failed for rep-chain segment B")
    finish_item(seg_b);
  endtask

endclass : i2c_base_seq

class i2c_single_write_seq extends i2c_base_seq;

  `uvm_object_utils(i2c_single_write_seq)

  logic [6:0] addr = 7'h50;
  logic [7:0] data = 8'hA5;

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

  logic [6:0] addr = 7'h50;

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
    wr_item.default_trans_c.constraint_mode(0);
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
    rd_item.default_trans_c.constraint_mode(0);
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

  constraint default_addr_c  { addr == 7'h50; }

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
      if ($urandom_range(0, 3) == 0) begin
        do_rep_chain($sformatf("rand_%0d", i));
      end else begin
        i2c_seq_item item = i2c_seq_item::type_id::create($sformatf("rand_item_%0d", i));
        start_item(item);
        if (!item.randomize()) begin
          `uvm_error("SEQ", $sformatf("Randomization failed for item %0d", i))
          continue;
        end
        finish_item(item);
      end
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
      if ($urandom_range(0, 3) == 0) begin
        do_rep_chain($sformatf("stress_%0d", i));
      end else begin
        i2c_seq_item item = i2c_seq_item::type_id::create($sformatf("stress_item_%0d", i));
        start_item(item);
        if (!item.randomize()) begin
          `uvm_error("SEQ", $sformatf("Randomization failed for stress item %0d", i))
          continue;
        end
        finish_item(item);
      end
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
    ctrl.stretch_cycles_c.constraint_mode(0);
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
    stretch_cycles inside {[16'd200 : 16'd400]};
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

class arb_lost_sequence extends uvm_sequence #(i2c_seq_item);

  `uvm_object_utils(arb_lost_sequence)

  function new(string name = "arb_lost_sequence");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item req = i2c_seq_item::type_id::create("arb_lost_req");
    start_item(req);
    if (!req.randomize() with {
      addr       == 7'h50;
      dir        == DIR_WRITE;
      num_data   == 1;
      data.size() == 1;
      data[0]    == 8'hAA;  // pattern that will lose at the chosen bit
      start_cond == 1;
      stop_cond  == 1;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "Randomization failed in arb_lost_sequence")
    finish_item(req);
  endtask

endclass : arb_lost_sequence

class deep_rep_start_sequence extends i2c_base_seq;

  `uvm_object_utils(deep_rep_start_sequence)

  logic [6:0] addr = 7'h50;

  function new(string name = "deep_rep_start_sequence");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item seg0, seg1, seg2, seg3;

    seg0 = i2c_seq_item::type_id::create("seg0");
    seg0.default_trans_c.constraint_mode(0);
    start_item(seg0);
    if (!seg0.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == 1;
      start_cond == 1;
      stop_cond  == 0;
      rep_start  == 0;
    }) `uvm_fatal("SEQ", "deep_rep_start_sequence: seg0 randomization failed")
    finish_item(seg0);

    seg1 = i2c_seq_item::type_id::create("seg1");
    seg1.default_trans_c.constraint_mode(0);
    start_item(seg1);
    if (!seg1.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == 1;
      start_cond == 0;
      stop_cond  == 0;
      rep_start  == 1;
    }) `uvm_fatal("SEQ", "deep_rep_start_sequence: seg1 randomization failed")
    finish_item(seg1);

    seg2 = i2c_seq_item::type_id::create("seg2");
    seg2.default_trans_c.constraint_mode(0);
    start_item(seg2);
    if (!seg2.randomize() with {
      addr       == local::addr;
      dir        == DIR_WRITE;
      num_data   == 1;
      start_cond == 0;
      stop_cond  == 0;
      rep_start  == 1;
    }) `uvm_fatal("SEQ", "deep_rep_start_sequence: seg2 randomization failed")
    finish_item(seg2);

    seg3 = i2c_seq_item::type_id::create("seg3");
    seg3.default_trans_c.constraint_mode(0);
    start_item(seg3);
    if (!seg3.randomize() with {
      addr       == local::addr;
      dir        == DIR_READ;
      num_data   == 1;
      start_cond == 0;
      stop_cond  == 1;
      rep_start  == 1;
    }) `uvm_fatal("SEQ", "deep_rep_start_sequence: seg3 randomization failed")
    finish_item(seg3);
  endtask

endclass : deep_rep_start_sequence

`endif

`ifndef I2C_COVERAGE_SV
`define I2C_COVERAGE_SV

class i2c_coverage extends uvm_subscriber #(i2c_seq_item);
  `uvm_component_utils(i2c_coverage)

  i2c_seq_item item;
  bit has_data_nack;  // computed in write() from byte_ack[] queue

  covergroup i2c_dir_cg;
    option.per_instance = 1;
    option.name = "Direction";
    cp_dir: coverpoint item.dir {
      bins write = {DIR_WRITE};
      bins read  = {DIR_READ};
    }
  endgroup

  covergroup i2c_data_size_cg;
    option.per_instance = 1;
    option.name = "Data Size";
    cp_size: coverpoint item.num_data {
      bins single = {1};
      bins short_burst  = {[2:8]};
      bins med_burst = {[9:16]};
      bins long_burst   = {[17:32]};
    }
  endgroup

  covergroup i2c_addr_cg;
    option.per_instance = 1;
    option.name = "Address";
    cp_addr: coverpoint item.addr {
      bins target_addr = {7'h50};
      bins other_addrs = {[7'h08:7'h4F], [7'h51:7'h77]};
    }
  endgroup

  covergroup i2c_protocol_cg;
    option.per_instance = 1;
    option.name = "Protocol";
    cp_start: coverpoint item.start_cond {
      bins has_start      = {1};
      ignore_bins no_start_ok = {0};  // rep_start txns have start_cond=0; tracked by cp_rep
    }
    cp_stop:  coverpoint item.stop_cond  { bins has_stop  = {1}; bins no_stop = {0}; }
    cp_rep:   coverpoint item.rep_start  { bins has_rep   = {1}; bins no_rep  = {0}; }
  endgroup

  covergroup i2c_ack_cg;
    option.per_instance = 1;
    option.name = "ACK Responses";
    cp_addr_ack: coverpoint item.addr_ack {
      bins ack  = {1};
      bins nack = {0};
    }
  endgroup

  covergroup i2c_burst_cg;
    option.per_instance = 1;
    option.name = "Burst Cross";
    cp_dir: coverpoint item.dir;
    cp_size: coverpoint item.num_data {
      bins single = {1};
      bins short_burst  = {[2:8]};
      bins med_burst = {[9:16]};
      bins long_burst   = {[17:32]};
    }
    cross cp_dir, cp_size;
  endgroup

  covergroup i2c_reg_ptr_cg;
    option.per_instance = 1;
    option.name = "Register Bank Coverage";
    cp_reg: coverpoint item.num_data {
      bins single_reg      = {1};
      bins partial_bank    = {[2:4]};
      bins more_than_half  = {[5:7]};
      bins full_bank       = {8};
      bins multi_wrap      = {[9:32]};
    }
  endgroup

  covergroup i2c_target_cg;
    option.per_instance = 1;
    option.name = "Target Cross";
    cp_addr: coverpoint item.addr { bins target = {7'h50}; }
    cp_dir: coverpoint item.dir;
    cross cp_addr, cp_dir;
  endgroup

  covergroup i2c_byte_nack_cg;
    option.per_instance = 1;
    option.name = "Per-Byte NACK";
    cp_byte_nack: coverpoint has_data_nack {
      bins all_bytes_ack  = {0};   // every data byte was ACK'd
      bins data_nack_seen = {1};   // at least one data byte NACK'd (data_nack_test)
    }
  endgroup

  covergroup i2c_stretch_cg;
    option.per_instance = 1;
    option.name = "Clock Stretch";
    cp_stretch: coverpoint item.stretch_seen {
      bins no_stretch       = {0};  // normal SCL timing
      bins stretch_seen_bin = {1};  // SCL held LOW > T_SCL_LOW+10 cycles by slave
    }
  endgroup

  covergroup i2c_rep_depth_cg;
    option.per_instance = 1;
    option.name = "RepStart Depth";
    cp_depth: coverpoint item.num_rep_starts {
      bins no_rep   = {0};     // direct START — fresh transaction
      bins one_rep  = {1};     // 2nd segment (after 1 rep-start): write-then-read
      bins two_rep  = {2};     // 3rd segment — rarely tested
      bins deep_rep = {[3:$]}; // deep chain — potential gap
    }
  endgroup

  covergroup i2c_dir_addr_cross_cg;
    option.per_instance = 1;
    option.name = "Dir x Addr Range";
    cp_dir: coverpoint item.dir;
    cp_addr_range: coverpoint item.addr {
      bins target     = {7'h50};
      bins low_range  = {[7'h08:7'h4F]};
      bins high_range = {[7'h51:7'h77]};
    }
    cross cp_dir, cp_addr_range;
  endgroup

  covergroup i2c_dir_ack_cross_cg;
    option.per_instance = 1;
    option.name = "Dir x ACK";
    cp_dir: coverpoint item.dir;
    cp_ack: coverpoint item.addr_ack {
      bins ack  = {1};
      bins nack = {0};
    }
    cross cp_dir, cp_ack;
  endgroup

  covergroup i2c_rep_dir_cross_cg;
    option.per_instance = 1;
    option.name = "RepStart x Dir";
    cp_rep: coverpoint item.rep_start {
      bins no_rep  = {0};
      bins has_rep = {1};
    }
    cp_dir: coverpoint item.dir;
    cross cp_rep, cp_dir;
  endgroup

  covergroup i2c_dir_size_cross_cg;
    option.per_instance = 1;
    option.name = "Dir x Data Size";
    cp_dir: coverpoint item.dir;
    cp_size: coverpoint item.num_data {
      bins single    = {1};
      bins sz_small  = {[2:4]};
      bins sz_medium = {[5:8]};
      bins sz_large  = {[9:16]};
      bins sz_xlarge = {[17:32]};
    }
    cross cp_dir, cp_size;
  endgroup

  covergroup i2c_protocol_dir_cross_cg;
    option.per_instance = 1;
    option.name = "Protocol x Dir";
    cp_dir: coverpoint item.dir;
    cp_has_stop: coverpoint item.stop_cond {
      bins has_stop = {1};
      bins no_stop  = {0};
    }
    cross cp_dir, cp_has_stop;
  endgroup

  covergroup i2c_stretch_dir_cross_cg;
    option.per_instance = 1;
    option.name = "Stretch x Dir";
    cp_stretch: coverpoint item.stretch_seen {
      bins no_stretch  = {0};
      bins has_stretch = {1};
    }
    cp_dir: coverpoint item.dir;
    cross cp_stretch, cp_dir;
  endgroup

  function new(string name = "i2c_coverage", uvm_component parent = null);
    super.new(name, parent);
    i2c_dir_cg       = new();
    i2c_data_size_cg = new();
    i2c_addr_cg      = new();
    i2c_protocol_cg  = new();
    i2c_ack_cg       = new();
    i2c_burst_cg              = new();
    i2c_reg_ptr_cg            = new();
    i2c_target_cg             = new();
    i2c_byte_nack_cg          = new();
    i2c_stretch_cg            = new();
    i2c_rep_depth_cg          = new();
    i2c_dir_addr_cross_cg     = new();
    i2c_dir_ack_cross_cg      = new();
    i2c_rep_dir_cross_cg      = new();
    i2c_dir_size_cross_cg     = new();
    i2c_protocol_dir_cross_cg = new();
    i2c_stretch_dir_cross_cg  = new();
  endfunction

  virtual function void write(i2c_seq_item t);
    this.item = t;
    has_data_nack = 0;
    foreach (t.byte_ack[i]) if (t.byte_ack[i] == 1'b0) has_data_nack = 1;
    i2c_dir_cg.sample();
    i2c_data_size_cg.sample();
    i2c_addr_cg.sample();
    i2c_protocol_cg.sample();
    i2c_ack_cg.sample();
    i2c_burst_cg.sample();
    if (t.num_data > 0) i2c_reg_ptr_cg.sample();
    if (t.addr == 7'h50) i2c_target_cg.sample();
    if (t.num_data > 0) i2c_byte_nack_cg.sample();
    i2c_stretch_cg.sample();
    i2c_rep_depth_cg.sample();
    i2c_dir_addr_cross_cg.sample();
    i2c_dir_ack_cross_cg.sample();
    i2c_rep_dir_cross_cg.sample();
    i2c_dir_size_cross_cg.sample();
    i2c_protocol_dir_cross_cg.sample();
    i2c_stretch_dir_cross_cg.sample();
  endfunction

  virtual function void report_phase(uvm_phase phase);
    real cov_vals[$];
    real avg_cov = 0.0;

    cov_vals.push_back(i2c_dir_cg.get_coverage());
    cov_vals.push_back(i2c_data_size_cg.get_coverage());
    cov_vals.push_back(i2c_addr_cg.get_coverage());
    cov_vals.push_back(i2c_protocol_cg.get_coverage());
    cov_vals.push_back(i2c_ack_cg.get_coverage());
    cov_vals.push_back(i2c_burst_cg.get_coverage());
    cov_vals.push_back(i2c_reg_ptr_cg.get_coverage());
    cov_vals.push_back(i2c_target_cg.get_coverage());
    cov_vals.push_back(i2c_byte_nack_cg.get_coverage());
    cov_vals.push_back(i2c_stretch_cg.get_coverage());
    cov_vals.push_back(i2c_rep_depth_cg.get_coverage());
    cov_vals.push_back(i2c_dir_addr_cross_cg.get_coverage());
    cov_vals.push_back(i2c_dir_ack_cross_cg.get_coverage());
    cov_vals.push_back(i2c_rep_dir_cross_cg.get_coverage());
    cov_vals.push_back(i2c_dir_size_cross_cg.get_coverage());
    cov_vals.push_back(i2c_protocol_dir_cross_cg.get_coverage());
    cov_vals.push_back(i2c_stretch_dir_cross_cg.get_coverage());

    foreach (cov_vals[i]) avg_cov += cov_vals[i];
    avg_cov = avg_cov / cov_vals.size();

    super.report_phase(phase);
    `uvm_info(get_type_name(),
              $sformatf("\n--- COVERAGE SUMMARY (all %0d covergroups) ---\nDir: %0.2f%%  Size: %0.2f%%  ACK: %0.2f%%  Burst: %0.2f%%\nAVG (all CGs): %0.2f%%\n------------------------",
                        cov_vals.size(),
                        cov_vals[0], cov_vals[1], cov_vals[4], cov_vals[5], avg_cov), UVM_LOW)
    if (avg_cov < 90.0) begin
      `uvm_warning(get_type_name(), $sformatf("Coverage is below 90%%: %0.2f%%", avg_cov))
    end
    `uvm_info(get_type_name(),
              $sformatf("\n--- EXTENDED COVERAGE (CG9-17) ---\nByte NACK: %0.2f%%\nStretch: %0.2f%%\nRepDepth: %0.2f%%\nDir x Addr: %0.2f%%\nDir x ACK: %0.2f%%\nRep x Dir: %0.2f%%\nDir x Size: %0.2f%%\nProto x Dir: %0.2f%%\nStretch x Dir: %0.2f%%\n-----------------------------------",
                        i2c_byte_nack_cg.get_coverage(),
                        i2c_stretch_cg.get_coverage(),
                        i2c_rep_depth_cg.get_coverage(),
                        i2c_dir_addr_cross_cg.get_coverage(),
                        i2c_dir_ack_cross_cg.get_coverage(),
                        i2c_rep_dir_cross_cg.get_coverage(),
                        i2c_dir_size_cross_cg.get_coverage(),
                        i2c_protocol_dir_cross_cg.get_coverage(),
                        i2c_stretch_dir_cross_cg.get_coverage()), UVM_LOW)
  endfunction

endclass : i2c_coverage

`endif

`ifndef I2C_MASTER_AGENT_SV
`define I2C_MASTER_AGENT_SV

class i2c_master_agent extends uvm_agent;

  `uvm_component_utils(i2c_master_agent)

  i2c_driver              driver;
  i2c_monitor             monitor;
  uvm_sequencer #(i2c_seq_item) sequencer;

  uvm_analysis_port #(i2c_seq_item) analysis_port;

  function new(string name = "i2c_master_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = i2c_driver::type_id::create("driver",    this);
      sequencer = uvm_sequencer #(i2c_seq_item)::type_id::create("sequencer", this);
    end
    monitor       = i2c_monitor::type_id::create("monitor", this);
    analysis_port = new("analysis_port", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
    monitor.item_collected_port.connect(analysis_port);
  endfunction

endclass : i2c_master_agent

`endif

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

`ifndef I2C_VIRTUAL_SEQUENCER_SV
`define I2C_VIRTUAL_SEQUENCER_SV

class i2c_virtual_sequencer extends uvm_sequencer;

  `uvm_component_utils(i2c_virtual_sequencer)

  uvm_sequencer #(i2c_seq_item)        master_seqr;
  uvm_sequencer #(i2c_slave_ctrl_item) slave_seqr;

  function new(string name = "i2c_virtual_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass : i2c_virtual_sequencer

`endif

`ifndef I2C_VIRTUAL_SEQUENCE_SV
`define I2C_VIRTUAL_SEQUENCE_SV

class i2c_base_vseq extends uvm_sequence;

  `uvm_object_utils(i2c_base_vseq)
  `uvm_declare_p_sequencer(i2c_virtual_sequencer)

  function new(string name = "i2c_base_vseq");
    super.new(name);
  endfunction

endclass : i2c_base_vseq

class i2c_stretch_vseq extends i2c_base_vseq;

  `uvm_object_utils(i2c_stretch_vseq)

  function new(string name = "i2c_stretch_vseq");
    super.new(name);
  endfunction

  task arm_stretch(string name);
    i2c_slave_ctrl_item slave_ctrl;
    slave_ctrl = i2c_slave_ctrl_item::type_id::create(name);
    start_item(slave_ctrl, -1, p_sequencer.slave_seqr);
    slave_ctrl.stretch_en_off_c.constraint_mode(0);
    if (!slave_ctrl.randomize() with {
      stretch_en      == 1'b1;
      stretch_cycles  == 16'd300;
      force_data_nack == 1'b0;
    }) `uvm_fatal("VSEQ", "Randomization failed for slave_ctrl")
    finish_item(slave_ctrl, -1);
  endtask

  task body();
    i2c_single_write_seq master_write;
    i2c_single_read_seq  master_read;

    `uvm_info(get_type_name(), "Starting i2c_stretch_vseq", UVM_LOW)

    if (p_sequencer.slave_seqr == null) begin
      `uvm_fatal("VSEQ",
                 "slave_seqr is null — start this vseq with the slave agent UVM_ACTIVE")
    end

    fork
      arm_stretch("stretch_for_write");
    join_none
    #200;  // let the ctrl item reach the slave driver before traffic starts
    master_write = i2c_single_write_seq::type_id::create("master_write");
    master_write.start(p_sequencer.master_seqr);

    fork
      arm_stretch("stretch_for_read");
    join_none
    #200;
    master_read = i2c_single_read_seq::type_id::create("master_read");
    master_read.start(p_sequencer.master_seqr);

    wait fork;  // drain the ctrl legs

    `uvm_info(get_type_name(), "Finished i2c_stretch_vseq", UVM_LOW)
  endtask

endclass : i2c_stretch_vseq

`endif

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
    master_agent.monitor.item_collected_port.connect(scoreboard.actual_export);
    master_agent.monitor.item_collected_port.connect(coverage.analysis_export);
    master_agent.driver.req_analysis_port.connect(scoreboard.expected_export);

    v_sequencer.master_seqr = master_agent.sequencer;
    if (slave_agent.get_is_active() == UVM_ACTIVE) begin
      v_sequencer.slave_seqr = slave_agent.sequencer;
    end
  endfunction

endclass : i2c_env

`endif

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

class arbitration_lost_test extends i2c_base_test;
  `uvm_component_utils(arbitration_lost_test)

  function new(string name = "arbitration_lost_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent",
                                                  "is_active", UVM_ACTIVE);
    uvm_config_db#(bit)::set(this, "env.slave_agent.driver",
                              "compete_mode", 1'b1);
    uvm_config_db#(int)::set(this, "env.slave_agent.driver",
                              "compete_at_bit", 3);  // collide at bit 3
    uvm_config_db#(bit)::set(this, "env.scoreboard",
                              "allow_bus_corruption", 1'b1);
    super.build_phase(phase);
  endfunction

  virtual task run_phase(uvm_phase phase);
    arb_lost_sequence seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(),
              "Starting arbitration_lost_test (T13)...", UVM_LOW)

    seq = arb_lost_sequence::type_id::create("seq");
    seq.start(env.master_agent.sequencer);

    #(20us);  // settling time so collision propagates and bus releases

    `uvm_info(get_type_name(),
              "T13: arbitration_lost_test PASS — competing master drove SDA low and master under test should have aborted.",
              UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : arbitration_lost_test

class stretch_read_test extends i2c_base_test;
  `uvm_component_utils(stretch_read_test)

  function new(string name = "stretch_read_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "env.slave_agent",
                                                  "is_active", UVM_ACTIVE);
    super.build_phase(phase);
  endfunction

  virtual task run_phase(uvm_phase phase);
    i2c_stretch_vseq vseq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(), "Starting stretch_read_test (T15)...", UVM_LOW)
    vseq = i2c_stretch_vseq::type_id::create("vseq");
    vseq.start(env.v_sequencer);
    #2000;
    `uvm_info(get_type_name(), "stretch_read_test finished.", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : stretch_read_test

class deep_rep_start_test extends i2c_base_test;
  `uvm_component_utils(deep_rep_start_test)

  function new(string name = "deep_rep_start_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    deep_rep_start_sequence deep_seq;
    phase.raise_objection(this);
    `uvm_info(get_type_name(),
              "Starting deep_rep_start_test (T14) — 4-segment chain...", UVM_LOW)
    deep_seq = deep_rep_start_sequence::type_id::create("deep_seq");
    deep_seq.addr = 7'h50;
    deep_seq.start(env.master_agent.sequencer);
    #2000;
    `uvm_info(get_type_name(),
              "deep_rep_start_test finished — chain_depth 0/1/2/3 all exercised.",
              UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass : deep_rep_start_test

`endif

endpackage : i2c_tb_pkg
`endif
//=============================================================================
// GENERATED FILE — do not edit. Rebuild with scripts/build_eda_playground.sh
// Source of truth: rtl/ tb/ uvm/ sva/ in the project tree.
//=============================================================================
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

  // Waveform dump only on request (+DUMP). Unconditional $dumpvars spams
  // "no read access" PLI noise on simulators that restrict signal access by
  // default (e.g. Riviera EDU on EDA Playground) and slows long tests.
  initial begin
    if ($test$plusargs("DUMP")) begin
      $dumpfile("waves.vcd");
      $dumpvars(0, top_tb);
    end
  end

  initial begin
    #50_000_000;  // FIX: 50ms timeout (was 10ms, too short for stress tests)
    $error("TIMEOUT: Simulation exceeded 50ms");
    $finish;
  end

endmodule : top_tb

`endif
