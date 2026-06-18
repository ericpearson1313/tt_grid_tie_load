	module dclink_model(
		input logic clk,
		input logic reset,
		// Model Inputs
		input logic signed [15:0] pnet,
		input logic pwm,
		// Model Outputs
		output logic signed [11:0] vdc
	);

	logic signed [37:0] vcap, next_vcap; // 340 V / 1544 DN
	logic signed [15:0] pdump; // 340 W / 1544 DN

	// With testbench control inputs and the dump PWM
   // The model based around capacitor enery storage
   // responds and provides Vac and Vdc readings and a phase angle contrl
   
	localparam R = 12.8; // Ohms
	localparam C = 200.0; // Uf
	localparam F = 48.0; // Mhz

	// LUT
	reg [10:0] dtocv_rom [63:0]; // tiny
	integer ii;
	initial begin
		for( int ii = 0; ii < 64; ii++ ) begin
			dtocv_rom[ii] = ( 67108864.0 * 1544.0 / ( C * F * (ii * 32.0 + 16) * 340.0 ));
			// synopsys translate_off
			$display("dtocv[ %0d ] = %0d", ii, dtocv_rom[ii] );
			// synopsys translate_on
		end
	end

	assign next_vcap = vcap + ((pnet - pdump) * dtocv_rom[ vcap[36-:6] ] );
	
	always @(negedge clk) begin
		if( reset ) begin
			vcap <= 0;
			pdump <= 0;	
		end else begin
			pdump <= ( !pwm ) ? 0 : ((vcap[36-:11] * vcap[36-:11] ) >> 6) ; // 340/1544/12.8 ~= 1/64 for R = 12.8 ohms-ish. 
			vcap  <= ( next_vcap[37] ) ? 0 : ( next_vcap[36-:11] > 2000 ) ? { 12'd2000, 26'h000_0000 } : next_vcap;
		end
	end
			
	// Scaled model outputs:
	assign vdc[11:0] = vcap[37-:12]; 

endmodule // dclink_model
