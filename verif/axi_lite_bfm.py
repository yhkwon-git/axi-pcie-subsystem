"""AXI4-Lite channel helpers and a single-beat memory slave for cocotb.

Handshake contract
------------------
DUT outputs are sampled in the ReadOnly region after a rising edge. That
value is what the DUT will sample on the *next* rising edge, because READY
and VALID of the register slice are both registered. Drives are applied one
simulator step after that sample: cocotb rejects signal writes in ReadOnly,
and one step is still before the next clock.

Master VALID and slave VALID sit on opposite sides of the slice, so the
order of coroutines in one timestep cannot create a false handshake.
"""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time

CLK_PERIOD_NS = 10
RESP_OKAY = 0
RESP_DECERR = 3


def idle_inputs(dut) -> None:
    """Drive every DUT input to a quiet zero. The clock is left to Clock()."""
    dut.s_axi_awaddr.value = 0
    dut.s_axi_awprot.value = 0
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wdata.value = 0
    dut.s_axi_wstrb.value = 0
    dut.s_axi_wvalid.value = 0
    dut.s_axi_bready.value = 0
    dut.s_axi_araddr.value = 0
    dut.s_axi_arprot.value = 0
    dut.s_axi_arvalid.value = 0
    dut.s_axi_rready.value = 0

    dut.m_axi_awready.value = 0
    dut.m_axi_wready.value = 0
    dut.m_axi_bresp.value = 0
    dut.m_axi_bvalid.value = 0
    dut.m_axi_arready.value = 0
    dut.m_axi_rdata.value = 0
    dut.m_axi_rresp.value = 0
    dut.m_axi_rvalid.value = 0


async def reset_dut(dut, cycles: int = 5) -> None:
    """Start this test's clock and hold aresetn low for `cycles` rising edges."""
    idle_inputs(dut)
    dut.aresetn.value = 0
    cocotb.start_soon(Clock(dut.aclk, CLK_PERIOD_NS, unit="ns").start())
    for _ in range(cycles):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)
    await ReadOnly()
    # ReadOnly forbids signal writes. Step one simulator tick so callers can drive.
    await Timer(1, unit="step")


async def drive_channel(
    clk,
    beats: list,
    drive_fn,
    valid,
    ready,
    timestamps: list | None = None,
    limit: int = 10000,
) -> None:
    """Present each beat on a VALID/READY channel and retire it on handshake."""
    valid.value = 0
    await RisingEdge(clk)
    await ReadOnly()
    ready_for_next = int(ready.value) == 1
    await Timer(1, unit="step")

    index = 0
    holding = False
    cycles = 0
    while index < len(beats) or holding:
        cycles += 1
        if cycles > limit:
            raise AssertionError("drive_channel exceeded cycle limit")
        if not holding and index < len(beats):
            drive_fn(beats[index])
            valid.value = 1
            holding = True
            index += 1
        await RisingEdge(clk)
        if holding and ready_for_next and timestamps is not None:
            timestamps.append(get_sim_time(unit="ns"))
        await ReadOnly()
        fired = holding and ready_for_next
        ready_for_next = int(ready.value) == 1
        await Timer(1, unit="step")
        if fired:
            valid.value = 0
            holding = False
    valid.value = 0


async def sample_channel(
    clk,
    count: int,
    valid,
    ready,
    sample_fn,
    stall_cycles: int = 0,
    timestamps: list | None = None,
    limit: int = 10000,
) -> list:
    """Accept `count` beats. Each beat waits `stall_cycles` clocks before READY."""
    ready.value = 0
    got: list = []
    stall_left = 0
    beat_open = False
    cycles = 0

    await RisingEdge(clk)
    await ReadOnly()

    while len(got) < count:
        cycles += 1
        if cycles > limit:
            raise AssertionError(
                f"sample_channel exceeded cycle limit with {len(got)}/{count} beats"
            )
        valid_now = int(valid.value) == 1
        if valid_now and not beat_open:
            stall_left = stall_cycles
            beat_open = True

        item = None
        accept = False
        if valid_now and stall_left > 0:
            next_ready = 0
            stall_left -= 1
        elif valid_now:
            item = sample_fn()
            next_ready = 1
            accept = True
        else:
            next_ready = 0
            beat_open = False

        await Timer(1, unit="step")
        ready.value = next_ready

        await RisingEdge(clk)
        if accept and timestamps is not None:
            timestamps.append(get_sim_time(unit="ns"))
        await ReadOnly()
        if accept:
            got.append(item)
            beat_open = False

    await Timer(1, unit="step")
    ready.value = 0
    return got


