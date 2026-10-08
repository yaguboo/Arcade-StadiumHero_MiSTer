derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# SDRAM
#
# There are deliberately NO set_input_delay / set_output_delay constraints on
# the SDRAM pins.  An earlier version of this file had some, invented from
# memory, and the fitter duly failed them by 3.4 ns -- a made-up requirement
# missed by a made-up margin, which tells you nothing about the board.
#
# The established MiSTer practice, checked against MiSTer-devel/NES_MiSTer
# (NES.sdc) and MiSTer-devel/Genesis_MiSTer (Genesis.sdc), is to leave the
# SDRAM pins unconstrained and set the interface timing physically, with the
# phase of the clock driven out on SDRAM_CLK.
#
# Ours is 180 degrees (rtl/pll/pll_0002.v, phase_shift1 = -8333 ps, half of
# the 16667 ps period).  At 60.000 MHz that puts the SDRAM's clock edge
# 8.33 ns after the controller's, which leaves:
#   output path   8.33 ns for FPGA clock-to-out plus board delay plus SDRAM
#                setup -- against roughly 5 ns needed
#   input path   16.67 - 8.33 = 8.33 ns for SDRAM tAC plus board delay plus
#                FPGA setup -- against roughly 7 ns needed
#
# The input margin is 1.3 ns.  That is thinner than Power Spikes has at 40 MHz
# and it is the price of choosing 60 MHz so that both crystals divide exactly
# (docs/DECISIONS.md D1).  UNVERIFIED ON HARDWARE.  If reads come back
# corrupted on a real DE10-Nano, this phase is the first thing to change.
#
# tRCD was checked rather than assumed, because the inherited header says
# "tRCD >= 18 ns -> 1 clock" and one clock at 60 MHz is 16.67 ns, which would
# be a violation.  It is not one: that line counts WAIT STATES, not the actual
# interval.  cmd() is nonblocking and every clock defaults to NOP, so ACTIVE is
# registered in S_IDLE and reaches the pins during S_RCD, while READ is
# registered in S_CMD and reaches them during S_CL1 -- two clock periods
# between the two sampling edges, 33.3 ns.  Comfortable.
#
# The same counting applies to tRP, and tRC is enforced by the timer S_IDLE
# loads after each access.  sh_sdram.sv's header carries the corrected table.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Framework video paths.  The scaler and the HQ2x filter are deeply pipelined
# and do not need to settle in a single core clock; the same relaxations appear
# in the reference cores above.
# ---------------------------------------------------------------------------
set_multicycle_path -to {*Hq2x*} -setup 4
set_multicycle_path -to {*Hq2x*} -hold 3

set_multicycle_path -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] -to {ascal|*} -setup 4
set_multicycle_path -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] -to {ascal|*} -hold 3

# ---------------------------------------------------------------------------
# clk_aux -> clk_sys is a DELIBERATE asynchronous crossing.
#
# The PLL's third output (300 MHz) exists only to force the solver into a
# legal VCO on Power Spikes.  At 60 MHz it may be unnecessary; it stays until
# a real fit says so, because an unloaded output gets DELETED and
# the PLL re-solved with two outputs and the VCO moved -- which is exactly the
# failure it was added to prevent.  Its load is a free-running counter whose
# top bit is sampled
# into clk_sys through a two-flop synchroniser, purely as a liveness bit for
# the debug overlay.
#
# Left unconstrained, TimeQuest times that crossing as a real 300 MHz to
# 60 MHz path and reports -2.362 ns of setup slack, while Fmax for the core
# clock itself is 39.87 MHz -- essentially at target.  The two numbers
# disagreeing is what says the failing path is not inside the core domain.
#
# It is a synchroniser.  It must not be timed.
# ---------------------------------------------------------------------------
set_false_path   -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[2].*|divclk}]   -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
