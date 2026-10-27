import collections
path = "asic/build/hold_sky130_fd_sc_hd__ff_100C_1v95.json"
n = 0
ports = collections.Counter()
pins = 0
ep = None
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        s = line.strip().rstrip(",")
        if s.startswith('"endpoint"'):
            ep = s.split(":", 1)[1].strip().strip('"')
        elif s.startswith('"slack"') and ep:
            n += 1
            if "/" not in ep:
                ports[ep.split("[")[0]] += 1
            else:
                pins += 1
            ep = None
print("endpoints", n, "pins", pins)
for k, v in ports.most_common():
    print(f"  {v:4} {k}")
