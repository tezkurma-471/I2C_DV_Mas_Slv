#=============================================================================
# questa_regress.do -- full regression on QuestaSim/ModelSim, no make needed.
#
# Usage (Questa Transcript window, cwd must be sim/):
#   do questa_regress.do            -- QUICK : 19 bus tests x 1 seed + 3 RAL
#   do questa_regress.do full       -- FULL  : 19 bus tests x 3 seeds + 3 RAL
#
# Pass criteria per test (same as sim/Makefile):
#   - no real UVM_ERROR line in the log (summary "UVM_ERROR :" excluded)
#   - AND "SCOREBOARD PASSED" (or the T13 arbitration marker / RAL "TEST PASSED")
#
# Outputs: logs/*.log, coverage/*.ucdb, and a PASS/FAIL summary at the end.
# After this, merge coverage with:   do questa_cov.do
#=============================================================================

if {[info exists 1] && $1 eq "full"} { set SEEDS {1 42 123} } else { set SEEDS {1} }

set TESTS {
  i2c_base_test basic_write_test basic_read_test burst_write_test
  burst_read_test write_read_test rep_start_test addr_nack_test
  data_nack_test clock_stretch_test random_directed_test addr_sweep_test
  bus_free_test sequential_txn_test data_pattern_test full_stress_test
  arbitration_lost_test deep_rep_start_test stretch_read_test
}
set RAL_TESTS { i2c_ral_reset_test i2c_ral_program_test i2c_ral_field_test }

# ---- locate UVM sources (same logic as questa_one.do) ----------------------
set INSTALL_BIN [file dirname [file normalize [info nameofexecutable]]]
set UVM_SRC     [file normalize "$INSTALL_BIN/../verilog_src/uvm-1.2/src"]
if {![file isdirectory $UVM_SRC]} {
  set UVM_SRC [file normalize "$INSTALL_BIN/../../verilog_src/uvm-1.2/src"]
}
puts "UVM_SRC = $UVM_SRC"

file mkdir ../logs
file mkdir ../coverage

# ---- compile BOTH benches once ----------------------------------------------
vlib work
# bus-level bench
vlog -sv -L mtiUvm \
  +incdir+$UVM_SRC +incdir+../uvm +incdir+../tb +incdir+.. \
  ../rtl/i2c_pkg.sv \
  ../rtl/i2c_master_controller.sv \
  ../rtl/i2c_master.sv \
  ../rtl/i2c_slave_controller.sv \
  ../rtl/i2c_slave.sv \
  ../sva/i2c_protocol_assertions.sv \
  ../tb/i2c_if.sv \
  ../tb/i2c_slave_if.sv \
  ../tb/i2c_tb_pkg.sv \
  ../tb/top_tb.sv
# RAL bench (separate top)
vlog -sv -L mtiUvm \
  +incdir+$UVM_SRC +incdir+../uvm +incdir+../tb +incdir+../ral +incdir+.. \
  ../tb/i2c_reg_if.sv \
  ../tb/i2c_tb_ral_pkg.sv \
  ../tb/top_tb_ral.sv

# ---- helpers -----------------------------------------------------------------
proc run_one {top test seed} {
  transcript file ../logs/${test}_seed${seed}.log
  vsim -coverage -voptargs=+acc -L mtiUvm work.$top \
       +UVM_TESTNAME=$test +UVM_VERBOSITY=UVM_LOW -sv_seed $seed
  run -all
  coverage save ../coverage/${test}_seed${seed}.ucdb
  quit -sim
  transcript file ""
}

proc judge {test seed kind} {
  set fname ../logs/${test}_seed${seed}.log
  if {[catch {set fh [open $fname r]}]} { return "FAIL (no log)" }
  set data [read $fh]; close $fh
  set bad 0
  foreach line [split $data "\n"] {
    if {[string match "*UVM_ERROR*" $line] && ![string match "*UVM_ERROR :*" $line]} {
      set bad 1
    }
  }
  if {$bad} { return "FAIL (UVM_ERROR in log)" }
  if {$kind eq "ral"} {
    if {[string match "*TEST PASSED*" $data]} { return PASS }
    return "FAIL (no TEST PASSED marker)"
  }
  if {[string match "*SCOREBOARD PASSED*" $data]} { return PASS }
  if {[string match "*T13: arbitration_lost_test PASS*" $data]} { return PASS }
  return "FAIL (no pass marker)"
}

# ---- run ----------------------------------------------------------------------
set results {}
set pass 0
set fail 0

foreach t $TESTS {
  foreach s $SEEDS {
    puts "--- Running: $t (seed=$s) ---"
    run_one top_tb $t $s
    set verdict [judge $t $s bus]
    if {$verdict eq "PASS"} { incr pass } else { incr fail }
    lappend results [format "%-7s %-28s seed=%s" $verdict $t $s]
  }
}

foreach t $RAL_TESTS {
  puts "--- Running RAL: $t ---"
  run_one top_tb_ral $t 1
  set verdict [judge $t 1 ral]
  if {$verdict eq "PASS"} { incr pass } else { incr fail }
  lappend results [format "%-7s %-28s seed=1" $verdict $t]
}

# ---- summary -------------------------------------------------------------------
puts "\n=============================================================="
puts " REGRESSION SUMMARY"
puts "=============================================================="
foreach r $results { puts " $r" }
puts "--------------------------------------------------------------"
puts " Total: [expr {$pass + $fail}]   Passed: $pass   Failed: $fail"
puts "=============================================================="
puts " Logs in logs/ -- UCDBs in coverage/ -- next: do questa_cov.do"
