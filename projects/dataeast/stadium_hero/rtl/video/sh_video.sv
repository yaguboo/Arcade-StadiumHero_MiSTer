//============================================================================
//  Stadium Hero -- video subsystem
//
//  Timing, three layers, one mixer.  Everything above the chips is here so
//  that sh_top.sv sees a single block with a CPU port and an RGB port.
//
//  Layer order and the reason there is nothing more to it: docs/MAME_NOTES.md
//  section 11 and sh_colmix.sv.
//
//  Flip screen originates in the BAC06's ctrlreg[0] bit 7 and the driver fans
//  it out to the sprite chip and the text tilemap by hand (stadhero.cpp:167-170).
//  On the board the pin does the same.  Fanning it out here, from the one chip
//  that owns it, keeps that structure visible.
//
//  ROM ports leave as three independent request/ack pairs.  sh_top arbitrates
//  them against the 68000 and the sound CPU; the layers do not know or care
//  what memory is behind them.
//============================================================================
`default_nettype none

module sh_video (
    input  wire        clk,
    input  wire        rst,
    input  wire        pxl_cen,

    // --- CPU bus ------------------------------------------------------------
    input  wire [12:1] cpu_addr,
    input  wire [15:0] cpu_dout,
    input  wire        cpu_rnw,
    input  wire [1:0]  cpu_dsn,

    input  wire        char_cs,        // 0x200000-0x2007ff
    input  wire        bac_mode_cs,    // 0x240000-0x24001f
    input  wire        bac_vram_cs,    // 0x260000-0x261fff
    input  wire        pal_cs,         // 0x310000-0x3107ff
    input  wire        obj_cs,         // 0xffc000-0xffc7ff

    output wire [15:0] char_din,
    output wire [15:0] bac_din,
    output wire [15:0] pal_din,
    output wire [15:0] obj_din,

    // --- ROM ports ----------------------------------------------------------
    output wire        char_rom_cs,
    output wire [14:0] char_rom_addr,
    input  wire [31:0] char_rom_data,
    input  wire        char_rom_ok,

    output wire        tile_rom_cs,
    output wire [16:0] tile_rom_addr,
    input  wire [31:0] tile_rom_data,
    input  wire        tile_rom_ok,

    output wire        obj_rom_cs,
    output wire [16:0] obj_rom_addr,
    input  wire [31:0] obj_rom_data,
    input  wire        obj_rom_ok,

    // --- video out ----------------------------------------------------------
    output wire [7:0]  red,
    output wire [7:0]  green,
    output wire [7:0]  blue,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,

    // --- to the rest of the board -------------------------------------------
    output wire [8:0]  hdump,          // 0x30c003 reads hdump[8:1] -- the RNG
    output wire        flip,
    input  wire [2:0]  gfx_en,

    output wire [7:0]  dbg_mode0,
    output wire [7:0]  dbg_mode2,
    output wire [7:0]  dbg_mode3,
    output wire [7:0]  dbg_hscr_lo,
    output wire [7:0]  dbg_vscr_lo,

    // Per frame, on how many lines was each engine still filling its line
    // buffer when the beam started reading it?  Saturating at 255.
    //
    // The offline golden model draws every tile, because it has no clock, so
    // "the writer ran out of time" is the one class of defect it cannot see.
    // These three counters are the instrument for it, and they cost three
    // adders.  The overlay shows them in place of the BAC06 mode registers,
    // which are worth less now that a 200-second run has shown this game never
    // moves them (docs/DRIVER_AUDIT.md section 7).
    output reg  [7:0]  dbg_late_bac,
    output reg  [7:0]  dbg_late_chr,
    output reg  [7:0]  dbg_late_obj
);

wire bac_busy, chr_busy, obj_busy;

wire [8:0] vdump, vrender;
wire       hs_raw, hinit, vload;
wire       vs_raw, hb_raw, vb_raw;   // undelayed, for the engines

sh_vtimer u_timer (
    .clk     ( clk     ),
    .rst     ( rst     ),
    .pxl_cen ( pxl_cen ),
    .hdump   ( hdump   ),
    .vdump   ( vdump   ),
    .vrender ( vrender ),
    .hs      ( hs_raw  ),
    .vs      ( vs_raw  ),
    .hblank  ( hb_raw  ),
    .vblank  ( vb_raw  ),
    .hinit   ( hinit   ),
    .vload   ( vload   )
);

// ------------------------------------------------- output pipeline alignment
//  MEASURED, not guessed: the board's picture is pixel-identical to MAME's and
//  sits exactly THREE pixels to the right of it -- 53760 of 53760 pixels agree
//  at dx = -3 on both boot self-test screens (DEBUG_LOG O3,
//  tools/board_vs_mame_boot.py).
//
//  Three registered stages sit between the line buffers and the pins: the
//  buffer's own read, the mixer's palette lookup, and the output register.
//  The sync and blanking signals come straight off the counters and share none
//  of them, so the scaler opens the active window three pixels before the data
//  arrives.
//
//  Delaying the four output signals by the same three pixel times is the whole
//  fix.  The engines keep the RAW signals -- they are preparing the next line,
//  not displaying this one -- so only what leaves this module moves.
localparam int VOUT_DLY = 3;

reg [VOUT_DLY-1:0] hs_p, vs_p, hb_p, vb_p;
always @(posedge clk) if (pxl_cen) begin
    hs_p <= { hs_p[VOUT_DLY-2:0], hs_raw   };
    vs_p <= { vs_p[VOUT_DLY-2:0], vs_raw   };
    hb_p <= { hb_p[VOUT_DLY-2:0], hb_raw   };
    vb_p <= { vb_p[VOUT_DLY-2:0], vb_raw   };
end

assign hsync  = hs_p[VOUT_DLY-1];
assign vsync  = vs_p[VOUT_DLY-1];
assign hblank = hb_p[VOUT_DLY-1];
assign vblank = vb_p[VOUT_DLY-1];

wire [7:0] tile_pxl, obj_pxl, char_pxl;

// ------------------------------------------------------------------ BAC06
sh_bac06 u_bac06 (
    .clk       ( clk           ),
    .rst       ( rst           ),
    .pxl_cen   ( pxl_cen       ),
    .mode_cs   ( bac_mode_cs   ),
    .vram_cs   ( bac_vram_cs   ),
    .cpu_addr  ( cpu_addr      ),
    .cpu_dout  ( cpu_dout      ),
    .cpu_din   ( bac_din       ),
    .cpu_rnw   ( cpu_rnw       ),
    .cpu_dsn   ( cpu_dsn       ),
    .hdump     ( hdump         ),
    .vrender   ( vrender       ),
    .hs        ( hs_raw        ),
    .hblank    ( hb_raw        ),
    .flip      ( flip          ),
    .rom_cs    ( tile_rom_cs   ),
    .rom_addr  ( tile_rom_addr ),
    .rom_data  ( tile_rom_data ),
    .rom_ok    ( tile_rom_ok   ),
    .pxl       ( tile_pxl      ),
    .dbg_mode0 ( dbg_mode0     ),
    .dbg_mode2 ( dbg_mode2     ),
    .dbg_mode3 ( dbg_mode3     ),
    .dbg_hscr_lo ( dbg_hscr_lo ),
    .dbg_vscr_lo ( dbg_vscr_lo ),
    .dbg_busy    ( bac_busy    )
);

// ------------------------------------------------------------------ MXC06
sh_mxc06 u_mxc06 (
    .clk       ( clk          ),
    .rst       ( rst          ),
    .pxl_cen   ( pxl_cen      ),
    .objram_cs ( obj_cs       ),
    .cpu_addr  ( cpu_addr[10:1] ),
    .cpu_dout  ( cpu_dout     ),
    .cpu_din   ( obj_din      ),
    .cpu_rnw   ( cpu_rnw      ),
    .cpu_dsn   ( cpu_dsn      ),
    .hdump     ( hdump        ),
    .vrender   ( vrender      ),
    .hs        ( hs_raw       ),
    .hblank    ( hb_raw       ),
    .vblank    ( vb_raw       ),
    .flip      ( flip         ),
    .rom_cs    ( obj_rom_cs   ),
    .rom_addr  ( obj_rom_addr ),
    .rom_data  ( obj_rom_data ),
    .rom_ok    ( obj_rom_ok   ),
    .pxl       ( obj_pxl      ),
    .dbg_busy  ( obj_busy     )
);

// -------------------------------------------------------------- text layer
sh_char u_char (
    .clk      ( clk             ),
    .rst      ( rst             ),
    .pxl_cen  ( pxl_cen         ),
    .vram_cs  ( char_cs         ),
    .cpu_addr ( cpu_addr[10:1]  ),
    .cpu_dout ( cpu_dout        ),
    .cpu_din  ( char_din        ),
    .cpu_rnw  ( cpu_rnw         ),
    .cpu_dsn  ( cpu_dsn         ),
    .hdump    ( hdump           ),
    .vrender  ( vrender         ),
    .hs       ( hs_raw          ),
    .hblank   ( hb_raw          ),
    .flip     ( flip            ),
    .rom_cs   ( char_rom_cs     ),
    .rom_addr ( char_rom_addr   ),
    .rom_data ( char_rom_data   ),
    .rom_ok   ( char_rom_ok     ),
    .pxl      ( char_pxl        ),
    .dbg_busy ( chr_busy        )
);

// ------------------------------------------------------------------- mixer
sh_colmix u_colmix (
    .clk      ( clk            ),
    .rst      ( rst            ),
    .pxl_cen  ( pxl_cen        ),
    .pal_cs   ( pal_cs         ),
    .cpu_addr ( cpu_addr[10:1] ),
    .cpu_dout ( cpu_dout       ),
    .cpu_din  ( pal_din        ),
    .cpu_rnw  ( cpu_rnw        ),
    .cpu_dsn  ( cpu_dsn        ),
    .tile_pxl ( tile_pxl       ),
    .obj_pxl  ( obj_pxl        ),
    .char_pxl ( char_pxl       ),
    .hblank   ( hb_raw         ),
    .vblank   ( vb_raw         ),
    .gfx_en   ( gfx_en         ),
    .red      ( red            ),
    .green    ( green          ),
    .blue     ( blue           )
);

// ------------------------------------------------- late-line counters
//  Sampled at hdump 0, the instant the beam starts reading the buffer these
//  engines have been filling since HS.  Still busy means the tail of the line
//  had not been written yet, and whatever the wipe left -- transparent -- is
//  what gets displayed.
//
//  Cleared on the rising edge of vblank, so the number on screen is always the
//  frame just finished.  Saturating: 255 means "at least 255 of the 240 lines",
//  which is every line.
reg [7:0] acc_bac, acc_chr, acc_obj;
reg       vb_d1;
always @(posedge clk) begin
    if (rst) begin
        dbg_late_bac <= 8'd0; acc_bac <= 8'd0;
        dbg_late_chr <= 8'd0; acc_chr <= 8'd0;
        dbg_late_obj <= 8'd0; acc_obj <= 8'd0;
        vb_d1        <= 1'b0;
    end else begin
        vb_d1 <= vb_raw;
        if (vb_raw && !vb_d1) begin
            // Publish the frame just finished and start the next one.  The
            // first version cleared here and displayed the LIVE accumulator,
            // so the overlay showed however much had piled up between the
            // start of vblank and the line the overlay itself was drawn on --
            // about forty lines of BLANKING.  It read 50 and 54 on every
            // single frame, which is what a constant should have given away.
            dbg_late_bac <= acc_bac;  acc_bac <= 8'd0;
            dbg_late_chr <= acc_chr;  acc_chr <= 8'd0;
            dbg_late_obj <= acc_obj;  acc_obj <= 8'd0;
        end else if (pxl_cen && hdump == 9'd0 && !vb_raw) begin
            // Only VISIBLE lines.  During blanking there is no beam to race,
            // so an engine still working there is not late -- it is early.
            if (bac_busy && !(&acc_bac)) acc_bac <= acc_bac + 8'd1;
            if (chr_busy && !(&acc_chr)) acc_chr <= acc_chr + 8'd1;
            if (obj_busy && !(&acc_obj)) acc_obj <= acc_obj + 8'd1;
        end
    end
end

endmodule

`default_nettype wire
