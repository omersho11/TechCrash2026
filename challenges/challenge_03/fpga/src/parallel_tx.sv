module parallel_tx #(
    parameter CLK_FREQ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,     // Starts the transaction, resets counters
    input  wire        tx_start,  // Top module wants to send a byte
    input  wire [7:0]  tx_data,   // Byte data
    output reg         tx_busy,   // High when we cannot accept a byte
    output reg  [3:0]  parallel_data, // 4-bit parallel data
    output reg         strobe     // Strobe clock signal
);

    // ---- Packing domain variables ----
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

    // ---- Serializer variables ----
    reg        serializer_load;
    reg [15:0] sr_left;
    reg [15:0] sr_right;
    reg [2:0]  nibble_idx; // 0 to 7 (8 nibbles in a 32-bit frame)
    reg [5:0]  delay_cnt;  // Delay counter for strobe frequency
    reg        state_tx;   // 0: IDLE, 1: TX

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            parallel_data   <= 0;
            strobe          <= 0;
            sr_left         <= 0;
            sr_right        <= 0;
            nibble_idx      <= 0;
            delay_cnt       <= 0;
            state_tx        <= 0;
            serializer_load <= 0;
        end else if (start) begin
            parallel_data   <= 0;
            strobe          <= 0;
            sr_left         <= 0;
            sr_right        <= 0;
            nibble_idx      <= 0;
            delay_cnt       <= 0;
            state_tx        <= 0;
            serializer_load <= 0;
        end else begin
            serializer_load <= 0;

            if (!state_tx) begin
                if (frame_ready) begin
                    sr_left         <= buf_left;
                    sr_right        <= buf_right;
                    serializer_load <= 1;
                    state_tx        <= 1;
                    nibble_idx      <= 0;
                    delay_cnt       <= 0;
                end
            end else begin
                if (delay_cnt == 200) begin // 4 us per nibble (250 kHz strobe rate)
                    delay_cnt <= 0;
                    
                    if (nibble_idx == 7) begin
                        if (frame_ready) begin
                            sr_left         <= buf_left;
                            sr_right        <= buf_right;
                            serializer_load <= 1;
                            nibble_idx      <= 0;
                        end else begin
                            state_tx <= 0;
                        end
                    end else begin
                        nibble_idx <= nibble_idx + 1;
                    end
                end else begin
                    delay_cnt <= delay_cnt + 1;
                end

                // Drive parallel data and toggle strobe
                if (delay_cnt == 0) begin
                    case (nibble_idx)
                        3'd0: parallel_data <= sr_left[15:12];
                        3'd1: parallel_data <= sr_left[11:8];
                        3'd2: parallel_data <= sr_left[7:4];
                        3'd3: parallel_data <= sr_left[3:0];
                        3'd4: parallel_data <= sr_right[15:12];
                        3'd5: parallel_data <= sr_right[11:8];
                        3'd6: parallel_data <= sr_right[7:4];
                        3'd7: parallel_data <= sr_right[3:0];
                    endcase
                end
                if (delay_cnt == 100) begin
                    strobe <= ~strobe;
                end
            end
        end
    end

    // ---- Packing Engine ----
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
