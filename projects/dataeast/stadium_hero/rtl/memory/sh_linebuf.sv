//============================================================================
//  Stadium Hero -- line buffer
//
//  Single buffer, writer racing ahead of the beam.  The draw engine fills it
//  from HS onwards at the core clock while the beam reads it at pxl_cen; the
//  writer is ten times faster so it stays in front.  The buffer is wiped in a
//  burst during horizontal blanking, before the next line's writer starts.
//
//  ---- this module was 48% of the design, which is why it looks like this ---
//  The first version read at rd_addr and wrote a zero to the address read one
//  cycle earlier, both on "port B", one cycle apart so they would not collide.
//  That is a natural way to write read-and-clear and it does not infer.  A port
//  performs ONE access per cycle; asking one for a read and, on other cycles, a
//  write at a DIFFERENT address is not a port, it is a register file.  Quartus
//  built it out of flip-flops without a word.  Measured on the first Analysis &
//  Synthesis run:
//
//      sh_linebuf:u_buf    6116 ALUTs   4114 registers    x 3 instances
//                         -------------------------------
//                         18,345 ALUTs of the design's 37,938
//
//  Half the core -- with the whole MiSTer framework, fx68k and three sound
//  chips in the other half -- was three line buffers made of logic.  Power
//  Spikes lost 7,673 ALM to the same class of mistake, and root CLAUDE.md
//  section 7 puts "did the memory infer as memory" at step 0 of every resource
//  investigation because of it.  This is that step paying out.
//
//  Note what the earlier comment in this file got wrong: it said the two
//  accesses being on different CYCLES made it a legal dual-port RAM.  Cycles
//  were never the problem.  A port cannot have two addresses.
//
//  ---- the shape that does infer -------------------------------------------
//      port A   write   the draw engine, OR the blanking wipe
//      port B   read    the beam, at pxl_cen
//
//  One write address and one read address: simple dual port, which always maps
//  to M10K.  The two writers never contend because they are disjoint in time.
//  The wipe starts on the rising edge of hblank (hdump 256) and takes 512
//  clocks; the draw engine starts at HS (hdump 336), 80 pixel times or 800
//  clocks later.  The line just displayed was consumed during hdump 0..255, so
//  there is nothing in it left to keep.
//
//  Wiping all 512 entries rather than the visible 256 is deliberate: sub-tile
//  scroll starts the first tile at a negative write address, which wraps to the
//  top of the buffer.
//============================================================================
`default_nettype none

module sh_linebuf #(
    parameter DW = 8,
    parameter AW = 9
) (
    input  wire            clk,
    input  wire            pxl_cen,
    input  wire            hblank,

    // draw engine
    input  wire [AW-1:0]   wr_addr,
    input  wire [DW-1:0]   wr_data,
    input  wire            we,

    // beam
    input  wire [AW-1:0]   rd_addr,
    output wire [DW-1:0]   rd_data
);

(* ramstyle = "no_rw_check" *) reg [DW-1:0] mem [0:(1<<AW)-1];

// Power-up contents, FOR SIMULATION ONLY.  Quartus already zeroes M10K on
// Cyclone V; this is so the simulator starts where the hardware does instead of
// at X.  translate_off because Quartus refuses to unroll a constant loop past
// 5000 iterations, and Analysis & Synthesis failed on exactly that once.
// synthesis translate_off
integer ram_i;
initial for (ram_i = 0; ram_i < (1<<AW); ram_i = ram_i + 1)
    mem[ram_i] = {DW{1'b0}};
// synthesis translate_on

// ------------------------------------------------------------- blanking wipe
reg [AW-1:0] clr_cnt  = {AW{1'b0}};
reg          clearing = 1'b0;
reg          hb_d     = 1'b0;

always @(posedge clk) begin
    hb_d <= hblank;
    if (hblank && !hb_d) begin
        clearing <= 1'b1;
        clr_cnt  <= {AW{1'b0}};
    end else if (clearing) begin
        clr_cnt <= clr_cnt + 1'b1;
        if (&clr_cnt) clearing <= 1'b0;
    end
end

// ------------------------------------------------------------- the two ports
wire [AW-1:0] a_addr = clearing ? clr_cnt    : wr_addr;
wire [DW-1:0] a_data = clearing ? {DW{1'b0}} : wr_data;
wire          a_we   = clearing | we;

reg [DW-1:0] q;

always @(posedge clk) begin
    if (a_we)    mem[a_addr] <= a_data;      // port A -- write
    if (pxl_cen) q <= mem[rd_addr];          // port B -- read
end

assign rd_data = q;

endmodule

`default_nettype wire
