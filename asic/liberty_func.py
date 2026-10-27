#!/usr/bin/env python3
"""Zero-delay Verilog for the Sky130 cells used by the mapped netlist.

Pin functions and ff groups are copied from the liberty file. The output is
a functional model of those statements. It has no timing arcs, so a simulator
can check the mapped netlist without a timing model. Cells the netlist does
not instantiate are left out.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "asic" / "pdk" / "sky130_fd_sc_hd__tt_025C_1v80.lib"
NETLIST = ROOT / "asic" / "build" / "nand_sol_subsystem_top.nl.v"
OUT = ROOT / "asic" / "build" / "sky130_fd_sc_hd_func.v"

CELL_USE = re.compile(r"^\s*(sky130_fd_sc_hd__\w+)\s+", re.M)
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def brace_block(text: str, open_at: int) -> str:
    depth = 0
    in_str = False
    for i in range(open_at, len(text)):
        ch = text[i]
        if ch == '"':
            in_str = not in_str
        elif not in_str:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return text[open_at + 1 : i]
    raise SystemExit(f"unbalanced brace at offset {open_at}")


def brace_delta(line: str) -> int:
    delta = 0
    in_str = False
    for ch in line:
        if ch == '"':
            in_str = not in_str
        elif not in_str:
            if ch == "{":
                delta += 1
            elif ch == "}":
                delta -= 1
    return delta


def parse_cell(block: str) -> dict:
    pins: list[dict] = []
    ff: dict[str, str] | None = None
    depth = 0
    pin: dict | None = None
    in_ff = False
    for raw in block.splitlines():
        line = raw.strip()
        if depth == 0 and re.match(r"pin\s*\(", line):
            name = line.split("(", 1)[1].split(")", 1)[0].strip().strip('"')
            pin = {"name": name, "direction": None, "function": None, "three_state": None}
            pins.append(pin)
        elif depth == 0 and re.match(r"ff\s*\(", line):
            ff = {}
            in_ff = True
        elif depth == 0 and re.match(r"(latch|statetable)\s*\(", line):
            kind = line.split("(", 1)[0].strip()
            raise SystemExit(f"{kind} group is not modeled")
        elif pin is not None and depth == 1 and ":" in line:
            key, val = line.split(":", 1)
            key = key.strip()
            val = val.strip().rstrip(";").strip().strip('"')
            if key in {"direction", "function", "three_state"}:
                pin[key] = val
        elif in_ff and ff is not None and depth == 1 and ":" in line:
            key, val = line.split(":", 1)
            key = key.strip()
            val = val.strip().rstrip(";").strip().strip('"')
            if key in {"clocked_on", "next_state", "clear", "preset", "enable"}:
                ff[key] = val
        depth += brace_delta(line)
        if depth == 0:
            pin = None
            in_ff = False
        if depth < 0:
            raise SystemExit("brace depth went negative")
    return {"pins": pins, "ff": ff}


def verilog_expr(expr: str) -> str:
    expr = expr.strip()
    if expr in {"0", "1"}:
        return f"1'b{expr}"
    return expr


def edge(expr: str) -> tuple[str, str]:
    """Liberty clear/preset/clock expression -> (sensitivity, condition)."""
    expr = expr.strip()
    if expr.startswith("!"):
        pin = expr[1:].strip()
        return f"negedge {pin}", f"!{pin}"
    return f"posedge {expr}", expr


def emit_cell(name: str, parsed: dict) -> str:
    pins = [p for p in parsed["pins"] if p["direction"] in {"input", "output", "inout"}]
    if any(p["three_state"] for p in pins):
        raise SystemExit(f"{name}: three_state pin is not modeled")
    missing = [p["name"] for p in pins if p["direction"] is None]
    if missing:
        raise SystemExit(f"{name}: pin without direction: {missing}")
    ports = ", ".join(p["name"] for p in pins)
    lines = [f"module {name} ({ports});"]
    for pin in pins:
        lines.append(f"  {pin['direction']} {pin['name']};")
    ff = parsed["ff"]
    if ff:
        if "clocked_on" not in ff or "next_state" not in ff:
            raise SystemExit(f"{name}: ff group is missing clocked_on or next_state")
        if ff.get("enable"):
            raise SystemExit(f"{name}: ff enable is not modeled")
        lines.append("  reg IQ;")
        lines.append("  wire IQ_N = ~IQ;")
        clk_sens, _ = edge(ff["clocked_on"])
        sens = [clk_sens]
        body = []
        if "clear" in ff:
            clear_sens, clear_cond = edge(ff["clear"])
            sens.append(clear_sens)
            body.append(f"    if ({clear_cond}) IQ <= 1'b0;")
        if "preset" in ff:
            preset_sens, preset_cond = edge(ff["preset"])
            sens.append(preset_sens)
            kw = "else if" if body else "if"
            body.append(f"    {kw} ({preset_cond}) IQ <= 1'b1;")
        nxt = verilog_expr(ff["next_state"])
        if body:
            body.append(f"    else IQ <= {nxt};")
        else:
            body.append(f"    IQ <= {nxt};")
        lines.append(f"  always @({' or '.join(sens)}) begin")
        lines.extend(body)
        lines.append("  end")
    for pin in pins:
        if pin["direction"] != "output":
            continue
        if not pin["function"]:
            raise SystemExit(f"{name}: output {pin['name']} has no function")
        lines.append(f"  assign {pin['name']} = {verilog_expr(pin['function'])};")
    lines.append("endmodule")
    return "\n".join(lines) + "\n"


def used_cells(netlist: str) -> list[str]:
    found = []
    seen = set()
    for name in CELL_USE.findall(netlist):
        if name not in seen:
            seen.add(name)
            found.append(name)
    return found


def main() -> None:
    if not LIB.is_file():
        raise SystemExit(f"missing {LIB}")
    if not NETLIST.is_file():
        raise SystemExit(f"missing {NETLIST}")
    lib = LIB.read_text(encoding="utf-8", errors="replace")
    names = used_cells(NETLIST.read_text(encoding="utf-8", errors="replace"))
    parts = [
        "// Generated by asic/liberty_func.py from pin functions and ff groups.",
        "// Zero delay. This checks function, not timing.",
        "",
    ]
    for name in names:
        marker = f'cell ("{name}")'
        at = lib.find(marker)
        if at < 0:
            raise SystemExit(f"{name} is in the netlist and not in {LIB.name}")
        open_at = lib.find("{", at)
        try:
            parsed = parse_cell(brace_block(lib, open_at))
            parts.append(emit_cell(name, parsed))
        except SystemExit as exc:
            raise SystemExit(f"{name}: {exc}") from exc
    OUT.write_text("\n".join(parts), encoding="utf-8", newline="\n")
    print(f"wrote {OUT} cells={len(names)}")


if __name__ == "__main__":
    main()
