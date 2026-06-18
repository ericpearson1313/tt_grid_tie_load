// vim: ts=4:
/*
 * Copyright (c) 2026 Eric Pearson
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_60hz_load(
`ifdef __ALTERA_STD__
	// MAx10 fpga probing
    output reg [11:0] ac_acc,
	 output reg [11:0] dc_acc,
	 output reg ac_thresh,
	 output reg dc_thresh,
`endif
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
	reg [5:0] gate_cc, gate;
	always @(posedge clk) begin
		gate_cc <= ui_in[7:2];
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

`define USE_CORDIC
`ifdef USE_CORDIC
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
`endif

		

	// Count angle every start pulse (-25000 to 24999 )
   	// at 3Mhz (48Mhz/16) this gives us exactly 60 Hz grid freq

	reg polarity;
	reg pdir;
	wire quad0;
	always @(posedge clk) begin
		if( reset ) begin
			angle <= 12500;
			polarity <= 0;
			pdir <= 0;
		end else begin
			if( strobe ) begin
				angle <= angle + (( pdir ) ? 1 : -1);
		    	polarity <= ( angle == 12499 && pdir == 1 ) ? ~polarity : polarity;
				pdir <= ( pdir == 0 && angle == 1 ) ? 1 : ( pdir == 1 && angle == 12499 ) ? 0 : pdir;
			end
		end
	end
	assign quad0 = !polarity & !pdir;

	// Multiply cos by 3: to nicely fill dynamic range
	wire signed [11:0] cos3x;
`ifdef USE_CORDIC
	assign cos3x = cos_out[15-:12] + ( cos_out[15-:12] >>> 1 );
`endif

//`define MAKE_ROM
`ifdef MAKE_ROM
    /////////////////////
	// Build a rom
	reg [8:0] cos_rom[31:0];
	initial for( int ii = 0; ii < 32; ii++ ) 
		cos_rom[ii] <= 12'sd0;
	reg [15:0] prev_angle;
	always @(posedge clk) begin
		prev_angle <= angle;
		if( strobe && !angle[15] ) 
			if( prev_angle[8:0] == (1<<8) )  cos_rom[prev_angle[13-:5]] <= cos3x[10:2];
	end
	always @(posedge clk) begin
		if( strobe && angle == 100 && pdir == 1 && polarity == 0 ) 
			for( int ii = 0; ii < 32; ii++ )
			$display("cos_rom[%0d] = 9'd%0d;", ii, cos_rom[ii] );
	end
	///////////////////
`endif

`ifndef USE_CORDIC // if not cordic, then ROM
    reg [8:0] cos_rom [31:0];
	initial begin
cos_rom[0] = 9'd385;
cos_rom[1] = 9'd384;
cos_rom[2] = 9'd380;
cos_rom[3] = 9'd375;
cos_rom[4] = 9'd369;
cos_rom[5] = 9'd361;
cos_rom[6] = 9'd352;
cos_rom[7] = 9'd341;
cos_rom[8] = 9'd329;
cos_rom[9] = 9'd315;
cos_rom[10] = 9'd300;
cos_rom[11] = 9'd284;
cos_rom[12] = 9'd267;
cos_rom[13] = 9'd249;
cos_rom[14] = 9'd229;
cos_rom[15] = 9'd209;
cos_rom[16] = 9'd187;
cos_rom[17] = 9'd166;
cos_rom[18] = 9'd143;
cos_rom[19] = 9'd119;
cos_rom[20] = 9'd96;
cos_rom[21] = 9'd72;
cos_rom[22] = 9'd47;
cos_rom[23] = 9'd22;
cos_rom[24] = 9'd0;
cos_rom[25] = 9'dx;
cos_rom[26] = 9'dx;
cos_rom[27] = 9'dx;
cos_rom[28] = 9'dx;
cos_rom[29] = 9'dx;
cos_rom[30] = 9'dx;
cos_rom[31] = 9'dx;
	end
    assign valid = 1;
	wire [8:0] read;
	assign read = cos_rom[angle[13-:5]];
	assign cos3x = { 1'b0, read, 2'b00 };
`endif // ROM not CORDIC
	
	// Correct Polarity (just negate)
	reg signed [11:0] sin, absin;
	always @(posedge clk) begin
		if( reset ) begin
			sin<= 0;
			absin<= 0;
		end
		else
		if( valid ) begin
			sin   <= ( polarity ) ? ~cos3x : cos3x; // use cos as it aligns with polarity
			absin <= cos3x;
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
	reg dc_very_low;
	always @(posedge clk) 
		delta  <= (( !gate[5] || quad0 ) && gate[2] && !dc_very_low ) ? ac_data - sin : 0;

	// Accumdulate the delta error 'u' 
	// Have reasonable hard clamps because it can accumulate forever
	reg signed [25:0] fast_acc;
	wire signed [25:0] next_acc;
	assign next_acc = fast_acc + (delta<<<3) - (( !fast_acc[25] && (|fast_acc[24-:5]) ) ? absin : 'sd0 );
	always @(posedge clk) begin
		if( reset ) begin
			fast_acc <= 0;
		end else begin
			//fast_acc <= ( next_acc[25] != next_acc[24] ) ? {{2{next_acc[25]}}, {24{~next_acc[25]}}} : next_acc;
			fast_acc <= ( !next_acc[25] &&    next_acc[24]    ) ? 26'h0FFFFFF : 
			            (  next_acc[25] && !(&next_acc[24-:5])) ? 26'h3F00000 : next_acc;
		end
	end

	// Low pass filter u : TBD

	// Threhold filterer u;
	always @(posedge clk)
		th_gate <= !fast_acc[25] & |fast_acc[24-:5]; // can be modulate down

	/////////////
	//	DC Loop
	/////////////

	// Pseduo energy is the voltage error from Vref DC
	reg signed [11:0] dc_delta;
	always @(posedge clk)
		dc_delta  <= ( !gate[3] ) ? 0 : { gate[4] ^ dc_data[11], dc_data[10:0] };

	// Accumdulate the delta error 'u' 
	// Have reasonable hard clamps because it can accumulate forever
	reg signed [30:0] dc_fast_acc;
	wire signed [30:0] dc_next_acc;
	assign dc_next_acc = dc_fast_acc + (dc_delta<<<2) - ((!dc_fast_acc[30] & |dc_fast_acc[29-:6] ) ? absin : 0 );
	always @(posedge clk) begin
		if( reset ) begin
			dc_fast_acc <= 0;
		end else begin
			//dc_fast_acc <= ( dc_next_acc[30] != dc_next_acc[29] ) ? {{2{dc_next_acc[30]}}, {29{~dc_next_acc[30]}}} : dc_next_acc;
			dc_fast_acc <= ( !dc_next_acc[30] &&    dc_next_acc[29]    ) ? 31'h1FFFFFFF : 
			               (  dc_next_acc[30] && !(&dc_next_acc[29-:6])) ? 31'h7F000000 : dc_next_acc;
		end
	end

	always @(posedge clk)
		dc_very_low <= ( reset ) ? 1'b1 : ( !dc_very_low && dc_next_acc[30] && !(&dc_next_acc[29-:6])) ? 1'b1 : 
                                          (  dc_very_low && dc_th_gate ) ? 1'b0 : dc_very_low ;

	// Low pass filter u : TBD

	// Threhold filterer u;

	always @(posedge clk)
		dc_th_gate <= !dc_fast_acc[30] & |dc_fast_acc[29-:6];
		
`ifdef __ALTERA_STD__
    // Hook Up fpga probing
	 always @(posedge clk) begin
			ac_thresh <= th_gate;
			dc_thresh <= dc_th_gate;
			dc_acc <= dc_fast_acc[29-:12];
			ac_acc <= fast_acc[24-:12];
	end
`endif


endmodule
