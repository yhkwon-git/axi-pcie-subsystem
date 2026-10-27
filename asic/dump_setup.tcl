# Endpoint setup slacks with slack < 0, one path per endpoint.
if {![info exists ::env(LIB)] || $::env(LIB) eq ""} {
  set ::env(LIB) sky130_fd_sc_hd__ss_n40C_1v40
}
set lib $::env(LIB)
read_liberty asic/pdk/${lib}.lib
read_verilog asic/build/nand_sol_subsystem_top.nl.v
link_design nand_sol_subsystem_top
read_sdc asic/constraints.sdc
report_checks -path_delay max -slack_max 0 -group_path_count 20000 \
    -endpoint_path_count 1 -format json -digits 3 \
    > asic/build/setup_${lib}.json
puts "wrote asic/build/setup_${lib}.json"
report_worst_slack -max
report_tns -max
