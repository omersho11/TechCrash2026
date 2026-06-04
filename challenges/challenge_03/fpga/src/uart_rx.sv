module uart_rx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD = 9600
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx_in,
    output reg  [7:0] rx_data,
    output reg        rx_valid
);

    localparam BIT_PERIOD = CLK_FREQ / BAUD;
    localparam HALF_BIT   = BIT_PERIOD / 2;

    reg [31:0] clk_cnt;
    reg [3:0]  bit_idx;
    reg [7:0]  shifter;
    
    // Sync rx_in to avoid metastability
    reg rx_sync_0, rx_sync_1;
    always @(posedge clk) begin
        rx_sync_0 <= rx_in;
        rx_sync_1 <= rx_sync_0;
    end

    typedef enum reg [1:0] {
        IDLE  = 2'd0,
        START = 2'd1,
        DATA  = 2'd2,
        STOP  = 2'd3
    } state_t;

    state_t state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            rx_data  <= 0;
            rx_valid <= 0;
            clk_cnt  <= 0;
            bit_idx  <= 0;
            shifter  <= 0;
        end else begin
            rx_valid <= 0;
            
            case (state)
                IDLE: begin
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if (!rx_sync_1) begin // start bit detected (low)
                        state <= START;
                    end
                end

                START: begin
                    if (clk_cnt >= HALF_BIT - 1) begin
                        clk_cnt <= 0;
                        if (!rx_sync_1) begin
                            state <= DATA;
                        end else begin
                            state <= IDLE; // false start
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                DATA: begin
                    if (clk_cnt >= BIT_PERIOD - 1) begin
                        clk_cnt <= 0;
                        shifter <= {rx_sync_1, shifter[7:1]}; // LSB first
                        if (bit_idx >= 7) begin
                            state <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                STOP: begin
                    if (clk_cnt >= BIT_PERIOD - 1) begin
                        clk_cnt  <= 0;
                        rx_data  <= shifter;
                        rx_valid <= 1;
                        state    <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end

endmodule
