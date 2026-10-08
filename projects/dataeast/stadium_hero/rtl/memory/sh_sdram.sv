//============================================================================
//  Stadium Hero -- SDRAM controller for the MiSTer SDRAM module
//
//  Copied from projects/vsystem/power_spikes/rtl/memory/ps_sdram.sv, which is
//  running on hardware.  Root CLAUDE.md 1.3: proven beats theoretically nicer,
//  and a memory controller is exactly the kind of timing-bearing code 1.5 says
//  not to rewrite for tidiness.  What changed is the clock and the refresh
//  interval; the state machine is untouched.
//
//  Single port, one 16-bit word per transaction, auto-precharge, CAS latency 2.
//
//  Interface matches sh_top's `mem_*` port exactly, so a behavioural model and
//  this controller are drop-in equivalents:
//      req    held high until ack
//      ack    one clock, read data valid in the same clock
//      addr   WORD address (sh_romarb.sv shifts the byte map down by one)
//
//  A write with ds != 2'b11 costs two transactions rather than one: the board
//  does not honour DQM, so byte writes are read-modify-write.  Nothing in
//  Stadium Hero writes to SDRAM after the download, which writes full words.
//
//  ---- budget at 60 MHz ----------------------------------------------------
//  This controller delivers roughly one access every 8 clocks, so about
//  7.5 M/s.  What the board asks for per frame, from the numbers in
//  sh_romarb.sv's header:
//
//      graphics   224 fetches/line x 2 accesses x 240 lines   = 107 k
//      68000      one bus cycle per 16 clocks at worst        =  ~10 k
//      sound      65C02 at 1.5 MHz, plus 8 kHz of ADPCM       =   ~7 k
//                                                   ~124 k/frame
//      x 57.44 Hz                                    ~7.1 M/s
//
//  That is close enough to the ceiling to be worth measuring rather than
//  trusting: the graphics figure is the WORST case (48 sprite tiles on every
//  line, which no real frame does), but if the picture ever tears under load
//  this is the first number to instrument, not the last.  Page-mode bursts
//  would roughly halve the graphics cost and fit behind the same interface.
//
//  Timing at 60.000 MHz (tCK = 16.67 ns), for the -6A/-7 parts on the MiSTer
//  SDRAM boards:
//      tRCD >= 18 ns  -> 2 clock periods between the ACTIVE and READ sampling
//                        edges (S_RCD is one WAIT state, not the interval) = 33.3 ns
//      tRP  >= 18 ns  -> covered by auto-precharge plus the S_IDLE timer
//      tRC  >= 60 ns  -> 4 clocks   (enforced by the state machine length)
//      tREF =  64 ms / 8192 rows -> one AUTO REFRESH every 7.8 us
//               = every 468 clocks; 420 is used, to keep the same ~10% margin
//               Power Spikes uses at 40 MHz
//      CL   =  2
//
//  Address mapping: {row[12:0], bank[1:0], col[9:0]} so that sequential words
//  stay inside one row for as long as possible -- which is what a graphics
//  fetch's two halves and the 68000's prefetch both do.
//============================================================================
`default_nettype none

module sh_sdram #(
    parameter int CLK_HZ      = 60_000_000,
    parameter int INIT_US     = 200,        // power-up wait
    parameter int REFRESH_CLK = 420         // clocks between AUTO REFRESH
) (
    input  wire        clk,          // SDRAM clock (same domain as the core)
    input  wire        init,         // hold high to (re)run the init sequence

    // --- request port -------------------------------------------------------
    input  wire [24:0] addr,         // word address
    input  wire [15:0] din,
    output reg  [15:0] dout,
    input  wire        req,
    input  wire        we,
    input  wire [1:0]  ds,           // {upper byte, lower byte}
    output reg         ack,

    // --- SDRAM pins ---------------------------------------------------------
    output reg  [12:0] SDRAM_A,
    output reg  [1:0]  SDRAM_BA,
    inout  wire [15:0] SDRAM_DQ,
    output reg         SDRAM_DQML,
    output reg         SDRAM_DQMH,
    output wire        SDRAM_nCS,
    output reg         SDRAM_nWE,
    output reg         SDRAM_nRAS,
    output reg         SDRAM_nCAS,
    output reg         SDRAM_CKE
);

  localparam int INIT_CLKS = (CLK_HZ / 1_000_000) * INIT_US;   // ~10000

  // command encoding {nRAS, nCAS, nWE}
  localparam [2:0] CMD_NOP        = 3'b111,
                   CMD_ACTIVE     = 3'b011,
                   CMD_READ       = 3'b101,
                   CMD_WRITE      = 3'b100,
                   CMD_PRECHARGE  = 3'b010,
                   CMD_REFRESH    = 3'b001,
                   CMD_LOADMODE   = 3'b000;

  // Mode register: burst length 1, sequential, CAS latency 2, single write
  localparam [12:0] MODE = 13'b000_0_00_010_0_000;

  assign SDRAM_nCS = 1'b0;          // always selected

  // ---- bidirectional data bus -------------------------------------------
  reg        dq_oe;
  reg [15:0] dq_out;
  assign SDRAM_DQ = dq_oe ? dq_out : 16'hZZZZ;

  // ---- address decomposition --------------------------------------------
  wire [9:0]  a_col  = addr[9:0];
  wire [1:0]  a_bank = addr[11:10];
  wire [12:0] a_row  = addr[24:12];

  // ---- sequencer ---------------------------------------------------------
  localparam S_INIT       = 4'd0,
             S_INIT_PRE   = 4'd1,
             S_INIT_REF1  = 4'd2,
             S_INIT_REF2  = 4'd3,
             S_INIT_MODE  = 4'd4,
             S_IDLE       = 4'd5,
             S_ACTIVE     = 4'd6,
             S_RCD        = 4'd7,
             S_CMD        = 4'd8,
             S_CL1        = 4'd9,
             S_CL2        = 4'd10,
             S_CL3        = 4'd11,
             S_REFRESH    = 4'd12,
             S_REF_WAIT   = 4'd13;

  reg [3:0]  st;
  reg [15:0] timer;
  reg [9:0]  ref_cnt;
  reg        ref_due;
  reg        rd_pending;

  // ---- read-modify-write for byte writes --------------------------------
  // On the DE10-Nano this core runs on, DQM is not honoured on writes.
  //
  // INHERITED EVIDENCE, not measured by this project: the NA-1/NA-2 project
  // established it on the same physical machine.  Its na2_membus self-test
  // wrote 0x0000 as a word, then 0x00A5 with ds=01, then 0x5A00 with ds=10,
  // and read back 0x5A00 -- 256 byte writes, 256 mismatches, while the same
  // 256 word writes read back clean.  Every write puts both bytes down.
  //             HW_CONFIRMED for that board; assumed to hold for this one
  //             because it is the same board.  Re-measure before trusting it
  //             on any other MiSTer.
  //
  // Power Spikes needs this for the same reason NA-2 did: the 68000 writes
  // bytes into work RAM, and work RAM is not in SDRAM here -- but the sprite
  // lookup RAM and palette are byte-writable too, and any region that ever
  // moves to SDRAM inherits the problem.  Keeping RMW costs one extra
  // transaction on byte writes only.
  //
  // So a write whose ds is not 2'b11 becomes read-modify-write: read the word,
  // merge the enabled lanes, write the whole word back with both DQM low.
  // That is correct whether or not DQM is wired, and it costs one extra
  // transaction on byte writes only.  Per-lane DQM is still driven, so if the
  // board turns out to be fine nothing about the full-word path changes.
  reg        rmw_rd;      // the read in flight is the R half of a byte write
  reg        rmw_wr;      // the next access is the W half of a byte write
  reg [15:0] rmw_data;    // merged word waiting to go back

  wire       byte_wr = we & (ds != 2'b11);

  task automatic cmd(input [2:0] c);
    begin
      SDRAM_nRAS <= c[2];
      SDRAM_nCAS <= c[1];
      SDRAM_nWE  <= c[0];
    end
  endtask

  always @(posedge clk) begin
    // defaults every clock
    cmd(CMD_NOP);
    ack   <= 1'b0;
    dq_oe <= 1'b0;

    // refresh timer runs regardless of state
    if (ref_cnt == REFRESH_CLK[9:0]) begin
      ref_cnt <= 10'd0;
      ref_due <= 1'b1;
    end else
      ref_cnt <= ref_cnt + 10'd1;

    if (init) begin
      st         <= S_INIT;
      timer      <= INIT_CLKS[15:0];
      ref_cnt    <= 10'd0;
      ref_due    <= 1'b0;
      rd_pending <= 1'b0;
      rmw_rd     <= 1'b0;
      rmw_wr     <= 1'b0;
      SDRAM_CKE  <= 1'b1;
      SDRAM_DQML <= 1'b1;
      SDRAM_DQMH <= 1'b1;
      SDRAM_A    <= 13'd0;
      SDRAM_BA   <= 2'd0;
    end else begin
      case (st)
        // ---------------- power-up sequence ----------------------------
        S_INIT: begin
          if (timer == 0) st <= S_INIT_PRE;
          else            timer <= timer - 16'd1;
        end
        S_INIT_PRE: begin
          cmd(CMD_PRECHARGE);
          SDRAM_A[10] <= 1'b1;              // all banks
          timer       <= 16'd4;
          st          <= S_INIT_REF1;
        end
        S_INIT_REF1: begin
          if (timer == 0) begin cmd(CMD_REFRESH); timer <= 16'd8; st <= S_INIT_REF2; end
          else timer <= timer - 16'd1;
        end
        S_INIT_REF2: begin
          if (timer == 0) begin cmd(CMD_REFRESH); timer <= 16'd8; st <= S_INIT_MODE; end
          else timer <= timer - 16'd1;
        end
        S_INIT_MODE: begin
          if (timer == 0) begin
            cmd(CMD_LOADMODE);
            SDRAM_A  <= MODE;
            SDRAM_BA <= 2'd0;
            timer    <= 16'd4;
            st       <= S_IDLE;
          end else timer <= timer - 16'd1;
        end

        // ---------------- idle -----------------------------------------
        S_IDLE: begin
          SDRAM_DQML <= 1'b1;
          SDRAM_DQMH <= 1'b1;
          if (timer != 0) begin
            timer <= timer - 16'd1;         // honour tRC after the last access
          end else if (ref_due) begin
            ref_due <= 1'b0;
            cmd(CMD_REFRESH);
            timer   <= 16'd6;               // tRFC
            st      <= S_REF_WAIT;
          end else if (req) begin
            cmd(CMD_ACTIVE);
            SDRAM_A    <= a_row;
            SDRAM_BA   <= a_bank;
            // a byte write reads first; rmw_wr marks the write-back half, and
            // a refresh is free to slip in between the two -- req is held by
            // the same master until ack, so nothing else can take the bus.
            rd_pending <= rmw_wr ? 1'b0 : (~we | byte_wr);
            rmw_rd     <= rmw_wr ? 1'b0 : byte_wr;
            st         <= S_RCD;
          end
        end

        S_REF_WAIT: begin
          if (timer == 0) st <= S_IDLE;
          else            timer <= timer - 16'd1;
        end

        // ---------------- one access -----------------------------------
        S_RCD: st <= S_CMD;                 // tRCD = 1 clock

        S_CMD: begin
          // A10 = 1 selects auto precharge, so no explicit PRECHARGE is needed
          SDRAM_A <= {2'b00, 1'b1, a_col};
          if (rd_pending) begin
            cmd(CMD_READ);
            SDRAM_DQML <= 1'b0;
            SDRAM_DQMH <= 1'b0;
            st         <= S_CL1;
          end else begin
            cmd(CMD_WRITE);
            dq_oe      <= 1'b1;
            // the write-back half of a byte write already holds a merged word,
            // so it goes down whole and does not depend on DQM at all
            dq_out     <= rmw_wr ? rmw_data : din;
            SDRAM_DQML <= rmw_wr ? 1'b0 : ~ds[0];   // DQM high masks the byte
            SDRAM_DQMH <= rmw_wr ? 1'b0 : ~ds[1];
            rmw_wr     <= 1'b0;
            ack        <= 1'b1;             // writes complete immediately
            timer      <= 16'd2;            // keep tRC clear before the next ACTIVE
            st         <= S_IDLE;
          end
        end

        // Read data return.  Count the clocks rather than trusting CL=2 to mean
        // "sample two states later", because it does not:
        //
        //   cycle N    st = S_CMD                     READ registered
        //   cycle N+1  READ on the pins;  the SDRAM samples it half a period
        //              in (SDRAM_CLK is 180 degrees out), so the part's command
        //              edge is at N+1.5
        //   N+3.5      CL=2 later the part starts driving DQ; tAC is measured
        //              from this edge, and DQ is held until N+4.5
        //   N+4.0      the only core clock edge inside that window
        //
        // so the latch has to be three states after S_CMD, not two.  It used to
        // be two and sim/tb_na2_sdram.sv reads back high-Z on every access --
        // the whole 68000 program ROM.  Nothing in a fitter run or in the boot
        // testbench (which swaps in a behavioural memory) can see this.
        S_CL1: st <= S_CL2;
        S_CL2: st <= S_CL3;
        S_CL3: begin
          if (rmw_rd) begin
            // R half of a byte write: merge, then go round again as a write.
            // No ack -- the caller sees one transaction.
            rmw_data <= {ds[1] ? din[15:8] : SDRAM_DQ[15:8],
                         ds[0] ? din[7:0]  : SDRAM_DQ[7:0]};
            rmw_rd   <= 1'b0;
            rmw_wr   <= 1'b1;
          end else begin
            dout <= SDRAM_DQ;
            ack  <= 1'b1;
          end
          timer <= 16'd1;
          st    <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
