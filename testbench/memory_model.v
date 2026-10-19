`timescale 1ns/1ps
// Simulation-only 4 KB little-endian memory. Reset preserves memory contents.
module memory_model (
    input wire clk, input wire rst,
    input wire req_valid, output wire req_ready,
    input wire req_write, input wire [31:0] req_addr, input wire [31:0] req_wdata,
    output reg resp_valid, input wire resp_ready, output reg [31:0] resp_rdata,
    input wire [3:0] response_delay, input wire stall_enable
);
    reg [7:0] mem [0:4095];
    reg pending, saved_write;
    reg [31:0] saved_addr, saved_data;
    reg [3:0] delay_left;
    reg [31:0] cycle;
    reg [31:0] init_word;
    integer i;
    // Periodic three-cycle request stalls, independent of the request itself.
    assign req_ready = !rst && !pending && !resp_valid &&
                       (!stall_enable || cycle % 7 >= 3);
    initial begin
        for (i=0; i<1024; i=i+1) begin
            init_word = 32'hCAFE0000 + i;
            mem[4*i]   = init_word[7:0];
            mem[4*i+1] = init_word[15:8];
            mem[4*i+2] = init_word[23:16];
            mem[4*i+3] = init_word[31:24];
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            pending <= 0;
            resp_valid <= 0;
            resp_rdata <= 0;
            cycle <= 0;
            saved_write <= 0;
            saved_addr <= 0;
            saved_data <= 0;
            delay_left <= 0;
        end else begin
            cycle <= cycle + 1;
            if (resp_valid && resp_ready) resp_valid <= 0;
            if (req_valid && req_ready) begin
                if ((^req_addr === 1'bx) || req_addr[1:0] != 0 || req_addr > 4092) begin
                    $display("FAIL: illegal memory address %h at %0t", req_addr, $time);
                    $finish;
                end
                saved_addr <= req_addr;
                saved_data <= req_wdata;
                saved_write <= req_write;
                delay_left <= response_delay;
                pending <= 1;
            end
            if (pending) begin
                if (delay_left != 0) delay_left <= delay_left - 1'b1;
                else begin
                    pending <= 0;
                    resp_valid <= 1;
                    if (saved_write) begin
                        mem[saved_addr]   <= saved_data[7:0];
                        mem[saved_addr+1] <= saved_data[15:8];
                        mem[saved_addr+2] <= saved_data[23:16];
                        mem[saved_addr+3] <= saved_data[31:24];
                        resp_rdata <= 0;
                    end else begin
                        resp_rdata <= {mem[saved_addr+3], mem[saved_addr+2],
                                       mem[saved_addr+1], mem[saved_addr]};
                    end
                end
            end
        end
    end
endmodule
