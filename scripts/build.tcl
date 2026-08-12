# Non-project (Tcl-only) Vivado synthesis flow.
# Usage: vivado -mode batch -source scripts/build.tcl

set part "xc7a100tcsg324-1"    ;# change to match your target device/board

set script_dir [file dirname [info script]]
set root_dir   [file normalize "$script_dir/.."]
set build_dir  "$root_dir/build"

file mkdir $build_dir

read_verilog -sv [glob "$root_dir/rtl/*.sv"]
read_xdc "$root_dir/constraints/eth_header.xdc"

synth_design -top eth_header -part $part

write_checkpoint -force "$build_dir/eth_header_synth.dcp"
report_utilization    -file "$build_dir/eth_header_utilization.rpt"
report_timing_summary -file "$build_dir/eth_header_timing_summary.rpt"

puts "Synthesis complete. Reports written to $build_dir"
