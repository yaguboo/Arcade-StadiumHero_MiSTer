//============================================================================
//  Data East "Stadium Hero" for MiSTer -- board wrapper
//
//  Wires the board-independent core in rtl/sh_top.sv to the MiSTer framework:
//  clocks, HPS I/O, ROM download, SDRAM and video.  Root CLAUDE.md section 4
//  keeps hps_io / ioctl_* / MRA on this side of the line and out of rtl/.
//
//  STATE OF PLAY -- read this before believing anything on screen.
//
//  This is the FIRST build of this core.  Nothing in it has been on hardware
//  and only two of its modules have been simulated at all (jt65c02 and
//  sh_romarb; see STATUS.md for the per-module rung).  Everything else has
//  been elaborated and nothing more.
//
//  So a black screen is the expected first outcome, not a surprise, and the
//  useful question is which of the suspects in docs/SIMULATION_RULES.md
//  section 11 it is.  Two of them are answerable without a rebuild:
//
//      python ../../tools/check_pll.py mister      (is the PLL programmed?)
//      python ../../tools/check_unconnected.py     (is a wrapper input open?)
//
//  Stadium Hero is horizontal (MAME rotate=0), so there is no screen_rotate
//  and no MISTER_FB -- the same call Power Spikes made, and for the same
//  reason: a DDR framebuffer this core never reads costs resources.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Ports this core does not use /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

// No framebuffer: horizontal game, so the qsf does not define MISTER_FB and
// the FB_* ports DO NOT EXIST -- sys/emu_ports.vh declares them inside an
// `ifdef.  Assigning them anyway creates implicit nets that go nowhere, and
// every one of them draws a warning.  That is how Power Spikes found it.
//
// Note the wording.  The first version of this comment began a line with
// "// synthesis warns about..." and Quartus read it as a PRAGMA, reporting
// four unrecognised synthesis attributes: warns, about, every, one.  A comment
// starting "// synthesis" is not a comment.
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN,
        DDRAM_BE, DDRAM_WE, DDRAM_RD} = 0;

// Aspect ratio.  Nothing drives these by default and an undriven output is
// only a warning, so the picture would simply come out the wrong shape.
// 256 x 240 on a 4:3 monitor is the original.
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

