// =================================================================
// Reusable FPGA UART Transmitter Module (SystemVerilog)
// =================================================================
// Transmits one byte at a time (8N1) when tx_start is pulsed.
// Features:
// - Parameterizable Clock Frequency and Baud Rate.
// - Standard start, 8 data bits (LSB first), and 1 stop bit framing.
// - Asserts tx_busy flag during active transmission.
// =================================================================

module uart_tx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 115200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] tx_data,    // Byte data to transmit
    input  logic       tx_start,   // Pulse high to start transmission
    output logic       tx,         // Serial output pin
    output logic       tx_busy     // Stays high while transmitting
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;

    typedef enum logic [2:0] {
        IDLE, START, DATA, STOP
    } state_t;

    state_t state;
    logic [15:0] clk_cnt;
    logic [2:0]  bit_idx;
    logic [7:0]  shift_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            clk_cnt  <= 0;
            bit_idx  <= 0;
            shift_reg <= 0;
            tx       <= 1'b1;  // Idle line level is high
            tx_busy  <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    tx      <= 1'b1;
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if (tx_start) begin
                        shift_reg <= tx_data;
                        tx_busy   <= 1'b1;
                        state     <= START;
                    end else begin
                        tx_busy   <= 1'b0;
                    end
                end

                START: begin
                    tx <= 1'b0;  // Start bit (low)
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        state   <= DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                DATA: begin
                    tx <= shift_reg[bit_idx];  // Send LSB first
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        if (bit_idx == 7) begin
                            state <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                STOP: begin
                    tx <= 1'b1;  // Stop bit (high)
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        tx_busy <= 1'b0;
                        state   <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end

endmodule
