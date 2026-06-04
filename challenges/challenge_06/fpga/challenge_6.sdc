create_clock -period 20.000 -name clk [get_ports {MAX10_CLK1_50}]
derive_clock_uncertainty
