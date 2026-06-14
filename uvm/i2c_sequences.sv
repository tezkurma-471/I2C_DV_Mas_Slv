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

  // Drive a 2-segment repeated-START chain (segment A: START, no STOP;
  // segment B: Sr + STOP, random direction). Used by the random/stress
  // sequences so rep-start protocol framing is part of constrained-random
  // coverage instead of only appearing in directed tests.
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

  // FIX (EP live-run): these MUST be non-rand fields with defaults, not
  // `rand` + a `default_addr_c` constraint. A constraint only applies when
  // the SEQUENCE itself is randomized; virtual sequences start this seq via
  // .start() WITHOUT randomizing it, leaving addr=0 — which then violates the
  // item's valid_addr_c (addr != 0) and fatals. A default-valued field works
  // in both the directed-test path (which sets it) and the vseq path.
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

  // FIX (EP live-run): non-rand default, see i2c_single_write_seq above —
  // a rand field + constraint is not applied when started via a vseq.
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
    // FIX (EP live-run): default_trans_c pins start=1/stop=1/rep=0. The first
    // segment needs stop_cond=0 and the second needs start_cond=0/rep_start=1,
    // both of which CONFLICT with default_trans_c — so it must be disabled
    // per item (exactly as deep_rep_start_sequence already does). Without
    // this the randomize() is unsatisfiable and fatals.
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

  // NOTE: the stretch duration is owned by the SLAVE-side control sequence
  // (i2c_slave_stretch_ctrl_seq). The old `stretch_cycles` field here was
  // randomized and silently ignored — removed.
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
      // FIX: default_trans_c pins start=1/stop=1/rep=0, so plain randomize()
      // could never produce a repeated START. ~25% of iterations now drive a
      // 2-segment Sr chain instead.
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
      // FIX: include repeated-START chains in the stress profile (~25%).
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
    // FIX (EP live-run): the item's stretch_cycles_c forces stretch_cycles
    // into [1:500]; the inline stretch_cycles==0 below CONFLICTS with it and
    // fatals. stretch_cycles is don't-care here (stretch_en==0), so disable
    // that constraint and pin it to 0 for cleanliness.
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

  // Range must comfortably exceed the monitor's 64-cycle stretch-detection
  // threshold and stay far below MAX_CLK_STRETCH (1000).
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

//=============================================================================
// T13: arb_lost_sequence
// Drives a write transaction whose data byte (0xAA) WILL collide with the
// competing master pulled low by the slave driver in compete_mode. The
// master under test should detect arb_lost during STATE_TX_BIT and abort
// the transaction cleanly without producing a STOP.
//=============================================================================
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

//=============================================================================
// T14: deep_rep_start_sequence
// Sends a 4-segment repeated-START chain to close CG11 (i2c_rep_depth_cg):
//   seg0: fresh START, write, no STOP  → chain_depth=0  (no_rep  bin)
//   seg1: REP_START,   write, no STOP  → chain_depth=1  (one_rep  bin)
//   seg2: REP_START,   write, no STOP  → chain_depth=2  (two_rep  bin)
//   seg3: REP_START,   read,  STOP     → chain_depth=3  (deep_rep bin)
//
// All 4 depth bins are exercised in a single test run.
// Also exercises CG14 (RepStart x Dir) with write→write→write→read pattern,
// and CG16 (Protocol x Dir) with no_stop+write and has_stop+read cells.
//
// Why default_trans_c is disabled: that constraint hard-codes start_cond=1,
// stop_cond=1, rep_start=0 for every item. Middle segments need stop_cond=0
// and final segments need rep_start=1, so we turn it off per-item and
// specify protocol fields explicitly via inline constraints.
//=============================================================================
class deep_rep_start_sequence extends i2c_base_seq;

  `uvm_object_utils(deep_rep_start_sequence)

  logic [6:0] addr = 7'h50;

  function new(string name = "deep_rep_start_sequence");
    super.new(name);
  endfunction

  task body();
    i2c_seq_item seg0, seg1, seg2, seg3;

    // --- Segment 0: fresh START, write, no STOP — begins the rep-start chain ---
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

    // --- Segment 1: REP_START, write, no STOP — chain_depth=1 ---
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

    // --- Segment 2: REP_START, write, no STOP — chain_depth=2 ---
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

    // --- Segment 3: REP_START, read, STOP — chain_depth=3 — end of chain ---
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