assign VGA_F1        = 0;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// The PCB is mono: one MB3730 amp and `SPEAKER(config, "mono")` at
// stadhero.cpp:397.  sh_mixer already applies MAME's per-channel gains and
// outputs signed 16-bit, so AUDIO_S is 1 and nothing is scaled here.
// AUDIO_MIX stays 0 -- there is nothing to mix, both channels are the same
// signal, and asking the framework to blend them would be a change, not a fix.
assign AUDIO_S   = 1;
assign AUDIO_L   = snd_l;
assign AUDIO_R   = snd_r;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
// Solid while ROMs load, then a slow blink for as long as the third PLL output
// keeps counting.  See pll_alive below.
assign LED_USER  = ioctl_download | pll_alive;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"StadiumHero;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	// Layer enables.  Three fixed layers with no priority mixing
	// (docs/MAME_NOTES.md section 11), so switching one off is a clean way to
	// ask "whose pixels are those" without a rebuild -- which is the question
	// every first-light session ends up asking.
	"P1O[20],Background (BAC06),On,Off;",
	"P1O[21],Sprites (MXC06),On,Off;",
	"P1O[22],Text layer,On,Off;",
	// Freezes both CPUs (sh_top: ce_en = ~pause & ~dl_active).  The video
	// engines keep scanning and keep contending for SDRAM, so a paused screen
	// is a STATIC picture drawn by a LIVE renderer -- the only way to
	// photograph a frame-to-frame artefact without the game animating under it.
	"P1O[14],Pause CPUs,Off,On;",
	// Sound liveness readout.  Eight bytes as eight rows of blocks in the
	// top-left corner; sh_dbg.sv has the table.  There is no way to listen to
	// the board over ssh, so this is how a running sound CPU is told apart
	// from a stopped one.
	"P1O[15],Debug overlay,Off,On;",
	// Solo one sound source.  The M6295 readout proved the voices are asked
	// for, started on channel 2 and fetched from ROM; whether they are
	// AUDIBLE against the music is a question only an ear settles, and this
	// turns it into a ten-second test instead of a thirty-five minute build.
	"P1O[17:16],Audio,All,M6295 only,YM2203 only,YM3812 only;",
	// Calibration, not a feature.  The board's M6295 measures about 33x
	// quieter than MAME's, but the two measurements did not play the same
	// samples at the same volume.  Forcing both sides to attenuation 0 makes
	// the comparison like for like; tools/wav_diff.py does the MAME half.
	"P1O[18],M6295 full volume (test),Off,On;",
	// Plays phrase 8 on channel 2 at attenuation 0 every ~2 s, so the peak
	// meter reads the SAME thing every time.  Attract cannot give that -- which
	// sample is loudest in a four-minute window changes run to run, and that is
	// why "8 -> 24" could not be read as a gain factor.
	"P1O[19],M6295 test tone,Off,On;",
	// Eight rows, one per value of rng[6:4], counted at the instant the 68000
	// completes a read of 0x30c003.  Flat and the phase theory dies; a bump
	// and it is confirmed, in one screenshot.
	// O[23], NOT O[20].  O[20] is the background layer enable three lines
	// above, and putting the histogram there turned the background OFF in
	// every measurement -- caught only because the captures came back
	// black.  A second meaning on a status bit is a silent one.
	"P1O[23],RNG phase histogram,Off,On;",
	// Three more pages on the same eight rows.  O[23]'s histogram bins
	// rng[6:4]; DEBUG_LOG O10 showed the fielders' threshold is
	// 64 + (rng & 0x0F) redrawn every call, so those are not the bits that
	// decide anything and these pages carry the ones that are.
	//
	//   CPU speed   rows 0-1  polls of 0x30c002 last frame (6694 = 1A 26)
	//               rows 2-3  68000 clocks last frame / 16 (174079 = 2A 7F)
	//               rows 4-6  the last RNG read's call site, 24 bits
	//               row  7    reads that matched 0xAC1x, / 256
	//   Fielder 0-7 / 8-15    rng[3:0] at 0x00AC10, sixteen bins over two
	//                         pages, each / 16
	//
	// Rows 4-6 exist so a dead site detector cannot look like a game that
	// never reached the demo: it says what the address actually was.
	"P1O[25:24],Debug page,Normal,CPU speed,Fielder 0-7,Fielder 8-15;",
	// Which derivation 0x30c003 returns, and how long the 68000 sees VBLANK.
	// BEHAVIOUR-CHANGING, both: 0x30c003 is the game's only random number and
	// the game starts each frame's work when VBLANK falls, so together they
	// decide the CPU pitcher's pitch type (0x00AC36), the batted ball
	// (0x0080EE, 0x00845A) and the stage music (0x0017DE).
	//
	// DEFAULT IS MAME-COMPATIBLE (status 0), since 2026-09-14.  With the board
	// derivation and the raster's 32-line VBLANK the CPU pitcher threw a slow
	// breaking ball on nine pitches of nine where MAME's threw a fast one; with
	// both set to MAME's the first pitches match MAME's choice, timer and
	// flight exactly.  Neither setting is a hardware claim.
	// docs/STADHERO_FIX_REPORT.md, docs/STADHERO_MYSTERY_RNG_AUDIT.md.
	"P1O[27:26],RNG source,MAME hpos/2,Board,hdump[6:0];",
	"P1O[28],VBlank at 0x30c002,MAME 529us,Raster;",
	// 위의 항목들은 전부 프로브다.  첫 화면에는 플레이어가 쓸 것만 둔다
	// (docs/OSD_POLICY.md 6절).  status 비트는 하나도 안 옮겼다 -- .mra 가
	// OSD 기본값을 비트 번호로 저장하므로 위치만 바꾼다.
	"P1,Debug;",
	"-;",
	// The MRA's <switches> block.  Every PORT_DIPNAME in stadhero.cpp:276-311
	// is on this page; without this line the block is still downloaded but the
	// operator has no way to reach it, which is how this core shipped its
	// first build -- DIPs frozen at FF FF and no menu.
	"DIP;",
	"-;",
	// --- 표준 OSD, docs/OSD_POLICY.md -------------------------------------
	// `On` 이 먼저여야 기본이 On 이다 -- MiSTer 는 코어 로드 때 status 를 0 으로
	// 지우므로 status[12]==0 이 곧 기본값이다.
	"O[12],Pause when OSD open,On,Off;",
	// Service 는 이 기판에서 DIP 가 아니라 캐비닛 스위치다 (stadhero.cpp:317,
	// COIN bit 6).  DIP 메뉴로 뺄 수 없으므로 OSD 항목으로 둔다 -- 어느 쪽이든
	// 키매핑에는 넣지 않는다 (OSD_POLICY 3절).
	"O[13],Service,Off,On;",
	"-;",
	"R[0],Reset;",
	// Three buttons and Start on the pad, Coin on Select -- the shape both
	// working cores in this factory use.  stadhero.cpp:259-274 gives each
	// player three buttons; P1 is the low byte of INPUTS and P2 the high.
	// Each pad drives its OWN start: P1 is joystick_0 bit 7, P2 joystick_1
	// bit 7.  Power Spikes shipped a build where Start and Coin were not where
	// anyone reaches for them, which looked like broken input.
	// Service (COIN bit 6, stadhero.cpp:317) is a cabinet switch, not a DIP.
	// It was hard-wired inactive until 2026-09-03, so the operator menu was
	// unreachable -- a whole input the driver has and the core did not.
	// *** bit 9 는 Service 였고 이제 Pause 다. ***  m_service 는 아래에서
	// status[13] 을 읽도록 같이 바꿨다 -- 안 바꿨으면 Pause 를 누를 때마다
	// Service 가 들어갔을 것이고, 빌드는 그대로 통과했을 것이다.
	// Names from what the ROM does with each bit, not from guesses (2026-09-14,
	// docs/STADHERO_TIMING_AUDIT.md 5.1).  "Bat/Throw" used to sit on Button 1,
	// which never swings.  Positions are unchanged -- the .mra maps by position.
	//   Button 1  pickoff throw while pitching (0x002670 -> 0x0028E6)
	//   Button 2  swing (0x003F62), pitch (0x002668), run (0x002D92)
	//   Button 3  "TIME" player-substitution menu (0x00E76A / 0x00E8A2)
	"J1,Pickoff,Swing/Pitch/Run,Time/Sub,Start,Coin,Pause;",
	"jn,A,B,X,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire [21:0]  gamma_bus;
