// ============================================================
// CrashTech VLSI-2026 — Challenge 6: Frequency Detector Top RTL
// ============================================================

module challenge_6_top (
    input  logic        MAX10_CLK1_50,   // 50 MHz clock
    input  logic [1:0]  KEY,             // KEY[0] as active-low reset
    input  logic [9:0]  SW,              // SW[9] debug, SW[8:0] unused
    output logic [9:0]  LEDR,            // Red LEDs for frequency band
    output logic [7:0]  HEX0,            // 7-segment display outputs (active-low)
    output logic [7:0]  HEX1,
    output logic [7:0]  HEX2,
    output logic [7:0]  HEX3,
    output logic [7:0]  HEX4,
    output logic [7:0]  HEX5,
    inout  logic [15:0] ARDUINO_IO       // ARDUINO_IO[0] is UART RX from ESP32
);

    logic clk;
    logic rst_n;
    assign clk = MAX10_CLK1_50;
    assign rst_n = KEY[0];

    // ---- UART RX Line Configuration ----
    assign ARDUINO_IO[0] = 1'bz; // Input mode for RX
    logic rx_pin;
    assign rx_pin = ARDUINO_IO[0];

    // Disable unused Arduino pins
    assign ARDUINO_IO[15:1] = 15'bz;

    // ---- UART Receiver ----
    logic [7:0] rx_data;
    logic rx_valid;

    uart_rx #(
        .CLK_FREQ(50_000_000),
        .BAUD(115200)
    ) u_uart_rx (
        .clk(clk),
        .rst_n(rst_n),
        .rx(rx_pin),
        .rx_data(rx_data),
        .rx_valid(rx_valid)
    );

    // ---- Zero-Crossing Detection with Hysteresis & Frame Sync ----
    // ESP32 sends raw 8-bit signed samples
    logic signed [7:0] sample;
    assign sample = signed'(rx_data);

    logic is_positive;
    logic is_positive_d;
    logic [9:0] crossings;
    logic [9:0] sample_count;

    // Idle gap frame sync
    // 50 MHz clock: 1 cycle = 20 ns.
    // 100,000 cycles = 2 ms idle gap to trigger frame end.
    logic [19:0] idle_counter;
    logic frame_done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idle_counter <= 0;
            frame_done   <= 0;
        end else begin
            if (rx_valid) begin
                idle_counter <= 0;
                frame_done   <= 0;
            end else if (idle_counter < 20'd100_000) begin
                idle_counter <= idle_counter + 1;
                frame_done   <= 0;
            end else if (idle_counter == 20'd100_000) begin
                idle_counter <= idle_counter + 1;
                frame_done   <= 1; // Trigger calculation once
            end else begin
                frame_done   <= 0;
            end
        end
    end

    // Hysteresis threshold
    localparam int HYS = 10;

    logic [9:0] final_crossings;
    logic [11:0] final_frequency;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_positive      <= 0;
            is_positive_d    <= 0;
            crossings        <= 0;
            sample_count     <= 0;
            final_crossings  <= 0;
            final_frequency  <= 0;
        end else begin
            if (rx_valid) begin
                // Track number of samples in this burst
                if (sample_count < 10'd512) begin
                    sample_count <= sample_count + 1;
                end

                // On the very first sample, initialize the sign state to avoid spurious crossings
                if (sample_count == 0) begin
                    is_positive   <= (sample >= 0);
                    is_positive_d <= (sample >= 0);
                end else begin
                    is_positive_d <= is_positive;
                    // Hysteresis comparator
                    if (sample > HYS) begin
                        is_positive <= 1;
                    end else if (sample < -HYS) begin
                        is_positive <= 0;
                    end

                    // Sign crossing occurs when positive/negative state transitions
                    if (is_positive != is_positive_d) begin
                        crossings <= crossings + 1;
                    end
                end
            end

            // When idle gap is detected, calculate frequency and reset counters
            if (frame_done) begin
                // Frame is valid if we received a reasonable number of samples (e.g. at least 240 out of 256)
                if (sample_count >= 10'd240) begin
                    final_crossings <= crossings;
                    // Formula: frequency = crossings * 15.625
                    // Done in integer: (crossings * 125) >> 3
                    final_frequency <= (crossings * 125) >> 3;
                end
                
                // Reset for next frame
                crossings    <= 0;
                sample_count <= 0;
                is_positive  <= 0;
                is_positive_d <= 0;
            end
        end
    end

    // ---- Display Decoding ----
    logic [11:0] display_value;
    // If SW[9] is high, show raw crossings. Else show calculated frequency in Hz.
    assign display_value = SW[9] ? {2'b0, final_crossings} : final_frequency;

    // Binary to BCD conversion
    function automatic [15:0] bin_to_bcd(input [11:0] bin);
        integer i;
        reg [15:0] bcd;
        begin
            bcd = 0;
            for (i = 11; i >= 0; i = i - 1) begin
                if (bcd[3:0] >= 5)   bcd[3:0]   = bcd[3:0] + 3;
                if (bcd[7:4] >= 5)   bcd[7:4]   = bcd[7:4] + 3;
                if (bcd[11:8] >= 5)  bcd[11:8]  = bcd[11:8] + 3;
                if (bcd[15:12] >= 5) bcd[15:12] = bcd[15:12] + 3;
                bcd = {bcd[14:0], bin[i]};
            end
            bin_to_bcd = bcd;
        end
    endfunction

    logic [15:0] bcd_value;
    assign bcd_value = bin_to_bcd(display_value);

    // HEX 7-Segment Displays
    seven_segment hex0_inst (.data(bcd_value[3:0]),   .blank(1'b0), .seg(HEX0));
    seven_segment hex1_inst (.data(bcd_value[7:4]),   .blank(1'b0), .seg(HEX1));
    seven_segment hex2_inst (.data(bcd_value[11:8]),  .blank(1'b0), .seg(HEX2));
    seven_segment hex3_inst (.data(bcd_value[15:12]), .blank(1'b0), .seg(HEX3));

    // HEX4 and HEX5 are unused, blank them
    assign HEX4 = 8'b11111111;
    assign HEX5 = 8'b11111111;

    // ---- LED Bar Graph (LEDR[9:0]) ----
    // Thermometer scale mapping for frequency bands
    always_comb begin
        if (final_frequency < 200)       LEDR = 10'b0000000000;
        else if (final_frequency < 400)  LEDR = 10'b0000000001;
        else if (final_frequency < 600)  LEDR = 10'b0000000011;
        else if (final_frequency < 800)  LEDR = 10'b0000000111;
        else if (final_frequency < 1000) LEDR = 10'b0000001111;
        else if (final_frequency < 1200) LEDR = 10'b0000011111;
        else if (final_frequency < 1400) LEDR = 10'b0000111111;
        else if (final_frequency < 1600) LEDR = 10'b0001111111;
        else if (final_frequency < 1800) LEDR = 10'b0011111111;
        else if (final_frequency < 2000) LEDR = 10'b0111111111;
        else                             LEDR = 10'b1111111111;
    end

endmodule
