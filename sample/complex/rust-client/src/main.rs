// Rust-as-client reverse interop test client.
//
// Connects to the Dart server (sample/complex/dart-server) on 127.0.0.1:12347
// and verifies that the Dart RPC server correctly handles incoming calls from
// an external Rust client.
//
// Tests:
//   1. echoScalars     — basic scalar encode/decode from Dart server
//   2. makePipeline    — capability return + ping call
//   3. callObserver    — Rust-side callback cap (Rust→Dart→Rust call chain)
//   4. exchangeCapabilities — List(Interface) round-trip
//   5. failIntentionally    — error propagation
//   6. shutdown        — graceful server shutdown

use capnp::capability::FromClientHook;
use capnp_rpc::{rpc_twoparty_capnp, twoparty, RpcSystem};
use futures::AsyncReadExt;
use std::cell::RefCell;
use std::rc::Rc;
use tokio::net::TcpStream;
use tokio::task;
use tokio_util::compat::TokioAsyncReadCompatExt;

pub mod complex_capnp {
    include!(concat!(env!("OUT_DIR"), "/complex_capnp.rs"));
}

use complex_capnp::{complex_test_service, observer, pipeline_target};

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

static mut PASS: u32 = 0;
static mut FAIL: u32 = 0;

fn pass(label: &str) {
    println!("  ✓ {}", label);
    unsafe { PASS += 1; }
}

fn fail(label: &str, reason: &str) {
    println!("  ✗ {} — {}", label, reason);
    unsafe { FAIL += 1; }
}

macro_rules! check {
    ($label:expr, $cond:expr) => {
        if $cond { pass($label); } else { fail($label, "assertion failed"); }
    };
}

macro_rules! check_eq {
    ($label:expr, $got:expr, $expected:expr) => {{
        let g = $got;
        let e = $expected;
        if g == e { pass($label); } else {
            fail($label, &format!("got {:?}, expected {:?}", g, e));
        }
    }};
}

// ---------------------------------------------------------------------------
// Rust-side observer implementation
// ---------------------------------------------------------------------------

struct ObserverImpl {
    next_count: Rc<RefCell<u32>>,
    complete: Rc<RefCell<bool>>,
}

impl observer::Server<complex_capnp::person::Owned> for ObserverImpl {
    async fn on_next(
        self: Rc<Self>,
        _params: observer::OnNextParams<complex_capnp::person::Owned>,
        _results: observer::OnNextResults<complex_capnp::person::Owned>,
    ) -> Result<(), capnp::Error> {
        *self.next_count.borrow_mut() += 1;
        Ok(())
    }

