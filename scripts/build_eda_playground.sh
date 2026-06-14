#!/bin/bash
#=============================================================================
# build_eda_playground.sh — regenerate the eda_playground/ bundle from the
# canonical rtl/ tb/ uvm/ sva/ sources.
#
# WHY: the bundle used to be maintained by hand and silently diverged from
# the real tree (the audit found the flattened driver/scoreboard were stale).
# Run this script after ANY change to the sources; never edit the bundle
# files directly.
#
# Output files (EDA Playground tab order — see eda_playground/INSTRUCTIONS.md):
#   1. i2c_pkg.sv     — shared package (verbatim copy)
#   2. rtl.sv         — master + slave RTL, concatenated
#   3. if_sva.sv      — interfaces + protocol assertions
#   4. i2c_tb_pkg.sv  — flattened UVM package (include order preserved)
#   5. top_tb.sv      — top module (verbatim copy)
#=============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"
OUT="$PROJ_DIR/eda_playground"

mkdir -p "$OUT"

banner() {
  echo "//============================================================================="
  echo "// GENERATED FILE — do not edit. Rebuild with scripts/build_eda_playground.sh"
  echo "// Source of truth: rtl/ tb/ uvm/ sva/ in the project tree."
  echo "//============================================================================="
}

# --- 1. i2c_pkg.sv -----------------------------------------------------------
{ banner; cat "$PROJ_DIR/rtl/i2c_pkg.sv"; } > "$OUT/i2c_pkg.sv"

# --- 2. rtl.sv ---------------------------------------------------------------
{
  banner
  cat "$PROJ_DIR/rtl/i2c_master_controller.sv"
  echo ""
  cat "$PROJ_DIR/rtl/i2c_master.sv"
  echo ""
  cat "$PROJ_DIR/rtl/i2c_slave_controller.sv"
  echo ""
  cat "$PROJ_DIR/rtl/i2c_slave.sv"
} > "$OUT/rtl.sv"

# --- 3. if_sva.sv ------------------------------------------------------------
{
  banner
  cat "$PROJ_DIR/tb/i2c_if.sv"
  echo ""
  cat "$PROJ_DIR/tb/i2c_slave_if.sv"
  echo ""
  cat "$PROJ_DIR/sva/i2c_protocol_assertions.sv"
} > "$OUT/if_sva.sv"

# --- 4. i2c_tb_pkg.sv (flattened — order mirrors tb/i2c_tb_pkg.sv) -----------
UVM_FILES=(
  i2c_seq_item.sv
  i2c_scoreboard.sv
  i2c_monitor.sv
  i2c_master_driver.sv
  i2c_slave_monitor.sv
  i2c_slave_driver.sv
  i2c_sequences.sv
  i2c_coverage.sv
  i2c_master_agent.sv
  i2c_slave_agent.sv
  i2c_virtual_sequencer.sv
  i2c_virtual_sequence.sv
  i2c_env.sv
  i2c_base_test.sv
  i2c_tests.sv
)

# NOTE: EDA Playground enforces a 100,000-character limit PER FILE. The
# fully-commented flattened package is ~106k, so this one file is emitted in
# compact form: full-line comments stripped, blank runs squeezed (~80k).
# The commented source of truth lives in uvm/ — read it there.
{
  banner
  echo '// NOTE: comments stripped to fit EDA Playground'"'"'s 100k-char file limit.'
  echo '// The fully commented sources are in uvm/ in the project repository.'
  echo '`ifndef I2C_TB_PKG_SV'
  echo '`define I2C_TB_PKG_SV'
  echo 'package i2c_tb_pkg;'
  echo '  import uvm_pkg::*;'
  echo '  `include "uvm_macros.svh"'
  echo '  import i2c_pkg::*;'
  for f in "${UVM_FILES[@]}"; do
    echo ""
    grep -vE '^[[:space:]]*//' "$PROJ_DIR/uvm/$f"
  done | cat -s
  echo ""
  echo 'endpackage : i2c_tb_pkg'
  echo '`endif'
} > "$OUT/i2c_tb_pkg.sv"

# --- 5. top_tb.sv ------------------------------------------------------------
{ banner; cat "$PROJ_DIR/tb/top_tb.sv"; } > "$OUT/top_tb.sv"

# --- Two-tab convenience files -----------------------------------------------
# EDA Playground guarantees design.sv compiles BEFORE testbench.sv, and caps
# every file at 100k chars. These two combos exploit both facts:
#   ep_design.sv    -> paste into the RIGHT pane (design.sv)
#   ep_testbench.sv -> paste into the LEFT pane (testbench.sv)
cat "$OUT/i2c_pkg.sv" "$OUT/rtl.sv" "$OUT/if_sva.sv" > "$OUT/ep_design.sv"
cat "$OUT/i2c_tb_pkg.sv" "$OUT/top_tb.sv"            > "$OUT/ep_testbench.sv"

# --- Remove stale hand-maintained leftovers ----------------------------------
rm -f "$OUT/testbench.sv"

echo "EDA Playground bundle regenerated in $OUT:"
wc -l "$OUT"/i2c_pkg.sv "$OUT"/rtl.sv "$OUT"/if_sva.sv "$OUT"/i2c_tb_pkg.sv "$OUT"/top_tb.sv
echo "Two-tab EP combos (each must be < 100000 chars):"
wc -c "$OUT"/ep_design.sv "$OUT"/ep_testbench.sv
