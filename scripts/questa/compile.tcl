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
quietly set filelist       [required_env HPDCACHE_TCL_FILELIST]
quietly set config_pkg     [required_env HPDCACHE_TCL_CONFIG_PKG]
quietly set top            [required_env HPDCACHE_TCL_TOP]
quietly set optimized_top  [required_env HPDCACHE_TCL_OPTIMIZED_TOP]
quietly set compile_log    [required_env HPDCACHE_TCL_COMPILE_LOG]
quietly set optimize_log   [required_env HPDCACHE_TCL_OPTIMIZE_LOG]
quietly set coverage       [optional_env HPDCACHE_TCL_COVERAGE 0]
quietly set coverage_types [optional_env HPDCACHE_TCL_COVERAGE_TYPES sbcefx]
quietly set coverage_scope [optional_env HPDCACHE_TCL_COVERAGE_SCOPE /top/dut.]

if {[file isdirectory $work_dir]} {
  puts "Clearing Questa library: $work_dir"
  vdel -lib $work_dir -all
} else {
  puts "Creating Questa library: $work_dir"
  vlib $work_dir
}

puts "Compiling: $filelist"
quietly set compile_args [list \
  -sv \
  "+define+HPDCACHE_CONFIG_PKG=$config_pkg" \
  -work $work_dir \
  -L $uvm_lib \
  -f $filelist \
  -l $compile_log]
vlog {*}$compile_args

puts "Optimizing: $top -> $optimized_top"
quietly set optimize_args [list \
  -64 \
  -work $work_dir \
  -L $uvm_lib \
  $top \
  -o $optimized_top \
  +acc \
  -l $optimize_log]
if {$coverage eq "1"} {
  # Instrument the selected RTL subtree without testbench/library counters.
  lappend optimize_args "+cover=$coverage_types+$coverage_scope" -coveragesaveparams
  if {[string first x $coverage_types] >= 0} {
    lappend optimize_args -extendedtogglemode 3
  }
}
vopt {*}$optimize_args

quit -code 0