class AxiLiteMaster:
    """Issues one AXI4-Lite transaction at a time on a slave port.

    `prefix` is the signal stem: ``s_axi_`` on the register slice, ``s0_axi_``
    or ``s1_axi_`` on the crossbar. AW and W are driven together. Response
    READY can be withheld for `resp_stall_cycles` clocks.
    """

    def __init__(self, dut, data_width: int = 32, resp_stall_cycles: int = 0, prefix: str = "s_axi_"):
        self.dut = dut
        self.data_width = data_width
        self.nbytes = data_width // 8
        self.resp_stall_cycles = resp_stall_cycles
        self._data_mask = (1 << data_width) - 1
        self._strb_mask = (1 << self.nbytes) - 1
        self.awaddr = getattr(dut, f"{prefix}awaddr")
        self.awprot = getattr(dut, f"{prefix}awprot")
        self.awvalid = getattr(dut, f"{prefix}awvalid")
        self.awready = getattr(dut, f"{prefix}awready")
        self.wdata = getattr(dut, f"{prefix}wdata")
        self.wstrb = getattr(dut, f"{prefix}wstrb")
        self.wvalid = getattr(dut, f"{prefix}wvalid")
        self.wready = getattr(dut, f"{prefix}wready")
        self.bresp = getattr(dut, f"{prefix}bresp")
        self.bvalid = getattr(dut, f"{prefix}bvalid")
        self.bready = getattr(dut, f"{prefix}bready")
        self.araddr = getattr(dut, f"{prefix}araddr")
        self.arprot = getattr(dut, f"{prefix}arprot")
        self.arvalid = getattr(dut, f"{prefix}arvalid")
        self.arready = getattr(dut, f"{prefix}arready")
        self.rdata = getattr(dut, f"{prefix}rdata")
        self.rresp = getattr(dut, f"{prefix}rresp")
        self.rvalid = getattr(dut, f"{prefix}rvalid")
        self.rready = getattr(dut, f"{prefix}rready")

    async def write(self, addr: int, data: int, strb: int | None = None, prot: int = 0) -> int:
        if strb is None:
            strb = self._strb_mask
        aw = cocotb.start_soon(self._send_aw(addr, prot))
        w = cocotb.start_soon(self._send_w(data, strb))
        await aw
        await w
        return await self._recv_b()

    async def read(self, addr: int, prot: int = 0) -> tuple[int, int]:
        await self._send_ar(addr, prot)
        return await self._recv_r()

    async def _send_aw(self, addr: int, prot: int) -> None:
        def drive(beat) -> None:
            self.awaddr.value = beat[0]
            self.awprot.value = beat[1]

        await drive_channel(
            self.dut.aclk,
            [(addr, prot)],
            drive,
            self.awvalid,
            self.awready,
        )

    async def _send_w(self, data: int, strb: int) -> None:
        def drive(beat) -> None:
            self.wdata.value = beat[0]
            self.wstrb.value = beat[1]

        await drive_channel(
            self.dut.aclk,
            [(data, strb)],
            drive,
            self.wvalid,
            self.wready,
        )

    async def _send_ar(self, addr: int, prot: int) -> None:
        def drive(beat) -> None:
            self.araddr.value = beat[0]
            self.arprot.value = beat[1]

        await drive_channel(
            self.dut.aclk,
            [(addr, prot)],
            drive,
            self.arvalid,
            self.arready,
        )

    async def _recv_b(self) -> int:
        def sample() -> int:
            return int(self.bresp.value) & 0x3

        got = await sample_channel(
            self.dut.aclk,
            1,
            self.bvalid,
            self.bready,
            sample,
            stall_cycles=self.resp_stall_cycles,
        )
        return got[0]

    async def _recv_r(self) -> tuple[int, int]:
        def sample() -> tuple[int, int]:
            data = int(self.rdata.value) & self._data_mask
            resp = int(self.rresp.value) & 0x3
            return data, resp

        got = await sample_channel(
            self.dut.aclk,
            1,
            self.rvalid,
            self.rready,
            sample,
            stall_cycles=self.resp_stall_cycles,
        )
        return got[0]


