"""Drive nand_sol_subsystem_top across clk_pcie and clk_axi.

A 1DW Memory Write/Read is the transaction the AXI4-Lite crossbar can carry.
One write lands in the MI0 window and one in the MI1 window. The scoreboard
checks the slave bytes and the CplD. While each read is in flight, oq_count
is 1 and returns to 0 when the beat completes. A firmware write on the CPU
port reaches MI0 and does not allocate a host read ID.
"""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

from axi_lite_bfm import drive_channel, sample_channel
from scoreboard import Scoreboard


def _dw0(fmt: int, length: int) -> int:
    return ((fmt & 0x7) << 29) | (length & 0x3FF)


def _dw1(req_id: int, tag: int, last_be: int, first_be: int) -> int:
    return ((req_id & 0xFFFF) << 16) | ((tag & 0xFF) << 8) | ((last_be & 0xF) << 4) | (first_be & 0xF)


async def reset_top(dut) -> None:
    dut.tlp_valid.value = 0
    dut.tlp_sop.value = 0
    dut.tlp_eop.value = 0
    dut.tlp_data.value = 0
    dut.cpl_ready.value = 0
    for name in (
        "awaddr",
        "awprot",
        "awvalid",
        "wdata",
        "wstrb",
        "wvalid",
        "bready",
        "araddr",
        "arprot",
        "arvalid",
        "rready",
    ):
        getattr(dut, f"cpu_axi_{name}").value = 0
    for prefix in ("m0_axi_", "m1_axi_"):
        for name in ("awready", "wready", "bresp", "bvalid", "arready", "rdata", "rresp", "rvalid"):
            getattr(dut, f"{prefix}{name}").value = 0
    dut.rst_pcie_n.value = 0
    dut.rst_axi_n.value = 0
    cocotb.start_soon(Clock(dut.clk_pcie, 8, unit="ns").start())
    cocotb.start_soon(Clock(dut.clk_axi, 10, unit="ns").start())
    for _ in range(5):
        await RisingEdge(dut.clk_pcie)
    for _ in range(5):
        await RisingEdge(dut.clk_axi)
    await RisingEdge(dut.clk_axi)
    dut.rst_axi_n.value = 1
    await RisingEdge(dut.clk_pcie)
    dut.rst_pcie_n.value = 1
    await RisingEdge(dut.clk_axi)
    await RisingEdge(dut.clk_pcie)
    await ReadOnly()
    await Timer(1, unit="step")


async def send_beat(dut, data: int, sop: int, eop: int) -> None:
    for _ in range(10000):
        await RisingEdge(dut.clk_pcie)
        await ReadOnly()
        ready = int(dut.tlp_ready.value)
        await Timer(1, unit="step")
        if not ready:
            dut.tlp_valid.value = 0
            continue
        dut.tlp_data.value = data
        dut.tlp_sop.value = sop
        dut.tlp_eop.value = eop
        dut.tlp_valid.value = 1
        await RisingEdge(dut.clk_pcie)
        await ReadOnly()
        await Timer(1, unit="step")
        dut.tlp_valid.value = 0
        dut.tlp_sop.value = 0
        dut.tlp_eop.value = 0
        return
    raise AssertionError("TLP beat was not accepted")


async def collect_completion(dut) -> list[tuple[int, int, int]]:
    words: list[tuple[int, int, int]] = []
    for _ in range(20000):
        await RisingEdge(dut.clk_pcie)
        await ReadOnly()
        valid = int(dut.cpl_valid.value)
        if not valid:
            await Timer(1, unit="step")
            dut.cpl_ready.value = 0
            continue
        word = (
            int(dut.cpl_sop.value),
            int(dut.cpl_eop.value),
            int(dut.cpl_data.value) & 0xFFFF_FFFF,
        )
        await Timer(1, unit="step")
        dut.cpl_ready.value = 1
        await RisingEdge(dut.clk_pcie)
        await ReadOnly()
        await Timer(1, unit="step")
        dut.cpl_ready.value = 0
        words.append(word)
        if word[1]:
            return words
    raise AssertionError("completion did not end")


