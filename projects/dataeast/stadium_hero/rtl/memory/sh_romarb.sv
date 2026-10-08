//============================================================================
//  Stadium Hero -- ROM arbiter
//
//  Named for what it does.  The SDRAM controller that actually drives the
//  pins is sh_sdram.sv; this sits above it and decides who gets the bus.
//
//  Six readers, one 16-bit memory port.  The board owns this, not the
//  platform: root CLAUDE.md section 4 says the platform connection can be
//  adapted but arbitration, fetch and timing belong to the board.
//
//  ---- who waits for whom --------------------------------------------------
//  Priority is by DEADLINE, not by importance.
//
//  The three graphics fetchers have a hard budget: 32 tiles of background, up
//  to 48 sprite tiles and 32 characters, all inside one 384-pixel line.  At
//  60 MHz that is 3840 clocks for at most 224 32-bit fetches, so they need to
//  be served promptly but there is a great deal of slack.  What they cannot do
//  is wait indefinitely -- a missed fetch is a visibly wrong pixel.
//
//  The two CPUs can wait: the 68000 stalls on DTACK and the 65C02 on a gated
//  clock enable, and both lose only cycles.  The M6295 fetches one byte per
//  132 chip clocks and is the most patient reader on the board.
//
//  So: video first, then the 68000, then sound.  Round-robin among the video
//  ports so that a busy sprite line cannot starve the background.
//
//  ---- `ok` means "the data for THIS address is on the bus" ----------------
//  Not "a fetch completed at some point".  Each reader's address is latched
//  when its fetch starts, and `ok` is the AND of "a fetch finished" and "the
//  address still matches".  A reader that moves to a new address while its cs
//  stays high -- which is exactly what a CPU stepping through ROM does --
//  therefore sees ok fall immediately instead of latching the previous word.
//
//  This matters more here than it does upstream.  jtcop takes rom_ok into
//  jtcop_snd and never reads it (jtcop_snd.v:20 is the only occurrence): its
//  65C02 assumes memory answers inside one clock enable.  jt65c02 has no wait
//  input, so if that assumption breaks the CPU latches whatever happens to be
//  on the bus and there is no error, just wrong sound.  sh_snd.sv closes that
//  by gating the CPU's enable on this signal, which only works if `ok` is
//  address-qualified.
//
//  ---- widths ---------------------------------------------------------------
//  The graphics ports want 32 bits and the memory is 16, so each graphics
//  fetch is two consecutive reads of the LATCHED address.  `ok` rises only
//  when both halves are in, which lets the fetchers treat rom_data as atomic.
//
//  Sound ROM and ADPCM are byte readers on a 16-bit memory: one read, then the
//  half selected by the low address bit -- the EVEN address is the HIGH half,
//  because the download writes big-endian.
//
//  ---- byte order ----------------------------------------------------------
//  sh_download writes word W as { byte 2W, byte 2W+1 }: the even byte is in
//  [15:8].  Everything read here has to undo that to reach the plane order
//  sh_rommap.svh describes.  It is one swap in one place, and getting it wrong
//  permuted every graphics pixel and stopped the sound CPU booting.
//
//  ---- units ---------------------------------------------------------------
//  sh_rommap.svh is in BYTES, because that is the unit MAME's ROM regions and
//  the MRA are in and translating there would put the conversion somewhere
//  nobody looks.  The memory port is in WORDS, because the SDRAM is 16 bits
//  wide and a word address is what the controller and the downloader both
//  take.  The `>> 1` at the single point where mem_addr is assigned is the
//  whole of the conversion; every access is 16-bit aligned, and the byte
//  readers use bit 0 to pick a half before it is shifted away.
//============================================================================
`default_nettype none

module sh_romarb (
    input  wire        clk,
    input  wire        rst,

    // --- neutral memory port -------------------------------------------------
    output reg  [24:0] mem_addr,
    output wire [15:0] mem_din,
    input  wire [15:0] mem_dout,
    output reg         mem_req,
    output wire        mem_we,
    output wire [1:0]  mem_ds,
    input  wire        mem_ack,

    // --- download ------------------------------------------------------------
    input  wire        dl_active,
    input  wire [24:0] dl_addr,       // WORD address, like mem_addr
    input  wire [15:0] dl_data,
    input  wire        dl_req,
    output wire        dl_ack,

    // --- readers -------------------------------------------------------------
    input  wire        main_cs,
    input  wire [16:1] main_addr,
    output reg  [15:0] main_data,
    output wire        main_ok,

    input  wire        snd_cs,
    input  wire [14:0] snd_addr,
    output reg  [7:0]  snd_data,
    output wire        snd_ok,

    input  wire        pcm_cs,
    input  wire [17:0] pcm_addr,
    output reg  [7:0]  pcm_data,
    output wire        pcm_ok,

    // Free-running count of COMPLETED M6295 fetches, high byte.  jt6295 does
    // not wait on rom_ok for ADPCM data (jt6295_rom.v:22) -- it assumes the
    // byte is there one cen32 later -- so "is the sample data arriving at all"
    // is not answerable from the sound chip's own signals.
    output wire [7:0]  dbg_pcm_cnt,

    input  wire        char_cs,
    input  wire [14:0] char_addr,
    output reg  [31:0] char_data,
    output wire        char_ok,

    input  wire        tile_cs,
    input  wire [16:0] tile_addr,
    output reg  [31:0] tile_data,
    output wire        tile_ok,

    input  wire        obj_cs,
    input  wire [16:0] obj_addr,
    output reg  [31:0] obj_data,
    output wire        obj_ok
);

`include "sh_rommap.svh"

