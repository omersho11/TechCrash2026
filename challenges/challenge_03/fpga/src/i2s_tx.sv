module i2s_tx #(
    parameter CLK_FREQ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,     // Starts the transaction, resets counters
    input  wire        tx_start,  // Top module wants to send a byte
    input  wire [7:0]  tx_data,   // Byte data
    output reg         tx_busy,   // High when we cannot accept a byte
    output reg         bclk,      // I2S Bit Clock (output)
    output reg         ws,        // I2S Word Select (output)
    output reg         sd         // I2S Serial Data (output)
);

    // ---- Packing domain (clk) variables ----
    reg [31:0] byte_count;
    reg [2:0]  lfsr_bit_cnt;
    reg [7:0]  shifter;
    reg [31:0] expected_data_len;
    reg [31:0] comp_byte_count;

    reg [15:0] buf_left;
    reg [15:0] buf_right;
    reg        frame_ready;

    wire       is_last = (byte_count == expected_data_len + 3) && (expected_data_len > 0);
    reg [7:0]  next_shifter;

    // ---- Serializer (clk domain) ----
    reg        serializer_load;
    reg [15:0] sr_left;
    reg [15:0] sr_right;
    reg [3:0]  bclk_div;
    reg [4:0]  ws_div;
    reg        tx_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk            <= 0;
            ws              <= 0;
            sd              <= 0;
            sr_left         <= 0;
            sr_right        <= 0;
            bclk_div        <= 0;
            ws_div          <= 0;
            tx_active       <= 0;
            serializer_load <= 0;
        end else if (start) begin
            // Keep clocks running to avoid glitching ESP32 synchronization,
            // just reset the serialization state.
            sd              <= 0;
            sr_left         <= 0;
            sr_right        <= 0;
            tx_active       <= 0;
            serializer_load <= 0;
        end else begin
            serializer_load <= 0;

            // Continuous clock divider
            bclk_div <= bclk_div + 1;

            if (bclk_div == 7) begin
                bclk   <= 0; // Falling edge
                ws_div <= ws_div + 1;

                // WS is 1 for Left (cycles 0-15), 0 for Right (cycles 16-31)
                if (ws_div <= 15) begin
                    ws <= 1;
                end else begin
                    ws <= 0;
                end

                // Serialization
                if (tx_active) begin
                    if (ws_div <= 15) begin
                        sd <= sr_left[15 - ws_div];
                    end else begin
                        sd <= sr_right[31 - ws_div];
                    end
                end else begin
                    sd <= 0;
                end

                // Load new frame at the end of the current frame boundary
                if (ws_div == 31) begin
                    if (frame_ready) begin
                        sr_left         <= buf_left;
                        sr_right        <= buf_right;
                        serializer_load <= 1;
                        tx_active       <= 1;
                    end else begin
                        tx_active <= 0;
                    end
                end
            end else if (bclk_div == 15) begin
                bclk     <= 1; // Rising edge
                bclk_div <= 0;
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
            next_shifter      <= 0;
            frame_ready       <= 0;
        end else if (start) begin
            tx_busy           <= 0;
            byte_count        <= 0;
            lfsr_bit_cnt      <= 0;
            shifter           <= 0;
            expected_data_len <= 0;
            buf_left          <= 0;
            buf_right         <= 0;
            comp_byte_count   <= 0;
            next_shifter      <= 0;
            frame_ready       <= 0;
        end else begin
            if (serializer_load) begin
                frame_ready <= 0;
                tx_busy     <= 0;
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
                        frame_ready    <= 1;
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
                                    frame_ready    <= 1;
                                    tx_busy        <= 1;
                                end
                            end
                            2'b01: begin
                                buf_right[7:0] <= next_shifter;
                                frame_ready    <= 1;
                                tx_busy        <= 1;
                            end
                            2'b10: begin
                                buf_left[15:8] <= next_shifter;
                                if (is_last) begin
                                    buf_left[7:0] <= 8'd0;
                                    buf_right     <= 16'd0;
                                    frame_ready   <= 1;
                                    tx_busy       <= 1;
                                end
                            end
                            2'b11: begin
                                buf_left[7:0] <= next_shifter;
                                if (is_last) begin
                                    buf_right     <= 16'd0;
                                    frame_ready   <= 1;
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
