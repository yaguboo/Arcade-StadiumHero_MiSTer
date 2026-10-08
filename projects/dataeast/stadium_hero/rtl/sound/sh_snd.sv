//============================================================================
//  Stadium Hero -- sound board
//
//  65C02 + YM2203 + YM3812 + M6295.  From stadhero.cpp:245-253:
//
//    0000-05ff  RW  RAM     -- the part is a 2Kx8 5814 (:29), so the hardware
//                              decode is 0000-07ff and MAME under-maps it
//    0800-0801   W  YM2203
//    1000-1001   W  YM3812
//    3000        R  sound latch, and reading it clears NMI
//    3800       RW  M6295
//    8000-ffff   R  ROM, 32 KB
//
//  NMI comes from the 68000's latch write (:400).  IRQ comes from the YM3812
//  ONLY (:409) -- the YM2203's IRQ pin is not connected on this board.
//
//  ---- this is very nearly RoboCop's sound board ---------------------------
//  jtcores cores/cop/hdl/jtcop_snd.v:75-92 decodes RAM at 0000, YM2203 at
//  0800, YM3812 at 1000, latch+NMI-clear at 3000 and M6295 at 3800 -- five of
//  six regions at the same addresses, the same three sound chips, the same
//  NMI-from-latch and IRQ-from-OPL wiring.  Only the ROM decode differs:
//  RoboCop banks and enables from 0x4000, Stadium Hero has one 32 KB ROM at
//  0x8000, so this decodes cpu_addr[15] alone.
//
//  Two Data East boards four years apart sharing a sound decode this closely is
//  the strongest common/ promotion candidate to come out of this project.
//  Recorded in docs/FACTORY_REUSE_NOTES.md -- not promoted, because root
//  CLAUDE.md 1.4 wants a second INDEPENDENT hardware family first and this is
//  one board.
//
//  ---- clocking ------------------------------------------------------------
//  jt65c02's cen is documented as "crystal clock freq. = 4x E pin freq.", and
//  jtcop drives it at 6 MHz for a 1.5 MHz E.  Stadium Hero's 65C02 is
//  24 MHz / 16 = 1.5 MHz, so the same 6 MHz enable is exact here.
//============================================================================
`default_nettype none

module sh_snd (
    input  wire        clk,
    input  wire        rst,

    input  wire        cen6,           // 6.000 MHz -> 1.5 MHz E pin
    input  wire        cen_opn,        // 1.500 MHz -- YM2203
    input  wire        cen_opl,        // 3.000 MHz -- YM3812
    input  wire        cen_oki,        // 1.056 MHz -- M6295, pin 7 HIGH

    // --- from the 68000 -----------------------------------------------------
    input  wire [1:0]  audio_sel,      // solo one source, for listening tests
    // Force every M6295 start to attenuation 0.  A calibration switch, not a
    // feature: the board's M6295 measures about 33x quieter than MAME's, but
    // the two measurements did not play the same samples at the same volume,
    // so the number is a lead and not a scale factor.  With both sides forced
    // to full volume the comparison is like for like.
    input  wire        oki_full,
    // Play ONE known phrase at ONE known attenuation, over and over, so the
    // peak meter reads the same thing every time.  Attract cannot do that:
    // which sample happens to be loudest in a four-minute window changes run
    // to run, which is why "8 -> 24" could not be read as a gain factor.
    // With this on, the number is a measurement of the path and nothing else.
    input  wire        oki_test,

    input  wire        snd_req,        // one-cycle pulse: latch written
    input  wire [7:0]  snd_latch,

    // --- program ROM --------------------------------------------------------
    output wire        rom_cs,
    output wire [14:0] rom_addr,       // 32 KB, 0x8000-0xffff
    input  wire [7:0]  rom_data,
    input  wire        rom_ok,

    // --- ADPCM samples ------------------------------------------------------
    output wire        pcm_cs,
    output wire [17:0] pcm_addr,
    input  wire [7:0]  pcm_data,
    input  wire        pcm_ok,

    // --- mixed output -------------------------------------------------------
    output wire signed [15:0] snd,

    // --- observability ------------------------------------------------------
    // There is no way to listen to the board over ssh, so these are how a
    // running sound CPU is told apart from a stopped one.  Strobes only; the
    // counting is done by the instrument (targets/mister/sh_dbg.sv).
    output wire        dbg_cpu_acc,
    output wire        dbg_opn_wr,
    output wire        dbg_opl_wr,
    output wire        dbg_oki_wr,
    output wire        dbg_opl_irq,

    // What the M6295 is being told, so "the safe/out voices do not play" can
    // be split into "the sound CPU never asks for them" and "it asks and
    // nothing comes out".  MAME says the game plays ten distinct samples;
    // the four rare ones (8, 9, 10, 13) all start on CHANNEL 2, and those are
    // the ones reported missing.
    // bit N set once phrase N+6 has EVER been latched: 6,7,8,9,10,11,12,13.
    // "The last phrase" was the first version and it only ever showed 3 and 4,
    // because those are the ones attract plays 62 and 262 times -- a snapshot
    // of a register cannot see something that happens twice in 12000 frames.
    // A sticky bit can.
    output reg  [7:0]  dbg_oki_seen,
    // The M6295 protocol is TWO writes: bit 7 set latches the phrase, the next
    // write starts it with the channel mask in [7:4].  A STOP is a single
    // write with bit 7 clear and its mask in [6:3].
    //
    // The first version of this counter did not track the pair -- it counted
    // any write with bit 7 clear and bit 6 set, which catches stops as well,
    // and read 255 against the chip's 7.  That ratio was an artefact.
    output reg  [7:0]  dbg_cpu_ch2,    // channel-2 START requests
    output reg  [7:0]  dbg_cpu_all,    // START requests, any channel
    // Peak |M6295| over roughly one frame.  Says whether the chip RENDERS the
    // samples it is fetching, which is the last link the counters do not cover.
    output reg  [7:0]  dbg_pcm_peak,
    // How many times the CHIP actually started channel 2, against how many
    // times the CPU asked it to (dbg_oki_ch2 above).  jt6295 publishes its
    // per-channel state continuously -- `assign dout = { 4'hf, busy | start }`
    // (jt6295.v:61) -- so this needs no change to the vendored source.
    //
    // Asked >> started is the proof that the start never completes: jt6295's
    // control machine has to walk six sequential rom_ok-gated byte reads
    // before `start <= ch` fires, and a walk that does not finish leaves the
    // sample unplayed with nothing else looking wrong.
    output reg  [7:0]  dbg_oki_chip2,
    output reg  [7:0]  dbg_oki_chall,
    output wire [7:0]  dbg_peak_pcm,
    output wire [7:0]  dbg_peak_opl,
    output wire [7:0]  dbg_peak_fm,
    output wire [7:0]  dbg_peak_ssg
);

