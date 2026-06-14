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
      // SCL stretch detection: the BFM's normal SCL-low phase is
      // BIT_HOLD+BIT_SETUP (~16) cycles, so >64 consecutive LOW cycles
      // means the slave is holding the clock.
      if (vif.scl === 1'b0) scl_low_cnt++;
      else                   scl_low_cnt = 0;
      if (in_transaction && scl_low_cnt > 64 && current_item != null)
        current_item.stretch_seen = 1'b1;

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
        // Track rep-START chain depth for coverage
        if (saw_rep_start) begin
          rep_start_chain_depth++;
          current_item.num_rep_starts = rep_start_chain_depth;
        end else begin
          rep_start_chain_depth = 0;
          current_item.num_rep_starts = 0;
        end
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
          rep_start_chain_depth = 0;
          scl_low_cnt = 0;
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