    async fn on_complete(
        self: Rc<Self>,
        _params: observer::OnCompleteParams<complex_capnp::person::Owned>,
        _results: observer::OnCompleteResults<complex_capnp::person::Owned>,
    ) -> Result<(), capnp::Error> {
        *self.complete.borrow_mut() = true;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

async fn test_echo_scalars(svc: &complex_test_service::Client) {
    println!("[1] echoScalars");
    let mut req = svc.echo_scalars_request();
    {
        let mut b = req.get().init_value();
        b.set_boolean(true);
        b.set_int32_value(42);
        b.set_text_value("hello from Rust");
        b.set_uint64_value(9999999999);
    }
    match req.send().promise.await {
        Ok(resp) => {
            let r = match resp.get() {
                Ok(r) => r,
                Err(e) => { fail("echoScalars response parse", &e.to_string()); return; }
            };
            let v = match r.get_value() {
                Ok(v) => v,
                Err(e) => { fail("echoScalars get_value", &e.to_string()); return; }
            };
            check_eq!("boolean", v.get_boolean(), true);
            check_eq!("int32Value", v.get_int32_value(), 42);
            check_eq!("uint64Value", v.get_uint64_value(), 9999999999u64);
            let text = v.get_text_value().ok().and_then(|t| t.to_str().ok()).unwrap_or("");
            check_eq!("textValue", text, "hello from Rust");
        }
        Err(e) => fail("echoScalars call", &e.to_string()),
    }
}

async fn test_make_pipeline(svc: &complex_test_service::Client) {
    println!("[2] makePipeline + ping");
    let mut req = svc.make_pipeline_request();
    req.get().set_depth(2);

    match req.send().promise.await {
        Ok(resp) => {
            let target: pipeline_target::Client = match resp.get() {
                Ok(r) => match r.get_target() {
                    Ok(t) => t,
                    Err(e) => { fail("makePipeline get_target", &e.to_string()); return; }
                },
                Err(e) => { fail("makePipeline response", &e.to_string()); return; }
            };
            check!("makePipeline returns target", true);

            // Ping the returned cap
            let mut ping_req = target.ping_request();
            ping_req.get().set_payload(&[1, 2, 3]);
            match ping_req.send().promise.await {
                Ok(ping_resp) => {
                    let payload = ping_resp.get()
                        .and_then(|r| r.get_payload())
                        .unwrap_or_default();
                    check_eq!("ping payload length", payload.len(), 3);
                    check_eq!("ping payload[0]", payload[0], 1u8);
                    check_eq!("ping payload[2]", payload[2], 3u8);
                }
                Err(e) => fail("ping call", &e.to_string()),
            }
        }
        Err(e) => fail("makePipeline call", &e.to_string()),
    }
}

async fn test_call_observer(svc: &complex_test_service::Client) {
    println!("[3] callObserver (Rust→Dart→Rust)");
    let next_count = Rc::new(RefCell::new(0u32));
    let complete = Rc::new(RefCell::new(false));

    let observer: observer::Client<complex_capnp::person::Owned> =
        capnp_rpc::new_client(ObserverImpl {
            next_count: next_count.clone(),
            complete: complete.clone(),
        });

    let mut req = svc.call_observer_request();
    {
        let mut b = req.get();
        b.set_observer(observer);
        let mut events = b.init_events(3);
        events.reborrow().get(0).set_name("Alice");
        events.reborrow().get(1).set_name("Bob");
        events.get(2).set_name("Carol");
    }

    match req.send().promise.await {
        Ok(resp) => {
            let delivered = resp.get()
                .map(|r| r.get_delivered())
                .unwrap_or(0);
            check_eq!("callObserver delivered", delivered, 3u32);
            check_eq!("observer onNext count", *next_count.borrow(), 3u32);
            check!("observer onComplete called", *complete.borrow());
        }
        Err(e) => fail("callObserver call", &e.to_string()),
    }
}

async fn test_exchange_capabilities(svc: &complex_test_service::Client) {
    println!("[4] exchangeCapabilities (List(Interface) round-trip)");

    // First get a PipelineTarget cap
    let mut make_req = svc.make_pipeline_request();
    make_req.get().set_depth(1);
    let target = match make_req.send().promise.await {
        Ok(resp) => match resp.get().and_then(|r| r.get_target()) {
            Ok(t) => t,
            Err(e) => { fail("exchangeCapabilities makePipeline", &e.to_string()); return; }
        },
        Err(e) => { fail("exchangeCapabilities makePipeline call", &e.to_string()); return; }
    };

    // Send bundle with primary + targets[0] = same cap
    let mut req = svc.exchange_capabilities_request();
    {
        let mut bundle = req.get().init_bundle();
        bundle.set_primary(target.clone());
        let mut tgts = bundle.init_targets(1);
        tgts.reborrow().set(0, target.clone().into_client_hook());
    }

    match req.send().promise.await {
        Ok(resp) => {
            let bundle = match resp.get().and_then(|r| r.get_bundle()) {
                Ok(b) => b,
                Err(e) => { fail("exchangeCapabilities get_bundle", &e.to_string()); return; }
            };
            check!("exchangeCapabilities returns bundle", true);

            // Verify echoed primary by calling ping
            let echoed_primary = match bundle.get_primary() {
                Ok(p) => p,
                Err(e) => { fail("get_primary", &e.to_string()); return; }
            };
            let mut ping_req = echoed_primary.ping_request();
            ping_req.get().set_payload(&[0xAB]);
            match ping_req.send().promise.await {
                Ok(r) => {
                    let payload = r.get().and_then(|r| r.get_payload()).unwrap_or_default();
                    check_eq!("echoed primary ping[0]", payload.first().copied().unwrap_or(0), 0xABu8);
                }
                Err(e) => fail("echoed primary ping", &e.to_string()),
            }

            // Verify echoed targets list
            let targets = match bundle.get_targets() {
                Ok(t) => t,
                Err(e) => { fail("get_targets", &e.to_string()); return; }
            };
            check_eq!("targets length", targets.len(), 1u32);

            let echoed_target = match targets.get(0) {
                Ok(t) => t,
                Err(e) => { fail("targets.get(0)", &e.to_string()); return; }
            };
            let mut ping2 = echoed_target.ping_request();
            ping2.get().set_payload(&[0xCD]);
            match ping2.send().promise.await {
                Ok(r) => {
                    let payload = r.get().and_then(|r| r.get_payload()).unwrap_or_default();
                    check_eq!("echoed target[0] ping[0]", payload.first().copied().unwrap_or(0), 0xCDu8);
                }
                Err(e) => fail("echoed target[0] ping", &e.to_string()),
            }
        }
        Err(e) => fail("exchangeCapabilities call", &e.to_string()),
    }
}

async fn test_fail_intentionally(svc: &complex_test_service::Client) {
    println!("[5] failIntentionally");
    let mut req = svc.fail_intentionally_request();
    {
        let mut b = req.get();
        b.set_code(42);
        b.set_message("test error from Rust client");
    }
    match req.send().promise.await {
        Ok(_) => fail("failIntentionally should error", "got Ok"),
        Err(e) => {
            let msg = e.to_string();
            check!("failIntentionally returns error", !msg.is_empty());
            check!("error contains code", msg.contains("42") || msg.contains("test error"));
        }
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("Connecting to Dart server on 127.0.0.1:12347...");

    let local = task::LocalSet::new();
    local.run_until(async {
        let stream = TcpStream::connect("127.0.0.1:12347").await?;
        stream.set_nodelay(true)?;
        println!("Connected.\n");

        let (reader, writer) = stream.compat().split();
        let network = twoparty::VatNetwork::new(
            futures::io::BufReader::new(reader),
            futures::io::BufWriter::new(writer),
            rpc_twoparty_capnp::Side::Client,
            Default::default(),
        );

        let mut rpc_system = RpcSystem::new(Box::new(network), None);
        let svc: complex_test_service::Client =
            rpc_system.bootstrap(rpc_twoparty_capnp::Side::Server);

        task::spawn_local(rpc_system);

        test_echo_scalars(&svc).await;
        test_make_pipeline(&svc).await;
        test_call_observer(&svc).await;
        test_exchange_capabilities(&svc).await;
        test_fail_intentionally(&svc).await;

        // Shutdown the Dart server
        println!("\n[6] shutdown");
        let _ = svc.shutdown_request().send().promise.await;
        pass("shutdown sent");

        let (pass_count, fail_count) = unsafe { (PASS, FAIL) };
        println!("\n══════════════════════════════════════");
        println!("PASSED: {}   FAILED: {}", pass_count, fail_count);
        println!("══════════════════════════════════════");

        if fail_count > 0 {
            std::process::exit(1);
        }
        Ok(())
    }).await
}
