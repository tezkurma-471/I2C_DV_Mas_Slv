#=============================================================================
# questa_one.do -- compile everything and run ONE test on QuestaSim/ModelSim.
#
# No make, no bash needed -- this runs inside Questa's own Tcl shell.
#
# Usage (type in the Questa "Transcript" window, cwd must be sim/):
#   do questa_one.do                       -- runs basic_write_test
#   do questa_one.do clock_stretch_test    -- runs that test instead
#   do questa_one.do rep_start_test 42     -- optional second arg = seed
#
# Outputs:
#   logs/<test>_seed<seed>.log
#   coverage/<test>_seed<seed>.ucdb
#=============================================================================

if {[info exists 1]} { set TESTNAME $1 } else { set TESTNAME basic_write_test }
if {[info exists 2]} { set SEED $2 }     else { set SEED 1 }

# ---- locate the UVM 1.2 sources shipped inside the Questa install ----------
# (needed for `include "uvm_macros.svh"`; the compiled uvm_pkg comes from the
#  precompiled mtiUvm library)
set INSTALL_BIN [file dirname [file normalize [info nameofexecutable]]]
set UVM_SRC     [file normalize "$INSTALL_BIN/../verilog_src/uvm-1.2/src"]
if {![file isdirectory $UVM_SRC]} {
  set UVM_SRC [file normalize "$INSTALL_BIN/../../verilog_src/uvm-1.2/src"]
}
if {![file isdirectory $UVM_SRC]} {
  puts "WARNING: could not auto-find UVM sources. Find the folder"
  puts "  <questa_install>/verilog_src/uvm-1.2/src on this machine and run:"
  puts "  set UVM_SRC {C:/path/to/verilog_src/uvm-1.2/src}; do questa_one.do"
} else {
  puts "UVM_SRC = $UVM_SRC"
}

file mkdir ../logs
file mkdir ../coverage

# ---- compile ----------------------------------------------------------------
vlib work
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

# If the vlog above fails with "mtiUvm not found" (very old/odd installs),
# comment it out and use this instead (compiles UVM 1.2 from source):
#
# vlog -sv +define+UVM_NO_DPI \
#   +incdir+$UVM_SRC $UVM_SRC/uvm_pkg.sv \
#   +incdir+../uvm +incdir+../tb +incdir+.. \
#   ../rtl/i2c_pkg.sv ../rtl/i2c_master_controller.sv ../rtl/i2c_master.sv \
#   ../rtl/i2c_slave_controller.sv ../rtl/i2c_slave.sv \
#   ../sva/i2c_protocol_assertions.sv \
#   ../tb/i2c_if.sv ../tb/i2c_slave_if.sv ../tb/i2c_tb_pkg.sv ../tb/top_tb.sv

# ---- simulate ----------------------------------------------------------------
transcript file ../logs/${TESTNAME}_seed${SEED}.log
vsim -coverage -voptargs=+acc -L mtiUvm work.top_tb \
     +UVM_TESTNAME=$TESTNAME +UVM_VERBOSITY=UVM_MEDIUM -sv_seed $SEED
run -all
coverage save ../coverage/${TESTNAME}_seed${SEED}.ucdb
quit -sim
transcript file ""

puts "=============================================================="
puts " Done: $TESTNAME (seed $SEED)"
puts " Log : logs/${TESTNAME}_seed${SEED}.log"
puts " Look for: 'SCOREBOARD PASSED' and 'UVM_ERROR :    0'"
puts "=============================================================="
