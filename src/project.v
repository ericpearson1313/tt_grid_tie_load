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
  assign uo_out[7:4]  = 0; 
  assign uio_out = 0;
  assign uio_oe  = 0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, clk, rst_n, ui_in, uio_in, 1'b0};
	
	wire reset;
	assign reset = !rst_n;

	// Gate input reg CC crossing meta regs
	reg [4:0] gate_cc, gate;
	always @(posedge clk) begin
		gate_cc <= ui_in[6:2];
		gate <= gate_cc;
	end

	// ADC Input
	wire strobe; // 1 cycle pulse every 16 cycles
	wire [11:0] ac_data, dc_data; // 2s comp adc input data
	adc_in i_adc (
		.clk( clk ),
		.reset( reset ),
		.ad_cs( uo_out[0] ),
		.ad_sdata( ui_in[1:0] ),
		.ad_out0( ac_data ),
		.ad_out1( dc_data ),
		.ad_strobe( strobe )
	);

	wire [11:0] absac_data;
	assign absac_data = ( ac_data[11] ) ? ~ac_data : ac_data;

	// Cordic unit
	reg [15:0] angle;
	wire [15:0] sin_out, cos_out;
	wire valid, busy;
	cordic_sincos_50000_core_20 i_dut(
		.clk( clk ),
		.rst( reset ),
		.start( strobe ),
		.angle_in( angle ),
		.sin_out ( sin_out ),
		.cos_out ( cos_out ),
		.valid( valid ),
		.busy( busy )
	);
		

	// Count angle every start pulse (-25000 to 24999 )
   	// at 3Mhz (48Mhz/16) this gives us exactly 60 Hz grid freq

	reg polarity;
	always @(posedge clk) begin
		if( reset ) begin
			angle <= -12500;
			polarity <= 0;
		end else begin
			if( strobe ) begin
				angle <= ( angle == 12499 ) ? -12500 : angle + 1;
		    	polarity <= ( angle == 12499 ) ? ~polarity : polarity;
			end
		end
	end
	wire half_cycle;
	assign half_cycle = ( strobe && angle == 12499 ) ? 1'b1 : 1'b0;

	// Correct Polarity (just negate)
	reg signed [15:0] sin, absin;
	always @(posedge clk) begin
		if( reset ) begin
			sin <= 0;
			absin <= 0;
		end else if( valid ) begin
			sin   <= ( polarity ) ? ~cos_out : cos_out; // use cos as it aligns with polarity
			absin <= cos_out; // since cordic works over -/+pi/2
		end
	end

	// gain_vref is gate 4, duty cycle is vrefA
	reg [20:0] vref_count, vref_sum, vref;
	always @(posedge clk) begin
		if( reset ) begin
			vref_count <=0;
			vref_sum <= 0;
			vref <= 0;
		end else begin
			vref_count <= vref_count + 1;
			vref_sum <= ( vref_count == 20'hfffff ) ? gate[4] : vref_sum + gate[4];
			vref <= ( vref_count == 20'hfffff ) ? vref_sum : vref;
		end
	end

	// Accumulate error function
	// and gates PWM outputs with
	// guaranteed min pulse width of 4us
	reg signed [31:0] sin_err;
	reg sin_pwm_p, sin_pwm_n;

	always @(posedge clk) begin
		if( reset ) begin
			sin_pwm_p <= 0;
			sin_pwm_n <= 0;
			sin_err <= 0;
		end else begin
			sin_pwm_p <= ( sin_err >  16465 * 12 * 16 ) ? 1 : ( sin_err < 0 ) ? 0 : sin_pwm_p;
			sin_pwm_n <= ( sin_err < -16465 * 12 * 16 ) ? 1 : ( sin_err > 0 ) ? 0 : sin_pwm_n;
			sin_err <= sin_err + ((gate[0])?sin:0) + ((sin_pwm_p)?-16465:(sin_pwm_n)?16465:0);
		end
 	end

	assign uo_out[1] = sin_pwm_p;
	assign uo_out[2] = sin_pwm_n;

	// Output PWM based on gated absin.

	reg signed [31:0] absin_err;
	reg absin_pwm;
	wire th_gate; // U > thresh gate
	always @(posedge clk) begin
		if( reset ) begin
			absin_pwm <= 0;
			absin_err <= 0;
		end else begin
			absin_pwm <= ( absin_err >  16465 * 12 * 16 ) ? 1 : ( absin_err < 0 ) ? 0 : sin_pwm_p;
			absin_err <= absin_err + ((gate[1]&&th_gate)?absin:0) - ((absin_pwm)?16465:0);
		end
 	end

	assign uo_out[3] = absin_pwm;

	// Pseduo energy is the volt error Vin-sin subtractin |ac_data| when pem asserted
	wire [11:0] delta, deltad, deltae;
	assign delta = ( polarity ) ? ac_data - sin[15-:12] : sin[15-:12] - ac_data;
    assign deltad = ( absin_pwm && gate[2] ) ? absac_data : 0;
	assign deltae = ( gate[3] ) ? delta - deltad : 0;


	// Accumdulate the delta error 'u' 
	// Have reasonable hard clamps because it can accumulate forever
	reg [31:0] fast_acc;
	wire [31:0] next_acc;
	assign next_acc = fast_acc + {{24{deltae[11]}},deltae[11:0]};
	always @(posedge clk) begin
		if( reset ) begin
			fast_acc <= 0;
		end else begin
			fast_acc <= ( next_acc[31:30] == 2'b01 ) ? 32'h3FFF_FFFF :
                       	( next_acc[31:30] == 2'b10 ) ? 32'hC000_0000 : next_acc;
		end
	end

	// Low pass filter u : TBD

	// Threhold filterer u;

	assign th_gate = ( !fast_acc[31] && fast_acc[31] > 32'h000F_FFFF ) ? 1'b1 : 1'b0; // can be modulate down

endmodule
