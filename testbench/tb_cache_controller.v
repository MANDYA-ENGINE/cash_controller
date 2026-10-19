`timescale 1ns/1ps
module tb_cache_controller;
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

    // CPU-visible reference data is separate from delayed write-back memory.
    reg [31:0] golden [0:1023];
    // Abstract cache model, updated once per CPU operation, never from DUT internals.
    reg model_valid [0:15];
    reg model_dirty [0:15];
    reg [24:0] model_tag [0:15];
    integer model_lru [0:7];
    reg [31:0] expected_addr [0:7];
    reg [31:0] expected_data [0:7];
    reg expected_write [0:7];
    integer expected_count, observed_count;
    integer operations, read_transfers, write_transfers, req_stall_cycles, resp_stall_cycles;
    integer outstanding, accepted, responses;
    integer before_reads, before_writes;
    reg prev_mem_stall, prev_cpu_stall;
    reg [64:0] held_mem_request;
    reg [31:0] held_cpu_response;
    reg [31:0] random_state;
    integer i, j, k;
    reg [31:0] test_addr, test_data;
    reg test_write;
    integer hold_cycles;

    task fail;
        input [8*160-1:0] reason;
        begin
            $display("FAIL at %0t, operation %0d: %0s", $time, operations, reason);
            $finish;
        end
    endtask

    // Compare every accepted memory operation with the predicted transfer list.
    // Also check handshake stability and one-response-per-request accounting.
    always @(posedge clk) begin
        if (rst) begin
            prev_mem_stall = 0;
            prev_cpu_stall = 0;
            outstanding = 0;
        end else begin
            if (prev_mem_stall &&
                (mem_req_valid !== 1'b1 ||
                 {mem_req_write,mem_req_addr,mem_req_wdata} !== held_mem_request))
                fail("Memory request changed while waiting for ready");
            if (prev_cpu_stall &&
                (cpu_resp_valid !== 1'b1 || cpu_resp_rdata !== held_cpu_response))
                fail("CPU response changed while waiting for ready");
            prev_mem_stall = mem_req_valid && !mem_req_ready;
            prev_cpu_stall = cpu_resp_valid && !cpu_resp_ready;
            held_mem_request = {mem_req_write,mem_req_addr,mem_req_wdata};
            held_cpu_response = cpu_resp_rdata;
            if (prev_mem_stall) req_stall_cycles = req_stall_cycles + 1;
            if (prev_cpu_stall) resp_stall_cycles = resp_stall_cycles + 1;
            if (outstanding != 0 && cpu_req_ready !== 1'b0)
                fail("Cache offered request-ready while a request was outstanding");
            if (cpu_req_valid && cpu_req_ready) begin
                if (outstanding != 0) fail("Accepted overlapping CPU requests");
                outstanding = 1;
                accepted = accepted + 1;
            end
            if (cpu_resp_valid && outstanding != 1) fail("Unexpected CPU response");
            if (cpu_resp_valid && cpu_resp_ready) begin
                outstanding = 0;
                responses = responses + 1;
            end
            if (mem_req_valid && mem_req_ready) begin
                if (observed_count >= expected_count) fail("Unexpected extra memory transaction");
                if (mem_req_addr !== expected_addr[observed_count] ||
                    mem_req_write !== expected_write[observed_count]) begin
                    $display("Expected memory addr=%h write=%b; actual addr=%h write=%b",
                        expected_addr[observed_count], expected_write[observed_count],
                        mem_req_addr, mem_req_write);
                    fail("Wrong memory transaction address, ordering, or direction");
                end
                if (mem_req_write) begin
                    if (mem_req_wdata !== expected_data[observed_count]) fail("Wrong write-back word");
                    write_transfers = write_transfers + 1;
                end else read_transfers = read_transfers + 1;
                observed_count = observed_count + 1;
            end
        end
    end

    task access_cpu;
        input wr;
        input [31:0] addr;
        input [31:0] data;
        input integer stall_response;
        integer s, way, idx, n, base, old_base, w;
        reg found;
        reg [31:0] expected_read;
        begin
            if (addr[1:0] != 0 || addr > 4092) fail("Illegal test stimulus");
            s = (addr >> 4) & 7;
            found = 0;
            way = 0;
            for (w=0; w<2; w=w+1)
                if (model_valid[s*2+w] && model_tag[s*2+w] == (addr >> 7)) begin
                    found = 1;
                    way = w;
                end
            expected_count = 0;
            observed_count = 0;
            if (!found) begin
                if (!model_valid[s*2]) way = 0;
                else if (!model_valid[s*2+1]) way = 1;
                else way = model_lru[s];
                idx = s*2+way;
                if (model_valid[idx] && model_dirty[idx]) begin
                    old_base = (model_tag[idx] << 7) | (s << 4);
                    for (n=0; n<4; n=n+1) begin
                        expected_addr[expected_count] = old_base + n*4;
                        expected_data[expected_count] = golden[(old_base >> 2)+n];
                        expected_write[expected_count] = 1;
                        expected_count = expected_count + 1;
                    end
                end
                base = (addr >> 4) << 4;
                for (n=0; n<4; n=n+1) begin
                    expected_addr[expected_count] = base + n*4;
                    expected_data[expected_count] = 0;
                    expected_write[expected_count] = 0;
                    expected_count = expected_count + 1;
                end
                model_valid[idx] = 1;
                model_dirty[idx] = 0;
                model_tag[idx] = addr >> 7;
            end
            idx = s*2+way;
            model_lru[s] = 1-way;
            expected_read = golden[addr >> 2];
            if (wr) begin
                golden[addr >> 2] = data;
                model_dirty[idx] = 1;
            end
            @(negedge clk);
            cpu_req_valid = 1;
            cpu_req_addr = addr;
            cpu_req_write = wr;
            cpu_req_wdata = data;
            cpu_resp_ready = (stall_response < 0);
            @(posedge clk);
            while (!cpu_req_ready) @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 0;
            // Poison live inputs: subsequent processing must use the latched request.
            cpu_req_addr = 32'hxxxxxxxx;
            cpu_req_write = 1'bx;
            cpu_req_wdata = 32'hxxxxxxxx;
            while (!cpu_resp_valid) @(negedge clk);
            if (!wr && cpu_resp_rdata !== expected_read) begin
                $display("CPU addr=%h expected=%h actual=%h", addr, expected_read, cpu_resp_rdata);
                fail("CPU read mismatch");
            end
            if (stall_response > 0) repeat (stall_response) @(negedge clk);
            cpu_resp_ready = 1;
            @(posedge clk);
            @(negedge clk);
            cpu_resp_ready = 0;
            if (observed_count != expected_count) fail("Missing memory transfers at CPU completion");
            operations = operations + 1;
        end
    endtask

    task directed;
        input wr;
        input [31:0] addr, data;
        input integer want_reads, want_writes, stall_response;
        begin
            before_reads = read_transfers;
            before_writes = write_transfers;
            access_cpu(wr, addr, data, stall_response);
            if (read_transfers-before_reads != want_reads ||
                write_transfers-before_writes != want_writes)
                fail("Directed hit/miss/write-back transfer count mismatch");
        end
    endtask

    task reset_cache;
        integer r;
        begin
            @(negedge clk);
            rst = 1;
            cpu_req_valid = 0;
            cpu_resp_ready = 0;
            repeat (3) @(negedge clk);
            for (r=0; r<16; r=r+1) begin
                model_valid[r] = 0;
                model_dirty[r] = 0;
                model_tag[r] = 0;
            end
            for (r=0; r<8; r=r+1) model_lru[r] = 0;
            if (dut.u_way0.valid_bits !== 0 || dut.u_way1.valid_bits !== 0 ||
                dut.u_way0.dirty_bits !== 0 || dut.u_way1.dirty_bits !== 0)
                fail("Reset did not clear valid/dirty bits");
            rst = 0;
        end
    endtask

    // Fixed-seed xorshift makes mixed traffic repeatable across simulators.
    task next_random;
        begin
            random_state = random_state ^ (random_state << 13);
            random_state = random_state ^ (random_state >> 17);
            random_state = random_state ^ (random_state << 5);
        end
    endtask

    initial begin
        if ($test$plusargs("DUMP_VCD")) begin
            $dumpfile("cache_waveforms.vcd");
            $dumpvars(0, tb_cache_controller);
        end
        rst=1; cpu_req_valid=0; cpu_req_write=0; cpu_req_addr=0;
        cpu_req_wdata=0; cpu_resp_ready=0; response_delay=0; stall_enable=0;
        expected_count=0; observed_count=0; operations=0;
        read_transfers=0; write_transfers=0; req_stall_cycles=0; resp_stall_cycles=0;
        outstanding=0; accepted=0; responses=0; random_state=32'h13579BDF;
        for (i=0; i<1024; i=i+1) golden[i] = 32'hCAFE0000+i;
        reset_cache;

        $display("PHASE 1: cold refill, all word offsets, both ways, LRU, clean eviction");
        directed(0,32'h000,0,4,0,0);
        directed(0,32'h004,0,0,0,-1); // CPU ready before response arrives.
        directed(0,32'h008,0,0,0,0);
        directed(0,32'h00C,0,0,0,0);
        directed(0,32'h080,0,4,0,-1);
        directed(0,32'h000,0,0,0,0); // Touch way 0: way 1 becomes LRU.
        directed(0,32'h100,0,4,0,0); // Evict clean 0x080.
        directed(0,32'h000,0,0,0,0);
        directed(0,32'h080,0,4,0,0);

        $display("PHASE 2: four dirty words, dirty eviction, reload, write allocation");
        directed(1,32'h000,32'hDEAD0000,0,0,0);
        directed(1,32'h004,32'hDEAD0001,0,0,0);
        directed(1,32'h008,32'hDEAD0002,0,0,0);
        directed(1,32'h00C,32'hDEAD0003,0,0,0);
        directed(0,32'h008,0,0,0,0);
        directed(0,32'h080,0,0,0,0); // Make dirty 0x000 the victim.
        directed(0,32'h100,0,4,4,0);
        directed(0,32'h00C,0,4,0,0); // Reload written-back data.
        directed(1,32'h18C,32'h12345678,4,0,0);
        directed(0,32'h18C,0,0,0,0);
        directed(0,32'h180,0,0,0,0); // Other word preserved by write allocation.
        directed(0,32'h000,0,0,0,0);
        directed(1,32'h208,32'hABCDEF01,4,4,0); // Write miss with dirty victim.
        directed(0,32'h208,0,0,0,0);

        $display("PHASE 3: sets, memory boundary, delayed requests/responses, CPU stalls");
        stall_enable=1;
        response_delay=3;
        for (i=1; i<8; i=i+1) directed(0,i*16,0,4,0,2);
        directed(0,32'hFFC,0,4,0,5);
        directed(0,32'hFF0,0,0,0,3);
        directed(1,32'h074,32'h76543210,0,0,4);
        directed(0,32'h074,0,0,0,4);

        $display("PHASE 4: 600 repeatable mixed accesses, locality and conflicts");
        for (k=0; k<600; k=k+1) begin
            next_random;
            // Alternate a conflict-heavy 64-word working set with broad memory traffic.
            if (k % 2 == 0) test_addr = ((random_state % 16) << 7) | ((random_state >> 8 & 3) << 2);
            else test_addr = (random_state % 896) << 2; // Reserve 0xE00..0xFFF as clean scratch.
            next_random;
            test_write = random_state[0];
            test_data = random_state;
            hold_cycles = random_state[3:1] % 4;
            response_delay = random_state[7:4] % 6;
            access_cpu(test_write,test_addr,test_data,hold_cycles);
        end

        $display("PHASE 5: evict dirty lines through clean scratch, compare all 1024 words");
        for (i=0; i<8; i=i+1)
            for (j=0; j<3; j=j+1) access_cpu(0,32'hE00+j*128+i*16,0,0);
        for (i=0; i<1024; i=i+1)
            if ({memory.mem[4*i+3],memory.mem[4*i+2],memory.mem[4*i+1],memory.mem[4*i]} !== golden[i]) begin
                $display("Backing memory mismatch at byte address %h",i*4);
                fail("Final backing-memory comparison failed");
            end
        // Final reset is safe because all dirty data was already evicted.
        reset_cache;
        directed(0,32'h000,0,4,0,2);
        repeat (4) @(negedge clk);
        if (accepted != responses || accepted != operations || outstanding != 0)
            fail("Final CPU request/response accounting mismatch");
        if (req_stall_cycles == 0 || resp_stall_cycles == 0)
            fail("Stall scenarios were not exercised");
        $display("PASS: %0d CPU operations, %0d memory reads, %0d memory writes",
                 operations,read_transfers,write_transfers);
        $display("PASS: %0d memory-request stall cycles, %0d CPU-response stall cycles",
                 req_stall_cycles,resp_stall_cycles);
        $display("PASS: all 1024 backing-memory words match the CPU reference model");
        $finish;
    end
    initial begin
        #2000000;
        fail("Global timeout: probable deadlock");
    end
endmodule