// Downloading is a straight pass-through: the target owns the bus until it is
// finished, and no reader is running because the CPUs are held in reset.
assign mem_we  = dl_active & dl_req;
assign mem_din = dl_data;
assign mem_ds  = 2'b11;
assign dl_ack  = dl_active & mem_ack;

localparam [2:0] SEL_NONE = 3'd0,
                 SEL_TILE = 3'd1,
                 SEL_OBJ  = 3'd2,
                 SEL_CHAR = 3'd3,
                 SEL_MAIN = 3'd4,
                 SEL_SND  = 3'd5,
                 SEL_PCM  = 3'd6;

reg [2:0] sel;          // who is being served
reg       half;         // second 16-bit half of a 32-bit fetch
reg [1:0] rr;           // round-robin pointer among the video ports

// The address each reader asked for when its fetch started, and whether that
// fetch has completed.  `ok` is the two together -- see the header.
reg [16:1] main_lat;  reg main_done;
reg [14:0] snd_lat;   reg snd_done;
reg [17:0] pcm_lat;   reg pcm_done;
reg [14:0] char_lat;  reg char_done;
reg [16:0] tile_lat;  reg tile_done;
reg [16:0] obj_lat;   reg obj_done;

assign main_ok = main_done & (main_lat == main_addr);
assign snd_ok  = snd_done  & (snd_lat  == snd_addr );
assign pcm_ok  = pcm_done  & (pcm_lat  == pcm_addr );

reg [15:0] pcm_fetches;
reg        pcm_done_d;
always @(posedge clk) begin
    if (rst) begin
        pcm_fetches <= 16'd0;
        pcm_done_d  <= 1'b0;
    end else begin
        pcm_done_d <= pcm_done;
        if (pcm_done && !pcm_done_d) pcm_fetches <= pcm_fetches + 16'd1;
    end
end
assign dbg_pcm_cnt = pcm_fetches[15:8];
assign char_ok = char_done & (char_lat == char_addr);
assign tile_ok = tile_done & (tile_lat == tile_addr);
assign obj_ok  = obj_done  & (obj_lat  == obj_addr );

wire tile_pend = tile_cs & ~tile_ok;
wire obj_pend  = obj_cs  & ~obj_ok;
wire char_pend = char_cs & ~char_ok;
wire main_pend = main_cs & ~main_ok;
wire snd_pend  = snd_cs  & ~snd_ok;
wire pcm_pend  = pcm_cs  & ~pcm_ok;

// ---------------------------------------------------------------- transfers
//  ONE always block owns sel, half, the latched addresses, the done flags, the
//  captured data and the memory port.  An earlier revision split capture from
//  arbitration and both blocks assigned the done flags -- a multiple-driver
//  race that Icarus resolved differently run to run and Quartus would have
//  resolved silently.  The arbiter testbench caught it as a byte reader
//  returning the previous fetch's half; on hardware it would have been a
//  sound CPU executing a stale byte with no error anywhere.

