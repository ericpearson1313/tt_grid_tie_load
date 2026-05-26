# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    # Set the clock period to 10 us (100 KHz)
    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    # Reset
    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    dut._log.info("Test project behavior")

    # Wait for one full 60Hz cycle
    await ClockCycles(dut.clk, 50000 * 16)
    
    # check time passed
    assert int(dut.cnt.value) > 790000
    assert int(dut.cnt.value) < 810000
    # Check that N & P never intersect
    assert int(dut.cnt_sin_np.value) == 0
    assert int(dut.cnt_cos_np.value) == 0

    # Check that each is approx 1/3 of cnt
    assert int(dut.cnt_sin_p.value) > 250000
    assert int(dut.cnt_sin_n.value) > 250000
    assert int(dut.cnt_cos_p.value) > 250000
    assert int(dut.cnt_cos_n.value) > 250000

    assert int(dut.cnt_sin_p.value) < 260000
    assert int(dut.cnt_sin_n.value) < 260000
    assert int(dut.cnt_cos_p.value) < 260000
    assert int(dut.cnt_cos_n.value) < 260000

    # Keep testing the module by changing the input values, waiting for
    # one or more clock cycles, and asserting the expected output values.
