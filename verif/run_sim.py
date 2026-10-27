"""Launch the cocotb runner. Works with cocotb 1.8 (cocotb.runner) and 2.x (cocotb_tools.runner)."""

from __future__ import annotations

import argparse
import inspect
import os
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIF = Path(__file__).resolve().parent
RTL_DIR = ROOT / "rtl"
SIM_ROOT = ROOT / "sim"

# Slice keeps its historical build directory. Later DUTs get their own tree so
# a crossbar run does not overwrite the register-slice binary.
DUTS = {
    "slice": {
        "toplevel": "axi_register_slice",
        "test_module": "test_axi_register_slice",
        "sources": [RTL_DIR / "axi_register_slice.sv"],
        "build_dir": lambda sim: SIM_ROOT / "build" / sim,
    },
    "crossbar": {
        "toplevel": "axi_crossbar",
        "test_module": "test_axi_crossbar",
        "sources": [RTL_DIR / "axi_crossbar.sv"],
        "build_dir": lambda sim: SIM_ROOT / "build" / "crossbar" / sim,
    },
    "fifo": {
        "toplevel": "cdc_async_fifo",
        "test_module": "test_cdc_async_fifo",
        "sources": [RTL_DIR / "cdc_async_fifo.sv"],
        "parameters": {"WIDTH": 32, "DEPTH": 8},
        "build_dir": lambda sim: SIM_ROOT / "build" / "fifo" / sim,
    },
    "bridge": {
        "toplevel": "pcie_to_axi_bridge",
        "test_module": "test_pcie_to_axi_bridge",
        "sources": [RTL_DIR / "cdc_async_fifo.sv", RTL_DIR / "pcie_to_axi_bridge.sv"],
        "parameters": {"ADDR_WIDTH": 32},
        "build_dir": lambda sim: SIM_ROOT / "build" / "bridge" / sim,
    },
    "top": {
        "toplevel": "nand_sol_subsystem_top",
        "test_module": "test_subsystem_top",
        "sources": [
            RTL_DIR / "cdc_async_fifo.sv",
            RTL_DIR / "axi_register_slice.sv",
            RTL_DIR / "axi_crossbar.sv",
            RTL_DIR / "pcie_to_axi_bridge.sv",
            RTL_DIR / "outstanding_queue.sv",
            RTL_DIR / "nand_sol_subsystem_top.sv",
        ],
        "parameters": {"ADDR_WIDTH": 32, "DATA_WIDTH": 32},
        "build_dir": lambda sim: SIM_ROOT / "build" / "top" / sim,
    },
    "gate": {
        "toplevel": "nand_sol_subsystem_top",
        "test_module": "test_subsystem_top",
        "sources": [
            ROOT / "asic" / "build" / "sky130_fd_sc_hd_func.v",
            ROOT / "asic" / "build" / "nand_sol_subsystem_top.nl.v",
        ],
        "parameters": {},
        "build_dir": lambda sim: SIM_ROOT / "build" / "gate" / sim,
    },
}


def _import_runner():
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        try:
            from cocotb.runner import get_runner
        except ImportError as exc:
            print(
                "cocotb is not installed. From verif/: pip install -r requirements.txt",
                file=sys.stderr,
            )
            raise SystemExit(1) from exc
    return get_runner


def _filter_kwargs(fn, kwargs: dict) -> dict:
    params = inspect.signature(fn).parameters
    if any(p.kind == inspect.Parameter.VAR_KEYWORD for p in params.values()):
        return kwargs
    return {key: value for key, value in kwargs.items() if key in params}


def _accepts(fn, name: str) -> bool:
    params = inspect.signature(fn).parameters
    if any(p.kind == inspect.Parameter.VAR_KEYWORD for p in params.values()):
        return True
    return name in params


def build_dir_for(dut: str, sim: str) -> Path:
    return DUTS[dut]["build_dir"](sim)


def clean() -> None:
    shutil.rmtree(SIM_ROOT / "build", ignore_errors=True)
    for path in (
        SIM_ROOT / "results.xml",
        VERIF / "results.xml",
        VERIF / "sim_build",
    ):
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)
        elif path.exists():
            path.unlink()


def run(sim: str, dut: str, waves: bool, testcase: str | None) -> None:
    if dut not in DUTS:
        print(f"Unknown DUT {dut}. Choose from: {', '.join(DUTS)}", file=sys.stderr)
        raise SystemExit(1)
    spec = DUTS[dut]
    sources = list(spec["sources"])
    missing = [path for path in sources if not path.is_file()]
    if missing:
        print(f"RTL not found: {missing[0]}", file=sys.stderr)
        raise SystemExit(1)

    get_runner = _import_runner()
    verif = str(VERIF)
    if verif not in sys.path:
        sys.path.insert(0, verif)
    build_dir = build_dir_for(dut, sim)
    build_dir.mkdir(parents=True, exist_ok=True)

    runner = get_runner(sim)
    # Icarus already passes -g2012. Verilator should keep going on lint so the
    # functional tests still run.
    build_args = [] if sim == "icarus" else ["-Wno-fatal"]
    params = spec["parameters"] if "parameters" in spec else {"ADDR_WIDTH": 32, "DATA_WIDTH": 32}
    build_kwargs = {
        "hdl_toplevel": spec["toplevel"],
        "build_args": build_args,
        "always": True,
        "build_dir": build_dir,
        "waves": waves,
        "timescale": ("1ns", "1ps"),
    }
    if params:
        build_kwargs["parameters"] = params
    # Cocotb 2 compiles both `sources` and `verilog_sources`. Pass the file once.
    if _accepts(runner.build, "sources"):
        build_kwargs["sources"] = sources
    else:
        build_kwargs["verilog_sources"] = sources
    _call(runner.build, build_kwargs)

    test_kwargs = {
        "hdl_toplevel": spec["toplevel"],
        "test_module": spec["test_module"],
        "test_dir": SIM_ROOT,
        "build_dir": build_dir,
        "waves": waves,
        "results_xml": "results.xml",
        "timescale": ("1ns", "1ps"),
    }
    extra_env = {}
    if testcase:
        if _accepts(runner.test, "testcase"):
            test_kwargs["testcase"] = testcase
        else:
            extra_env["TESTCASE"] = testcase
    if waves:
        extra_env["WAVES"] = "1"
    if extra_env:
        test_kwargs["extra_env"] = extra_env
    _call(runner.test, test_kwargs)


def _call(fn, kwargs: dict) -> None:
    filtered = _filter_kwargs(fn, kwargs)
    fn(**filtered)


def main() -> None:
    parser = argparse.ArgumentParser(description="Simulate an AXI RTL block with cocotb")
    parser.add_argument("--sim", default=os.environ.get("SIM", "icarus"), choices=("icarus", "verilator"))
    parser.add_argument("--dut", default=os.environ.get("DUT", "slice"), choices=tuple(DUTS))
    parser.add_argument("--waves", type=int, default=int(os.environ.get("WAVES", "0")))
    parser.add_argument("--testcase", default=os.environ.get("TESTCASE") or None)
    parser.add_argument("--clean", action="store_true")
    args = parser.parse_args()

    if args.clean:
        clean()
        return
    run(args.sim, args.dut, bool(args.waves), args.testcase)


if __name__ == "__main__":
    main()
