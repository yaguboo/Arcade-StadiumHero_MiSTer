//============================================================================
//  Stadium Hero -- Data East L7B0073 "MXC06" sprite generator
//
//  Behavioural reference:
//    references/upstream/mame/src/mame/dataeast/decmxc06.cpp
//    references/upstream/jtcores/cores/cop/hdl/jtcop_obj_draw.v   (GPL-3.0)
//
//  ---- what differs from RoboCop's -----------------------------------------
//  Two things, both checked rather than assumed:
//
//  1.  NO SPRITE DMA.  jtcop_obj_buffer.v implements RoboCop's software-
//      triggered copy -- obj_copy, mixpsel, a second copy RAM, a v14 scan
//      counter.  Stadium Hero has no DMA trigger anywhere in its memory map
//      (stadhero.cpp:226-241) and screen_update reads m_spriteram directly.
//      So the table here is one dual-port RAM: CPU on one port, scan engine on
//      the other.  No copy, no trigger, nothing to arm.
//
//  2.  MULTI-WIDTH SPRITES CONSUME ONE TABLE SLOT PER COLUMN.
//      decmxc06.cpp:100-153 -- the `offs += 4` is INSIDE the width loop, and
//      each pass re-reads `spriteram[offs + 1]` for that column's code while
//      keeping the PARENT's position, palette, flips and height.  Column x is
//      drawn at `sx + mult*x`, mult = -16 (or +16 when flipped), so columns
//      run leftwards from the parent's X.  The comment at :105 records this
//      was found via Birdie Try.
//
//      jtcop instead reuses one base code and walks rom_addr[17:6] by
//      (1 << msize) per column, never reading the extra slots.  It also
//      advances the table by only 4 for an enabled sprite that misses the
//      line, which would misparse the following entry.  This module follows
//      MAME on both counts: 4 words for a disabled sprite, 4*w for an enabled
//      one whether or not it touches this line.
//
//  ---- table format (decmxc06.cpp:17-36) ----------------------------------
//    word0  [15]     enable -- sprite skipped entirely when clear
//           [14]     Y flip      [13]     X flip
//           [12:11]  height 1<<n [10:9]   width 1<<n   (1, 2, 4, 8 tiles)
//           [8:0]    Y
//    word1  [11:0]   tile code
//    word2  [15:12]  colour  [11] flash  [8:0] X
//    word3           unused
//
//  Position is `240 - x` / `240 - y` after a signed 9-bit wrap
//  (decmxc06.cpp:78-83).  Multi-height walks the code DOWNWARDS unless Y flip
//  is set, with the base masked by the height first: `code &= ~(h-1)` at :107.
//  The bit that picks the direction is the PARENT's Y flip (:104, :110).
//
//  Working from the bottom edge makes that fall out for free: `veff` is the
//  raster line minus the sprite's bottom, so it counts up from -16h at the top
//  to -1 at the bottom, and its bits 6:4 index the sub-tile in exactly MAME's
//  order without a subtract per row.
//
//  ---- pipeline -----------------------------------------------------------
//  Parse one line ahead of the beam, draw into a line buffer that clears as the
//  beam reads it.  Later entries overwrite earlier ones, which is what MAME's
//  front-to-back transpen loop produces.
//
//  Per-line tile budget: the chip runs at 12 MHz over a 384-pixel line, so at
//  most 48 16-pixel tiles fit.  jtcop derives the same number the same way.
//============================================================================
`default_nettype none

module sh_mxc06 (
    input  wire        clk,
    input  wire        rst,
    input  wire        pxl_cen,        // 6 MHz

    // --- CPU side: sprite RAM, 0xffc000-0xffc7ff (mirrored at +0x800) -------
    input  wire        objram_cs,
    input  wire [10:1] cpu_addr,
    input  wire [15:0] cpu_dout,
    output wire [15:0] cpu_din,
    input  wire        cpu_rnw,
    input  wire [1:0]  cpu_dsn,

    // --- timing -------------------------------------------------------------
    input  wire [8:0]  hdump,
    input  wire [8:0]  vrender,
    input  wire        hs,
    input  wire        hblank,
    input  wire        vblank,
    input  wire        flip,

    // --- sprite ROM ---------------------------------------------------------
    output reg         rom_cs,
    output reg  [16:0] rom_addr,       // 32-bit words
    input  wire [31:0] rom_data,
    input  wire        rom_ok,

    output wire [7:0]  pxl,            // { colour, pixel }, pixel 0 = clear

    // High while this engine is still filling the line buffer.  Sampled at
    // hdump 0 it says the beam began reading before the writer had finished,
    // which is the one failure mode the offline golden model cannot see --
    // it has no clock.
    output wire        dbg_busy
);

localparam [5:0] TILES_PER_LINE = 6'd48;

// ------------------------------------------------------------- sprite RAM
//  1024 words.  No copy buffer -- header note 1.
reg  [9:0]  tbl_addr;
wire [15:0] tbl_dout;
wire [1:0]  cpu_we = ~cpu_dsn & {2{objram_cs & ~cpu_rnw}};

sh_dpram16 #(.AW(10)) u_objram (
    .clk    ( clk       ),
    .addr_a ( cpu_addr  ),
    .data_a ( cpu_dout  ),
    .we_a   ( cpu_we    ),
    .q_a    ( cpu_din   ),
    .addr_b ( tbl_addr  ),
    .q_b    ( tbl_dout  )
);

// ------------------------------------------------------------- line buffer
reg        buf_we;         // a pixel is being shifted out this cycle
wire       buf_wr;         // ...and it is opaque, so the buffer takes it
reg  [8:0] buf_waddr;
wire [7:0] buf_wdata;
// 255, not 256 -- see the note in sh_bac06.sv.
wire [8:0] buf_waflip = flip ? (9'd255 - buf_waddr) : buf_waddr;

sh_linebuf #(.DW(8), .AW(9)) u_buf (
    .clk     ( clk        ),
    .pxl_cen ( pxl_cen    ),
    .hblank  ( hblank     ),
    .wr_addr ( buf_waflip ),
    .wr_data ( buf_wdata  ),
    .we      ( buf_wr     ),
    .rd_addr ( hdump      ),
    .rd_data ( pxl        )
);

// ------------------------------------------------------------ parse engine
localparam [1:0] S_W0 = 2'd0,   // attributes
                 S_W1 = 2'd1,   // code, column 0
                 S_W2 = 2'd2,   // position + palette
                 S_WN = 2'd3;   // code, columns 1..w-1

reg [1:0]  st;
reg        hs_d, vb_d, frame;
reg        parse_busy, rd_pend, draw_req, draw_busy;
reg [5:0]  line_cnt;

reg [2:0]  ncol;        // width - 1, in tiles
reg [2:0]  col;         // column being drawn
reg [1:0]  msize;       // height, log2
reg        hflip, vflip;
reg [8:0]  veff;        // raster line relative to the sprite's bottom edge
reg [8:0]  xpos;        // parent X, column 0
reg [3:0]  pal;
reg [11:0] code;

// ---- the line number is latched, ONCE, at HS ------------------------------
//  vrender changes when hdump wraps 383 -> 0, which is in the MIDDLE of this
//  engine's line: the scan starts at HS (hdump 336) and runs on past the wrap.
//  Reading the live counter meant every tile parsed or drawn after the wrap
//  used the NEXT line's number.
//
//  On hardware that showed as text with its bottom rows missing and whole
//  lines of it blinking in and out -- how much of the line landed on the wrong
//  side of the wrap depends on how long the arbiter made this engine wait, so
//  it varied frame to frame.  sh_bac06 never had the bug because it latches
//  its own veff at HS; this is the same discipline.
reg [8:0] vline;

// The raster line in sprite coordinates.
wire [8:0] vrf = flip ? (9'd255 - vline) : vline;

// Bottom edge.  decmxc06.cpp works from `240 - y`; this is that plus the
// 16-pixel tile height, which is where the arithmetic is cheapest.
wire [8:0] ypos   = 9'd256 - tbl_dout[8:0];
wire [1:0] h_log2 = tbl_dout[12:11];
wire [1:0] w_log2 = tbl_dout[10:9];
wire       enable = tbl_dout[15];
wire       flash  = tbl_dout[11];       // word2

reg [8:0] top;
always @* begin
    case (h_log2)
        2'd0: top = ypos - 9'h10;
        2'd1: top = ypos - 9'h20;
        2'd2: top = ypos - 9'h40;
        2'd3: top = ypos - 9'h80;
    endcase
end

// Off the top (top wrapped negative), past the bottom, or entirely off-screen.
wire inzone = !((vrf < top && !top[8]) || vrf >= ypos ||
                 ypos < 9'd8 || (top[8] && ypos[8]));

// Sub-tile select.  veff counts -16h .. -1 across the sprite, so its bits pick
// the row's tile in MAME's order and mask the base code at the same time.
reg [11:0] code_eff;
always @* begin
    code_eff = tbl_dout[11:0];
    case (msize)
        2'd1: code_eff = { tbl_dout[11:1],  vflip     ^ veff[4]   };
        2'd2: code_eff = { tbl_dout[11:2], {2{vflip}} ^ veff[5:4] };
        2'd3: code_eff = { tbl_dout[11:3], {3{vflip}} ^ veff[6:4] };
        default: ;
    endcase
end

// One slot per column, and enabled sprites consume all of them even when the
// line misses -- otherwise the next entry is parsed from the wrong offset.
wire [9:0] skip_all = 10'd4 << w_log2;

always @(posedge clk) begin
    if (rst) begin
        hs_d       <= 1'b0;
        vb_d       <= 1'b0;
        frame      <= 1'b0;
        parse_busy <= 1'b0;
        rd_pend    <= 1'b0;
        draw_req   <= 1'b0;
        tbl_addr   <= 10'd0;
        st         <= S_W0;
        vline      <= 9'd0;
        ncol       <= 3'd0;
        col        <= 3'd0;
        msize      <= 2'd0;
    end else begin
        hs_d     <= hs;
        vb_d     <= vblank;
        draw_req <= 1'b0;

        // Flash alternates per frame (decmxc06.cpp:118).
        if (vblank && !vb_d) frame <= ~frame;

        if (hs_d && !hs) begin
            vline      <= vrender;      // the line this buffer will be shown on
            tbl_addr   <= 10'd0;
            st         <= S_W0;
            parse_busy <= 1'b1;
            rd_pend    <= 1'b0;
        end else if (parse_busy && !draw_busy) begin
            if (!rd_pend) begin
                rd_pend <= 1'b1;            // address out; data next cycle
            end else begin
                rd_pend <= 1'b0;
                case (st)
                    S_W0: begin
                        { vflip, hflip } <= tbl_dout[14:13];
                        ncol  <= (3'd1 << w_log2) - 3'd1;
                        msize <= h_log2;
                        veff  <= vrf - ypos;
                        if (!enable) begin
                            tbl_addr <= tbl_addr + 10'd4;
                        end else if (!inzone) begin
                            tbl_addr <= tbl_addr + skip_all;
                        end else begin
                            tbl_addr <= tbl_addr + 10'd1;
                            st       <= S_W1;
                        end
                        if (&tbl_addr[9:2]) parse_busy <= 1'b0;
                    end

                    S_W1: begin
                        code     <= code_eff;
                        tbl_addr <= tbl_addr + 10'd1;
                        st       <= S_W2;
                    end

                    S_W2: begin
                        xpos     <= 9'd240 - tbl_dout[8:0];
                        pal      <= tbl_dout[15:12];
                        col      <= 3'd0;
                        draw_req <= ~flash | frame;   // flash: alternate frames
                        if (ncol == 3'd0) begin
                            tbl_addr <= tbl_addr + 10'd2;   // -> next word0
                            st       <= S_W0;
                            if (&tbl_addr[9:2]) parse_busy <= 1'b0;
                        end else begin
                            tbl_addr <= tbl_addr + 10'd3;   // -> next slot's word1
                            st       <= S_WN;
                        end
                    end

                    S_WN: begin
                        code     <= code_eff;
                        col      <= col + 3'd1;
                        draw_req <= ~flash | frame;
                        if (col + 3'd1 == ncol) begin
                            tbl_addr <= tbl_addr + 10'd3;   // -> next word0
                            st       <= S_W0;
                            if (&tbl_addr[9:2]) parse_busy <= 1'b0;
                        end else begin
                            tbl_addr <= tbl_addr + 10'd4;   // -> next column's word1
                        end
                    end
                endcase
                if (line_cnt >= TILES_PER_LINE) parse_busy <= 1'b0;
            end
        end
    end
end

// -------------------------------------------------------------- draw engine
reg [31:0] shifter;
reg [3:0]  draw_cnt;
reg        half;
reg        rom_armed;

wire [3:0] draw_pxl = hflip
        ? { shifter[24], shifter[16], shifter[8], shifter[0] }
        : { shifter[31], shifter[23], shifter[15], shifter[7] };

assign buf_wdata = { pal, draw_pxl };

// Pen 0 is transparent and must NOT reach the buffer.  MAME draws sprites with
// transpen (drawgfx.cpp), which skips pen 0 entirely; a line buffer that takes
// every pixel instead lets a later sprite's empty area ERASE an earlier one.
//
// The batter had no head because of this.  His helmet is slots 4 and 5
// (colour 10) and his face is slots 13, 14 and 15 (colour 8); the face tiles
// are parsed later, so their transparent right-hand columns wiped the helmet
// out, and the face tiles that survived were themselves clipped by the body
// tiles behind them.  714 of the frame's 2542 sprite pixels -- 28 % -- were
// being erased this way.
//
// Measured offline before the fix, against a MAME dump of the same frame:
//   tools/render_spr.py with transpen semantics   2538/2542 vs MAME  99.8 %
//   the same model writing pen 0 as well          1828 pixels survive, no head
assign buf_wr = buf_we & |draw_pxl;

// Column c sits at sx + mult*c, mult = -16 normally and +16 flipped
// (decmxc06.cpp:85-93).
wire [8:0] col_x = flip ? (xpos + {col, 4'd0}) : (xpos - {col, 4'd0});

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
        line_cnt  <= 6'd0;
    end else begin
        if (!parse_busy) line_cnt <= 6'd0;

        if (draw_req) begin
            draw_busy <= 1'b1;
            half      <= 1'b0;
            draw_cnt  <= 4'd0;
            rom_cs    <= 1'b1;
            rom_armed <= 1'b1;
            buf_waddr <= col_x;
            // Bytes 16-31 are the LEFT half of the tile, so the first fetch is
            // the one with the half bit set -- unless X flip, which starts from
            // the right.  The row within the tile flips as a unit.
            rom_addr  <= { code, ~hflip, veff[3:0] ^ {4{vflip}} };
        end

        if (!buf_we && rom_cs && rom_armed && rom_ok && draw_cnt == 4'd0) begin
            shifter   <= rom_data;
            rom_cs    <= 1'b0;
            rom_armed <= 1'b0;
            buf_we    <= 1'b1;
            draw_cnt  <= 4'd7;
        end

        if (buf_we) begin
            shifter   <= hflip ? (shifter >> 1) : (shifter << 1);
            draw_cnt  <= draw_cnt - 4'd1;
            buf_waddr <= buf_waddr + 9'd1;
            if (draw_cnt == 4'd0) begin
                buf_we <= 1'b0;
                if (half) begin
                    line_cnt  <= line_cnt + 6'd1;
                    draw_busy <= 1'b0;
                    rom_cs    <= 1'b0;
                end else begin
                    rom_addr[4] <= hflip;   // the other half
                    rom_cs      <= 1'b1;
                    rom_armed   <= 1'b1;
                    half        <= 1'b1;
                    draw_cnt    <= 4'd0;
                end
            end
        end
    end
end

assign dbg_busy = parse_busy | draw_busy;

endmodule

`default_nettype wire