// Byte addresses, built from the LATCHED address so a reader that changes its
// mind mid-fetch cannot redirect a transfer already under way.
wire [24:0] tile_byte = SH_TILE_BASE + { 6'd0,  tile_lat, half, 1'b0 };
wire [24:0] obj_byte  = SH_SPR_BASE  + { 6'd0,  obj_lat,  half, 1'b0 };
wire [24:0] char_byte = SH_CHAR_BASE + { 8'd0,  char_lat, half, 1'b0 };
wire [24:0] main_byte = SH_MAIN_BASE + { 8'd0,  main_lat, 1'b0 };
wire [24:0] snd_byte  = SH_SND_BASE  + { 10'd0, snd_lat  };
wire [24:0] pcm_byte  = SH_OKI_BASE  + { 7'd0,  pcm_lat  };

// Past the populated sample ROM.  See SEL_PCM below.
wire pcm_past_end = |pcm_lat[17:16];

always @(posedge clk) begin
    if (rst) begin
        sel       <= SEL_NONE;
        half      <= 1'b0;
        mem_req   <= 1'b0;
        mem_addr  <= 25'd0;
        rr        <= 2'd0;
        main_done <= 1'b0; snd_done  <= 1'b0; pcm_done <= 1'b0;
        char_done <= 1'b0; tile_done <= 1'b0; obj_done <= 1'b0;
    end else if (dl_active) begin
        sel      <= SEL_NONE;
        half     <= 1'b0;
        mem_req  <= dl_req;
        mem_addr <= dl_addr;
    end else if (sel == SEL_NONE) begin
        half <= 1'b0;
        // ---- the M6295 goes FIRST, and it is the only client that does ----
        //
        // Every other client waits on `ok` and simply stalls if this arbiter is
        // slow.  jt6295 does not: its ADPCM path takes whatever is on rom_data
        // one cen32 after presenting the address and never looks at rom_ok
        // (jt6295_rom.v:22), and its CONTROL path has to walk SIX sequential
        // byte reads -- start[17:16], [15:8], [7:0], stop[17:16], [15:8],
        // [7:0] -- each one waiting on rom_ok, before `start <= ch` finally
        // fires at st == 6 (jt6295_ctrl.v:138-160).  A sample that does not
        // finish that walk never starts at all.
        //
        // It was LAST here, behind three video fetchers and both CPUs.  On the
        // board the samples that go missing are 8, 9, 10 and 13 -- and MAME
        // says those are exactly the ones started on CHANNEL 2, which is to
        // say the ones asked for while channels 0 and 1 are already consuming
        // ADPCM slots.  That is when this arbiter is busiest and the six-byte
        // header walk has least room.
        //
        // Promoting it costs almost nothing: measured on the board, the OKI
        // completes about 20 300 fetches a second against the video's millions.
        // It is a latency client, not a bandwidth one, and it was queued as
        // though it were the other way round.
        if (pcm_pend) begin
            sel <= SEL_PCM;  pcm_lat  <= pcm_addr;  pcm_done  <= 1'b0;
        end
        // Video next, round-robin between the three so a busy sprite line
        // cannot starve the background.  Then the 68000, then sound.
        // Latching the address and clearing done happen together: an `ok` that
        // survived into a new fetch is the bug this block exists to prevent.
        else if (tile_pend && (rr == 2'd0 || !(obj_pend || char_pend))) begin
            sel <= SEL_TILE; tile_lat <= tile_addr; tile_done <= 1'b0; rr <= 2'd1;
        end else if (obj_pend && (rr == 2'd1 || !(tile_pend || char_pend))) begin
            sel <= SEL_OBJ;  obj_lat  <= obj_addr;  obj_done  <= 1'b0; rr <= 2'd2;
        end else if (char_pend) begin
            sel <= SEL_CHAR; char_lat <= char_addr; char_done <= 1'b0; rr <= 2'd0;
        end else if (tile_pend) begin
            sel <= SEL_TILE; tile_lat <= tile_addr; tile_done <= 1'b0; rr <= 2'd1;
        end else if (obj_pend) begin
            sel <= SEL_OBJ;  obj_lat  <= obj_addr;  obj_done  <= 1'b0; rr <= 2'd2;
        end else if (main_pend) begin
            sel <= SEL_MAIN; main_lat <= main_addr; main_done <= 1'b0;
        end else if (snd_pend) begin
            sel <= SEL_SND;  snd_lat  <= snd_addr;  snd_done  <= 1'b0;
        end
    end else if (!mem_req) begin
        // One cycle after selection the latched address has settled; request.
        mem_addr <= ((sel == SEL_TILE) ? tile_byte :
                     (sel == SEL_OBJ ) ? obj_byte  :
                     (sel == SEL_CHAR) ? char_byte :
                     (sel == SEL_MAIN) ? main_byte :
                     (sel == SEL_SND ) ? snd_byte  : pcm_byte) >> 1;
        mem_req  <= 1'b1;
    end else if (mem_ack) begin
        mem_req <= 1'b0;
        case (sel)
            // BYTE ORDER.  sh_download writes SDRAM words BIG-ENDIAN -- the
            // even byte lands in [15:8] (integration/sh_download.sv:109-112,
            // and Power Spikes' downloader does the same) -- so a word read
            // back is { byte 2W, byte 2W+1 }.  sh_rommap.svh wants plane0, the
            // pixel LSB, at the LOWEST byte address, which is [15:8] of the
            // word, not [7:0].
            //
            // The first version dropped mem_dout into the halves unswapped and
            // therefore assembled { plane2, plane3, plane0, plane1 }.  Every
            // graphics pixel came out with its bits permuted -- MAME's pixel 5
            // arrived as 10, 6 as 9, 4 as 8 -- so the 3bpp layers lost their
            // MSB entirely at the palette stage and the browns at palette
            // 518/519/532-534 became unreachable.  It also byte-swapped the
            // 65C02's reset vector, so the sound CPU never ran at all.
            SEL_TILE: if (half) begin tile_data[31:16] <= { mem_dout[7:0], mem_dout[15:8] }; tile_done <= 1'b1; end
                      else            tile_data[15:0]  <= { mem_dout[7:0], mem_dout[15:8] };
            SEL_OBJ:  if (half) begin obj_data[31:16]  <= { mem_dout[7:0], mem_dout[15:8] }; obj_done  <= 1'b1; end
                      else            obj_data[15:0]   <= { mem_dout[7:0], mem_dout[15:8] };
            SEL_CHAR: if (half) begin char_data[31:16] <= { mem_dout[7:0], mem_dout[15:8] }; char_done <= 1'b1; end
                      else            char_data[15:0]  <= { mem_dout[7:0], mem_dout[15:8] };
            // The 68000 wants the word exactly as written -- big-endian is its
            // own convention, which is why it booted correctly throughout.
            SEL_MAIN: begin main_data <= mem_dout; main_done <= 1'b1; end
            // Byte readers: the EVEN address is the high half.
            SEL_SND:  begin
                snd_data <= snd_lat[0] ? mem_dout[7:0] : mem_dout[15:8];
                snd_done <= 1'b1;
            end
            // The M6295 has 18 address lines but stadhero populates only the
            // first 64 KB of them (ROM_REGION 0x40000, one 0x10000 ROM at
            // offset 0).  MAME reads the rest of that region back as zero;
            // this image has the CHARACTER ROM there, so an address past the
            // end would play tile graphics as audio.
            //
            // Measured, not assumed: tools/sh_oki_dump.lua taps the 6295's
            // command port for 3000 frames of attract and dumps the phrase
            // table entry of every sample the game actually triggers.  Seven
            // distinct samples, highest address 0x06A77 -- all inside 64 KB.
            // So this guard never fires in play; it is here so a wrong address
            // is silent the way the hardware is, instead of loud and wrong.
            //
            // Reading the table statically does NOT answer this.  Sample 1
            // starts at 0x0278, inside the 0x400 table region, so the later
            // "entries" are sample data; scanning all 127 reports 52 addresses
            // past 64 KB and every one of them is an artefact.
            SEL_PCM:  begin
                pcm_data <= pcm_past_end ? 8'h00
                          : pcm_lat[0]   ? mem_dout[7:0] : mem_dout[15:8];
                pcm_done <= 1'b1;
            end
            default: ;
        endcase
        // A 32-bit reader needs a second access at the same latched address.
        if (!half && (sel == SEL_TILE || sel == SEL_OBJ || sel == SEL_CHAR)) begin
            half <= 1'b1;
        end else begin
            sel  <= SEL_NONE;
            half <= 1'b0;
        end
    end
end

endmodule

`default_nettype wire
