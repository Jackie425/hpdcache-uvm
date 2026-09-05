// HPDcache UVM compile file list.
//
// HPDCACHE_DIR, CORE_V_VERIF, CONFIG_DIR, and UVM_SRC are exported by the
// Makefile. Keep sources in dependency order: parameters and RTL first,
// followed by the memory model and the UVM testbench.

// HPDcache RTL and the selected DV configuration.
+incdir+${HPDCACHE_DIR}/rtl/include
+incdir+${HPDCACHE_DIR}/rtl/src/utils/ecc
${HPDCACHE_DIR}/rtl/include/hpdcache_typedef.svh
${HPDCACHE_CONFIG_FILE}
-F ${HPDCACHE_DIR}/rtl/hpdcache.Flist

// ECC support and behavioral SRAM macros required by the RTL.
${HPDCACHE_DIR}/rtl/src/utils/ecc/prim_secded_pkg.sv
${HPDCACHE_DIR}/rtl/src/utils/ecc/prim_secded_36_29_dec.sv
${HPDCACHE_DIR}/rtl/src/utils/ecc/prim_secded_36_29_enc.sv
${HPDCACHE_DIR}/rtl/src/utils/ecc/prim_secded_39_32_dec.sv
${HPDCACHE_DIR}/rtl/src/utils/ecc/prim_secded_39_32_enc.sv
${HPDCACHE_DIR}/rtl/src/utils/ecc/prim_secded_55_48_dec.sv
${HPDCACHE_DIR}/rtl/src/utils/ecc/prim_secded_55_48_enc.sv
${HPDCACHE_DIR}/rtl/src/utils/ecc/prim_secded_72_64_dec.sv
${HPDCACHE_DIR}/rtl/src/utils/ecc/prim_secded_72_64_enc.sv
${HPDCACHE_DIR}/rtl/src/common/macros/behav/hpdcache_sram_wbyteenable_1rw.sv
${HPDCACHE_DIR}/rtl/src/common/macros/behav/hpdcache_sram_1rw.sv
${HPDCACHE_DIR}/rtl/src/common/macros/behav/hpdcache_sram_wmask_1rw.sv
${HPDCACHE_DIR}/rtl/src/common/macros/behav/hpdcache_sram_wbyteenable_ecc_1rw.sv
${HPDCACHE_DIR}/rtl/src/common/macros/behav/hpdcache_sram_ecc_1rw.sv
${HPDCACHE_DIR}/rtl/src/common/macros/behav/hpdcache_sram_wmask_ecc_1rw.sv

// cv_dv_utils clock/reset generation and memory response path.
+incdir+${UVM_SRC}
+incdir+${CORE_V_VERIF}/lib/cv_dv_utils/uvm/clock_gen
+incdir+${CORE_V_VERIF}/lib/cv_dv_utils/uvm/reset_gen
+incdir+${CORE_V_VERIF}/lib/cv_dv_utils/uvm/memory_rsp_model
+incdir+${CORE_V_VERIF}/lib/cv_dv_utils/uvm/memory_rsp_model/axi2mem
${CORE_V_VERIF}/lib/cv_dv_utils/uvm/reset_gen/reset_vif_xrtl_pkg.sv
${CORE_V_VERIF}/lib/cv_dv_utils/uvm/reset_gen/xrtl_reset_vif.sv
${CORE_V_VERIF}/lib/cv_dv_utils/uvm/reset_gen/reset_driver_pkg.sv
${CORE_V_VERIF}/lib/cv_dv_utils/uvm/clock_gen/xrtl_clock_vif.sv
${CORE_V_VERIF}/lib/cv_dv_utils/uvm/clock_gen/clock_driver_pkg.sv
${CORE_V_VERIF}/lib/cv_dv_utils/uvm/memory_rsp_model/memory_response_model_pkg.sv
${CORE_V_VERIF}/lib/cv_dv_utils/uvm/memory_rsp_model/memory_response_if.sv
${CORE_V_VERIF}/lib/cv_dv_utils/uvm/memory_rsp_model/axi2mem/axi2mem_pkg.sv
${CORE_V_VERIF}/lib/cv_dv_utils/uvm/memory_rsp_model/axi2mem/axi_intf.sv

// Minimal CVA6-only UVM environment and random test.
+incdir+testbench/config
+incdir+testbench/hpdcache_cri_agent
+incdir+testbench/hpdcache_cri_agent/items
+incdir+testbench/hpdcache_cri_agent/sequences
+incdir+testbench/hpdcache_cri_agent/sequences/api
+incdir+testbench/hpdcache_cri_agent/sequences/worker
+incdir+testbench/vsequences
+incdir+testbench/hpdcache_cmi_agent
+incdir+testbench/hpdcache_cmi_agent/items
+incdir+testbench/env
+incdir+testbench/tests
+incdir+testbench/tests/basic_test
testbench/types/hpdcache_cva6_types_pkg.sv
testbench/hpdcache_cri_agent/hpdcache_cri_if.sv
testbench/hpdcache_cmi_agent/hpdcache_cmi_if.sv
testbench/hpdcache_uvm_components_pkg.sv
testbench/top.sv
