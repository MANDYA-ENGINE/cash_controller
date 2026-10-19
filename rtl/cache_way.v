`timescale 1ns/1ps
// Eight lines in one way. Asynchronous reads, synchronous writes.
// Data and tags are intentionally not reset; valid bits protect their use.
module cache_way (
    input wire clk, input wire rst,
    input wire [2:0] set_index,
    output wire [127:0] line_data,
    output wire [24:0] tag_out,
    output wire valid_out, output wire dirty_out,
    input wire invalidate,
    input wire data_we, input wire [1:0] word_index,
    input wire [31:0] write_data,
    input wire meta_we, input wire [24:0] write_tag,
    input wire write_dirty
);
    reg [31:0] data [0:31];
    reg [24:0] tags [0:7];
    reg [7:0] valid_bits, dirty_bits;
    assign line_data = {data[{set_index,2'b11}], data[{set_index,2'b10}],
                        data[{set_index,2'b01}], data[{set_index,2'b00}]};
    assign tag_out = tags[set_index];
    assign valid_out = valid_bits[set_index];
    assign dirty_out = dirty_bits[set_index];
    always @(posedge clk) begin
        if (rst) begin
            valid_bits <= 0;
            dirty_bits <= 0;
        end else begin
            if (invalidate) begin
                valid_bits[set_index] <= 1'b0;
                dirty_bits[set_index] <= 1'b0;
            end
            if (data_we) data[{set_index,word_index}] <= write_data;
            if (meta_we) begin
                tags[set_index] <= write_tag;
                valid_bits[set_index] <= 1'b1;
                dirty_bits[set_index] <= write_dirty;
            end
        end
    end
endmodule
