"""One Memory Write and one Memory Read through pcie_to_axi_bridge.

The PCIe side is a DWORD stream on pclk. The AXI side is a single-beat or
short INCR burst on aclk. Clocks are intentionally different so the request
and the completion each have to cross cdc_async_fifo.
"""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

from axi_lite_bfm import drive_channel, sample_channel


def _dw0(fmt: int, length: int) -> int:
    # Fmt[2:0] at [31:29], Type Memory = 00000 at [28:24], Length at [9:0].
    return ((fmt & 0x7) << 29) | (length & 0x3FF)


def _dw1(req_id: int, tag: int, last_be: int, first_be: int) -> int:
    return ((req_id & 0xFFFF) << 16) | ((tag & 0xFF) << 8) | ((last_be & 0xF) << 4) | (first_be & 0xF)


async def reset_bridge(dut) -> None:
    dut.tlp_valid.value = 0
    dut.tlp_sop.value = 0
    dut.tlp_eop.value = 0
    dut.tlp_data.value = 0
    dut.cpl_ready.value = 0
    for name in (
        "awready",
        "wready",
        "bresp",
        "bvalid",
        "bid",
        "arready",
        "rdata",
        "rresp",
        "rvalid",
        "rlast",
        "rid",
    ):
        getattr(dut, f"m_axi_{name}").value = 0
    dut.p_rst_n.value = 0
    dut.a_rst_n.value = 0
    cocotb.start_soon(Clock(dut.pclk, 8, unit="ns").start())
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.pclk)
    await RisingEdge(dut.pclk)
    dut.p_rst_n.value = 1
    await RisingEdge(dut.aclk)
    dut.a_rst_n.value = 1
    await RisingEdge(dut.pclk)
    await RisingEdge(dut.aclk)
    await ReadOnly()
    await Timer(1, unit="step")


async def send_beat(dut, data: int, sop: int, eop: int) -> None:
    for _ in range(10000):
        await RisingEdge(dut.pclk)
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
        await RisingEdge(dut.pclk)
        await ReadOnly()
        await Timer(1, unit="step")
        dut.tlp_valid.value = 0
        dut.tlp_sop.value = 0
        dut.tlp_eop.value = 0
        return
    raise AssertionError("TLP beat was not accepted")


async def axi_memory(dut, mem: dict[int, int], log: list) -> None:
    """One AXI4 write burst or read burst at a time. VALID is held by the bridge."""
    while True:
        await RisingEdge(dut.aclk)
        await ReadOnly()
        awvalid = int(dut.m_axi_awvalid.value) == 1
        arvalid = int(dut.m_axi_arvalid.value) == 1
        await Timer(1, unit="step")
        if awvalid:
            def sample_aw():
                return (
                    int(dut.m_axi_awaddr.value),
                    int(dut.m_axi_awlen.value),
                    int(dut.m_axi_awid.value),
                    int(dut.m_axi_awsize.value),
                    int(dut.m_axi_awburst.value),
                )

            aw = (await sample_channel(
                dut.aclk, 1, dut.m_axi_awvalid, dut.m_axi_awready, sample_aw
            ))[0]
            log.append(("aw", aw))
            addr, length, awid, _size, _burst = aw

            def sample_w():
                return (
                    int(dut.m_axi_wdata.value),
                    int(dut.m_axi_wstrb.value) & 0xF,
                    int(dut.m_axi_wlast.value),
                )

            beats = await sample_channel(
                dut.aclk, length + 1, dut.m_axi_wvalid, dut.m_axi_wready, sample_w
            )
            for index, (data, strb, _last) in enumerate(beats):
                for lane in range(4):
                    if (strb >> lane) & 1:
                        mem[addr + 4 * index + lane] = (data >> (8 * lane)) & 0xFF
            log.append(("w", addr, beats))

            def drive_b(_resp: int) -> None:
                dut.m_axi_bresp.value = 0
                dut.m_axi_bid.value = awid

            await drive_channel(dut.aclk, [0], drive_b, dut.m_axi_bvalid, dut.m_axi_bready)
        elif arvalid:
            def sample_ar():
                return (
                    int(dut.m_axi_araddr.value),
                    int(dut.m_axi_arlen.value),
                    int(dut.m_axi_arid.value),
                )

            ar = (await sample_channel(
                dut.aclk, 1, dut.m_axi_arvalid, dut.m_axi_arready, sample_ar
            ))[0]
            log.append(("ar", ar))
            addr, length, arid = ar
            payload = []
            for index in range(length + 1):
                data = 0
                for lane in range(4):
                    data |= mem.get(addr + 4 * index + lane, 0) << (8 * lane)
                payload.append((data, 1 if index == length else 0))

            def drive_r(beat: tuple[int, int]) -> None:
                dut.m_axi_rdata.value = beat[0]
                dut.m_axi_rresp.value = 0
                dut.m_axi_rlast.value = beat[1]
                dut.m_axi_rid.value = arid

            await drive_channel(dut.aclk, payload, drive_r, dut.m_axi_rvalid, dut.m_axi_rready)


