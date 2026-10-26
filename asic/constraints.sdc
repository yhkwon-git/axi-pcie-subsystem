# Pre-layout constraints for nand_sol_subsystem_top.
# Periods match the Cocotb clocks: clk_pcie 8 ns, clk_axi 10 ns.
# No SPEF. Clocks are ideal. External delay is 0 because no board
# delay was measured. Sky130 HD tt has no wire-load model, so net
# delay is pin capacitance only.
#
# Every non-clock port is given a clk_axi delay, and the host TLP
# ports are also given a clk_pcie delay. set_clock_groups -asynchronous
# drops the cross-domain combination, so each port is checked only
# against the flops in its own domain.

create_clock -name clk_pcie -period 8.000 [get_ports clk_pcie]
create_clock -name clk_axi  -period 10.000 [get_ports clk_axi]

set_clock_groups -asynchronous \
    -group [get_clocks clk_pcie] \
    -group [get_clocks clk_axi]

set_input_delay  0.0 -clock clk_axi [all_inputs -no_clocks]
set_output_delay 0.0 -clock clk_axi [all_outputs]
set_input_delay  0.0 -clock clk_pcie [get_ports {tlp_valid tlp_sop tlp_eop tlp_data* cpl_ready}]
set_output_delay 0.0 -clock clk_pcie [get_ports {tlp_ready cpl_valid cpl_sop cpl_eop cpl_data*}]

# Async assert, sync deassert. Recovery is not part of this check.
set_false_path -from [get_ports {rst_pcie_n rst_axi_n}]
