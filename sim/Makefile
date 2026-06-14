#=============================================================================
# Makefile : I2C UVM Verification Project
# Supports  : QuestaSim (vlog/vsim) for UVM; Icarus Verilog for the RTL smoke
# V3 (post-audit):
#   - Coverage flow fixed end-to-end: every sim/regress run saves its UCDB
#     into $(COV_DIR), and `make cov` merges from the same place. (The old
#     flow saved into sim/ but merged from logs/ — it could never work.)
#   - Pass criteria now FAIL a test on any real UVM_ERROR line (which now
#     includes SVA failures, routed through uvm_report_error), instead of
#     only grepping for "SCOREBOARD PASSED".
#   - RAL bench (top_tb_ral + i2c_tb_ral_pkg) is part of the build:
#     `make compile_ral` / `make sim_ral` / `make regress_ral`.
#   - `make smoke` runs the pure-SV master<->slave RTL integration test
#     under Icarus Verilog (no license needed).
#=============================================================================

SIM_TOOL  ?= questa

PROJ_DIR  := ..
RTL_DIR   := ../rtl
TB_DIR    := ../tb
UVM_DIR   := ../uvm
SVA_DIR   := ../sva
RAL_DIR   := ../ral
LOG_DIR   := ../logs
COV_DIR   := ../coverage

UVM_HOME  ?= $(MODEL_TECH)/../verilog_src/uvm-1.2

VLOG_OPTS  = +incdir+$(UVM_HOME)/src $(UVM_HOME)/src/uvm_pkg.sv
VLOG_OPTS += +incdir+$(UVM_DIR)
VLOG_OPTS += +incdir+$(TB_DIR)
VLOG_OPTS += +incdir+$(PROJ_DIR)
VLOG_OPTS += -sv -coverassert -coverfsm -covertoggle -coverbc

TEST      ?= i2c_base_test
SEED      ?= 1
RAL_TEST  ?= i2c_ral_reset_test

RTL_SRCS = \
  $(RTL_DIR)/i2c_pkg.sv               \
  $(RTL_DIR)/i2c_master_controller.sv \
  $(RTL_DIR)/i2c_master.sv            \
  $(RTL_DIR)/i2c_slave_controller.sv  \
  $(RTL_DIR)/i2c_slave.sv

#-----------------------------------------------------------------------------
# Compile all sources (main bus-level bench)
#-----------------------------------------------------------------------------
.PHONY: compile
compile:
	@echo "=== Compiling I2C Project (bus-level bench) ==="
	@if [ ! -d "work" ]; then vlib work; fi
	vlog $(VLOG_OPTS) \
	  $(RTL_SRCS)                          \
	  $(SVA_DIR)/i2c_protocol_assertions.sv \
	  $(TB_DIR)/i2c_if.sv                  \
	  $(TB_DIR)/i2c_slave_if.sv            \
	  $(TB_DIR)/i2c_tb_pkg.sv              \
	  $(TB_DIR)/top_tb.sv
	@echo "=== Compilation Complete ==="

#-----------------------------------------------------------------------------
# Compile the RAL bench (register-level bench, separate top)
#-----------------------------------------------------------------------------
.PHONY: compile_ral
compile_ral:
	@echo "=== Compiling I2C Project (RAL bench) ==="
	@if [ ! -d "work" ]; then vlib work; fi
	vlog $(VLOG_OPTS) \
	  $(RTL_SRCS)                  \
	  $(TB_DIR)/i2c_reg_if.sv      \
	  $(TB_DIR)/i2c_tb_ral_pkg.sv  \
	  $(TB_DIR)/top_tb_ral.sv
	@echo "=== RAL Compilation Complete ==="

#-----------------------------------------------------------------------------
# Run a single test
#-----------------------------------------------------------------------------
.PHONY: sim
sim: compile
	@mkdir -p $(LOG_DIR) $(COV_DIR)
	@echo "=== Running Test: $(TEST) (seed=$(SEED)) ==="
	vsim -c top_tb \
	  +UVM_TESTNAME=$(TEST)              \
	  +UVM_VERBOSITY=UVM_MEDIUM          \
	  -sv_seed $(SEED)                   \
	  -coverall                          \
	  -do "run -all; coverage save -onexit $(COV_DIR)/$(TEST)_seed$(SEED).ucdb; quit -code [coverage attribute -name TESTSTATUS -concise]" \
	  -l $(LOG_DIR)/$(TEST)_seed$(SEED).log
	@echo "=== Log: $(LOG_DIR)/$(TEST)_seed$(SEED).log ==="

