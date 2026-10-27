# Print the worst ss setup path for each top-level pair.
import collections

path = "asic/build/setup_sky130_fd_sc_hd__ss_n40C_1v40.json"
start = end = None
in_src = False
cur = []
seen = {}
order = []

def top(pin):
    if not pin:
        return "?"
    return pin.split("/")[0] if "/" in pin else pin

with open(path, encoding="utf-8", errors="replace") as fh:
    cell = pin = net = None
    arrival = None
    for line in fh:
        s = line.strip().rstrip(",")
        if s.startswith('"source_path"'):
            in_src = True
            cur = []
            cell = pin = net = None
            arrival = None
            continue
        if s.startswith('"target_clock"'):
            in_src = False
            continue
        if s.startswith('"startpoint"'):
            start = s.split(":", 1)[1].strip().strip('"')
        elif s.startswith('"endpoint"'):
            end = s.split(":", 1)[1].strip().strip('"')
        elif in_src:
            if s.startswith('"cell"'):
                cell = s.split(":", 1)[1].strip().strip('"')
            elif s.startswith('"pin"'):
                pin = s.split(":", 1)[1].strip().strip('"')
            elif s.startswith('"net"'):
                net = s.split(":", 1)[1].strip().strip('"')
            elif s.startswith('"arrival"'):
                arrival = float(s.split(":", 1)[1])
            elif s.startswith("}"):
                if cell and pin and arrival is not None:
                    short = cell.replace("sky130_fd_sc_hd__", "")
                    leaf = pin.split("/")[-1]
                    if leaf in ("Q", "X", "Y"):
                        cur.append((short, leaf, net or "", arrival * 1e9))
                cell = pin = net = None
                arrival = None
        elif s.startswith('"slack"'):
            key = (top(start), top(end))
            if key not in seen:
                seen[key] = (start, end, float(s.split(":", 1)[1]) * 1e9, list(cur))
                order.append(key)

want = {
    ("u_tlp_ingress", "u_bridge"),
    ("u_bridge", "u_bridge"),
    ("u_bridge", "u_cpl_egress"),
    ("tlp_valid", "u_tlp_ingress"),
    ("u_cpl_egress", "u_cpl_egress"),
    ("u_bridge", "u_slice_host"),
    ("u_bridge", "u_oq"),
    ("u_xbar", "u_slice_nand"),
    ("u_xbar", "u_xbar"),
    ("u_slice_host", "u_xbar"),
    ("u_oq", "u_oq"),
    ("u_cpl_egress", "cpl_data[11]"),
}
for key in order:
    if key not in want:
        continue
    sp, ep, ns, hops = seen[key]
    print(f"\n== {key[0]} -> {key[1]}  slack {ns:.2f} ns  hops {len(hops)}")
    print(f"   {sp}")
    print(f"   {ep}")
    for short, leaf, net, arr in hops:
        print(f"   {arr:7.2f}  {short:16} {net}")
