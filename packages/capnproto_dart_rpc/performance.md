
### Benchmark: capnproto_dart_rpc: in-memory echo call

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip | 5000 | 8110 | 123.31 |


### Benchmark: capnproto_dart_rpc: UDS echo call

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip (0B payload) | 2000 | 3197 | 312.75 |
| echo round-trip (64B payload) | 2000 | 7936 | 126.00 |
| echo round-trip (1KiB payload) | 2000 | 8990 | 111.23 |
| echo round-trip (16KiB payload) | 2000 | 2044 | 489.13 |
| echo round-trip (64KiB payload) | 2000 | 617 | 1620.23 |


### Benchmark: capnproto_dart_rpc: in-memory echo call

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip | 5000 | 6690 | 149.49 |


### Benchmark: capnproto_dart_rpc: UDS echo call

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip (0B payload) | 2000 | 2536 | 394.38 |
| echo round-trip (64B payload) | 2000 | 4317 | 231.63 |
| echo round-trip (1KiB payload) | 2000 | 5435 | 183.98 |
| echo round-trip (16KiB payload) | 2000 | 1577 | 634.19 |
| echo round-trip (64KiB payload) | 2000 | 514 | 1944.18 |

