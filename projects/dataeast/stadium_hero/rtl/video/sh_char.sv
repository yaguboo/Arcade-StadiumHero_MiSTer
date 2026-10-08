//============================================================================
//  Stadium Hero -- 8x8 text layer
//
//  This one has no custom chip behind it.  0x200000-0x2007ff is plain SRAM and
//  stadhero.cpp:203 builds a 32x32 tilemap of 8x8 tiles straight out of it:
//
//      create(..., TILEMAP_SCAN_ROWS, 8, 8, 32, 32)
//      set_transparent_pen(0)
//
//  and get_pf1_tile_info (:189) splits each word as
//
//      [15:12] colour     [11:0] code
//
//  No scroll, no geometry register, no bank -- 256x256 fixed, drawn last and
//  on top of everything (:174).  RoboCop's equivalent is a third BAC06 in 8x8
//  mode, which is why there is nothing in jtcores to reuse here.
//
//  Chars are 3bpp, so pixel bit 3 is always zero; the ROM packing zero-fills
//  plane 3 (rtl/sh_rommap.svh) and the layer presents a uniform 8 bits.
//  Palette base is 0 (docs/MAME_NOTES.md section 6).
//============================================================================
`default_nettype none

module sh_char (
    input  wire        clk,
    input  wire        rst,
    input  wire        pxl_cen,

    // --- CPU side: 0x200000-0x2007ff ---------------------------------------
    input  wire        vram_cs,
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
    input  wire        flip,

    // --- char ROM -----------------------------------------------------------
    output reg         rom_cs,
    output reg  [14:0] rom_addr,       // 32-bit words: 4096 chars x 8 rows
    input  wire [31:0] rom_data,
    input  wire        rom_ok,

    output wire [7:0]  pxl,            // { colour, pixel }, pixel 0 = clear

    // High while this engine is still filling the line buffer.  Sampled at
    // hdump 0 it says the beam began reading before the writer had finished,
    // which is the one failure mode the offline golden model cannot see --
    // it has no clock.
    output wire        dbg_busy
);

// ------------------------------------------------------------------- VRAM
wire [1:0]  cpu_we = ~cpu_dsn & {2{vram_cs & ~cpu_rnw}};
reg  [9:0]  scan_addr;
wire [15:0] scan_data;

sh_dpram16 #(.AW(10)) u_vram (
    .clk    ( clk       ),
    .addr_a ( cpu_addr  ),
    .data_a ( cpu_dout  ),
    .we_a   ( cpu_we    ),
    .q_a    ( cpu_din   ),
    .addr_b ( scan_addr ),
    .q_b    ( scan_data )
);

// ------------------------------------------------------------- line buffer
reg        buf_we;
reg  [8:0] buf_waddr;
wire [7:0] buf_wdata;
// 255, not 256 -- see the note in sh_bac06.sv.  This layer already had the
// vertical mirror right (255 - vrender below); only the horizontal one was
// off, so flipped text sat one pixel to the right.
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
//  Fixed 32 tiles per line, no scroll, so the whole thing is a counter.
//  TILEMAP_SCAN_ROWS: index = row*32 + col.
reg        hs_d, scan_busy, rd_pend, draw_req, draw_busy;
reg  [4:0] col;
reg  [3:0] tile_pal;
reg [11:0] tile_id;

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
wire [8:0] veff = flip ? (9'd255 - vline) : vline;

always @* scan_addr = { veff[7:3], col };

always @(posedge clk) begin
    if (rst) begin
        hs_d      <= 1'b0;
        scan_busy <= 1'b0;
        rd_pend   <= 1'b0;
        draw_req  <= 1'b0;
        col       <= 5'd0;
        vline     <= 9'd0;
    end else begin
        hs_d     <= hs;
        draw_req <= 1'b0;

        if (hs_d && !hs) begin
            vline     <= vrender;       // the line this buffer will be shown on
            col       <= 5'd0;
            scan_busy <= 1'b1;
            rd_pend   <= 1'b0;
        end else if (scan_busy && !draw_busy) begin
            if (!rd_pend) begin
                rd_pend <= 1'b1;
            end else begin
                rd_pend  <= 1'b0;
                tile_id  <= scan_data[11:0];
                tile_pal <= scan_data[15:12];
                draw_req <= 1'b1;
                col      <= col + 5'd1;
                if (col == 5'd31) scan_busy <= 1'b0;
            end
        end
    end
end

// -------------------------------------------------------------- draw engine
reg [31:0] shifter;
reg [3:0]  draw_cnt;
reg        rom_armed;

// Plane 0 is the pixel LSB and bit 7 of each plane byte is the leftmost pixel
// (rtl/sh_rommap.svh).  This layer has no per-tile flip; screen flip is handled
// by the line-buffer address, so the shifter direction is fixed.
wire [3:0] draw_pxl = { shifter[31], shifter[23], shifter[15], shifter[7] };

assign buf_wdata = { tile_pal, draw_pxl };

always @(posedge clk) begin
    if (rst) begin
        draw_busy <= 1'b0;
        draw_cnt  <= 4'd0;
        buf_waddr <= 9'd0;
        buf_we    <= 1'b0;
        rom_cs    <= 1'b0;
        rom_addr  <= 15'd0;
        rom_armed <= 1'b0;
    end else begin
        if (draw_req) begin
            draw_busy <= 1'b1;
            draw_cnt  <= 4'd0;
            rom_cs    <= 1'b1;
            rom_armed <= 1'b1;
            rom_addr  <= { tile_id, veff[2:0] };
            buf_waddr <= { 1'b0, col - 5'd1, 3'd0 };
        end

        if (!buf_we && rom_cs && rom_armed && rom_ok && draw_cnt == 4'd0) begin
            shifter   <= rom_data;
            rom_cs    <= 1'b0;
            rom_armed <= 1'b0;
            buf_we    <= 1'b1;
            draw_cnt  <= 4'd7;
        end

        if (buf_we) begin
            shifter   <= shifter << 1;
            draw_cnt  <= draw_cnt - 4'd1;
            buf_waddr <= buf_waddr + 9'd1;
            if (draw_cnt == 4'd0) begin
                buf_we    <= 1'b0;
                draw_busy <= 1'b0;
                rom_cs    <= 1'b0;
            end
        end
    end
end

assign dbg_busy = scan_busy | draw_busy;

endmodule

`default_nettype wire
