//============================================================================
//  Stadium Hero -- SDRAM ROM map
//
//  One place that the loader, the fetch logic and the MRA all agree on.
//
//  ---- packing ------------------------------------------------------------
//  The graphics regions are repacked at build time so that one 32-bit read
//  yields eight pixels of one tile row.  This is BUILD_TIME_ONLY under root
//  CLAUDE.md section 6: the MRA reorders bytes, it does not compute anything
//  the PCB computed at runtime.
//
//  chars and tiles are 3bpp on this board, sprites are 4bpp
//  (docs/MAME_NOTES.md section 6).  All three are packed into 32-bit words
//  with plane 3 zero-filled for the 3bpp regions, so one fetch path serves
//  every layer.  The cost is 33% of two small regions and it buys a single
//  ROM-read state machine instead of three.
//
//  A packed word holds, from bit 31 down:  plane3[7:0] plane2[7:0]
//                                          plane1[7:0] plane0[7:0]
//  where plane0 is the LEAST significant bit of the pixel, and bit 7 of each
//  plane byte is the LEFTMOST of the eight pixels.  The MRA is responsible
//  for the plane-order difference between chars and tiles/sprites that
//  docs/MAME_NOTES.md section 6 records -- by the time a word reaches the
//  RTL, plane0 is the LSB in every region.
//
//  ---- addressing ---------------------------------------------------------
//  Byte addresses.  Word/dword addressing is done at the point of use.
//
//    maincpu   0x000000  128 KB   16-bit, ef15 = even/high, ef13 = odd/low
//    audiocpu  0x020000   32 KB    8-bit, ROM image of 0x8000-0xffff
//    oki       0x028000   64 KB    8-bit
//    chars     0x040000  128 KB   4096 chars x  8 rows x 4 B
//    tiles     0x060000  512 KB   4096 tiles x 32 rows x 4 B
//    sprites   0x0e0000  512 KB   4096 tiles x 32 rows x 4 B
//                        ------
//                       ~1.31 MB
//
//  Only 2048 tiles physically exist in the tile region -- the region is
//  0x30000 bytes over three planes, which is 2048 16x16 tiles, while the tile
//  field in VRAM is 12 bits wide (docs/MAME_NOTES.md section 6).  The upper
//  half is allocated and reads as zero rather than aliasing, so a stray code
//  shows as a blank tile instead of a plausible wrong one.
//============================================================================
`ifndef SH_ROMMAP_SVH
`define SH_ROMMAP_SVH

localparam [24:0] SH_MAIN_BASE = 25'h00_0000;   // 68000 program
localparam [24:0] SH_MAIN_SIZE = 25'h02_0000;

localparam [24:0] SH_SND_BASE  = 25'h02_0000;   // 65C02 program (0x8000-0xffff)
localparam [24:0] SH_SND_SIZE  = 25'h00_8000;

localparam [24:0] SH_OKI_BASE  = 25'h02_8000;   // M6295 samples
localparam [24:0] SH_OKI_SIZE  = 25'h01_0000;

localparam [24:0] SH_CHAR_BASE = 25'h04_0000;   // 8x8  text, packed
localparam [24:0] SH_CHAR_SIZE = 25'h02_0000;

localparam [24:0] SH_TILE_BASE = 25'h06_0000;   // 16x16 BAC06, packed
localparam [24:0] SH_TILE_SIZE = 25'h08_0000;

localparam [24:0] SH_SPR_BASE  = 25'h0e_0000;   // 16x16 MXC06, packed
localparam [24:0] SH_SPR_SIZE  = 25'h08_0000;

localparam [24:0] SH_ROM_END   = SH_SPR_BASE + SH_SPR_SIZE;   // 0x16_0000

`endif
