//=============================================================================
// File          : i2c_tb_pkg.sv
// Description   : UVM Testbench Package — single include point for all
//               : UVM components. Import this in top_tb.sv before run_test().
// Language      : SystemVerilog (IEEE 1800-2012) + UVM 1.2
//=============================================================================

`ifndef I2C_TB_PKG_SV
`define I2C_TB_PKG_SV

package i2c_tb_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import i2c_pkg::*;

  // 1. Transaction object
  `include "i2c_seq_item.sv"

  // 2. Scoreboard
  `include "i2c_scoreboard.sv"

  // 3. Monitor
  `include "i2c_monitor.sv"

  // 4. Driver
  `include "i2c_master_driver.sv"

  // 5. Slave monitor + driver + status/control items
  `include "i2c_slave_monitor.sv"
  `include "i2c_slave_driver.sv"

  // 6. Sequences (must come before agent/tests)
  `include "i2c_sequences.sv"

  // 7. Coverage collector
  `include "i2c_coverage.sv"

  // 8. Agents
  `include "i2c_master_agent.sv"
  `include "i2c_slave_agent.sv"

  // 8.5 Virtual Sequencer & Sequences
  `include "i2c_virtual_sequencer.sv"
  `include "i2c_virtual_sequence.sv"

  // 9. Environment
  `include "i2c_env.sv"

  // 10. Base test
  `include "i2c_base_test.sv"

  // 11. All specific tests
  `include "i2c_tests.sv"

endpackage : i2c_tb_pkg

`endif
