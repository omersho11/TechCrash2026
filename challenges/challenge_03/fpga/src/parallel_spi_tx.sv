module parallel_spi_tx #(
    parameter CLK_DIV = 16  // Period of SCLK in system clock cycles
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,     // Resets state if needed
    input  wire        tx_start,  // Trigger sending a byte
    input  wire [7:0]  tx_data,   // Byte to send
    output reg         tx_busy,   // Transmitter is busy
    output reg  [7:0]  parallel_data, // 8-bit parallel data
    output reg         sclk       // SCLK clock signal
);

    reg [7:0] clk_cnt;
    localparam HALF_DIV = CLK_DIV / 2;

    typedef enum logic [1:0] {
        IDLE,
        TX_CYCLE
    } state_t;
    state_t state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_busy       <= 0;
            parallel_data <= 0;
            sclk          <= 0;
            clk_cnt       <= 0;
            state         <= IDLE;
        end else if (start) begin
            tx_busy       <= 0;
            parallel_data <= 0;
            sclk          <= 0;
            clk_cnt       <= 0;
            state         <= IDLE;
        end else begin
            case (state)
                IDLE: begin
                    sclk <= 0;
                    if (tx_start) begin
                        parallel_data <= tx_data;
                        clk_cnt       <= 0;
                        tx_busy       <= 1;
                        state         <= TX_CYCLE;
                    end else begin
                        tx_busy       <= 0;
                    end
                end

                TX_CYCLE: begin
                    if (clk_cnt == HALF_DIV - 1) begin
                        sclk    <= 1; // Rising edge: ESP32 samples data
                        clk_cnt <= clk_cnt + 1;
                    end else if (clk_cnt == CLK_DIV - 1) begin
                        sclk    <= 0; // Falling edge
                        clk_cnt <= 0;
                        state   <= IDLE;
                        tx_busy <= 0;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end

endmodule