async def collect_completion(dut) -> list[tuple[int, int, int]]:
    words: list[tuple[int, int, int]] = []
    for _ in range(10000):
        await RisingEdge(dut.pclk)
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
        await RisingEdge(dut.pclk)
        await ReadOnly()
        await Timer(1, unit="step")
        dut.cpl_ready.value = 0
        words.append(word)
        if word[1]:
            return words
    raise AssertionError("completion did not end")


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_memory_write_and_read_cross_clocks(dut):
    """A 2DW MWr lands in AXI memory. The matching MRd returns a CplD."""
    await reset_bridge(dut)
    await RisingEdge(dut.pclk)
    await ReadOnly()
    assert int(dut.tlp_ready.value) == 1
    assert int(dut.cpl_valid.value) == 0
    assert int(dut.m_axi_awvalid.value) == 0
    assert int(dut.m_axi_arvalid.value) == 0

    mem: dict[int, int] = {}
    log: list = []
    slave = cocotb.start_soon(axi_memory(dut, mem, log))
    try:
        req_id = 0x0ABC
        tag = 0x3C
        # MWr 3DW header, two data DWORDs, full byte enables.
        await send_beat(dut, _dw0(0b010, 2), sop=1, eop=0)
        await send_beat(dut, _dw1(req_id, tag, 0xF, 0xF), sop=0, eop=0)
        await send_beat(dut, 0x0000_0020, sop=0, eop=0)
        await send_beat(dut, 0x1111_1111, sop=0, eop=0)
        await send_beat(dut, 0x2222_2222, sop=0, eop=1)

        for _ in range(400):
            if mem.get(0x20) == 0x11 and mem.get(0x24) == 0x22:
                break
            await RisingEdge(dut.aclk)
        else:
            raise AssertionError(f"write never reached AXI memory: {mem} log={log}")

        assert mem[0x20] == 0x11 and mem[0x21] == 0x11
        assert mem[0x22] == 0x11 and mem[0x23] == 0x11
        assert mem[0x24] == 0x22 and mem[0x27] == 0x22
        aw = next(item for item in log if item[0] == "aw")
        assert aw[1][0] == 0x20
        assert aw[1][1] == 1  # awlen = beats-1
        assert aw[1][3] == 0b010
        assert aw[1][4] == 0b01

        # No completion for a posted write.
        await RisingEdge(dut.pclk)
        await ReadOnly()
        assert int(dut.cpl_valid.value) == 0

        # MRd of the same two DWORDs.
        await send_beat(dut, _dw0(0b000, 2), sop=1, eop=0)
        await send_beat(dut, _dw1(req_id, tag, 0xF, 0xF), sop=0, eop=0)
        await send_beat(dut, 0x0000_0020, sop=0, eop=1)

        cpl = await collect_completion(dut)
        assert len(cpl) == 5, cpl  # 3 header DWORDs + 2 data DWORDs
        assert cpl[0][0] == 1 and cpl[0][1] == 0
        assert cpl[-1][1] == 1
        assert all(word[0] == 0 for word in cpl[1:])
        assert all(word[1] == 0 for word in cpl[:-1])

        dw0, dw1, dw2, d0, d1 = [word[2] for word in cpl]
        assert (dw0 >> 29) & 0x7 == 0b010
        assert (dw0 >> 24) & 0x1F == 0b01010
        assert dw0 & 0x3FF == 2
        assert (dw1 >> 16) & 0xFFFF == 0x0100
        assert dw1 & 0xFFF == 8  # byte count, full two DWORDs
        assert (dw2 >> 16) & 0xFFFF == req_id
        assert (dw2 >> 8) & 0xFF == tag
        assert dw2 & 0x7F == 0x20
        assert d0 == 0x1111_1111
        assert d1 == 0x2222_2222
    finally:
        slave.cancel()
