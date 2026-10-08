//============================================================================
//  Stadium Hero -- 8-bit single-port RAM
//
//  The sound CPU's 5814 (2Kx8).  Read data appears one cycle after the
//  address, which is what jt65c02 expects from its bus.
//============================================================================
`default_nettype none

module sh_ram8 #(
    parameter AW = 11
) (
    input  wire          clk,
    input  wire [AW-1:0] addr,
    input  wire [7:0]    data,
    input  wire          we,
    output reg  [7:0]    q
);

(* ramstyle = "no_rw_check" *) reg [7:0] mem [0:(1<<AW)-1];

// Power-up contents, FOR SIMULATION ONLY.
//
// Quartus already initialises M10K to zero on Cyclone V, so the hardware starts
// at zero either way.  What this fixes is the SIMULATOR, which starts at X --
// and a difference between sim and hardware is what hides bugs.  tb_bac06 found
// it as "unwritten VRAM does not read as zero", which on hardware it does.
//
// translate_off is not decoration.  Quartus unrolls a constant loop and refuses
// past 5000 iterations; at AW=13 this is 8192 and Analysis & Synthesis failed
// with "loop must terminate within 5000 iterations" -- after burning 28 minutes
// of CPU trying.  There is nothing for synthesis to do here anyway.
// synthesis translate_off
integer ram_i;
initial for (ram_i = 0; ram_i < (1<<AW); ram_i = ram_i + 1)
    mem[ram_i] = 8'd0;
// synthesis translate_on



always @(posedge clk) begin
    if (we) mem[addr] <= data;
    q <= mem[addr];
end

endmodule

`default_nettype wire
