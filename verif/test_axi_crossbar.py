"""Cocotb tests for the 2x2 AXI4-Lite crossbar.

Default address map (see axi_crossbar):
  MI0 / downstream slave 0: 0x0000_0000 - 0x0000_FFFF
  MI1 / downstream slave 1: 0x0001_0000 - 0x0001_FFFF
Anything else is DECERR on the requesting master and is not forwarded.
"""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time

from axi_lite_bfm import (
    CLK_PERIOD_NS,
    RESP_DECERR,
    RESP_OKAY,
    AxiLiteMaster,
    AxiLiteMemorySlave,
)


def _bit(dut, name: str) -> int:
    return int(getattr(dut, name).value)


def _store(slave: AxiLiteMemorySlave, addr: int, data: int) -> None:
    for lane in range(slave.nbytes):
        slave.mem[addr + lane] = (data >> (8 * lane)) & 0xFF


def _idle(dut, prefix: str, names: tuple[str, ...]) -> None:
    for name in names:
        getattr(dut, f"{prefix}{name}").value = 0


async def reset_crossbar(dut, cycles: int = 5) -> None:
    """Start the clock and hold aresetn low. Leaves the caller able to drive."""
    master_inputs = (
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
    )
    slave_inputs = (
        "awready",
        "wready",
        "bresp",
        "bvalid",
        "arready",
        "rdata",
        "rresp",
        "rvalid",
    )
    for prefix in ("s0_axi_", "s1_axi_"):
        _idle(dut, prefix, master_inputs)
    for prefix in ("m0_axi_", "m1_axi_"):
        _idle(dut, prefix, slave_inputs)

    dut.aresetn.value = 0
    cocotb.start_soon(Clock(dut.aclk, CLK_PERIOD_NS, unit="ns").start())
    for _ in range(cycles):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)
    await ReadOnly()
    await Timer(1, unit="step")


