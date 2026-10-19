`timescale 1ns/1ps
// Each bit names the way to evict next when both ways are valid.
module cache_lru (
    input wire clk, input wire rst,
    input wire [2:0] set_index,
    input wire update, input wire accessed_way,
    output wire victim_way
);
    reg [7:0] lru_bits;
    assign victim_way = lru_bits[set_index];
    always @(posedge clk) begin
        if (rst) lru_bits <= 0;
        else if (update) lru_bits[set_index] <= ~accessed_way;
    end
endmodule
