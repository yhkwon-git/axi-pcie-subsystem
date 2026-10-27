#!/usr/bin/env python3
"""Insert Sky130 delay cells on hold-violating endpoint pins.

Reads the JSON written by asic/run_sta.tcl. Each violating D or DE pin gets
sky130_fd_sc_hd__dlymetal6s6s_1 between its current net and the pin. Other
loads of that net stay where they are, so a short hold path can be padded
without delaying every branch of the driver.

The cell is a buffer (function A). It is not a timing waiver.
Each violating D/DE pin and each violating output port bit gets one cell.
HOLD_CELL selects the buffer. HOLD_CHAIN=1 inserts it in front of a pin
that already has a hold net, and the new names continue past the existing
_hold_ indices. The short cell is sky130_fd_sc_hd__dlymetal6s2s_1: its
fast-corner delay covers a few tens of picoseconds and its slow-corner
delay stays under the setup slack of the endpoints that still miss hold.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETLIST = ROOT / "asic" / "build" / "nand_sol_subsystem_top.nl.v"
HOLD_JSON = ROOT / "asic" / "build" / "hold_sky130_fd_sc_hd__tt_025C_1v80.json"
CELL = os.environ.get("HOLD_CELL", "sky130_fd_sc_hd__dlymetal6s6s_1")
CHAIN = os.environ.get("HOLD_CHAIN") == "1"
TOP = "nand_sol_subsystem_top"

PIN_CONN = re.compile(r"\.([A-Za-z_][A-Za-z0-9_]*)\(([^()]*)\)")


def split_modules(text: str) -> tuple[str, list[tuple[str, str]], str]:
    matches = list(re.finditer(r"^module\s+(\S+)\s*\(", text, re.M))
    if not matches:
        raise SystemExit("no modules in netlist")
    prefix = text[: matches[0].start()]
    modules: list[tuple[str, str]] = []
    for i, match in enumerate(matches):
        start = match.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        chunk = text[start:end]
        endmod = chunk.rfind("\nendmodule")
        if endmod < 0:
            raise SystemExit(f"endmodule missing for {match.group(1)}")
        body = chunk[: endmod + len("\nendmodule")]
        if not body.endswith("\n"):
            body += "\n"
        modules.append((match.group(1), body))
    last = text[matches[-1].start() :]
    endmod = last.rfind("\nendmodule")
    trailer = last[endmod + len("\nendmodule") :]
    return prefix, modules, trailer


def parse_instances(body: str) -> dict[str, dict]:
    lines = body.splitlines(keepends=True)
    instances: dict[str, dict] = {}
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if (
            not stripped
            or stripped.startswith(("wire ", "assign ", "input ", "output ", "reg ", "module ", "endmodule"))
            or "(" not in stripped
        ):
            i += 1
            continue
        try:
            tokens = stripped.split()
            cell = tokens[0]
            inst = tokens[1].rstrip("(")
        except IndexError:
            i += 1
            continue
        if inst == "(":
            i += 1
            continue
        block = line
        depth = line.count("(") - line.count(")")
        i += 1
        while i < len(lines) and depth > 0:
            block += lines[i]
            depth += lines[i].count("(") - lines[i].count(")")
            i += 1
        pins = {m.group(1): m.group(2).strip() for m in PIN_CONN.finditer(block)}
        instances[inst] = {"cell": cell, "pins": pins, "block": block}
    return instances


def violating_endpoints(path: Path) -> dict[str, float]:
    data = json.loads(path.read_text(encoding="utf-8"))
    worst: dict[str, float] = {}
    for check in data["checks"]:
        if check.get("path_type") != "min":
            continue
        slack = float(check["slack"])
        if slack >= 0:
            continue
        endpoint = check["endpoint"]
        prev = worst.get(endpoint)
        if prev is None or slack < prev:
            worst[endpoint] = slack
    return worst


def insert_port_delays(body: str, ports: dict[str, float]) -> tuple[str, int]:
    """Delay top-level output bits. The driving instance keeps a private wire."""
    groups: dict[str, set[int]] = {}
    scalars: set[str] = set()
    for ep in ports:
        if "[" in ep:
            base, idx = ep[:-1].split("[")
            groups.setdefault(base, set()).add(int(idx))
        else:
            scalars.add(ep)
    extra: list[str] = []
    inserted = 0
    n = 0
    for base, viol in {**{s: set() for s in scalars}, **groups}.items():
        vec = re.search(rf"output\s+\[(\d+):(\d+)\]\s+{re.escape(base)}\s*;", body)
        token = f"({base})"
        assign = re.search(rf"^  assign {re.escape(base)} = (.*);\n", body, re.M)
        via_assign = False
        if body.count(token) == 1:
            body = body.replace(token, f"(_hold_bus_{base})", 1)
        elif assign:
            via_assign = True
            if vec:
                hi, lo = int(vec.group(1)), int(vec.group(2))
                decl = f"  wire [{hi}:{lo}] _hold_bus_{base};\n"
            else:
                decl = f"  wire _hold_bus_{base};\n"
            body = body.replace(
                assign.group(0),
                decl + f"  assign _hold_bus_{base} = {assign.group(1)};\n",
                1,
            )
        else:
            raise SystemExit(f"{token} occurs {body.count(token)} times in the top")
        if vec:
            hi, lo = int(vec.group(1)), int(vec.group(2))
            if not via_assign:
                extra.append(f"  wire [{hi}:{lo}] _hold_bus_{base};\n")
            step = -1 if hi >= lo else 1
            for i in range(hi, lo + step, step):
                src = f"_hold_bus_{base}[{i}]"
                dst = f"{base}[{i}]"
                if i in viol:
                    extra.append(
                        f"  {CELL} _hold_pu{n}_ (\n    .A({src}),\n    .X({dst})\n  );\n"
                    )
                    inserted += 1
                    n += 1
                else:
                    extra.append(f"  assign {dst} = {src};\n")
        else:
            if not re.search(rf"output\s+{re.escape(base)}\s*;", body):
                raise SystemExit(f"output {base} not found in the top")
            if not via_assign:
                extra.append(f"  wire _hold_bus_{base};\n")
            extra.append(
                f"  {CELL} _hold_pu{n}_ (\n    .A(_hold_bus_{base}),\n    .X({base})\n  );\n"
            )
            inserted += 1
            n += 1
    if extra:
        body = body.replace("\nendmodule", "\n" + "".join(extra) + "endmodule", 1)
    return body, inserted


def series_count(slack: float) -> int:
    # One cell per pass. dlymetal6s6s_1 is about 1.5 ns at ss, more than
    # the 0.02 ns setup margin of the worst path, so a second one of that
    # cell is not inserted. A later pass uses the shorter cell instead.
    return 1


def main() -> None:
    hold_json = Path(sys.argv[1]) if len(sys.argv) > 1 else HOLD_JSON
    if not hold_json.is_file():
        raise SystemExit(f"missing {hold_json}; run asic/run_sta.sh first")
    endpoints = violating_endpoints(hold_json)
    pins = {ep: sl for ep, sl in endpoints.items() if ep.rsplit("/", 1)[-1] in {"D", "DE"}}
    ports = {ep: sl for ep, sl in endpoints.items() if "/" not in ep}
    leftover = set(endpoints) - set(pins) - set(ports)
    if leftover:
        raise SystemExit(f"unhandled hold endpoints: {sorted(leftover)[:8]}")
    text = NETLIST.read_text(encoding="utf-8")
    prefix, modules, trailer = split_modules(text)
    parsed = {name: parse_instances(body) for name, body in modules}
    by_name = {name: body for name, body in modules}

    edits: dict[tuple[str, str, str], tuple[str, float]] = {}
    for endpoint, slack in pins.items():
        parts = endpoint.split("/")
        if len(parts) < 2:
            raise SystemExit(f"endpoint is not hierarchical: {endpoint}")
        pin = parts[-1]
        inst_path = parts[:-1]
        mod = TOP
        for idx, inst in enumerate(inst_path):
            info = parsed.get(mod, {}).get(inst)
            if info is None:
                raise SystemExit(f"instance {inst} not in {mod} for {endpoint}")
            if idx == len(inst_path) - 1:
                net = info["pins"].get(pin)
                if net is None:
                    raise SystemExit(f"{endpoint} has no .{pin} connection")
                if net.startswith("_hold_") and not CHAIN:
                    continue
                key = (mod, inst, pin)
                prev = edits.get(key)
                if prev is None or slack < prev[1]:
                    edits[key] = (net, slack)
            else:
                mod = info["cell"]

    inserted = 0
    planned = sum(series_count(slack) for _, slack in edits.values())
    new_modules: list[tuple[str, str]] = []
    for name, body in modules:
        wanted = [
            (inst, pin, net, slack)
            for (mod, inst, pin), (net, slack) in edits.items()
            if mod == name
        ]
        if not wanted and name != TOP:
            new_modules.append((name, body))
            continue
        by_inst: dict[str, list[tuple[str, str, float]]] = {}
        for inst, pin, net, slack in wanted:
            by_inst.setdefault(inst, []).append((pin, net, slack))
        lines = body.splitlines(keepends=True)
        out: list[str] = []
        i = 0
        used = [int(x) for x in re.findall(r"_hold_[a-z]*(\d+)_", body)]
        n = max(used) + 1 if used else 0
        while i < len(lines):
            line = lines[i]
            stripped = line.strip()
            inst_name = None
            if stripped and not stripped.startswith(("wire ", "assign ", "input ", "output ", "reg ", "module ")):
                tokens = stripped.split()
                if len(tokens) >= 2 and "(" in stripped:
                    inst_name = tokens[1].rstrip("(")
            if inst_name in by_inst:
                block_lines = [line]
                depth = line.count("(") - line.count(")")
                i += 1
                while i < len(lines) and depth > 0:
                    block_lines.append(lines[i])
                    depth += lines[i].count("(") - lines[i].count(")")
                    i += 1
                block = "".join(block_lines)
                extra = []
                for pin, net, slack in by_inst[inst_name]:
                    prev = net
                    last = net
                    for _ in range(series_count(slack)):
                        last = f"_hold_n{n}_"
                        buf = f"_hold_u{n}_"
                        extra.append(f"  wire {last};\n")
                        extra.append(
                            f"  {CELL} {buf} (\n    .A({prev}),\n    .X({last})\n  );\n"
                        )
                        prev = last
                        n += 1
                        inserted += 1
                    old = f".{pin}({net})"
                    if old not in block:
                        raise SystemExit(f"{name} {inst_name} missing {old}")
                    block = block.replace(old, f".{pin}({last})", 1)
                out.extend(extra)
                out.append(block)
                continue
            out.append(line)
            i += 1
        body_out = "".join(out) if wanted else body
        if name == TOP and ports:
            body_out, nport = insert_port_delays(body_out, ports)
            inserted += nport
        new_modules.append((name, body_out))
        by_name[name] = body_out

    if inserted < planned:
        raise SystemExit(f"planned {planned} pin buffers but inserted {inserted}")
    NETLIST.write_text(
        prefix + "".join(body for _, body in new_modules) + trailer,
        encoding="utf-8",
        newline="\n",
    )
    print(
        f"inserted {inserted} {CELL} for {len(pins)} pin endpoints"
        f" and {len(ports)} port endpoints"
    )


if __name__ == "__main__":
    main()
