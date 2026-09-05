PYTHON ?= python3
.DEFAULT_GOAL := test

UVM_VERSION ?= 1.2
HPDCACHE_DIR ?= modules/cv-hpdcache
CORE_V_VERIF ?= modules/core-v-verif
CONFIG_DIR ?= config
BUILD_DIR ?= build/questa
FILELIST ?= testbench/hpdcache_uvm.f
TEST ?= hpdcache_random_test
SEED ?= random
UVM_VERBOSITY ?= UVM_LOW
CONFIG ?= hpdcache_cva6
TESTLIST ?= regression/smoke.yaml
JOBS ?= 4
COMPILE_TIMEOUT ?= 1800
RUN_TIMEOUT ?= 3600

export UVM_VERSION HPDCACHE_DIR CORE_V_VERIF CONFIG_DIR BUILD_DIR FILELIST

.PHONY: test regression clean

test:
	$(PYTHON) scripts/run_test.py --config "$(CONFIG)" \
		--test "$(TEST)" --seed "$(SEED)" \
		--verbosity "$(UVM_VERBOSITY)" --run-name run \
		--compile-timeout-seconds "$(COMPILE_TIMEOUT)" \
		--timeout-seconds "$(RUN_TIMEOUT)"

regression:
	$(PYTHON) scripts/run_regression.py --testlist "$(TESTLIST)" \
		--config "$(CONFIG)" --jobs "$(JOBS)" \
		--compile-timeout-seconds "$(COMPILE_TIMEOUT)" \
		--timeout-seconds "$(RUN_TIMEOUT)"

clean:
	rm -rf -- "$(BUILD_DIR)"
