// vim: ts=4:
module cordic_sincos_50000_core_20 (
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    // angle_in must be in -12500..+12500  (� -p/2..+p/2)
    input  wire signed [15:0] angle_in,

    output reg  signed [15:0] sin_out,
    output reg  signed [15:0] cos_out,
    output reg               valid,
    output reg               busy
);

    // *** INTERNAL WIDTH WITH GUARD BITS ***
    // 16-bit I/O, 19-bit internal
    localparam integer IW = 17;

    // atan(2^-i) scaled for -12500..+12500 � -p/2..+p/2

    logic signed [15:0] atan_table [0:14];
	initial begin
		atan_table = '{
        16'sd6250,   // i=0
        16'sd3694,   // i=1
        16'sd1948,   // i=2
        16'sd989,    // i=3
        16'sd497,    // i=4
        16'sd249,    // i=5
        16'sd125,    // i=6
        16'sd62,     // i=7
        16'sd31,     // i=8
        16'sd16,     // i=9
        16'sd8,      // i=10
        16'sd4,      // i=11
        16'sd2,      // i=12
        16'sd1,      // i=13
        16'sd0       // i=14
    };
	end

    // K � 0.607252935 ? 16-bit fixed � 19997, then sign-extend to 19 bits
    logic signed [15:0] K16;
	initial K16  = 16'sd19997;
    logic signed [IW-1:0] K;
	initial K = {{(IW-16){K16[15]}}, K16};

    // *** INTERNAL STATE: 19 BITS ***
    reg signed [IW-1:0] x, y, z;
    reg [3:0]           iter;  // 0..14

    // sign-extend atan_table entry to 19 bits
    wire signed [IW-1:0] dz;
	assign dz = {{(IW-16){atan_table[iter][15]}}, atan_table[iter]};
    always @(posedge clk) begin
        if (rst) begin
            x       <= 0;
            y       <= 0;
            z       <= 0;
            iter    <= 0;
            busy    <= 1'b0;
            valid   <= 1'b0;
            sin_out <= 0;
            cos_out <= 0;
        end else begin
            valid <= 1'b0;

            if (start && !busy) begin
                x    <= K;
                y    <= {IW{1'b0}};
                z    <= {{(IW-16){angle_in[15]}}, angle_in};  // sign-extend
                iter <= 0;
                busy <= 1'b1;
            end
            else if (busy) begin

                if (z >= 0) begin
                    x <= x - (y >>> iter);
                    y <= y + (x >>> iter);
                    z <= z - dz;
                end else begin
                    x <= x + (y >>> iter);
                    y <= y - (x >>> iter);
                    z <= z + dz;
                end

                if (iter == 4'd14) begin
                    busy  <= 1'b0;
                    valid <= 1'b1;
                    // take the top 16 bits (sign-preserving)
                    cos_out <= x[IW-1 -: 16];
                    sin_out <= y[IW-1 -: 16];
                end

                iter <= iter + 1'b1;
            end
        end
    end

endmodule

