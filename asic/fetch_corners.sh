#!/bin/bash
# Sky130 HD NLDM corners published by siliconcompiler/lambdapdk v0.2.9.
# That tree's sky130hd/nldm directory contains these three files only.
# OpenLane's ss_100C_1v60 and ff_n40C_1v95 are not in the tree (HTTP 404).
set -eu
cd "$(dirname "$0")/.."
mkdir -p asic/pdk
base="https://raw.githubusercontent.com/siliconcompiler/lambdapdk/v0.2.9/lambdapdk/sky130/libs/sky130hd/nldm"
declare -A urls=(
  [sky130_fd_sc_hd__ss_n40C_1v40.lib]="${base}/sky130_fd_sc_hd__ss_n40C_1v40.lib.gz"
  [sky130_fd_sc_hd__ff_100C_1v95.lib]="${base}/sky130_fd_sc_hd__ff_100C_1v95.lib.gz"
)
for f in "${!urls[@]}"; do
  if [[ ! -s "asic/pdk/$f" ]]; then
    if curl -fL --retry 3 --retry-delay 2 -o "asic/pdk/$f.gz" "${urls[$f]}"; then
      gunzip -f "asic/pdk/$f.gz"
    else
      rm -f "asic/pdk/$f.gz"
      echo "download failed: $f" >&2
      exit 1
    fi
  fi
  echo "-- $f"
  head -n 1 "asic/pdk/$f"
  wc -c "asic/pdk/$f"
done
echo "-- metastability tokens"
for f in sky130_fd_sc_hd__tt_025C_1v80.lib sky130_fd_sc_hd__ss_n40C_1v40.lib sky130_fd_sc_hd__ff_100C_1v95.lib; do
  if grep -E -m 1 -i 'metastab|intrinsic_rise|tau' "asic/pdk/$f"; then
    echo "found in $f"
  else
    echo "none in $f"
  fi
done
