//============================================================================
//  Stadium Hero -- the 68000's program ROM, on chip
//
//  128 KB, 65536 x 16, filled during the ROM download and read with one clock
//  of latency and no arbitration at all.
//
//  ---- why this is not in SDRAM with everything else ------------------------
//  It was, and it changed the game.
//
//  The 68000 reached SDRAM through sh_romarb, behind three video fetchers that
//  all start at the falling edge of HS and hold the bus for most of the line.
//  So the CPU only executed in the window they left -- and 0x30c003, the
//  register the game uses as its random number, is the RASTER COUNTER.  A CPU
//  that can only run at certain phases of the line reads a random number that
//  is not random.
//
//  MEASURED, both sides, over four minutes and ~4300 reads each
//  (docs/DEBUG_LOG.md O7).  Percentage of reads landing in each eighth of the
//  range:
//
//      bin   rng        MAME    board (SDRAM)
//       0    0..15      11.4      15.2
//       1    16..31     19.1      24.5
//       2    32..47     27.3       1.1     <- MAME's largest, all but absent
//       3    48..63      1.1       0.7
//       4    64..79      1.3       0.7
//       5    80..95     19.7      22.7
//       6    96..111    19.4       2.6
//       7    112..127    0.7      32.3     <- absent in MAME, the board's largest
//
//  Both are phase-locked -- the game frame-syncs on vblank, so that much is
//  expected and happens on real hardware too.  What differs is WHICH phase,
//  and that is set by who has the bus.  The game seeds its fielders' action
//  timers from the raw value ($8098 = rng & 0x7F at 0xAD56, compared against
//  0x40 + (rng & 0xF) at 0xAC10), so a different phase is a different game.
//
//  On the PCB the 68000 has its own ROMs on its own board (DE-0303-3) and
//  waits for nobody.  This is that.
//
//  ---- cost ----------------------------------------------------------------
//  1,048,576 bits = 103 M10K of 553.  The design used 147; this takes it to
//  about 250, or 45 %.  The SDRAM budget loses its largest client at the same
//  time, which is the other half of the point.
//============================================================================
`default_nettype none

module sh_progrom (
    input  wire        clk,

    // --- the ROM download ---------------------------------------------------
    //  dl_addr is a WORD address: integration/sh_download.sv:111 assigns
    //  `dl_addr <= ioctl_addr[25:1]`, and sh_romarb hands it to mem_addr
    //  unshifted while every other client shifts by one.  The 68000's region
    //  is bytes 0x000000-0x01ffff, so words 0x0000-0xFFFF.
    //
    //  The first version of this file took it for a byte address and indexed
    //  with dl_addr[16:1], halving it again: the image folded onto itself,
    //  half of it never written, and the board came up black.
    input  wire        dl_active,
    input  wire [24:0] dl_addr,
    input  wire [15:0] dl_data,
    input  wire        dl_req,

    // --- the CPU ------------------------------------------------------------
    input  wire        cs,
    input  wire [16:1] addr,
    output reg  [15:0] data,
    output reg         ok
);

localparam [24:0] WORDS = 25'h01_0000;   // 0x20000 bytes = 0x10000 words

(* ramstyle = "M10K, no_rw_check" *) reg [15:0] mem [0:65535];

wire        dl_hit  = dl_active & dl_req & (dl_addr < WORDS);
wire [15:0] dl_word = dl_addr[15:0];

always @(posedge clk) begin
    if (dl_hit) mem[dl_word] <= dl_data;
    data <= mem[addr];
    // One clock, every time.  No arbitration, so `ok` is simply the request
    // delayed -- which is what makes the CPU's timing independent of the
    // raster, and that independence is the whole reason this module exists.
    ok   <= cs;
end

endmodule

`default_nettype wire
