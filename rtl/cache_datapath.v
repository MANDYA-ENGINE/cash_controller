`timescale 1ns/1ps
module cache_datapath (
    input wire clk, input wire rst,
    input wire [31:0] cpu_req_addr, input wire cpu_req_write,
    input wire [31:0] cpu_req_wdata, output reg [31:0] cpu_resp_rdata,
    input wire capture_req, input wire lookup, input wire complete,
    input wire writeback, input wire refill_store,
    input wire [1:0] word_count,
    input wire [31:0] mem_resp_rdata,
    output wire [31:0] mem_req_addr, output wire [31:0] mem_req_wdata,
    input wire [127:0] line0, input wire [127:0] line1,
    input wire [24:0] tag0, input wire [24:0] tag1,
    input wire valid0, input wire valid1, input wire dirty0, input wire dirty1,
    input wire lru_victim,
    output wire hit, output wire victim_dirty,
    output wire [2:0] set_index,
    output wire [1:0] storage_word,
    output wire [31:0] storage_data,
    output wire [24:0] storage_tag,
    output wire storage_dirty,
    output wire [1:0] data_we, output wire [1:0] meta_we,
    output wire [1:0] invalidate,
    output wire lru_update, output wire accessed_way
);
    reg [31:0] req_addr, req_wdata;
    reg req_write;
    reg victim_way;
    reg [24:0] victim_tag;
    wire hit0, hit1, hit_way, chosen_victim, active_way;
    wire cpu_write, install;
    wire [127:0] hit_line, victim_line;
    assign set_index = req_addr[6:4];
    assign hit0 = valid0 && tag0 == req_addr[31:7];
    assign hit1 = valid1 && tag1 == req_addr[31:7];
    assign hit = hit0 || hit1;
    assign hit_way = !hit0 && hit1;
    assign chosen_victim = !valid0 ? 1'b0 : (!valid1 ? 1'b1 : lru_victim);
    assign victim_dirty = chosen_victim ? (valid1 && dirty1) : (valid0 && dirty0);
    assign hit_line = hit_way ? line1 : line0;
    assign victim_line = victim_way ? line1 : line0;
    assign active_way = complete || refill_store ? victim_way : hit_way;
    assign cpu_write = req_write && ((lookup && hit) || complete);
    assign install = complete || (lookup && hit && req_write);
    assign storage_word = refill_store ? word_count : req_addr[3:2];
    assign storage_data = refill_store ? mem_resp_rdata : req_wdata;
    assign storage_tag = req_addr[31:7];
    assign storage_dirty = req_write;
    assign data_we = (refill_store || cpu_write) ? (active_way ? 2'b10 : 2'b01) : 2'b00;
    assign meta_we = install ? (active_way ? 2'b10 : 2'b01) : 2'b00;
    assign invalidate = lookup && !hit ? (chosen_victim ? 2'b10 : 2'b01) : 2'b00;
    assign lru_update = (lookup && hit) || complete;
    assign accessed_way = complete ? victim_way : hit_way;
    assign mem_req_addr = writeback ? {victim_tag, req_addr[6:4], word_count, 2'b00}
                                    : {req_addr[31:4], word_count, 2'b00};
    assign mem_req_wdata = victim_line[word_count*32 +: 32];
    always @(posedge clk) begin
        if (rst) begin
            req_addr <= 0;
            req_wdata <= 0;
            req_write <= 0;
            victim_way <= 0;
            victim_tag <= 0;
            cpu_resp_rdata <= 0;
        end else begin
            if (capture_req) begin
                req_addr <= cpu_req_addr;
                req_wdata <= cpu_req_wdata;
                req_write <= cpu_req_write;
            end
            if (lookup && !hit) begin
                victim_way <= chosen_victim;
                victim_tag <= chosen_victim ? tag1 : tag0;
            end
            if (lookup && hit)
                cpu_resp_rdata <= req_write ? 32'b0 : hit_line[req_addr[3:2]*32 +: 32];
            if (complete)
                cpu_resp_rdata <= req_write ? 32'b0 : victim_line[req_addr[3:2]*32 +: 32];
        end
    end
endmodule
