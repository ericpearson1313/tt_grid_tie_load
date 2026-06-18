// vim: ts=4:
// Top level Chip Wrapper
(* top *) module forge_wrapper
(
// Forge FPGA built in clk reset
(* clkbuf_inhibit *) 	input wire clk2x, // 2x from PLL
(* clkbuf_inhibit *) 	input wire clk,   // from LAC 0
						output reg clk_toggle, 					// toggle reg = clk output to LAC
						output wire logic_as_clk0_en,			// enable Logic as clock
						output wire osc_en,

						
	// Inputs
	
//(* iopad_external_pin *)	input  logic arm_button,
(* iopad_external_pin *)	input  wire pwm_vref,
(* iopad_external_pin *)	input  wire gain_sine,
(* iopad_external_pin *)	input  wire gain_ac,
(* iopad_external_pin *)	input  wire gain_dc,
(* iopad_external_pin *)	input  wire gain_out,

	// Output
(* iopad_external_pin *)	output wire grid_pwm_p,
(* iopad_external_pin *)	output wire grid_pwm_n,
(* iopad_external_pin *)	output wire dump_pwm,
						output wire grid_pwm_p_oe,
						output wire grid_pwm_n_oe,
						output wire dump_pwm_oe,
						
						
	// External A/D Converters (2.5v)
(* iopad_external_pin *)	output wire  ad_cs,
(* iopad_external_pin *)	output reg	 ad_sclk, 
(* iopad_external_pin *)	input  wire  ad_sdata_vdc,
(* iopad_external_pin *)	input  wire  ad_sdata_vac,
						output wire  ad_cs_oe,
						output wire	 ad_sclk_oe, 

	// Forge PLL control
						output pll_en,
						output [5:0] pll_refdiv,
						output [11:0] pll_fbdiv,
						output [2:0] pll_postdiv1,
						output [2:0] pll_postdiv2,
						output pll_bypass,
						output pll_clk_selection,
    						input pll_lock
);

    // PLL Control, 50 Mhz int Osc Ref,  2 x 48 Mhz = 96 Mhz out
    assign pll_en = 1'b1;
    assign pll_refdiv = 6'b00_0101;		// Equivalent value in decimal form 6'd5,
    assign pll_fbdiv = 12'b0000_1001_0000;	// Equivalent value in decimal form 12'd144,
    assign pll_postdiv1 = 3'b101;		// Equivalent value in decimal form 3'd5,
    assign pll_postdiv2 = 3'b011;		// Equivalent value in decimal form 3'd3,
    assign pll_bypass = 1'b0;
    assign pll_clk_selection = 1'b0;
    
    // Enable LAC 0
    assign logic_as_clk0_en = 1'b1;
    
    // Enable OSC
    assign osc_en = 1'b1;
    
    // Emab;e Ouput OEs
    assign ad_sclk_oe 		= 1'b1;
    assign ad_cs_oe 			= 1'b1;
    assign grid_pwm_p_oe 	= 1'b1;
    assign grid_pwm_n_oe 	= 1'b1;
    assign dump_pwm_oe 		= 1'b1;

	//  flops create half rate clk and ad_sclk = !clk;
	reg toggle;
	//reg clk_toggle;
	reg sclk_toggle;
	always @(posedge clk2x) begin 
		toggle <= !toggle;
		clk_toggle 	<= toggle; // To embend in the IOB FF for REF_LAC_0
		sclk_toggle <= toggle; // before inversion/phase delay 
		ad_sclk 	<= sclk_toggle; // inverted to embed in the IOB FF for ad_sclk
	end

	// Create an internal reset 
	reg [7:0] rst_cnt = 0;
	reg reset = 0;
	initial reset = 0;
	initial rst_cnt = 0;
	always @(posedge clk) begin
		rst_cnt <= ( rst_cnt != 8'hff ) ? rst_cnt + 1 : rst_cnt;
		reset <= ( rst_cnt == 8'hff ) ? 1'b1 : 1'b0;
	end
		
	// Instantiate tt chip I/Os
    wire [7:0] ui_in;    // Dedicated inputs
    wire [7:0] uo_out;   // Dedicated outputs
    wire [7:0] uio_in;   // IOs: Input path
    wire [7:0] uio_out;  // IOs: Output path
    wire [7:0] uio_oe;   // IOs: Enable path (active high: 0=input, 1=output)

	// Connect up inputs
	assign ui_in[0] = ad_sdata_vac;
	assign ui_in[1] = ad_sdata_vdc;
	assign ui_in[2] = gain_sine;
	assign ui_in[3] = gain_ac;
	assign ui_in[4] = gain_dc;
	assign ui_in[5] = gain_out;
	assign ui_in[6] = pwm_vref;
	assign ui_in[7] = 1'b1;
	
	// Connect up outputs
	assign ad_cs 		= uo_out[0];
	assign grid_pwm_p 	= uo_out[1];
	assign grid_pwm_n 	= uo_out[2];
	assign dump_pwm 		= uo_out[3];

	tt_um_60hz_load i_chip(
		.ui_in	( ui_in		),    // Dedicated inputs
		.uo_out	( uo_out		),   // Dedicated outputs
		.uio_in	( 8'h00		),   // IOs: Input path
		.uio_out( 			),  	// IOs: Output path
		.uio_oe	( 			),   // IOs: Enable path (active high: 0=input, 1=output)
		.ena		( 1'b1		),      // always 1 when the design is powered, so you can ignore it
		.clk		( clk		),      // clock
		.rst_n  ( !reset 	)     // reset_n - low to reset
	);

endmodule // forge_launcher_wrapper 
		
		
		
