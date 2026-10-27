#!/usr/bin/env python3
"""Insert Sky130 buf_8 trees where a driver's load exceeds its max_capacitance.

The FIFO read and write enables are single-cycle nets. ABC's set_load does not
see the flop pin capacitance, so a few enables stay outside the liberty table.
This pass only splits those nets. It does not touch CLK pins.
"""
import re
import sys
from collections import defaultdict

LIB = "asic/pdk/sky130_fd_sc_hd__ss_n40C_1v40.lib"
BUF = "sky130_fd_sc_hd__buf_8"
MARGIN = 0.90


def parse_liberty(path):
    cells = {}
    cur = pin = None
    depth = cell_depth = pin_depth = 0
    for line in open(path, encoding="latin1"):
        stripped = line.strip()
        if pin is not None:
            if pin["direction"] is None and stripped.startswith("direction"):
                pin["direction"] = stripped.split()[2].rstrip(";").strip('"')
            elif pin["cap"] is None and stripped.startswith("capacitance "):
                pin["cap"] = float(stripped.split()[2].rstrip(";"))
            elif pin["max_cap"] is None and stripped.startswith("max_capacitance"):
                pin["max_cap"] = float(stripped.split()[2].rstrip(";"))
        if cur is None:
            found = re.search(r'cell\s*\(\s*"([^"]+)"\s*\)', line)
            if found:
                cur = {"pins": {}}
                cells[found.group(1)] = cur
                cell_depth = depth + line[: found.end()].count("{") + 1
        elif pin is None:
            found = re.search(r'pin\s*\(\s*"([^"]+)"\s*\)', line)
            if found:
                pin = {"direction": None, "cap": None, "max_cap": None, "table_max": None}
                cur["pins"][found.group(1)] = pin
                pin_depth = depth + line[: found.end()].count("{") + 1
        if pin is not None:
            found = re.search(r'index_2\("([^"]+)"\)', line)
            if found:
                last = float(found.group(1).split(",")[-1])
                if pin["table_max"] is None or last > pin["table_max"]:
                    pin["table_max"] = last
        depth += line.count("{") - line.count("}")
        if pin is not None and depth < pin_depth:
            pin = None
        if cur is not None and depth < cell_depth:
            cur = None
            pin = None
    return cells


INST_RE = re.compile(r"(sky130_fd_sc_hd__\w+)\s+(\S+)\s*\((.*?)\);", re.S)
PIN_RE = re.compile(r"\.(\w+)\(\s*([^)]*?)\s*\)")
CONST_RE = re.compile(r"^\d+'[bhdBHD][0-9a-fA-FxXzZ]+$")


def drive_limit(pin):
    caps = [c for c in (pin["max_cap"], pin["table_max"]) if c]
    if not caps:
        return None
    return min(caps)


def parse_module(body, cells):
    insts = []
    for m in INST_RE.finditer(body):
        pins = []
        for pm in PIN_RE.finditer(m.group(3)):
            net = pm.group(2).strip()
            pins.append([pm.group(1), net])
        insts.append({"cell": m.group(1), "name": m.group(2), "pins": pins, "span": m.span()})
    return insts


def fix_module(body, cells, buf_in, buf_max):
    insts = parse_module(body, cells)
    if not insts:
        return body, 0
    loads = defaultdict(list)
    drivers = defaultdict(list)
    for ii, inst in enumerate(insts):
        info = cells.get(inst["cell"])
        if info is None:
            continue
        for pi, (pin, net) in enumerate(inst["pins"]):
            if CONST_RE.match(net) or net in {"1'b0", "1'b1"}:
                continue
            meta = info["pins"].get(pin)
            if meta is None or meta["direction"] is None:
                continue
            if meta["direction"] == "input":
                loads[net].append((ii, pi, meta["cap"] or 0.0, pin))
            elif meta["direction"] == "output":
                drivers[net].append((ii, pi, drive_limit(meta), pin))
    extra = []
    nbuf = 0
    seq = 0
    for net, drvs in drivers.items():
        if len(drvs) != 1:
            continue
        ii, pi, max_cap, pin = drvs[0]
        if pin == "CLK" or max_cap is None:
            continue
        load_pins = [item for item in loads.get(net, []) if item[3] != "CLK"]
        if not load_pins:
            continue
        total = sum(item[2] for item in load_pins)
        limit = MARGIN * max_cap
        if total <= limit:
            continue
        # Leaf buffers, each held to buf_max. The driver only sees buffer inputs.
        group = []
        groups = []
        acc = 0.0
        for item in load_pins:
            if group and acc + item[2] > MARGIN * buf_max:
                groups.append(group)
                group = []
                acc = 0.0
            group.append(item)
            acc += item[2]
        if group:
            groups.append(group)
        # If the driver still cannot feed every leaf input, add one more stage.
        stages = [groups]
        if len(groups) * buf_in > limit:
            stages = [[("leaf", k) for k in range(len(groups))]]
        # One stage is enough when leaf-input cap fits. Build leaves only.
        driver_net = net
        if len(groups) * buf_in > limit:
            mid = f"_fanbuf_m{seq}_"
            seq += 1
            extra.append(f"  wire {mid};")
            extra.append(
                f"  {BUF} _fanbuf_u{nbuf}_ (\n    .A({driver_net}),\n    .X({mid})\n  );"
            )
            nbuf += 1
            driver_net = mid
        for group in groups:
            leaf = f"_fanbuf_n{seq}_"
            seq += 1
            extra.append(f"  wire {leaf};")
            extra.append(
                f"  {BUF} _fanbuf_u{nbuf}_ (\n    .A({driver_net}),\n    .X({leaf})\n  );"
            )
            nbuf += 1
            for lii, lpi, _, _ in group:
                insts[lii]["pins"][lpi][1] = leaf
    if nbuf == 0:
        return body, 0
    # Rewrite instances from the end so spans stay valid.
    for inst in reversed(insts):
        a, b = inst["span"]
        pin_txt = ",\n".join(f"    .{p}({n})" for p, n in inst["pins"])
        repl = f"{inst['cell']} {inst['name']} (\n{pin_txt}\n  );"
        body = body[:a] + repl + body[b:]
    body = body.replace("\nendmodule", "\n" + "\n".join(extra) + "\nendmodule", 1)
    return body, nbuf


def main():
    path = sys.argv[1]
    lib = sys.argv[2] if len(sys.argv) > 2 else LIB
    cells = parse_liberty(lib)
    buf = cells[BUF]
    buf_in = buf["pins"]["A"]["cap"]
    buf_max = min(c for c in (buf["pins"]["X"]["max_cap"], buf["pins"]["X"]["table_max"]) if c)
    text = open(path, encoding="utf-8").read()
    parts = re.split(r"(?=module )", text)
    out = []
    total = 0
    for part in parts:
        if part.startswith("module "):
            part, n = fix_module(part, cells, buf_in, buf_max)
            total += n
        out.append(part)
    open(path, "w", encoding="utf-8", newline="\n").write("".join(out))
    print(f"inserted {total} {BUF}  input_cap={buf_in:.4f}pF  max_cap={buf_max:.4f}pF")


if __name__ == "__main__":
    main()
