#!/bin/bash
#=============================================================================
# coverage_report.sh — Generate coverage report for I2C project
# Usage: ./coverage_report.sh
#=============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Generating Coverage Report ==="

cd "$PROJ_DIR/sim"

if ls *.ucdb 1>/dev/null 2>&1; then
  vcover merge -out merged.ucdb *.ucdb
  vcover report -html merged.ucdb -output coverage_report/
  vcover report -text merged.ucdb > coverage_summary.txt
  echo "Coverage report generated in: sim/coverage_report/"
  echo "Text summary: sim/coverage_summary.txt"
  echo ""
  echo "=== Coverage Summary ==="
  head -30 coverage_summary.txt
else
  echo "No .ucdb files found. Run regression with coverage first."
  echo "Example: vsim -c top_tb +UVM_TESTNAME=basic_write_test -coverage -do 'run -all; quit'"
fi
