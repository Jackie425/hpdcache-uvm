proc required_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "required environment variable $name is not set"
  }
  return $::env($name)
}

proc optional_env {name default} {
  if {[info exists ::env($name)] && $::env($name) ne ""} {
    return $::env($name)
  }
  return $default
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
quietly set coverage       [optional_env HPDCACHE_TCL_COVERAGE 0]
quietly set coverage_ucdb  [optional_env HPDCACHE_TCL_COVERAGE_UCDB ""]
quietly set coverage_scope [optional_env HPDCACHE_TCL_COVERAGE_SCOPE /top/dut.]
quietly set coverage_name  [optional_env HPDCACHE_TCL_COVERAGE_NAME $test_name]

quietly set simulation_args [list \
  -lib $work_dir \
  -L $uvm_lib \
  $optimized_top \
  "+UVM_TESTNAME=$test_name" \
  "+UVM_VERBOSITY=$verbosity" \
  -sv_seed $seed \
  -wlf $wave_path]

if {$coverage eq "1"} {
  lappend simulation_args -coverage
}

for {set index 0} {$index < $extra_count} {incr index} {
  quietly lappend simulation_args [required_env HPDCACHE_TCL_EXTRA_ARG_$index]
}

vsim {*}$simulation_args
if {$coverage eq "1" && $coverage_ucdb ne ""} {
  coverage save -onexit -instance $coverage_scope -testname $coverage_name $coverage_ucdb
}
run -all
quit -code 0
