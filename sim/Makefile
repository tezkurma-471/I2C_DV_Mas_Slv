#=============================================================================
# Makefile : I2C UVM Verification Project
# Supports  : QuestaSim (vlog/vsim)
# V2: Proper regression with logs, seed, coverage, pass/fail detection
#=============================================================================

SIM_TOOL  ?= questa

RTL_DIR   := ../rtl
TB_DIR    := ../tb
UVM_DIR   := ../uvm
SVA_DIR   := ../sva
LOG_DIR   := ../logs
COV_DIR   := ../coverage

UVM_HOME  ?= $(MODEL_TECH)/../verilog_src/uvm-1.2

VLOG_OPTS  = +incdir+$(UVM_HOME)/src $(UVM_HOME)/src/uvm_pkg.sv
VLOG_OPTS += +incdir+$(UVM_DIR)
VLOG_OPTS += +incdir+$(TB_DIR)
VLOG_OPTS += -sv -coverassert -coverfsm -covertoggle -coverbc

TEST      ?= i2c_base_test
SEED      ?= 1

#-----------------------------------------------------------------------------
# Compile all sources
#-----------------------------------------------------------------------------
.PHONY: compile
compile:
	@echo "=== Compiling I2C Project ==="
	@if [ ! -d "work" ]; then vlib work; fi
	vlog $(VLOG_OPTS) \
	  $(RTL_DIR)/i2c_pkg.sv              \
	  $(RTL_DIR)/i2c_master_controller.sv \
	  $(RTL_DIR)/i2c_master.sv           \
	  $(RTL_DIR)/i2c_slave_controller.sv \
	  $(RTL_DIR)/i2c_slave.sv            \
	  $(SVA_DIR)/i2c_protocol_assertions.sv \
	  $(TB_DIR)/i2c_if.sv               \
	  $(TB_DIR)/i2c_slave_if.sv         \
	  $(TB_DIR)/i2c_tb_pkg.sv           \
	  $(TB_DIR)/top_tb.sv
	@echo "=== Compilation Complete ==="

#-----------------------------------------------------------------------------
# Run a single test
#-----------------------------------------------------------------------------
.PHONY: sim
sim: compile
	@mkdir -p $(LOG_DIR)
	@echo "=== Running Test: $(TEST) (seed=$(SEED)) ==="
	vsim -c top_tb \
	  +UVM_TESTNAME=$(TEST)              \
	  +UVM_VERBOSITY=UVM_MEDIUM          \
	  -sv_seed $(SEED)                   \
	  -coverall                          \
	  -do "run -all; coverage save -onexit $(TEST)_seed$(SEED).ucdb; quit -code [coverage attribute -name TESTSTATUS -concise]" \
	  -l $(LOG_DIR)/$(TEST)_seed$(SEED).log
	@echo "=== Log: $(LOG_DIR)/$(TEST)_seed$(SEED).log ==="

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
# Regression: run all 18 tests with multiple seeds
#-----------------------------------------------------------------------------
TESTS = i2c_base_test basic_write_test basic_read_test burst_write_test burst_read_test \
        write_read_test rep_start_test addr_nack_test data_nack_test \
        clock_stretch_test random_directed_test addr_sweep_test \
        bus_free_test sequential_txn_test data_pattern_test full_stress_test \
        arbitration_lost_test deep_rep_start_test

SEEDS = 1 42 123

.PHONY: regress
regress: compile
	@mkdir -p $(LOG_DIR)
	@echo "=== Running Full Regression ==="
	@pass=0; fail=0; total=0; \
	for test in $(TESTS); do \
	  for seed in $(SEEDS); do \
	    total=$$((total+1)); \
	    echo "--- Running: $$test (seed=$$seed) ---"; \
	    vsim -c top_tb +UVM_TESTNAME=$$test +UVM_VERBOSITY=UVM_LOW \
	      -sv_seed $$seed -coverall \
	      -do "run -all; quit -code [coverage attribute -name TESTSTATUS -concise]" \
	      -l $(LOG_DIR)/$${test}_seed$${seed}.log 2>&1 | tail -3; \
	    if grep -q "SCOREBOARD PASSED" $(LOG_DIR)/$${test}_seed$${seed}.log 2>/dev/null; then \
	      echo "  PASS: $$test (seed=$$seed)"; pass=$$((pass+1)); \
	    elif grep -q "T13: arbitration_lost_test PASS" $(LOG_DIR)/$${test}_seed$${seed}.log 2>/dev/null; then \
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
# Quick regression (1 seed per test)
#-----------------------------------------------------------------------------
.PHONY: quick
quick: compile
	@mkdir -p $(LOG_DIR)
	@echo "=== Running Quick Regression ==="
	@pass=0; fail=0; total=0; \
	for test in $(TESTS); do \
	  total=$$((total+1)); \
	  echo "--- Running: $$test (seed=1) ---"; \
	  vsim -c top_tb +UVM_TESTNAME=$$test +UVM_VERBOSITY=UVM_LOW \
	    -sv_seed 1 -coverall \
	    -do "run -all; quit -code [coverage attribute -name TESTSTATUS -concise]" \
	    -l $(LOG_DIR)/$${test}_seed1.log 2>&1 | tail -3; \
	  if grep -q "SCOREBOARD PASSED" $(LOG_DIR)/$${test}_seed1.log 2>/dev/null; then \
	    echo "  PASS: $$test"; pass=$$((pass+1)); \
	  elif grep -q "T13: arbitration_lost_test PASS" $(LOG_DIR)/$${test}_seed1.log 2>/dev/null; then \
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
# Merge and report coverage
#-----------------------------------------------------------------------------
.PHONY: cov
cov:
	@mkdir -p $(COV_DIR)
	vcover merge -out merged.ucdb $(LOG_DIR)/*.ucdb
	vcover report -html merged.ucdb -output $(COV_DIR)/html
	vcover report -text merged.ucdb -output $(COV_DIR)/coverage.txt
	@echo "=== Coverage report: $(COV_DIR)/html/index.html ==="

#-----------------------------------------------------------------------------
# Clean
#-----------------------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf work/ *.ucdb *.wlf *.vcd transcript vsim.wlf $(LOG_DIR)/ $(COV_DIR)/

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make compile           — compile all sources"
	@echo "  make sim TEST=<name>   — compile and run one test"
	@echo "  make gui  TEST=<name>  — compile and open waveform viewer"
	@echo "  make regress           — full regression (18 tests x 3 seeds)"
	@echo "  make quick              — quick regression (18 tests x 1 seed)"
	@echo "  make cov               — merge and report coverage"
	@echo "  make clean             — remove all build artifacts"
	@echo ""
	@echo "Available tests:"
	@echo "  i2c_base_test basic_write_test basic_read_test"
	@echo "  burst_write_test burst_read_test write_read_test"
	@echo "  rep_start_test addr_nack_test data_nack_test"
	@echo "  clock_stretch_test random_directed_test addr_sweep_test"
	@echo "  bus_free_test sequential_txn_test data_pattern_test"
	@echo "  full_stress_test arbitration_lost_test deep_rep_start_test"