async def _join(*aws) -> None:
    started = [cocotb.start_soon(item) for item in aws]
    for task in started:
        await task


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_reset_readys_idle(dut):
    """Empty trackers: SI READYs are high and every VALID we drive is low."""
    await reset_crossbar(dut)

    for name in (
        "s0_axi_awready",
        "s0_axi_wready",
        "s0_axi_arready",
        "s1_axi_awready",
        "s1_axi_wready",
        "s1_axi_arready",
    ):
        assert _bit(dut, name) == 1, name

    for name in (
        "s0_axi_bvalid",
        "s0_axi_rvalid",
        "s1_axi_bvalid",
        "s1_axi_rvalid",
        "m0_axi_awvalid",
        "m0_axi_wvalid",
        "m0_axi_arvalid",
        "m0_axi_bready",
        "m0_axi_rready",
        "m1_axi_awvalid",
        "m1_axi_wvalid",
        "m1_axi_arvalid",
        "m1_axi_bready",
        "m1_axi_rready",
    ):
        assert _bit(dut, name) == 0, name


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_parallel_masters_different_slaves(dut):
    """Masters aimed at different slaves proceed together.

    Slave 0 withholds READY, so master 0's write stays in flight. Master 1's
    read of slave 1 must finish while that write is still outstanding.
    """
    await reset_crossbar(dut)
    master0 = AxiLiteMaster(dut, prefix="s0_axi_")
    master1 = AxiLiteMaster(dut, prefix="s1_axi_")
    slave0 = AxiLiteMemorySlave(dut, prefix="m0_axi_", stall_cycles=12)
    slave1 = AxiLiteMemorySlave(dut, prefix="m1_axi_", stall_cycles=0)
    _store(slave1, 0x0001_0040, 0xCAFEBABE)
    slave0.start()
    slave1.start()
    try:
        done: dict[str, tuple] = {}

        async def write(name, master, addr, data):
            resp = await master.write(addr, data, prot=0b010)
            done[name] = (get_sim_time(unit="ns"), resp)

        async def read(name, master, addr):
            data, resp = await master.read(addr, prot=0b010)
            done[name] = (get_sim_time(unit="ns"), data, resp)

        await _join(
            write("m0", master0, 0x0000_0010, 0x1111_1111),
            read("m1", master1, 0x0001_0040),
        )

        assert done["m0"][1] == RESP_OKAY
        assert done["m1"][1:] == (0xCAFEBABE, RESP_OKAY)
        assert done["m1"][0] < done["m0"][0], (
            f"slave1 read finished at {done['m1'][0]} ns, "
            f"stalled slave0 write at {done['m0'][0]} ns"
        )
        assert slave0.seen_aw == [(0x0000_0010, 0b010)]
        assert slave1.seen_ar == [(0x0001_0040, 0b010)]
        assert slave1.seen_aw == []

        data, resp = await master0.read(0x0000_0010)
        assert resp == RESP_OKAY
        assert data == 0x1111_1111

        resp = await master1.write(0x0001_0020, 0x2222_2222)
        assert resp == RESP_OKAY
        data, resp = await master1.read(0x0001_0020)
        assert resp == RESP_OKAY
        assert data == 0x2222_2222
        assert slave0.seen_aw == [(0x0000_0010, 0b010)]
    finally:
        slave0.stop()
        slave1.stop()


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_round_robin_on_shared_slave(dut):
    """After SI0 takes the token alone, the next contested grant goes to SI1.

    Fixed priority would keep serving SI0 first. The token moves to the back
    of the queue on every grant, including an uncontended one.
    """
    await reset_crossbar(dut)
    master0 = AxiLiteMaster(dut, prefix="s0_axi_")
    master1 = AxiLiteMaster(dut, prefix="s1_axi_")
    slave0 = AxiLiteMemorySlave(dut, prefix="m0_axi_")
    slave1 = AxiLiteMemorySlave(dut, prefix="m1_axi_")
    slave0.start()
    slave1.start()
    try:
        resp = await master0.write(0x0000_0004, 0xA0A0_0004)
        assert resp == RESP_OKAY

        aw_mark = len(slave0.seen_aw)
        await _join(
            master0.write(0x0000_0010, 0xA1A1_0010),
            master1.write(0x0000_0020, 0xB1B1_0020),
        )
        first = [addr for addr, _prot in slave0.seen_aw[aw_mark:]]
        assert first == [0x0000_0020, 0x0000_0010], first

        aw_mark = len(slave0.seen_aw)
        await _join(
            master0.write(0x0000_0030, 0xA2A2_0030),
            master1.write(0x0000_0040, 0xB2B2_0040),
        )
        second = [addr for addr, _prot in slave0.seen_aw[aw_mark:]]
        assert second == [0x0000_0040, 0x0000_0030], second
        assert slave1.seen_aw == []

        for addr, data in (
            (0x0000_0004, 0xA0A0_0004),
            (0x0000_0010, 0xA1A1_0010),
            (0x0000_0020, 0xB1B1_0020),
            (0x0000_0030, 0xA2A2_0030),
            (0x0000_0040, 0xB2B2_0040),
        ):
            got, resp = await master0.read(addr)
            assert resp == RESP_OKAY
            assert got == data, f"0x{addr:08X} read 0x{got:08X}"

        # The reads above were SI0 only, so the read token now prefers SI1.
        ar_mark = len(slave0.seen_ar)
        await _join(
            master0.read(0x0000_0010),
            master1.read(0x0000_0020),
        )
        read_order = [addr for addr, _prot in slave0.seen_ar[ar_mark:]]
        assert read_order == [0x0000_0020, 0x0000_0010], read_order
    finally:
        slave0.stop()
        slave1.stop()


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_decode_error_does_not_stall_the_other_master(dut):
    """An unmapped address returns DECERR and leaves the other SI's path free."""
    await reset_crossbar(dut)
    master0 = AxiLiteMaster(dut, prefix="s0_axi_")
    master1 = AxiLiteMaster(dut, prefix="s1_axi_")
    slave0 = AxiLiteMemorySlave(dut, prefix="m0_axi_")
    slave1 = AxiLiteMemorySlave(dut, prefix="m1_axi_")
    slave0.start()
    slave1.start()
    try:
        bad = cocotb.start_soon(master0.write(0x0002_0000, 0xDEAD_BEEF))
        good = cocotb.start_soon(master1.write(0x0001_0080, 0x5555_5555, prot=0b001))
        assert await bad == RESP_DECERR
        assert await good == RESP_OKAY

        data, resp = await master1.read(0x0001_0080)
        assert resp == RESP_OKAY
        assert data == 0x5555_5555
        assert slave0.seen_aw == []
        assert slave1.seen_aw == [(0x0001_0080, 0b001)]
        assert all(addr != 0x0002_0000 for addr, _prot in slave0.seen_ar + slave1.seen_ar)

        data, resp = await master0.read(0x0002_0004)
        assert resp == RESP_DECERR
        assert data == 0
    finally:
        slave0.stop()
        slave1.stop()


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_wdata_may_follow_awaddr(dut):
    """AW and W are buffered separately, and a late WSTRB still merges."""
    await reset_crossbar(dut)
    master0 = AxiLiteMaster(dut, prefix="s0_axi_")
    slave0 = AxiLiteMemorySlave(dut, prefix="m0_axi_")
    slave1 = AxiLiteMemorySlave(dut, prefix="m1_axi_")
    slave0.start()
    slave1.start()
    try:
        resp = await master0.write(0x0000_0030, 0xA1B2_C3D4)
        assert resp == RESP_OKAY

        await master0._send_aw(0x0000_0030, 0)
        for _ in range(4):
            await RisingEdge(dut.aclk)
        await master0._send_w(0x0000_005A, 0x1)
        assert await master0._recv_b() == RESP_OKAY
        data, resp = await master0.read(0x0000_0030)
        assert resp == RESP_OKAY
        assert data == 0xA1B2_C35A, f"0x{data:08X}"

        await master0._send_w(0x1122_3344, 0xF)
        for _ in range(3):
            await RisingEdge(dut.aclk)
        await master0._send_aw(0x0000_0044, 0)
        assert await master0._recv_b() == RESP_OKAY
        data, resp = await master0.read(0x0000_0044)
        assert resp == RESP_OKAY
        assert data == 0x1122_3344
    finally:
        slave0.stop()
        slave1.stop()
