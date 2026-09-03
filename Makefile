ifndef QUESTA_HOME
$(error QUESTA_HOME is not set)
endif

UVM_VERSION ?= 1.2
HPDCACHE_DIR ?= modules/cv-hpdcache
CORE_V_VERIF ?= modules/core-v-verif
CONFIG_DIR ?= config
BUILD_DIR ?= build/questa
FILELIST ?= testbench/hpdcache_uvm.f

VLOG := $(QUESTA_HOME)/bin/vlog
VOPT := $(QUESTA_HOME)/bin/vopt
VSIM := $(QUESTA_HOME)/bin/vsim
VLIB := $(QUESTA_HOME)/bin/vlib
UVM_LIB ?= $(QUESTA_HOME)/uvm-$(UVM_VERSION)
UVM_SRC ?= $(QUESTA_HOME)/verilog_src/uvm-$(UVM_VERSION)/src
UVM_FAILURE_RE := UVM_(ERROR|FATAL)[[:space:]]*:[[:space:]]*[1-9][0-9]*

define CHECK_UVM_LOG
	@if grep -Eq '$(UVM_FAILURE_RE)' $(1); then \
		echo "UVM test failed; see $(1)"; \
		exit 1; \
	fi
endef

export HPDCACHE_DIR CORE_V_VERIF CONFIG_DIR UVM_SRC

.PHONY: random compile clean

random: compile
	$(VSIM) -c -64 -lib $(BUILD_DIR)/work hpdcache_uvm_opt \
		+UVM_TESTNAME=hpdcache_random_test +UVM_VERBOSITY=UVM_LOW \
		-sv_seed random -wlf $(BUILD_DIR)/random.wlf \
		-do "onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0" \
		-l $(BUILD_DIR)/random.log
	$(call CHECK_UVM_LOG,$(BUILD_DIR)/random.log)

compile:
	mkdir -p $(BUILD_DIR)
	@if [ ! -d $(BUILD_DIR)/work ]; then $(VLIB) $(BUILD_DIR)/work; fi
	$(VLOG) -sv -work $(BUILD_DIR)/work -L $(UVM_LIB) \
		-f $(FILELIST) -l $(BUILD_DIR)/compile.log
	$(VOPT) -64 -work $(BUILD_DIR)/work -L $(UVM_LIB) top \
		-o hpdcache_uvm_opt +acc -l $(BUILD_DIR)/vopt.log

clean:
	rm -rf $(BUILD_DIR)
