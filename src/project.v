// vim: ts=4:
/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_60hz_load(
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // All output pins must be assigned. If not used, assign to 0.
  assign uo_out  = ui_in + uio_in;  // Example: ou_out is the sum of ui_in and uio_in
  assign uio_out = 0;
  assign uio_oe  = 0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, clk, rst_n, 1'b0};
	
	logic reset;
	assign reset = !rst_n;

	logic start;
	logic [15:0] angle;
	logic [15:0] sin_out, cos_out;
	logic valid, busy;
	cordic_sincos_50000_core_20 i_dut(
		.clk( clk ),
		.rst( reset ),
		.start( start ),
		.angle_in( angle ),
		.sin_out ( sin_out ),
		.cos_out ( cos_out ),
		.valid( valid ),
		.busy( busy )
	);
		

	// Test

	// start pulse every 16 cycles
	logic [3:0] pcnt;
	always @(posedge clk) begin
		pcnt <= ( reset ) ? 0 : pcnt+1;
		start <= ( reset ) ? 0 : ( pcnt == 0 ) ? 1 : 0;
	end

	// Count angle every start pulse (-25000 to 24999 )
    	// at 3Mhz (48Mhz/16) this gives us exactly 60 Hz grid freq

	logic polarity;
	always @(posedge clk) begin
		if( reset ) begin
			angle <= -12500;
			polarity <= 0;
		end else if( start ) begin
			angle <= ( angle == 12499 ) ? -12500 : angle + 1;
		    polarity <= ( angle == 12499 ) ? ~polarity : polarity;
		end
	end

	// latch and hold sin value when produced

	logic signed [15:0] sin, cos;
	always @(posedge clk) begin
		if( reset ) begin
			sin <= 0;
			cos <= 0;
		end else if( valid ) begin
			sin <= ( polarity ) ? ~sin_out : sin_out;
			cos <= ( polarity ) ? ~cos_out : cos_out;
		end
	end

	// Accumulate error function
	// and PWM outputs

	logic signed [31:0] sin_err, cos_err;
	logic sin_pwm_p, sin_pwm_n;
	logic cos_pwm_p, cos_pwm_n;

	always @(posedge clk) begin
		if( reset ) begin
			sin_pwm_p <= 0;
			sin_pwm_n <= 0;
			sin_err <= 0;
			cos_pwm_p <= 0;
			cos_pwm_n <= 0;
			cos_err <= 0;
		end else if( valid ) begin
			sin_pwm_p <= ( sin_err >  16465 * 12 ) ? 1 : ( sin_err < 0 ) ? 0 : sin_pwm_p;
			sin_pwm_n <= ( sin_err < -16465 * 12 ) ? 1 : ( sin_err > 0 ) ? 0 : sin_pwm_n;
			sin_err <= sin_err + sin + ((sin_pwm_p)?-16465:(sin_pwm_n)?16465:0);
			cos_pwm_p <= ( cos_err >  16465 * 12 ) ? 1 : ( cos_err < 0 ) ? 0 : cos_pwm_p;
			cos_pwm_n <= ( cos_err < -16465 * 12 ) ? 1 : ( cos_err > 0 ) ? 0 : cos_pwm_n;
			cos_err <= cos_err + cos + ((cos_pwm_p)?-16465:(cos_pwm_n)?16465:0);
		end
 	end

	assign uo_out[0] = sin_pwm_p;
	assign uo_out[1] = sin_pwm_n;
	assign uo_out[2] = cos_pwm_p;
	assign uo_out[3] = cos_pwm_n;

endmodule
