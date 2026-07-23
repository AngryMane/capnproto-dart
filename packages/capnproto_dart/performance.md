
### Benchmark: capnproto_dart: serialization

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| encode (build + serialize) | 200000 | 903338 | 1.11 |
| encode (reused MessageBuilder + reset()) | 200000 | 1220055 | 0.82 |
| decode (deserialize + read all fields) | 200000 | 1331354 | 0.75 |


### Benchmark: capnproto_dart: serialization

| Benchmark | Iterations | ops/sec | µs/op |
|---|---:|---:|---:|
| encode (build + serialize) | 200000 | 741021 | 1.35 |
| encode (reused MessageBuilder + reset()) | 200000 | 969965 | 1.03 |
| decode (deserialize + read all fields) | 200000 | 1161467 | 0.86 |

