//============================================================================
//  Stadium Hero -- 68000 side: address decode, I/O, interrupt
//
//  Map, from stadhero.cpp:226-241 (docs/MAME_NOTES.md section 2):
//
//    000000-01ffff  R   program ROM, 128 KB
//    200000-2007ff  RW  text layer tile RAM
//    240000-240007   W  BAC06 control registers
//    240010-240017   W  BAC06 scroll registers
//    260000-261fff  RW  BAC06 VRAM
//    30c000-30c001  R   INPUTS
//    30c002         R   COIN          (high byte of the word)
//    30c003         R   mystery/RNG   (low byte)
//    30c004-30c005  R   DSW
//    30c004-30c005   W  IRQ5 acknowledge
//    30c007          W  sound latch   (low byte)
//    310000-3107ff  RW  palette
//    ff8000-ffbfff  RW  main RAM, 16 KB
//    ffc000-ffc7ff  RW  sprite RAM, mirrored at +0x800
//
//  ---- interrupt -----------------------------------------------------------
//  set_vblank_int(irq5_line_assert) at :372, cleared by int_ack_w at :211.
//  ASSERT, not pulse: the line stays asserted until the game acknowledges with
//  a write to 0x30c004.  A pulse would work almost always and fail exactly
//  when the game is late to service it.
//
//  ---- the RNG at 0x30c003 -------------------------------------------------
//  MAME returns m_screen->hpos()/2 from a 256-wide screen, so 0-127, and the
//  driver header carries `TODO : RNG issue? ... BGM randomizer`.  This core
//  returns (hdump*85)>>8 from the true 384-wide counter by default; rng_mode
//  selects MAME's own derivation or hdump[6:0] for diagnosis.  APPROXIMATION,
//  PCB_VERIFICATION_NEEDED: docs/DECISIONS.md D9,
//  docs/STADHERO_MYSTERY_RNG_AUDIT.md.
//============================================================================
`default_nettype none

module sh_main (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_rst,        // held during ROM download
    input  wire        ce_en,          // pause / download stall

    // --- program ROM (through the arbiter) ----------------------------------
    output wire        rom_cs,
    output wire [16:1] rom_addr,
    input  wire [15:0] rom_data,
    input  wire        rom_ok,

    // --- video --------------------------------------------------------------
    output wire        char_cs,
    output wire        bac_mode_cs,
    output wire        bac_vram_cs,
    output wire        pal_cs,
    output wire        obj_cs,
    input  wire [15:0] char_din,
    input  wire [15:0] bac_din,
    input  wire [15:0] pal_din,
    input  wire [15:0] obj_din,

    input  wire        vblank,
    input  wire [8:0]  hdump,
    // Which derivation 0x30c003 returns.  DIAGNOSTIC, and it changes the game:
    //   0 = board, (hdump*85)>>8 -- what has shipped since DEBUG_LOG O5
    //   1 = MAME's hpos()/2, cycle-matched (EMULATION_DERIVED, below)
    //   2 = hdump[6:0], DECISIONS D9's what-a-wire-does candidate
    //   3 = same as 0
    input  wire [1:0]  rng_mode,
    // How long bit 7 of 0x30c002 (VBLANK) stays set, as the 68000 sees it.
    // DIAGNOSTIC, and it changes the game (below):
    //   0 = the raster's own blanking, 32 lines -- what DEC0 has
    //       (dec0.cpp:1797 set_raw(..., 272, 8, 248))
    //   1 = MAME stadhero.cpp:380, set_vblank_time(529 us) = 5290 clocks
    input  wire        vbl_mame,

    // --- cabinet ------------------------------------------------------------
    input  wire [15:0] inputs,
    input  wire [6:0]  coin,           // bit 7 of the port is vblank, added here
    input  wire [15:0] dsw,

    // --- sound --------------------------------------------------------------
    output reg  [7:0]  snd_latch,
    output reg         snd_req,        // one-cycle pulse per latch write

    // --- bus, exported to the video block -----------------------------------
    output wire [23:1] cpu_addr,
    output wire [15:0] cpu_dout,
    output wire        cpu_rnw,
    output wire [1:0]  cpu_dsn,

    // --- observability ------------------------------------------------------
    // Eight counters, one per value of rng[6:4], incremented at the instant the
    // 68000 completes a read of 0x30c003.
    //
    // The RANGE of that register was matched to MAME (0..127) and it was not
    // enough.  What this asks is whether the DISTRIBUTION is flat, and it is
    // the one question the range can hide: the video engines all start at the
    // HS falling edge and hold the arbiter for most of the line, so the 68000
    // only executes in the window they leave -- and this register is the
    // raster counter, so it is sampled at whatever phase that window falls in.
    //
    // Flat and the theory dies.  A bump and it is confirmed, in one screenshot.
    output wire [7:0]  dbg_hist0, dbg_hist1, dbg_hist2, dbg_hist3,
    output wire [7:0]  dbg_hist4, dbg_hist5, dbg_hist6, dbg_hist7,
    // The game's own loop rate.  The sync routine at 0x9330 waits for vblank to
    // end, then to start, then writes the scroll registers at 0x9346 -- so one
    // write of 0x240012 is one pass of the game's loop, and counting them
    // against frames says whether the loop keeps up.
    //
    // MAME, measured over 6000 frames: 0.616 passes per frame.  35 % of frames
    // have none at all, so the loop already skips there.  If this board is
    // LOWER the game animates more slowly in real time than it should, which
    // is what a fielder arriving late looks like.
    //
    // Scaled x256, so 0.616 reads as 158.
    output wire [7:0]  dbg_looprate,
    // ---- the CPU-speed page and the fielder-threshold histogram (O9, O10)
    //  Everything O9 says about this 68000 was measured under Verilator.  A
    //  simulation is rung 2 and the board is rung 5 (root CLAUDE.md 6.5), and
    //  these are what let the board say the same numbers or not.
    output wire [63:0] dbg_speed,
    output wire [63:0] dbg_niblo,
    output wire [63:0] dbg_nibhi,
    output wire [31:0] dbg_d7,
    output wire        halted_n
);

wire [23:1] addr;
wire [15:0] cpu_do, cpu_di;
wire        cpu_rd, cpu_wr, uds_n, lds_n, as_n;
wire        bus_ack;
wire        cpu_phi1;
wire [2:0]  ipl_n;

assign cpu_addr = addr;
assign cpu_dout = cpu_do;
assign cpu_rnw  = ~cpu_wr;
assign cpu_dsn  = { uds_n, lds_n };

wire acc = cpu_rd | cpu_wr;

// ------------------------------------------------------------ address decode
//  Only the lines the board decodes.  The 68000's A23..A17 are compared as the
//  driver's map compares them; anything the board leaves undecoded aliases the
//  way it would on the PCB rather than reading as open bus.
wire cs_rom  = acc & (addr[23:17] == 7'h00);                       // 000000-01ffff
wire cs_char = acc & (addr[23:16] == 8'h20) & (addr[15:11] == 5'd0);
wire cs_bacm = acc & (addr[23:16] == 8'h24) & (addr[15:5]  == 11'd0);
wire cs_bacv = acc & (addr[23:16] == 8'h26) & (addr[15:13] == 3'd0);
wire cs_io   = acc & (addr[23:16] == 8'h30) & (addr[15:8]  == 8'hc0);
wire cs_pal  = acc & (addr[23:16] == 8'h31) & (addr[15:11] == 5'd0);
wire cs_ram  = acc & (addr[23:16] == 8'hff) & (addr[15:14] == 2'b10);
// ffc000-ffc7ff mirrored at +0x800 (stadhero.cpp:240) -- addr[11] is ignored,
// which is what `.mirror(0x000800)` means on the real decode.
wire cs_obj  = acc & (addr[23:16] == 8'hff) & (addr[15:12] == 4'hc);

assign rom_cs      = cs_rom & cpu_rd;
assign rom_addr    = addr[16:1];
assign char_cs     = cs_char;
assign bac_mode_cs = cs_bacm;
assign bac_vram_cs = cs_bacv;
assign pal_cs      = cs_pal;
assign obj_cs      = cs_obj;

// ------------------------------------------------------------------ work RAM
//  ff8000-ffbfff, 16 KB = 8192 words.
wire [1:0]  ram_we = ~cpu_dsn & {2{cs_ram & cpu_wr}};
wire [15:0] ram_q;

sh_dpram16 #(.AW(13)) u_ram (
    .clk    ( clk        ),
    .addr_a ( addr[13:1] ),
    .data_a ( cpu_do     ),
    .we_a   ( ram_we     ),
    .q_a    ( ram_q      ),
    .addr_b ( 13'd0      ),
    .q_b    (            )
);

// ------------------------------------------------------------------------ I/O
//  0x30c002 is the high byte and 0x30c003 the low byte of one word, so a word
//  read at 0x30c002 returns { COIN, RNG }.  COIN bit 7 is vblank and is the
//  only ACTIVE HIGH bit on this board (stadhero.cpp:318).
// ---- VBLANK as the 68000 sees it (vbl_mame) ----------------------------------
// EMULATION_DERIVED (vbl_mame = 1)
// Matches MAME stadhero.cpp:379-380: set_refresh_hz(58) + set_vblank_time(529 us).
// That pair is the legacy screen setup copied into fourteen dataeast/ drivers;
// dec0.cpp, the same BAC06/MXC06 generation, has it commented out in favour of
// the raw 384 x 272 raster this core already generates.  It is here because
// the game's main loop starts its work when this bit FALLS (0x009330-0x009364),
// so the bit's length decides where in the raster every 0x30c003 read lands:
// 20,480 clocks of blanking here against 5,290 in MAME put every read 14,100 to
// 15,200 clocks later (tools/rng_diverge.py, DEBUG_LOG O15).
// IRQ5 still asserts on the raster's vblank edge, as MAME's does.
// TODO(HARDWAREIZE): the PCB's VBLANK length at this input is not measured.
localparam [12:0] MAME_VBL_CLOCKS = 13'd5290;
reg  [12:0] vbl_cnt;
reg         vbl_short, vbl_edge_d;
always @(posedge clk) begin
    if (rst) begin
        vbl_cnt    <= 13'd0;
        vbl_short  <= 1'b0;
        vbl_edge_d <= 1'b0;
    end else begin
        vbl_edge_d <= vblank;
        if (vblank && !vbl_edge_d) begin
            vbl_cnt   <= cpu_phi1 ? 13'd1 : 13'd0;
            vbl_short <= 1'b1;
        end else if (vbl_short && cpu_phi1) begin
            vbl_cnt <= vbl_cnt + 13'd1;
            if (vbl_cnt == MAME_VBL_CLOCKS - 13'd1) vbl_short <= 1'b0;
        end
    end
end
wire vblank_cpu = vbl_mame ? vbl_short : vblank;

wire [7:0] coin_in = { vblank_cpu, coin };
// ------------------------------------------------------------------- RNG
//  0x30c003.  MAME calls it mystery_r and returns m_screen->hpos() / 2 from a
//  256-wide screen, so 0..127 spread evenly across the line.  The real raster
//  is 384 wide, and this used to return hdump[8:1] -- 0..191, the same counter
//  but a third again as wide.
//
//  MEASURED, and it matters at exactly one place in the game.  Of 1853 reads
//  in 6000 frames (MAME, tools tapped by hand), every site but one masks the
//  value -- & 0x0F, & 0x07, & 0x1F, & 0x7F, BTST #1 -- so the range cannot
//  reach them.  The exception is 0x00ACA8:
//
//      MOVE.B  $30C003,D0
//      ANDI.B  #$F0,D0
//      CMPI.B  #$50,D0
//      BNE.S   00ACEE            skip the whole thing unless the top nibble is 5
//      LEA     $FF80CE,A2        four 0x22-byte objects, $80CE..$8156
//      BTST    #7,(A2)           ... and set a flag from a table at $ACEA
//
//  With 0..127 the top nibble is 5 one time in eight.  With 0..191 it is one
//  time in TWELVE, so a decision the game makes about once a second happens
//  half again as rarely, forever.
//
//  This board's fielders throw to empty bases where MAME's do not, and this is
//  the only difference in anything the 68000 reads -- ROM is byte-identical
//  (tools/check_rom.py), and the only other reads outside RAM are the text
//  layer, the BAC06 VRAM, INPUTS, DSW and the palette, all of which are plain
//  memory or verified wiring.
//
//  So the counter is scaled to MAME's range: x85 >> 8 is /3.01, which maps
//  hdump 0..383 onto 0..127 evenly.  383*85 = 32555, high byte 127.
//
//  INFERRED, and it stays inferred: nobody has told us how many bits of which
//  counter the real chip puts on this register, and MAME's own header carries
//  `TODO : RNG issue? Some behavior isn't correct (ex: BGM randomizer)`.  What
//  is known is that the game was tuned against the real thing, MAME reproduces
//  it, and 0..191 does not.  docs/DEBUG_LOG.md O5.
wire [16:0] rng_mul   = { 8'd0, hdump } * 17'd85;
wire [7:0]  rng_board = rng_mul[15:8];

// ---- the same register as MAME computes it (rng_mode == 1) ----------------
// EMULATION_DERIVED
// Matches MAME stadhero.cpp:216-221 (mystery_r = hpos()/2) with hpos() from
// screen.cpp:1034-1049, on the screen stadhero.cpp:379-381 declares: 256 x 256
// at 58 Hz.  Built to separate "the RNG" from "everything else" in the batting
// investigation.  It is NOT a hardware claim -- MAME's line is 256 ticks and
// this board's is 384.
// TODO(HARDWAREIZE): which H-counter bits does DE-0303-3 put on this byte?
//
// hpos() = ((t - vblank_start + pixel/2) mod line) / pixel.  In 68000 clocks a
// MAME line is 10e6 / 58 / 256 = 673.4914 and a pixel 2.6308, so a 32-bit
// phase that restarts at 1/512 of a line on the vblank edge and adds
// 2^32 / 673.4914 = 6377167.44 per clock carries hpos in its top eight bits and
// hpos/2 in its top seven.  Rounding the step costs 0.005 pixel per frame.
//
// MAME's frame is 172,414 clocks, which is 256.000 of its lines, so the phase
// is back at 1/512 before this board's longer frame (174,080) ends: the
// restart on the edge is continuous with the free-running phase.
localparam [31:0] MAME_PH_INC  = 32'd6377167;
localparam [31:0] MAME_PH_INIT = 32'h0080_0000;
reg [31:0] mame_ph;
reg        mame_vb_d;
always @(posedge clk) begin
    if (rst) begin
        mame_ph   <= MAME_PH_INIT;
        mame_vb_d <= 1'b0;
    end else begin
        mame_vb_d <= vblank;
        if (vblank && !mame_vb_d)
            mame_ph <= MAME_PH_INIT + (cpu_phi1 ? MAME_PH_INC : 32'd0);
        else if (cpu_phi1)
            mame_ph <= mame_ph + MAME_PH_INC;
    end
end

wire [7:0]  rng = (rng_mode == 2'd1) ? { 1'b0, mame_ph[31:25] } :
                  (rng_mode == 2'd2) ? { 1'b0, hdump[6:0] }     :
                                       rng_board;

reg [15:0] io_q;
always @* begin
    case (addr[3:1])
        3'd0:    io_q = inputs;             // 30c000
        3'd1:    io_q = { coin_in, rng };   // 30c002 / 30c003
        3'd2:    io_q = dsw;                // 30c004
        default: io_q = 16'hffff;
    endcase
end

// -------------------------------------------------------- the loop rate
//  0x240012 is BAC06 scrollreg[1]; cs_bacm covers 0x240000-0x24001f and
//  addr[4:1] picks the word, so 0x12 >> 1 = 9.
wire scr_wr = cs_bacm & cpu_wr & (addr[4:1] == 4'd9) & bus_ack;

reg [15:0] loop_cnt, loop_frames;
reg [7:0]  loop_rate;
reg        lvb_d;
always @(posedge clk) begin
    if (rst) begin
        loop_cnt <= 16'd0; loop_frames <= 16'd0;
        loop_rate <= 8'd0; lvb_d <= 1'b0;
    end else begin
        lvb_d <= vblank;
        if (scr_wr && !(vblank && !lvb_d && (&loop_frames[7:0])))
            loop_cnt <= loop_cnt + 16'd1;
        if (vblank && !lvb_d) begin
            if (&loop_frames[7:0]) begin
                // Every 256 frames, published as count/2 -- the per-frame
                // rate x128, so anything up to 1.99 passes a frame fits in
                // eight bits and NOTHING can wrap.
                //
                // The first version published loop_cnt[7:0] over the same
                // window, rate x256, and 301 passes came back as 45.  Against
                // MAME's 159 that reads as a game running three and a half
                // times too slowly; the true 301 reads as one running faster.
                // The same eight bits, opposite conclusions, and no way to
                // tell from the number itself.  Saturating would have said
                // "255 or more" and still not distinguished them.
                //
                // MAME measures 0.621 passes a frame, so 79 here.
                loop_rate   <= loop_cnt[8:1];
                loop_cnt    <= 16'd0;
                loop_frames <= 16'd0;
            end else begin
                loop_frames <= loop_frames + 16'd1;
            end
        end
    end
end
assign dbg_looprate = loop_rate;

// ------------------------------------------------- the RNG phase histogram
//  bus_ack is one clock wide, so each completed read counts once.  LDS only:
//  0x30c003 is the ODD byte, and the game reaches it with MOVE.B.
wire rng_rd = cs_io & cpu_rd & (addr[3:1] == 3'd1) & ~lds_n & bus_ack;

reg [15:0] hist [0:7];
integer hi;
always @(posedge clk) begin
    if (rst) begin
        for (hi = 0; hi < 8; hi = hi + 1) hist[hi] <= 16'd0;
    end else if (rng_rd && !(&hist[rng[6:4]])) begin
        hist[rng[6:4]] <= hist[rng[6:4]] + 16'd1;
    end
end

// Bits 11:4, so a bin of ~500 reads shows as ~31 and the row is readable long
// before it saturates.  Attract makes about 0.3 RNG reads a frame, so four
// minutes is a few hundred per bin if the distribution is flat.
assign dbg_hist0 = hist[0][11:4];  assign dbg_hist1 = hist[1][11:4];
assign dbg_hist2 = hist[2][11:4];  assign dbg_hist3 = hist[3][11:4];
assign dbg_hist4 = hist[4][11:4];  assign dbg_hist5 = hist[5][11:4];
assign dbg_hist6 = hist[6][11:4];  assign dbg_hist7 = hist[7][11:4];

// -------------------------------------------------- how fast the CPU really is
//  The game frame-syncs in a two-instruction loop at 0x9330, 0x9338 and
//  0x935C:
//
//      move.b  $30c002.l, D0     16 cycles      68000 user manual
//      bmi     back              10 cycles
//                                -- 26 --
//
//  Counting how many times that goes round in a frame measures the CPU's
//  throughput directly: not quantised, not dependent on what is on screen,
//  and with a documented expected value.  Through the boot self-test the game
//  does nothing else, so the count IS the clock.
//
//  MAME does 6630 a frame (tools/sh_pollrate.lua).  This board has 174,080
//  cycles in a frame against MAME's 172,414 -- the PCB's refresh against a
//  rounded one -- so an identical CPU does 6694, and Verilator says 6694.
//  DEBUG_LOG O9.  What has not said it is the board.
//
//  This replaces dbg_looprate as the speed row.  That one counts writes of
//  0x240012 and measures which attract scene is on screen: 99.3 % of passes
//  take exactly one frame, and MAME's own 256-frame windows read 0.004 to
//  1.000.  Do not read it as a CPU number.
wire io_poll = cs_io & cpu_rd & (addr[3:1] == 3'd1) & ~uds_n & bus_ack;

//  The MAXIMUM over frames, not the last frame.  A frame in which the game
//  did some work polls less -- MAME's own count runs 4950..6630 across attract
//  -- so an instantaneous reading is a measure of what is on screen and a
//  screenshot catches one frame.  The ceiling is the frame with no work in it,
//  which is the one that measures the CPU, and it is reached in the first
//  seconds of the boot self-test and then stands still.  A partial first frame
//  can only be under it.
reg [15:0] poll_cnt, poll_pf, poll_max;
reg [23:0] phi_cnt,  phi_pf;       // 68000 clocks in the last frame
reg        pvb_d;
wire [15:0] poll_now = poll_cnt + {15'd0, io_poll};

always @(posedge clk) begin
    if (rst) begin
        poll_cnt <= 16'd0; poll_pf <= 16'd0; poll_max <= 16'd0;
        phi_cnt  <= 24'd0; phi_pf  <= 24'd0;
        pvb_d    <= 1'b0;
    end else begin
        pvb_d <= vblank;
        if (vblank && !pvb_d) begin
            // publish and restart in the same cycle, counting anything that
            // lands on the edge -- otherwise one poll a frame goes missing
            // and 6694 reads as 6693 for no reason anyone could find later
            poll_pf  <= poll_now;
            phi_pf   <= phi_cnt  + {23'd0, cpu_phi1};
            poll_cnt <= 16'd0;
            phi_cnt  <= 24'd0;
            if (poll_now > poll_max) poll_max <= poll_now;
        end else begin
            if (io_poll)  poll_cnt <= poll_cnt + 16'd1;
            if (cpu_phi1) phi_cnt  <= phi_cnt  + 24'd1;
        end
    end
end

// ------------------------------------- WHICH call site read the RNG (O10)
//  The fielders' threshold is 64 + (rng & 0x0F), redrawn on every call at
//  0x00AC10, so the LOW nibble alone spans 15 frames -- a quarter of a second
//  at 57.4 Hz.  The O7 histogram bins rng[6:4] and cannot see it.
//
//  fx68k exposes no PC.  The site is identified by the last program-ROM fetch
//  before the read: the operand read at 0x30c003 follows the two extension
//  words at 0xAC12 and 0xAC14, and the next opcode is at 0xAC16, so every
//  candidate is in the sixteen bytes 0xAC10..0xAC1F whatever order fx68k
//  prefetches in.  The other three sites live in different blocks -- 0xAC3x,
//  0xACAx, 0xAD6x -- so a block compare separates them.
//
//  The last fetch address is published as-is on the speed page.  If the block
//  compare is wrong, that row says what the address actually was, in the same
//  screenshot -- rather than a histogram of zeroes with no way to tell a dead
//  detector from a site the game never reached.
reg [23:1] last_fetch;
always @(posedge clk) begin
    if (rst) last_fetch <= 23'd0;
    else if (cs_rom & cpu_rd & bus_ack) last_fetch <= addr;
end

wire site_ac10 = (last_fetch[23:4] == 20'h00AC1);

reg [23:1] rng_fetch;              // where the LAST RNG read came from
reg [15:0] site_cnt;               // how many landed on 0xAC1x
reg [15:0] nib [0:15];
integer    ni;

always @(posedge clk) begin
    if (rst) begin
        rng_fetch <= 23'd0;
        site_cnt  <= 16'd0;
        for (ni = 0; ni < 16; ni = ni + 1) nib[ni] <= 16'd0;
    end else if (rng_rd) begin
        rng_fetch <= last_fetch;
        if (site_ac10) begin
            if (~&site_cnt)          site_cnt      <= site_cnt + 16'd1;
            if (~&nib[rng[3:0]])     nib[rng[3:0]] <= nib[rng[3:0]] + 16'd1;
        end
    end
end

//  row 0-1  the MOST polls of 0x30c002 in any frame, 16 bits.  Verilator says
//           6694 = 0x1A 0x26; MAME's ceiling is 6630 = 0x19 0xE6.
//  row 2-3  68000 clocks in the last frame / 16.  174,079/16 = 10879 = 0x2A7F.
//  row 4-6  the last RNG read's call site, 24 bits.  0x00AC14 or 0x00AC16 is
//           the fielder threshold; 0x00ACAx is the O5 site; 0 is a dead
//           detector or a game that has not reached either.
//  row 7    reads that matched 0xAC1x, /256
assign dbg_speed = { site_cnt[15:8],
                     rng_fetch[7:1], 1'b0, rng_fetch[15:8], rng_fetch[23:16],
                     phi_pf[11:4], phi_pf[19:12],
                     poll_max[7:0], poll_max[15:8] };

//  Sixteen bins of rng[3:0] at 0xAC10, saturating, published as [11:4] the
//  way the O7 histogram is.  Two pages because the overlay has eight rows.
assign dbg_niblo = { nib[ 7][11:4], nib[ 6][11:4], nib[ 5][11:4], nib[ 4][11:4],
                     nib[ 3][11:4], nib[ 2][11:4], nib[ 1][11:4], nib[ 0][11:4] };
assign dbg_nibhi = { nib[15][11:4], nib[14][11:4], nib[13][11:4], nib[12][11:4],
                     nib[11][11:4], nib[10][11:4], nib[ 9][11:4], nib[ 8][11:4] };

// ------------------------------------------------------------------ IRQ5
reg  irq5, vblank_d;
wire int_ack  = cs_io & cpu_wr & (addr[3:1] == 3'd2);    // write to 30c004
wire latch_we = cs_io & cpu_wr & (addr[3:1] == 3'd3) & ~lds_n;   // 30c007

always @(posedge clk) begin
    if (rst) begin
        irq5     <= 1'b0;
        vblank_d <= 1'b0;
    end else begin
        vblank_d <= vblank;
        if (vblank && !vblank_d) irq5 <= 1'b1;   // assert on the vblank edge
        else if (int_ack)        irq5 <= 1'b0;   // and hold until acknowledged
    end
end

assign ipl_n = irq5 ? 3'b010 : 3'b111;           // level 5, active low

// ------------------------------------------------------------- sound latch
//  A write to 0x30c007 raises NMI on the 65C02 (stadhero.cpp:400).  bus_ack
//  gates it so the pulse happens once per bus cycle, not once per clock.
always @(posedge clk) begin
    if (rst) begin
        snd_latch <= 8'd0;
        snd_req   <= 1'b0;
    end else begin
        snd_req <= 1'b0;
        if (latch_we && bus_ack) begin
            snd_latch <= cpu_do[7:0];
            snd_req   <= 1'b1;
        end
    end
end

// ------------------------------------------------------------------ read mux
assign cpu_di = cs_rom              ? rom_data :
                cs_ram              ? ram_q    :
                cs_char             ? char_din :
                (cs_bacv | cs_bacm) ? bac_din  :
                cs_pal              ? pal_din  :
                cs_obj              ? obj_din  :
                cs_io               ? io_q     : 16'hffff;

// ---------------------------------------------------------------- bus ack
//  Everything on the board answers immediately except the program ROM, which
//  comes from SDRAM.  Waiting for rom_ok is what keeps that latency invisible
//  to the CPU instead of silently returning stale data.
//
//  The on-chip RAMs and the video RAMs are one-cycle: their q appears the
//  cycle after the address, so the ack is delayed by one.
reg ack_d;
always @(posedge clk) begin
    if (rst) ack_d <= 1'b0;
    else     ack_d <= acc & ~cs_rom & ~ack_d & ~bus_ack;
end

assign bus_ack = cs_rom ? rom_ok : ack_d;

// ------------------------------------------------------------------- CPU
// SLIP 6510: the 68000 is on the 20 MHz crystal and everything else on the
// 24 MHz one, 25.6 ppm apart by the PCB's own measured HSync.  Without it the
// CPU and the raster are locked to an exact 640.000 cycles a line and the
// game's only source of randomness returns three values forever -- the header
// in sh_m68k.sv, and DEBUG_LOG O11.
sh_m68k #(.CLK_DIV(6), .SLIP(6510)) u_cpu (
    .clk      ( clk      ),
    .rst      ( rst      ),
    .cpu_rst  ( cpu_rst  ),
    .ce_en    ( ce_en    ),
    .addr     ( addr     ),
    .dout     ( cpu_do   ),
    .din      ( cpu_di   ),
    .rd       ( cpu_rd   ),
    .wr       ( cpu_wr   ),
    .uds_n    ( uds_n    ),
    .lds_n    ( lds_n    ),
    .ack      ( bus_ack  ),
    .ipl_n    ( ipl_n    ),
    .fc       (          ),
    .iack_stb (          ),
    .dbg_d7   ( dbg_d7   ),
    .as_n     ( as_n     ),
    .halted_n ( halted_n ),
    .dbg_phi1 ( cpu_phi1 )
);

endmodule

`default_nettype wire
