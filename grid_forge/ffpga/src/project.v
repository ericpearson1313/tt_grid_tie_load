// vim: ts=4:
/*
 * Copyright (c) 2026 Eric Pearson
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

	// Multiply cos by 3: to nicely fill dynamic range
	wire signed [16:0] cos3x;
	assign cos3x = cos_out + ( cos_out << 1 );

	// Correct Polarity (just negate)
	reg signed [11:0] sin, absin;
	always @(posedge clk) begin
		if( reset ) begin
			sin <= 0;
			absin <= 0;
		end else if( valid ) begin
			sin   <= ( polarity ) ? ~cos3x[16-:12] : cos3x[16-:12]; // use cos as it aligns with polarity
			absin <= cos3x[16-:12] ; // since cordic works over -/+pi/2
		end
	end

	// Accumulate error function
	// and gates PWM outputs with
	// guaranteed min pulse width of 4us
	reg signed [19:0] sin_err;
	reg sin_pwm_p, sin_pwm_n;

	always @(posedge clk) begin
		if( reset ) begin
			sin_pwm_p <= 0;
			sin_pwm_n <= 0;
			sin_err <= 0;
		end else begin
			sin_pwm_p <= ( sin_err >  1544 * 12 * 16 ) ? 1 : ( sin_err < 0 ) ? 0 : sin_pwm_p;
			sin_pwm_n <= ( sin_err < -1544 * 12 * 16 ) ? 1 : ( sin_err > 0 ) ? 0 : sin_pwm_n;
			sin_err <= sin_err + ((gate[0])?sin:0) + ((sin_pwm_p)?-1544:(sin_pwm_n)?1544:0);
		end
 	end

	assign uo_out[1] = sin_pwm_p;
	assign uo_out[2] = sin_pwm_n;

	// Output PWM based on gated absin.

	reg signed [19:0] absin_err, absin_in;
	reg absin_pwm;
	reg th_gate, dc_th_gate; // U > thresh gate
	always @(posedge clk) begin
		if( reset ) begin
			absin_in <= 0;
			absin_pwm <= 0;
			absin_err <= 0;
		end else begin
			absin_pwm <= ( absin_err >  1544 * 12 * 16 ) ? 1 : ( absin_err < 0 ) ? 0 : absin_pwm;
			absin_in  <= (gate[1]&&(th_gate|dc_th_gate))?absin:0;
			absin_err <= absin_err + absin_in - ((absin_pwm)?1544:0);
		end
 	end

	assign uo_out[3] = absin_pwm;

	/////////////
	//	AC Loop
	/////////////

	// Pseduo energy is the voltage error from leading AC, ie phase error from generator energy
	reg signed [11:0] delta;
	always @(posedge clk) begin
		delta  <= ( gate[2] ) ? ac_data - sin : 0;
	end


	// Accumdulate the delta error 'u' 
	// Have reasonable hard clamps because it can accumulate forever
	reg signed [25:0] fast_acc;
	wire signed [25:0] next_acc;
	assign next_acc = fast_acc + delta - (( fast_acc > 26'h00FFFFF ) ? absin : 0 );
	always @(posedge clk) begin
		if( reset ) begin
			fast_acc <= 0;
		end else begin
			fast_acc <= ( next_acc[25:24] == 2'b01 ) ? 26'h1FFFFFF :
                       	( next_acc[25:24] == 2'b10 ) ? 26'h2000000 : next_acc;
		end
	end

	// Low pass filter u : TBD

	// Threhold filterer u;
	always @(posedge clk)
		th_gate <= ( !fast_acc[25] && fast_acc > 26'h00FFFFF ) ? 1'b1 : 1'b0; // can be modulate down

	/////////////
	//	DC Loop
	/////////////

	// Pseduo energy is the voltage error from Vref DC
	reg signed [30:0] dc_delta;
	always @(posedge clk) begin
		dc_delta  <= ( gate[3] ) ? dc_data - (( gate[4] ) ? 12'h800 : 0 ) : 0;; 
	end

	// Accumdulate the delta error 'u' 
	// Have reasonable hard clamps because it can accumulate forever
	reg signed [30:0] dc_fast_acc;
	wire signed [30:0] dc_next_acc;
	assign dc_next_acc = dc_fast_acc + dc_delta - (( dc_fast_acc > 31'h00FF_FFFF ) ? absin : 0 );
	always @(posedge clk) begin
		if( reset ) begin
			dc_fast_acc <= 0;
		end else begin
			dc_fast_acc <= ( dc_next_acc[30:29] == 2'b01 ) ? 31'h1FFF_FFFF :
                       	   ( dc_next_acc[30:29] == 2'b10 ) ? 31'h6000_0000 : dc_next_acc;
		end
	end

	// Low pass filter u : TBD

	// Threhold filterer u;

	always @(posedge clk)
		dc_th_gate <= ( !dc_fast_acc[30] && dc_fast_acc > 31'h00FF_FFFF ) ? 1'b1 : 1'b0; 

endmodule
