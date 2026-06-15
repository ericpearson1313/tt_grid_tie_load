// vim: ts=4:
`timescale 1ns / 1ps
module grid_tie_chip

#(
	// Parameter Declarations
	parameter UNIQ_ID = 32'h0000_0000
)

(
	// Input Buttons
	input  logic button,

	// Output LED/SPK
	output logic arm_led_n,
	output logic cont_led_n,
	output logic speaker,
	output logic speaker_n,
	
	// Bank 1A: Analog Inputs / IO
	output [8:1] anain,
	
	// Bank 7, future serial port
	inout [6:0] digio,

	// External Current Control Input
	input	 logic  [2:0] iset, // Current target in unit amps  
	
	// SPI8 Bus
	inout  wire [7:0]  spi8_data_pad,   //   pad_io.export
	inout  wire spi_clk0,
	inout  wire spi_ncs,
	inout  wire spi_ds,
	inout  wire spi_nrst,
	
	// HDMI Output 1 (not connect on LCC Dev board)
	output logic		hdmi_d0,
	output logic		hdmi_d1,
	output logic		hdmi_d2,
	output logic      hdmi_ck,

	// HDMI Output 2 (Tru LVDS)
	output logic		hdmi2_d0,
	output logic		hdmi2_d1,
	output logic		hdmi2_d2,
	output logic      hdmi2_ck,
	
	// Input clock, reset
	output logic clk_out, // Differential output
	input logic clk_in,	// Reference 48Mhz or other
	input logic reset_n
);

	logic [4:0] key; // keypad, bit 4 indicates pressed



	// PLL (only 1 PLL in E144 package!)

	logic clk;	// global 48Mhz clock
	logic clk4; // global 192MhZ spi8 clk
	logic hdmi_clk; 	// Pixel clk, apparentlyi can support 720p
	logic hdmi_clk5;  // 5x pixel clk clock for data xmit, 10b*3=30/3lanes=10ddr=5 

	trial_pll _spll(
		.inclk0 (clk_in),		// External clock input
		.c0     (clk_out), 	// Flash Clock 6Mhz, also External clock output differential
		.c1	  (clk),			// Global Clock ADC rate 48 Mhz
		.c2	  (clk4),		// Global Clock SPI8 rate 192 Mhz
		.c3	  (hdmi_clk),	// HDMI pixel clk
		.c4	  (hdmi_clk5)  // HDMI ddr clock 5x
		);
		
	// delayed from fpga config and external reset d-assert

	logic [3:0] reset_shift = 0; // initial value upon config
	always @(posedge clk) begin
			if( !reset_n ) begin
				reset_shift <= 4'h0;
			end else begin
				if( reset_shift != 4'HF ) begin
					reset_shift[3:0] <= reset_shift[3:0] + 4'h1;
				end else begin
					reset_shift[3:0] <= reset_shift[3:0];
				end
			end
	end

	logic reset;
	assign reset = (reset_shift[3:0] != 4'hF) ? 1'b1 : 1'b0; // reset de-asserted after all bit shifted in 


	// LEDs active low
	logic arm_led;
	logic cont_led;
	assign arm_led_n = arm_led;	// not complemented bc external NPN
	assign cont_led_n = cont_led; //  we added a NPN  to drive 12v led
	assign speaker_n = !speaker;

	// AIN
	assign anain[3:1] = iset[2:0]; // active low switch inputs
	assign anain[4] = !reset;
	logic [24:0] count;
	always @(posedge clk) begin
		count <= count + 1;
	end
	assign anain[8:5] = count[24:21];
	assign anain[8]=count[24];

	/////////////////////////////////
	/////////////////////////////////
	////
	////  Grid Tie Chip (DUT) 
	////
	/////////////////////////////////
	/////////////////////////////////
	
  // Wire up the inputs and outputs:

  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
  wire [7:0] uo_out;


  // TT Grid Tie Chip under test
  tt_um_60hz_load user_project (
      .ui_in  (ui_in),    // Dedicated inputs
      .uo_out (uo_out),   // Dedicated outputs
      .uio_in (uio_in),   // IOs: Input path
      .uio_out(uio_out),  // IOs: Output path
      .uio_oe (uio_oe),   // IOs: Enable path (active high: 0=input, 1=output)
      .ena    ( 1'b1 ),      // enable - goes high when design is selected
      .clk    (clk),      // clock
      .rst_n  (!reset)     // not reset
  );
  
  // Expand Inputs and outputs to named signals
  logic pwm_sin_n, pwm_sin_p, pwm_dump; // Outputs
  logic pwm_vref, gain_sin, gain_out, gain_ac, gain_dc; // Inputs
  logic ac_mode;
  
  assign ui_in[2] = pwm_vref;
  assign ui_in[3] = gain_sin;
  assign ui_in[4] = gain_out;
  assign ui_in[5] = gain_ac;
  assign ui_in[6] = gain_dc;
  assign ui_in[7] = 1'b1; // AC mode 1/4 cycle
  
  assign pwm_sin_p = uo_out[2];
  assign pwm_sin_n = uo_out[3];
  assign pwm_dump  = uo_out[4];

  // ADC simulated IO
  logic adc_cs, adc_sdata_vac, adc_sdata_vdc;
  
  assign adc_cs = uo_out[0];
  assign ui_in[0] = adc_sdata_vac;
  assign ui_in[1] = adc_sdata_vdc;
  

	/////////////////////////////////
	/////////////////////////////////
	////
	////       TESTER
	////
	/////////////////////////////////
	//////////////////////////////////
	

	//////////////////////
    // PWM Generators
	//////////////////////

	// Test plan drives pgrid and vref setpoint.
	logic signed [15:0] pgrid; // net power on our grid (gens - loads)
	logic signed [11:0] vref;
	
	assign vref = 1744;	// 340 vdc
	assign pgrid = 500; // aprox 100w
	
	
	// Ratios drive by testbench
	logic [15:0] num_vref, den_vref; // from system model
	logic [15:0] num_sin , den_sin ;
	logic [15:0] num_out , den_out ;
	logic [15:0] num_ac  , den_ac  ;
	logic [15:0] num_dc  , den_dc  ;

	// Pwm signals
	recip_pwm #( 16 ) i_pwm0 ( clk, reset, num_vref, den_vref, pwm_vref  );
	recip_pwm #( 16 ) i_pwm1 ( clk, reset, num_sin , den_sin , gain_sin  );
	recip_pwm #( 16 ) i_pwm2 ( clk, reset, num_out , den_out , gain_out  );
	recip_pwm #( 16 ) i_pwm3 ( clk, reset, num_ac  , den_ac  , gain_ac   );
	recip_pwm #( 16 ) i_pwm4 ( clk, reset, num_dc  , den_dc  , gain_dc   );
	
	assign ac_mode = 1'b1;

	assign num_sin  =  99;
	assign den_sin  =  100;
	assign num_out  =  99;
	assign den_out  =  100;
	assign num_ac   =  25;
	assign den_ac   =  100;
	assign num_dc   =  999;
	assign den_dc   =  1000;
	assign num_vref =  vref;
	assign den_vref =  2048;	
	
	// and the 6 adc pins, expanded to 12 bit adc channels
	logic [11:0] mad_a0, mad_a1, mad_b0, mad_b1, iest;
	logic mad_strobe;	
	

	// monitor LCC digital I/O pins
	logic [7:0] lcc_mon;
	assign lcc_mon = { 
							pwm_sin_p, // can put burn here
							pwm_sin_n,
							pwm_dump ,
							pwm_vref ,
							gain_sin ,
							gain_out ,
							gain_ac  , 
							gain_dc  };	
							
	// Simualte an external ADC
	logic signed [11:0] vdc, vac;
	logic [1:0] unused;
	adcsim  i_adcsim (
		// Input clock
		.clk( clk ),
		.reset( reset ),
		// External A/D interface
		.ad_cs( adc_cs ),
		.ad_out( {unused[0], unused[1], adc_sdata_vdc, adc_sdata_vac } ),
		// simualted ADC Data for Tester
		.ad_in( { 12'h000, 12'h000, vac, vdc })
	);	

	//////////////////////
    // Cordic to drive AC
	//////////////////////

	// Driven by difference from target voltage to get some reactivity on AC. 
	reg signed [15:0] phase_lead; // 50000 steps per cycle, typical 1000 = 2% lead
	always @(posedge clk) 
		phase_lead  <= ( vdc - vref ) * int'(( 12500.0 / 90.0 ) * ( 90.0 / 340.0 ) * ( 340.0 / 1744.0 )); // 340v error is 90 degrees phase shift	
		
	// Otherwise this feeds the 
   reg signed [15:0] angle;
   wire [15:0] sin_out, cos_out;
   wire valid, busy;
	wire [11:0] cos3x;

	always @(posedge clk) begin
		if( reset ) begin
			angle <= -12500;
		end else if ( adc_cs ) begin
			angle <= ( angle == 12499 ) ? -12500 : angle + 1;
		end
	end

    wire signed [15:0] angle_ofs;
    wire signed [15:0] angle_new;

	assign angle_ofs = angle + phase_lead;
	assign angle_new = ( angle_ofs > 12499 ) ? angle_ofs - 25000 :
                       ( angle_ofs < -12500) ? angle_ofs + 25000 : angle_ofs;

	reg polarity;
	always @(posedge clk) begin
		if( reset ) begin
			polarity <= 0;
		end else if ( adc_cs ) begin
			polarity <= ( angle_new == 12499 ) ? !polarity : polarity;
		end
	end

    cordic_sincos_50000_core_20 i_tb_sin(
        .clk( clk ),
        .rst( reset ),
        .start( adc_cs ),
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


	
   // Plant Model 48Mhz
	dclink_model i_dclink (
		.clk	( clk ),
		.reset 	( reset ),
		// Model Inputs
		.pnet		( pgrid ),  // input Grid net power (gens-loads)
		.pwm		( pwm_dump ),	// Dump PWM
		// Model Outputs
		.vdc		( vdc ), 	// DC Link Voltage
	);

	
	
	// Energy accumulator Display
	logic [7:0] pwr_str;
	//string_overlay #(.LEN(8)) _pwr4 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d100),.y('d3), .out( pwr_str[4] ), .str("Out J 0x") );
	//hex_overlay    #(.LEN(2)) _pwr5 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char)    , .x('d108),.y('d3), .out( pwr_str[5] ), .in( eout[39-:8] ) );
	//string_overlay #(.LEN(1)) _pwr6 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d110),.y('d3), .out( pwr_str[6] ), .str(".") );
	//hex_overlay    #(.LEN(5)) _pwr7 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char)    , .x('d111),.y('d3), .out( pwr_str[7] ), .in( eout[31-:20]) );
	
	// Digio pads.
	logic [6:0] digio_in, digio_out;
	ioe_pads7 _digio_pads (
		.dout( digio_in ), 
		.din( digio_out ),  
		.pad_io( digio ),
		.oe ( 7'b1101010 ) // Row drive 1653, col sense 204
	);
		
		
	// Keyboard Scanner
	key_scan _keypad ( 
		.clk( clk ),
		.reset( reset ),
		.keypad_in( digio_in ),
		.keypad_out( digio_out ),
		.key( key )
	);	

	// SPI 8 Memory interface

	logic [7:0] 	spi_data_out;
	logic   			spi_data_oe;
	logic [1:0]   	spi_le_out; // match delay
	logic [7:0] 	spi_data_in;
	logic [1:0]		spi_le_in; // match IO registering
	logic				spi_clk;
	logic				spi_cs;
	logic				spi_rwds_out;
	logic				spi_rwds_oe;
	logic				spi_rwds_in;
	
	// SPI Controller
	
	logic psram_ready;
	logic [17:0] rdata;
	logic [15:0] wdata;
	logic rvalid;
	logic [24:0] araddr;
	logic arvalid, arready;
	logic wready;
	logic [24:0] awaddr;
	logic awvalid;
	logic awready;
	
	// hack view alignment hook
	logic pwm_del, burn_del, zoom_del;
	logic [15:0] retrigger;
	logic [24:0] base_addr;
	logic [24:0] burn_addr;
	logic [3:0] zoom;
	logic zoom_button;
	logic key_del;
	logic burn;
	logic m_cap_halt;
	logic m_pwm;

	
	always @(posedge clk) begin
		if( reset ) begin
			zoom <= 0;
			zoom_button <= 0;
			key_del <= 0;
		end else begin
			key_del <= key[4];
			pwm_del <= m_pwm;
			burn_del <= burn;
			retrigger <= ( !pwm_del && m_pwm && retrigger == 0 ) ? 16'hffff : ( retrigger == 0 ) ? 0 : retrigger - 1;
			base_addr <= ( !pwm_del && m_pwm && retrigger == 0 && !m_cap_halt ) ? awaddr : base_addr; 
			burn_addr <= ( !pwm_del && m_pwm && retrigger == 0 && !m_cap_halt ) ? awaddr : // default to base addr
			             ( !burn_del && burn                              ) ? awaddr : // snap to burn addr
							 ( !key_del && key == 5'h16                       ) ? burn_addr + (512<<zoom) :
							 ( !key_del && key == 5'h14                       ) ? burn_addr - (512<<zoom) :
							                                                      burn_addr;
			zoom <= ( !key_del && key == 5'h12 ) ? ( ( zoom == 12 ) ? 0 : zoom + 1 ) : 
					  ( !key_del && key == 5'h18 ) ? ( ( zoom == 0 ) ? 11 : zoom - 1 ) : zoom;
		end
	end 
	
	// bv raddr bus 
	logic [24:0] 	bv_araddr;
	logic [7:0]  	bv_arlen; // always == 8'd32
	logic        	bv_arvalid;
	logic 		 	bv_arready;
	psram_ctrl _psram_ctl(
		// System
		.clk		( clk ),
		.clk4		( clk4 ),
		.reset	( reset ),
		// Psram spi8 interface
		.spi_data_out( spi_data_out ),
		.spi_data_oe(  spi_data_oe  ),
		.spi_le_out( 	spi_le_out 	 ),
		.spi_data_in( 	spi_data_in  ),
		.spi_le_in( 	spi_le_in 	 ),
		.spi_clk( 		spi_clk 		 ),
		.spi_cs( 		spi_cs 		 ),
		.spi_rwds_out( spi_rwds_out ),
		.spi_rwds_oe( 	spi_rwds_oe  ),
		.spi_rwds_in( 	spi_rwds_in  ),
		// Status
		.psram_ready( psram_ready ),	// Indicates control is ready to accept requests
		// AXI4 R/W port
		// Write Data
		.wdata( wdata ),
		.wvalid( 1'b1 ), // always avail)
		.wready( wready ),
		// Write Addr
		.awaddr( awaddr ),
		.awlen( 8'h08 ),	// assumed 8
		.awvalid( awvalid ), // write valid
		.awready( awready ),
		// Write Response
		.bready( 1'b1 ),	// Assume 1, non blocking
		.bvalid( ),
		.bresp(  ),
		// Read Addr, Port 0, bl=4
		.araddr0 ( burn_addr + ( araddr << zoom ) - (((burn)?(192*16):(64*16))<<zoom) ),
		.arlen0  ( 8'd04 ),	// assumed 4
		.arvalid0( arvalid ), // read valid	
		.arready0( arready ),
		// Read Addr, Port 1, bl = 32
		.araddr1 ( bv_araddr ),
		.arlen1  ( bv_arlen ),	// assumed 32
		.arvalid1( bv_arvalid ), // read valid	
		.arready1( bv_arready ),
		// Read Data, shared
		.rdata( rdata[17:0] ),
		.rvalid( rvalid ),
		.rready( 1'b1 ) // Assumed 1, non blocking
	);	

 	    
	// Capture ID regs 
	//logic [35:0] id_reg;
	//always @(posedge clk) begin
	//	id_reg <= ( !psram_ready && rvalid ) ? { id_reg[17:0], rdata[17:0] } : id_reg;
	//end
		
	// feedback delay le 2 cycles to match IO
	logic [1:0] 	spi_le_reg;
	always @(posedge clk4) spi_le_reg <= spi_le_out;
	always @(posedge clk4) spi_le_in  <= spi_le_reg;
	
	// Registered I/O pad interfaces
	reg_ioe _spi_d0 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[0] ), .din( spi_data_out[0] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[0] ) );
	reg_ioe _spi_d1 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[1] ), .din( spi_data_out[1] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[1] ) );
	reg_ioe _spi_d2 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[2] ), .din( spi_data_out[2] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[2] ) );
	reg_ioe _spi_d3 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[3] ), .din( spi_data_out[3] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[3] ) );
	reg_ioe _spi_d4 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[4] ), .din( spi_data_out[4] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[4] ) );
	reg_ioe _spi_d5 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[5] ), .din( spi_data_out[5] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[5] ) );
	reg_ioe _spi_d6 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[6] ), .din( spi_data_out[6] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[6] ) );
	reg_ioe _spi_d7 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[7] ), .din( spi_data_out[7] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[7] ) );
	reg_ioe _spi_ds ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_rwds_in    ), .din( spi_rwds_out    ), .oe( spi_rwds_oe ), .pad_io( spi_ds           ) );
	reg_ioe _spi_clk( .inclock( clk4 ), .outclock( clk4 ), .dout( ),                .din( spi_clk  ),        .oe( 1'b1        ), .pad_io( spi_clk0         ) );
	reg_ioe _spi_ncs( .inclock( clk4 ), .outclock( clk4 ), .dout( ),                .din( !spi_cs  ),        .oe( 1'b1        ), .pad_io( spi_ncs          ) ); // invert CS on output
	reg_ioe _spi_nrst(.inclock( clk4 ), .outclock( clk4 ), .dout( ),                .din( !reset   ),        .oe( 1'b1        ), .pad_io( spi_nrst         ) ); // send out nreset
	

	////////////////////////////////
	//       Data Capture
	////////////////////////////////
	
	// Can capture ALL adc samples, when psram_ready
	// write all samples into the fifo (as burst write of 4 16-bit samples)	
	// When there are 8 words in the fifo, initiate a write 
	// increment the address by 16bytes  = 8x 16bit = 2 samples of 64 bit;


			
	// Fifo Write 
	
	logic almost_empty;
	logic [15:0] wrfifo_data;
	logic wrfifo;
	logic [3:0][15:0] mad_data;
	logic [2:0] mad_strobe_d;
	logic mscroll_halt;
	
	always @(posedge clk) begin
		mad_strobe_d <= { mad_strobe_d[1:0], mad_strobe & psram_ready}; 
		if( mad_strobe ) begin
		mad_data <= { { iest[11:8], mad_a0[11:1],lcc_mon[7] },
						 { iest[7:4], mad_a1[11:1],lcc_mon[6] },
						 { iest[3:1],lcc_mon[5], mad_b0[11:1],lcc_mon[4] }, 
						 { 1'b0, lcc_mon[3:1], mad_b1[11:1],lcc_mon[0] } };
		end else begin
			mad_data <= mad_data;
		end
	end
	assign wrfifo_data = ( mad_strobe ) ? { iest[11:8], mad_a0[11:1],lcc_mon[7] } :
			               ( mad_strobe_d[0] ) ? mad_data[2] :
			               ( mad_strobe_d[1] ) ? mad_data[1] :
			               ( mad_strobe_d[2] ) ? mad_data[0] : 16'h0048;
	assign wrfifo = (mad_strobe & psram_ready) | (|mad_strobe_d);
	
	adc_fifo _write_fifo
	(
	.clock( clk ),
	.almost_empty( almost_empty ),
	.wrreq( wrfifo ),
	.data( wrfifo_data ),
	.rdreq( wready ),
	.q( wdata )
	);

	// Fifo Read / PSRAM Write control. 
	// when there are 8 or more (!almost_empty)
	// psram write awaddr and awvalid write request
	// wait for awready
	// increment awaddr address by 16
	// Repeat.
	
	always @(posedge clk) begin
		if( reset ) begin
			awaddr <= 25'b0;
			awvalid <= 0;
		end else begin
			if( m_cap_halt && awaddr[24:4] == (base_addr[24:4] - 16384) ) begin // approx 10 ms before start
				awvalid <= 0;
				awaddr <= awaddr;
			end else begin
				awvalid <= !almost_empty; // race if mem ctrl reads ahead, but not here
				awaddr <= ( awready & awvalid ) ? awaddr + 25'd16 : awaddr;
			end
		end
	end
	
	/////////////////////////////////
	////
	////       HDMI VIDEO
	////
	//////////////////////////////////
	
	// HDMI reset
	logic [3:0] hdmi_reg;
	always @(posedge hdmi_clk) begin
		hdmi_reg[3:0] <= { hdmi_reg[2:0], reset };
	end
	logic hdmi_reset;
	assign hdmi_reset = hdmi_reg[3];
	
	logic video_preamble;
	logic data_preamble;
	logic video_guard;
	logic data_guard;
	logic data_island;
	
	// XVGA 800x480x60hz sych generator
	logic blank, hsync, vsync;
	vga_800x480_sync _sync
	(
		.clk(   hdmi_clk   ),	
		.reset( reset ),
		.blank( blank ),
		.hsync( hsync ),
		.vsync( vsync ),
		// HDMI encoding controls
		.video_preamble( video_preamble ),
		.data_preamble ( data_preamble  ),
		.video_guard   ( video_guard    ),
		.data_guard    ( data_guard     ),
		.data_island   ( data_island    )
	);
	
	// Font Generator
	logic [7:0] char_x, char_y;
	logic [255:0] ascii_char;
	logic [15:0] hex_char;
	logic [1:0] bin_char;
	ascii_font57 _font
	(
		.clk( hdmi_clk ),
		.reset( reset ),
		.blank( blank ),
		.hsync( hsync ),
		.vsync( vsync ),
		.char_x( char_x ), // 0 to 105 chars horizontally
		.char_y( char_y ), // o to 59 rows vertically
		.hex_char   ( hex_char ),
		.binary_char( bin_char ),
		.ascii_char ( ascii_char )	
	);

	// test pattern gen
	logic [7:0] test_red, test_green, test_blue;
	test_pattern _testgen 
	(
		.clk( hdmi_clk  ),
		.reset( reset ),
		.blank( blank ),
		.hsync( hsync ),
		.vsync( vsync ),
		.red	( test_red   ),
		.green( test_green ),
		.blue	( test_blue  )
	);	
	
	// Flash Memory interface (init font and text overlay)
	// the serial interface runs at 6 Mhz (max 7 Mhz!)
	// we assigned c0 the output diff pair clock to this interface.
	
	logic [11:0] 	flash_addr; // 32 bit word address, 16Kbytes total flash for M04
	logic 			flash_read;
	logic				flash_data;
	logic 			flash_wait;
	logic 			flash_valid;
	ufm_flash _flash (
		.clock						( clk_out 			 ), // 6 Mhz
		.avmm_data_addr			( flash_addr[11:0] ), // word address 
		.avmm_data_read			( flash_read 		 ),
		.avmm_data_readdata		( flash_data 		 ),
		.avmm_data_waitrequest	( flash_wait 		 ),
		.avmm_data_readdatavalid( flash_valid 		 ),
		.avmm_data_burstcount	( 128 * 32 			 ), // 4K bit burst
		.reset_n						( !reset 			 )
	);	
	
	// Text Overlay 
	logic text_ovl;
	logic [3:0] text_color;
	text_overlay _text
	(
		.clk( hdmi_clk  ),
		.reset( reset ),
		.blank( blank ),
		.hsync( hsync ),
		.vsync( vsync ),
		// Overlay output bit for ORing
		.overlay( text_ovl ),
		.color( text_color ),
		// Avalon bus to init font and text rams
		.flash_clock( clk_out 			 ), // 6 Mhz
		.flash_addr ( flash_addr[11:0] ), // word address 
		.flash_read ( flash_read 		 ),
		.flash_data ( flash_data 		 ),
		.flash_wait ( flash_wait 		 ),
		.flash_valid( flash_valid 		 )
	);

	/////////////////////////////////////////////////////
	// BlipVert, 1sec dump of 32M sram on HDMI video out
	/////////////////////////////////////////////////////
	
	// clock crossing of blank
	logic [1:0] bvena;
	always @(posedge clk) bvena[1:0] <= { bvena[0], !blank };	
	
	logic [16:0] bv_wdata;
	logic        bv_wvalid;
	logic blipvert;
	logic m_long_fire;
	
	assign blipvert = ( m_long_fire || key == 5'h17 ) ? 1'b1 : 1'b0;
	
	blipvert _bv_unit (
		// System
		.clk		( clk ),
		.reset	( reset ),
		// enable input
		.enable	( bvena[1] & blipvert ), // Rising edge starts
		.base( base_addr[24:0] ), // starting addr to flag first 1k block
		// Psram Port
		.araddr	( bv_araddr ), 
		.arlen 	( bv_arlen  ), // bv uses 32 always
		.arvalid	( bv_arvalid ), // read valid	
		.arready	( bv_arready ),
		.rdata	( rdata[17:0] ), 
		.rvalid	( rvalid ),
		// Output data 
		.vdata	( bv_wdata ),
		.vvalid	( bv_wvalid )
	);
		
	
	// Clock domain crossing fifo 17bit wide
	logic [16:0] bv_vdata;
	logic        bv_vvalid_n; // inverse valid
	logic [30:0] blank_delay;
	logic 		 read_fifo;
	
	always @(posedge hdmi_clk) // Delay reading to allow starting the fill
		{ read_fifo, blank_delay } <= { blank_delay, !blank };
		
	bvfifo _bv_fifo (
		// Write port
		.wrclk	( clk ),
		.wrreq	( bv_wvalid ),
		.data		( bv_wdata[16:0] ),
		// Read port
		.rdclk	( hdmi_clk ),
		.rdreq	( !bv_vvalid_n & read_fifo ), // auto read when not emptyu
		.rdempty	( bv_vvalid_n ),
		.q			( bv_vdata[16:0] )
		);	
		

	// Average of the adc values
	
	logic [0:3][33:0]  acc	   ; // accumulate 4M x 12 bit samples, 1.3 sec
	logic [0:3][11:0]  avg	   ;
	logic [21:0]       acc_cnt ; // count to 4M
	
	always @(posedge clk) begin
		if( reset ) begin
			acc     <= 0;
			acc_cnt <= 0;
			avg     <= 0;
		end else begin
			if( mad_strobe ) begin
				acc[0] <= ( acc_cnt == 0 ) ? { 22'h00_0000, mad_a0[11:0] } : acc[0] + { 22'h00_0000, mad_a0[11:0] };
				acc[1] <= ( acc_cnt == 0 ) ? { 22'h00_0000, mad_a1[11:0] } : acc[1] + { 22'h00_0000, mad_a1[11:0] };
				acc[2] <= ( acc_cnt == 0 ) ? { 22'h00_0000, mad_b0[11:0] } : acc[2] + { 22'h00_0000, mad_b0[11:0] };
				acc[3] <= ( acc_cnt == 0 ) ? { 22'h00_0000, mad_b1[11:0] } : acc[3] + { 22'h00_0000, mad_b1[11:0] };
				if( acc_cnt == 0 ) begin
					avg[0] <= acc[0][33-:12];
					avg[1] <= acc[1][33-:12];
					avg[2] <= acc[2][33-:12];
					avg[3] <= acc[3][33-:12];	
				end else begin
					avg <= avg;
				end
				acc_cnt <= acc_cnt + 1;
			end else begin
				avg <= avg;
				acc <= acc;
				acc_cnt <= acc_cnt;
			end
		end
	end
		
	// snapshot display values during vsync
	logic [11:0] value_1, value_2, value_3, value_4;
	logic [4:0] key_reg;
	always @(posedge clk) begin
		if( vsync ) begin
			value_1[11:0] <= avg[0]; // ad_a0;
			value_2[11:0] <= avg[1]; // ad_a1;
			value_3[11:0] <= avg[2]; // ad_b0;
			value_4[11:0] <= avg[3]; // ad_b1;
			key_reg <= key;
		end
	end
	
	// Overlay PSRAM ID and expected values
	logic [31:0] disp_id;
	//assign disp_id = { id_reg[34:31], id_reg[30:27],id_reg[25:22],id_reg[21:18],id_reg[16:13],id_reg[12: 9],id_reg[ 7: 4],id_reg[ 3: 0] };
	logic [4:0] id_str;
	//string_overlay #(.LEN(5)) _id0(.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y),.ascii_char(ascii_char), .x('h48), .y('h09), .out( id_str[0]), .str( "PSRAM" ) );
	//hex_overlay    #(.LEN(8 )) _id1(.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y),.hex_char(hex_char), .x('h50),.y('d58), .out( id_str[1]), .in( disp_id ) );
   //bin_overlay    #(.LEN(1 )) _id2(.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y),.bin_char(bin_char), .x('h46),.y('h09), .out( id_str[2]), .in( disp_id == 32'h0E96_0001 ) );
	//string_overlay #(.LEN(12)) _id3(.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y),.ascii_char(ascii_char), .x('d120),.y('d59), .out( id_str[3]), .str( "ERIC PEARSON" ) );
	string_overlay #(.LEN( 9)) _id4 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h02),.y('h03), .out(id_str[4]), 
	.str(	( zoom == 0 ) ? " 21us/div" :
			( zoom == 1 ) ? " 43us/div" :
			( zoom == 2 ) ? " 85us/div" :
			( zoom == 3 ) ? "170us/div" :
			( zoom == 4 ) ? "340us/div" :
			( zoom == 5 ) ? "680us/div" :
			( zoom == 6 ) ? "1.4ms/div" :
			( zoom == 7 ) ? "2.7ms/div" :
			( zoom == 8 ) ? "5.5ms/div" :
			( zoom == 9 ) ? " 11ms/div" :
			( zoom == 10) ? " 22ms/div" :
			( zoom == 11) ? " 44ms/div" :
			/*zoom == 12)*/ " 87ms/div" ) );

	
	// Overlay the Keystroke
	logic key_str, key_strg;
	hex_overlay #(.LEN(1)) _key  (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x(1),.y(58), .out( key_str  ), .in( key_reg[3:0] ) );
	assign key_strg = key_str & key_reg[4];

	// 4ch Oscilloscope mem & vga display
	logic [7:0] scope_red, scope_green, scope_blue;


	// 4ch Oscilloscope mem & vga display
	logic [7:0] tiny_red, tiny_green, tiny_blue;
	logic tiny;
	tiny_scope #( 
		.V_HEIGHT( 192 ), // 96 or 192 options
		.V_START ( 80  ),
		.H_START	( 529 ),
		.H_END 	( 784 ),
		.N       ( 2   ), // 60 Hz frames per col pel
		.GD_COLOR( 24'h32006a /* smpte_deep_violet */ ), 
		.BG_COLOR( 24'h00214c /* smpte_oxford_blue */ ) //24'h1d1d1d /* smpte_eerie_black */ )	
	 ) _tiny_scope(
		.clk(   hdmi_clk ),
		.reset( reset ),
		// video sync 
		.blank( blank ), 
		.hsync( hsync ),
		.vsync( vsync ),
		// scroll halt input
		.halt ( mscroll_halt ),
		// capture inputs
		.ad_a0( mad_a0 ),
		.ad_a1( mad_a1 ),
		.ad_b0( mad_b0 ),
		.ad_b1( mad_b1 ),
		.ad_strobe( mad_strobe ),
		.ad_clk( clk ),
		// video output
		.red(   tiny_red ),
		.green( tiny_green ),
		.blue(  tiny_blue )
	);
	assign tiny = |{ tiny_red, tiny_green, tiny_blue };

	// 8ch digital logic analyser mem & vga display
	logic [7:0] tinyb_red, tinyb_green, tinyb_blue;
	logic tinyb;
	tiny_binary_scope #( 
		.V_HEIGHT( 64 ), // 96 or 192 options
		.V_START ( 400  ),
		.H_START	( 529 ),
		.H_END 	( 784 ),
		.N       ( 2   ), // 60 Hz frames per col pel
		.GD_COLOR( 24'h32006a /* smpte_deep_violet */ ), 
		.BG_COLOR( 24'h00214c /* smpte_oxford_blue */ ) //24'h1d1d1d /* smpte_eerie_black */ )	
	 ) _tinyb_scope(
		.clk(   hdmi_clk ),
		.reset( reset ),
		// video sync 
		.blank( blank ), 
		.hsync( hsync ),
		.vsync( vsync ),
		// scroll halt input
		.halt ( mscroll_halt ),
		// capture inputs
		.ad_data( lcc_mon ),

		.ad_strobe( mad_strobe ),
		.ad_clk( clk ),
		// video output
		.red(   tinyb_red ),
		.green( tinyb_green ),
		.blue(  tinyb_blue )
	);
	assign tinyb = |{ tinyb_red, tinyb_green, tinyb_blue };	
		
	// 12 bit resistance number is 6.5. so 
	// plotting as 8.4 with { 2`b00, in[10:1] } will give Ohms. A decimal point woudl be nice
	logic [4:0] res_str;
	//string_overlay #(.LEN(8)) _res0 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d100),.y('d5), .out( res_str[0] ), .str("Res $ 0x") );
	//hex_overlay    #(.LEN(2)) _res1 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char)    , .x('d108),.y('d5), .out( res_str[1] ), .in( { 2'b00, igniter_res[10:5] ^ 6'h3F } ) );
	//string_overlay #(.LEN(1)) _res2 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d110),.y('d5), .out( res_str[2] ), .str(".") );
	//hex_overlay    #(.LEN(1)) _res3 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char)    , .x('d111),.y('d5), .out( res_str[3] ), .in( { igniter_res[4:1] ^ 4'hF } ) );
	//string_overlay #(.LEN(11))_res4 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d117),.y('d5), .out( res_str[4] ), .str("(3E.E=Open)") );

	
	// Port Names
	logic [3:0] in_str;
   //string_overlay #(.LEN(2)) _in0 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h48),.y('h01), .out( in_str[0]), .str("A0") );
	//string_overlay #(.LEN(2)) _in1 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h48),.y('h03), .out( in_str[1]), .str("A1") );
	//string_overlay #(.LEN(2)) _in2 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h48),.y('h05), .out( in_str[2]), .str("B0") );
	//string_overlay #(.LEN(2)) _in3 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h48),.y('h07), .out( in_str[3]), .str("B1") );
	
	// 12bit hex overlays(4)
	logic [3:0] hex_str;
	//hex_overlay #(.LEN(3)) _hex0 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x('h4B),.y('h01), .out( hex_str[0]), .in( value_1 ) );
	//hex_overlay #(.LEN(3)) _hex1 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x('h4B),.y('h03), .out( hex_str[1]), .in( value_2 ) );
	//hex_overlay #(.LEN(3)) _hex2 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x('h4B),.y('h05), .out( hex_str[2]), .in( value_3 ) );
	//hex_overlay #(.LEN(3)) _hex3 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x('h4B),.y('h07), .out( hex_str[3]), .in( value_4 ) );
					
	// dump binary	values	
	logic [3:0] bin_str;
	//bin_overlay #(.LEN(12)) _bin0 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .bin_char(bin_char), .x('h4B), .y('h01), .out( bin_str[0] ), .in( value_1 ) );
	//bin_overlay #(.LEN(12)) _bin1 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .bin_char(bin_char), .x('h4B), .y('h03), .out( bin_str[1] ), .in( value_2 ) );
	//bin_overlay #(.LEN(12)) _bin2 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .bin_char(bin_char), .x('h4B), .y('h05), .out( bin_str[2] ), .in( value_3 ) );
	//bin_overlay #(.LEN(12)) _bin3 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .bin_char(bin_char), .x('h4B), .y('h07), .out( bin_str[3] ), .in( value_4 ) );

	// Merge overlays
	logic overlay;
	assign overlay = (|bin_str ) |
						  (|hex_str ) |
						  (|pwr_str ) |
						  (|in_str  ) |
						  ( text_ovl && text_color == 0 ) | // normal text
						  ( key_strg) |
						  (|res_str ) |
						  (|id_str  ) ;
	

	// Oscilloscope & vga display
	logic [7:0] wave_scope_red, wave_scope_green, wave_scope_blue;
	vga_wave_display _wave_scope (
		.clk(   hdmi_clk ),
		.reset( reset ),
		// video sync 
		.blank( blank ), 
		.hsync( hsync ),
		.vsync( vsync ),
		// Font data
		.ascii_char( ascii_char ),
		.char_x( char_x ),
		.char_y( char_y ),
		// AXI Sram Read port connection
		.psram_ready	( psram_ready 	 ) ,
		.rdata			( rdata 			 ) , 
		.rvalid			( rvalid		    ) ,
		.araddr			( araddr[24:0]	 ) ,
		.arvalid			( arvalid		 ) , 
		.arready			( arready		 ) ,
		.mem_clk			( clk ),
		// video output
		.red(   wave_scope_red ),
		.green( wave_scope_green ),
		.blue(  wave_scope_blue )	
	);	

	// Overlay Color
	logic [7:0] overlay_red, overlay_green, overlay_blue;
	
	assign { overlay_red, overlay_green, overlay_blue } =
			( overlay ) ? 24'hFFFFFF :
			( text_ovl && text_color == 4'h1 ) ? 24'hf00000 :
			( text_ovl && text_color == 4'h2 ) ? 24'hFFFFFF :
			( text_ovl && text_color == 4'h3 ) ? 24'hff0000 :			
			( text_ovl && text_color == 4'h4 ) ? 24'h00ff00 :
			( text_ovl && text_color == 4'h5 ) ? 24'h0000ff :
			( text_ovl && text_color == 4'h6 ) ? 24'hc0c0c0 :
			( text_ovl && text_color == 4'h7 ) ? 24'h0000c0 :
			( text_ovl && text_color == 4'h8 ) ? 24'h00c0c0 :
			( text_ovl && text_color == 4'h9 ) ? 24'h00c000 : 
			( text_ovl && text_color == 4'hA ) ? 24'hc0c000 : 
			( text_ovl                       ) ? 24'hf0f000 : 
															 24'h000000 ;

	// video encoder
	logic [7:0] hdmi_data;
	logic [7:0] dvi_data;
	video_encoder _encode2
	(
		.clk  ( hdmi_clk  ),
		.clk5 ( hdmi_clk5 ),
		.reset( reset ), //| charge ),  // battery limit during charging
		.blank( blank ),
		.hsync( hsync ),
		.vsync( vsync ),
		// HDMI encoding control
		.video_preamble( video_preamble ),
		.data_preamble ( data_preamble  ),
		.video_guard   ( video_guard    ),
		.data_guard    ( data_guard     ),
		.data_island   ( data_island    ),	
		// YUV mode input
		.yuv_mode		( blipvert ), // use YUV2 mode, cheap USb capture devices provice lossless YUV2 capture mode 
		// RBG Data
		.red	( (blipvert) ? bv_vdata[7:0]  : ((( tiny | tinyb ) ? (tiny_red   | tinyb_red  ) : wave_scope_red   ) | overlay_red   ) ),
		.green( (blipvert) ? bv_vdata[15:8] : ((( tiny | tinyb ) ? (tiny_green | tinyb_green) : wave_scope_green ) | overlay_green ) ),
		.blue	( (blipvert) ? 8'h00          : ((( tiny | tinyb ) ? (tiny_blue  | tinyb_blue ) : wave_scope_blue  ) | overlay_blue  ) ),
		.hdmi_data( hdmi_data ),
		.dvi_data( dvi_data )
	);
		
	// HDMI or DVI output.
	hdmi_out _hdmi2_out ( // LDVS DDR outputs
		.outclock( hdmi_clk5 ),
		.din( hdmi_data ), // hdmi_data or dvi_data 
		.pad_out( {hdmi2_d2, hdmi2_d1, hdmi2_d0, hdmi2_ck} ), 
		.pad_out_b( )  // true differential, _b not req
	);
	

endmodule

// 1024 moving window debounce 80/20
// tick is about 1 per 480 cycles	
module debounce(
	input clk,
	input reset,
	input in,
	output out,	// fixed pulse 15ms after 5ms pressure
	output long // after fire held for > 2/3 sec, until release
	);
	
	logic [25:0] count1; // total 1.3 sec
	logic [22:0] count0;
	logic [2:0] state;
	logic [2:0] meta;
	logic       inm;

	
	always @(posedge clk) { inm, meta } <= { meta, in };
	
	// State Machine	
	localparam S_IDLE 		= 0;
	localparam S_WAIT_PRESS	= 1;
	localparam S_WAIT_PULSE	= 2;
	localparam S_WAIT_LONG	= 3;
	localparam S_LONG			= 4;
	localparam S_WAIT_OFF	= 5;
	localparam S_WAIT_LOFF	= 6;
	
	always @(posedge clk) begin
		if( reset ) begin
			state <= S_IDLE;
		end else begin
			case( state )
				S_IDLE 		 :	state <= ( inm ) ? S_WAIT_PRESS : S_IDLE;
				S_WAIT_PRESS :	state <= (!inm ) ? S_IDLE       : (count1 == ( 5  * 48000 )) ? S_WAIT_PULSE : S_WAIT_PRESS;
				S_WAIT_PULSE :	state <=                          (count1 == ( 25 * 48000 )) ? S_WAIT_LONG  : S_WAIT_PULSE; 
				S_WAIT_LONG	 :	state <= (!inm ) ? S_WAIT_OFF   : (count1 >= 26'h20_00000  ) ? S_LONG       : S_WAIT_LONG;
				S_LONG		 :	state <= (!inm ) ? S_WAIT_LOFF  :  S_LONG;
				S_WAIT_OFF	 :	state <= ( inm ) ? S_WAIT_LONG  : (count0 == ( 100 * 48000)) ? S_IDLE       : S_WAIT_OFF;
				S_WAIT_LOFF	 :	state <= ( inm ) ? S_LONG       : (count0 == ( 100 * 48000)) ? S_IDLE       : S_WAIT_LOFF;
				default: state <= S_IDLE;
			endcase
		end
	end
	
	assign out = (state == S_WAIT_PULSE) ? 1'b1 : 1'b0;
	assign long = (state == S_LONG || state == S_WAIT_LOFF) ? 1'b1 : 1'b0;
	
	// Counters
	always @(posedge clk) begin
		if( reset ) begin
			count0 <= 0;
			count1 <= 0;
		end else begin
			count0 <= ( state == S_WAIT_OFF  || 
			            state == S_WAIT_LOFF ) ? (count0 + 1) : 0; // count when low waiting
			count1 <= ( state == S_IDLE      ) ? 0            : (count1 + 1); 
		end
	end

endmodule
	

module key_scan( 
	input [6:0] keypad_in,
	output [6:0] keypad_out,
	input	clk,
	input reset,
	output [4:0] key
	);
	
	
	logic [11:0] div;
	logic [2:0] col;
	logic [3:0] row;
	logic flag;
	always @(posedge clk) begin
		if( reset ) begin
			key <= 0;
			div <= 0;
			col <= 0;
			row <= 0;
			flag <= 0;
			keypad_out <= 0;
		end else begin
			div <= div + 1;
			// drive 4 rows
			keypad_out[1] <= ( div[11:10] == 0 ) ? 1'b0 : 1'b1;
			keypad_out[6] <= ( div[11:10] == 1 ) ? 1'b0 : 1'b1;
			keypad_out[5] <= ( div[11:10] == 2 ) ? 1'b0 : 1'b1;
			keypad_out[3] <= ( div[11:10] == 3 ) ? 1'b0 : 1'b1;
			// capture columns
				if( div[11:0] == 0 ) begin
					flag <= 0;
					col <= col;
					row <= row;
				end else if( div[11:0] == 12'hfff && flag == 0 ) begin
					col <= 0;
					row <= 0;
				end else if( div[9:0] == 10'h3F0 && { keypad_in[2], keypad_in[0], keypad_in[4]} != 3'b111 ) begin // key pressed
					flag  <= 1;
					col[2] <= !keypad_in[2];
					col[1] <= !keypad_in[0];
					col[0] <= !keypad_in[4];
					row[0] <= !keypad_in[1];
					row[1] <= !keypad_in[6];
					row[2] <= !keypad_in[5];
					row[3] <= !keypad_in[3];
				end else begin
					flag <= flag;
					col <= col;
					row <= row;
				end
			key <= ( col[2:0] == 3'b001 && row[0] ) ? 5'h13 :
					 ( col[2:0] == 3'b001 && row[1] ) ? 5'h16 :
					 ( col[2:0] == 3'b001 && row[2] ) ? 5'h19 :
					 ( col[2:0] == 3'b001 && row[3] ) ? 5'h1B :
					 ( col[2:1] == 3'b01  && row[0] ) ? 5'h12 :
					 ( col[2:1] == 3'b01  && row[1] ) ? 5'h15 :
					 ( col[2:1] == 3'b01  && row[2] ) ? 5'h18 :
					 ( col[2:1] == 3'b01  && row[3] ) ? 5'h10 :
					 ( col[2  ] == 3'b1   && row[0] ) ? 5'h11 :
					 ( col[2  ] == 3'b1   && row[1] ) ? 5'h14 :
					 ( col[2  ] == 3'b1   && row[2] ) ? 5'h17 :
					 ( col[2  ] == 3'b1   && row[3] ) ? 5'h1A : 5'h00;		
		end
	end	
endmodule

// BlipVert - From max headroom
// dump the entire memory as video pixels
// When enabled during active video line pels (!blank)
// writes address, end then burst reads 1kB to video each scanline

module blipvert (
	input clk,
	input reset,
	input enable,
	input [24:0] base, // starting block addr
	// Axi4 read Bus
	output logic [24:0] araddr,
	output logic [7:0]  arlen,
	output logic        arvalid,
	input  logic        arready,
	input  logic [17:0] rdata,
	input  logic        rvalid,
	// Video output data to fifo to hdmi live video
	output [16:0] vdata,
	output        vvalid
	);
	
	// State machine
	logic [1:0] state;
	localparam S_IDLE 	= 0;
	localparam S_ADDR 	= 1;
	localparam S_VALID   = 2;
	localparam S_WAIT		= 3;
	
	always @(posedge clk) begin
		if( reset ) begin
			state <= S_IDLE;
		end else begin
			case( state )
				S_IDLE : state <= ( enable ) ? S_ADDR : S_IDLE;
				S_ADDR : state <= ( enable ) ? S_VALID : S_IDLE;
				S_VALID: state <= ( !enable ) ? S_IDLE :
			                      ( arready && arvalid && addr[9:6] == 4'hF ) ? S_WAIT : S_VALID; 
				S_WAIT : state <= ( enable ) ? S_WAIT : S_IDLE;
			endcase
		end
	end
	assign arvalid = ( state == S_VALID ) ? 1'b1 : 1'b0;

	// Read Address
	logic [24:0] addr;
	logic [24:10] next_addr;
	
	assign next_addr[24:10] = addr[24:10] + 1;

	always @(posedge clk) begin
		if( reset ) begin
			addr <= 0;
		end else begin
			addr[5:0] <= 0;
			addr[9:6] <= ( state == S_ADDR ) ? 4'h0 :
			             ( state == S_VALID && arready && arvalid ) ? addr[9:6] + 4'h1 : addr[9:6];
			addr[24:10] <= ( state == S_ADDR ) ? next_addr[24:10] : addr[24:10];
		end
	end
	assign araddr[24:0] = addr[24:0];
	assign arlen[7:0] = 8'd32; 

	// Output
	always @(posedge clk) begin
		vvalid <= ( state == S_ADDR || ( enable && rvalid )) ? 1'b1 : 1'b0;
		vdata  <= ( state == S_ADDR ) ? { 2'b1, next_addr[24:10] == base[24:10], next_addr[24:10] } : // addr flag, start flag, addr 1k
		                                { 1'b0, rdata[16:9], rdata[7:0] }; // mem data
	end
	
endmodule


// external adc sim block
module adcsim (
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
