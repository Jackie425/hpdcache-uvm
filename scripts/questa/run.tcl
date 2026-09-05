proc required_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "required environment variable $name is not set"
  }
  return $::env($name)
}

onbreak {quit -code 1}
onerror {quit -code 1}

quietly set work_dir       [required_env HPDCACHE_TCL_WORK_DIR]
quietly set uvm_lib        [required_env HPDCACHE_TCL_UVM_LIB]
quietly set optimized_top  [required_env HPDCACHE_TCL_OPTIMIZED_TOP]
quietly set test_name      [required_env HPDCACHE_TCL_TEST]
quietly set verbosity      [required_env HPDCACHE_TCL_VERBOSITY]
quietly set seed           [required_env HPDCACHE_TCL_SEED]
quietly set wave_path      [required_env HPDCACHE_TCL_WAVE]
quietly set extra_count    [required_env HPDCACHE_TCL_EXTRA_ARG_COUNT]

quietly set simulation_args [list \
  -lib $work_dir \
  -L $uvm_lib \
  $optimized_top \
  "+UVM_TESTNAME=$test_name" \
  "+UVM_VERBOSITY=$verbosity" \
  -sv_seed $seed \
  -wlf $wave_path]

for {set index 0} {$index < $extra_count} {incr index} {
  quietly lappend simulation_args [required_env HPDCACHE_TCL_EXTRA_ARG_$index]
}

vsim {*}$simulation_args
run -all
quit -code 0