wire [127:0] status;
wire  [1:0]  buttons;

wire         ioctl_download;
wire         ioctl_wr;
wire [26:0]  ioctl_addr;
wire  [7:0]  ioctl_dout;
wire [15:0]  ioctl_index;
wire         ioctl_wait;

wire [31:0]  joystick_0, joystick_1;
wire [10:0]  ps2_key;

hps_io #(.CONF_STR(CONF_STR), .WIDE(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(),
	.joystick_3(),

	.ps2_key(ps2_key),

	// hps_io declares these inputs with no default, so leaving them open makes
	// them FLOAT.  NA-1/NA-2 lost a session to exactly that: an open
	// ioctl_wait goes onto HPS_BUS[37] as "core not ready" and hung the HPS
	// partway through the ROM load.  Tie every one of them off explicitly.
	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0),
	.joystick_4_rumble(16'd0),
	.joystick_5_rumble(16'd0),
	.ps2_kbd_clk_in(1'b0),
	.ps2_kbd_data_in(1'b0),
	.ps2_kbd_led_status(3'd0),
	.ps2_kbd_led_use(3'd0),
	.ps2_mouse_clk_in(1'b0),
	.ps2_mouse_data_in(1'b0),
	.video_rotated(1'b0),
	.new_vmode(1'b0),
	// OSD defaults come from the .mra, not from a rebuild.  Bit 0 (Reset) is
	// masked off: seeding it would hold the core in reset from the moment the
	// .mra finished loading, which is a baffling way to find an .mra typo.
	.status_in({96'd0, mra_status[31:1], 1'b0}),
	.status_set(mra_status_set),
	.info_req(1'b0),
	.info(8'd0),
	.sd_lba('{default:32'd0}),
	.sd_blk_cnt('{default:6'd0}),
	.sd_rd(1'b0),
	.sd_wr(1'b0),
	.sd_buff_din('{default:8'd0}),
	.ioctl_upload(),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(8'd0)
);

///////////////////   .MRA-SUPPLIED OSD DEFAULTS   ///////////////////////
//
// MiSTer clears every status bit on a fresh arcade load, so the DEFAULT is
// what a session actually starts with.  Rebuilding a bitstream to flip one
// option costs a build slot and forty minutes; editing three bytes in the .mra
// costs seconds.  Mechanism from NA-1/NA-2 via Power Spikes.
//
//   <rom index="1"><part>hh mm ll</part></rom>
//     hh = status[23:16]   mm = status[15:8]   ll = status[7:0]
//
//   <rom index="1"><part>hh mm ll xx</part></rom>
//     xx = status[31:24], and the debug page lives at status[25:24]
//
// The fourth byte is APPENDED rather than prepended so that every .mra written
// before it still means what it meant: three bytes leave [31:24] at zero, and
// `seen` is still set by the third.  Prepending would have silently shifted
// every existing default by eight bits.

reg [31:0] mra_status      = 32'd0;
reg        mra_status_seen = 1'b0;
reg        ioctl_dl_d      = 1'b0;
reg        mra_status_done = 1'b0;
reg        mra_status_set  = 1'b0;

always @(posedge clk_sys) begin
	// !ioctl_addr[26:2] so only the first FOUR bytes can land here.
	if (ioctl_wr && (ioctl_index == 16'd1) && !ioctl_addr[26:2]) begin
		case (ioctl_addr[1:0])
			2'd0: mra_status[23:16] <= ioctl_dout;
			2'd1: mra_status[15:8]  <= ioctl_dout;
			2'd2: begin mra_status[7:0] <= ioctl_dout; mra_status_seen <= 1'b1; end
			2'd3: mra_status[31:24] <= ioctl_dout;
		endcase
	end
end

always @(posedge clk_sys) begin
	ioctl_dl_d     <= ioctl_download;
	mra_status_set <= 1'b0;
	if (ioctl_dl_d && !ioctl_download && mra_status_seen && !mra_status_done) begin
		// Only when NO saved settings were loaded.  MiSTer loads <setname>.CFG
		// into status BEFORE the ROM download, and status_set makes Main replace
		// all 128 bits with status_in (Main_MiSTer user_io.cpp
		// check_status_change) -- so pushing the .mra defaults unconditionally
		// overwrote every saved OSD setting on every load ("settings do not
		// save", reported 2026-10-07).  A saved file has some bit of [127:1]
		// set; a fresh load has none.  [0] is the reset bit Main pulses.
		mra_status_set  <= ~|status[127:1];
		mra_status_done <= 1'b1;
	end
end

///////////////////////   CLOCKS   ///////////////////////////////
//
// 60.000 MHz, and every board clock divides from it exactly:
//     68000 /6 = 10 MHz, pixel /10 = 6 MHz, YM3812 /20 = 3 MHz,
//     YM2203 /40 = 1.5 MHz.  rtl/sh_cen.sv has the full table and why 60 was
//     chosen over 48.
// outclk_1 is the same frequency shifted half a period for SDRAM_CLK
// (-8333 ps at 60 MHz).
//
// NA-1/NA-2's worst bug was a PLL that Quartus accepted, TimeQuest blessed and
// the fitter programmed with an out-of-range VCO, so the core clock never ran
// on hardware and nothing said a word.  60 MHz from a 50 MHz reference is an
// exact 6/5 ratio, which should give a comfortable VCO -- but "should" is not
// a measurement, and the gate stays: build.sh runs tools/check_pll.py against
// the Fitter's PLL Usage Summary, which reports the counters as PROGRAMMED
// rather than as requested.  Do not remove that check.

wire clk_sys, clk_sdram, clk_aux, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_aux),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

// clk_aux is the third PLL output, inherited from Power Spikes where it exists
// to force the solver into a legal VCO.  At 60 MHz it may well be unnecessary
// -- but an unloaded output gets DELETED, the PLL re-solved with two outputs
// and the VCO moved, which is exactly the failure it was added to prevent.  So
// it keeps a real load until check_pll on a real fit says it can go.
//
// The load is also an instrument: if pll_alive never toggles, that clock is
// not running.
//
// It has to be READ, though, or the whole chain is dead logic and Quartus
// removes it -- taking the load with it and re-solving the PLL, which is the
// failure this exists to prevent.  The first synthesis run said so:
//
//     Warning (10036): object "pll_alive" assigned a value but never read
//
// Power Spikes fed it to a debug overlay.  This core has no overlay, so it
// drives the user LED instead: a slow blink means the third PLL output is
// running, and a dark LED on an otherwise-working core means it is not.  That
// is a real load and a real instrument, not a tie-off to silence a warning.
reg [26:0] aux_cnt = 27'd0;
always @(posedge clk_aux) aux_cnt <= aux_cnt + 27'd1;

reg [2:0] aux_sync = 3'd0;
always @(posedge clk_sys) aux_sync <= {aux_sync[1:0], aux_cnt[26]};
wire pll_alive = aux_sync[2];    // ~1.1 Hz square wave when that clock runs

wire rst_sys = RESET | status[0] | buttons[1] | ~pll_locked;

// The core is held in reset while ROMs load.  The memory bus must NOT be: it
// is the thing doing the loading.
wire rst_mem = ~pll_locked;

///////////////////////   INPUT   ////////////////////////////////
//
// docs/MAME_NOTES.md section 2 and section 8.  Everything is ACTIVE LOW except
// the vblank bit, which sh_main inserts itself.
//
// INPUTS (0x30c000), stadhero.cpp:259-274 -- P1 in the LOW byte, P2 in the
// HIGH byte:
//   0 up  1 down  2 left  3 right  4 B1  5 B2  6 B3  7 START1
//   8 up  9 down 10 left 11 right 12 B1 13 B2 14 B3 15 START2
//
// Note the direction order is UP, DOWN, LEFT, RIGHT -- not the right/left/
// down/up that MiSTer joystick bits use.  Getting this backwards makes the
// game look like it works until someone tries to move.
//
// joystick bit order from the J1 line above:
//   0 right  1 left  2 down  3 up  4 Bat  5 Run  6 Special  7 Start  8 Coin
//   9 Service

wire [31:0] j1 = joystick_0;
wire [31:0] j2 = joystick_1;

wire [15:0] inputs = ~{
	j2[7],                          // 15 START2 -- P2's own pad
	j2[6], j2[5], j2[4],            // 14-12 P2 buttons 3,2,1
	j2[0], j2[1], j2[2], j2[3],     // 11-8  P2 right,left,down,up
	j1[7],                          //  7 START1
	j1[6], j1[5], j1[4],            //  6-4  P1 buttons 3,2,1
	j1[0], j1[1], j1[2], j1[3]      //  3-0  P1 right,left,down,up
};

// COIN (0x30c002), bits 6:0.  Bit 7 is vblank and sh_main supplies it -- it is
// the one ACTIVE HIGH bit on the board (stadhero.cpp:318) and must not be
// inverted here with the rest.
wire [6:0] coin = ~{
	m_service,        // 6 service
	j2[8],            // 5 coin 2 -- each pad coins itself
	j1[8],            // 4 coin 1
	4'b0000           // 3-0 unused
};

// Either pad can press Service; the cabinet has one switch and it does not
// belong to a player.
wire m_service = status[13];          // was j1[9] -- that bit is Pause now

// --- Pause -----------------------------------------------------------------
// 버튼 토글 + OSD 자동 정지.  ioctl_download 에서 반드시 푼다: ROM 로드 뒤
// 남은 pause 는 화면상 행과 구별되지 않는다.  docs/OSD_POLICY.md 2절.
wire pause_btn = j1[9] | j2[9];
reg  pause_btn_d, pause_latch;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (ioctl_download)                  pause_latch <= 1'b0;
	else if (~pause_btn_d & pause_btn)   pause_latch <= ~pause_latch;
end
wire pause_core = status[14] | pause_latch | (OSD_STATUS & ~status[12]);

// DSW (0x30c004).  Reset value is all ones, which is every switch in the
// position stadhero.cpp:276-311 documents as its default -- including Demo
// Sounds ON.  Power Spikes lost hours to a Demo Sounds default read the other
// way round (root CLAUDE.md section 5.1), so this is deliberate and not a
// placeholder.  The .mra overrides individual bits.
wire [15:0] dsw = mra_dsw;

reg [15:0] mra_dsw = 16'hffff;
always @(posedge clk_sys) begin
	// <rom index="254"> carries the DIP bytes, low byte first.
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[26:1]) begin
		if (!ioctl_addr[0]) mra_dsw[7:0]  <= ioctl_dout;
		else                mra_dsw[15:8] <= ioctl_dout;
	end
end

///////////////////////   THE BOARD   ////////////////////////////

wire [24:0] mem_addr;
wire [15:0] mem_din, mem_dout;
wire        mem_req, mem_we, mem_ack;
wire  [1:0] mem_ds;

wire        dl_active, dl_req, dl_ack;
wire [24:0] dl_addr;
wire [15:0] dl_data;

wire [7:0]  vid_r, vid_g, vid_b;
wire        hs, vs, hblank, vblank, ce_pix;
wire signed [15:0] snd_l, snd_r;

// OSD order is MAME-compatible first, so status 0 is the default; sh_main's
// own encoding is 0 board, 1 MAME, 2 hdump[6:0].
wire [1:0] rng_mode = (status[27:26] == 2'd0) ? 2'd1 :
                      (status[27:26] == 2'd1) ? 2'd0 : status[27:26];

// Layer enables are active-low in the OSD (On is 0), so invert here.
wire [2:0] gfx_en = ~{status[22], status[21], status[20]};

sh_top u_board
(
	.clk        (clk_sys),
	.rst        (rst_sys),
	.mem_rst    (rst_mem),
	.pause      (pause_core),

	.mem_addr   (mem_addr),
	.mem_din    (mem_din),
	.mem_dout   (mem_dout),
	.mem_req    (mem_req),
	.mem_we     (mem_we),
	.mem_ds     (mem_ds),
	.mem_ack    (mem_ack),

	.dl_active  (dl_active),
	.dl_addr    (dl_addr),
	.dl_data    (dl_data),
	.dl_req     (dl_req),
	.dl_ack     (dl_ack),

	.inputs     (inputs),
	.coin       (coin),
	.dsw        (dsw),
	.audio_sel  (status[17:16]),
	.oki_full   (status[18]),
	.oki_test   (status[19]),
	.rng_mode   (rng_mode),
	.vbl_mame   (~status[28]),          // status 0 = MAME 529 us

	.red        (vid_r),
	.green      (vid_g),
	.blue       (vid_b),
	.hsync      (hs),
	.vsync      (vs),
	.hblank     (hblank),
	.vblank     (vblank),
	.ce_pix     (ce_pix),

	.snd_l      (snd_l),
	.snd_r      (snd_r),

	.gfx_en     (gfx_en),
	.dbg_addr   (dbg_addr),
	.dbg_d7     (),
	.dbg_halted_n(),

	.dbg_snd_latch   (dbg_snd_latch),
	.dbg_snd_cpu_acc (dbg_snd_cpu_acc),
	.dbg_opn_wr      (dbg_opn_wr),
	.dbg_opl_wr      (dbg_opl_wr),
	.dbg_oki_wr      (dbg_oki_wr),
	.dbg_opl_irq     (dbg_opl_irq),
	.dbg_pcm_fetch   (dbg_pcm_fetch),
	.dbg_hdump       (dbg_hdump),
	.dbg_mode0       (dbg_mode0),
	.dbg_mode2       (dbg_mode2),
	.dbg_mode3       (dbg_mode3),
	.dbg_hscr_lo     (dbg_hscr_lo),
	.dbg_vscr_lo     (dbg_vscr_lo),
	.dbg_hist        (dbg_hist),
	.dbg_looprate    (dbg_looprate),
	.dbg_speed       (dbg_speed),
	.dbg_niblo       (dbg_niblo),
	.dbg_nibhi       (dbg_nibhi),
	.dbg_late_bac    (dbg_late_bac),
	.dbg_late_chr    (dbg_late_chr),
	.dbg_late_obj    (dbg_late_obj),
	.dbg_oki_seen    (dbg_oki_seen),
	.dbg_cpu_ch2     (dbg_cpu_ch2),
	.dbg_cpu_all     (dbg_cpu_all),
	.dbg_pcm_peak    (dbg_pcm_peak),
	.dbg_oki_chip2   (dbg_oki_chip2),
	.dbg_oki_chall   (dbg_oki_chall),
	.dbg_peak_pcm    (dbg_peak_pcm),
	.dbg_peak_opl    (dbg_peak_opl),
	.dbg_peak_fm     (dbg_peak_fm),
	.dbg_peak_ssg    (dbg_peak_ssg),
	.dbg_pcm_cnt     (dbg_pcm_cnt)
);

wire [23:1] dbg_addr;
wire [7:0]  dbg_snd_latch;
wire        dbg_snd_cpu_acc, dbg_opn_wr, dbg_opl_wr, dbg_oki_wr;
wire        dbg_opl_irq, dbg_pcm_fetch;
wire [8:0]  dbg_hdump;
wire [7:0]  dbg_mode0, dbg_mode2, dbg_mode3, dbg_hscr_lo, dbg_vscr_lo;
wire [7:0]  dbg_late_bac, dbg_late_chr, dbg_late_obj;
wire [63:0] dbg_hist;
wire [63:0] dbg_speed, dbg_niblo, dbg_nibhi;
wire [7:0]  dbg_looprate;

// One page selector over the same eight rows.  sh_dbg already takes a 64-bit
// bus and a switch, so the pages are a mux here rather than a change there.
wire [1:0]  dbg_page = status[25:24];
wire [63:0] dbg_rows = dbg_page == 2'd1 ? dbg_speed
                     : dbg_page == 2'd2 ? dbg_niblo
                     : dbg_page == 2'd3 ? dbg_nibhi
                     :                    dbg_hist;
wire [7:0]  dbg_oki_seen, dbg_pcm_cnt, dbg_pcm_peak, dbg_oki_chip2;
wire [7:0]  dbg_cpu_ch2, dbg_cpu_all, dbg_oki_chall;
wire [7:0]  dbg_peak_pcm, dbg_peak_opl, dbg_peak_fm, dbg_peak_ssg;

// The raster line.  sh_top does not export vdump, and the overlay must land
// inside the visible window rather than in the 32 lines of vblank, so it is
// counted here from the END of vblank.
reg [8:0] dbg_vdump;
reg       hb_d2, vb_d2;
always @(posedge clk_sys) if (ce_pix) begin
	hb_d2 <= hblank;
	vb_d2 <= vblank;
	if (vb_d2 && !vblank)      dbg_vdump <= 9'd0;
	else if (hblank && !hb_d2) dbg_vdump <= dbg_vdump + 9'd1;
end

wire [7:0] ov_r, ov_g, ov_b;

sh_dbg u_dbg (
	.clk(clk_sys), .pxl_cen(ce_pix),
	.enable(status[15] | status[23] | (dbg_page != 2'd0)),
	.hist_en(status[23] | (dbg_page != 2'd0)), .hist(dbg_rows),
	.hdump(dbg_hdump), .vdump(dbg_vdump),
	.rgb_in({vid_r, vid_g, vid_b}),
	.rgb_out({ov_r, ov_g, ov_b}),
	// Rows 0-2 carry the M6295 readout, because that is the open question:
	// "the safe/out voices do not play".  MAME says the game uses ten samples
	// and the four rare ones all start on channel 2 -- the group reported
	// missing.  row 0 = last phrase number the sound CPU latched, row 1 =
	// rolling count of start commands, row 2 = rolling count of COMPLETED
	// sample-ROM fetches / 256.
	//
	// Phrase moving + starts moving + fetch frozen  -> the data path.
	// Phrase frozen                                 -> the sound CPU never asks.
	// All three moving                              -> the chip or the mixer.
	//
	// The late-line counters that were here measured the wrong thing twice and
	// are dropped: "busy at hdump 0" is not "late", because the BAC06's last
	// tile is at the RIGHT of the line and the beam is 2400 clocks away from it.
	.mode0(dbg_peak_pcm), .mode2(dbg_peak_fm), .mode3(dbg_peak_opl),
	// hscr/vscr were a measured constant on this game (0x0300, never moves),
	// so row 3 carries the M6295 peak instead.
	// row 3 CPU start requests on ANY channel, row 4 the chip's starts on any
	// channel.  Rows 1 and 2 are the same pair for channel 2 alone, so the
	// channel-2 ratio can be read against the whole -- if both are 1:1 the
	// OKI path is fine, if only channel 2 is lossy the fault is per-channel.
	// Rows 0-3 are the MIX BALANCE, post-gain and directly comparable:
	// M6295, YM3812, YM2203 FM, YM2203 SSG.  Row 4 keeps the chip's own
	// channel-2 start count, which is already proved 1:1 with the CPU's.
	// row 3 SSG peak, row 4 the GAME'S OWN LOOP RATE -- passes x256 per
	// frame.  MAME measures 0.616, so 158.  Lower means the game skips more
	// frames here than there, and everything it animates is slow in real
	// time, which is what a fielder arriving late looks like.
	.hscr_lo(dbg_peak_ssg), .vscr_lo(dbg_looprate),
	.snd_cpu_acc(dbg_snd_cpu_acc),
	.opn_wr(dbg_opn_wr), .opl_wr(dbg_opl_wr), .oki_wr(dbg_oki_wr),
	.opl_irq(dbg_opl_irq)
);

///////////////////////   DOWNLOAD   /////////////////////////////

sh_download u_download
(
	.clk            (clk_sys),
	.rst            (rst_mem),
	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_dout     (ioctl_dout),
	.ioctl_index    (ioctl_index),
	.ioctl_wait     (ioctl_wait),
	.dl_addr        (dl_addr),
	.dl_data        (dl_data),
	.dl_req         (dl_req),
	.dl_ack         (dl_ack),
	.dl_active      (dl_active)
);

///////////////////////   SDRAM   ////////////////////////////////

reg  [3:0] sdram_init_cnt = 0;
wire       sdram_init = ~sdram_init_cnt[3];
always @(posedge clk_sys) begin
	if (!pll_locked)     sdram_init_cnt <= 0;
	else if (sdram_init) sdram_init_cnt <= sdram_init_cnt + 1'd1;
end

sh_sdram #(.CLK_HZ(60_000_000), .REFRESH_CLK(420)) u_sdram
(
	.clk        (clk_sys),
	.init       (sdram_init),
	.addr       (mem_addr),
	.din        (mem_din),
	.dout       (mem_dout),
	.req        (mem_req),
	.we         (mem_we),
	.ds         (mem_ds),
	.ack        (mem_ack),
	.SDRAM_A    (SDRAM_A),
	.SDRAM_BA   (SDRAM_BA),
	.SDRAM_DQ   (SDRAM_DQ),
	.SDRAM_DQML (SDRAM_DQML),
	.SDRAM_DQMH (SDRAM_DQMH),
	.SDRAM_nCS  (SDRAM_nCS),
	.SDRAM_nWE  (SDRAM_nWE),
	.SDRAM_nRAS (SDRAM_nRAS),
	.SDRAM_nCAS (SDRAM_nCAS),
	.SDRAM_CKE  (SDRAM_CKE)
);

///////////////////////   VIDEO   ////////////////////////////////

wire [2:0] fx = status[4:2];

// 256 visible pixels.  WIDTH is what arcade_video uses for the "Original"
// aspect calculation, so it has to be the game's width and not the raster's.
arcade_video #(.WIDTH(256), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(ce_pix),
	.RGB_in({ov_r, ov_g, ov_b}),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),
	.fx(fx)
);

endmodule
