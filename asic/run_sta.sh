#!/bin/bash
# Pre-layout OpenSTA. Needs the Yosys netlist from asic/run_sky130.sh
# and sta on PATH (see asic/build_opensta.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p asic/build
sta="${STA:-sta}"
"$sta" -exit asic/run_sta.tcl | tee asic/build/sta.log
