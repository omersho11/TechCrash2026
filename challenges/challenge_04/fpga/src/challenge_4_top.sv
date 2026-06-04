// =================================================================
// Challenge 4: Press Right (FPGA Top Module)
// =================================================================

module challenge_4_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N
);

    // ---- Key0 Debouncer ----
    logic [19:0] debounce_cnt;
    logic key0_stable;
    
    always_ff @(posedge MAX10_CLK1_50 or negedge KEY[1]) begin
        if (!KEY[1]) begin
            debounce_cnt <= 0;
            key0_stable  <= 1'b1;
        end else begin
            if (KEY[0] == key0_stable) begin
                debounce_cnt <= 0;
            end else begin
                debounce_cnt <= debounce_cnt + 1;
                if (debounce_cnt == 20'd1_000_000) begin // 20ms debounce
                    key0_stable  <= KEY[0];
                    debounce_cnt <= 0;
                end
            end
        end
    end

    logic key0_stable_prev;
    always_ff @(posedge MAX10_CLK1_50 or negedge KEY[1]) begin
        if (!KEY[1]) begin
            key0_stable_prev <= 1'b1;
        end else begin
            key0_stable_prev <= key0_stable;
        end
    end

    // Detect falling edge of debounced KEY[0] (active low press)
    logic key0_pressed;
    assign key0_pressed = (key0_stable_prev && !key0_stable);

    // ---- Main State Machine & Counter ----
    typedef enum logic [1:0] {
        IDLE,
        RUNNING,
        STOPPED
    } state_t;

    state_t state;
    logic [15:0] count;
    logic [18:0] tick_cnt;

    always_ff @(posedge MAX10_CLK1_50 or negedge KEY[1]) begin
        if (!KEY[1]) begin
            state    <= IDLE;
            count    <= 0;
            tick_cnt <= 0;
        end else begin
            case (state)
                IDLE: begin
                    count    <= 0;
                    tick_cnt <= 0;
                    if (key0_pressed) begin
                        state <= RUNNING;
                    end
                end
                RUNNING: begin
                    if (tick_cnt == 19'd499_999) begin // 10ms tick (50MHz / 100)
                        tick_cnt <= 0;
                        if (count == 16'd9999) begin
                            count <= 0;
                        end else begin
                            count <= count + 1;
                        end
                    end else begin
                        tick_cnt <= tick_cnt + 1;
                    end

                    if (key0_pressed) begin
                        state <= STOPPED;
                    end
                end
                STOPPED: begin
                    if (key0_pressed) begin
                        state    <= RUNNING;
                        count    <= 0;
                        tick_cnt <= 0;
                    end
                end
            endcase
        end
    end

    // ---- Decimal/BCD Decoding ----
    logic [3:0] bcd3, bcd2, bcd1, bcd0;
    always_comb begin
        bcd3 = (count / 1000) % 10;
        bcd2 = (count / 100) % 10;
        bcd1 = (count / 10) % 10;
        bcd0 = count % 10;
    end

    function automatic [7:0] seven_seg_decode(input [3:0] digit);
        case (digit)
            4'd0: return 8'hC0;
            4'd1: return 8'hF9;
            4'd2: return 8'hA4;
            4'd3: return 8'hB0;
            4'd4: return 8'h99;
            4'd5: return 8'h92;
            4'd6: return 8'h82;
            4'd7: return 8'hF8;
            4'd8: return 8'h80;
            4'd9: return 8'h90;
            default: return 8'hFF;
        endcase
    endfunction

    logic [7:0] hex0_dec, hex1_dec, hex2_dec, hex3_dec;
    assign hex0_dec = seven_seg_decode(bcd0);
    assign hex1_dec = seven_seg_decode(bcd1);
    assign hex2_dec = seven_seg_decode(bcd2);
    assign hex3_dec = seven_seg_decode(bcd3);

    assign HEX0 = hex0_dec;
    assign HEX1 = hex1_dec;
    // Display decimal point on HEX2 (which represents 10.00 seconds)
    assign HEX2 = {1'b0, hex2_dec[6:0]};
    assign HEX3 = hex3_dec;
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

    // ---- LED Closeness Feedback ----
    logic [15:0] diff;
    always_comb begin
        if (count > 16'd1000) begin
            diff = count - 16'd1000;
        end else begin
            diff = 16'd1000 - count;
        end
    end

    logic [9:0] led_val;
    always_comb begin
        if (state == IDLE) begin
            led_val = 10'b0;
        end else begin
            if (diff == 0)          led_val = 10'h3FF;
            else if (diff <= 16'd5)  led_val = 10'h1FF;
            else if (diff <= 16'd10) led_val = 10'h0FF;
            else if (diff <= 16'd15) led_val = 10'h07F;
            else if (diff <= 16'd20) led_val = 10'h03F;
            else if (diff <= 16'd25) led_val = 10'h01F;
            else if (diff <= 16'd30) led_val = 10'h00F;
            else if (diff <= 16'd35) led_val = 10'h007;
            else if (diff <= 16'd40) led_val = 10'h003;
            else if (diff <= 16'd50) led_val = 10'h001;
            else                     led_val = 10'h000;
        end
    end
    assign LEDR = led_val;

    // ---- UART Transmission ----
    typedef enum logic [2:0] {
        TX_IDLE,
        TX_CHAR3,
        TX_CHAR2,
        TX_CHAR1,
        TX_CHAR0,
        TX_NL,
        TX_WAIT
    } tx_state_t;

    tx_state_t tx_state;
    logic [7:0] tx_byte;
    logic tx_trigger;
    logic tx_busy;
    logic uart_tx_out;

    uart_tx #(
        .CLK_FREQ(50_000_000),
        .BAUD(9600)
    ) u_tx (
        .clk(MAX10_CLK1_50),
        .rst_n(KEY[1]),
        .tx_data(tx_byte),
        .tx_start(tx_trigger),
        .tx(uart_tx_out),
        .tx_busy(tx_busy)
    );

    always_ff @(posedge MAX10_CLK1_50 or negedge KEY[1]) begin
        if (!KEY[1]) begin
            tx_state   <= TX_IDLE;
            tx_trigger <= 0;
            tx_byte    <= 0;
        end else begin
            tx_trigger <= 0;
            case (tx_state)
                TX_IDLE: begin
                    if (state == RUNNING && key0_pressed) begin
                        tx_state <= TX_CHAR3;
                    end
                end
                TX_CHAR3: begin
                    if (!tx_busy && !tx_trigger) begin
                        tx_byte    <= {4'h3, bcd3};
                        tx_trigger <= 1;
                        tx_state   <= TX_CHAR2;
                    end
                end
                TX_CHAR2: begin
                    if (!tx_busy && !tx_trigger) begin
                        tx_byte    <= {4'h3, bcd2};
                        tx_trigger <= 1;
                        tx_state   <= TX_CHAR1;
                    end
                end
                TX_CHAR1: begin
                    if (!tx_busy && !tx_trigger) begin
                        tx_byte    <= {4'h3, bcd1};
                        tx_trigger <= 1;
                        tx_state   <= TX_CHAR0;
                    end
                end
                TX_CHAR0: begin
                    if (!tx_busy && !tx_trigger) begin
                        tx_byte    <= {4'h3, bcd0};
                        tx_trigger <= 1;
                        tx_state   <= TX_NL;
                    end
                end
                TX_NL: begin
                    if (!tx_busy && !tx_trigger) begin
                        tx_byte    <= 8'h0A; // '\n'
                        tx_trigger <= 1;
                        tx_state   <= TX_WAIT;
                    end
                end
                TX_WAIT: begin
                    if (!tx_busy) begin
                        tx_state <= TX_IDLE;
                    end
                end
            endcase
        end
    end

    // Arduino header UART RX/TX connection
    assign ARDUINO_IO[0]    = 1'bz;
    assign ARDUINO_IO[1]    = uart_tx_out;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_RESET_N  = 1'bz;

endmodule
