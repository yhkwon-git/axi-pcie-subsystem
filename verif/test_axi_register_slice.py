"""Cocotb tests for the AXI4-Lite full register slice.

Transaction tests go through AxiLiteMaster / AxiLiteMemorySlave.
Channel tests drive AW directly so backpressure and throughput are visible
without a slave round-trip. AW, W, B, AR, and R share axi_channel_reg_slice,
so the AW stream covers the leaf timing behavior and the memory test covers
all five channel instances.
"""

from __future__ import annotations

import cocotb

from axi_lite_bfm import (
    CLK_PERIOD_NS,
    RESP_OKAY,
    AxiLiteMaster,
    AxiLiteMemorySlave,
    drive_channel,
    reset_dut,
    sample_channel,
)


def _bit(dut, name: str) -> int:
    return int(getattr(dut, name).value)


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_reset_outputs_idle(dut):
    """After reset the slice is empty: output VALIDs are low and READYs are high."""
    await reset_dut(dut)

    for name in (
        "m_axi_awvalid",
        "m_axi_wvalid",
        "s_axi_bvalid",
        "m_axi_arvalid",
        "s_axi_rvalid",
    ):
        assert _bit(dut, name) == 0, f"{name} should be low out of reset"

    for name in (
        "s_axi_awready",
        "s_axi_wready",
        "m_axi_bready",
        "s_axi_arready",
        "m_axi_rready",
    ):
        assert _bit(dut, name) == 1, f"{name} should be high when the skid slot is empty"


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_write_read_and_strobe(dut):
    """Write, partial-strobe update, and read-back across all five channels."""
    await reset_dut(dut)
    slave = AxiLiteMemorySlave(dut, data_width=32, stall_cycles=2)
    master = AxiLiteMaster(dut, data_width=32, resp_stall_cycles=2)
    slave.start()
    try:
        resp = await master.write(0x10, 0xA1B2C3D4, strb=0xF, prot=0b010)
        assert resp == RESP_OKAY
        data, rresp = await master.read(0x10, prot=0b010)
        assert rresp == RESP_OKAY
        assert data == 0xA1B2C3D4, f"read 0x{data:08X}"

        resp = await master.write(0x10, 0x0000005A, strb=0x1, prot=0b000)
        assert resp == RESP_OKAY
        data, rresp = await master.read(0x10)
        assert rresp == RESP_OKAY
        assert data == 0xA1B2C35A, f"byte strobe merged to 0x{data:08X}"

        assert slave.seen_aw[0] == (0x10, 0b010)
        assert slave.seen_ar[0] == (0x10, 0b010)
    finally:
        slave.stop()


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_aw_backpressure_preserves_beats(dut):
    """Downstream AW stalls must not drop, duplicate, or reorder beats."""
    await reset_dut(dut)
    addrs = [0x1000 + (i * 4) for i in range(8)]

    def drive(addr: int) -> None:
        dut.s_axi_awaddr.value = addr
        dut.s_axi_awprot.value = 0

    def sample() -> int:
        return int(dut.m_axi_awaddr.value)

    captured = cocotb.start_soon(
        sample_channel(
            dut.aclk,
            len(addrs),
            dut.m_axi_awvalid,
            dut.m_axi_awready,
            sample,
            stall_cycles=4,
        )
    )
    await drive_channel(
        dut.aclk,
        addrs,
        drive,
        dut.s_axi_awvalid,
        dut.s_axi_awready,
    )
    got = await captured
    assert got == addrs, f"AW stream mismatch: {got}"


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_aw_back_to_back_throughput(dut):
    """With READY held, AW beats exit one per clock and one clock after entry."""
    await reset_dut(dut)
    count = 16
    addrs = [0x8000 + (i * 4) for i in range(count)]
    t_in: list = []
    t_out: list = []

    def drive(addr: int) -> None:
        dut.s_axi_awaddr.value = addr
        dut.s_axi_awprot.value = 0

    def sample() -> int:
        return int(dut.m_axi_awaddr.value)

    captured = cocotb.start_soon(
        sample_channel(
            dut.aclk,
            count,
            dut.m_axi_awvalid,
            dut.m_axi_awready,
            sample,
            stall_cycles=0,
            timestamps=t_out,
        )
    )
    await drive_channel(
        dut.aclk,
        addrs,
        drive,
        dut.s_axi_awvalid,
        dut.s_axi_awready,
        timestamps=t_in,
    )
    got = await captured
    assert got == addrs
    assert len(t_in) == count and len(t_out) == count

    latency = float(t_out[0] - t_in[0])
    assert abs(latency - CLK_PERIOD_NS) < 0.05, f"AW latency {latency} ns, expected one clock"
    for index in range(1, count):
        gap = float(t_out[index] - t_out[index - 1])
        assert abs(gap - CLK_PERIOD_NS) < 0.05, f"bubble at beat {index}: gap {gap} ns"
