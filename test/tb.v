// vim: ts=4:
`default_nettype none
`timescale 1ns / 1ps

/* This testbench just instantiates the module and makes some convenient wires
   that can be driven / tested by the cocotb test.py.
*/
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
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
  reg adc_vac, adc_vdc;
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

      .ui_in  ({ui_in[7:2], adc_vdc, adc_vac}),    // Dedicated inputs
      .uo_out (uo_out),   // Dedicated outputs
      .uio_in (uio_in),   // IOs: Input path
      .uio_out(uio_out),  // IOs: Output path
      .uio_oe (uio_oe),   // IOs: Enable path (active high: 0=input, 1=output)
      .ena    (ena),      // enable - goes high when design is selected
      .clk    (clk),      // clock
      .rst_n  (rst_n)     // not reset
  );

  // Expand IO for easy wave viewing
  wire sin_pwm_n, sin_pwm_p;
  assign sin_pwm_p = uo_out[1];
  assign sin_pwm_n = uo_out[2];

  // add some simple counters for sanity check

  reg  [31:0] cnt;
  reg  [31:0] cnt_sin_n, cnt_sin_p, cnt_sin_np;
  always @(posedge clk) begin
	cnt <= (!rst_n)?0:cnt+1;
	cnt_sin_p <= (!rst_n)?0:(sin_pwm_p )?cnt_sin_p +1:cnt_sin_p;
	cnt_sin_n <= (!rst_n)?0:(sin_pwm_n )?cnt_sin_n +1:cnt_sin_n;
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

