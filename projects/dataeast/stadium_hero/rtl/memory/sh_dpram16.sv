//============================================================================
//  Stadium Hero -- 16-bit dual-port RAM with byte enables
//
//  Port A is the CPU: read/write, byte-selectable.
//  Port B is a video scan engine: read only.
//
//  Written as two independent byte-wide arrays rather than one 16-bit array
//  with a masked write.  Root CLAUDE.md section 7 puts "did the memory infer as
//  memory" at step 0 of every resource investigation, ahead of the RTL, because
//  Power Spikes lost 7,673 ALM to a line buffer that could not be a block RAM
//  and Quartus said nothing (L24).  Byte-enabled writes on a single array are
//  the classic way to fall off M10K inference; split arrays always fit.
//
//  Same clock for both ports -- this core is single-domain by design, see
//  rtl/sh_top.sv.  Read data appears one cycle after the address.
//============================================================================
`default_nettype none

module sh_dpram16 #(
    parameter AW = 10
) (
    input  wire            clk,

    // Port A -- CPU, read/write
    input  wire [AW-1:0]   addr_a,
    input  wire [15:0]     data_a,
    input  wire [1:0]      we_a,       // [1] = upper byte, [0] = lower
    output wire [15:0]     q_a,

    // Port B -- video scan, read only
    input  wire [AW-1:0]   addr_b,
    output wire [15:0]     q_b
);

(* ramstyle = "no_rw_check" *) reg [7:0] mem_hi [0:(1<<AW)-1];
(* ramstyle = "no_rw_check" *) reg [7:0] mem_lo [0:(1<<AW)-1];

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
    begin mem_hi[ram_i] = 8'd0; mem_lo[ram_i] = 8'd0; end
// synthesis translate_on



reg [7:0] qa_hi, qa_lo, qb_hi, qb_lo;

always @(posedge clk) begin
    if (we_a[1]) mem_hi[addr_a] <= data_a[15:8];
    qa_hi <= mem_hi[addr_a];
end

always @(posedge clk) begin
    if (we_a[0]) mem_lo[addr_a] <= data_a[7:0];
    qa_lo <= mem_lo[addr_a];
end

always @(posedge clk) begin
    qb_hi <= mem_hi[addr_b];
    qb_lo <= mem_lo[addr_b];
end

assign q_a = { qa_hi, qa_lo };
assign q_b = { qb_hi, qb_lo };

endmodule

`default_nettype wire
