"""Self-checking scoreboard for nand_sol_subsystem_top.

The test predicts each posted write and each memory read before the DUT runs.
check_memories() compares those writes with the bytes captured on the AXI
slave ports. observe_completion() compares the next predicted read with one
CplD. check_outstanding() compares the sampled queue occupancy with the
peak the test expects. finish() raises if any comparison failed or a
predicted completion was never seen.
"""

from __future__ import annotations


class Scoreboard:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self._writes: list[tuple[str, int, int, int]] = []
        self._reads: list[dict] = []

    def expect_write(self, port: str, addr: int, data: int, strb: int = 0xF) -> None:
        self._writes.append((port, addr & 0xFFFF_FFFF, data & 0xFFFF_FFFF, strb & 0xF))

    def expect_read(
        self,
        addr: int,
        data: int,
        req_id: int,
        tag: int,
        completer: int = 0x0100,
    ) -> None:
        self._reads.append(
            {
                "addr": addr & 0xFFFF_FFFF,
                "data": data & 0xFFFF_FFFF,
                "req_id": req_id & 0xFFFF,
                "tag": tag & 0xFF,
                "completer": completer & 0xFFFF,
            }
        )

    def check(self, name: str, got, expected) -> None:
        if got != expected:
            self.failures.append(f"{name}: got {got!r}, expected {expected!r}")

    def check_memories(self, mems: dict[str, dict[int, int]]) -> None:
        for port, addr, data, strb in self._writes:
            mem = mems[port]
            for lane in range(4):
                if ((strb >> lane) & 1) == 0:
                    continue
                byte = (data >> (8 * lane)) & 0xFF
                self.check(f"{port}[0x{addr + lane:08X}]", mem.get(addr + lane), byte)
            for other, other_mem in mems.items():
                if other == port:
                    continue
                for lane in range(4):
                    if ((strb >> lane) & 1) == 0:
                        continue
                    self.check(
                        f"{other} holds 0x{addr + lane:08X}",
                        other_mem.get(addr + lane),
                        None,
                    )

    def observe_completion(self, words: list[tuple[int, int, int]]) -> None:
        if not self._reads:
            self.failures.append(f"unexpected completion: {words}")
            return
        exp = self._reads.pop(0)
        self.check("cpl dword count", len(words), 4)
        if len(words) != 4:
            return
        flags = tuple((word[0], word[1]) for word in words)
        self.check("cpl sop/eop", flags, ((1, 0), (0, 0), (0, 0), (0, 1)))
        dw0, dw1, dw2, payload = (word[2] & 0xFFFF_FFFF for word in words)
        lower = exp["addr"] & 0x7F
        self.check("cpl dw0", dw0, (0b010 << 29) | (0b01010 << 24) | 1)
        self.check("cpl dw1", dw1, (exp["completer"] << 16) | 4)
        self.check(
            "cpl dw2",
            dw2,
            (exp["req_id"] << 16) | (exp["tag"] << 8) | lower,
        )
        self.check("cpl data", payload, exp["data"])

    def check_outstanding(self, samples: list[int], peak: int) -> None:
        if not samples:
            self.failures.append("outstanding queue was not sampled")
            return
        self.check("outstanding peak", max(samples), peak)
        self.check("outstanding drained", samples[-1], 0)

    def raise_if_failed(self) -> None:
        if self.failures:
            raise AssertionError("scoreboard mismatches:\n" + "\n".join(self.failures))

    def finish(self) -> None:
        if self._reads:
            self.failures.append(f"{len(self._reads)} expected completions were not seen")
        self.raise_if_failed()
