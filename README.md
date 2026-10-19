# Two-Way Cache Controller

A 2-way set-associative cache written in Verilog. The design uses write-back,
write-allocate, and LRU replacement. It handles one CPU request at a time and
transfers data to main memory one word at a time.

## Cache configuration

| Parameter | Value |
| --- | --- |
| Address width | 32 bits, byte-addressed |
| Data width | 32 bits |
| Cache capacity | 256 bytes |
| Sets | 8 |
| Ways per set | 2 |
| Line size | 16 bytes / 4 words |
| Main memory used for testing | 1,024 words / 4 KB |

Only aligned 32-bit reads and writes are supported. Consecutive words are at
byte addresses `0x000`, `0x004`, `0x008`, and so on.

```text
Address:  [31:7] Tag | [6:4] Set | [3:2] Word | [1:0] Byte
```

The byte bits must be `00` for each request.

## Files

```text
rtl/
  cache_top.v
  cache_controller.v
  cache_datapath.v
  cache_way.v
  cache_lru.v

testbench/
  memory_model.v
  tb_cache_controller.v
```

## Design

### Top module — cache_top.v

Connects the controller, datapath, two cache ways, and LRU storage. It exposes
separate request and response interfaces for the CPU and main memory.

A transfer happens on a rising clock edge when both `valid` and `ready` are
high. If the receiver is not ready, the sender holds its valid signal and data
until the transfer is accepted. Both reads and writes receive a completion
response.

### Controller — cache_controller.v

The controller uses an eight-state FSM to handle hits, write-backs, and refills.

| Value | State | Purpose |
| --- | --- | --- |
| 0 | IDLE | Wait for and accept a CPU request |
| 1 | LOOKUP | Check both ways for a hit; select a victim on a miss |
| 2 | WB_REQ | Send one word of the dirty victim to memory |
| 3 | WB_WAIT | Wait for the write acknowledgment |
| 4 | REFILL_REQ | Request one word of the new line |
| 5 | REFILL_WAIT | Wait for and store the returned word |
| 6 | COMPLETE | Mark the new line valid and finish the original access |
| 7 | RESPOND | Hold the CPU response until it is accepted |

A two-bit word counter steps through the four words during write-back and
refill. It advances only when a memory response is accepted. The cache accepts
its next CPU request after returning to `IDLE`.

### Datapath — cache_datapath.v

Stores the accepted CPU address, write data, and read/write control. It compares
the requested tag against both ways, selects the required word, and generates
memory addresses. On a miss, it saves the victim way and its old tag before
replacement.

Write-back uses the victim's old tag. Refill uses the new request's tag. This
ensures dirty data goes back to its original memory address.

The datapath follows control signals from the controller; it has no separate FSM.

### Cache storage — cache_way.v

This module is instantiated twice, once for each way. Each instance stores eight
lines, with four data words, a tag, a valid bit, and a dirty bit per line.

Reads are asynchronous and writes happen on the rising clock edge. A matching
tag is a hit only when its valid bit is set. A CPU write marks the line dirty.
During replacement, the selected line stays invalid until refill is complete.

### Replacement — cache_lru.v

Each set has one LRU bit naming the way to replace next. Accessing way 0 makes
way 1 the replacement choice, and accessing way 1 makes way 0 the choice.

An invalid way is always used before evicting a valid line. If both ways are
invalid, way 0 is chosen. This module is a bank of bits, not a separate FSM.

### Reset

Reset is active-high and synchronous. It returns the controller to `IDLE` and
clears valid bits, dirty bits, and LRU bits. Data and tags do not need to be
cleared because invalid lines cannot produce hits.

Reset discards dirty cache data; it does not write it back to memory.

## How accesses are handled

### Read or write hit

```text
IDLE -> LOOKUP -> RESPOND -> IDLE
```

A read returns the selected word. A write updates that word and sets the dirty
bit. Both update LRU. No main-memory transaction is needed.

### Miss with an invalid or clean victim

```text
IDLE -> LOOKUP -> (REFILL_REQ -> REFILL_WAIT) x 4
     -> COMPLETE -> RESPOND -> IDLE
```

The cache fetches all four words of the requested line. It then returns the
requested word for a read, or applies the CPU write and marks the line dirty.
Fetching the line before applying a write miss is the write-allocate policy.

### Miss with a dirty victim

```text
IDLE -> LOOKUP -> (WB_REQ -> WB_WAIT) x 4
     -> (REFILL_REQ -> REFILL_WAIT) x 4
     -> COMPLETE -> RESPOND -> IDLE
```

All four victim words are written back and acknowledged before refill starts.
The original CPU request stays saved throughout the operation.

## Testbench

### Main memory — memory_model.v

The memory model stores 4,096 bytes in little-endian order. Word `i` starts with
`32'hCAFE0000 + i`.

| Byte address | Initial word |
| --- | --- |
| `0x000` | `CAFE0000` |
| `0x004` | `CAFE0001` |
| `0x008` | `CAFE0002` |
| `0x00C` | `CAFE0003` |
| `0xFFC` | `CAFE03FF` |

The model accepts one request, waits for a configurable delay, performs the
read or write, and holds its response until accepted. It uses a pending flag
and delay counter rather than a named FSM. Request stalls can also be enabled.
Memory contents are initialized once and preserved across reset.

### Functional checks — tb_cache_controller.v

The testbench compares CPU reads against reference data and checks the address,
direction, and order of memory transactions. Write-back data is also checked.

The test sequence covers:

- Cold misses and reads from all four word positions.
- Read/write hits, write allocation, and preservation of neighboring words.
- Two lines in the same set, LRU replacement, and clean eviction.
- Dirty eviction and reloading previously modified data.
- All eight sets and the last word of main memory.
- Memory delays and CPU response stalls.
- 600 repeatable mixed reads and writes.

At the end, accesses to clean scratch lines force remaining dirty lines out.
All 1,024 backing-memory words are then compared against the reference data.

CPU request inputs are deliberately driven to `X` after acceptance. This checks
that the cache uses its saved request while busy. Those external inputs are not
valid at that point; the internal request registers should remain stable.

### Vivado simulation

Add `rtl/` files as design sources and `testbench/` files as simulation sources.
Set `cache_top` as the design top and `tb_cache_controller` as the simulation top.
Start behavioral simulation and enter `run all` in the Tcl console.

The full simulation passed in Vivado at **265,590 ns**, with these results:

```text
PASS: 659 CPU operations, 2296 memory reads, 1184 memory writes
PASS: 4036 memory-request stall cycles, 929 CPU-response stall cycles
PASS: all 1024 backing-memory words match the CPU reference model
```

The current tests cover functional behavior. Reset during an active transaction,
continuously queued CPU requests, and FPGA timing have not been tested.
