// Rust-side counterpart to
// packages/capnproto_dart/benchmark/serialization_benchmark.dart — encodes
// and decodes the same `Metrics` struct shape, using the same iteration
// counts and the same "warm up, then time N iterations with a plain clock"
// methodology, so the two languages' numbers are directly comparable rather
// than comparing a simple timing loop against a statistically-adjusted one.
//
// Run with: cargo run --release --bin serialization_benchmark

use capnp::message;
use capnp::serialize;
use std::time::Instant;

pub mod metrics_capnp {
    include!(concat!(env!("OUT_DIR"), "/metrics_capnp.rs"));
}

use metrics_capnp::metrics;

const ITERATIONS: u32 = 200_000;
const WARMUP_ITERATIONS: u32 = 5_000;

fn encode_once(i: u32) -> Vec<u8> {
    let mut message = message::Builder::new_default();
    {
        let mut root = message.init_root::<metrics::Builder>();
        root.set_flag(i.is_multiple_of(2));
        root.set_count(i as i32);
        root.set_total((i as i64) * 1_000_000_000);
        root.set_ratio(i as f64 / 3.0);
        root.set_label(format!("benchmark-message-{i}").as_str());
    }
    serialize::write_message_to_words(&message)
}

fn decode_once(bytes: &[u8]) -> i64 {
    let reader =
        serialize::read_message(bytes, message::ReaderOptions::default()).expect("decode");
    let root = reader.get_root::<metrics::Reader>().expect("root");
    let mut acc: i64 = root.get_count() as i64;
    if root.get_flag() {
        acc += 1;
    }
    acc += root.get_total() % 97;
    acc += root.get_ratio().round() as i64;
    if let Ok(label) = root.get_label() {
        if let Ok(s) = label.to_str() {
            acc += s.len() as i64;
        }
    }
    acc
}

fn main() {
    for i in 0..WARMUP_ITERATIONS {
        decode_once(&encode_once(i));
    }

    let encode_start = Instant::now();
    for i in 0..ITERATIONS {
        std::hint::black_box(encode_once(i));
    }
    let encode_elapsed = encode_start.elapsed();

    let sample = encode_once(0);
    let mut checksum: i64 = 0;
    let decode_start = Instant::now();
    for _ in 0..ITERATIONS {
        checksum += decode_once(&sample);
    }
    let decode_elapsed = decode_start.elapsed();
    eprintln!("# checksum (ignore): {checksum}");

    report_benchmarks(
        "capnproto-rust: serialization",
        &[
            BenchmarkResult::new(
                "encode (build + serialize)",
                ITERATIONS,
                encode_elapsed.as_micros(),
            ),
            BenchmarkResult::new(
                "decode (deserialize + read all fields)",
                ITERATIONS,
                decode_elapsed.as_micros(),
            ),
        ],
    );
}

struct BenchmarkResult {
    name: &'static str,
    iterations: u32,
    elapsed_micros: u128,
}

impl BenchmarkResult {
    fn new(name: &'static str, iterations: u32, elapsed_micros: u128) -> Self {
        Self {
            name,
            iterations,
            elapsed_micros,
        }
    }

    fn ops_per_second(&self) -> f64 {
        self.iterations as f64 / (self.elapsed_micros as f64 / 1_000_000.0)
    }

    fn micros_per_op(&self) -> f64 {
        self.elapsed_micros as f64 / self.iterations as f64
    }
}

/// Prints [results] as a JSON line and a Markdown table — matching the
/// shape the Dart benchmarks print — and appends the table to
/// `$GITHUB_STEP_SUMMARY` when running in a GitHub Actions job, so both
/// languages' tables show up side by side on the workflow run's summary
/// page.
fn report_benchmarks(suite_name: &str, results: &[BenchmarkResult]) {
    let mut json = String::from("{\"suite\":\"");
    json.push_str(suite_name);
    json.push_str("\",\"results\":[");
    for (i, r) in results.iter().enumerate() {
        if i > 0 {
            json.push(',');
        }
        json.push_str(&format!(
            "{{\"name\":\"{}\",\"iterations\":{},\"elapsedMicroseconds\":{},\"opsPerSecond\":{},\"microsecondsPerOp\":{}}}",
            r.name,
            r.iterations,
            r.elapsed_micros,
            r.ops_per_second(),
            r.micros_per_op(),
        ));
    }
    json.push_str("]}");
    println!("{json}");

    let mut table = format!("### Benchmark: {suite_name}\n\n");
    table.push_str("| Benchmark | Iterations | ops/sec | µs/op |\n");
    table.push_str("|---|---:|---:|---:|\n");
    for r in results {
        table.push_str(&format!(
            "| {} | {} | {:.0} | {:.2} |\n",
            r.name,
            r.iterations,
            r.ops_per_second(),
            r.micros_per_op(),
        ));
    }
    print!("{table}");

    if let Ok(summary_path) = std::env::var("GITHUB_STEP_SUMMARY") {
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(summary_path)
        {
            let _ = writeln!(file, "\n{table}");
        }
    }
}
