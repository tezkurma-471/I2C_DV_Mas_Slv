//=============================================================================
// File          : i2c_scoreboard.sv (FIXED v3)
// Description   : UVM Scoreboard — True Self-Checking Reference Model
//               : V3 fixes (post-audit):
//               :  - WRITE DATA IS NOW CHECKED. The old write_actual path did
//               :    `match_count++` for writes without comparing a single
//               :    byte — a corrupted write could never fail a test.
//               :  - Expected (driver) and actual (monitor) streams are
//               :    queued and matched in order when BOTH sides are present,
//               :    so analysis-port arrival order no longer matters.
//               :  - The shadow register bank is updated from the MONITOR
//               :    (what was really on the wire), not from driver intent.
//               :  - check_phase() flags unconsumed leftovers in either queue.
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

  // In-order pending queues — matched pairwise as soon as both sides have an
  // entry. This is robust against either stream arriving first.
  i2c_seq_item exp_q [$];
  i2c_seq_item act_q [$];

  // Shadow of the DUT's 8-register bank, built from observed bus traffic.
  // NOTE on semantics: the DUT commits a received byte even when it was
  // force-NACKed (force_data_nack does not gate the register write), so the
  // shadow stores every observed write byte to the matching address.
  logic [7:0] ref_reg_bank [0:7];

  int expected_count;
  int actual_count;
  int error_count;
  int match_count;

  // Set (via config_db) ONLY by tests that corrupt the bus on purpose, e.g.
  // arbitration_lost_test's competing master. Suppresses intent-vs-wire
  // comparison for the corrupted traffic.
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

  // Pop and compare as long as both streams have a pending transaction
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

    // ---- Framing: address, direction ------------------------------------
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

    // ---- Address ACK: only the real slave address may be ACKed ----------
    check_address_ack(act);

    // ---- ACK consistency between the two observation points -------------
    if (exp.addr_ack !== act.addr_ack) begin
      `uvm_error(get_type_name(),
                 $sformatf("ADDR_ACK INCONSISTENT: driver sampled %0b, monitor saw %0b",
                           exp.addr_ack, act.addr_ack))
      error_count++; pair_ok = 0;
    end

    // ---- Payload ---------------------------------------------------------
    if (!exp.addr_ack) begin
      // NACK-aborted: nothing may have been driven after the address byte
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
        // FIX (the big one): byte-for-byte data check for BOTH directions.
        // Writes: intent (driver) vs wire (monitor).
        // Reads : data the driver sampled vs data the monitor saw the slave
        //         drive — and below, the wire data vs the shadow model.
        foreach (exp.data[i]) begin
          if (exp.data[i] !== act.data[i]) begin
            `uvm_error(get_type_name(),
                       $sformatf("%s DATA MISMATCH byte[%0d]: driver 0x%02x vs monitor 0x%02x",
                                 exp.dir.name(), i, exp.data[i], act.data[i]))
            error_count++; pair_ok = 0;
          end
        end
      end

      // ---- Reference-model check / update (target slave only) -----------
      if (act.addr == 7'h50 && act.addr_ack) begin
        if (act.dir == DIR_READ) begin
          // The DUT resets its reg_ptr on every address ACK, so every read
          // transaction streams from register 0.
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
          // Update shadow from what was REALLY on the wire
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

  // End-of-test: anything still queued means a lost/extra transaction
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
