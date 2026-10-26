"""Cocotb tests for the dual-clock FIFO.

Write clock is 10 ns, read clock is 14 ns, so the reader is slower and a
concurrent stream has to exercise wr_full. DEPTH is 8 (runner parameter).

rd_empty / wr_full are registered in their own clocks. A word is not visible
on the read side until the Gray write pointer has crossed the 2-flop
synchronizer, so empty must stay high for at least two rd_clk edges after the
write that created the first word. The symmetric case holds for wr_full after
a pop that frees the last slot.
"""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

DEPTH = 8
WR_NS = 10
RD_NS = 14


async def reset_fifo(dut) -> None:
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    dut.wr_data.value = 0
    dut.wr_rst_n.value = 0
    dut.rd_rst_n.value = 0
    cocotb.start_soon(Clock(dut.wr_clk, WR_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.rd_clk, RD_NS, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.wr_clk)
    await RisingEdge(dut.wr_clk)
    dut.wr_rst_n.value = 1
    await RisingEdge(dut.rd_clk)
    dut.rd_rst_n.value = 1
    await RisingEdge(dut.wr_clk)
    await RisingEdge(dut.rd_clk)
    await ReadOnly()
    await Timer(1, unit="step")


async def write_word(dut, data: int, waits: list | None = None) -> None:
    """Push one word. Waits out wr_full. The beat is ignored by the DUT while full."""
    waited = False
    for _ in range(10000):
        await RisingEdge(dut.wr_clk)
        await ReadOnly()
        full = int(dut.wr_full.value)
        await Timer(1, unit="step")
        if full:
            waited = True
            dut.wr_en.value = 0
            continue
        dut.wr_data.value = data
        dut.wr_en.value = 1
        await RisingEdge(dut.wr_clk)
        await ReadOnly()
        await Timer(1, unit="step")
        dut.wr_en.value = 0
        if waits is not None and waited:
            waits.append(1)
        return
    raise AssertionError("write_word timed out")


async def read_word(dut) -> int:
    """Pop one word. rd_data is the current head while rd_empty is low."""
    for _ in range(10000):
        await RisingEdge(dut.rd_clk)
        await ReadOnly()
        empty = int(dut.rd_empty.value)
        data = int(dut.rd_data.value)
        await Timer(1, unit="step")
        if empty:
            dut.rd_en.value = 0
            continue
        dut.rd_en.value = 1
        await RisingEdge(dut.rd_clk)
        await ReadOnly()
        await Timer(1, unit="step")
        dut.rd_en.value = 0
        return data
    raise AssertionError("read_word timed out")


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_reset_is_empty(dut):
    """Both domains leave reset with the FIFO empty and not full."""
    await reset_fifo(dut)
    await RisingEdge(dut.wr_clk)
    await ReadOnly()
    assert int(dut.wr_full.value) == 0
    await RisingEdge(dut.rd_clk)
    await ReadOnly()
    assert int(dut.rd_empty.value) == 1


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_fill_sets_full_and_extra_write_is_dropped(dut):
    """DEPTH writes raise full. A further wr_en must not stick an extra word."""
    await reset_fifo(dut)
    payload = [0x1000 + i for i in range(DEPTH)]
    for word in payload:
        await write_word(dut, word)

    await RisingEdge(dut.wr_clk)
    await ReadOnly()
    assert int(dut.wr_full.value) == 1, "full should be set once every slot is occupied"

    await Timer(1, unit="step")
    dut.wr_data.value = 0xFFFF_FFFF
    dut.wr_en.value = 1
    await RisingEdge(dut.wr_clk)
    await ReadOnly()
    assert int(dut.wr_full.value) == 1
    await Timer(1, unit="step")
    dut.wr_en.value = 0

    got = [await read_word(dut) for _ in range(DEPTH)]
    assert got == payload, f"0x{got} != 0x{payload}"

    await RisingEdge(dut.rd_clk)
    await ReadOnly()
    assert int(dut.rd_empty.value) == 1


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_empty_waits_for_write_pointer_sync(dut):
    """Empty falls only after the Gray write pointer crosses into rd_clk.

    Two synchronizer flops plus the registered empty flag mean the read side
    cannot see the word on the first destination edge after the write.
    """
    await reset_fifo(dut)
    await write_word(dut, 0x5A)

    edges = 0
    for _ in range(12):
        await RisingEdge(dut.rd_clk)
        await ReadOnly()
        edges += 1
        if int(dut.rd_empty.value) == 0:
            break
        await Timer(1, unit="step")
    else:
        raise AssertionError("rd_empty stayed high after the write pointer should have synced")

    assert edges >= 2, f"empty fell after {edges} rd_clk edges; synchronizer was bypassed"
    assert edges <= 6, f"empty fell after {edges} rd_clk edges; pointer sync looks stuck"
    assert await read_word(dut) == 0x5A


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_full_waits_for_read_pointer_sync(dut):
    """Full stays set until the Gray read pointer is visible in wr_clk."""
    await reset_fifo(dut)
    for i in range(DEPTH):
        await write_word(dut, 0x200 + i)

    await RisingEdge(dut.wr_clk)
    await ReadOnly()
    assert int(dut.wr_full.value) == 1

    first = await read_word(dut)
    assert first == 0x200

    edges = 0
    for _ in range(12):
        await RisingEdge(dut.wr_clk)
        await ReadOnly()
        edges += 1
        if int(dut.wr_full.value) == 0:
            break
        await Timer(1, unit="step")
    else:
        raise AssertionError("wr_full stayed high after the read pointer should have synced")

    assert edges >= 2, f"full cleared after {edges} wr_clk edges; synchronizer was bypassed"
    assert edges <= 6, f"full cleared after {edges} wr_clk edges; pointer sync looks stuck"

    await write_word(dut, 0x2FF)
    rest = [await read_word(dut) for _ in range(DEPTH)]
    assert rest == [0x200 + i for i in range(1, DEPTH)] + [0x2FF]


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_wrap_under_both_clocks(dut):
    """More than two depths of traffic wraps both pointers and still keeps order.

    The reader is the slower clock, so the writer has to observe full and wait.
    """
    await reset_fifo(dut)
    count = DEPTH * 5
    payload = [0xA000_0000 + i for i in range(count)]
    waits: list[int] = []

    async def produce() -> None:
        for word in payload:
            await write_word(dut, word, waits)

    async def consume(sink: list[int]) -> None:
        for _ in range(count):
            sink.append(await read_word(dut))

    got: list[int] = []
    reader = cocotb.start_soon(consume(got))
    await produce()
    await reader

    assert waits, "writer never saw wr_full, so the depth was not stressed"
    assert got == payload
    await RisingEdge(dut.rd_clk)
    await ReadOnly()
    assert int(dut.rd_empty.value) == 1
    await RisingEdge(dut.wr_clk)
    await ReadOnly()
    assert int(dut.wr_full.value) == 0
