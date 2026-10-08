//============================================================================
//  Stadium Hero -- board top
//
//  This is the arcade board and nothing else.  No hps_io, no ioctl, no APF,
//  no MRA: those live in targets/, per root CLAUDE.md section 4.  What crosses
//  this boundary is a neutral memory port (mem_*), neutral inputs, and
//  video/audio out.
//
//  ---- clocking ------------------------------------------------------------
//  clk = 60.000 MHz, one domain.  See rtl/sh_cen.sv for why 60 and not 48, and
//  for the exact divisor of every board clock.
//
//  ---- what is implemented -------------------------------------------------
//      68000, full address decode, all board RAM       yes
//      video timing, BAC06 tilemap, palette            yes
//      MXC06 sprites                                   yes
//      8x8 text layer                                  yes
//      65C02 + YM2203 + YM3812 + M6295                 yes
//      ef19.3d priority PROM                           not implemented, and
//        deliberately -- the layer order is fixed, so there is nothing for it
//        to select.  docs/MAME_NOTES.md section 10.
//
//  ---- ROM traffic ---------------------------------------------------------
//  Five readers share one memory port: the 68000's program ROM, the sound
//  CPU's ROM, the ADPCM samples, and the three graphics fetchers.  sh_romarb
//  arbitrates.  Priority is by deadline, not by importance: the graphics
//  fetchers have a hard per-line budget and the CPUs can wait a cycle, so the
//  video ports are served first.
//============================================================================
`default_nettype none

module sh_top (
    input  wire        clk,            // 60.000 MHz
    input  wire        rst,
    input  wire        mem_rst,        // memory transport runs during download
    input  wire        pause,

    // --- neutral memory port -------------------------------------------------
    output wire [24:0] mem_addr,
    output wire [15:0] mem_din,
    input  wire [15:0] mem_dout,
    output wire        mem_req,
    output wire        mem_we,
    output wire [1:0]  mem_ds,
    input  wire        mem_ack,

    // --- download (the target drives this while loading) ----------------------
    input  wire        dl_active,
    input  wire [24:0] dl_addr,
    input  wire [15:0] dl_data,
    input  wire        dl_req,
    output wire        dl_ack,

    // --- inputs --------------------------------------------------------------
    input  wire [15:0] inputs,         // 0x30c000, both players, active low
    input  wire [6:0]  coin,           // 0x30c002 bits 6:0, active low
    input  wire [15:0] dsw,
    input  wire [1:0]  audio_sel,
    input  wire        oki_full,
    input  wire        oki_test,            // 0x30c004, active low
    input  wire [1:0]  rng_mode,            // 0x30c003 derivation, sh_main.sv
    input  wire        vbl_mame,            // VBLANK length at 0x30c002, sh_main.sv

    // --- video ----------------------------------------------------------------
    output wire [7:0]  red,
    output wire [7:0]  green,
    output wire [7:0]  blue,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,
    output wire        ce_pix,

    // --- audio ----------------------------------------------------------------
    output wire signed [15:0] snd_l,
    output wire signed [15:0] snd_r,

    // --- observability --------------------------------------------------------
    input  wire [2:0]  gfx_en,         // layer enables, all ones in normal use
    output wire [23:1] dbg_addr,
    output wire [31:0] dbg_d7,
    output wire        dbg_halted_n,

    // Sound liveness.  See targets/mister/sh_dbg.sv for why these exist.
    output wire [7:0]  dbg_snd_latch,
    output wire        dbg_snd_cpu_acc,
    output wire        dbg_opn_wr,
    output wire        dbg_opl_wr,
    output wire        dbg_oki_wr,
    output wire        dbg_opl_irq,
    output wire [7:0]  dbg_oki_seen,
    output wire [7:0]  dbg_cpu_ch2,
    output wire [7:0]  dbg_cpu_all,
    output wire [7:0]  dbg_pcm_peak,
    output wire [7:0]  dbg_oki_chip2,
    output wire [7:0]  dbg_oki_chall,
    output wire [7:0]  dbg_peak_pcm,
    output wire [7:0]  dbg_peak_opl,
    output wire [7:0]  dbg_peak_fm,
    output wire [7:0]  dbg_peak_ssg,
    output wire [7:0]  dbg_pcm_cnt,
    output wire        dbg_pcm_fetch,
    output wire [8:0]  dbg_hdump,

    output wire [7:0]  dbg_mode0,
    output wire [7:0]  dbg_mode2,
    output wire [7:0]  dbg_mode3,
    output wire [7:0]  dbg_hscr_lo,
    output wire [7:0]  dbg_vscr_lo,
    output wire [63:0] dbg_hist,
    output wire [7:0]  dbg_looprate,
    output wire [63:0] dbg_speed,
    output wire [63:0] dbg_niblo,
    output wire [63:0] dbg_nibhi,
    output wire [7:0]  dbg_late_bac,
    output wire [7:0]  dbg_late_chr,
    output wire [7:0]  dbg_late_obj
);

// -------------------------------------------------------------- clock enables
wire cen10, cen12, cen6, cen3, cen1p5, cen_oki;

sh_cen u_cen (
    .clk     ( clk     ),
    .rst     ( rst     ),
    .cen10   ( cen10   ),
    .cen12   ( cen12   ),
    .cen6    ( cen6    ),
    .cen3    ( cen3    ),
    .cen1p5  ( cen1p5  ),
    .cen_oki ( cen_oki )
);

assign ce_pix = cen6;

// The CPUs are held in reset and stalled while ROM is loading; the video keeps
// running so the target sees a stable sync during the download.
wire cpu_rst = rst | dl_active;
wire ce_en   = ~pause & ~dl_active;

// ------------------------------------------------------------------ CPU side
wire [23:1] cpu_addr;
wire [15:0] cpu_dout;
wire        cpu_rnw;
wire [1:0]  cpu_dsn;

wire        char_cs, bac_mode_cs, bac_vram_cs, pal_cs, obj_cs;
wire [15:0] char_din, bac_din, pal_din, obj_din;

wire        main_rom_cs;
wire [16:1] main_rom_addr;
wire [15:0] main_rom_data;
wire        main_rom_ok;

// The 68000's 128 KB of program ROM, on chip.  In SDRAM it sat behind three
// video fetchers that hold the bus for most of every line, and since the
// game's random number IS the raster counter, a CPU that can only execute at
// certain phases reads a random number that is not random -- measured, both
// sides, DEBUG_LOG O7.  On the PCB this ROM is on the CPU board and waits for
// nobody.
sh_progrom u_progrom (
    .clk       ( clk           ),
    .dl_active ( dl_active     ),
    .dl_addr   ( dl_addr       ),
    .dl_data   ( dl_data       ),
    .dl_req    ( dl_req        ),
    .cs        ( main_rom_cs   ),
    .addr      ( main_rom_addr ),
    .data      ( main_rom_data ),
    .ok        ( main_rom_ok   )
);

wire [7:0]  snd_latch;
wire        snd_req;

wire [8:0]  hdump;
wire        flip;

sh_main u_main (
    .clk         ( clk           ),
    .rst         ( rst           ),
    .cpu_rst     ( cpu_rst       ),
    .ce_en       ( ce_en         ),
    .rom_cs      ( main_rom_cs   ),
    .rom_addr    ( main_rom_addr ),
    .rom_data    ( main_rom_data ),
    .rom_ok      ( main_rom_ok   ),
    .char_cs     ( char_cs       ),
    .bac_mode_cs ( bac_mode_cs   ),
    .bac_vram_cs ( bac_vram_cs   ),
    .pal_cs      ( pal_cs        ),
    .obj_cs      ( obj_cs        ),
    .char_din    ( char_din      ),
    .bac_din     ( bac_din       ),
    .pal_din     ( pal_din       ),
    .obj_din     ( obj_din       ),
    .vblank      ( vblank        ),
    .hdump       ( hdump         ),
    .rng_mode    ( rng_mode      ),
    .vbl_mame    ( vbl_mame      ),
    .inputs      ( inputs        ),
    .coin        ( coin          ),
    .dsw         ( dsw           ),
    .snd_latch   ( snd_latch     ),
    .snd_req     ( snd_req       ),
    .cpu_addr    ( cpu_addr      ),
    .cpu_dout    ( cpu_dout      ),
    .cpu_rnw     ( cpu_rnw       ),
    .cpu_dsn     ( cpu_dsn       ),
    .dbg_hist0   ( dbg_hist[ 7: 0] ),
    .dbg_hist1   ( dbg_hist[15: 8] ),
    .dbg_hist2   ( dbg_hist[23:16] ),
    .dbg_hist3   ( dbg_hist[31:24] ),
    .dbg_hist4   ( dbg_hist[39:32] ),
    .dbg_hist5   ( dbg_hist[47:40] ),
    .dbg_hist6   ( dbg_hist[55:48] ),
    .dbg_hist7   ( dbg_hist[63:56] ),
    .dbg_looprate( dbg_looprate  ),
    .dbg_speed   ( dbg_speed     ),
    .dbg_niblo   ( dbg_niblo     ),
    .dbg_nibhi   ( dbg_nibhi     ),
    .dbg_d7      ( dbg_d7        ),
    .halted_n    ( dbg_halted_n  )
);

assign dbg_addr  = cpu_addr;
assign dbg_hdump = hdump;

// --------------------------------------------------------------------- video
wire        char_rom_cs, tile_rom_cs, obj_rom_cs;
wire [14:0] char_rom_addr;
wire [16:0] tile_rom_addr, obj_rom_addr;
wire [31:0] char_rom_data, tile_rom_data, obj_rom_data;
wire        char_rom_ok, tile_rom_ok, obj_rom_ok;

sh_video u_video (
    .clk           ( clk           ),
    .rst           ( rst           ),
    .pxl_cen       ( cen6          ),
    .cpu_addr      ( cpu_addr[12:1]),
    .cpu_dout      ( cpu_dout      ),
    .cpu_rnw       ( cpu_rnw       ),
    .cpu_dsn       ( cpu_dsn       ),
    .char_cs       ( char_cs       ),
    .bac_mode_cs   ( bac_mode_cs   ),
    .bac_vram_cs   ( bac_vram_cs   ),
    .pal_cs        ( pal_cs        ),
    .obj_cs        ( obj_cs        ),
    .char_din      ( char_din      ),
    .bac_din       ( bac_din       ),
    .pal_din       ( pal_din       ),
    .obj_din       ( obj_din       ),
    .char_rom_cs   ( char_rom_cs   ),
    .char_rom_addr ( char_rom_addr ),
    .char_rom_data ( char_rom_data ),
    .char_rom_ok   ( char_rom_ok   ),
    .tile_rom_cs   ( tile_rom_cs   ),
    .tile_rom_addr ( tile_rom_addr ),
    .tile_rom_data ( tile_rom_data ),
    .tile_rom_ok   ( tile_rom_ok   ),
    .obj_rom_cs    ( obj_rom_cs    ),
    .obj_rom_addr  ( obj_rom_addr  ),
    .obj_rom_data  ( obj_rom_data  ),
    .obj_rom_ok    ( obj_rom_ok    ),
    .red           ( red           ),
    .green         ( green         ),
    .blue          ( blue          ),
    .hsync         ( hsync         ),
    .vsync         ( vsync         ),
    .hblank        ( hblank        ),
    .vblank        ( vblank        ),
    .hdump         ( hdump         ),
    .flip          ( flip          ),
    .gfx_en        ( gfx_en        ),
    .dbg_mode0     ( dbg_mode0     ),
    .dbg_mode2     ( dbg_mode2     ),
    .dbg_mode3     ( dbg_mode3     ),
    .dbg_hscr_lo   ( dbg_hscr_lo   ),
    .dbg_vscr_lo   ( dbg_vscr_lo   ),
    .dbg_late_bac  ( dbg_late_bac  ),
    .dbg_late_chr  ( dbg_late_chr  ),
    .dbg_late_obj  ( dbg_late_obj  )
);

// --------------------------------------------------------------------- sound
wire        snd_rom_cs, pcm_cs;
wire [14:0] snd_rom_addr;
wire [17:0] pcm_addr;
wire [7:0]  snd_rom_data, pcm_data;
wire        snd_rom_ok, pcm_ok;
wire signed [15:0] snd_mono;

sh_snd u_snd (
    .audio_sel ( audio_sel    ),
    .oki_full  ( oki_full     ),
    .oki_test  ( oki_test     ),
    .clk       ( clk          ),
    .rst       ( cpu_rst      ),
    .cen6      ( cen6         ),
    .cen_opn   ( cen1p5       ),
    .cen_opl   ( cen3         ),
    .cen_oki   ( cen_oki      ),
    .snd_req   ( snd_req      ),
    .snd_latch ( snd_latch    ),
    .rom_cs    ( snd_rom_cs   ),
    .rom_addr  ( snd_rom_addr ),
    .rom_data  ( snd_rom_data ),
    .rom_ok    ( snd_rom_ok   ),
    .pcm_cs    ( pcm_cs       ),
    .pcm_addr  ( pcm_addr     ),
    .pcm_data  ( pcm_data     ),
    .pcm_ok    ( pcm_ok       ),
    .snd       ( snd_mono     ),
    .dbg_cpu_acc ( dbg_snd_cpu_acc ),
    .dbg_opn_wr  ( dbg_opn_wr      ),
    .dbg_opl_wr  ( dbg_opl_wr      ),
    .dbg_oki_wr  ( dbg_oki_wr      ),
    .dbg_opl_irq ( dbg_opl_irq     ),
    .dbg_oki_seen ( dbg_oki_seen ),
    .dbg_cpu_ch2  ( dbg_cpu_ch2  ),
    .dbg_cpu_all  ( dbg_cpu_all  ),
    .dbg_pcm_peak ( dbg_pcm_peak ),
    .dbg_oki_chip2 ( dbg_oki_chip2 ),
    .dbg_oki_chall ( dbg_oki_chall ),
    .dbg_peak_pcm ( dbg_peak_pcm ),
    .dbg_peak_opl ( dbg_peak_opl ),
    .dbg_peak_fm  ( dbg_peak_fm  ),
    .dbg_peak_ssg ( dbg_peak_ssg )
);

assign dbg_snd_latch = snd_latch;
// One pulse per ADPCM byte actually delivered, not per request.
reg pcm_ok_d;
always @(posedge clk) pcm_ok_d <= pcm_ok;
assign dbg_pcm_fetch = pcm_ok & ~pcm_ok_d;

// The PCB is mono: one MB3730 amp, `SPEAKER(config, "mono")` at :397.
assign snd_l = snd_mono;
assign snd_r = snd_mono;

// -------------------------------------------------------------------- memory
sh_romarb u_romarb (
    .clk           ( clk           ),
    .rst           ( mem_rst       ),

    .mem_addr      ( mem_addr      ),
    .mem_din       ( mem_din       ),
    .mem_dout      ( mem_dout      ),
    .mem_req       ( mem_req       ),
    .mem_we        ( mem_we        ),
    .mem_ds        ( mem_ds        ),
    .mem_ack       ( mem_ack       ),

    .dl_active     ( dl_active     ),
    .dl_addr       ( dl_addr       ),
    .dl_data       ( dl_data       ),
    .dl_req        ( dl_req        ),
    .dl_ack        ( dl_ack        ),

    // The 68000's ROM is on chip now (sh_progrom below), so the arbiter has
    // no main client at all.  Tying it off rather than deleting the port
    // keeps sh_romarb and its testbench unchanged.
    .main_cs       ( 1'b0          ),
    .main_addr     ( 16'd0         ),
    .main_data     (               ),
    .main_ok       (               ),

    .snd_cs        ( snd_rom_cs    ),
    .snd_addr      ( snd_rom_addr  ),
    .snd_data      ( snd_rom_data  ),
    .snd_ok        ( snd_rom_ok    ),

    .pcm_cs        ( pcm_cs        ),
    .pcm_addr      ( pcm_addr      ),
    .pcm_data      ( pcm_data      ),
    .pcm_ok        ( pcm_ok        ),
    .dbg_pcm_cnt   ( dbg_pcm_cnt   ),

    .char_cs       ( char_rom_cs   ),
    .char_addr     ( char_rom_addr ),
    .char_data     ( char_rom_data ),
    .char_ok       ( char_rom_ok   ),

    .tile_cs       ( tile_rom_cs   ),
    .tile_addr     ( tile_rom_addr ),
    .tile_data     ( tile_rom_data ),
    .tile_ok       ( tile_rom_ok   ),

    .obj_cs        ( obj_rom_cs    ),
    .obj_addr      ( obj_rom_addr  ),
    .obj_data      ( obj_rom_data  ),
    .obj_ok        ( obj_rom_ok    )
);

endmodule

`default_nettype wire
