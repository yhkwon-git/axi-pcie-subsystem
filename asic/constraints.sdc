# Sign-off constraints for nand_sol_subsystem_top.
# Periods match the Cocotb clocks: clk_pcie 8 ns, clk_axi 10 ns.
#
# Budgets below are the OpenLane sky130 pre-CTS defaults, not a measured
# board delay or a measured clock tree:
#   SYNTH_CLOCK_UNCERTAINTY 0.25 ns  (setup and hold)
#   SYNTH_CLOCK_TRANSITION  0.15 ns
#   SYNTH_TIMING_DERATE     +5% late / -5% early on data cell and net delay
#   IO_PCT                  0.2 of the related clock period, max only
# Hold keeps a min external delay of 0 so an early launch is still checked.
#
# The liberty default wire-load is "Small" in top mode. Small/Medium/Large/Huge
# in this library are the same table: 1.42e-05 pF per length unit, so a
# fanout of 6 is 84.2649 * 1.42e-05 = 0.00120 pF. That is the library model.
# It is not a routed SPEF. asic/run_sta.tcl reads a SPEF only when SPEF is set.

create_clock -name clk_pcie -period 8.000 [get_ports clk_pcie]
create_clock -name clk_axi  -period 10.000 [get_ports clk_axi]

# -allow_paths keeps the domains asynchronous for clock grouping, but does
# not delete the crossing. The false paths cover every crossing, and
# set_max_delay -reset_path puts the synchronizer pins back.
set_clock_groups -asynchronous -allow_paths \
    -group [get_clocks clk_pcie] \
    -group [get_clocks clk_axi]
set_false_path -from [get_clocks clk_pcie] -to [get_clocks clk_axi]
set_false_path -from [get_clocks clk_axi] -to [get_clocks clk_pcie]

set_clock_uncertainty -setup 0.250 [get_clocks {clk_pcie clk_axi}]
set_clock_uncertainty -hold  0.250 [get_clocks {clk_pcie clk_axi}]
set_clock_transition 0.150 [get_clocks {clk_pcie clk_axi}]

set_timing_derate -late  -data -cell_delay 1.05
set_timing_derate -early -data -cell_delay 0.95
set_timing_derate -late  -data -net_delay  1.05
set_timing_derate -early -data -net_delay  0.95

set_wire_load_mode top
set_wire_load_model -name Small

# Max I/O delay is 20% of the clock that launches or captures that port.
# Min stays 0: hold is checked against an early external launch.
set_input_delay  -max 2.000 -clock clk_axi [all_inputs -no_clocks]
set_input_delay  -min 0.000 -clock clk_axi [all_inputs -no_clocks]
set_output_delay -max 2.000 -clock clk_axi [all_outputs]
set_output_delay -min 0.000 -clock clk_axi [all_outputs]
set_input_delay  -max 1.600 -clock clk_pcie [get_ports {tlp_valid tlp_sop tlp_eop tlp_data* cpl_ready}]
set_input_delay  -min 0.000 -clock clk_pcie [get_ports {tlp_valid tlp_sop tlp_eop tlp_data* cpl_ready}]
set_output_delay -max 1.600 -clock clk_pcie [get_ports {tlp_ready cpl_valid cpl_sop cpl_eop cpl_data*}]
set_output_delay -min 0.000 -clock clk_pcie [get_ports {tlp_ready cpl_valid cpl_sop cpl_eop cpl_data*}]

# Async assert, sync deassert. Recovery is not part of this check.
set_false_path -from [get_ports {rst_pcie_n rst_axi_n}]

# Library default. A transition outside this range is not a signed-off slew.
set_max_transition 1.5 [current_design]

# rd_data is mem[rd_bin] and is consumed in that same cycle.
# There is no set_multicycle_path on the FIFO read.

# Crossings are not single-cycle paths. The limit on the commands below is
# the receiving clock period. -ignore_clock_latency keeps the check on the
# data path into the first synchronizer flop. The second flop is timed by
# its own clock. This OpenSTA still reports the pins as unconstrained while
# the clock-to-clock false path exists; asic/run_sta.tcl checks the
# unconstrained arrival against the same period and fails the run if it is over.
# Receiving period. Launch clock is the other domain.
# u_tlp_ingress is written by clk_pcie and read by clk_axi.
# u_cpl_egress is written by clk_axi and read by clk_pcie.
set_max_delay -ignore_clock_latency -reset_path \
    -from [get_clocks clk_pcie] -to [get_pins {
      u_tlp_ingress/u_sync_wr_to_rd/_0_/D
      u_tlp_ingress/u_sync_wr_to_rd/_1_/D
      u_tlp_ingress/u_sync_wr_to_rd/_2_/D
      u_tlp_ingress/u_sync_wr_to_rd/_3_/D
      u_tlp_ingress/u_sync_wr_to_rd/_4_/D
      u_cpl_egress/u_sync_rd_to_wr/_0_/D
      u_cpl_egress/u_sync_rd_to_wr/_1_/D
      u_cpl_egress/u_sync_rd_to_wr/_2_/D
      u_cpl_egress/u_sync_rd_to_wr/_3_/D
      u_cpl_egress/u_sync_rd_to_wr/_4_/D
    }] 10.000
set_max_delay -ignore_clock_latency -reset_path \
    -from [get_clocks clk_axi] -to [get_pins {
      u_tlp_ingress/u_sync_rd_to_wr/_0_/D
      u_tlp_ingress/u_sync_rd_to_wr/_1_/D
      u_tlp_ingress/u_sync_rd_to_wr/_2_/D
      u_tlp_ingress/u_sync_rd_to_wr/_3_/D
      u_tlp_ingress/u_sync_rd_to_wr/_4_/D
      u_cpl_egress/u_sync_wr_to_rd/_0_/D
      u_cpl_egress/u_sync_wr_to_rd/_1_/D
      u_cpl_egress/u_sync_wr_to_rd/_2_/D
      u_cpl_egress/u_sync_wr_to_rd/_3_/D
      u_cpl_egress/u_sync_wr_to_rd/_4_/D
    }] 8.000
