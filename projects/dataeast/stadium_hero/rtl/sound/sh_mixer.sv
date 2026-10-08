//============================================================================
//  Stadium Hero -- audio mixer
//
//  stadhero.cpp:402-413 is the whole specification:
//
//      YM2203  ch0 0.95  ch1 0.95  ch2 0.95      the three SSG voices
//      YM2203  ch3 0.40                          the FM section
//      YM3812  all 0.80
//      M6295   all 0.80
//
//  ---- which stream is which, and why this was wrong once ------------------
//  The first version of this file read those four routes as "FM at 0.95, SSG
//  at 0.40" -- the intuitive reading, and backwards.
//
//  `ym2203_device` derives from `ymfm_ssg_device_base`, whose
//  `sound_stream_update` says so in as many words
//  (src/devices/sound/ymfm_mame.h:307):
//
//      // ymfm outputs FM first, then SSG, while MAME traditionally
//      // wants SSG streams first; to do this, we rotate the outputs
//      // by the number of SSG output channels
//      parent::update_internal(stream, ChipClass::SSG_OUTPUTS);
//
//  With OUTPUTS = 4 and SSG_OUTPUTS = 3, `eff_outnum = (outnum + 3) % 4` sends
//  ymfm's FM (its output 0) to MAME stream 3 and the three SSG channels to
//  streams 0, 1, 2.  So the driver's three 0.95 routes are the SSG and the
//  lone 0.40 is the FM.
//
//  FBNeo confirms it independently, with its own scaling but the same ordering
//  (d_stadhero.cpp:415-418):
//
//      BurnYM2203SetRoute(0, BURN_SND_YM2203_YM2203_ROUTE,   0.30, ...)  FM
//      BurnYM2203SetRoute(0, BURN_SND_YM2203_AY8910_ROUTE_1, 0.43, ...)  SSG A
//      BurnYM2203SetRoute(0, BURN_SND_YM2203_AY8910_ROUTE_2, 0.43, ...)  SSG B
//      BurnYM2203SetRoute(0, BURN_SND_YM2203_AY8910_ROUTE_3, 0.43, ...)  SSG C
//
//  Two emulators, both louder on the SSG than on the FM.  Root CLAUDE.md 12.0:
//  when they agree it is a hardware fact.  (FBNeo read for facts only; no code
//  from it is here.)
//
//  jt03's `psg_snd` is already the SUM of the three SSG channels, so one 0.95
//  applied to that sum is what MAME's three separate 0.95 routes come to.
//
//  Gains are 8.8 fixed point:  0.95 -> 243,  0.80 -> 205,  0.40 -> 102.
//
//  jt03 already sums its three FM channels into fm_snd, so the per-channel
//  0.95 applies to that sum.  psg_snd is the SSG's 10-bit unsigned output.
//
//  Headroom: the four sources are scaled to a little under half scale each
//  before the sum, so the worst case cannot clip.  A saturating stage would be
//  the alternative; this board never gets close enough to need one, and a
//  saturator that never fires is untested logic.
//============================================================================
`default_nettype none

module sh_mixer (
    input  wire               clk,
    input  wire               rst,

    input  wire signed [15:0] opn_fm,     // YM2203 FM, signed
    input  wire        [9:0]  opn_psg,    // YM2203 SSG, unsigned
    input  wire signed [15:0] opl,        // YM3812
    input  wire signed [13:0] pcm,        // M6295

    // Solo one source.  "The safe/out voices do not play" got as far as the
    // instruments can take it -- the sound CPU asks for those phrases, the
    // channel-2 starts happen, the sample ROM is fetched twenty thousand times
    // a second -- and the next question is whether they are AUDIBLE, which
    // only an ear can answer.  This makes that a ten-second test instead of a
    // build.
    //   0 everything   1 M6295 only   2 YM2203 only   3 YM3812 only
    input  wire        [1:0]  audio_sel,

    output reg  signed [15:0] snd,

    // Peak of each source over ~one frame, as it stands AFTER its gain -- so
    // these four numbers are the mix balance itself, not the raw chip outputs.
    //
    // "Is the M6295 audible against the music" was the last question left, and
    // it was called an ear-only question.  It is not: the mixer is a pure
    // function of four inputs and four constants, so the balance can simply be
    // measured.  MAME's routing says SSG 0.95, FM 0.40, YM3812 0.80, M6295
    // 0.80 (stadhero.cpp:403-413), and these say what the board actually does.
    output reg  [7:0]  dbg_peak_pcm,
    output reg  [7:0]  dbg_peak_opl,
    output reg  [7:0]  dbg_peak_fm,
    output reg  [7:0]  dbg_peak_ssg
);

//  ---- the M6295's gain is CALIBRATED, not taken from the driver ----------
//  MAME's routing says 0.80 for the M6295 and this used to be 205, the same
//  8.8 constant as the YM3812.  That assumes the two chip MODELS put out the
//  same scale for the same commands, and they do not.
//
//  Measured with both sides forced to attenuation 0 (board O[18], MAME the
//  same nibble rewrite), DEBUG_LOG O4:
//
//      board  M6295 peak   2048 of 32767   =  6.2 % of full scale
//      MAME   music alone 17981            = 54.9 %
//      MAME   full mix    32768, clipped   -> M6295 contributed >= 14787
//
//  So jt6295 was landing at least 7x -- 17 dB -- below where MAME's okim6295
//  lands for the same sample at the same volume, and the safe/out calls were
//  inaudible under the music because of it.  1476 = 205 * 7.2 closes it.
localparam signed [12:0] G_FM  = 13'sd102;   // 0.40 -- MAME stream 3
localparam signed [12:0] G_SSG = 13'sd243;   // 0.95 -- MAME streams 0, 1, 2
localparam signed [12:0] G_OPL = 13'sd205;   // 0.80
localparam signed [12:0] G_PCM = 13'sd1476;  // 0.80, x7.2 for jt6295's scale

// The SSG is unsigned around mid-scale; centre it before it is scaled.
wire signed [10:0] psg_s = $signed({1'b0, opn_psg}) - 11'sd512;

// Widen every source to a common 16-bit signed scale first.  The M6295 is
// 14-bit and the SSG 10-bit, so they are shifted up rather than left small and
// then drowned by the 16-bit FM.
wire signed [15:0] pcm_s = { pcm, 2'b00 };
wire signed [15:0] ssg_s = { psg_s, 5'b00000 };

//  Wider than before: the M6295's gain is now seven times larger, so the worst
//  case sum no longer fits 26 bits.  16 x 13 = 29 per product, four of them
//  needs 31.
reg signed [30:0] acc;

//  And the output SATURATES.  The old code could not overflow and said so; it
//  can now -- jt6295 at four channels, attenuation 0 and full-range ADPCM
//  would reach 48 M on its own -- so the clamp is reachable logic rather than
//  the untested kind, and sim/tb_mixer.sv drives it.
wire signed [20:0] mixed = acc[30:10];

always @(posedge clk) begin
    if (rst) begin
        acc <= 26'sd0;
        snd <= 16'sd0;
    end else begin
        case (audio_sel)
            2'd1: acc <=  pcm_s * G_PCM;
            2'd2: acc <= (opn_fm * G_FM) + (ssg_s * G_SSG);
            2'd3: acc <=  opl    * G_OPL;
            default: acc <= (opn_fm * G_FM) + (ssg_s * G_SSG) +
                            (opl    * G_OPL) + (pcm_s * G_PCM);
        endcase
        // >>> 10 undoes the 8.8 gains.  Clamp rather than wrap: a wrapped
        // overflow is a click, and a click is worse than a loud note.
        snd <= (mixed >  21'sd32767) ?  16'sh7FFF :
               (mixed < -21'sd32768) ? -16'sh8000 : mixed[15:0];
    end
end

// ------------------------------------------------------------ peak meters
//  Post-gain, so they are directly comparable with each other.  The window is
//  a free-running ~57 Hz counter rather than vblank: this module has no video
//  signal and does not need one to answer a question about ratios.
function [15:0] absv(input signed [30:0] v);
    reg signed [30:0] a;
begin
    a = v[25] ? -v : v;
    absv = a[25:10];        // same >>10 the accumulator uses
end
endfunction

wire [15:0] a_pcm = absv(pcm_s  * G_PCM);
wire [15:0] a_opl = absv(opl    * G_OPL);
wire [15:0] a_fm  = absv(opn_fm * G_FM);
wire [15:0] a_ssg = absv(ssg_s  * G_SSG);

reg [19:0] pk_div;
reg [15:0] pk_pcm, pk_opl, pk_fm, pk_ssg;
always @(posedge clk) begin
    if (rst) begin
        pk_div <= 20'd0;
        pk_pcm <= 0; pk_opl <= 0; pk_fm <= 0; pk_ssg <= 0;
        dbg_peak_pcm <= 0; dbg_peak_opl <= 0;
        dbg_peak_fm  <= 0; dbg_peak_ssg <= 0;
    end else begin
        pk_div <= pk_div + 20'd1;
        if (&pk_div) begin
            dbg_peak_pcm <= pk_pcm[15:8]; pk_pcm <= 0;
            dbg_peak_opl <= pk_opl[15:8]; pk_opl <= 0;
            dbg_peak_fm  <= pk_fm [15:8]; pk_fm  <= 0;
            dbg_peak_ssg <= pk_ssg[15:8]; pk_ssg <= 0;
        end else begin
            if (a_pcm > pk_pcm) pk_pcm <= a_pcm;
            if (a_opl > pk_opl) pk_opl <= a_opl;
            if (a_fm  > pk_fm ) pk_fm  <= a_fm;
            if (a_ssg > pk_ssg) pk_ssg <= a_ssg;
        end
    end
end

endmodule

`default_nettype wire
