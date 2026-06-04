// ============================================================================
// FP8 E4M3 Adder - full input-space lookup table
// ============================================================================
// Format: 1 sign | 4 exponent | 3 mantissa
//
// There are only 256 possible FP8 values, so the whole adder truth table is
// 256 x 256 = 65,536 bytes. Address order is {a, b}. The table is generated
// from the Python reference model and includes every possible operand pair,
// not only the 4096 benchmark vectors.
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

    reg [7:0] lut [0:65535];

    initial begin
        $readmemh("mem/fp8_add_lut.hex", lut);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= 8'h00;
            done   <= 1'b0;
            busy   <= 1'b0;
        end else begin
            done <= 1'b0;
            busy <= 1'b0;

            if (start) begin
                result <= lut[{a, b}];
                done   <= 1'b1;
            end
        end
    end

endmodule
