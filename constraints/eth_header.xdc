# eth_header.xdc
#
# eth_header is a pure datapath module (clk/rst + AXI4-Stream buses only),
# so there are no board-specific pin/IOSTANDARD constraints here. Add those
# if you instantiate this at the top level of a real board design.

create_clock -period 10.000 -name clk [get_ports clk]
