//============================================================================
//  Stadium Hero -- screenshot-readable debug overlay
//
//  Eight 8-bit values as eight rows of eight blocks, 8x4 pixels each, MSB on
//  the left, white for a one and dark blue for a zero.  Readable straight off a
//  screenshot with no decoder script.
//
//  It answers the two questions that cannot be answered from here any other
//  way.
//
//  ---- 1. which mode is the BAC06 in -------------------------------------
//  Six tilemap mappers, and which one runs is decided by ctrlreg[0] bit 0 and
//  ctrlreg[3] bits 1:0.  The first attempt at those mappers was guesswork
//  because that state was not observable, and it cost a build.  Rows 0-4.
//
//    row 0  peak M6295   post-gain, over ~one frame
//    row 1  peak YM3812
//    row 2  peak YM2203 FM
//    row 3  peak YM2203 SSG
//    row 4  channel-2 starts the chip made
//
//  Rows 0-3 ARE THE MIX BALANCE.  Post-gain and on one scale, so they compare
//  directly, and MAME's routing (stadhero.cpp:403-413) says what they should
//  look like: SSG 0.95, FM 0.40, YM3812 0.80, M6295 0.80.
//
//  "Is the M6295 audible against the music" was the last open question and it
//  was called an ear-only one.  It is not.  The mixer is a pure function of
//  four inputs and four constants; the balance can be measured, and if the
//  M6295's peak is a fraction of the others' then it is buried and by how much.
//
//  Rows 1:2 against rows 3:4 is the whole diagnosis.  Both ratios near 1:1 and
//  the OKI path is fine; only channel 2 lossy and the fault is per-channel;
//  both lossy and it is the path.
//
//  Row 1 used to count any write with bit 7 clear and bit 6 set.  That is the
//  channel-2 mask bit of a START -- but a STOP puts its mask in din[6:3], so
//  stops were counted too, and it never checked for the preceding phrase
//  latch.  It read 255 against the chip's 7 and that ratio was an artefact.
//
//  Rows 0-2 used to be the BAC06 mode registers.  They were worth a row each
//  while the mappers were guesswork; a 200-second run has since shown this
//  game never moves them off 02/00/02 (docs/DRIVER_AUDIT.md section 7), so
//  they were three bytes of confirmed constant.  The late counters answer the
//  question that is actually open -- and it is the one class of defect the
//  offline golden model cannot see, because it has no clock.
//
//  ---- 2. is the sound CPU running --------------------------------------
//  There is no way to listen to the board over ssh, so "check the sound" from
//  here means measuring that the 65C02 executes and that the chips are written
//  -- a real rung below "it sounds right", and worth saying so (root 6.5).
//
//    row 5  65C02 bus cycles /1024   MOVING = it is executing
//    row 6  YM3812 interrupts /16    this is the sound CPU's tempo
//    row 7  YM2203+YM3812+M6295 writes /16
//
//  A row that never changes is the finding.  Row 5 frozen means the 65C02 is
//  not running at all; row 5 moving with row 7 frozen means it runs but never
//  reaches a chip.
//
//  ---- placement ----------------------------------------------------------
//  vdump here is the raster line, and the visible window starts at line 8 of
//  272 (docs/MAME_NOTES.md section 5).  The first version of this counted from
//  the START of vblank, so the whole box sat inside the blanking interval and
//  was invisible -- a debug overlay that cannot be seen.
//
//  This lives in targets/ and not rtl/ because it is an instrument, not the
//  board (root CLAUDE.md section 4).
//============================================================================
`default_nettype none

module sh_dbg (
    input  wire        clk,
    input  wire        pxl_cen,
    input  wire        enable,

    input  wire [8:0]  hdump,
    input  wire [8:0]  vdump,

    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out,

    // --- what is being measured ---------------------------------------------
    input  wire [7:0]  mode0,
    input  wire [7:0]  mode2,
    input  wire [7:0]  mode3,
    input  wire [7:0]  hscr_lo,
    input  wire [7:0]  vscr_lo,

    // When `hist_en` is set every row comes from `hist` instead, eight bytes
    // of one histogram.  That is the shape a distribution wants: eight rows
    // side by side, read as bar lengths rather than as numbers.
    input  wire        hist_en,
    input  wire [63:0] hist,

    input  wire        snd_cpu_acc,     // 65C02 read or write strobe
    input  wire        opn_wr,
    input  wire        opl_wr,
    input  wire        oki_wr,
    input  wire        opl_irq          // active high
);

// ---------------------------------------------------------------- counters
reg [17:0] cpu_cnt;
reg [11:0] irq_cnt, wr_cnt;
reg        opl_irq_d;

always @(posedge clk) begin
    if (snd_cpu_acc)             cpu_cnt <= cpu_cnt + 18'd1;
    if (opn_wr | opl_wr | oki_wr) wr_cnt <= wr_cnt + 12'd1;
    opl_irq_d <= opl_irq;
    if (opl_irq && !opl_irq_d)   irq_cnt <= irq_cnt + 12'd1;
end

wire [7:0] row [0:7];
assign row[0] = hist_en ? hist[ 7: 0] : mode0;
assign row[1] = hist_en ? hist[15: 8] : mode3;
assign row[2] = hist_en ? hist[23:16] : mode2;
assign row[3] = hist_en ? hist[31:24] : hscr_lo;
assign row[4] = hist_en ? hist[39:32] : vscr_lo;
assign row[5] = hist_en ? hist[47:40] : cpu_cnt[17:10];
assign row[6] = hist_en ? hist[55:48] : irq_cnt[11:4];
assign row[7] = hist_en ? hist[63:56] : wr_cnt[11:4];

// ------------------------------------------------------------------ paint
//  8 rows x 4 lines = 32 lines tall, 8 blocks x 8 px = 64 px wide.
localparam [8:0] X0 = 9'd0;
localparam [8:0] Y0 = 9'd16;   // well inside the visible window

wire in_box = enable && (hdump >= X0) && (hdump < X0 + 9'd64)
                     && (vdump >= Y0) && (vdump < Y0 + 9'd32);

// Both are offsets INTO the box, not raw counters.  Slicing vdump directly
// only works while Y0 is zero, and Y0 is not zero -- the box has to clear the
// 8 lines of vertical blanking at the top of the raster.
wire [8:0] box_x = hdump - X0;
wire [8:0] box_y = vdump - Y0;
wire [2:0] bit_x = box_x[5:3];          // which of the eight blocks
wire [2:0] row_y = box_y[4:2];          // which of the eight rows

// MSB on the left, which is how a byte is written down.
wire bit_on = row[row_y][3'd7 - bit_x];

always @(posedge clk) if (pxl_cen) begin
    if (in_box) rgb_out <= bit_on ? 24'hff_ff_ff : 24'h00_00_60;
    else        rgb_out <= rgb_in;
end

endmodule

`default_nettype wire
