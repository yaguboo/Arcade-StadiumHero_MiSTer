//============================================================================
//  Stadium Hero -- Data East L7B0072 "BAC06" tilemap generator
//
//  Behavioural reference:
//    references/upstream/mame/src/mame/dataeast/decbac06.cpp
//    references/upstream/jtcores/cores/cop/hdl/jtcop_bac06.v   (GPL-3.0)
//
//  Our own RTL, written to this factory's conventions.  jtcop's version is
//  jtframe-coupled and pulling jtframe in for one module would be an
//  architecture change made for one board's convenience -- docs/JTCORES_REUSE.md
//  section 5 has the reasoning, LICENSE_USAGE_REPORT.md the classification.
//
//  ---- what THIS board wires up -------------------------------------------
//  Stadium Hero has ONE BAC06 running 16x16 tiles as the opaque background.
//  RoboCop has three.  Two consequences, both checked against the driver
//  rather than assumed:
//
//  1.  ctrlreg[2] bit 0 banks the VRAM by 0x1000 words, and Stadium Hero is
//      the ONLY board known to use it.  decbac06.cpp:446:
//
//          // I don't know WHY Stadium Hero uses this as a bank but the RAM
//          // test expects it..
//
//      jtcop does not implement it because RoboCop never sets it.  Without it
//      the power-on RAM test fails and the game never starts.
//
//  2.  The row- and column-scroll tables have NO CPU PATH on this board.
//      dec0.cpp:479-493 maps colscroll_w/rowscroll_w for all three of
//      RoboCop's chips; stadhero.cpp:226-241 maps neither, only vram at
//      0x260000.  So those tables are permanently zero here.  The enable bits
//      are still decoded -- a game that sets them gets the documented
//      behaviour, which with an all-zero table is no offset -- but there is no
//      table RAM to build.  A later DEC0 board reusing this module has to add
//      the port; that is why the enables are wired to a named constant below
//      instead of being quietly deleted.
//
//  The whole 8192-word VRAM is therefore tilemap, which matches the two 2063
//  (8Kx8) SRAMs on the DE-0304-3 layout (stadhero.cpp:65-67).
//
//  ---- pipeline -----------------------------------------------------------
//  One line ahead of the beam, as the chip is:
//
//    HS falling  -> latch scroll, reset the scan
//    scan        -> read a tile word from VRAM
//    draw        -> two 32-bit ROM reads per 16-pixel tile (LEFT half first)
//                   into a line buffer the beam reads and erases
//
//  Pixels leave as { colour[3:0], pixel[3:0] }.  Tiles are 3bpp here, so pixel
//  bit 3 is always zero -- the ROM packing zero-fills plane 3
//  (rtl/sh_rommap.svh) and downstream sees a uniform 8-bit layer.
//============================================================================
`default_nettype none

module sh_bac06 (
    input  wire        clk,
    input  wire        rst,
    input  wire        pxl_cen,        // 6 MHz

    // --- CPU side -----------------------------------------------------------
    input  wire        mode_cs,        // 0x240000-0x24001f  (ctrl + scroll regs)
    input  wire        vram_cs,        // 0x260000-0x261fff
    input  wire [12:1] cpu_addr,
    input  wire [15:0] cpu_dout,
    output wire [15:0] cpu_din,
    input  wire        cpu_rnw,
    input  wire [1:0]  cpu_dsn,        // active low, [1] = upper byte

    // --- timing -------------------------------------------------------------
    input  wire [8:0]  hdump,
    input  wire [8:0]  vrender,
    input  wire        hs,
    input  wire        hblank,

    output wire        flip,           // ctrlreg[0] bit 7, fanned out by sh_video

    // --- tile ROM -----------------------------------------------------------
    output reg         rom_cs,
    output reg  [16:0] rom_addr,       // 32-bit words
    input  wire [31:0] rom_data,
    input  wire        rom_ok,

    output wire [7:0]  pxl,            // { colour, pixel }

    // Observability.  Which mode the chip is in decides which of six mappers
    // runs, and a wrong picture cannot be diagnosed without knowing that --
    // the first attempt at those mappers was guesswork for exactly this reason.
    output wire [7:0]  dbg_mode0,
    output wire [7:0]  dbg_mode2,
    output wire [7:0]  dbg_mode3,
    output wire [7:0]  dbg_hscr_lo,
    output wire [7:0]  dbg_vscr_lo,

    // High while this engine is still filling the line buffer.  Sampled at
    // hdump 0 it says the beam began reading before the writer had finished,
    // which is the one failure mode the offline golden model cannot see --
    // it has no clock.
    output wire        dbg_busy
);

// The scroll tables have no CPU write path on this board (header note 2), so
// every lookup would return zero.  Named, not inlined, so the reason survives.
localparam [9:0] SCROLL_TABLE_ABSENT = 10'd0;

// ---------------------------------------------------------------- registers
reg [7:0]  mode [0:3];
reg [15:0] hscr, vscr;


// decbac06.cpp:26-44
wire       tile8_en  = mode[0][0];    // 1 = 8x8, 0 = 16x16
wire       rowmajor  = mode[0][1];
wire       vram_bank = mode[2][0];    // Stadium Hero only -- see header
wire [1:0] geometry  = mode[3][1:0];  // 0 = 4x1, 1 = 2x2, 2 = 1x4

assign flip = mode[0][7];

assign dbg_mode0   = mode[0];
assign dbg_mode2   = mode[2];
assign dbg_mode3   = mode[3];
assign dbg_hscr_lo = hscr[7:0];
assign dbg_vscr_lo = vscr[7:0];

localparam [1:0] GEOM_4X1 = 2'd0,     //  8x8: 128x32   16x16: 64x16
                 GEOM_2X2 = 2'd1,     //       64x64           32x32
                 GEOM_1X4 = 2'd2;     //       32x128          16x64

// 3 is documented as invalid and behaves as 1 (decbac06.cpp:346-347)
wire [1:0] geom = (geometry == 2'd3) ? GEOM_2X2 : geometry;

// Column-major mode flips tiles on X and inverts the scroll direction
// (decbac06.cpp:196, :207, :268).  There is no per-tile flip bit on this chip.
wire flip_x = ~rowmajor;

function automatic [15:0] combine(input [15:0] old);
    combine = { cpu_dsn[1] ? old[15:8] : cpu_dout[15:8],
                cpu_dsn[0] ? old[ 7:0] : cpu_dout[ 7:0] };
endfunction

// The register file is byte-wide on the chip but the 68000 writes words.
// 0x240000-7 are the mode registers and 0x240010-17 the scroll registers --
// one address bit apart, which is how the real decode separates them.
always @(posedge clk) begin
    if (rst) begin
        mode[0]   <= 8'd0;  mode[1]   <= 8'd0;
        mode[2]   <= 8'd0;  mode[3]   <= 8'd0;
        hscr      <= 16'd0; vscr      <= 16'd0;

    end else if (mode_cs && !cpu_rnw) begin
        if (!cpu_addr[4]) begin
            if (!cpu_dsn[0]) mode[cpu_addr[2:1]] <= cpu_dout[7:0];
        end else begin
            case (cpu_addr[2:1])
                2'd0: hscr <= combine(hscr);
                2'd1: vscr <= combine(vscr);
                // scrollreg 2 and 3 are the column- and row-scroll SHIFT
                // counts.  This board has no scroll TABLES
                // (SCROLL_TABLE_ABSENT below), so nothing can consume them:
                // storing them would be two registers Quartus rightly reports
                // as assigned and never read.  The write is accepted and
                // discarded, which is what a chip with no table memory does.
                2'd2, 2'd3: ;
            endcase
        end
    end
end

// The chip drives only the low byte back; the bus pulls the rest high.  MAME
// returns mode[0] for every register offset and jtcop_bac06.v does the same.
// Nothing on this board reads them, so matching the odd upstream behaviour is
// cheaper than inventing a different one.
assign cpu_din = vram_cs ? cpu_vram_q : { 8'hff, mode[0] };

// -------------------------------------------------------------------- VRAM
//  8192 words.  The CPU sees 4096 of them at a time through the bank bit.
wire [12:0] cpu_vram_addr = { vram_bank, cpu_addr[12:1] };
wire [1:0]  cpu_vram_we   = ~cpu_dsn & {2{vram_cs & ~cpu_rnw}};
wire [15:0] cpu_vram_q;

reg  [12:0] scan_addr;
wire [15:0] scan_data;

sh_dpram16 #(.AW(13)) u_vram (
    .clk    ( clk           ),
    .addr_a ( cpu_vram_addr ),
    .data_a ( cpu_dout      ),
    .we_a   ( cpu_vram_we   ),
    .q_a    ( cpu_vram_q    ),
    .addr_b ( scan_addr     ),
    .q_b    ( scan_data     )
);

// ------------------------------------------------------- scan address maths
//
//  TRANSCRIBED FROM MAME, decbac06.cpp:138-190, one mapper at a time.  The
//  first version of this block was derived from jtcop instead and was wrong in
//  a way that only hardware showed: with sprites and text disabled, the
//  background came back as bands of unrelated tiles while the sprite and text
//  layers were pixel-correct.
//
//  Two things it got wrong, and the second explains the first:
//
//  1.  For GEOM_2X2 16x16 it used MAME's COMMENTED-OUT arrangement -- the one
//      labelled "Needs testing on real hardware, not used by any game".
//  2.  It put a row-major / column-major branch on all six mappers.  Only ONE
//      has one: shape0 at 16x16.  The other five have a single formula, and
//      the alternatives beside them in the source are commented out.
//
//  So the ctrlreg[0] bit 1 branch was being taken in shapes that do not have
//  one, and it selected the arrangement no game uses.
//
//  MAME's col/row are TILE indices, so they are computed once here rather than
//  slicing an x/8 counter differently at each use -- which is how the off-by-a
//  -factor-of-two crept into the testbench as well.
//
//      8x8   shape0   (col&0x1f) + ((row&0x1f)<<5) + ((col&0x60)<<5)
//            shape1   (col&0x1f) + ((row&0x1f)<<5) + ((row&0x20)<<5)
//                                                  + ((col&0x20)<<6)
//            shape2   (col&0x1f) + ((row&0x7f)<<5)
//      16x16 shape0   row major:  (col&0xf) + ((row&0xf)<<4) + ((col&0x1f0)<<4)
//                     col major:  (row&0xf) + ((col_mask-col)<<4)
//            shape1   (col&0xf) + ((row&0x1f)<<4) + ((col&0xf0)<<5)
//            shape2   (col&0xf) + ((row&0x3f)<<4) + ((col&0x70)<<6)
//
//  Widths: shape0 at 16x16 is 64<<wide = 256 columns for this board's
//  set_gfx_region_wide(1,1,2), so hn has to reach 4096 pixels.  It was ten bits
//  and truncated at 1024.
reg  [12:0] map_addr;
reg  [9:0]  veff;         // vertical position after scroll
reg  [11:0] hn;           // horizontal position, walked tile by tile

// Tile indices, in MAME's terms.
wire [8:0] tcol = tile8_en ? hn[11:3] : { 1'b0, hn[11:4] };
wire [6:0] trow = tile8_en ? veff[9:3] : { 1'b0, veff[9:4] };

// Column-major shape0 counts columns backwards from the map's last one.
// num_cols is 64 << wide = 256 here, so col_mask is 255.
localparam [7:0] SHAPE0_COL_MASK = 8'd255;

always @* begin
    map_addr = 13'd0;
    if (tile8_en) begin
        case (geom)
            GEOM_4X1: map_addr = { 1'b0, tcol[6:5], trow[4:0], tcol[4:0] };
            GEOM_2X2: map_addr = { 1'b0, tcol[5], trow[5], trow[4:0], tcol[4:0] };
            default:  map_addr = { 1'b0, trow[6:0], tcol[4:0] };
        endcase
    end else begin
        case (geom)
            // The ONLY mapper with a row/column-major branch.
            GEOM_4X1: map_addr = rowmajor
                    ? { tcol[8:4], trow[3:0], tcol[3:0] }
                    : { 1'b0, (SHAPE0_COL_MASK - tcol[7:0]), trow[3:0] };
            GEOM_2X2: map_addr = { tcol[7:4], trow[4:0], tcol[3:0] };
            default:  map_addr = { tcol[6:4], trow[5:0], tcol[3:0] };
        endcase
    end
end

// The scan reads the same array the CPU does, and through the same bank bit --
// the chip has one set of address pins.
// map_addr is 13 bits but a bank is 4096 words, so the top bit is the bank's.
always @* scan_addr = { vram_bank, map_addr[11:0] };

// ------------------------------------------------------------- line buffer
reg        buf_we;
reg  [8:0] buf_waddr;
wire [7:0] buf_wdata;
// Screen flip mirrors the line buffer's WRITE address, so the last visible
// column must map to the first: 255 - a, not 256 - a.  Drawing in unflipped
// coordinates and mirroring on the way in is also why the per-tile and
// per-sprite flip bits are NOT additionally inverted here the way MAME
// inverts them (decmxc06.cpp:85-93) -- mirroring the whole line already does
// that, and doing both would cancel out.
//
// This was 9'h100 until 2026-09-03 and the whole flipped picture sat one
// pixel down and to the right of MAME's.  Nothing caught it because nothing
// had ever run the core flipped: tools/render_frame.py now does, driving the
// DIP word on the bus (tools/sh_frame_dump.lua).  61440/61440 with 255,
// 42345/61440 with 256 and a clean peak at dx=-1, dy=-1.
wire [8:0] buf_waflip = flip ? (9'd255 - buf_waddr) : buf_waddr;

sh_linebuf #(.DW(8), .AW(9)) u_buf (
    .clk     ( clk        ),
    .pxl_cen ( pxl_cen    ),
    .hblank  ( hblank     ),
    .wr_addr ( buf_waflip ),
    .wr_data ( buf_wdata  ),
    .we      ( buf_we     ),
    .rd_addr ( hdump      ),
    .rd_data ( pxl        )
);

// ------------------------------------------------------------- scan engine
//  Runs on clk between HS pulses, not on pxl_cen.  The chip has the whole line
//  time to prepare the next one and so does this, with room to spare.
reg       hs_d, scan_busy, draw_req, draw_busy, rd_pend, first_tile;
// draw_req is registered, so the draw engine sees it one cycle after the scan
// sets it -- by which time first_tile has already been cleared.  Carry the
// flag ALONGSIDE the request instead of reading the live one.
reg       draw_first;
reg [5:0] tilecnt;
reg [11:0] tile_id;
reg [3:0]  tile_pal;

// decbac06.cpp:311-315.  Column-major inverts the horizontal scroll direction.
wire [11:0] hscr_eff = rowmajor ? hscr[11:0] : (12'd0 - hscr[11:0] - 12'd256);
// 255, matching the horizontal mirror above and MAME's tilemap flip over a
// 256-line map.  256 put the background one line low.
wire [9:0] veff0 = (flip ? (10'd255 - {1'b0, vrender}) : {1'b0, vrender}) + vscr[9:0];

always @(posedge clk) begin
    if (rst) begin
        hs_d       <= 1'b0;
        scan_busy  <= 1'b0;
        draw_req   <= 1'b0;
        rd_pend    <= 1'b0;
        tilecnt    <= 6'd0;
        first_tile <= 1'b0;
        draw_first <= 1'b0;
        hn         <= 12'd0;
        veff       <= 10'd0;
    end else begin
        hs_d     <= hs;
        draw_req <= 1'b0;

        if (hs_d && !hs) begin
            // Line over; set up the next one.  The scroll tables are absent on
            // this board, so both offsets are the constant above.
            hn         <= hscr_eff + { 2'd0, SCROLL_TABLE_ABSENT };
            veff       <= veff0          + SCROLL_TABLE_ABSENT;
            tilecnt    <= 6'd0;
            scan_busy  <= 1'b1;
            first_tile <= 1'b1;
            rd_pend    <= 1'b0;
        end else if (scan_busy && !draw_busy) begin
            if (!rd_pend) begin
                rd_pend <= 1'b1;         // address presented; data next cycle
            end else begin
                rd_pend    <= 1'b0;
                tile_id    <= scan_data[11:0];
                tile_pal   <= scan_data[15:12];
                draw_req   <= 1'b1;
                draw_first <= first_tile;
                hn         <= hn + (tile8_en ? 12'd8 : 12'd16);
                tilecnt    <= tilecnt + 6'd1;
                first_tile <= 1'b0;
                // A full 256-pixel line, plus the partial tile at each end.
                if (buf_waddr[8] && tilecnt > 6'd1) scan_busy <= 1'b0;
            end
        end
    end
end

// -------------------------------------------------------------- draw engine
reg [31:0] shifter;
reg [3:0]  draw_cnt;
reg        half;          // second 8 pixels of a 16-pixel tile
reg        rom_armed;

// After packing, plane0 is the pixel LSB and bit 7 of each plane byte is the
// leftmost pixel (rtl/sh_rommap.svh).  Flip reverses which end we consume.
wire [3:0] draw_pxl = flip_x
        ? { shifter[24], shifter[16], shifter[8], shifter[0] }
        : { shifter[31], shifter[23], shifter[15], shifter[7] };

assign buf_wdata = { tile_pal, draw_pxl };

always @(posedge clk) begin
    if (rst) begin
        draw_busy <= 1'b0;
        draw_cnt  <= 4'd0;
        buf_waddr <= 9'd0;
        buf_we    <= 1'b0;
        rom_cs    <= 1'b0;
        rom_addr  <= 17'd0;
        half      <= 1'b0;
        rom_armed <= 1'b0;
    end else begin
        if (draw_req) begin
            draw_busy <= 1'b1;
            half      <= 1'b0;
            draw_cnt  <= 4'd0;
            rom_cs    <= 1'b1;
            rom_armed <= 1'b1;

            // 16x16: bytes 16-31 are the LEFT half, so the first fetch sets the
            // half bit (docs/MAME_NOTES.md section 6).
            //  8x8 : 4096 chars x 8 rows.
            rom_addr <= tile8_en ? { 2'd0, tile_id, veff[2:0] }
                                 : { tile_id, 1'b1, veff[3:0] };

            // Sub-tile scroll: the first tile starts partway in, so the write
            // address starts negative and the leading pixels land outside the
            // visible window.
            //
            // draw_first, not first_tile.  Reading the live flag here was a real
            // bug that tb_bac06 caught: the scan clears first_tile in the same
            // cycle it raises draw_req, so by the time the draw engine ran it was
            // always 0, buf_waddr was never reset at the start of a line, and it
            // carried on from the previous line's end -- with bit 8 set, which
            // then stopped the scan two tiles in.  One tile drawn per line.
            if (draw_first)
                buf_waddr <= tile8_en ? (9'd0 - { 6'd0, hn[2:0] })
                                      : (9'd0 - { 5'd0, hn[3:0] });
        end

        if (!buf_we && rom_cs && rom_armed && rom_ok && draw_cnt == 4'd0) begin
            shifter   <= rom_data;
            rom_cs    <= 1'b0;
            rom_armed <= 1'b0;
            buf_we    <= 1'b1;
            draw_cnt  <= 4'd7;
        end

        if (buf_we) begin
            shifter   <= flip_x ? (shifter >> 1) : (shifter << 1);
            draw_cnt  <= draw_cnt - 4'd1;
            buf_waddr <= buf_waddr + 9'd1;
            if (draw_cnt == 4'd0) begin
                buf_we <= 1'b0;
                if (tile8_en || half) begin
                    draw_busy <= 1'b0;
                    rom_cs    <= 1'b0;
                end else begin
                    rom_addr[4] <= 1'b0;   // right half
                    rom_cs      <= 1'b1;
                    rom_armed   <= 1'b1;
                    half        <= 1'b1;
                    draw_cnt    <= 4'd0;
                end
            end
        end
    end
end

assign dbg_busy = scan_busy | draw_busy;

endmodule

`default_nettype wire
