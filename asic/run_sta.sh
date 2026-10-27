#!/bin/bash
# OpenSTA on the mapped netlist. Runs tt, ss, and ff unless LIBS is set.
# SPEF, when set, is read after the SDC (placement or extraction parasitics).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p asic/build
sta="${STA:-sta}"
if [[ -n "${LIBS:-}" ]]; then
  read -r -a libs <<< "$LIBS"
else
  libs=(
    sky130_fd_sc_hd__tt_025C_1v80
    sky130_fd_sc_hd__ss_n40C_1v40
    sky130_fd_sc_hd__ff_100C_1v95
  )
fi
for lib in "${libs[@]}"; do
  if [[ ! -s "asic/pdk/${lib}.lib" ]]; then
    echo "missing asic/pdk/${lib}.lib" >&2
    exit 1
  fi
done
for lib in "${libs[@]}"; do
  echo "===== ${lib} ====="
  LIB="$lib" SPEF="${SPEF:-}" "$sta" -exit asic/run_sta.tcl | tee "asic/build/sta_${lib}.log"
done