#-----------------------------------------------------------------------------
# Run a single RAL test
#-----------------------------------------------------------------------------
.PHONY: sim_ral
sim_ral: compile_ral
	@mkdir -p $(LOG_DIR) $(COV_DIR)
	@echo "=== Running RAL Test: $(RAL_TEST) (seed=$(SEED)) ==="
	vsim -c top_tb_ral \
	  +UVM_TESTNAME=$(RAL_TEST)          \
	  +UVM_VERBOSITY=UVM_MEDIUM          \
	  -sv_seed $(SEED)                   \
	  -coverall                          \
	  -do "run -all; coverage save -onexit $(COV_DIR)/$(RAL_TEST)_seed$(SEED).ucdb; quit -code [coverage attribute -name TESTSTATUS -concise]" \
	  -l $(LOG_DIR)/$(RAL_TEST)_seed$(SEED).log
	@echo "=== Log: $(LOG_DIR)/$(RAL_TEST)_seed$(SEED).log ==="

#-----------------------------------------------------------------------------
# Run with GUI (waveform viewer)
#-----------------------------------------------------------------------------
.PHONY: gui
gui: compile
	vsim top_tb \
	  +UVM_TESTNAME=$(TEST)              \
	  +UVM_VERBOSITY=UVM_HIGH            \
	  -sv_seed $(SEED)

#-----------------------------------------------------------------------------
# RTL smoke test (Icarus Verilog — no license needed)
# Pure-SV master<->slave integration: burst write/read, NACK, stretch, Sr.
#-----------------------------------------------------------------------------
.PHONY: smoke
smoke:
	@echo "=== RTL smoke test (Icarus Verilog) ==="
	iverilog -g2012 -s tb_rtl_smoke -o i2c_rtl_smoke \
	  $(RTL_SRCS) $(TB_DIR)/tb_rtl_smoke.sv
	vvp i2c_rtl_smoke
	@rm -f i2c_rtl_smoke

#-----------------------------------------------------------------------------
# Regression: all bus-level tests x multiple seeds
#
# Pass criteria (per run):
#   1. NO real UVM_ERROR lines in the log. (SVA failures count: they are
#      reported via uvm_report_error. The summary line "UVM_ERROR :  N" is
#      excluded from the grep.)
#   2. AND either "SCOREBOARD PASSED" or the T13 exception-flow marker.
#-----------------------------------------------------------------------------
TESTS = i2c_base_test basic_write_test basic_read_test burst_write_test burst_read_test \
        write_read_test rep_start_test addr_nack_test data_nack_test \
        clock_stretch_test random_directed_test addr_sweep_test \
        bus_free_test sequential_txn_test data_pattern_test full_stress_test \
        arbitration_lost_test deep_rep_start_test stretch_read_test

RAL_TESTS = i2c_ral_reset_test i2c_ral_program_test i2c_ral_field_test

SEEDS = 1 42 123

.PHONY: regress
regress: compile
	@mkdir -p $(LOG_DIR) $(COV_DIR)
	@echo "=== Running Full Regression ==="
	@pass=0; fail=0; total=0; \
	for test in $(TESTS); do \
	  for seed in $(SEEDS); do \
	    total=$$((total+1)); \
	    log=$(LOG_DIR)/$${test}_seed$${seed}.log; \
	    echo "--- Running: $$test (seed=$$seed) ---"; \
	    vsim -c top_tb +UVM_TESTNAME=$$test +UVM_VERBOSITY=UVM_LOW \
	      -sv_seed $$seed -coverall \
	      -do "run -all; coverage save -onexit $(COV_DIR)/$${test}_seed$${seed}.ucdb; quit -code [coverage attribute -name TESTSTATUS -concise]" \
	      -l $$log 2>&1 | tail -3; \
	    if grep "UVM_ERROR" $$log | grep -v "UVM_ERROR :" | grep -q . ; then \
	      echo "  FAIL: $$test (seed=$$seed) [UVM_ERROR in log]"; fail=$$((fail+1)); \
	    elif grep -q "SCOREBOARD PASSED" $$log 2>/dev/null; then \
	      echo "  PASS: $$test (seed=$$seed)"; pass=$$((pass+1)); \
	    elif grep -q "T13: arbitration_lost_test PASS" $$log 2>/dev/null; then \
	      echo "  PASS: $$test (seed=$$seed) [T13 exception-flow]"; pass=$$((pass+1)); \
	    else \
	      echo "  FAIL: $$test (seed=$$seed)"; fail=$$((fail+1)); \
	    fi; \
	  done; \
	done; \
	echo ""; \
	echo "========================================"; \
	echo "  REGRESSION SUMMARY"; \
	echo "  Total  : $$total"; \
	echo "  Passed : $$pass"; \
	echo "  Failed : $$fail"; \
	echo "========================================"; \
	if [ $$fail -gt 0 ]; then exit 1; fi

