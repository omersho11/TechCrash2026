module i2s_tx #(
    parameter CLK_FREQ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,     // Starts the transaction, resets counters
    input  wire        tx_start,  // Top module wants to send a byte
    input  wire [7:0]  tx_data,   // Byte data
    output reg         tx_busy,   // High when we cannot accept a byte
    input  wire        bclk,      // I2S Bit Clock (from ESP32)
    input  wire        ws,        // I2S Word Select (from ESP32)
    output reg         sd         // I2S Serial Data
);

    // ---- CDC Toggle Handshake Signals ----
    reg        req;
    reg        ack;

    // Synchronize req (clk -> bclk)
    reg req_sync0, req_sync1;
    always @(posedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            req_sync0 <= 0;
            req_sync1 <= 0;
        end else begin
            req_sync0 <= req;
            req_sync1 <= req_sync0;
        end
    end

    // Synchronize ack (bclk -> clk)
    reg ack_sync0, ack_sync1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_sync0 <= 0;
            ack_sync1 <= 0;
        end else begin
            ack_sync0 <= ack;
            ack_sync1 <= ack_sync0;
        end
    end

    // Synchronize start to bclk domain (toggle synchronizer)
    reg start_toggle;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_toggle <= 0;
        end else if (start) begin
            start_toggle <= ~start_toggle;
        end
    end

    reg start_sync0, start_sync1, start_sync2;
    always @(posedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            start_sync0 <= 0;
            start_sync1 <= 0;
            start_sync2 <= 0;
        end else begin
            start_sync0 <= start_toggle;
            start_sync1 <= start_sync0;
            start_sync2 <= start_sync1;
        end
    end
    wire start_bclk = (start_sync1 != start_sync2);

    // ---- Packing domain (clk) variables ----
    reg [31:0] byte_count;
    reg [2:0]  lfsr_bit_cnt;
    reg [7:0]  shifter;
    reg [31:0] expected_data_len;
    reg [31:0] comp_byte_count;

    reg [15:0] buf_left;
    reg [15:0] buf_right;
    reg        ack_r;

    wire       is_last = (byte_count == expected_data_len + 3) && (expected_data_len > 0);
    reg [7:0]  next_shifter;

    // ---- Serializer domain (bclk) variables ----
    reg        ws_sync;
    reg        ws_sync_r;
    reg        req_sync_r;

    reg [5:0]  bit_index;
    reg [15:0] sr_left;
    reg [15:0] sr_right;

    // Sample ws on posedge bclk to avoid setup/hold hazards
    always @(posedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            ws_sync <= 1;
        end else begin
            ws_sync <= ws;
        end
    end

    wire ws_rising  = ws_sync & ~ws_sync_r;
    wire ws_falling = ~ws_sync & ws_sync_r;

    always @(negedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            ws_sync_r  <= 1;
            req_sync_r <= 0;
            ack        <= 0;
            sd         <= 0;
            bit_index  <= 0;
            sr_left    <= 0;
            sr_right   <= 0;
        end else begin
            ws_sync_r <= ws_sync;

            if (ws_rising) begin
                bit_index <= 0;
                // Check if new frame is ready
                if (req_sync1 != req_sync_r) begin
                    sr_left    <= buf_left;
                    sr_right   <= buf_right;
                    sd         <= buf_left[15];
                    ack        <= ~ack;
                    req_sync_r <= req_sync1;
                end else begin
                    sr_left  <= 16'd0;
                    sr_right <= 16'd0;
                    sd       <= 1'b0;
                end
            end else if (ws_falling) begin
                sd        <= sr_right[15];
                bit_index <= 16;
            end else begin
                // Normal bit shifting on falling edge of BCLK
                // (Note: always block is triggered on negedge bclk)
                if (bit_index < 15) begin
                    sd <= sr_left[14 - bit_index];
                end else if (bit_index == 15) begin
                    // Wait for ws_falling
                end else if (bit_index > 15 && bit_index < 31) begin
                    sd <= sr_right[30 - bit_index];
                end else if (bit_index == 31) begin
                    // Wait for ws_rising
                end
                bit_index <= bit_index + 1;
            end
        end
    end

    // ---- Packing Engine (clk domain) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_busy           <= 0;
            byte_count        <= 0;
            lfsr_bit_cnt      <= 0;
            shifter           <= 0;
            expected_data_len <= 0;
            buf_left          <= 0;
            buf_right         <= 0;
            comp_byte_count   <= 0;
            req               <= 0;
            ack_r             <= 0;
            next_shifter      <= 0;
        end else if (start) begin
            tx_busy           <= 0;
            byte_count        <= 0;
            lfsr_bit_cnt      <= 0;
            shifter           <= 0;
            expected_data_len <= 0;
            buf_left          <= 0;
            buf_right         <= 0;
            comp_byte_count   <= 0;
            ack_r             <= ack_sync1;
            next_shifter      <= 0;
        end else begin
            // CDC Handshake: clear busy when ack toggles
            if (ack_sync1 != ack_r) begin
                tx_busy <= 0;
                ack_r   <= ack_sync1;
            end

            if (!tx_busy && tx_start) begin
                byte_count <= byte_count + 1;

                if (byte_count == 0) expected_data_len[7:0]   <= tx_data;
                if (byte_count == 1) expected_data_len[15:8]  <= tx_data;
                if (byte_count == 2) expected_data_len[23:16] <= tx_data;
                if (byte_count == 3) expected_data_len[31:24] <= tx_data;

                if (byte_count < 4) begin
                    if (byte_count == 0) begin
                        buf_left[15:8] <= tx_data;
                    end else if (byte_count == 1) begin
                        buf_left[7:0] <= tx_data;
                    end else if (byte_count == 2) begin
                        buf_right[15:8] <= tx_data;
                    end else if (byte_count == 3) begin
                        buf_right[7:0] <= tx_data;
                        req            <= ~req; // Trigger serialization
                        tx_busy        <= 1;
                    end
                end else if (byte_count == 4) begin
                    buf_left        <= {tx_data, 8'd0};
                    comp_byte_count <= 0;
                end else begin
                    // Compression
                    if (is_last) begin
                        next_shifter = {tx_data[0], shifter[7:1]};
                        next_shifter = next_shifter >> (7 - lfsr_bit_cnt);
                    end else begin
                        next_shifter = {tx_data[0], shifter[7:1]};
                    end

                    shifter <= next_shifter;

                    if (lfsr_bit_cnt == 7 || is_last) begin
                        lfsr_bit_cnt    <= 0;
                        comp_byte_count <= comp_byte_count + 1;

                        case (comp_byte_count[1:0])
                            2'b00: begin
                                buf_right[15:8] <= next_shifter;
                                if (is_last) begin
                                    buf_right[7:0] <= 8'd0;
                                    req            <= ~req;
                                    tx_busy        <= 1;
                                end
                            end
                            2'b01: begin
                                buf_right[7:0] <= next_shifter;
                                req            <= ~req;
                                tx_busy        <= 1;
                            end
                            2'b10: begin
                                buf_left[15:8] <= next_shifter;
                                if (is_last) begin
                                    buf_left[7:0] <= 8'd0;
                                    buf_right     <= 16'd0;
                                    req           <= ~req;
                                    tx_busy       <= 1;
                                end
                            end
                            2'b11: begin
                                buf_left[7:0] <= next_shifter;
                                if (is_last) begin
                                    buf_right     <= 16'd0;
                                    req           <= ~req;
                                    tx_busy       <= 1;
                                end
                            end
                        endcase
                    end else begin
                        lfsr_bit_cnt <= lfsr_bit_cnt + 1;
                    end
                end
            end
        end
    end

endmodule
