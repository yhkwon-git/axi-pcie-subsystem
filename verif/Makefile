# Cocotb simulation.
#
#   make sim
#   make sim SIM=verilator WAVES=1
#   make sim DUT=crossbar SIM=verilator
#   make sim DUT=fifo SIM=verilator
#   make sim DUT=bridge SIM=verilator
#   make sim DUT=top SIM=verilator
#   make sim DUT=slice TESTCASE=test_reset_outputs_idle
#   make clean

SIM      ?= icarus
DUT      ?= slice
WAVES    ?= 0
TESTCASE ?=
PYTHON   ?= python

.PHONY: help sim clean

help:
	@echo "Targets: sim, clean"
	@echo "Variables: DUT=(slice|crossbar|fifo|bridge|top|gate) SIM=(icarus|verilator) WAVES=(0|1) TESTCASE=<cocotb test name> PYTHON=<interpreter>"

sim:
	$(PYTHON) run_sim.py --sim $(SIM) --dut $(DUT) --waves $(WAVES) $(if $(TESTCASE),--testcase $(TESTCASE),)

clean:
	$(PYTHON) run_sim.py --clean
