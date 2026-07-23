// Rust-side counterpart to
// packages/capnproto_dart_rpc/benchmark/rpc_benchmark.dart — an in-memory
// (no real socket) two-party RPC connection exchanging the same trivial
// text-echo call, using the same iteration counts and "warm up, then time N
// iterations" methodology, so the two languages' numbers are directly
// comparable.
//
// Run with: cargo run --release --bin rpc_benchmark

use capnp_rpc::{rpc_twoparty_capnp, twoparty, RpcSystem};
use futures::AsyncReadExt;
use std::rc::Rc;
use std::time::Instant;
use tokio::task;
use tokio_util::compat::TokioAsyncReadCompatExt;

pub mod echo_capnp {
    include!(concat!(env!("OUT_DIR"), "/echo_capnp.rs"));
}

use echo_capnp::echo;

const ITERATIONS: u32 = 5_000;
const WARMUP_ITERATIONS: u32 = 200;

struct EchoImpl;

impl echo::Server for EchoImpl {
    async fn echo(
        self: Rc<Self>,
        params: echo::EchoParams,
        mut results: echo::EchoResults,
    ) -> Result<(), capnp::Error> {
        let message = params.get()?.get_message()?.to_str()?;
        results.get().set_message(format!("echo: {message}").as_str());
        Ok(())
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let local = task::LocalSet::new();
    local
        .run_until(async {
            // An in-memory duplex pipe, not a real socket — measures RPC
            // protocol/dispatch overhead in isolation from transport latency,
            // matching the Dart benchmark's StreamController-based pipe.
            let (client_stream, server_stream) = tokio::io::duplex(64 * 1024);

            let (client_reader, client_writer) = client_stream.compat().split();
            let client_network = twoparty::VatNetwork::new(
                futures::io::BufReader::new(client_reader),
                futures::io::BufWriter::new(client_writer),
                rpc_twoparty_capnp::Side::Client,
                Default::default(),
            );
            let mut client_rpc_system = RpcSystem::new(Box::new(client_network), None);
            let echo_client: echo::Client =
                client_rpc_system.bootstrap(rpc_twoparty_capnp::Side::Server);
            task::spawn_local(client_rpc_system);

            let (server_reader, server_writer) = server_stream.compat().split();
            let server_network = twoparty::VatNetwork::new(
                futures::io::BufReader::new(server_reader),
                futures::io::BufWriter::new(server_writer),
                rpc_twoparty_capnp::Side::Server,
                Default::default(),
            );
            let echo_server: echo::Client = capnp_rpc::new_client(EchoImpl);
            let server_rpc_system =
                RpcSystem::new(Box::new(server_network), Some(echo_server.client));
            task::spawn_local(server_rpc_system);

            for i in 0..WARMUP_ITERATIONS {
                let mut request = echo_client.echo_request();
                request.get().set_message(format!("warmup-{i}").as_str());
                request.send().promise.await?;
            }

            let start = Instant::now();
            for i in 0..ITERATIONS {
                let mut request = echo_client.echo_request();
                request.get().set_message(format!("message-{i}").as_str());
                request.send().promise.await?;
            }
            let elapsed = start.elapsed();

            report_benchmarks(
                "capnp-rpc: in-memory echo call",
                &[BenchmarkResult::new(
                    "echo round-trip",
                    ITERATIONS,
                    elapsed.as_micros(),
                )],
            );

            Ok::<(), Box<dyn std::error::Error>>(())
        })
        .await
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