async def lite_memory(dut, prefix: str, mem: dict[int, int]) -> None:
    """One AXI4-Lite beat at a time on clk_axi. VALID is held by the slice."""
    clk = dut.clk_axi
    awvalid = getattr(dut, f"{prefix}awvalid")
    awready = getattr(dut, f"{prefix}awready")
    awaddr = getattr(dut, f"{prefix}awaddr")
    wvalid = getattr(dut, f"{prefix}wvalid")
    wready = getattr(dut, f"{prefix}wready")
    wdata = getattr(dut, f"{prefix}wdata")
    wstrb = getattr(dut, f"{prefix}wstrb")
    bvalid = getattr(dut, f"{prefix}bvalid")
    bready = getattr(dut, f"{prefix}bready")
    bresp = getattr(dut, f"{prefix}bresp")
    arvalid = getattr(dut, f"{prefix}arvalid")
    arready = getattr(dut, f"{prefix}arready")
    araddr = getattr(dut, f"{prefix}araddr")
    rvalid = getattr(dut, f"{prefix}rvalid")
    rready = getattr(dut, f"{prefix}rready")
    rdata = getattr(dut, f"{prefix}rdata")
    rresp = getattr(dut, f"{prefix}rresp")

    while True:
        await RisingEdge(clk)
        await ReadOnly()
        see_aw = int(awvalid.value) == 1
        see_ar = int(arvalid.value) == 1
        await Timer(1, unit="step")
        if see_aw:
            def sample_aw():
                return int(awaddr.value)

            addr = (await sample_channel(clk, 1, awvalid, awready, sample_aw))[0]

            def sample_w():
                return (int(wdata.value) & 0xFFFF_FFFF, int(wstrb.value) & 0xF)

            data, strb = (await sample_channel(clk, 1, wvalid, wready, sample_w))[0]
            for lane in range(4):
                if (strb >> lane) & 1:
                    mem[addr + lane] = (data >> (8 * lane)) & 0xFF

            def drive_b(_beat: int) -> None:
                bresp.value = 0

            await drive_channel(clk, [0], drive_b, bvalid, bready)
        elif see_ar:
            def sample_ar():
                return int(araddr.value)

            addr = (await sample_channel(clk, 1, arvalid, arready, sample_ar))[0]
            data = 0
            for lane in range(4):
                data |= mem.get(addr + lane, 0) << (8 * lane)

            def drive_r(beat: int) -> None:
                rdata.value = beat
                rresp.value = 0

            await drive_channel(clk, [data], drive_r, rvalid, rready)


async def send_mwr(dut, addr: int, data: int, req_id: int, tag: int) -> None:
    await send_beat(dut, _dw0(0b010, 1), sop=1, eop=0)
    await send_beat(dut, _dw1(req_id, tag, 0x0, 0xF), sop=0, eop=0)
    await send_beat(dut, addr, sop=0, eop=0)
    await send_beat(dut, data, sop=0, eop=1)


async def send_mrd(dut, addr: int, req_id: int, tag: int) -> None:
    await send_beat(dut, _dw0(0b000, 1), sop=1, eop=0)
    await send_beat(dut, _dw1(req_id, tag, 0x0, 0xF), sop=0, eop=0)
    await send_beat(dut, addr, sop=0, eop=1)


async def wait_byte(dut, mem: dict[int, int], addr: int, value: int, cycles: int = 4000) -> None:
    for _ in range(cycles):
        if mem.get(addr) == value:
            return
        await RisingEdge(dut.clk_axi)
    raise AssertionError(f"byte 0x{addr:08X} stayed {mem.get(addr)!r}, expected {value}")


async def watch_count(dut, samples: list[int], running: list[bool]) -> None:
    while running[0]:
        await RisingEdge(dut.clk_axi)
        await ReadOnly()
        samples.append(int(dut.oq_count.value))


async def watch_error(dut, pulses: list[int]) -> None:
    while True:
        await RisingEdge(dut.clk_axi)
        await ReadOnly()
        if int(dut.tlp_error.value) == 1:
            pulses.append(1)


async def cpu_write(dut, addr: int, data: int) -> int:
    clk = dut.clk_axi

    def drive_aw(_beat: int) -> None:
        dut.cpu_axi_awaddr.value = addr
        dut.cpu_axi_awprot.value = 0

    await drive_channel(clk, [0], drive_aw, dut.cpu_axi_awvalid, dut.cpu_axi_awready)

    def drive_w(_beat: int) -> None:
        dut.cpu_axi_wdata.value = data
        dut.cpu_axi_wstrb.value = 0xF

    await drive_channel(clk, [0], drive_w, dut.cpu_axi_wvalid, dut.cpu_axi_wready)

    def sample_b():
        return int(dut.cpu_axi_bresp.value)

    return (await sample_channel(clk, 1, dut.cpu_axi_bvalid, dut.cpu_axi_bready, sample_b))[0]


