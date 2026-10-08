//============================================================================
//  Stadium Hero -- clock enables
//
//  One clock domain at 60.000 MHz.  Every board clock but one divides from it
//  exactly, which is why 60 was chosen over the more obvious 48:
//
//      68000      10.000 MHz   / 6     HW_CONFIRMED  20 MHz XTAL / 2
//      pixel       6.000 MHz   /10     24 MHz XTAL / 4
//      MXC06/BAC06 12.000 MHz   / 5     24 MHz XTAL / 2
//      YM3812      3.000 MHz   /20     HW_CONFIRMED  24 MHz XTAL / 8
//      YM2203      1.500 MHz   /40     HW_CONFIRMED  24 MHz XTAL / 16
//      65C02 cen   6.000 MHz   /10     4x the 1.5 MHz E pin
//
//  48 MHz gives the video and sound chain exactly but needs a fractional
//  divider for the 68000; 60 MHz needs one only for the M6295, which is on its
//  own resonator anyway and so is fractional against every choice.
//
//      M6295       1.056 MHz           resonator, pin 7 HIGH
//
//  60e6 * 11 / 625 = 1,056,000 Hz exactly, so the fractional accumulator adds
//  11 and wraps at 625.  Pulses land 56 or 57 clocks apart; the M6295 divides
//  by 132 internally to reach its 8 kHz sample rate, which averages the jitter
//  away long before anything hears it.
//
//  Two crystals, one domain: the alternative is a second PLL output and a real
//  CDC at every dual-port RAM between the CPU and the video chips.  Root
//  CLAUDE.md 1.5 treats clock and CDC structure as the highest-risk thing to
//  get wrong, and Power Spikes made the same call for the same reason
//  (rtl/ps_top.sv header).  The board's two crystals are not
//  phase-related to each other on the PCB either.
//============================================================================
`default_nettype none

module sh_cen (
    input  wire clk,            // 60.000 MHz
    input  wire rst,

    output reg  cen10,          // 68000
    output reg  cen12,          // video chips
    output reg  cen6,           // pixel clock, and the 65C02 enable
    output reg  cen3,           // YM3812
    output reg  cen1p5,         // YM2203
    output reg  cen_oki         // M6295, 1.056 MHz
);

// 60 / 10 = 6 MHz, and everything that is a power-of-two submultiple of it
// hangs off the same counter so the edges stay aligned.
reg [5:0] div;          // 0 .. 39, the LCM of 6, 10, 20 and 40
reg [2:0] div6;         // 0 .. 5 for the 68000

always @(posedge clk) begin
    if (rst) begin
        div    <= 6'd0;
        div6   <= 3'd0;
        cen10  <= 1'b0;
        cen12  <= 1'b0;
        cen6   <= 1'b0;
        cen3   <= 1'b0;
        cen1p5 <= 1'b0;
    end else begin
        div  <= (div  == 6'd39) ? 6'd0 : div  + 6'd1;
        div6 <= (div6 == 3'd5)  ? 3'd0 : div6 + 3'd1;

        // Compared against explicit values, NOT written as `div % 5`.
        // The modulo version cost two lpm_divide instances -- 45 ALUTs of
        // hardware divider on a free-running counter -- because % by a
        // non-power-of-two is a division, and Quartus builds one.  It showed up
        // in the first Analysis & Synthesis run as
        //     |sh_cen:u_cen| -> |lpm_divide:Mod1| ... |lpm_divide:Mod2|
        // The area is small; the combinational depth on a 60 MHz enable is not
        // something to find out about at the timing report.
        cen10  <= (div6 == 3'd0);
        cen12  <= (div == 6'd0)  || (div == 6'd5)  || (div == 6'd10) ||
                  (div == 6'd15) || (div == 6'd20) || (div == 6'd25) ||
                  (div == 6'd30) || (div == 6'd35);
        cen6   <= (div == 6'd0)  || (div == 6'd10) || (div == 6'd20) ||
                  (div == 6'd30);
        cen3   <= (div == 6'd0)  || (div == 6'd20);
        cen1p5 <= (div == 6'd0);
    end
end

// 60e6 * 11 / 625 = 1.056 MHz exactly.
localparam [9:0] OKI_NUM = 10'd11;
localparam [9:0] OKI_DEN = 10'd625;

reg [9:0] oki_acc;

always @(posedge clk) begin
    if (rst) begin
        oki_acc <= 10'd0;
        cen_oki <= 1'b0;
    end else begin
        if (oki_acc + OKI_NUM >= OKI_DEN) begin
            oki_acc <= oki_acc + OKI_NUM - OKI_DEN;
            cen_oki <= 1'b1;
        end else begin
            oki_acc <= oki_acc + OKI_NUM;
            cen_oki <= 1'b0;
        end
    end
end

endmodule

`default_nettype wire
