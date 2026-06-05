// spi_tx.sv
// Custom SPI Master for Challenge 3.
// Packs 4-byte header, 1 full byte, then 9999 LSB bits into 1255 bytes.
// Transmits serialized SPI data (MOSI, SCLK).

module spi_tx #(
    parameter CLK_DIV = 4  // Period of SCLK in system clock cycles
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,     // Resets counters (tied to start_pulse)
    input  wire        tx_start,  // Trigger sending a byte
    input  wire [7:0]  tx_data,   // Byte to send / compress
    output reg         tx_busy,   // High when serializing and cannot accept new input
    output reg         mosi,      // SPI Master Out Slave In
    output reg         sclk       // SPI Clock
);

    localparam HALF_DIV = CLK_DIV / 2;

    // Byte counter to track protocol phase:
    // 0..3: Header bytes (sent in full)
    // 4: First data byte b_0 (sent in full)
    // 5..10003: Data bytes b_1..b_9999 (LSBs only)
    reg [13:0] byte_cnt;

    // Bit packing for LSBs
    reg [7:0]  pack_buf;
    reg [2:0]  pack_len;

    // Serializer state machine
    typedef enum logic {
        S_IDLE,
        S_SHIFT
    } state_t;
    state_t state;

    reg [7:0]  shift_reg;
    reg [2:0]  bit_cnt;
    reg [7:0]  clk_cnt;

    // Internal signal to trigger serialization of a packed or raw byte
    reg        serialize_start;
    reg [7:0]  serialize_data;
    wire       serializer_busy = (state == S_SHIFT);

    reg [7:0]  startup_delay;

    // Combine busy signals: we are busy if the serializer is active, OR if we are waiting for the startup delay.
    always @(*) begin
        if (startup_delay > 0) begin
            tx_busy = 1;
        end else begin
            tx_busy = (state != S_IDLE) || serialize_start;
        end
    end

    // ---- Packing and Flow Control ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt        <= 0;
            pack_buf        <= 0;
            pack_len        <= 0;
            serialize_start <= 0;
            serialize_data  <= 0;
            startup_delay   <= 8'd100;
        end else if (start) begin
            byte_cnt        <= 0;
            pack_buf        <= 0;
            pack_len        <= 0;
            serialize_start <= 0;
            serialize_data  <= 0;
            startup_delay   <= 8'd100;
        end else begin
            serialize_start <= 0;

            if (startup_delay > 0) begin
                startup_delay <= startup_delay - 1;
            end else if (tx_start && !tx_busy) begin
                byte_cnt <= byte_cnt + 1;

                if (byte_cnt < 14'd4) begin
                    // Header bytes: send directly
                    serialize_data  <= tx_data;
                    serialize_start <= 1;
                end else if (byte_cnt == 14'd4) begin
                    // First data byte: send directly
                    serialize_data  <= tx_data;
                    serialize_start <= 1;
                    pack_buf        <= 0;
                    pack_len        <= 0;
                end else begin
                    // LSB bytes (byte_cnt > 4): pack LSB
                    // Pack from LSB to MSB: pack_buf[pack_len] <= tx_data[0]
                    // (Matches: lsb_k at bit offset (k-1) % 8)
                    pack_buf[pack_len] <= tx_data[0];

                    if (pack_len == 3'd7) begin
                        // Buffer is full (8 bits collected), send it!
                        serialize_data  <= {tx_data[0], pack_buf[6:0]};
                        serialize_start <= 1;
                        pack_len        <= 0;
                    end else if (byte_cnt == 14'd10003) begin
                        // This is the last byte, send whatever we have in the buffer (padded with 0)
                        serialize_data  <= {1'b0, tx_data[0], pack_buf[5:0]};
                        serialize_start <= 1;
                        pack_len        <= 0;
                    end else begin
                        pack_len <= pack_len + 1;
                    end
                end
            end
        end
    end

    // ---- SPI Serializer ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            mosi      <= 0;
            sclk      <= 0;
            shift_reg <= 0;
            bit_cnt   <= 0;
            clk_cnt   <= 0;
        end else if (start) begin
            state     <= S_IDLE;
            mosi      <= 0;
            sclk      <= 0;
            shift_reg <= 0;
            bit_cnt   <= 0;
            clk_cnt   <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    sclk <= 0;
                    if (serialize_start) begin
                        shift_reg <= serialize_data;
                        bit_cnt   <= 0;
                        clk_cnt   <= 0;
                        // SPI Mode 0: change data on falling/idle edge, sample on rising edge
                        mosi      <= serialize_data[7]; // MSB-first transmission
                        state     <= S_SHIFT;
                    end
                end

                S_SHIFT: begin
                    if (clk_cnt == HALF_DIV - 1) begin
                        sclk    <= 1; // Rising edge
                        clk_cnt <= clk_cnt + 1;
                    end else if (clk_cnt == CLK_DIV - 1) begin
                        sclk    <= 0; // Falling edge
                        clk_cnt <= 0;
                        
                        if (bit_cnt == 3'd7) begin
                            state <= S_IDLE;
                        end else begin
                            bit_cnt   <= bit_cnt + 1;
                            shift_reg <= {shift_reg[6:0], 1'b0};
                            mosi      <= shift_reg[6]; // Shift out next bit (MSB first)
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end

endmodule
