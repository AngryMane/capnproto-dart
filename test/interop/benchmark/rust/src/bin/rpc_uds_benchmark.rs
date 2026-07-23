// Rust-side counterpart to
// packages/capnproto_dart_rpc/benchmark/rpc_uds_benchmark.dart — an RPC
// round-trip over a real Unix domain socket (not an in-memory pipe), across
// several payload sizes, matching the Dart benchmark's methodology.
//
// Run with: cargo run --release --bin rpc_uds_benchmark

use capnp_rpc::{rpc_twoparty_capnp, twoparty, RpcSystem};
use futures::AsyncReadExt;
use std::rc::Rc;
use std::time::Instant;
use tokio::net::{UnixListener, UnixStream};
use tokio::task;
use tokio_util::compat::TokioAsyncReadCompatExt;

pub mod echo_capnp {
    include!(concat!(env!("OUT_DIR"), "/echo_capnp.rs"));
}

use echo_capnp::echo;

const ITERATIONS_PER_SIZE: u32 = 2_000;
const WARMUP_ITERATIONS: u32 = 100;
const PAYLOAD_SIZES: [usize; 5] = [0, 64, 1024, 16384, 65536];

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

fn size_label(bytes: usize) -> String {
    if bytes == 0 {
        "0B".to_string()
    } else if bytes < 1024 {
        format!("{bytes}B")
    } else {
        format!("{}KiB", bytes / 1024)
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let local = task::LocalSet::new();
    local
        .run_until(async {
            let socket_path = std::env::temp_dir()
                .join(format!("capnp_rpc_uds_bench_{}.sock", std::process::id()));
            let _ = std::fs::remove_file(&socket_path);

            let listener = UnixListener::bind(&socket_path)?;
            let client_stream = UnixStream::connect(&socket_path).await?;
            let (server_stream, _addr) = listener.accept().await?;
            let _ = std::fs::remove_file(&socket_path);

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

            let mut results = Vec::new();
            for &size in PAYLOAD_SIZES.iter() {
                let payload = "x".repeat(size);

                for _ in 0..WARMUP_ITERATIONS {
                    let mut request = echo_client.echo_request();
                    request.get().set_message(payload.as_str());
                    request.send().promise.await?;
                }

                let start = Instant::now();
                for _ in 0..ITERATIONS_PER_SIZE {
                    let mut request = echo_client.echo_request();
                    request.get().set_message(payload.as_str());
                    request.send().promise.await?;
                }
                let elapsed = start.elapsed();

                results.push(BenchmarkResult::new(
                    format!("echo round-trip ({} payload)", size_label(size)),
                    ITERATIONS_PER_SIZE,
                    elapsed.as_micros(),
                ));
            }

            report_benchmarks("capnp-rpc: UDS echo call", &results);

            Ok::<(), Box<dyn std::error::Error>>(())
        })
        .await
}

struct BenchmarkResult {
    name: String,
    iterations: u32,
    elapsed_micros: u128,
}

impl BenchmarkResult {
    fn new(name: String, iterations: u32, elapsed_micros: u128) -> Self {
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
/// `$GITHUB_STEP_SUMMARY` when running in a GitHub Actions job.
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
