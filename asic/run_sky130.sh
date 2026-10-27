#!/bin/bash
# Sky130 HD synthesis. Requires yosys on PATH and sv2v at ~/.local/bin/sv2v-Linux/sv2v.
set -eu
cd "$(dirname "$0")/.."
mkdir -p asic/build asic/pdk
sv2v="${SV2V:-$HOME/.local/bin/sv2v-Linux/sv2v}"
"$sv2v" -DSYNTHESIS \
  rtl/cdc_async_fifo.sv \
  rtl/axi_register_slice.sv \
  rtl/axi_crossbar.sv \
  rtl/pcie_to_axi_bridge.sv \
  rtl/outstanding_queue.sv \
  rtl/nand_sol_subsystem_top.sv \
  -w asic/build/subsystem.v
yosys -l asic/build/yosys.log -s asic/synth_sky130.ys
python3 asic/buffer_fanout.py asic/build/nand_sol_subsystem_top.nl.v
