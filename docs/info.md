<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->
## Why is it?

Use my 10kw grid-tied solar system to power my home on the second day of a power outage.

A grid tied solar system becomes useless without the grid. Hybrid systems involve using batteries fix this, but are a big expense. If a grid tied solar system is disconnected gtom the grid and provided with a simulated grid the solar system will generate hydro AC. The issue is that grid tied inverters work by maximizing the energy delivery without restriction knowing that the grid can accept it.
If the energy is not dissipated the voltage and frequiency of the simulated grid will be driven out of spec and the grid tied inverters will shutdown. 

The energy from the sun needs to be always and exactly dissipated. This dissipation can be partially done by any electrical devices in the home, but something else needs dissipate the remainder. Heating water is a good way of dumping energy.

A device is proposed which will generate a reference 60Hz AC, and control dumping extra energy into a resistive load without needed a battery system.

Its a good fit for a tiny tapeout chip with low I/O count PWM and serial data, and 20ns PWM edge resolution
gives fine control, while maintaiing minimum pulse widths. 

Fitting this device into a tiny tapeout would remove all cost from the control part of the problem.

## How it works

A free running angle counter is input into a cordic rotational block and polarity corrected to calculate a 60Hz sine wave.
The sine wave is gated and then accumulated in PWM modulator produce bi-polar PWM signals which can be used to drive an H Bridge to reconstruct the waveform from battery power.
The ADC data is sample and a rectified delta with the sine wave is gates and accumulated in a PWM modulator to with programmable gain to produce a PWM signal to control the dump switch.

## How to test

Tests I used to bring up the RTL with.

## External hardware

Grid ties solar system, sunlight

    -Hbridge and drivers
    -Step up transformer
    -Bridge Rectifier
    -DCLink Capactors
    -Dump FET and driver
    -Resistive Water Heater, water
    -ADC with isolated instrumentation.
    -external control panel (gates and gain)


