#!/bin/bash
#=============================================================================
# run_all_tests.sh — Run full regression of all 19 I2C tests
# Usage: ./run_all_tests.sh [questa|vcs|xcelium] [seed]
# NOTE: keep this list in sync with TESTS in sim/Makefile.
#=============================================================================

set -e

TOOL=${1:-questa}
SEED=${2:-1}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

TESTS=(
  i2c_base_test
  basic_write_test
  basic_read_test
  burst_write_test
  burst_read_test
  write_read_test
  rep_start_test
  addr_nack_test
  data_nack_test
  clock_stretch_test
  random_directed_test
  addr_sweep_test
  bus_free_test
  sequential_txn_test
  data_pattern_test
  full_stress_test
  arbitration_lost_test
  deep_rep_start_test
  stretch_read_test
)

echo "=============================================="
echo " I2C UVM Full Regression"
echo " Tool: $TOOL | Seed: $SEED"
echo " Tests: ${#TESTS[@]}"
echo "=============================================="

# Compile first
echo ">>> Compiling..."
$SCRIPT_DIR/compile.sh $TOOL

PASS=0
FAIL=0

for test in "${TESTS[@]}"; do
  echo ""
  echo ">>> Running: $test (seed=$SEED)"

  case $TOOL in
    questa)
      vsim -c top_tb +UVM_TESTNAME=$test +UVM_VERBOSITY=UVM_LOW \
        -sv_seed $SEED \
        -do "run -all; quit" > "${test}.log" 2>&1 || true
      ;;
    vcs)
      ./simv +UVM_TESTNAME=$test +UVM_VERBOSITY=UVM_LOW \
        +ntb_random_seed=$SEED > "${test}.log" 2>&1 || true
      ;;
    xcelium)
      xrun -R +UVM_TESTNAME=$test +UVM_VERBOSITY=UVM_LOW \
        -svseed $SEED > "${test}.log" 2>&1 || true
      ;;
  esac

  # Pass criteria: no real UVM_ERROR lines (the "UVM_ERROR :  N" summary
  # line is excluded), and either SCOREBOARD PASSED or the T13 marker.
  if grep "UVM_ERROR" "${test}.log" 2>/dev/null | grep -v "UVM_ERROR :" | grep -q . ; then
    echo "    FAIL: $test (UVM_ERROR in log)"
    FAIL=$((FAIL+1))
  elif grep -q "SCOREBOARD PASSED" "${test}.log" 2>/dev/null \
    || grep -q "T13: arbitration_lost_test PASS" "${test}.log" 2>/dev/null; then
    echo "    PASS: $test"
    PASS=$((PASS+1))
  else
    echo "    FAIL: $test"
    FAIL=$((FAIL+1))
  fi
done

echo ""
echo "=============================================="
echo " REGRESSION SUMMARY"
echo "=============================================="
echo "  Total : ${#TESTS[@]}"
echo "  Pass  : $PASS"
echo "  Fail  : $FAIL"
echo "=============================================="

if [ $FAIL -eq 0 ]; then
  echo "  ALL TESTS PASSED!"
else
  echo "  SOME TESTS FAILED — check individual logs"
fi
