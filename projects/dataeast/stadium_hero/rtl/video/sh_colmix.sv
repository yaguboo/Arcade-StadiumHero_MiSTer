//============================================================================
//  Stadium Hero -- palette and colour mixing
//
//  stadhero.cpp:165-176 is the whole mixer:
//
//      tilegen->draw(..., TILEMAP_DRAW_OPAQUE)   BAC06 16x16 background
//      spritegen->draw_sprites(...)              MXC06
//      pf1_tilemap->draw(..., 0)                 8x8 text, pen 0 transparent
//
//  Three layers, fixed order, back to front.  No priority register, no
//  per-pen priority, no mixing PROM.  jtcop_colmix.v -- 24-bit palette across
//  two RAMs, a prisel input and a 1024x2 priority PROM -- has nothing in it
//  that applies here.
//
//  ef19.3d IS a 512-byte PROM in the ROM set, and on other DEC0 boards the
//  equivalent part is exactly that priority lookup.  MAME loads it, marks it
//  `// ?` and never reads it (stadhero.cpp:448-449).  With a fixed layer order
//  there is nothing for it to select, so it is not implemented.  Recorded here
//  and in docs/MAME_NOTES.md section 10 so that "we forgot the PROM" is not a
//  live hypothesis later.
//
//  ---- palette -------------------------------------------------------------
//  1024 entries of 16 bits at 0x310000, format xBGR_444
//  (stadhero.cpp:387): bits 11-8 = B, 7-4 = G, 3-0 = R.
//
//  Layer palette bases come from GFXDECODE (stadhero.cpp:356-363):
//
//      chars    base   0, 3bpp -> entries    0-127
//      sprites  base 256, 4bpp -> entries  256-511
//      tiles    base 512, 3bpp -> entries  512-639
//
//  Each layer hands over { colour[3:0], pixel[3:0] }.  The base is added here
//  rather than inside each layer so that all three bases are visible in one
//  place next to the driver line they came from.
//============================================================================
`default_nettype none

module sh_colmix (
    input  wire        clk,
    input  wire        rst,
    input  wire        pxl_cen,

    // --- CPU side: 0x310000-0x3107ff ---------------------------------------
    input  wire        pal_cs,
    input  wire [10:1] cpu_addr,
    input  wire [15:0] cpu_dout,
    output wire [15:0] cpu_din,
    input  wire        cpu_rnw,
    input  wire [1:0]  cpu_dsn,

    // --- layers -------------------------------------------------------------
    input  wire [7:0]  tile_pxl,       // BAC06,  opaque
    input  wire [7:0]  obj_pxl,        // MXC06
    input  wire [7:0]  char_pxl,       // 8x8 text

    input  wire        hblank,
    input  wire        vblank,

    // --- layer enables, debug only; all ones in normal operation ------------
    input  wire [2:0]  gfx_en,

    output reg  [7:0]  red,
    output reg  [7:0]  green,
    output reg  [7:0]  blue
);

localparam [9:0] BASE_CHAR = 10'd0;
localparam [9:0] BASE_OBJ  = 10'd256;
localparam [9:0] BASE_TILE = 10'd512;

// ---- THE STRIDE IS THE BIT DEPTH, NOT THE BUS WIDTH ----------------------
// A colour set is as many palette entries as the layer has pens.  chars and
// tiles are 3bpp, so their sets are EIGHT entries apart; sprites are 4bpp and
// theirs are sixteen.
//
//     chars    0 + colour*8  + pixel[2:0]     ->   0..127
//     sprites  256 + colour*16 + pixel[3:0]   -> 256..511
//     tiles    512 + colour*8  + pixel[2:0]   -> 512..639
//
// which is the 640 reachable entries docs/MAME_NOTES.md section 6 already
// wrote down, from GFXDECODE_ENTRY at stadhero.cpp:356-363.
//
// The first version strode all three by sixteen, because each layer hands over
// a byte of { colour, pixel } and concatenation is the obvious thing to do with
// one.  Sprites were therefore right and the other two were wrong, and the
// symptom was subtle in exactly the wrong way: the shapes were perfect and only
// the COLOURS were off, so it read as a palette-RAM or plane-order fault.
//
// The text layer looked correct too, which delayed it further -- at colour 0
// both strides give the same entries, and the attract text is colour 0.
//
// Found by comparing a board screenshot with a MAME snapshot of the same
// screen: MAME's outfield is green and the board's was orange.  Same tiles,
// different palette entries.

// A pixel is transparent when its index within the colour is zero.  Only the
// bits the layer actually has are tested.
wire char_opaque = |char_pxl[2:0] & gfx_en[2];
wire obj_opaque  = |obj_pxl[3:0]  & gfx_en[1];

wire [7:0] tile_sel = gfx_en[0] ? tile_pxl : 8'd0;

reg [9:0] pal_addr;

always @* begin
    // Back to front: text wins, then sprites, then the opaque background.
    if      (char_opaque) pal_addr = BASE_CHAR + { 3'd0, char_pxl[7:4], char_pxl[2:0] };
    else if (obj_opaque)  pal_addr = BASE_OBJ  + { 2'd0, obj_pxl };
    else                  pal_addr = BASE_TILE + { 3'd0, tile_sel[7:4], tile_sel[2:0] };
end

// ---------------------------------------------------------------- palette
wire [1:0]  pal_we = ~cpu_dsn & {2{pal_cs & ~cpu_rnw}};
wire [15:0] pal_q;

sh_dpram16 #(.AW(10)) u_pal (
    .clk    ( clk       ),
    .addr_a ( cpu_addr  ),
    .data_a ( cpu_dout  ),
    .we_a   ( pal_we    ),
    .q_a    ( cpu_din   ),
    .addr_b ( pal_addr  ),
    .q_b    ( pal_q     )
);

// xBGR_444 -> 8 bits per channel.  Replicating the nibble is the standard
// expansion and puts 0xf at full scale, which a shift by four would not.
wire [7:0] r8 = { pal_q[3:0],  pal_q[3:0]  };
wire [7:0] g8 = { pal_q[7:4],  pal_q[7:4]  };
wire [7:0] b8 = { pal_q[11:8], pal_q[11:8] };

always @(posedge clk) begin
    if (rst) begin
        red <= 8'd0; green <= 8'd0; blue <= 8'd0;
    end else if (pxl_cen) begin
        if (hblank || vblank) begin
            red <= 8'd0; green <= 8'd0; blue <= 8'd0;
        end else begin
            red <= r8; green <= g8; blue <= b8;
        end
    end
end

endmodule

`default_nettype wire
