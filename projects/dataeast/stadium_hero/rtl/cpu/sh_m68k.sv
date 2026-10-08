//============================================================================
//  Stadium Hero -- 68000 wrapper around fx68k
//
//  Adapted from projects/vsystem/power_spikes/rtl/cpu/ps_m68k.sv, which is
//  itself from NA-1/NA-2.  The two-phase enable generation, the DTACK
//  handshake and the din_hold are unchanged: that code is verified on real
//  hardware in two families and root CLAUDE.md 1.3 says proven beats
//  theoretically nicer.  Reusing it is also the answer 1.2 asks for -- the
//  sibling lane is the first place to look, not the last.
//
//  What is different here:
//
//    * CLK_DIV is 6.  60 MHz / 6 = 10.000 MHz, this board's 68000 clock
//      (20 MHz XTAL / 2, stadhero.cpp:370, HW_CONFIRMED).
//    * IPL is driven from a single level-5 line held until acknowledged, so
//      unlike Power Spikes' irq1_line_hold this board does NOT clear on the
//      interrupt-acknowledge cycle -- it clears on a write to 0x30c004
//      (stadhero.cpp:211).  iack_stb is still exported for observability but
//      nothing on this board consumes it.
//
//  fx68k (third_party/cpu/fx68k/) is (c) 2018,2021 Jorge Cwik, GPLv3, copied from the
//  Power Spikes tree and carrying its one local additive change, the dbg_d7
//  port.  See docs/LICENSE_USAGE_REPORT.md.
//============================================================================
`default_nettype none

module sh_m68k #(
    // clk ticks per 68000 clock.  60 MHz / 6 = 10.000 MHz, HW_CONFIRMED.
    parameter int CLK_DIV = 6,
    // 68000 cycles between one that is a clk SHORT, modelling the PCB's two
    // separate crystals.  0 = the exact ratio this core had before.  See the
    // block comment below; 6510 is the PCB's own measured 25.6 ppm.
    parameter int SLIP    = 0
) (
    input  wire        clk,
    input  wire        rst,          // synchronous, active high
    input  wire        cpu_rst,      // hold the 68000 in reset (ROM download)
    input  wire        ce_en,        // global clock enable (pause / download)

    // --- simple synchronous bus ---------------------------------------------
    output wire [23:1] addr,
    output wire [15:0] dout,
    input  wire [15:0] din,
    output wire        rd,
    output wire        wr,
    output wire        uds_n,
    output wire        lds_n,
    input  wire        ack,

    input  wire [2:0]  ipl_n,

    // --- observability -------------------------------------------------------
    output wire [2:0]  fc,
    output wire        iack_stb,
    output wire [31:0] dbg_d7,
    output wire        as_n,
    output wire        halted_n,
    // The 68000's own clock, one pulse per bus clock.  Counting it against
    // the frame is how the board says whether the enable really is 10 MHz --
    // in simulation it is 174,079 a frame and that is a derived number until
    // hardware has said the same.
    output wire        dbg_phi1
);

  // Two-phase clock enables, one enPhi1 and one enPhi2 per 68000 clock, half a
  // clock apart.
  //
  // ---- SLIP: the 68000 is on the OTHER crystal ---------------------------
  //
  // DE-0303-3 clocks the 68000 from a 20 MHz crystal; DE-0304-3 clocks the
  // video and the sound chips from a 24 MHz one.  Two independent oscillators.
  // This core divides both from one 60 MHz PLL, which makes the ratio EXACT:
  // 640.000 68000 cycles a scanline, 272 lines, 174,080 cycles a frame with no
  // remainder anywhere.
  //
  // For most of a board that is a free simplification and it is why D1 chose
  // it.  Here it is not, because the game has no random number generator: it
  // reads the raster counter at 0x30c003 and uses that as one.  With an exact
  // ratio the code asks at the same cycle offset every frame and gets the same
  // raster position every frame -- MEASURED, on hardware and in simulation:
  // nine distinct values in 289 reads at 0x00AC10, and 96.6 % of them just
  // three, cycling 105, 107, 108 forever (DEBUG_LOG O11).  MAME spreads over
  // all sixteen low nibbles.  The fielders' wait is 64 + that low nibble, so
  // ours is stuck long and theirs is not.
  //
  // Two crystals cannot do that.  Nominally 20 and 24 MHz are 5:6 and the lock
  // would exist on the PCB too, but real crystals are not nominal and the PCB
  // says by how much: Guru measured HSync at 15.6246 kHz where an exact 24 MHz
  // gives 15.6250 -- 25.6 ppm apart.  On the real board the read point walks
  // about 2.7 pixels a frame and sweeps the whole line in 2.5 seconds.
  //
  // SLIP reproduces that by making one 68000 cycle in SLIP one clk short.
  // 25.6 ppm is one in 6510.  It costs one counter, no second PLL and no clock
  // domain crossing -- root CLAUDE.md 1.5 -- and it moves the CPU by 26 parts
  // per million: 6694 polls a frame becomes 6694.17.
  //
  // SLIP = 0 restores the exact ratio.  Which crystal is the fast one is not
  // knowable and does not matter; only the difference between them does.
  localparam int HALF = CLK_DIV / 2;
  reg [$clog2(CLK_DIV)-1:0] div;
  reg [12:0] slip;
  wire slip_now  = (SLIP != 0) && (slip == SLIP[12:0] - 13'd1);
  wire div_last  = (div == CLK_DIV - 1) || (slip_now && (div == CLK_DIV - 2));
  wire en_phi1 = ce_en && (div == 0);
  wire en_phi2 = ce_en && (div == HALF);

  always @(posedge clk) begin
    if (rst) begin
      div  <= '0;
      slip <= '0;
    end else if (ce_en) begin
      if (div_last) begin
        div  <= '0;
        slip <= slip_now ? 13'd0 : slip + 13'd1;
      end else begin
        div <= div + 1'b1;
      end
    end
  end

  assign dbg_phi1 = en_phi1;

  wire        cpu_as_n, cpu_lds_n, cpu_uds_n, cpu_rw_n;
  wire [15:0] cpu_dout;
  wire [23:1] cpu_addr;
  wire        fc0, fc1, fc2;
  wire        vma_n, e_clk;

  reg         dtack_n;
  reg  [15:0] din_hold;

  // Autovector every interrupt.  This board has no vector generator: the only
  // interrupt is IRQ5 from vblank and it uses the autovector at 0x74.
  wire iack  = (fc2 & fc1 & fc0);
  wire vpa_n = ~(iack & ~cpu_as_n);

  fx68k u_fx68k (
      .clk       (clk),
      .HALTn     (1'b1),
      .extReset  (rst | cpu_rst),
      .pwrUp     (rst),
      .enPhi1    (en_phi1),
      .enPhi2    (en_phi2),

      .dbg_d7    (dbg_d7),
      .eRWn      (cpu_rw_n),
      .ASn       (cpu_as_n),
      .LDSn      (cpu_lds_n),
      .UDSn      (cpu_uds_n),
      .E         (e_clk),
      .VMAn      (vma_n),

      .FC0       (fc0),
      .FC1       (fc1),
      .FC2       (fc2),
      .BGn       (),
      .oRESETn   (),
      .oHALTEDn  (halted_n),

      .DTACKn    (dtack_n),
      .VPAn      (vpa_n),
      .BERRn     (1'b1),
      .BRn       (1'b1),
      .BGACKn    (1'b1),

      .IPL0n     (ipl_n[0]),
      .IPL1n     (ipl_n[1]),
      .IPL2n     (ipl_n[2]),

      .iEdb      (din_hold),
      .oEdb      (cpu_dout),
      .eab       (cpu_addr)
  );

  wire cyc = ~cpu_as_n & ~(cpu_lds_n & cpu_uds_n) & ~iack;
  reg  done;

  // The system side only guarantees din in the cycle where ack is high, but
  // fx68k samples its external data bus later, on an enabled Phi2 edge.  Hold
  // the acknowledged word until the next read completes.
  always @(posedge clk) begin
    if (rst | cpu_rst)  din_hold <= 16'hFFFF;
    else if (ack && rd) din_hold <= din;
  end

  always @(posedge clk) begin
    if (rst | cpu_rst) begin
      done    <= 1'b0;
      dtack_n <= 1'b1;
    end else if (!cyc) begin
      done    <= 1'b0;
      dtack_n <= 1'b1;
    end else if (ack) begin
      done    <= 1'b1;
      dtack_n <= 1'b0;
    end
  end

  assign rd       = cyc & ~done &  cpu_rw_n;
  assign wr       = cyc & ~done & ~cpu_rw_n;
  assign addr     = cpu_addr;
  assign dout     = cpu_dout;
  assign uds_n    = cpu_uds_n;
  assign lds_n    = cpu_lds_n;
  assign as_n     = cpu_as_n;
  assign fc       = {fc2, fc1, fc0};
  assign iack_stb = iack & ~cpu_as_n;

endmodule

`default_nettype wire
