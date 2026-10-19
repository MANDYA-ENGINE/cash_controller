`timescale 1ns/1ps
module cache_top (
    input wire clk, input wire rst,
    input wire cpu_req_valid, output wire cpu_req_ready,
    input wire [31:0] cpu_req_addr, input wire cpu_req_write,
    input wire [31:0] cpu_req_wdata,
    output wire cpu_resp_valid, input wire cpu_resp_ready,
    output wire [31:0] cpu_resp_rdata,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire mem_req_write, output wire [31:0] mem_req_addr,
    output wire [31:0] mem_req_wdata,
    input wire mem_resp_valid, output wire mem_resp_ready,
    input wire [31:0] mem_resp_rdata
);
    wire capture_req, lookup, complete, writeback, refill_store;
    wire hit, victim_dirty, lru_victim, lru_update, accessed_way;
    wire [1:0] word_count, storage_word, data_we, meta_we, invalidate;
    wire [3:0] state;
    wire [2:0] set_index;
    wire [31:0] storage_data;
    wire [24:0] storage_tag, tag0, tag1;
    wire storage_dirty, valid0, valid1, dirty0, dirty1;
    wire [127:0] line0, line1;
    assign mem_req_write = writeback;

    cache_controller u_controller (
        .clk(clk), .rst(rst), .cpu_req_valid(cpu_req_valid), .cpu_req_ready(cpu_req_ready),
        .cpu_resp_valid(cpu_resp_valid), .cpu_resp_ready(cpu_resp_ready),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_resp_valid(mem_resp_valid), .mem_resp_ready(mem_resp_ready),
        .hit(hit), .victim_dirty(victim_dirty), .capture_req(capture_req),
        .lookup(lookup), .complete(complete), .writeback(writeback),
        .refill_store(refill_store), .word_count(word_count), .state(state)
    );
    cache_datapath u_datapath (
        .clk(clk), .rst(rst), .cpu_req_addr(cpu_req_addr), .cpu_req_write(cpu_req_write),
        .cpu_req_wdata(cpu_req_wdata), .cpu_resp_rdata(cpu_resp_rdata),
        .capture_req(capture_req), .lookup(lookup), .complete(complete),
        .writeback(writeback), .refill_store(refill_store), .word_count(word_count),
        .mem_resp_rdata(mem_resp_rdata), .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .line0(line0), .line1(line1), .tag0(tag0), .tag1(tag1),
        .valid0(valid0), .valid1(valid1), .dirty0(dirty0), .dirty1(dirty1),
        .lru_victim(lru_victim), .hit(hit), .victim_dirty(victim_dirty),
        .set_index(set_index), .storage_word(storage_word), .storage_data(storage_data),
        .storage_tag(storage_tag), .storage_dirty(storage_dirty), .data_we(data_we),
        .meta_we(meta_we), .invalidate(invalidate), .lru_update(lru_update), .accessed_way(accessed_way)
    );
    cache_way u_way0 (
        .clk(clk), .rst(rst), .set_index(set_index), .line_data(line0),
        .tag_out(tag0), .valid_out(valid0), .dirty_out(dirty0),
        .invalidate(invalidate[0]), .data_we(data_we[0]), .word_index(storage_word),
        .write_data(storage_data), .meta_we(meta_we[0]), .write_tag(storage_tag), .write_dirty(storage_dirty)
    );
    cache_way u_way1 (
        .clk(clk), .rst(rst), .set_index(set_index), .line_data(line1),
        .tag_out(tag1), .valid_out(valid1), .dirty_out(dirty1),
        .invalidate(invalidate[1]), .data_we(data_we[1]), .word_index(storage_word),
        .write_data(storage_data), .meta_we(meta_we[1]), .write_tag(storage_tag), .write_dirty(storage_dirty)
    );
    cache_lru u_lru (
        .clk(clk), .rst(rst), .set_index(set_index), .update(lru_update),
        .accessed_way(accessed_way), .victim_way(lru_victim)
    );
endmodule
