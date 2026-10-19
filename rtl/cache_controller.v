`timescale 1ns/1ps
// Blocking controller: one CPU operation and one memory word outstanding.
module cache_controller (
    input wire clk, input wire rst,
    input wire cpu_req_valid, output wire cpu_req_ready,
    output wire cpu_resp_valid, input wire cpu_resp_ready,
    output wire mem_req_valid, input wire mem_req_ready,
    input wire mem_resp_valid, output wire mem_resp_ready,
    input wire hit, input wire victim_dirty,
    output wire capture_req, output wire lookup,
    output wire complete, output wire writeback,
    output wire refill_store, output reg [1:0] word_count,
    output reg [3:0] state
);
    localparam IDLE=4'd0, LOOKUP=4'd1, WB_REQ=4'd2, WB_WAIT=4'd3,
               REFILL_REQ=4'd4, REFILL_WAIT=4'd5, COMPLETE=4'd6,
               RESPOND=4'd7;
    assign cpu_req_ready = !rst && state == IDLE;
    assign cpu_resp_valid = !rst && state == RESPOND;
    assign mem_req_valid = !rst && (state == WB_REQ || state == REFILL_REQ);
    assign mem_resp_ready = !rst && (state == WB_WAIT || state == REFILL_WAIT);
    assign capture_req = cpu_req_valid && cpu_req_ready;
    assign lookup = !rst && state == LOOKUP;
    assign complete = !rst && state == COMPLETE;
    assign writeback = state == WB_REQ || state == WB_WAIT;
    assign refill_store = !rst && state == REFILL_WAIT && mem_resp_valid;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            word_count <= 0;
        end else begin
            case (state)
                IDLE: if (capture_req) state <= LOOKUP;
                LOOKUP: begin
                    word_count <= 0;
                    if (hit) state <= RESPOND;
                    else if (victim_dirty) state <= WB_REQ;
                    else state <= REFILL_REQ;
                end
                WB_REQ: if (mem_req_ready) state <= WB_WAIT;
                WB_WAIT: if (mem_resp_valid) begin
                    if (word_count == 3) begin
                        word_count <= 0;
                        state <= REFILL_REQ;
                    end else begin
                        word_count <= word_count + 1'b1;
                        state <= WB_REQ;
                    end
                end
                REFILL_REQ: if (mem_req_ready) state <= REFILL_WAIT;
                REFILL_WAIT: if (mem_resp_valid) begin
                    if (word_count == 3) state <= COMPLETE;
                    else begin
                        word_count <= word_count + 1'b1;
                        state <= REFILL_REQ;
                    end
                end
                COMPLETE: state <= RESPOND;
                RESPOND: if (cpu_resp_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
