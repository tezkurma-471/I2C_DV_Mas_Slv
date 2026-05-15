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

  // Monitor-populated fields for enhanced coverage
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

  // FIX: Every I2C transaction MUST begin with START or Repeated START.
  // Without this, random/stress sequences generate impossible bus states.
  // NOTE: stop_cond=1 with rep_start=1 IS valid — it marks the final segment
  // of a repeated-START chain (driver generates REP_START, then ends with STOP).
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