wire [15:0] cpu_addr;
wire [7:0]  cpu_dout;
wire        cpu_rd, cpu_wr;
wire        cpu_rnw = ~cpu_wr;
wire        cpu_acc = cpu_rd | cpu_wr;

reg  [7:0]  cpu_din;
reg         ram_cs, opn_cs, opl_cs, oki_cs, nmi_clr;

wire [7:0]  ram_q, opn_dout, opl_dout, oki_dout;
wire        opn_irq_n, opl_irq_n;

// ---------------------------------------------------------------- decode
//  Registered one cycle, as jtcop does: the chip selects are what the address
//  decoder PAL produces and they are stable for the whole access.
always @(posedge clk) begin
    if (rst) begin
        ram_cs  <= 1'b0;
        opn_cs  <= 1'b0;
        opl_cs  <= 1'b0;
        oki_cs  <= 1'b0;
        nmi_clr <= 1'b0;
    end else begin
        ram_cs  <= 1'b0;
        opn_cs  <= 1'b0;
        opl_cs  <= 1'b0;
        oki_cs  <= 1'b0;
        nmi_clr <= 1'b0;
        if (cpu_acc && !cpu_addr[15]) begin
            case (cpu_addr[13:11])
                3'd0: ram_cs  <= 1'b1;          // 0000-07ff
                3'd1: opn_cs  <= 1'b1;          // 0800-0fff
                3'd2: opl_cs  <= 1'b1;          // 1000-17ff
                3'd6: nmi_clr <= cpu_rnw;       // 3000-37ff
                3'd7: oki_cs  <= 1'b1;          // 3800-3fff
                default: ;
            endcase
        end
    end