class AxiLiteMemorySlave:
    """Byte-addressable slave behind the slice master port.

    `stall_cycles` withholds READY on every accepted AW/W/AR beat so the
    skid buffer is forced to take the extra beat. Writes pair AW and W in
    arrival order, which matches AXI4-Lite (no ID).
    """

    def __init__(self, dut, data_width: int = 32, stall_cycles: int = 0, prefix: str = "m_axi_"):
        self.dut = dut
        self.data_width = data_width
        self.nbytes = data_width // 8
        self.stall_cycles = stall_cycles
        self.awaddr = getattr(dut, f"{prefix}awaddr")
        self.awprot = getattr(dut, f"{prefix}awprot")
        self.awvalid = getattr(dut, f"{prefix}awvalid")
        self.awready = getattr(dut, f"{prefix}awready")
        self.wdata = getattr(dut, f"{prefix}wdata")
        self.wstrb = getattr(dut, f"{prefix}wstrb")
        self.wvalid = getattr(dut, f"{prefix}wvalid")
        self.wready = getattr(dut, f"{prefix}wready")
        self.bresp = getattr(dut, f"{prefix}bresp")
        self.bvalid = getattr(dut, f"{prefix}bvalid")
        self.bready = getattr(dut, f"{prefix}bready")
        self.araddr = getattr(dut, f"{prefix}araddr")
        self.arprot = getattr(dut, f"{prefix}arprot")
        self.arvalid = getattr(dut, f"{prefix}arvalid")
        self.arready = getattr(dut, f"{prefix}arready")
        self.rdata = getattr(dut, f"{prefix}rdata")
        self.rresp = getattr(dut, f"{prefix}rresp")
        self.rvalid = getattr(dut, f"{prefix}rvalid")
        self.rready = getattr(dut, f"{prefix}rready")
        self.mem: dict[int, int] = {}
        self.aw_q: list[tuple[int, int]] = []
        self.w_q: list[tuple[int, int]] = []
        self.b_q: list[int] = []
        self.r_q: list[tuple[int, int]] = []
        self.seen_aw: list[tuple[int, int]] = []
        self.seen_ar: list[tuple[int, int]] = []
        self._tasks: list = []
        self._data_mask = (1 << data_width) - 1
        self._strb_mask = (1 << self.nbytes) - 1

    def start(self) -> None:
        self._tasks = [
            cocotb.start_soon(self._aw_loop()),
            cocotb.start_soon(self._w_loop()),
            cocotb.start_soon(self._b_loop()),
            cocotb.start_soon(self._ar_loop()),
            cocotb.start_soon(self._r_loop()),
        ]

    def stop(self) -> None:
        for task in self._tasks:
            cancel = getattr(task, "cancel", None) or getattr(task, "kill", None)
            if cancel is not None:
                cancel()
        self._tasks = []

    def _commit_writes(self) -> None:
        while self.aw_q and self.w_q:
            addr, _prot = self.aw_q.pop(0)
            data, strb = self.w_q.pop(0)
            for lane in range(self.nbytes):
                if (strb >> lane) & 0x1:
                    self.mem[addr + lane] = (data >> (8 * lane)) & 0xFF
            self.b_q.append(RESP_OKAY)

    def _read_word(self, addr: int) -> int:
        data = 0
        for lane in range(self.nbytes):
            data |= self.mem.get(addr + lane, 0) << (8 * lane)
        return data & self._data_mask

    async def _aw_loop(self) -> None:
        def sample() -> tuple[int, int]:
            return int(self.awaddr.value), int(self.awprot.value) & 0x7

        while True:
            got = await sample_channel(
                self.dut.aclk,
                1,
                self.awvalid,
                self.awready,
                sample,
                stall_cycles=self.stall_cycles,
            )
            self.seen_aw.append(got[0])
            self.aw_q.append(got[0])
            self._commit_writes()

    async def _w_loop(self) -> None:
        def sample() -> tuple[int, int]:
            data = int(self.wdata.value) & self._data_mask
            strb = int(self.wstrb.value) & self._strb_mask
            return data, strb

        while True:
            got = await sample_channel(
                self.dut.aclk,
                1,
                self.wvalid,
                self.wready,
                sample,
                stall_cycles=self.stall_cycles,
            )
            self.w_q.append(got[0])
            self._commit_writes()

    async def _b_loop(self) -> None:
        def drive(resp: int) -> None:
            self.bresp.value = resp

        while True:
            if not self.b_q:
                await RisingEdge(self.dut.aclk)
                continue
            resp = self.b_q.pop(0)
            await drive_channel(
                self.dut.aclk,
                [resp],
                drive,
                self.bvalid,
                self.bready,
            )

    async def _ar_loop(self) -> None:
        def sample() -> tuple[int, int]:
            return int(self.araddr.value), int(self.arprot.value) & 0x7

        while True:
            got = await sample_channel(
                self.dut.aclk,
                1,
                self.arvalid,
                self.arready,
                sample,
                stall_cycles=self.stall_cycles,
            )
            addr, prot = got[0]
            self.seen_ar.append((addr, prot))
            self.r_q.append((self._read_word(addr), RESP_OKAY))

    async def _r_loop(self) -> None:
        def drive(beat: tuple[int, int]) -> None:
            self.rdata.value = beat[0]
            self.rresp.value = beat[1]

        while True:
            if not self.r_q:
                await RisingEdge(self.dut.aclk)
                continue
            beat = self.r_q.pop(0)
            await drive_channel(
                self.dut.aclk,
                [beat],
                drive,
                self.rvalid,
                self.rready,
            )
