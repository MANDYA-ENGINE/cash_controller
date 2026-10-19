`timescale 1ns/1ps
// Standalone directed test; select this module as the simulation top.
module tb_dirty_eviction;
    reg clk = 0;
    always #5 clk = ~clk; // 100 MHz
    reg rst;
    reg cpu_req_valid, cpu_req_write, cpu_resp_ready;
    reg [31:0] cpu_req_addr, cpu_req_wdata;
    wire cpu_req_ready, cpu_resp_valid;
    wire [31:0] cpu_resp_rdata;
    wire mem_req_valid, mem_req_ready, mem_req_write, mem_resp_valid, mem_resp_ready;
    wire [31:0] mem_req_addr, mem_req_wdata, mem_resp_rdata;
    reg [3:0] response_delay;
    reg stall_enable;

    cache_top dut (
        .clk(clk), .rst(rst), .cpu_req_valid(cpu_req_valid), .cpu_req_ready(cpu_req_ready),
        .cpu_req_addr(cpu_req_addr), .cpu_req_write(cpu_req_write), .cpu_req_wdata(cpu_req_wdata),
        .cpu_resp_valid(cpu_resp_valid), .cpu_resp_ready(cpu_resp_ready), .cpu_resp_rdata(cpu_resp_rdata),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .mem_resp_valid(mem_resp_valid), .mem_resp_ready(mem_resp_ready), .mem_resp_rdata(mem_resp_rdata)
    );
    memory_model memory (
        .clk(clk), .rst(rst), .req_valid(mem_req_valid), .req_ready(mem_req_ready),
        .req_write(mem_req_write), .req_addr(mem_req_addr), .req_wdata(mem_req_wdata),
        .resp_valid(mem_resp_valid), .resp_ready(mem_resp_ready), .resp_rdata(mem_resp_rdata),
        .response_delay(response_delay), .stall_enable(stall_enable)
    );


    // Phase 0 is reset, 1 is setup, 2 is the main waveform, 3 is final checks.
    reg [2:0] phase;
    integer operations, expected_count, seen, outstanding;
    integer reads, writes;
    reg [31:0] expected_addr [0:7];
    reg [31:0] expected_data [0:7];
    reg expected_write [0:7];
    integer i;

    task fail;
        input [8*120-1:0] message;
        begin
            $display("FAIL %m at %0t: %0s", $time, message);
            $finish;
        end
    endtask

    // The list is explicit: these small tests do not need a cache reference model.
    task expect_refill;
        input [31:0] base;
        integer n;
        begin
            for (n=0; n<4; n=n+1) begin
                expected_addr[expected_count] = base + 4*n;
                expected_write[expected_count] = 0;
                expected_data[expected_count] = 0;
                expected_count = expected_count + 1;
            end
        end
    endtask

    task expect_writeback;
        input [31:0] base, word0, word1, word2, word3;
        integer n;
        begin
            for (n=0; n<4; n=n+1) begin
                expected_addr[expected_count+n] = base + 4*n;
                expected_write[expected_count+n] = 1;
            end
            expected_data[expected_count]   = word0;
            expected_data[expected_count+1] = word1;
            expected_data[expected_count+2] = word2;
            expected_data[expected_count+3] = word3;
            expected_count = expected_count + 4;
        end
    endtask

    always @(posedge clk) begin
        if (!rst) begin
            if (cpu_req_valid && cpu_req_ready) begin
                if (outstanding != 0) fail("Overlapping CPU requests");
                outstanding = 1;
            end
            if (cpu_resp_valid && outstanding != 1) fail("Unexpected CPU response");
            if (cpu_resp_valid && cpu_resp_ready) outstanding = 0;
            if (mem_req_valid && mem_req_ready) begin
                if (seen >= expected_count) fail("Unexpected memory transfer");
                if (mem_req_addr !== expected_addr[seen] || mem_req_write !== expected_write[seen])
                    fail("Wrong memory address, direction, or transfer order");
                if (mem_req_write) begin
                    if (mem_req_wdata !== expected_data[seen]) fail("Wrong write-back data");
                    writes = writes + 1;
                end else reads = reads + 1;
                seen = seen + 1;
            end
        end
    end

    task access_cpu;
        input wr;
        input [31:0] addr, data, expected_read;
        begin
            @(negedge clk);
            cpu_req_valid = 1;
            cpu_req_write = wr;
            cpu_req_addr = addr;
            cpu_req_wdata = data;
            @(posedge clk);
            while (!cpu_req_ready) @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 0;
            // Keep the payload visible for a clean waveform; valid is now low.
            while (!cpu_resp_valid) @(negedge clk);
            if (!wr && cpu_resp_rdata !== expected_read) begin
                $display("Address %h: expected %h, received %h", addr, expected_read, cpu_resp_rdata);
                fail("Read data mismatch");
            end
            @(posedge clk); // cpu_resp_ready stays high, so this accepts the response.
            @(negedge clk);
            if (seen != expected_count) fail("CPU completed before all expected memory requests");
            expected_count = 0;
            seen = 0;
            operations = operations + 1;
            repeat (2) @(negedge clk);
        end
    endtask

    function [31:0] backing_word;
        input integer addr;
        begin
            backing_word = {memory.mem[addr+3],memory.mem[addr+2],memory.mem[addr+1],memory.mem[addr]};
        end
    endfunction

    initial begin
        #20000;
        fail("Timeout");
    end

    initial begin
        if ($test$plusargs("DUMP_VCD")) begin
            $dumpfile("tb_dirty_eviction.vcd");
            $dumpvars(0, tb_dirty_eviction);
        end
        rst=1; phase=0;
        cpu_req_valid=0; cpu_req_write=0; cpu_req_addr=0; cpu_req_wdata=0;
        cpu_resp_ready=1; response_delay=1; stall_enable=0;
        operations=0; expected_count=0; seen=0; outstanding=0; reads=0; writes=0;
        repeat (3) @(negedge clk);
        if (dut.u_way0.valid_bits !== 0 || dut.u_way1.valid_bits !== 0 ||
            dut.u_way0.dirty_bits !== 0 || dut.u_way1.dirty_bits !== 0)
            fail("Reset metadata mismatch");
        rst=0;
        phase=1;
        expect_refill(32'h000);
        access_cpu(0,32'h000,0,32'hCAFE0000);
        for (i=0; i<4; i=i+1) access_cpu(1,i*4,32'hDEAD0000+i,0);
        if (dut.dirty0 !== 1) fail("Victim was not marked dirty");
        for (i=0; i<4; i=i+1)
            if (backing_word(i*4) !== 32'hCAFE0000+i)
                fail("Backing memory changed before eviction");
        expect_refill(32'h080);
        access_cpu(0,32'h080,0,32'hCAFE0020); // Makes dirty way 0 LRU.
        phase=2;
        expect_writeback(0,32'hDEAD0000,32'hDEAD0001,32'hDEAD0002,32'hDEAD0003);
        expect_refill(32'h100);
        access_cpu(0,32'h100,0,32'hCAFE0040);
        for (i=0; i<4; i=i+1)
            if (backing_word(i*4) !== 32'hDEAD0000+i)
                fail("Dirty line did not reach backing memory");
        phase=3;
        expect_refill(32'h000);
        access_cpu(0,32'h00C,0,32'hDEAD0003);
        access_cpu(0,32'h000,0,32'hDEAD0000);
        access_cpu(0,32'h004,0,32'hDEAD0001);
        access_cpu(0,32'h008,0,32'hDEAD0002);
        repeat (3) @(negedge clk);
        if (outstanding != 0) fail("Unfinished CPU request");
        $display("PASS tb_dirty_eviction: %0d CPU operations, %0d memory reads, %0d memory writes",
                 operations, reads, writes);
        $finish;
    end
endmodule
