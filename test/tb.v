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

      .ui_in  (ui_in),    // Dedicated inputs
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
  wire cos_pwm_n, cos_pwm_p;
  assign sin_pwm_p = uo_out[0];
  assign sin_pwm_n = uo_out[1];
  assign cos_pwm_p = uo_out[2];
  assign cos_pwm_n = uo_out[3];

  // add some simple counters for sanity check

  reg  [31:0] cnt;
  reg  [31:0] cnt_sin_n, cnt_sin_p, cnt_sin_np;
  reg  [31:0] cnt_cos_n, cnt_cos_p, cnt_cos_np;
  always @(posedge clk) begin
	cnt <= (!rst_n)?0:cnt+1;
	cnt_sin_p <= (!rst_n)?0:(sin_pwm_p )?cnt_sin_p +1:cnt_sin_p;
	cnt_sin_n <= (!rst_n)?0:(sin_pwm_n )?cnt_sin_n +1:cnt_sin_n;
	cnt_sin_np<= (!rst_n)?0:(sin_pwm_n &
							 sin_pwm_p )?cnt_sin_np+1:cnt_sin_np;
	cnt_cos_p <= (!rst_n)?0:(cos_pwm_p )?cnt_cos_p +1:cnt_cos_p;
	cnt_cos_n <= (!rst_n)?0:(cos_pwm_n )?cnt_cos_n +1:cnt_cos_n;
	cnt_cos_np<= (!rst_n)?0:(cos_pwm_n &
							 cos_pwm_p )?cnt_cos_np+1:cnt_cos_np;
  end
endmodule