#-----------------------------------------------------------------------------
# RAL regression (register-level tests, separate top)
#-----------------------------------------------------------------------------
.PHONY: regress_ral
regress_ral: compile_ral
	@mkdir -p $(LOG_DIR) $(COV_DIR)
	@echo "=== Running RAL Regression ==="
	@pass=0; fail=0; total=0; \
	for test in $(RAL_TESTS); do \
	  total=$$((total+1)); \
	  log=$(LOG_DIR)/$${test}_seed1.log; \
	  echo "--- Running: $$test ---"; \
	  vsim -c top_tb_ral +UVM_TESTNAME=$$test +UVM_VERBOSITY=UVM_LOW \
	    -sv_seed 1 -coverall \
	    -do "run -all; coverage save -onexit $(COV_DIR)/$${test}_seed1.ucdb; quit -code [coverage attribute -name TESTSTATUS -concise]" \
	    -l $$log 2>&1 | tail -3; \
	  if grep "UVM_ERROR" $$log | grep -v "UVM_ERROR :" | grep -q . ; then \
	    echo "  FAIL: $$test [UVM_ERROR in log]"; fail=$$((fail+1)); \
	  elif grep -q "TEST PASSED" $$log 2>/dev/null; then \
	    echo "  PASS: $$test"; pass=$$((pass+1)); \
	  else \
	    echo "  FAIL: $$test"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "========================================"; \
	echo "  RAL REGRESSION: $$pass passed, $$fail failed (out of $$total)"; \
	echo "========================================"; \
	if [ $$fail -gt 0 ]; then exit 1; fi

#-----------------------------------------------------------------------------
# Quick regression (1 seed per test)
#-----------------------------------------------------------------------------
.PHONY: quick
quick: compile
	@mkdir -p $(LOG_DIR) $(COV_DIR)
	@echo "=== Running Quick Regression ==="
	@pass=0; fail=0; total=0; \
	for test in $(TESTS); do \
	  total=$$((total+1)); \
	  log=$(LOG_DIR)/$${test}_seed1.log; \
	  echo "--- Running: $$test (seed=1) ---"; \
	  vsim -c top_tb +UVM_TESTNAME=$$test +UVM_VERBOSITY=UVM_LOW \
	    -sv_seed 1 -coverall \
	    -do "run -all; coverage save -onexit $(COV_DIR)/$${test}_seed1.ucdb; quit -code [coverage attribute -name TESTSTATUS -concise]" \
	    -l $$log 2>&1 | tail -3; \
	  if grep "UVM_ERROR" $$log | grep -v "UVM_ERROR :" | grep -q . ; then \
	    echo "  FAIL: $$test [UVM_ERROR in log]"; fail=$$((fail+1)); \
	  elif grep -q "SCOREBOARD PASSED" $$log 2>/dev/null; then \
	    echo "  PASS: $$test"; pass=$$((pass+1)); \
	  elif grep -q "T13: arbitration_lost_test PASS" $$log 2>/dev/null; then \
	    echo "  PASS: $$test [T13 exception-flow]"; pass=$$((pass+1)); \
	  else \
	    echo "  FAIL: $$test"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; \
	echo "========================================"; \
	echo "  QUICK REGRESSION: $$pass passed, $$fail failed (out of $$total)"; \
	echo "========================================"; \
	if [ $$fail -gt 0 ]; then exit 1; fi

#-----------------------------------------------------------------------------
# Merge and report coverage (UCDBs are saved into $(COV_DIR) by sim/regress)
#-----------------------------------------------------------------------------
.PHONY: cov
cov:
	@mkdir -p $(COV_DIR)
	vcover merge -out $(COV_DIR)/merged.ucdb $(COV_DIR)/*.ucdb
	vcover report -html $(COV_DIR)/merged.ucdb -output $(COV_DIR)/html
	vcover report -text $(COV_DIR)/merged.ucdb -output $(COV_DIR)/coverage.txt
	@echo "=== Coverage report: $(COV_DIR)/html/index.html ==="

#-----------------------------------------------------------------------------
# Clean
#-----------------------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf work/ *.ucdb *.wlf *.vcd transcript vsim.wlf i2c_rtl_smoke $(LOG_DIR)/ $(COV_DIR)/

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make compile             - compile bus-level bench"
	@echo "  make compile_ral         - compile RAL (register) bench"
	@echo "  make sim TEST=<name>     - compile and run one bus-level test"
	@echo "  make sim_ral RAL_TEST=<name> - compile and run one RAL test"
	@echo "  make gui  TEST=<name>    - compile and open waveform viewer"
	@echo "  make smoke               - RTL master<->slave smoke test (Icarus)"
	@echo "  make regress             - full regression (19 tests x 3 seeds)"
	@echo "  make regress_ral         - RAL regression (3 tests)"
	@echo "  make quick               - quick regression (19 tests x 1 seed)"
	@echo "  make cov                 - merge and report coverage"
	@echo "  make clean               - remove all build artifacts"
	@echo ""
	@echo "Bus-level tests:"
	@echo "  i2c_base_test basic_write_test basic_read_test"
	@echo "  burst_write_test burst_read_test write_read_test"
	@echo "  rep_start_test addr_nack_test data_nack_test"
	@echo "  clock_stretch_test random_directed_test addr_sweep_test"
	@echo "  bus_free_test sequential_txn_test data_pattern_test"
	@echo "  full_stress_test arbitration_lost_test deep_rep_start_test"
	@echo "  stretch_read_test"
	@echo ""
	@echo "RAL tests:"
	@echo "  i2c_ral_reset_test i2c_ral_program_test i2c_ral_field_test"
