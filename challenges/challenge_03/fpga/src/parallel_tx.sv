module parallel_tx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD = 9600
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire       tx_start,
    input  wire [7:0] tx_data,
    output reg        tx_busy,
    output reg        strobe,
    output reg  [7:0] data_out
);

    localparam HALF_PERIOD = CLK_FREQ / (BAUD * 2);

    reg [31:0] clk_cnt;
    reg [31:0] byte_counter;
    reg [2:0]  bit_counter;
    reg [7:0]  shifter;
    
    typedef enum reg [2:0] {
        IDLE     = 3'd0,
        ACCUM    = 3'd1,
        STROBE_H = 3'd2,
        STROBE_L = 3'd3,
        DONE     = 3'd4
    } state_t;

    state_t state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            tx_busy      <= 0;
            strobe       <= 0;
            data_out     <= 0;
            clk_cnt      <= 0;
            byte_counter <= 0;
            bit_counter  <= 0;
            shifter      <= 0;
        end else if (start) begin
            state        <= IDLE;
            tx_busy      <= 0;
            strobe       <= 0;
            data_out     <= 0;
            clk_cnt      <= 0;
            byte_counter <= 0;
            bit_counter  <= 0;
            shifter      <= 0;
        end else begin
            case (state)
                IDLE: begin
                    strobe  <= 0;
                    tx_busy <= 0;
                    if (tx_start) begin
                        tx_busy <= 1;
                        clk_cnt <= 0;
                        if (byte_counter < 5) begin
                            // Header + First data byte: send uncompressed
                            data_out     <= tx_data;
                            byte_counter <= byte_counter + 1;
                            state        <= STROBE_H;
                        end else begin
                            // Data bytes: accumulate feedback bit (tx_data[0])
                            shifter     <= {tx_data[0], shifter[7:1]};
                            bit_counter <= bit_counter + 1;
                            state       <= ACCUM;
                        end
                    end
                end

                ACCUM: begin
                    if (bit_counter == 0) begin
                        // Accumulated 8 bits, transmit
                        data_out <= shifter;
                        state    <= STROBE_H;
                    end else begin
                        tx_busy <= 0;
                        state   <= IDLE;
                    end
                end

                STROBE_H: begin
                    strobe <= 1;
                    if (clk_cnt >= HALF_PERIOD - 1) begin
                        clk_cnt <= 0;
                        state   <= STROBE_L;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                STROBE_L: begin
                    strobe <= 0;
                    if (clk_cnt >= HALF_PERIOD - 1) begin
                        tx_busy <= 0;
                        state   <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end

endmodule
