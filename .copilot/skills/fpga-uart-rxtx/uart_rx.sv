// =================================================================
// Reusable FPGA UART Receiver Module (SystemVerilog)
// =================================================================
// Receives one byte at a time and asserts rx_valid for 1 clock cycle.
// Features:
// - Parameterizable Clock Frequency and Baud Rate.
// - Double-flop input synchronizer on the RX pin to prevent metastability.
// - Start-bit midpoint verification for glitch filtering.
// =================================================================

module uart_rx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 115200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,         // Serial input pin
    output logic [7:0] rx_data,    // Deserialized byte output
    output logic       rx_valid    // Pulses high for 1 clock cycle when byte is ready
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;
    localparam HALF_BIT     = CLKS_PER_BIT / 2;

    typedef enum logic [2:0] {
        IDLE, START, DATA, STOP
    } state_t;

    state_t state;
    logic [15:0] clk_cnt;
    logic [2:0]  bit_idx;
    logic [7:0]  shift_reg;

    // Double-flop synchronizer for metastability
    logic rx_sync1, rx_sync2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            clk_cnt   <= 0;
            bit_idx   <= 0;
            shift_reg <= 0;
            rx_data   <= 0;
            rx_valid  <= 0;
        end else begin
            rx_valid <= 1'b0;

            case (state)
                IDLE: begin
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if (rx_sync2 == 1'b0)  // Start bit detected
                        state <= START;
                end

                START: begin
                    if (clk_cnt == HALF_BIT - 1) begin
                        // Verify start bit is still low at midpoint to filter glitches
                        if (rx_sync2 == 1'b0) begin
                            clk_cnt <= 0;
                            state   <= DATA;
                        end else begin
                            state <= IDLE;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        shift_reg[bit_idx] <= rx_sync2;  // LSB first
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
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        rx_data  <= shift_reg;
                        rx_valid <= 1'b1;
                        state    <= IDLE;
                        clk_cnt  <= 0;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end

endmodule
