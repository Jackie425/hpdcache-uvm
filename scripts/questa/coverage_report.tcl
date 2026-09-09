proc required_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "required environment variable $name is not set"
  }
  return $::env($name)
}

onbreak {quit -code 1}
onerror {quit -code 1}

quietly set coverage_types [required_env HPDCACHE_TCL_COVERAGE_TYPES]
quietly set html_dir       [required_env HPDCACHE_TCL_COVERAGE_HTML]
quietly set text_report    [required_env HPDCACHE_TCL_COVERAGE_REPORT]

file mkdir [file dirname $html_dir]
coverage report -code $coverage_types -assert -directive -cvg -details -precision 2 -annotate \
  -output $text_report
coverage report -code $coverage_types -assert -directive -cvg -html -details -precision 2 -annotate \
  -output $html_dir
quit -code 0
