// ============================================================
// CrashTech VLSI-2026 — Challenge 9: Neural Flappy Bird
// Milestone 1: Manual FPGA-Controlled Game
// ============================================================

module milestone_1_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);

    // --- High-Z unused Arduino IO pins ---
    assign ARDUINO_IO[0] = 1'bz; // FPGA RX (Input, from ESP32 TX)
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_RESET_N = 1'bz;

    wire uart_tx;
    assign ARDUINO_IO[1] = uart_tx; // FPGA TX (Output, to ESP32 RX)

    // Unused LEDs
    assign LEDR = {6'b0, SW[3:0]}; // Display difficulty on LEDs as well

    // --- HEX Display Settings (Active LOW, all segments off = 8'hFF) ---
    assign HEX1 = 8'hFF;
    assign HEX2 = 8'hFF;
    assign HEX3 = 8'hFF;
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

    // HEX0 displays SW[3:0] (0 to 15 in hex format)
    seven_seg_decoder hex0_decoder (
        .num(SW[3:0]),
        .hex_out(HEX0)
    );

    // --- Key Debouncing & Edge Detection ---
    reg key0_debounced;
    reg [19:0] debounce_counter = 0; // ~20ms debounce at 50MHz

    always @(posedge MAX10_CLK1_50) begin
        if (debounce_counter == 20'd1_000_000) begin
            key0_debounced <= KEY[0];
            debounce_counter <= 0;
        end else begin
            debounce_counter <= debounce_counter + 1;
        end
    end

    reg key0_last;
    wire key0_press; // Pulse on button press (falling edge of active-low KEY[0])
    always @(posedge MAX10_CLK1_50) begin
        key0_last <= key0_debounced;
    end
    assign key0_press = (key0_last == 1'b1) && (key0_debounced == 1'b0);

    // --- Switch Change Detection ---
    reg [3:0] sw_last;
    wire sw_change;
    always @(posedge MAX10_CLK1_50) begin
        sw_last <= SW[3:0];
    end
    assign sw_change = (SW[3:0] != sw_last);

    // --- UART Transmitter Control (9600 Baud) ---
    reg tx_start;
    reg [7:0] tx_data;
    wire tx_busy;

    uart_tx_9600 #(.CLK_FREQ(50000000)) utx (
        .clk(MAX10_CLK1_50),
        .start(tx_start),
        .data(tx_data),
        .tx(uart_tx),
        .busy(tx_busy)
    );

    // Queue/Send state machine
    reg [1:0] state = 0;
    reg send_flap = 0;
    reg send_diff = 0;
    reg [3:0] queued_diff = 0;

    always @(posedge MAX10_CLK1_50) begin
        // Catch events asynchronously
        if (key0_press) begin
            send_flap <= 1'b1;
        end
        if (sw_change) begin
            send_diff <= 1'b1;
            queued_diff <= SW[3:0];
        end

        // State machine
        case (state)
            0: begin
                tx_start <= 1'b0;
                if (send_flap && !tx_busy) begin
                    tx_data <= 8'h01; // Flap byte
                    tx_start <= 1'b1;
                    send_flap <= 1'b0;
                    state <= 1;
                end else if (send_diff && !tx_busy) begin
                    tx_data <= {4'h1, queued_diff}; // Difficulty byte (0x10 to 0x1F)
                    tx_start <= 1'b1;
                    send_diff <= 1'b0;
                    state <= 1;
                end
            end
            1: begin
                tx_start <= 1'b0;
                if (tx_busy) begin
                    state <= 2;
                end
            end
            2: begin
                if (!tx_busy) begin
                    state <= 0;
                end
            end
            default: state <= 0;
        endcase
    end

endmodule

// ============================================================
// Helper Modules
// ============================================================

module seven_seg_decoder (
    input      [3:0] num,
    output reg [7:0] hex_out
);
    // Active low: 0 turns on segment, 1 turns off segment.
    // Segment layout: {dp, g, f, e, d, c, b, a}
    always @(*) begin
        case (num)
            4'h0: hex_out = 8'hC0;
            4'h1: hex_out = 8'hF9;
            4'h2: hex_out = 8'hA4;
            4'h3: hex_out = 8'hB0;
            4'h4: hex_out = 8'h99;
            4'h5: hex_out = 8'h92;
            4'h6: hex_out = 8'h82;
            4'h7: hex_out = 8'hF8;
            4'h8: hex_out = 8'h80;
            4'h9: hex_out = 8'h90;
            4'hA: hex_out = 8'h88;
            4'hB: hex_out = 8'h83;
            4'hC: hex_out = 8'hC6;
            4'hD: hex_out = 8'hA1;
            4'hE: hex_out = 8'h86;
            4'hF: hex_out = 8'h8E;
            default: hex_out = 8'hFF;
        endcase
    end
endmodule

module uart_tx_9600 #(
    parameter CLK_FREQ = 50000000
) (
    input        clk,
    input        start,
    input  [7:0] data,
    output reg   tx,
    output reg   busy
);
    localparam BIT_PERIOD = CLK_FREQ / 9600;

    reg [3:0] bit_idx = 0;
    reg [15:0] clk_cnt = 0;
    reg [7:0] tx_shift = 0;
    reg [1:0] state = 0;

    initial begin
        tx = 1'b1;
        busy = 1'b0;
    end

    always @(posedge clk) begin
        case (state)
            0: begin
                tx <= 1'b1;
                busy <= 1'b0;
                clk_cnt <= 0;
                bit_idx <= 0;
                if (start) begin
                    tx_shift <= data;
                    busy <= 1'b1;
                    tx <= 1'b0; // Start bit
                    state <= 1;
                end
            end
            1: begin // Start bit and data bits
                busy <= 1'b1;
                if (clk_cnt < BIT_PERIOD - 1) begin
                    clk_cnt <= clk_cnt + 1;
                end else begin
                    clk_cnt <= 0;
                    if (bit_idx < 8) begin
                        tx <= tx_shift[bit_idx];
                        bit_idx <= bit_idx + 1;
                    end else begin
                        tx <= 1'b1; // Stop bit
                        state <= 2;
                    end
                end
            end
            2: begin // Stop bit
                busy <= 1'b1;
                if (clk_cnt < BIT_PERIOD - 1) begin
                    clk_cnt <= clk_cnt + 1;
                end else begin
                    clk_cnt <= 0;
                    state <= 0;
                end
            end
            default: state <= 0;
        endcase
    end
endmodule
