// ============================================================================
// FP8 E4M3 Adder — Optimized for sum-only throughput
// ============================================================================
// Tailored for this challenge workload: compute only A + B in FP8 E4M3.
// Latency is fixed at 2 cycles from start pulse to done pulse.
// ============================================================================

module fp8_adder (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] a,
    input  wire [7:0] b,
    output reg  [7:0] result,
    output reg        done,
    output reg        busy
);

    localparam S_IDLE   = 2'd0;
    localparam S_PREP   = 2'd1;
    localparam S_ENCODE = 2'd2;
    localparam S_DONE   = 2'd3;

    reg [1:0] state;
    reg [7:0] a_reg;
    reg [7:0] b_reg;
    reg [7:0] prep_result;
    reg       prep_special;
    integer   sum_scaled_reg;

    function integer floor_log2;
        input integer value;
        integer bit_idx;
        begin
            floor_log2 = 0;
            for (bit_idx = 0; bit_idx < 18; bit_idx = bit_idx + 1) begin
                if ((value >> bit_idx) != 0)
                    floor_log2 = bit_idx;
            end
        end
    endfunction

    function integer fp8_to_scaled;
        input [7:0] value;
        integer exp_field;
        integer man_field;
        begin
            exp_field = value[6:3];
            man_field = value[2:0];

            if (exp_field == 0)
                fp8_to_scaled = man_field;
            else
                fp8_to_scaled = (8 + man_field) << (exp_field - 1);

            if (value[7])
                fp8_to_scaled = -fp8_to_scaled;
        end
    endfunction

    function [7:0] fp8_from_sum;
        input integer sum_scaled;

        integer abs_scaled;
        integer sign_bit;
        integer exp_biased;
        integer shift;
        integer base;
        integer rem;
        integer half;
        integer man_int;
        begin
            abs_scaled = 0;
            sign_bit = 0;
            exp_biased = 0;
            shift = 0;
            base = 0;
            rem = 0;
            half = 0;
            man_int = 0;
            fp8_from_sum = 8'h00;

            if (sum_scaled == 0) begin
                fp8_from_sum = 8'h00;
            end else begin
                if (sum_scaled < 0) begin
                    sign_bit = 1;
                    abs_scaled = -sum_scaled;
                end else begin
                    abs_scaled = sum_scaled;
                end

                if (abs_scaled > 229376) begin
                    fp8_from_sum = ((sign_bit != 0) ? 8'h80 : 8'h00) | 8'h7E;
                end else if (abs_scaled < 8) begin
                    man_int = abs_scaled;
                    fp8_from_sum = ((sign_bit != 0) ? 8'h80 : 8'h00) | man_int[7:0];
                end else begin
                    exp_biased = floor_log2(abs_scaled) - 2;
                    shift = exp_biased - 1;
                    base = abs_scaled >> shift;

                    if (shift > 0) begin
                        rem = abs_scaled - (base << shift);
                        half = 1 << (shift - 1);

                        if (rem > half)
                            base = base + 1;
                        else if ((rem == half) && (base[0] == 1'b1))
                            base = base + 1;
                    end

                    if (base >= 16) begin
                        base = 8;
                        exp_biased = exp_biased + 1;
                    end

                    if (exp_biased > 15) begin
                        fp8_from_sum = ((sign_bit != 0) ? 8'h80 : 8'h00) | 8'h7E;
                    end else if ((exp_biased == 15) && (base == 15)) begin
                        fp8_from_sum = ((sign_bit != 0) ? 8'h80 : 8'h00) | 8'h7E;
                    end else begin
                        fp8_from_sum = ((sign_bit != 0) ? 8'h80 : 8'h00) |
                                       ((exp_biased & 15) << 3) |
                                       ((base - 8) & 7);
                    end
                end
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            a_reg         <= 8'd0;
            b_reg         <= 8'd0;
            prep_result   <= 8'd0;
            prep_special  <= 1'b0;
            sum_scaled_reg <= 0;
            result        <= 8'd0;
            done          <= 1'b0;
            busy          <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        a_reg <= a;
                        b_reg <= b;
                        busy <= 1'b1;
                        state <= S_PREP;
                    end
                end

                S_PREP: begin
                    if (((a_reg[6:3] == 4'hF) && (a_reg[2:0] == 3'h7)) ||
                        ((b_reg[6:3] == 4'hF) && (b_reg[2:0] == 3'h7))) begin
                        prep_special <= 1'b1;
                        prep_result <= 8'h7F;
                        sum_scaled_reg <= 0;
                    end else if ((a_reg[6:0] == 7'd0) && (b_reg[6:0] == 7'd0)) begin
                        prep_special <= 1'b1;
                        prep_result <= (a_reg[7] && b_reg[7]) ? 8'h80 : 8'h00;
                        sum_scaled_reg <= 0;
                    end else begin
                        prep_special <= 1'b0;
                        prep_result <= 8'h00;
                        sum_scaled_reg <= fp8_to_scaled(a_reg) + fp8_to_scaled(b_reg);
                    end
                    state <= S_ENCODE;
                end

                S_ENCODE: begin
                    result <= prep_special ? prep_result : fp8_from_sum(sum_scaled_reg);
                    state <= S_DONE;
                end

                S_DONE: begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
