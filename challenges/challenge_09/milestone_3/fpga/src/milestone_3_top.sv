// ============================================================
// CrashTech VLSI-2026 — Challenge 9: Neural Flappy Bird
// Milestone 3: FPGA Neural-Network Inference
// ============================================================

module milestone_3_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);

    // --- High-Z unused Arduino IO pins ---
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_RESET_N = 1'bz;

    wire uart_rx;
    wire uart_tx;
    assign uart_rx = ARDUINO_IO[0];   // FPGA RX (Input, from ESP32 TX)
    assign ARDUINO_IO[1] = uart_tx;   // FPGA TX (Output, to ESP32 RX)

    // Mode display on LEDs
    assign LEDR = {SW[9], SW[8], 4'b0, SW[3:0]}; // SW[8] mode display, SW[9] show display mode, SW[3:0] difficulty

    // HEX0 displays SW[3:0] (0 to 15 in hex format)
    seven_seg_decoder hex0_decoder (
        .num(SW[3:0]),
        .hex_out(HEX0)
    );

    // Mode display on HEX5
    // Training mode (SW[8]=0) -> display "t", Inference mode (SW[8]=1) -> display "i"
    assign HEX5 = SW[8] ? 8'hF7 : 8'h87; 
    assign HEX4 = 8'hFF;
    assign HEX3 = 8'hFF;
    assign HEX2 = 8'hFF;
    assign HEX1 = 8'hFF;

    // --- UART Receiver (9600 Baud) ---
    wire rx_ready;
    wire [7:0] rx_data;

    uart_rx_9600 #(.CLK_FREQ(50000000)) urx (
        .clk(MAX10_CLK1_50),
        .rx(uart_rx),
        .ready(rx_ready),
        .data(rx_data)
    );

    // --- UART Packet Parser state machine ---
    // Registers to store 25 weights & biases (signed 8-bit Q4.4 format)
    reg signed [7:0] w1 [0:3][0:3];
    reg signed [7:0] b1 [0:3];
    reg signed [7:0] w2 [0:3];
    reg signed [7:0] b2;

    // Inputs received from ESP32 (signed 8-bit Q4.4 format)
    reg signed [7:0] in0, in1, in2, in3;

    // Parser states
    reg [5:0] rx_state = 0;
    reg [7:0] rx_checksum = 0;
    reg [7:0] temp_weights [0:24];
    reg compute_trigger = 0;

    always @(posedge MAX10_CLK1_50) begin
        compute_trigger <= 0;
        if (rx_ready) begin
            case (rx_state)
                // Idle / Detect header
                0: begin
                    if (rx_data == 8'hA0) begin
                        // Start of weights packet (25 bytes + 1 checksum)
                        rx_state <= 1;
                        rx_checksum <= 0;
                    end else if (rx_data == 8'hB0) begin
                        // Start of inputs packet (4 bytes + 1 checksum)
                        rx_state <= 28;
                        rx_checksum <= 0;
                    end
                end

                // --- Parse Weight Packet (States 1 to 25) ---
                1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25: begin
                    temp_weights[rx_state - 1] <= rx_data;
                    rx_checksum <= rx_checksum + rx_data;
                    rx_state <= rx_state + 1;
                end
                26: begin // Validate weights checksum
                    if (rx_checksum == rx_data) begin
                        // Copy temp weights to formal registers
                        w1[0][0] <= temp_weights[0]; w1[0][1] <= temp_weights[1]; w1[0][2] <= temp_weights[2]; w1[0][3] <= temp_weights[3];
                        b1[0]    <= temp_weights[4]; w2[0]    <= temp_weights[5];
                        w1[1][0] <= temp_weights[6]; w1[1][1] <= temp_weights[7]; w1[1][2] <= temp_weights[8]; w1[1][3] <= temp_weights[9];
                        b1[1]    <= temp_weights[10]; w2[1]   <= temp_weights[11];
                        w1[2][0] <= temp_weights[12]; w1[2][1] <= temp_weights[13]; w1[2][2] <= temp_weights[14]; w1[2][3] <= temp_weights[15];
                        b1[2]    <= temp_weights[16]; w2[2]   <= temp_weights[17];
                        w1[3][0] <= temp_weights[18]; w1[3][1] <= temp_weights[19]; w1[3][2] <= temp_weights[20]; w1[3][3] <= temp_weights[21];
                        b1[3]    <= temp_weights[22]; w2[3]   <= temp_weights[23];
                        b2       <= temp_weights[24];
                    end
                    rx_state <= 0;
                end

                // --- Parse Input Packet (States 28 to 31) ---
                28: begin
                    in0 <= rx_data;
                    rx_checksum <= rx_checksum + rx_data;
                    rx_state <= 29;
                end
                29: begin
                    in1 <= rx_data;
                    rx_checksum <= rx_checksum + rx_data;
                    rx_state <= 30;
                end
                30: begin
                    in2 <= rx_data;
                    rx_checksum <= rx_checksum + rx_data;
                    rx_state <= 31;
                end
                31: begin
                    in3 <= rx_data;
                    rx_checksum <= rx_checksum + rx_data;
                    rx_state <= 32;
                end
                32: begin // Validate inputs checksum
                    if (rx_checksum == rx_data) begin
                        compute_trigger <= 1'b1;
                    end
                    rx_state <= 0;
                end
                default: rx_state <= 0;
            endcase
        end
    end

    // --- Neural Network Hardware Accelerator ---
    // Fixed point inputs and internal sums
    reg signed [16:0] sum [0:3];
    reg signed [7:0]  h [0:3];
    reg signed [16:0] out_sum;
    reg               flap_decision;

    always @(posedge MAX10_CLK1_50) begin
        if (compute_trigger) begin
            // Layer 1 - Hidden Neurons
            // w * in gives Q8.8 result. Bias is Q4.4, scaled to Q8.8 by shift left by 4.
            // Activating with step threshold: sum > 0 -> h = 1.0 (16 in Q4.4), else 0.
            sum[0] = (w1[0][0]*in0 + w1[0][1]*in1 + w1[0][2]*in2 + w1[0][3]*in3) + (b1[0] << 4);
            h[0]   = (sum[0] > 0) ? 8'd16 : 8'd0;

            sum[1] = (w1[1][0]*in0 + w1[1][1]*in1 + w1[1][2]*in2 + w1[1][3]*in3) + (b1[1] << 4);
            h[1]   = (sum[1] > 0) ? 8'd16 : 8'd0;

            sum[2] = (w1[2][0]*in0 + w1[2][1]*in1 + w1[2][2]*in2 + w1[2][3]*in3) + (b1[2] << 4);
            h[2]   = (sum[2] > 0) ? 8'd16 : 8'd0;

            sum[3] = (w1[3][0]*in0 + w1[3][1]*in1 + w1[3][2]*in2 + w1[3][3]*in3) + (b1[3] << 4);
            h[3]   = (sum[3] > 0) ? 8'd16 : 8'd0;

            // Layer 2 - Output Neuron
            out_sum = (w2[0]*h[0] + w2[1]*h[1] + w2[2]*h[2] + w2[3]*h[3]) + (b2 << 4);
            flap_decision = (out_sum > 0) ? 1'b1 : 1'b0;
        end
    end

    // --- State Changes & UART Transmitter (9600 Baud) ---
    reg [3:0] sw_last;
    reg sw8_last;
    reg sw9_last;
    wire sw_change = (SW[3:0] != sw_last);
    wire sw8_change = (SW[8] != sw8_last);
    wire sw9_change = (SW[9] != sw9_last);

    always @(posedge MAX10_CLK1_50) begin
        sw_last <= SW[3:0];
        sw8_last <= SW[8];
        sw9_last <= SW[9];
    end

    // Periodic 1-second sync timer
    reg [25:0] timer_counter = 0;
    wire timer_tick = (timer_counter == 26'd50_000_000);
    always @(posedge MAX10_CLK1_50) begin
        if (timer_tick) timer_counter <= 0;
        else timer_counter <= timer_counter + 1;
    end

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

    // TX state machine
    reg [2:0] tx_state = 0;
    reg send_diff = 0;
    reg send_mode9 = 0;
    reg send_mode8 = 0;
    reg send_decision = 0;

    reg [3:0] queued_diff = 0;
    reg queued_mode9 = 0;
    reg queued_mode8 = 0;
    reg queued_decision = 0;

    always @(posedge MAX10_CLK1_50) begin
        if (sw_change || (timer_tick && !send_diff)) begin
            send_diff <= 1'b1;
            queued_diff <= SW[3:0];
        end
        if (sw8_change || (timer_tick && !send_mode8)) begin
            send_mode8 <= 1'b1;
            queued_mode8 <= SW[8];
        end
        if (sw9_change || (timer_tick && !send_mode9)) begin
            send_mode9 <= 1'b1;
            queued_mode9 <= SW[9];
        end
        if (compute_trigger) begin
            send_decision <= 1'b1;
            queued_decision <= flap_decision;
        end

        case (tx_state)
            0: begin
                tx_start <= 1'b0;
                // High priority on inference decision returns
                if (send_decision && !tx_busy) begin
                    tx_data <= queued_decision ? 8'h01 : 8'h00;
                    tx_start <= 1'b1;
                    send_decision <= 1'b0;
                    tx_state <= 1;
                end else if (send_diff && !tx_busy) begin
                    tx_data <= {4'h1, queued_diff};
                    tx_start <= 1'b1;
                    send_diff <= 1'b0;
                    tx_state <= 1;
                end else if (send_mode9 && !tx_busy) begin
                    tx_data <= queued_mode9 ? 8'h21 : 8'h20;
                    tx_start <= 1'b1;
                    send_mode9 <= 1'b0;
                    tx_state <= 1;
                end else if (send_mode8 && !tx_busy) begin
                    tx_data <= queued_mode8 ? 8'h31 : 8'h30; // 0x31: inference, 0x30: training
                    tx_start <= 1'b1;
                    send_mode8 <= 1'b0;
                    tx_state <= 1;
                end
            end
            1: begin
                tx_start <= 1'b0;
                if (tx_busy) tx_state <= 2;
            end
            2: begin
                if (!tx_busy) tx_state <= 0;
            end
            default: tx_state <= 0;
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

module uart_rx_9600 #(
    parameter CLK_FREQ = 50000000
) (
    input            clk,
    input            rx,
    output reg       ready,
    output reg [7:0] data
);
    localparam BIT_PERIOD = CLK_FREQ / 9600;

    reg rx_d1 = 1;
    reg rx_d2 = 1;
    always @(posedge clk) begin
        rx_d1 <= rx;
        rx_d2 <= rx_d1;
    end

    reg [1:0] state = 0;
    reg [15:0] clk_cnt = 0;
    reg [3:0] bit_idx = 0;
    reg [7:0] rx_shift = 0;

    always @(posedge clk) begin
        ready <= 1'b0;
        case (state)
            0: begin // Idle
                clk_cnt <= 0;
                bit_idx <= 0;
                if (rx_d2 == 1'b0) begin // Start bit detected
                    state <= 1;
                end
            end
            1: begin // Wait for half period to sample start bit
                if (clk_cnt < (BIT_PERIOD / 2) - 1) begin
                    clk_cnt <= clk_cnt + 1;
                end else begin
                    clk_cnt <= 0;
                    if (rx_d2 == 1'b0) begin
                        state <= 2;
                    end else begin
                        state <= 0; // False start
                    end
                end
            end
            2: begin // Sample data bits
                if (clk_cnt < BIT_PERIOD - 1) begin
                    clk_cnt <= clk_cnt + 1;
                end else begin
                    clk_cnt <= 0;
                    rx_shift[bit_idx] <= rx_d2;
                    if (bit_idx < 7) begin
                        bit_idx <= bit_idx + 1;
                    end else begin
                        state <= 3;
                    end
                end
            end
            3: begin // Stop bit
                if (clk_cnt < BIT_PERIOD - 1) begin
                    clk_cnt <= clk_cnt + 1;
                end else begin
                    clk_cnt <= 0;
                    if (rx_d2 == 1'b1) begin
                        data <= rx_shift;
                        ready <= 1'b1;
                    end
                    state <= 0;
                end
            end
            default: state <= 0;
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
            1: begin
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
            2: begin
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