async def cpu_read(dut, addr: int) -> tuple[int, int]:
    clk = dut.clk_axi

    def drive_ar(_beat: int) -> None:
        dut.cpu_axi_araddr.value = addr
        dut.cpu_axi_arprot.value = 0

    await drive_channel(clk, [0], drive_ar, dut.cpu_axi_arvalid, dut.cpu_axi_arready)

    def sample_r():
        return (int(dut.cpu_axi_rdata.value) & 0xFFFF_FFFF, int(dut.cpu_axi_rresp.value))

    return (await sample_channel(clk, 1, dut.cpu_axi_rvalid, dut.cpu_axi_rready, sample_r))[0]


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_single_beat_windows_track_read_id(dut):
    """1DW host traffic hits MI0 and MI1, and the read ID is tracked."""
    await reset_top(dut)
    await RisingEdge(dut.clk_pcie)
    await ReadOnly()
    assert int(dut.tlp_ready.value) == 1
    assert int(dut.cpl_valid.value) == 0
    assert int(dut.m0_axi_awvalid.value) == 0
    assert int(dut.m1_axi_awvalid.value) == 0
    assert int(dut.oq_empty.value) == 1
    assert int(dut.oq_full.value) == 0
    assert int(dut.oq_count.value) == 0
    await Timer(1, unit="step")

    sb = Scoreboard()
    mem0: dict[int, int] = {}
    mem1: dict[int, int] = {}
    errors: list[int] = []
    m0 = cocotb.start_soon(lite_memory(dut, "m0_axi_", mem0))
    m1 = cocotb.start_soon(lite_memory(dut, "m1_axi_", mem1))
    err = cocotb.start_soon(watch_error(dut, errors))
    try:
        req_id = 0x0ABC
        sb.expect_write("m0", 0x0000_0010, 0xA1B2_C3D4)
        sb.expect_write("m1", 0x0001_0020, 0x55AA_55AA)
        await send_mwr(dut, 0x0000_0010, 0xA1B2_C3D4, req_id, 0x3C)
        await send_mwr(dut, 0x0001_0020, 0x55AA_55AA, req_id, 0x11)
        await wait_byte(dut, mem0, 0x10, 0xD4)
        await wait_byte(dut, mem1, 0x0001_0020, 0xAA)
        sb.check_memories({"m0": mem0, "m1": mem1})
        sb.check("queue idle after posted writes", int(dut.oq_count.value), 0)

        for _ in range(4):
            await RisingEdge(dut.clk_pcie)
            await ReadOnly()
            sb.check("posted write has no completion", int(dut.cpl_valid.value), 0)
        await Timer(1, unit="step")

        samples: list[int] = []
        running = [True]
        watcher = cocotb.start_soon(watch_count(dut, samples, running))
        sb.expect_read(0x0000_0010, 0xA1B2_C3D4, req_id, 0x3C)
        sb.expect_read(0x0001_0020, 0x55AA_55AA, req_id, 0x11)
        await send_mrd(dut, 0x0000_0010, req_id, 0x3C)
        sb.observe_completion(await collect_completion(dut))
        await send_mrd(dut, 0x0001_0020, req_id, 0x11)
        sb.observe_completion(await collect_completion(dut))
        for _ in range(8):
            await RisingEdge(dut.clk_axi)
        running[0] = False
        await RisingEdge(dut.clk_axi)
        watcher.cancel()
        sb.check_outstanding(samples, peak=1)

        cpu_samples: list[int] = []
        cpu_running = [True]
        cpu_watch = cocotb.start_soon(watch_count(dut, cpu_samples, cpu_running))
        sb.expect_write("m0", 0x0000_0030, 0x0102_0304)
        bresp = await cpu_write(dut, 0x0000_0030, 0x0102_0304)
        rdata, rresp = await cpu_read(dut, 0x0000_0030)
        for _ in range(4):
            await RisingEdge(dut.clk_axi)
        cpu_running[0] = False
        await RisingEdge(dut.clk_axi)
        cpu_watch.cancel()
        sb.check("cpu bresp", bresp, 0)
        sb.check("cpu rdata", rdata, 0x0102_0304)
        sb.check("cpu rresp", rresp, 0)
        sb.check_memories({"m0": mem0, "m1": mem1})
        sb.check_outstanding(cpu_samples, peak=0)
        sb.check("tlp_error pulses", len(errors), 0)
        sb.finish()
    finally:
        m0.cancel()
        m1.cancel()
        err.cancel()
