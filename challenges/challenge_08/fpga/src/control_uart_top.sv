module control_uart_top #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 115_200,
    parameter integer UPDATE_HZ = 100,
    parameter integer SWITCH_DEBOUNCE_MS = 5,
    parameter integer ADC_REF_MV = 3300,
    parameter integer ADC_MAX_MV = 2240
)(
    input  wire       MAX10_CLK1_50,
    input  wire [1:0] KEY,
    input  wire [9:0] SW,
    output wire [9:0] LEDR,
    output wire       FPGA_UART_TX
);

    localparam integer UPDATE_TICKS = CLK_FREQ / UPDATE_HZ;
    localparam integer SWITCH_DEBOUNCE_TICKS = (CLK_FREQ / 1000) * SWITCH_DEBOUNCE_MS;
    localparam integer ADC_MAX_RAW = (4095 * ADC_MAX_MV) / ADC_REF_MV;

    wire clk = MAX10_CLK1_50;
    wire rst_n = 1'b1;

    reg [1:0] key_meta;
    reg [1:0] key_sync;
    reg [9:0] sw_meta;
    reg [9:0] sw_sync;
    reg [9:0] sw_candidate;
    reg [9:0] sw_debounced;
    reg [31:0] sw_stable_count;

    initial begin
        key_meta        <= 2'b11;
        key_sync        <= 2'b11;
        sw_meta         <= 10'd0;
        sw_sync         <= 10'd0;
        sw_candidate    <= 10'd0;
        sw_debounced    <= 10'd0;
        sw_stable_count <= 32'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta        <= 2'b11;
            key_sync        <= 2'b11;
            sw_meta         <= 10'd0;
            sw_sync         <= 10'd0;
            sw_candidate    <= 10'd0;
            sw_debounced    <= 10'd0;
            sw_stable_count <= 32'd0;
        end else begin
            key_meta <= KEY;
            key_sync <= key_meta;
            sw_meta  <= SW;
            sw_sync  <= sw_meta;

            if (sw_sync != sw_candidate) begin
                sw_candidate    <= sw_sync;
                sw_stable_count <= 32'd0;
            end else if (sw_stable_count < SWITCH_DEBOUNCE_TICKS) begin
                sw_stable_count <= sw_stable_count + 32'd1;
            end else begin
                sw_debounced <= sw_candidate;
            end
        end
    end

    wire [1:0] key_pressed = ~key_sync;

    reg [31:0] tick_count;
    reg        send_pending;
    wire       start_byte;

    initial begin
        tick_count   <= 32'd0;
        send_pending <= 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_count   <= 32'd0;
            send_pending <= 1'b0;
        end else if (tick_count == UPDATE_TICKS - 1) begin
            tick_count   <= 32'd0;
            send_pending <= 1'b1;
        end else begin
            tick_count <= tick_count + 32'd1;
            if (start_byte)
                send_pending <= 1'b0;
        end
    end

    reg        tx_start;
    reg [7:0]  tx_data;
    wire       tx_busy;
    reg        tx_busy_d;
    reg [2:0]  byte_index;
    reg        sending;
    reg [1:0]  keys_latched;
    reg [9:0]  switches_latched;
    reg [7:0]  adc0_norm_latched;
    reg [7:0]  adc1_norm_latched;
    wire [11:0] adc0_value;
    wire [11:0] adc1_value;
    wire [11:0] adc_unused_2;
    wire [11:0] adc_unused_3;
    wire [11:0] adc_unused_4;
    wire [11:0] adc_unused_5;
    wire [11:0] adc_unused_6;
    wire [11:0] adc_unused_7;
    wire adc_sclk_unused;
    wire adc_cs_n_unused;
    wire adc_din_unused;

    assign start_byte = send_pending && !sending && !tx_busy;
    wire tx_done = tx_busy_d && !tx_busy;

    function [7:0] normalize_adc;
        input [11:0] raw;
        integer scaled;
        begin
            if (raw >= ADC_MAX_RAW) begin
                normalize_adc = 8'hFF;
            end else begin
                scaled = (raw * 255 + (ADC_MAX_RAW / 2)) / ADC_MAX_RAW;
                normalize_adc = scaled[7:0];
            end
        end
    endfunction

    initial begin
        tx_start         <= 1'b0;
        tx_data          <= 8'h00;
        tx_busy_d        <= 1'b0;
        byte_index       <= 3'd0;
        sending          <= 1'b0;
        keys_latched     <= 2'd0;
        switches_latched <= 10'd0;
        adc0_norm_latched <= 8'd0;
        adc1_norm_latched <= 8'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_start         <= 1'b0;
            tx_data          <= 8'h00;
            tx_busy_d        <= 1'b0;
            byte_index       <= 3'd0;
            sending          <= 1'b0;
            keys_latched     <= 2'd0;
            switches_latched <= 10'd0;
            adc0_norm_latched <= 8'd0;
            adc1_norm_latched <= 8'd0;
        end else begin
            tx_start <= 1'b0;
            tx_busy_d <= tx_busy;

            if (start_byte) begin
                keys_latched     <= key_pressed;
                switches_latched <= sw_debounced;
                adc0_norm_latched <= normalize_adc(adc0_value);
                adc1_norm_latched <= normalize_adc(adc1_value);
                tx_data          <= 8'hA5;
                tx_start         <= 1'b1;
                byte_index       <= 3'd1;
                sending          <= 1'b1;
            end else if (sending && tx_done) begin
                if (byte_index == 3'd7) begin
                    sending <= 1'b0;
                end else begin
                    tx_start <= 1'b1;
                    case (byte_index)
                        3'd1: tx_data <= {6'd0, keys_latched};
                        3'd2: tx_data <= switches_latched[7:0];
                        3'd3: tx_data <= {6'd0, switches_latched[9:8]};
                        3'd4: tx_data <= adc0_norm_latched;
                        3'd5: tx_data <= adc1_norm_latched;
                        3'd6: tx_data <= 8'hA5 ^ {6'd0, keys_latched} ^
                                          switches_latched[7:0] ^
                                          {6'd0, switches_latched[9:8]} ^
                                          adc0_norm_latched ^
                                          adc1_norm_latched;
                        default: tx_data <= 8'h00;
                    endcase
                    byte_index <= byte_index + 3'd1;
                end
            end
        end
    end

    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD(BAUD)
    ) uart_to_esp32 (
        .clk(clk),
        .rst_n(rst_n),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx_busy(tx_busy),
        .tx_out(FPGA_UART_TX)
    );

    altera_up_avalon_adc_mega #(
        .numch(4'd1),
        .board("DE10-Lite"),
        .max10pllmultby(1),
        .max10plldivby(5)
    ) adc_reader (
        .CLOCK(clk),
        .RESET(1'b0),
        .ADC_CS_N(adc_cs_n_unused),
        .ADC_SCLK(adc_sclk_unused),
        .ADC_DIN(adc_din_unused),
        .ADC_DOUT(1'b0),
        .CH0(adc0_value),
        .CH1(adc1_value),
        .CH2(adc_unused_2),
        .CH3(adc_unused_3),
        .CH4(adc_unused_4),
        .CH5(adc_unused_5),
        .CH6(adc_unused_6),
        .CH7(adc_unused_7)
    );

    assign LEDR = sw_debounced;
endmodule
