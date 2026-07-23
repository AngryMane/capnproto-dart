
### Benchmark: capnproto_dart: serialization [AOT]

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| encode (build + serialize) | 200000 | 1128904 | 0.89 |
| encode (reused MessageBuilder + reset()) | 200000 | 1296008 | 0.77 |
| decode (deserialize + read all fields) | 200000 | 1818661 | 0.55 |


### Benchmark: capnproto_dart_rpc: in-memory echo call [AOT]

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip | 5000 | 56035 | 17.85 |


### Benchmark: capnproto_dart_rpc: UDS echo call [AOT]

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip (0B payload) | 2000 | 13201 | 75.75 |
| echo round-trip (64B payload) | 2000 | 15229 | 65.66 |
| echo round-trip (1KiB payload) | 2000 | 10424 | 95.93 |
| echo round-trip (16KiB payload) | 2000 | 4129 | 242.19 |
| echo round-trip (64KiB payload) | 2000 | 1118 | 894.09 |


### Benchmark: capnproto-rust: serialization

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| encode (build + serialize) | 200000 | 2549070 | 0.39 |
| decode (deserialize + read all fields) | 200000 | 3896129 | 0.26 |


### Benchmark: capnp-rpc: in-memory echo call

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip | 5000 | 43105 | 23.20 |


### Benchmark: capnp-rpc: UDS echo call

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip (0B payload) | 2000 | 38422 | 26.03 |
| echo round-trip (64B payload) | 2000 | 37679 | 26.54 |
| echo round-trip (1KiB payload) | 2000 | 36599 | 27.32 |
| echo round-trip (16KiB payload) | 2000 | 24175 | 41.37 |
| echo round-trip (64KiB payload) | 2000 | 7419 | 134.80 |


### Benchmark: capnproto_dart: serialization [AOT]

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| encode (build + serialize) | 200000 | 1118743 | 0.89 |
| encode (reused MessageBuilder + reset()) | 200000 | 1102032 | 0.91 |
| decode (deserialize + read all fields) | 200000 | 1726549 | 0.58 |


### Benchmark: capnproto_dart_rpc: in-memory echo call [AOT]

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip | 5000 | 47647 | 20.99 |


### Benchmark: capnproto_dart_rpc: UDS echo call [AOT]

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip (0B payload) | 2000 | 10032 | 99.68 |
| echo round-trip (64B payload) | 2000 | 10230 | 97.75 |
| echo round-trip (1KiB payload) | 2000 | 9790 | 102.15 |
| echo round-trip (16KiB payload) | 2000 | 3276 | 305.23 |
| echo round-trip (64KiB payload) | 2000 | 1015 | 984.89 |


### Benchmark: capnproto-rust: serialization

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| encode (build + serialize) | 200000 | 1934666 | 0.52 |
| decode (deserialize + read all fields) | 200000 | 4168143 | 0.24 |


### Benchmark: capnp-rpc: in-memory echo call

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip | 5000 | 41851 | 23.89 |


### Benchmark: capnp-rpc: UDS echo call

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| echo round-trip (0B payload) | 2000 | 26918 | 37.15 |
| echo round-trip (64B payload) | 2000 | 27742 | 36.05 |
| echo round-trip (1KiB payload) | 2000 | 24323 | 41.11 |
| echo round-trip (16KiB payload) | 2000 | 15332 | 65.22 |
| echo round-trip (64KiB payload) | 2000 | 5930 | 168.62 |

