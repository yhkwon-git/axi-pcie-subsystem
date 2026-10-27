#!/usr/bin/env python3
"""Raise the drive of Sky130 cells on slow ss setup arcs.

OpenSTA's ss report is the input. A cell arc slower than ARC_NS is replaced
with the next stronger drive of the same function (same pins). Delay cells
inserted for hold are left alone. One pass; rerun after STA.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETLIST = ROOT / "asic" / "build" / "nand_sol_subsystem_top.nl.v"
LIB = ROOT / "asic" / "pdk" / "sky130_fd_sc_hd__ss_n40C_1v40.lib"
SETUP = ROOT / "asic" / "build" / "setup_sky130_fd_sc_hd__ss_n40C_1v40.json"
TOP = "nand_sol_subsystem_top"
ARC_NS = 2.0
OUT_PINS = {"Q", "X", "Y", "Z"}
SKIP = ("dly", "conb", "fill", "diode", "decap", "tap", "probe", "clkbuf", "spare", "df")


def liberty_pins(path: Path) -> dict[str, frozenset[str]]:
    pins: dict[str, set[str]] = {}
    cur = None
    depth = cell_depth = 0
    for line in path.open(encoding="latin1"):
        found = re.search(r'cell\s*\(\s*"([^"]+)"\s*\)', line)
        if found and cur is None:
            cur = found.group(1)
            pins[cur] = set()
            cell_depth = depth + line[: found.end()].count("{") + 1
        if cur is not None:
            pinf = re.search(r'pin\s*\(\s*"([^"]+)"\s*\)', line)
            if pinf:
                pins[cur].add(pinf.group(1))
        depth += line.count("{") - line.count("}")
        if cur is not None and depth < cell_depth:
            cur = None
    return {k: frozenset(v) for k, v in pins.items()}


def drive_ladder(cells: dict[str, frozenset[str]]) -> dict[str, str]:
    groups: dict[str, list[tuple[int, str]]] = {}
    for name in cells:
        m = re.match(r"^(.*)_(\d+)$", name)
        if not m:
            continue
        groups.setdefault(m.group(1), []).append((int(m.group(2)), name))
    nxt = {}
    for group in groups.values():
        group.sort()
        for i, (_, name) in enumerate(group):
            pins = cells[name]
            best = None
            for _, cand in group[i + 1 :]:
                if cells[cand] == pins:
                    best = cand
            if best is not None:
                nxt[name] = best
    return nxt


def split_modules(text: str):
    matches = list(re.finditer(r"^module\s+(\S+)\s*\(", text, re.M))
    if not matches:
        raise SystemExit("no modules")
    prefix = text[: matches[0].start()]
    modules = []
    for i, match in enumerate(matches):
        start = match.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        chunk = text[start:end]
        endmod = chunk.rfind("\nendmodule")
        body = chunk[: endmod + len("\nendmodule")]
        if not body.endswith("\n"):
            body += "\n"
        modules.append([match.group(1), body])
        if i + 1 == len(matches):
            trailer = chunk[endmod + len("\nendmodule") :]
    return prefix, modules, trailer


def child_map(modules):
    children = {name: {} for name, _ in modules}
    for name, body in modules:
        for line in body.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith(
                ("wire ", "assign ", "input ", "output ", "reg ", "module ", "endmodule")
            ):
                continue
            if "(" not in stripped:
                continue
            tokens = stripped.split()
            if len(tokens) < 2:
                continue
            cell, inst = tokens[0], tokens[1].rstrip("(")
            if cell.startswith("sky130_") or inst == "(":
                continue
            children[name][inst] = cell
    return children


def locate(hier: str, children) -> tuple[str, str] | None:
    if not hier:
        return None
    parts = hier.split("/")
    mod = TOP
    for part in parts[:-1]:
        mod = children.get(mod, {}).get(part)
        if mod is None:
            return None
    return mod, parts[-1]


def slow_arcs(path: Path, children, nxt):
    want: dict[tuple[str, str], tuple[str, str, float]] = {}
    missed = 0
    start = end = None
    in_src = False
    prev_arr = None
    cell = pin = None
    inst = None
    arrival = None
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            s = line.strip().rstrip(",")
            if s.startswith('"source_path"'):
                in_src = True
                prev_arr = None
                continue
            if s.startswith('"target_clock"'):
                in_src = False
                continue
            if not in_src:
                continue
            if s.startswith('"cell"'):
                cell = s.split(":", 1)[1].strip().strip('"')
            elif s.startswith('"pin"'):
                pin = s.split(":", 1)[1].strip().strip('"')
            elif s.startswith('"instance"'):
                inst = s.split(":", 1)[1].strip().strip('"')
            elif s.startswith('"arrival"'):
                arrival = float(s.split(":", 1)[1])
            elif s.startswith("}"):
                if cell and pin and arrival is not None:
                    leaf = pin.split("/")[-1]
                    if leaf in OUT_PINS and inst:
                        arc = arrival * 1e9 if prev_arr is None else (arrival - prev_arr) * 1e9
                        base = cell.replace("sky130_fd_sc_hd__", "")
                        stronger = None
                        if base in {"buf_1", "buf_2", "buf_4", "buf_6"} and arc > 1.0:
                            stronger = "sky130_fd_sc_hd__buf_8"
                        elif base in {"buf_8", "buf_12"} and arc > 1.0:
                            stronger = "sky130_fd_sc_hd__buf_16"
                        if stronger and inst:
                            found = locate(inst, children)
                            if found is None:
                                missed += 1
                            else:
                                prev = want.get(found)
                                if prev is None or arc > prev[2]:
                                    want[found] = (cell, stronger, arc)
                    prev_arr = arrival
                cell = pin = inst = None
                arrival = None
    return want, missed


def main() -> None:
    cells = liberty_pins(LIB)
    nxt = drive_ladder(cells)
    print(f"liberty cells {len(cells)}  drive steps {len(nxt)}")
    text = NETLIST.read_text(encoding="utf-8")
    prefix, modules, trailer = split_modules(text)
    children = child_map(modules)
    want, missed = slow_arcs(SETUP, children, nxt)
    bodies = {name: body for name, body in modules}
    done = 0
    for (mod, inst), (old, new, arc) in want.items():
        body = bodies[mod]
        pat = re.compile(
            rf"^(\s*){re.escape(old)}(\s+{re.escape(inst)}\s*\()",
            re.M,
        )
        body2, n = pat.subn(rf"\1{new}\2", body, count=1)
        if n != 1:
            continue
        bodies[mod] = body2
        done += 1
    ordered = []
    for name, body in modules:
        ordered.append(bodies[name])
    NETLIST.write_text(prefix + "".join(ordered) + trailer, encoding="utf-8")
    print(f"upsized {done} of {len(want)} slow instances  unresolved {missed}")


if __name__ == "__main__":
    main()