end

// One 32 KB ROM at 0x8000 -- no bank, unlike RoboCop.
assign rom_cs   = cpu_addr[15] & cpu_acc;
assign rom_addr = cpu_addr[14:0];

// Reads from the sound chips settle a cycle late, like the RAM.
reg       dev_cs;
reg [7:0] dev_q;
always @(posedge clk) begin
    dev_cs <= opn_cs | opl_cs | oki_cs;
    dev_q  <= opn_cs ? opn_dout :
              opl_cs ? opl_dout : oki_dout;
end

always @* begin
    cpu_din = cpu_addr[15] ? rom_data :
              ram_cs       ? ram_q    :
              nmi_clr      ? snd_latch:
              dev_cs       ? dev_q    : 8'hff;
end

// -------------------------------------------------------------------- NMI
//  Set by the 68000's latch write, cleared when the 65C02 reads the latch.
reg nmi_n;
always @(posedge clk) begin
    if (rst)          nmi_n <= 1'b1;
    else if (nmi_clr) nmi_n <= 1'b1;
    else if (snd_req) nmi_n <= 1'b0;
end

// IRQ from the YM3812 alone (stadhero.cpp:409).
wire irq_n = opl_irq_n;

// -------------------------------------------------------------------- CPU
//  jt65c02 has NO wait input.  Whatever is on cpu_din at an enabled edge is
//  what it executes, so a slow ROM read does not stall it -- it feeds it
//  garbage, silently.
//
//  jtcop takes rom_ok into jtcop_snd and never uses it (jtcop_snd.v:20 is the
//  only occurrence in the file): it assumes jtframe's SDRAM answers inside one
//  6 MHz enable.  That assumption is not free here.  This arbiter serves the
//  sound ROM LAST, behind three graphics fetchers that each take two 16-bit
//  accesses, so the worst case can exceed the ten clocks between enables.
//
//  So the enable is gated instead: while a ROM fetch is outstanding the CPU
//  simply does not advance.  That is a wait state the real board does not have
//  -- its ROM is fast SRAM -- but it is the conservative direction to be wrong
//  in, and it costs nothing whenever the fetch is already done.  The sound
//  chips' own enables are untouched, so pitch and tempo do not move.
wire rom_wait = rom_cs & ~rom_ok;
wire cen_cpu  = cen6 & ~rom_wait;

jt65c02 u_cpu (
    .rst    ( rst       ),
    .clk    ( clk       ),
    .cen    ( cen_cpu   ),      // 4x the E pin: 6 MHz -> 1.5 MHz, minus waits
    .irq    ( ~irq_n    ),
    .nmi    ( ~nmi_n    ),
    .opdec  ( 1'b0      ),
    .rd     ( cpu_rd    ),
    .wr     ( cpu_wr    ),
    .fetch  (           ),
    .addr   ( cpu_addr  ),
    .din    ( cpu_din   ),
    .dout   ( cpu_dout  )
);

// 2Kx8 5814 (stadhero.cpp:29)
sh_ram8 #(.AW(11)) u_ram (
    .clk  ( clk               ),
    .addr ( cpu_addr[10:0]    ),
    .data ( cpu_dout          ),
    .we   ( ram_cs & cpu_wr   ),
    .q    ( ram_q             )
);

// ---------------------------------------------------------------- YM2203
wire signed [15:0] opn_fm;
wire        [9:0]  opn_psg;

