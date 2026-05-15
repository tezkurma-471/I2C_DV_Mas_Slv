//=============================================================================
// File          : i2c_coverage.sv
// Description   : UVM Functional Coverage Collector for I2C Verification
//               : V3: 8 covergroups for comprehensive coverage
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_COVERAGE_SV
`define I2C_COVERAGE_SV

class i2c_coverage extends uvm_subscriber #(i2c_seq_item);
  `uvm_component_utils(i2c_coverage)

  i2c_seq_item item;
  bit has_data_nack;  // computed in write() from byte_ack[] queue

  // 1. Transaction Direction
  covergroup i2c_dir_cg;
    option.per_instance = 1;
    option.name = "Direction";
    cp_dir: coverpoint item.dir {
      bins write = {DIR_WRITE};
      bins read  = {DIR_READ};
    }
  endgroup

  // 2. Data Size (Burst lengths)
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

  // 3. Address Types
  covergroup i2c_addr_cg;
    option.per_instance = 1;
    option.name = "Address";
    cp_addr: coverpoint item.addr {
      bins target_addr = {7'h50};
      bins other_addrs = {[7'h08:7'h4F], [7'h51:7'h77]};
    }
  endgroup

  // 4. Protocol Conditions
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

  // 5. ACK/NACK Tracking
  covergroup i2c_ack_cg;
    option.per_instance = 1;
    option.name = "ACK Responses";
    cp_addr_ack: coverpoint item.addr_ack {
      bins ack  = {1};
      bins nack = {0};
    }
  endgroup

  // 6. Cross Coverage: Direction x Size
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

  // 7. Register Bank Coverage — how many registers are touched per transaction.
  // FIX BUG #13: Previous version covered item.data[0] value (0-255 data ranges)
  // mislabeled as "Register Access". Since reg_ptr is internal to DUT and not
  // exposed in seq_item, we cover burst length (num_data) for write transactions,
  // which determines how many register slots are written starting from ptr=0.
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

  // 8. Cross Coverage: Target Address x Direction
  covergroup i2c_target_cg;
    option.per_instance = 1;
    option.name = "Target Cross";
    cp_addr: coverpoint item.addr { bins target = {7'h50}; }
    cp_dir: coverpoint item.dir;
    cross cp_addr, cp_dir;
  endgroup

  // 9. Per-Byte ACK/NACK Tracking
  // Closes hole: byte_ack[] existed in seq_item but was never measured in coverage
  covergroup i2c_byte_nack_cg;
    option.per_instance = 1;
    option.name = "Per-Byte NACK";
    cp_byte_nack: coverpoint has_data_nack {
      bins all_bytes_ack  = {0};   // every data byte was ACK'd
      bins data_nack_seen = {1};   // at least one data byte NACK'd (data_nack_test)
    }
  endgroup

  // 10. Clock Stretch Coverage
  // Closes hole: clock_stretch_test exercised stretch but coverage never measured it
  covergroup i2c_stretch_cg;
    option.per_instance = 1;
    option.name = "Clock Stretch";
    cp_stretch: coverpoint item.stretch_seen {
      bins no_stretch       = {0};  // normal SCL timing
      bins stretch_seen_bin = {1};  // SCL held LOW > T_SCL_LOW+10 cycles by slave
    }
  endgroup

  // 11. Repeated START Chain Depth
  // Closes hole: rep_start was yes/no; now measures HOW DEEP the chain goes
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

  // 12. Cross: Direction x Address Range
  // Catches: reads only tested on target addr, writes on all addresses?
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

  // 13. Cross: Direction x ACK Result
  // Catches: all 4 combos needed — write+ack, write+nack, read+ack, read+nack
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

  // 14. Cross: Repeated START x Direction
  // Catches: rep_start for write->write, write->read, read->write, read->read
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

  // 15. Cross: Direction x Data Size (Refined)
  // Catches: burst reads of 17-32 bytes never tested? read+xlarge gap?
  covergroup i2c_dir_size_cross_cg;
    option.per_instance = 1;
    option.name = "Dir x Data Size";
    cp_dir: coverpoint item.dir;
    cp_size: coverpoint item.num_data {
      bins single  = {1};
      bins small   = {[2:4]};
      bins medium  = {[5:8]};
      bins large   = {[9:16]};
      bins xlarge  = {[17:32]};
    }
    cross cp_dir, cp_size;
  endgroup

  // 16. Cross: Protocol Flags x Direction
  // Catches: is STOP always present? rep_start in both read and write directions?
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

  // 17. Cross Coverage: Clock Stretch x Direction
  // Catches: clock stretch exercised in BOTH read and write directions?
  // clock_stretch_test only drives writes — stretch+read is an untested corner.
  // A slave holding SCL low during a READ is equally valid and must be verified.
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
    // Compute derived coverage flag from per-byte ACK queue
    has_data_nack = 0;
    foreach (t.byte_ack[i]) if (t.byte_ack[i] == 1'b0) has_data_nack = 1;
    // Sample all covergroups
    i2c_dir_cg.sample();
    i2c_data_size_cg.sample();
    i2c_addr_cg.sample();
    i2c_protocol_cg.sample();
    i2c_ack_cg.sample();
    i2c_burst_cg.sample();
    if (t.num_data > 0) i2c_reg_ptr_cg.sample();
    if (t.addr == 7'h50) i2c_target_cg.sample();
    // New covergroups (CG9-CG16)
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
    real dir_cov   = i2c_dir_cg.get_coverage();
    real size_cov  = i2c_data_size_cg.get_coverage();
    real ack_cov   = i2c_ack_cg.get_coverage();
    real burst_cov = i2c_burst_cg.get_coverage();
    real avg_cov   = (dir_cov + size_cov + ack_cov + burst_cov) / 4.0;
    
    super.report_phase(phase);
    `uvm_info(get_type_name(), 
              $sformatf("\n--- COVERAGE SUMMARY ---\nDir: %0.2f%%\nSize: %0.2f%%\nACK: %0.2f%%\nBurst: %0.2f%%\nAVG: %0.2f%%\n------------------------", 
                        dir_cov, size_cov, ack_cov, burst_cov, avg_cov), UVM_LOW)
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
