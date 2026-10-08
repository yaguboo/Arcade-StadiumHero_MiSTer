//============================================================================
//  Stadium Hero -- video timing
//
//  384 x 272 at a 6 MHz pixel clock.  256 x 240 visible, starting at line 8.
//
//  These are DEC0 numbers, not guesses.  Two independent sources agree:
//
//    the PCB, measured           HSync 15.6246 kHz   VSync 57.4434 Hz
//    stadhero.cpp:53-54
//
//    this raster                 6e6/384 = 15.6250   /272 = 57.4449
//                                                    0.003% apart
//
//    jtcores cop/hdl/jtcop_bac06.v, the RoboCop vtimer instance:
//      VB_START 247  VB_END 7  VCNT_END 271
//      VS_START 262  HS_START 304  HB_START 255  HB_END 383  HINIT 255
//
//  and MAME's set_visarea(0, 255, 8, 247) is exactly this window.
//  docs/JTCORES_REUSE.md section 3 works the arithmetic through.
//
//  The counters are free-running.  hdump is also the board's RNG source: the
//  68000 reads hdump[8:1] at 0x30c003 (docs/MAME_NOTES.md section 7), so this
//  module must count the true 384 and not a convenient 256.
//============================================================================
`default_nettype none

module sh_vtimer (
    input  wire       clk,
    input  wire       rst,
    input  wire       pxl_cen,        // 6 MHz

    output reg  [8:0] hdump,          // 0 .. 383
    output reg  [8:0] vdump,          // 0 .. 271
    output wire [8:0] vrender,      // line being FETCHED = the next one

    output reg        hs,
    output reg        vs,
    output reg        hblank,         // high during blanking
    output reg        vblank,

    output wire       hinit,          // hdump wrapped, one pxl_cen wide
    output wire       vload           // second-to-last line of vblank
);

localparam [8:0] H_TOTAL  = 9'd383;   // last count
localparam [8:0] HB_START = 9'd256;   // 0..255 visible
localparam [8:0] HS_START = 9'd304;
localparam [8:0] HS_END   = 9'd336;

localparam [8:0] V_TOTAL  = 9'd271;
localparam [8:0] VB_END   = 9'd8;     // first visible line
localparam [8:0] VB_START = 9'd248;   // 8..247 visible
localparam [8:0] VS_START = 9'd262;
localparam [8:0] VS_END   = 9'd266;

wire h_last = (hdump == H_TOTAL);

assign hinit   = pxl_cen & h_last;
// The line the engines prepare is NOT the one on screen.  They start at the
// falling edge of HS -- hdump 336 -- and the buffer they fill is read out
// during hdump 0..255, by which time vdump has already incremented.  So the
// line being fetched is vdump + 1; exporting vdump put every layer's content
// one line low.
assign vrender = (vdump == V_TOTAL) ? 9'd0 : vdump + 9'd1;
// The line before the last one of vblank.  Anything that has to be armed once
// per frame and be ready before line 8 hangs off this.
assign vload   = (vdump == V_TOTAL - 9'd1);

always @(posedge clk) begin
    if (rst) begin
        hdump  <= 9'd0;
        vdump  <= 9'd0;
        hs     <= 1'b0;
        vs     <= 1'b0;
        hblank <= 1'b1;
        vblank <= 1'b1;
    end else if (pxl_cen) begin
        hdump <= h_last ? 9'd0 : hdump + 9'd1;

        if (h_last) begin
            vdump <= (vdump == V_TOTAL) ? 9'd0 : vdump + 9'd1;
        end

        // Blanking and sync are decoded from the count that is about to be
        // presented, so the flags line up with the pixel they describe rather
        // than trailing it by one.
        begin : decode
            reg [8:0] hnext, vnext;
            hnext = h_last ? 9'd0 : hdump + 9'd1;
            vnext = h_last ? ((vdump == V_TOTAL) ? 9'd0 : vdump + 9'd1) : vdump;

            hblank <= (hnext >= HB_START);
            hs     <= (hnext >= HS_START) && (hnext < HS_END);
            vblank <= (vnext < VB_END) || (vnext >= VB_START);
            vs     <= (vnext >= VS_START) && (vnext < VS_END);
        end
    end
end

endmodule

`default_nettype wire
