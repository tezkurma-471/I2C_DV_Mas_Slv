#!/bin/bash
#=============================================================================
# compile.sh — Compile I2C UVM Verification Project
# Usage: ./compile.sh [questa|xcelium|vcs]
#=============================================================================

set -e

TOOL=${1:-questa}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== I2C UVM Project Compilation ==="
echo "Tool: $TOOL"
echo "Project dir: $PROJ_DIR"

case $TOOL in
  questa)
    if [ -z "$MODEL_TECH" ]; then
      echo "ERROR: MODEL_TECH not set. Source QuestaSim setup script."
      exit 1
    fi
    UVM_HOME="${UVM_HOME:-$MODEL_TECH/../verilog_src/uvm-1.2}"
    cd "$PROJ_DIR/sim"
    vlib work
    vlog +incdir+$UVM_HOME/src $UVM_HOME/src/uvm_pkg.sv \
         +incdir+$PROJ_DIR/uvm +incdir+$PROJ_DIR/tb -sv \
         $PROJ_DIR/rtl/i2c_pkg.sv \
         $PROJ_DIR/rtl/i2c_master_controller.sv \
         $PROJ_DIR/rtl/i2c_master.sv \
         $PROJ_DIR/rtl/i2c_slave_controller.sv \
         $PROJ_DIR/rtl/i2c_slave.sv \
         $PROJ_DIR/sva/i2c_protocol_assertions.sv \
         $PROJ_DIR/tb/i2c_if.sv \
         $PROJ_DIR/tb/i2c_slave_if.sv \
         $PROJ_DIR/tb/i2c_tb_pkg.sv \
         $PROJ_DIR/tb/top_tb.sv
    echo "=== QuestaSim compilation complete ==="
    ;;

  vcs)
    cd "$PROJ_DIR/sim"
    vcs -sverilog -ntb_opts uvm-1.2 \
        +incdir+$PROJ_DIR/uvm +incdir+$PROJ_DIR/tb \
        $PROJ_DIR/rtl/i2c_pkg.sv \
        $PROJ_DIR/rtl/i2c_master_controller.sv \
        $PROJ_DIR/rtl/i2c_master.sv \
        $PROJ_DIR/rtl/i2c_slave_controller.sv \
        $PROJ_DIR/rtl/i2c_slave.sv \
        $PROJ_DIR/sva/i2c_protocol_assertions.sv \
        $PROJ_DIR/tb/i2c_if.sv \
        $PROJ_DIR/tb/i2c_slave_if.sv \
        $PROJ_DIR/tb/i2c_tb_pkg.sv \
        $PROJ_DIR/tb/top_tb.sv \
        -top top_tb
    echo "=== VCS compilation complete ==="
    ;;

  xcelium)
    cd "$PROJ_DIR/sim"
    xrun -sverilog -uvm -uvmhome $UVM_HOME \
         +incdir+$PROJ_DIR/uvm +incdir+$PROJ_DIR/tb \
         $PROJ_DIR/rtl/i2c_pkg.sv \
         $PROJ_DIR/rtl/i2c_master_controller.sv \
         $PROJ_DIR/rtl/i2c_master.sv \
         $PROJ_DIR/rtl/i2c_slave_controller.sv \
         $PROJ_DIR/rtl/i2c_slave.sv \
         $PROJ_DIR/sva/i2c_protocol_assertions.sv \
         $PROJ_DIR/tb/i2c_if.sv \
         $PROJ_DIR/tb/i2c_slave_if.sv \
         $PROJ_DIR/tb/i2c_tb_pkg.sv \
         $PROJ_DIR/tb/top_tb.sv
    echo "=== Xcelium compilation complete ==="
    ;;

  *)
    echo "ERROR: Unknown tool '$TOOL'. Use: questa, vcs, or xcelium"
    exit 1
    ;;
esac
