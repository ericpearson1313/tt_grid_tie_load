// vim: ts=4:
`default_nettype none
`timescale 1ns / 1ps

/* This testbench just instantiates the module and makes some convenient wires
   that can be driven / tested by the cocotb test.py.
*/
// for gate level tests we need a local cordic
`ifdef GL_TEST
`include "cordic.sv"
`endif

module tb ();

  // Dump the signals to a FST file. You can view it with gtkwave or surfer.
  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  // Wire up the inputs and outputs:
  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
  wire [7:0] uo_out;
  reg adc_vac, adc_vdc;
  wire [5:0] in_pwm;
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  // Replace tt_um_example with your module name:
  tt_um_60hz_load user_project (

      // Include power ports for the Gate Level test:
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif

      .ui_in  ({ in_pwm[5:0], adc_vdc, adc_vac}),    // Dedicated inputs
      .uo_out (uo_out),   // Dedicated outputs
      .uio_in (uio_in),   // IOs: Input path
      .uio_out(uio_out),  // IOs: Output path
      .uio_oe (uio_oe),   // IOs: Enable path (active high: 0=input, 1=output)
      .ena    (ena),      // enable - goes high when design is selected
      .clk    (clk),      // clock
      .rst_n  (rst_n)     // not reset
  );

  // Expand IO for easy wave viewing
  wire sin_pwm_n, sin_pwm_p, pwm;
  assign sin_pwm_p = uo_out[1];
  assign sin_pwm_n = uo_out[2];
  assign pwm = uo_out[3];

  // add some simple counters for sanity check

  reg  [31:0] cnt;
  reg  [31:0] cnt_sin_n, cnt_sin_p, cnt_sin_np, cnt_pwm;
  always @(posedge clk) begin
	cnt <= (!rst_n)?0:cnt+1;
	cnt_sin_p <= (!rst_n)?0:(sin_pwm_p )?cnt_sin_p +1:cnt_sin_p;
	cnt_sin_n <= (!rst_n)?0:(sin_pwm_n )?cnt_sin_n +1:cnt_sin_n;
	cnt_pwm   <= (!rst_n)?0:(pwm)?cnt_pwm+1:cnt_pwm;
	cnt_sin_np<= (!rst_n)?0:(sin_pwm_n &
							 sin_pwm_p )?cnt_sin_np+1:cnt_sin_np;
  end

    /////////////////////
    // AD7352 Model     
    /////////////////////

	logic [11:0] vdc, vac; // driven by testbench
    // sim pad register of CS
    logic cs_ireg;
    always @(posedge !clk)
        cs_ireg <= ( !rst_n ) ? 0 : uo_out[0];
  
    // synthesisiable ADC models to feed system data into LCC
    logic [3:0] m_ad_out;
    lcc_adcsim i_adcsim(
        .clk( !clk ),
        .reset( !rst_n ),
        .ad_in( { 12'd0, 12'd0, vdc, vac } ),
        .ad_out( m_ad_out[3:0] ),
        .ad_cs( cs_ireg )
    );

    // sim out pad output reg for data
    always_ff @(posedge !clk) begin 
      if( !rst_n ) begin
        adc_vac <= 0;
        adc_vdc <= 0;
      end else begin
        adc_vac <= m_ad_out[0];
        adc_vdc <= m_ad_out[1];
      end
    end

	//////////////////////
    // Cordic to drive AC
	//////////////////////

	// Driven by testbench
	wire [15:0] phase_lead; // 50000 steps per cycle, typical 1000 = 2% lead

	// Otherwise this feeds the 
    reg signed [15:0] angle;
    wire [15:0] sin_out, cos_out;
    wire valid, busy;
	wire [11:0] cos3x;

	always @(posedge clk) begin
		if( !rst_n ) begin
			angle <= -12500;
		end else if ( cs_ireg ) begin
			angle <= ( angle == 12499 ) ? -12500 : angle + 1;
		end
	end

    wire signed [15:0] angle_ofs;
    wire signed [15:0] angle_new;

	assign angle_ofs = angle + phase_lead;
	assign angle_new = ( angle_ofs > 12499 ) ? angle_ofs - 25000 : angle_ofs;

	reg polarity;
	always @(posedge clk) begin
		if( !rst_n ) begin
			polarity <= 0;
		end else if ( cs_ireg ) begin
			polarity <= ( angle_new == 12499 ) ? !polarity : polarity;
		end
	end

    cordic_sincos_50000_core_20 i_tb_sin(
        .clk( clk ),
        .rst( !rst_n ),
        .start( cs_ireg ),
        .angle_in( angle_new ),
        .sin_out ( ),
        .cos_out ( cos_out ),
        .valid( ),
        .busy( )
    );

	wire [15:0] cos_pol;
	assign cos_pol = ( polarity ) ? ~cos_out : cos_out;
	assign cos3x = cos_pol[15-:12] + { cos_pol[15], cos_pol[15-:11] };

	assign vac = cos3x;


	//////////////////////
    // PWM Generators
	//////////////////////

	// Ratios drive by testbench
	logic ac_mode;
	logic [15:0] num_vref, den_vref;
	logic [15:0] num_sine, den_sine;
	logic [15:0] num_out , den_out ;
	logic [15:0] num_ac  , den_ac  ;
	logic [15:0] num_dc  , den_dc  ;
	logic pwm_vref, pwm_sine, pwm_out, pwm_ac, pwm_dc;

	// Pwm signals
	recip_pwm #( 16 ) i_pwm0 ( clk, !rst_n, num_vref, den_vref, pwm_vref );
	recip_pwm #( 16 ) i_pwm1 ( clk, !rst_n, num_sine, den_sine, pwm_sine );
	recip_pwm #( 16 ) i_pwm2 ( clk, !rst_n, num_out , den_out , pwm_out  );
	recip_pwm #( 16 ) i_pwm3 ( clk, !rst_n, num_ac  , den_ac  , pwm_ac   );
	recip_pwm #( 16 ) i_pwm4 ( clk, !rst_n, num_dc  , den_dc  , pwm_dc   );
	assign in_pwm[5:0] = { ac_mode, pwm_vref, pwm_sine, pwm_out, pwm_ac, pwm_dc };

endmodule

// external adc sim block
module lcc_adcsim (
        // system
        input logic clk,
        input logic reset,
        // ADC simulator connections, parallel in, serial out
        input logic [3:0][11:0] ad_in,
        output logic [3:0] ad_out,
        // driven by sampled falling edge of cs
        input logic ad_cs
    );

    logic [19:0] cs_del;
    always_ff @(posedge clk)
      if( reset ) begin
        cs_del <= 0;
      end else begin
        cs_del <= { cs_del[18:0], ad_cs };
      end
    logic [19:0] cs_trig;
    assign cs_trig[18:0] =  cs_del[19:0] &~{ cs_del[18:0], ad_cs };
    logic [3:0][11:0] hold;
    always_ff @(posedge clk) begin
      if( reset ) begin
        hold <= 0;
      end else begin
        hold[0] <= ( cs_trig[0] ) ? ( ad_in[0] ^ 12'h800 ) : ( |cs_trig[12-:12] ) ? { hold[0][10:0], 1'b0 } : hold[0];
        hold[1] <= ( cs_trig[0] ) ? ( ad_in[1] ^ 12'h800 ) : ( |cs_trig[12-:12] ) ? { hold[1][10:0], 1'b0 } : hold[1];
        hold[2] <= ( cs_trig[0] ) ? ( ad_in[2] ^ 12'h800 ) : ( |cs_trig[12-:12] ) ? { hold[2][10:0], 1'b0 } : hold[2];
        hold[3] <= ( cs_trig[0] ) ? ( ad_in[3] ^ 12'h800 ) : ( |cs_trig[12-:12] ) ? { hold[3][10:0], 1'b0 } : hold[3];
      end
    end
    assign ad_out[0] = hold[0][11];
    assign ad_out[1] = hold[1][11];
    assign ad_out[2] = hold[2][11];
    assign ad_out[3] = hold[3][11];
endmodule

module recip_pwm #(
    parameter W = 16   // bit-width of numerator/denominator
)(
    input  wire         clk,
    input  wire         rst,
    input  wire [W-1:0] n,
    input  wire [W-1:0] d,
    output reg          pwm
);

    reg [W-1:0] acc;

    always @(posedge clk) begin
        if (rst) begin
            acc <= 0;
            pwm <= 0;
        end else begin
            // accumulate numerator
			acc <= ( acc >= d ) ? acc - d + n : acc + n;
			pwm <= ( acc >= d ) ? 1'b1 : 1'b0;
        end
    end

endmodule

