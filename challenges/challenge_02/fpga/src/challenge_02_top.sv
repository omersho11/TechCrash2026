// ============================================================
// CrashTech VLSI-2026 — Challenge 2: Accelerometer 3D Cube (FPGA Top)
// ============================================================
// Configures onboard ADXL345 via SPI:
//   1. DATA_FORMAT (0x31) = 0x08 (4-wire SPI, Full Resolution, +/-2g)
//   2. POWER_CTL (0x2D) = 0x08 (Measurement Mode)
// Reads X, Y, Z acceleration data (6 bytes starting at 0x32)
// Sends raw packet to ESP32: [0xAA, X_H, X_L, Y_H, Y_L, Z_H, Z_L, 0x55]
// Maps tilt direction to LEDRs.
// ============================================================

module challenge_02_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N,
    
    // Onboard G-Sensor SPI pins
    output          GSENSOR_CS_N,
    output          GSENSOR_SCLK,
    output          GSENSOR_SDI, // MOSI (FPGA Output)
    input           GSENSOR_SDO  // MISO (FPGA Input)
);

    wire clk = MAX10_CLK1_50;
    wire rst_n = KEY[0];

    // ---- Arduino Header UART Pins ----
    wire uart_tx_out;
    assign ARDUINO_IO[0] = 1'bz;          // RX is input
    assign ARDUINO_IO[1] = uart_tx_out;   // TX is output
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_RESET_N = 1'bz;

    // ---- UART Transmitter (9600 baud) ----
    localparam CLKS_PER_BIT = 5208; // 50,000,000 / 9600
    
    reg [7:0]  uart_tx_data;
    reg        uart_tx_start;
    wire       uart_tx_busy;

    uart_tx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) utx (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(uart_tx_data),
        .tx_start(uart_tx_start),
        .tx_busy(uart_tx_busy),
        .tx_out(uart_tx_out)
    );

    // ---- SPI and ADXL345 Controller ----
    // SCLK frequency: 50MHz / 32 = 1.56MHz
    reg [4:0]  spi_clk_div;
    reg        spi_tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_clk_div <= 0;
            spi_tick    <= 0;
        end else begin
            if (spi_clk_div == 31) begin
                spi_clk_div <= 0;
                spi_tick    <= 1;
            end else begin
                spi_clk_div <= spi_clk_div + 1;
                spi_tick    <= 0;
            end
        end
    end

    // FSM States
    typedef enum logic [4:0] {
        ST_RESET,
        ST_POWER_ON_DELAY,
        ST_INIT_FORMAT_CS_L,
        ST_INIT_FORMAT_ADDR,
        ST_INIT_FORMAT_DATA,
        ST_INIT_FORMAT_CS_H,
        ST_INIT_POWER_CS_L,
        ST_INIT_POWER_ADDR,
        ST_INIT_POWER_DATA,
        ST_INIT_POWER_CS_H,
        ST_DELAY,
        ST_IDLE,
        ST_READ_CS_L,
        ST_READ_ADDR,
        ST_READ_DATA,
        ST_READ_CS_H,
        ST_UART_SEND
    } state_t;

    state_t state;
    
    reg        sclk_reg;
    reg        cs_n_reg;
    reg        mosi_reg;
    
    assign GSENSOR_CS_N = cs_n_reg;
    assign GSENSOR_SCLK = sclk_reg;
    assign GSENSOR_SDI  = mosi_reg;

    reg [4:0]  spi_tick_cnt; // 0 to 31 inside each bit
    reg [2:0]  bit_cnt;      // 0 to 7
    reg [2:0]  byte_cnt;     // 0 to 5 for reading data
    reg [7:0]  shift_reg;
    
    // ADXL345 Registers and Data Buffers
    reg [7:0]  rx_bytes[0:5]; // X_L, X_H, Y_L, Y_H, Z_L, Z_H
    
    // Sample timer: every 30ms (1,500,000 clock cycles at 50MHz)
    reg [20:0] sample_timer;
    reg        sample_trigger;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_timer   <= 0;
            sample_trigger <= 0;
        end else begin
            sample_trigger <= 0;
            if (sample_timer == 1500000 - 1) begin
                sample_timer   <= 0;
                sample_trigger <= 1;
            end else begin
                sample_timer   <= sample_timer + 1;
            end
        end
    end

    // Delay counter
    reg [23:0] delay_cnt;

    // FSM Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_RESET;
            sclk_reg     <= 1'b1;
            cs_n_reg     <= 1'b1;
            mosi_reg     <= 1'b0;
            spi_tick_cnt <= 0;
            bit_cnt      <= 0;
            byte_cnt     <= 0;
            shift_reg    <= 0;
            delay_cnt    <= 0;
            rx_bytes[0]  <= 8'h00;
            rx_bytes[1]  <= 8'h00;
            rx_bytes[2]  <= 8'h00;
            rx_bytes[3]  <= 8'h00;
            rx_bytes[4]  <= 8'h00;
            rx_bytes[5]  <= 8'h00;
        end else begin
            case (state)
                ST_RESET: begin
                    cs_n_reg     <= 1'b1;
                    sclk_reg     <= 1'b1;
                    mosi_reg     <= 1'b0;
                    spi_tick_cnt <= 0;
                    delay_cnt    <= 0;
                    state        <= ST_POWER_ON_DELAY;
                end

                ST_POWER_ON_DELAY: begin
                    // Wait ~40ms (2,000,000 clock cycles) to let sensor stabilize after power-up
                    if (delay_cnt < 24'd2000000) begin
                        delay_cnt <= delay_cnt + 1;
                    end else begin
                        state <= ST_INIT_FORMAT_CS_L;
                    end
                end

                ST_INIT_FORMAT_CS_L: begin
                    cs_n_reg <= 1'b0;
                    // DATA_FORMAT address is 0x31. Command is Write (0x31)
                    shift_reg <= 8'h31;
                    bit_cnt   <= 7;
                    if (spi_tick) begin
                        state <= ST_INIT_FORMAT_ADDR;
                    end
                end

                ST_INIT_FORMAT_ADDR: begin
                    if (spi_tick) begin
                        if (spi_tick_cnt == 0) begin
                            sclk_reg <= 1'b0;
                            mosi_reg <= shift_reg[bit_cnt];
                            spi_tick_cnt <= 16;
                        end else if (spi_tick_cnt == 16) begin
                            sclk_reg <= 1'b1;
                            spi_tick_cnt <= 0;
                            if (bit_cnt == 0) begin
                                // Load 0x08: 4-wire SPI, Full Resolution, +/-2g
                                shift_reg <= 8'h08;
                                bit_cnt   <= 7;
                                state     <= ST_INIT_FORMAT_DATA;
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                end

                ST_INIT_FORMAT_DATA: begin
                    if (spi_tick) begin
                        if (spi_tick_cnt == 0) begin
                            sclk_reg <= 1'b0;
                            mosi_reg <= shift_reg[bit_cnt];
                            spi_tick_cnt <= 16;
                        end else if (spi_tick_cnt == 16) begin
                            sclk_reg <= 1'b1;
                            spi_tick_cnt <= 0;
                            if (bit_cnt == 0) begin
                                state <= ST_INIT_FORMAT_CS_H;
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                end

                ST_INIT_FORMAT_CS_H: begin
                    if (spi_tick) begin
                        cs_n_reg <= 1'b1;
                        state    <= ST_INIT_POWER_CS_L;
                    end
                end
                
                ST_INIT_POWER_CS_L: begin
                    cs_n_reg <= 1'b0;
                    // POWER_CTL register address is 0x2D. Command is Write (0x2D)
                    shift_reg <= 8'h2D; 
                    bit_cnt   <= 7;
                    if (spi_tick) begin
                        state <= ST_INIT_POWER_ADDR;
                    end
                end
                
                ST_INIT_POWER_ADDR: begin
                    if (spi_tick) begin
                        if (spi_tick_cnt == 0) begin
                            sclk_reg <= 1'b0;
                            mosi_reg <= shift_reg[bit_cnt];
                            spi_tick_cnt <= 16;
                        end else if (spi_tick_cnt == 16) begin
                            sclk_reg <= 1'b1;
                            spi_tick_cnt <= 0;
                            if (bit_cnt == 0) begin
                                // Address sent, load data byte 0x08 (Measurement Mode)
                                shift_reg <= 8'h08;
                                bit_cnt   <= 7;
                                state     <= ST_INIT_POWER_DATA;
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                end
                
                ST_INIT_POWER_DATA: begin
                    if (spi_tick) begin
                        if (spi_tick_cnt == 0) begin
                            sclk_reg <= 1'b0;
                            mosi_reg <= shift_reg[bit_cnt];
                            spi_tick_cnt <= 16;
                        end else if (spi_tick_cnt == 16) begin
                            sclk_reg <= 1'b1;
                            spi_tick_cnt <= 0;
                            if (bit_cnt == 0) begin
                                state <= ST_INIT_POWER_CS_H;
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                end
                
                ST_INIT_POWER_CS_H: begin
                    if (spi_tick) begin
                        cs_n_reg  <= 1'b1;
                        delay_cnt <= 0;
                        state     <= ST_DELAY;
                    end
                end
                
                ST_DELAY: begin
                    // Wait ~200us (10,000 cycles) before starting measurement reads
                    if (delay_cnt < 24'd10000) begin
                        delay_cnt <= delay_cnt + 1;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
                
                ST_IDLE: begin
                    cs_n_reg <= 1'b1;
                    sclk_reg <= 1'b1;
                    mosi_reg <= 1'b0;
                    if (sample_trigger) begin
                        state <= ST_READ_CS_L;
                    end
                end
                
                ST_READ_CS_L: begin
                    cs_n_reg <= 1'b0;
                    // Command: Read + MB + 0x32 (DATAX0 address) => 0xF2
                    shift_reg <= 8'hF2;
                    bit_cnt   <= 7;
                    byte_cnt  <= 0;
                    if (spi_tick) begin
                        state <= ST_READ_ADDR;
                    end
                end
                
                ST_READ_ADDR: begin
                    if (spi_tick) begin
                        if (spi_tick_cnt == 0) begin
                            sclk_reg <= 1'b0;
                            mosi_reg <= shift_reg[bit_cnt];
                            spi_tick_cnt <= 16;
                        end else if (spi_tick_cnt == 16) begin
                            sclk_reg <= 1'b1;
                            spi_tick_cnt <= 0;
                            if (bit_cnt == 0) begin
                                bit_cnt  <= 7;
                                byte_cnt <= 0;
                                state    <= ST_READ_DATA;
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                end
                
                ST_READ_DATA: begin
                    if (spi_tick) begin
                        if (spi_tick_cnt == 0) begin
                            sclk_reg <= 1'b0;
                            spi_tick_cnt <= 16;
                        end else if (spi_tick_cnt == 16) begin
                            sclk_reg <= 1'b1;
                            // Sample input bit from GSENSOR_SDO
                            shift_reg[bit_cnt] <= GSENSOR_SDO;
                            spi_tick_cnt <= 0;
                            
                            if (bit_cnt == 0) begin
                                rx_bytes[byte_cnt] <= {shift_reg[7:1], GSENSOR_SDO};
                                bit_cnt <= 7;
                                if (byte_cnt == 5) begin
                                    state <= ST_READ_CS_H;
                                end else begin
                                    byte_cnt <= byte_cnt + 1;
                                end
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                end
                
                ST_READ_CS_H: begin
                    if (spi_tick) begin
                        cs_n_reg <= 1'b1;
                        state    <= ST_UART_SEND;
                    end
                end
                
                ST_UART_SEND: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    // ---- UART Packet Dispatcher ----
    reg [2:0] tx_buffer_state;
    reg [7:0] tx_buffer[0:7];
    reg [2:0] tx_index;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_buffer_state <= 0;
            tx_index        <= 0;
            uart_tx_start   <= 0;
            uart_tx_data    <= 0;
        end else begin
            uart_tx_start <= 0;
            case (tx_buffer_state)
                0: begin // Idle, wait for trigger
                    if (state == ST_UART_SEND) begin
                        tx_buffer[0]    <= 8'hAA;         // Header
                        tx_buffer[1]    <= rx_bytes[1];    // X_H
                        tx_buffer[2]    <= rx_bytes[0];    // X_L
                        tx_buffer[3]    <= rx_bytes[3];    // Y_H
                        tx_buffer[4]    <= rx_bytes[2];    // Y_L
                        tx_buffer[5]    <= rx_bytes[5];    // Z_H
                        tx_buffer[6]    <= rx_bytes[4];    // Z_L
                        tx_buffer[7]    <= 8'h55;         // Trailer
                        tx_index        <= 0;
                        tx_buffer_state <= 1;
                    end
                end
                
                1: begin // Send current byte
                    uart_tx_data    <= tx_buffer[tx_index];
                    uart_tx_start   <= 1;
                    tx_buffer_state <= 2;
                end
                
                2: begin // Wait 1 cycle for transmitter to accept it
                    uart_tx_start   <= 0;
                    tx_buffer_state <= 3;
                end
                
                3: begin // Wait for transmission to finish
                    if (!uart_tx_busy) begin
                        if (tx_index == 7) begin
                            tx_buffer_state <= 0;
                        end else begin
                            tx_index        <= tx_index + 1;
                            tx_buffer_state <= 1;
                        end
                    end
                end
                default: tx_buffer_state <= 0;
            endcase
        end
    end

    // ---- LED Indicators for Tilt Direction ----
    // Raw acceleration: 10-bit signed value.
    // 3.9mg/LSB means 1g is ~256. 
    // We set a threshold of 40 LSB for tilt feedback.
    wire signed [15:0] accel_x = {rx_bytes[1], rx_bytes[0]};
    wire signed [15:0] accel_y = {rx_bytes[3], rx_bytes[2]};

    reg [9:0] ledr_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ledr_reg <= 0;
        end else begin
            ledr_reg <= 10'd0;
            // Forward tilt: Y positive -> light up LEDR[9:8]
            if (accel_y > 16'sd40) begin
                ledr_reg[9:8] <= 2'b11;
            end
            // Backward tilt: Y negative -> light up LEDR[1:0]
            if (accel_y < -16'sd40) begin
                ledr_reg[1:0] <= 2'b11;
            end
            // Right tilt: X positive -> light up LEDR[4:2]
            if (accel_x > 16'sd40) begin
                ledr_reg[4:2] <= 3'b111;
            end
            // Left tilt: X negative -> light up LEDR[7:5]
            if (accel_x < -16'sd40) begin
                ledr_reg[7:5] <= 3'b111;
            end
        end
    end
    assign LEDR = ledr_reg;

    // ---- Unused Hex Displays (Blank them) ----
    assign HEX0 = 8'hFF;
    assign HEX1 = 8'hFF;
    assign HEX2 = 8'hFF;
    assign HEX3 = 8'hFF;
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

endmodule

// ============================================================
// Simple UART Transmitter
// ============================================================
module uart_tx #(
    parameter CLKS_PER_BIT = 5208
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] tx_data,
    input  logic       tx_start,
    output logic       tx_busy,
    output logic       tx_out
);

    logic [15:0] clk_cnt;
    logic [3:0]  bit_idx;
    logic [9:0]  tx_shift;
    
    assign tx_busy = (bit_idx != 4'd10);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt  <= 0;
            bit_idx  <= 4'd10; // Idle
            tx_shift <= 10'b1111111111;
            tx_out   <= 1'b1;
        end else begin
            if (bit_idx == 4'd10) begin
                tx_out <= 1'b1;
                if (tx_start) begin
                    tx_shift <= {1'b1, tx_data, 1'b0}; // Stop bit, data, start bit
                    bit_idx  <= 0;
                    clk_cnt  <= 0;
                    tx_out   <= 1'b0; // Start bit
                end
            end else begin
                if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 0;
                    if (bit_idx == 8) begin
                        tx_out  <= tx_shift[9]; // Stop bit
                        bit_idx <= bit_idx + 1;
                    end else if (bit_idx == 9) begin
                        bit_idx <= 4'd10; // Back to Idle
                    end else begin
                        tx_out  <= tx_shift[bit_idx + 1];
                        bit_idx <= bit_idx + 1;
                    end
                end else begin
                    clk_cnt <= clk_cnt + 1;
                end
            end
        end
    end

endmodule
