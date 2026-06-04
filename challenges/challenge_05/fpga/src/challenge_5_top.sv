// ============================================================
// CrashTech VLSI-2026 — Challenge 5: FPGA Volt-Meter Top RTL
// ============================================================

module challenge_5_top (
    input  logic        MAX10_CLK1_50,   // 50 MHz clock
    input  logic [1:0]  KEY,             // KEY[0] as active-low reset
    input  logic [9:0]  SW,              // Unused
    output logic [9:0]  LEDR,            // Red LEDs for voltage bar graph
    output logic [7:0]  HEX0,            // 7-segment display outputs (active-low)
    output logic [7:0]  HEX1,
    output logic [7:0]  HEX2,
    output logic [7:0]  HEX3,            // Blanks
    output logic [7:0]  HEX4,
    output logic [7:0]  HEX5,
    inout  logic [15:0] ARDUINO_IO       // ARDUINO_IO[1] is UART TX to ESP32
);

    logic clk;
    logic rst_n;
    assign clk = MAX10_CLK1_50;
    assign rst_n = KEY[0];

    // ---- Arduino Header UART Pin ----
    // FPGA TX: ARDUINO_IO[1]
    logic tx_pin;
    assign ARDUINO_IO[1] = tx_pin;
    assign ARDUINO_IO[0] = 1'bz;         // Set unused RX to High-Z
    assign ARDUINO_IO[15:2] = 14'bz;     // Unused pins to high-Z

    // ---- 10 MHz ADC Clock from PLL ----
    logic clk_10m;
    logic pll_locked;

    adc_pll u_pll (
        .inclk0(clk),
        .c0(clk_10m),
        .locked(pll_locked)
    );

    // ---- ADC Interface Signals ----
    logic        adc_cmd_valid;
    logic [4:0]  adc_cmd_channel;
    logic        adc_cmd_sop;
    logic        adc_cmd_eop;
    logic        adc_cmd_ready;

    logic        adc_resp_valid;
    logic [4:0]  adc_resp_channel;
    logic [11:0] adc_resp_data;
    logic        adc_resp_sop;
    logic        adc_resp_eop;

    // Instantiation of the Platform Designer system
    adc_qsys u_adc_qsys (
        .clk_clk(clk),
        .reset_reset_n(rst_n),
        .adc_pll_clock_clk(clk_10m),
        .adc_pll_locked_export(pll_locked),
        
        .command_valid(adc_cmd_valid),
        .command_channel(adc_cmd_channel),
        .command_startofpacket(adc_cmd_sop),
        .command_endofpacket(adc_cmd_eop),
        .command_ready(adc_cmd_ready),

        .response_valid(adc_resp_valid),
        .response_channel(adc_resp_channel),
        .response_data(adc_resp_data),
        .response_startofpacket(adc_resp_sop),
        .response_endofpacket(adc_resp_eop)
    );

    // ---- ADC Sampling Controller State Machine ----
    // Samples at regular intervals (approx 10 ms)
    typedef enum logic [1:0] {
        ADC_IDLE,
        ADC_SEND_CMD,
        ADC_WAIT_RESP
    } adc_state_t;

    adc_state_t adc_state;
    logic [19:0] adc_sample_timer;
    logic [11:0] raw_adc_val;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adc_state        <= ADC_IDLE;
            adc_sample_timer <= 0;
            adc_cmd_valid    <= 1'b0;
            adc_cmd_channel  <= 5'd0;
            adc_cmd_sop      <= 1'b0;
            adc_cmd_eop      <= 1'b0;
            raw_adc_val      <= 12'd0;
        end else begin
            case (adc_state)
                ADC_IDLE: begin
                    adc_cmd_valid <= 1'b0;
                    if (adc_sample_timer >= 20'd500_000) begin // 10 ms interval at 50 MHz
                        adc_sample_timer <= 0;
                        adc_state        <= ADC_SEND_CMD;
                    end else begin
                        adc_sample_timer <= adc_sample_timer + 1;
                    end
                end

                ADC_SEND_CMD: begin
                    adc_cmd_valid   <= 1'b1;
                    adc_cmd_channel <= 5'd1; // Channel 1 maps to A0
                    adc_cmd_sop     <= 1'b1;
                    adc_cmd_eop     <= 1'b1;

                    if (adc_cmd_ready) begin
                        adc_cmd_valid <= 1'b0;
                        adc_state     <= ADC_WAIT_RESP;
                    end
                end

                ADC_WAIT_RESP: begin
                    if (adc_resp_valid && adc_resp_channel == 5'd1) begin
                        raw_adc_val <= adc_resp_data;
                        adc_state   <= ADC_IDLE;
                    end
                end
            endcase
        end
    end

    // ---- Voltage Math (Centivolts) ----
    // Reference input A0 range is 0V to 5V (due to hardware scaling divider).
    // Potentiometer ranges 0V to 3.3V.
    // Digital readout centivolts = (raw_adc_val * 500) / 4095
    logic [31:0] centivolts;
    assign centivolts = (raw_adc_val * 32'd500 + 32'd2047) / 32'd4095;

    // ---- Decimal Digit Extraction (BCD) ----
    logic [3:0] digit0; // Ones digit
    logic [3:0] digit1; // Tenths digit
    logic [3:0] digit2; // Hundredths digit

    assign digit0 = centivolts / 100;
    assign digit1 = (centivolts / 10) % 10;
    assign digit2 = centivolts % 10;

    // ---- 7-Segment Display Configuration ----
    logic [7:0] seg0, seg1, seg2;
    seven_segment hex0_dec (.data(digit2), .blank(1'b0), .seg(seg0));
    seven_segment hex1_dec (.data(digit1), .blank(1'b0), .seg(seg1));
    seven_segment hex2_dec (.data(digit0), .blank(1'b0), .seg(seg2));

    assign HEX0 = seg0;
    assign HEX1 = seg1;
    // Turn decimal point (bit 7) ON (active-low: 0) on HEX2 (ones place)
    assign HEX2 = {1'b0, seg2[6:0]};

    // Blank out HEX3, HEX4, HEX5
    assign HEX3 = 8'hFF;
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

    // ---- LED Proportional Bar Graph ----
    always_comb begin
        if (centivolts < 33)        LEDR = 10'b0000000000; // < 0.33V
        else if (centivolts < 66)   LEDR = 10'b0000000001; // < 0.66V
        else if (centivolts < 99)   LEDR = 10'b0000000011; // < 0.99V
        else if (centivolts < 132)  LEDR = 10'b0000000111; // < 1.32V
        else if (centivolts < 165)  LEDR = 10'b0000001111; // < 1.65V
        else if (centivolts < 198)  LEDR = 10'b0000011111; // < 1.98V
        else if (centivolts < 231)  LEDR = 10'b0000111111; // < 2.31V
        else if (centivolts < 264)  LEDR = 10'b0001111111; // < 2.64V
        else if (centivolts < 297)  LEDR = 10'b0011111111; // < 2.97V
        else if (centivolts < 330)  LEDR = 10'b0111111111; // < 3.30V
        else                        LEDR = 10'b1111111111; // >= 3.30V
    end

    // ---- UART Transmitter Interface ----
    logic       uart_start;
    logic [7:0] uart_data;
    logic       uart_busy;

    uart_tx #(
        .CLK_FREQ(50_000_000),
        .BAUD(9600)
    ) u_uart_tx (
        .clk(clk),
        .rst_n(rst_n),
        .tx_start(uart_start),
        .tx_data(uart_data),
        .tx_busy(uart_busy),
        .tx_out(tx_pin)
    );

    // ---- UART Formatting & Transmission State Machine ----
    // Sends "X.XX\n" every 100 ms
    typedef enum logic [3:0] {
        TX_IDLE,
        TX_SEND_DIGIT0,
        TX_WAIT_DIGIT0,
        TX_SEND_DOT,
        TX_WAIT_DOT,
        TX_SEND_DIGIT1,
        TX_WAIT_DIGIT1,
        TX_SEND_DIGIT2,
        TX_WAIT_DIGIT2,
        TX_SEND_NL,
        TX_WAIT_NL
    } tx_state_t;

    tx_state_t tx_state;
    logic [22:0] tx_timer;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state   <= TX_IDLE;
            tx_timer   <= 0;
            uart_start <= 1'b0;
            uart_data  <= 8'd0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    uart_start <= 1'b0;
                    if (tx_timer >= 23'd5_000_000) begin // 100 ms at 50 MHz
                        tx_timer <= 0;
                        tx_state <= TX_SEND_DIGIT0;
                    end else begin
                        tx_timer <= tx_timer + 1;
                    end
                end

                TX_SEND_DIGIT0: begin
                    if (!uart_busy) begin
                        uart_data  <= {4'd3, digit0}; // ASCII '0'-'9'
                        uart_start <= 1'b1;
                        tx_state   <= TX_WAIT_DIGIT0;
                    end
                end
                TX_WAIT_DIGIT0: begin
                    uart_start <= 1'b0;
                    if (uart_busy) tx_state <= TX_SEND_DOT;
                end

                TX_SEND_DOT: begin
                    if (!uart_busy) begin
                        uart_data  <= 8'h2E;          // ASCII '.'
                        uart_start <= 1'b1;
                        tx_state   <= TX_WAIT_DOT;
                    end
                end
                TX_WAIT_DOT: begin
                    uart_start <= 1'b0;
                    if (uart_busy) tx_state <= TX_SEND_DIGIT1;
                end

                TX_SEND_DIGIT1: begin
                    if (!uart_busy) begin
                        uart_data  <= {4'd3, digit1}; // ASCII '0'-'9'
                        uart_start <= 1'b1;
                        tx_state   <= TX_WAIT_DIGIT1;
                    end
                end
                TX_WAIT_DIGIT1: begin
                    uart_start <= 1'b0;
                    if (uart_busy) tx_state <= TX_SEND_DIGIT2;
                end

                TX_SEND_DIGIT2: begin
                    if (!uart_busy) begin
                        uart_data  <= {4'd3, digit2}; // ASCII '0'-'9'
                        uart_start <= 1'b1;
                        tx_state   <= TX_WAIT_DIGIT2;
                    end
                end
                TX_WAIT_DIGIT2: begin
                    uart_start <= 1'b0;
                    if (uart_busy) tx_state <= TX_SEND_NL;
                end

                TX_SEND_NL: begin
                    if (!uart_busy) begin
                        uart_data  <= 8'h0A;          // ASCII '\n'
                        uart_start <= 1'b1;
                        tx_state   <= TX_WAIT_NL;
                    end
                end
                TX_WAIT_NL: begin
                    uart_start <= 1'b0;
                    if (uart_busy) tx_state <= TX_IDLE;
                end
            endcase
        end
    end

endmodule