jt03 u_opn (
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen_opn   ),
    .din        ( cpu_dout  ),
    .addr       ( cpu_addr[0] ),
    .cs_n       ( ~opn_cs   ),
    .wr_n       ( cpu_rnw   ),
    .dout       ( opn_dout  ),
    .irq_n      ( opn_irq_n ),
    .IOA_in     ( 8'd0      ),
    .IOB_in     ( 8'd0      ),
    .IOA_out    (           ),
    .IOB_out    (           ),
    .IOA_oe     (           ),
    .IOB_oe     (           ),
    .debug_view (           ),
    .psg_A      (           ),
    .psg_B      (           ),
    .psg_C      (           ),
    .fm_snd     ( opn_fm    ),
    .psg_snd    ( opn_psg   ),
    .snd        (           ),
    .snd_sample (           )
);

// ---------------------------------------------------------------- YM3812
wire signed [15:0] opl_snd;

jtopl2 u_opl (
    .rst    ( rst         ),
    .clk    ( clk         ),
    .cen    ( cen_opl     ),
    .din    ( cpu_dout    ),
    .addr   ( cpu_addr[0] ),
    .cs_n   ( ~opl_cs     ),
    .wr_n   ( cpu_rnw     ),
    .dout   ( opl_dout    ),
    .irq_n  ( opl_irq_n   ),
    .snd    ( opl_snd     ),
    .sample (             )
);

// ----------------------------------------------------------------- M6295
//  pin 7 HIGH -> sample rate = clock / 132 = 8 kHz (stadhero.cpp:412).
//  jt6295 divides internally, so it is handed the 1.056 MHz chip clock.
//
//  INTERPOL is 0.  jt6295_acc.v:33 says "0 = no interpolator (recommended if
//  there's already [one downstream])", and MiSTer's framework filters the audio
//  on the way out, so the chip's own 4x upsampler would be a second filter
//  doing the same job.  It also pulls in jtframe_fir_mono, which is the one
//  jtframe module the whole vendored sound chain would otherwise need.
wire signed [13:0] pcm_snd;
wire               oki_wr_n = inj_busy ? inj_wrn : ~(oki_cs & cpu_wr);

assign pcm_cs = 1'b1;

// ------------------------------------------------ the calibration injector
//  Every ~2.2 s: latch phrase 8, then start it on channel 2 at attenuation 0.
//  Phrase 8 is one of the four the board was reported to be missing, and
//  channel 2 is the one they all use (dist/oki_all.csv).
localparam [6:0] TEST_PHRASE = 7'd8;
localparam [3:0] TEST_MASK   = 4'b0100;

reg [26:0] inj_div;
reg [2:0]  inj_st;
reg        inj_wrn;
reg [7:0]  inj_din;

always @(posedge clk) begin
    if (rst || !oki_test) begin
        inj_div <= 27'd0;
        inj_st  <= 3'd0;
        inj_wrn <= 1'b1;
        inj_din <= 8'd0;
    end else begin
        inj_div <= inj_div + 27'd1;
        if (inj_st == 3'd0) begin
            if (&inj_div) inj_st <= 3'd1;      // ~2.2 s at 60 MHz
        end else if (inj_div[8:0] == 9'd0) begin
            // one step every 512 clocks, comfortably longer than jt6295's
            // negedge_wrn detection needs
            case (inj_st)
                3'd1: begin inj_din <= { 1'b1, TEST_PHRASE }; inj_wrn <= 1'b0; end
                3'd2: inj_wrn <= 1'b1;
                3'd3: begin inj_din <= { TEST_MASK, 4'd0 };   inj_wrn <= 1'b0; end
                3'd4: inj_wrn <= 1'b1;
                default: ;
            endcase
            inj_st <= (inj_st == 3'd5) ? 3'd0 : inj_st + 3'd1;
        end
    end
end

wire inj_busy = oki_test && (inj_st != 3'd0);

// The START of the pair carries the attenuation in [3:0]; oki_pend marks it.
wire [7:0] oki_din = inj_busy ? inj_din
                   : (oki_full && oki_pend && !cpu_dout[7])
                   ? { cpu_dout[7:4], 4'd0 } : cpu_dout;

jt6295 #(.INTERPOL(0)) u_oki (
    .rst      ( rst       ),
    .clk      ( clk       ),
    .cen      ( cen_oki   ),
    .ss       ( 1'b1      ),          // pin 7 HIGH
    .wrn      ( oki_wr_n  ),
    .din      ( oki_din   ),
    .dout     ( oki_dout  ),
    .rom_addr ( pcm_addr  ),
    .rom_data ( pcm_data  ),
    .rom_ok   ( pcm_ok    ),
    .sound    ( pcm_snd   ),
    .sample   (           )
);

// ~57 Hz window, close enough to a frame and needing no video signal here.
reg [19:0] peak_div;
reg [13:0] peak_acc;
wire [13:0] pcm_abs = pcm_snd[13] ? (~pcm_snd + 14'd1) : pcm_snd;
always @(posedge clk) begin
    if (rst) begin
        peak_div     <= 20'd0;
        peak_acc     <= 14'd0;
        dbg_pcm_peak <= 8'd0;
    end else begin
        peak_div <= peak_div + 20'd1;
        if (&peak_div) begin
            dbg_pcm_peak <= peak_acc[13:6];
            peak_acc     <= 14'd0;
        end else if (pcm_abs > peak_acc) begin
            peak_acc <= pcm_abs;
        end
    end
end

reg [3:0] oki_busy_d;
integer   bi;
always @(posedge clk) begin
    if (rst) begin
        dbg_oki_chip2 <= 8'd0;
        dbg_oki_chall <= 8'd0;
        oki_busy_d    <= 4'd0;
    end else begin
        oki_busy_d <= oki_dout[3:0];
        if (oki_dout[2] && !oki_busy_d[2] && !(&dbg_oki_chip2))
            dbg_oki_chip2 <= dbg_oki_chip2 + 8'd1;
        // any channel, so the channel-2 ratio can be read against the whole
        if ((|(oki_dout[3:0] & ~oki_busy_d)) && !(&dbg_oki_chall))
            dbg_oki_chall <= dbg_oki_chall + 8'd1;
    end
end

assign dbg_cpu_acc = cpu_acc & cen_cpu;
assign dbg_opn_wr  = opn_cs & cpu_wr;
assign dbg_opl_wr  = opl_cs & cpu_wr;
assign dbg_oki_wr  = oki_cs & cpu_wr;

// The M6295 protocol: a write with bit 7 set latches the phrase number, the
// next write starts it with the channel mask in the high nibble.
reg oki_wr_d;
reg oki_pend;
always @(posedge clk) begin
    if (rst) begin
        dbg_oki_seen <= 8'd0;
        dbg_cpu_ch2  <= 8'd0;
        dbg_cpu_all  <= 8'd0;
        oki_pend     <= 1'b0;
        oki_wr_d     <= 1'b0;
    end else begin
        oki_wr_d <= oki_cs & cpu_wr;
        if ((oki_cs & cpu_wr) && !oki_wr_d) begin
            if (cpu_dout[7]) begin
                oki_pend <= 1'b1;
                if (cpu_dout[6:0] >= 7'd6 && cpu_dout[6:0] <= 7'd13)
                    dbg_oki_seen[cpu_dout[3:0] - 4'd6] <= 1'b1;
            end else if (oki_pend) begin
                // the START of the pair: mask in [7:4], attenuation in [3:0]
                oki_pend <= 1'b0;
                if (|cpu_dout[7:4]) begin
                    if (!(&dbg_cpu_all)) dbg_cpu_all <= dbg_cpu_all + 8'd1;
                    if (cpu_dout[6] && !(&dbg_cpu_ch2))
                        dbg_cpu_ch2 <= dbg_cpu_ch2 + 8'd1;
                end
            end
        end
    end
end
assign dbg_opl_irq = ~opl_irq_n;

// ------------------------------------------------------------------- mix
//  stadhero.cpp:402-413:
//      YM2203 FM  ch0-2  0.95      YM2203 SSG ch3  0.40
//      YM3812     all    0.80      M6295      all  0.80
//
//  The SSG at 0.40 against the FM's 0.95 is deliberate on this board, not a
//  rounding of "the same".  Gains are 8.8 fixed point: 0.95 -> 243,
//  0.80 -> 205, 0.40 -> 102.
sh_mixer u_mix (
    .clk     ( clk      ),
    .rst     ( rst      ),
    .opn_fm  ( opn_fm   ),
    .opn_psg ( opn_psg  ),
    .opl     ( opl_snd  ),
    .pcm     ( pcm_snd  ),
    .audio_sel ( audio_sel ),
    .dbg_peak_pcm ( dbg_peak_pcm ),
    .dbg_peak_opl ( dbg_peak_opl ),
    .dbg_peak_fm  ( dbg_peak_fm  ),
    .dbg_peak_ssg ( dbg_peak_ssg ),
    .snd     ( snd      )
);

endmodule

`default_nettype wire
