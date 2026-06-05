// UART transmitter, 8N1, LSB first.
module uart_tx #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tx_start,
    input  wire [7:0] tx_data,
    output reg        tx_busy,
    output reg        tx_out
);

    localparam integer BIT_PERIOD = CLK_FREQ / BAUD;

    reg [15:0] clk_cnt;
    reg [3:0]  bit_idx;
    reg [7:0]  shift;

    initial begin
        tx_out  = 1'b1;
        tx_busy = 1'b0;
        clk_cnt = 16'd0;
        bit_idx = 4'd0;
        shift   = 8'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_out  <= 1'b1;
            tx_busy <= 1'b0;
            clk_cnt <= 16'd0;
            bit_idx <= 4'd0;
            shift   <= 8'd0;
        end else if (!tx_busy) begin
            if (tx_start) begin
                tx_busy <= 1'b1;
                tx_out  <= 1'b0;
                clk_cnt <= 16'd0;
                bit_idx <= 4'd0;
                shift   <= tx_data;
            end
        end else if (clk_cnt == BIT_PERIOD - 1) begin
            clk_cnt <= 16'd0;
            bit_idx <= bit_idx + 4'd1;

            if (bit_idx < 4'd8) begin
                tx_out <= shift[0];
                shift  <= {1'b0, shift[7:1]};
            end else if (bit_idx == 4'd8) begin
                tx_out <= 1'b1;
            end else begin
                tx_busy <= 1'b0;
                tx_out  <= 1'b1;
            end
        end else begin
            clk_cnt <= clk_cnt + 16'd1;
        end
    end
endmodule
