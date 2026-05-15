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
