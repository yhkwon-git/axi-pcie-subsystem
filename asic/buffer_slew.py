#!/usr/bin/env python3
"""Put a buf_8 on the output of a Sky130 arc that is slow at ss.

The multi-nanosecond nor2 arcs are weak drivers into a legal but heavy load.
The nor2 then drives only the buffer input, and buf_8 drives the old net.
One pass; rerun after STA.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETLIST = ROOT / "asic" / "build" / "nand_sol_subsystem_top.nl.v"
SETUP = ROOT / "asic" / "build" / "setup_sky130_fd_sc_hd__ss_n40C_1v40.json"
TOP = "nand_sol_subsystem_top"
ARC_NS = float(os.environ.get("ARC_NS", "2.0"))
BUF = "sky130_fd_sc_hd__buf_8"
OUT_PINS = {"Q", "X", "Y", "Z"}
SKIP = ("dly", "df", "buf", "clkbuf", "conb", "diode", "fill", "decap", "tap")


def split_modules(text: str):
    matches = list(re.finditer(r"^module\s+(\S+)\s*\(", text, re.M))
    prefix = text[: matches[0].start()]
    modules = []
    trailer = ""
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


def locate(hier: str, children):
    if not hier:
        return None
    parts = hier.split("/")
    mod = TOP
    for part in parts[:-1]:
        mod = children.get(mod, {}).get(part)
        if mod is None:
            return None
    return mod, parts[-1]


def slow_inputs(path: Path, children):
    want = {}
    missed = 0
    in_src = False
    prev = None
    cur = {}
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            s = line.strip().rstrip(",")
            if s.startswith('"source_path"'):
                in_src = True
                prev = None
                continue
            if s.startswith('"target_clock"'):
                in_src = False
                continue
            if not in_src:
                continue
            if s.startswith('"cell"'):
                cur["cell"] = s.split(":", 1)[1].strip().strip('"')
            elif s.startswith('"pin"'):
                cur["pin"] = s.split(":", 1)[1].strip().strip('"')
            elif s.startswith('"instance"'):
                cur["inst"] = s.split(":", 1)[1].strip().strip('"')
            elif s.startswith('"net"'):
                cur["net"] = s.split(":", 1)[1].strip().strip('"')
            elif s.startswith('"arrival"'):
                cur["arrival"] = float(s.split(":", 1)[1])
            elif s.startswith("}"):
                if cur.get("pin") and cur.get("arrival") is not None:
                    leaf = cur["pin"].split("/")[-1]
                    arc = None
                    if prev and prev.get("arrival") is not None:
                        arc = (cur["arrival"] - prev["arrival"]) * 1e9
                    base = (cur.get("cell") or "").replace("sky130_fd_sc_hd__", "")
                    if (
                        leaf in OUT_PINS
                        and arc is not None
                        and arc > ARC_NS
                        and cur.get("net")
                        and not any(k in base for k in SKIP)
                    ):
                        found = locate(cur.get("inst") or "", children)
                        parent = (cur.get("inst") or "").rsplit("/", 1)[0]
                        net = cur["net"]
                        if parent and net.startswith(parent + "/"):
                            net = net[len(parent) + 1 :]
                        if found is None or leaf in {"Q", "CLK"}:
                            missed += 1
                        else:
                            want[(found[0], found[1], leaf, net)] = arc
                    prev = dict(cur)
                cur = {}
    return want, missed


def main() -> None:
    text = NETLIST.read_text(encoding="utf-8")
    prefix, modules, trailer = split_modules(text)
    children = child_map(modules)
    want, missed = slow_inputs(SETUP, children)
    bodies = {name: body for name, body in modules}
    by_mod: dict[str, list] = {}
    for (mod, inst, pin, net), arc in want.items():
        by_mod.setdefault(mod, []).append((inst, pin, net, arc))
    done = 0
    used = [int(x) for x in re.findall(r"_slew_u(\d+)_", text)]
    seq = max(used) + 1 if used else 0
    for mod, items in by_mod.items():
        body = bodies[mod]
        extra = []
        for inst, pin, net, _arc in items:
            mark = re.search(
                rf"\n(\s*)\S+\s+{re.escape(inst)}\s*\(",
                body,
            )
            if not mark:
                continue
            start = mark.start()
            depth = 0
            end = None
            for i, ch in enumerate(body[start:], start):
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        end = i + 1
                        break
            if end is None:
                continue
            block = body[start:end]
            pin_pat = re.compile(rf"(\.{re.escape(pin)}\()\s*{re.escape(net)}\s*(\))")
            if not pin_pat.search(block):
                continue
            wire = f"_slew_{seq}_"
            seq += 1
            block2 = pin_pat.sub(rf"\1{wire}\2", block, count=1)
            body = body[:start] + block2 + body[end:]
            extra.append(f"  wire {wire};")
            extra.append(
                f"  {BUF} _slew_u{seq}_ (\n    .A({wire}),\n    .X({net})\n  );"
            )
            done += 1
        if extra:
            body = body.replace("\nendmodule", "\n" + "\n".join(extra) + "\nendmodule", 1)
        bodies[mod] = body
    NETLIST.write_text(prefix + "".join(bodies[n] for n, _ in modules) + trailer, encoding="utf-8")
    print(f"buffered {done} of {len(want)} slow inputs  unresolved {missed}")


if __name__ == "__main__":
    main()
