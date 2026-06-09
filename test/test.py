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
    dut.uio_in.value = 0
    dut.rst_n.value = 0

    # dut controls
    dut.ac_mode.value = 1
    dut.num_vref.value = 200
    dut.den_vref.value = 400
    dut.num_sine.value = 99
    dut.den_sine.value = 100
    dut.num_out.value = 99
    dut.den_out.value = 100
    dut.num_ac.value = 9
    dut.den_ac.value = 11
    dut.num_dc.value = 998
    dut.den_dc.value = 1000
    dut.phase_lead.value = 1000
    dut.vdc.value = 2000
    
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

    # Check that each is over >  1/4 of cnt
    assert int(dut.cnt_sin_p.value) > 200000
    assert int(dut.cnt_sin_n.value) > 200000

    # Check that each is under <  1/3 of cnt
    assert int(dut.cnt_sin_p.value) < 260000
    assert int(dut.cnt_sin_n.value) < 260000

    # our PWM is over > 1/2, and under 3/4
    assert int(dut.cnt_pwm.value) > 300000
    assert int(dut.cnt_pwm.value) < 600000


    # Keep testing the module by changing the input values, waiting for
    # one or more clock cycles, and asserting the expected output values.
