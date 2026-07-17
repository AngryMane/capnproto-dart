// Rust-as-client reverse interop test client.
//
// Connects to the Dart server (test/interop/complex/dart-server) on 127.0.0.1:12347
// and verifies that the Dart RPC server correctly handles incoming calls from
// an external Rust client. This mirrors (a subset of) the sections exercised
// by the Dart client against the Rust server in test/interop/complex/client, so
// that RPC coverage is roughly symmetric in both directions.
//
// Tests:
//    1. echo                     — basic struct-returning method
//    2. echoScalars              — scalar encode/decode from Dart server
//    3. echoLists                — list encode/decode from Dart server
//    4. echoUnion                — union encode/decode from Dart server
//    5. echoAnyPointer           — generic AnyPointer round-trip
//    6. makePipeline             — capability return + ping call
//    7. callObserver             — Rust-side callback cap (Rust→Dart→Rust call chain)
//    8. exchangeCapabilities     — List(Interface) round-trip
//    9. getRepository            — Repository(Text, Person) CRUD
//   10. useDiamond               — Rust-side Diamond capability called back by Dart
//   11. probePipelineTarget      — Rust-side PipelineTarget capability called back by Dart
//   12. makePromisedPipeline     — promise pipelining on a Dart-side deferred capability
//   13. echoPipelineTargetLater  — Dart returns a promise that resolves to the same cap sent to it
//   14. getFactory + getUntyped  — capability factory, untyped AnyPointer payload
//   15. failIntentionally        — error propagation
//   16. shutdown                 — graceful server shutdown
//
// Not covered here (see docs/... for the tracked gap): openUpload/openDownload
// (capnp streaming methods) and CapabilityFactory.newCell/newRepository/
// echoCapability<T> generic-method testing from the Rust side — these are
// already exercised from the Dart-client/Rust-server direction in
// test/interop/complex/client (sections 17 and 21).

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

use complex_capnp::{
    complex_test_service, diamond, left, named_union, observer, optional, parent,
    pipeline_target, right, Status,
};

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
// Rust-side PipelineTarget implementation (used for probePipelineTarget /
// echoPipelineTargetLater, where the Dart server calls back into a
// Rust-hosted capability).
// ---------------------------------------------------------------------------

struct RustPipelineTargetImpl {
    name: String,
}

impl pipeline_target::Server for RustPipelineTargetImpl {
    async fn ping(
        self: Rc<Self>,
        params: pipeline_target::PingParams,
        mut results: pipeline_target::PingResults,
    ) -> Result<(), capnp::Error> {
        let payload = params.get()?.get_payload()?;
        println!(
            "[rust-client] pipeline[{}].ping({} bytes)",
            self.name,
            payload.len()
        );
        results.get().set_payload(payload);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Rust-side Diamond implementation (used for useDiamond, where the Dart
// server calls diamond.both() back into this Rust-hosted capability).
// Parent/Left/Right are left at their default "unimplemented" bodies since
// the Dart server's useDiamond handler only calls `both`.
// ---------------------------------------------------------------------------

struct RustDiamondImpl;

impl parent::Server for RustDiamondImpl {}
impl left::Server for RustDiamondImpl {}
impl right::Server for RustDiamondImpl {}

impl diamond::Server for RustDiamondImpl {
    async fn both(
        self: Rc<Self>,
        params: diamond::BothParams,
        mut results: diamond::BothResults,
    ) -> Result<(), capnp::Error> {
        let p = params.get()?;
        let sum = p.get_left_value() as i64 + p.get_right_value() as i64;
        println!("[rust-client] diamond.both({}, {})", p.get_left_value(), p.get_right_value());
        results.get().set_sum(sum);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

async fn test_echo(svc: &complex_test_service::Client) {
    println!("[1] echo");
    let req = svc.echo_request();
    match req.send().promise.await {
        Ok(resp) => match resp.get().and_then(|r| r.get_response()) {
            Ok(r) => {
                check_eq!("echo accepted", r.get_accepted(), true);
                check_eq!("echo status", r.get_status(), Ok(Status::Running));
                let msg = r.get_message().ok().and_then(|t| t.to_str().ok()).unwrap_or("");
                check_eq!("echo message", msg, "echo from Dart");
            }
            Err(e) => fail("echo get_response", &e.to_string()),
        },
        Err(e) => fail("echo call", &e.to_string()),
    }
}

async fn test_echo_scalars(svc: &complex_test_service::Client) {
    println!("[2] echoScalars");
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

async fn test_echo_lists(svc: &complex_test_service::Client) {
    println!("[3] echoLists");
    let mut req = svc.echo_lists_request();
    {
        let mut b = req.get().init_value();
        let mut texts = b.reborrow().init_texts(3);
        texts.set(0, "alpha");
        texts.set(1, "beta");
        texts.set(2, "gamma");
    }
    match req.send().promise.await {
        Ok(resp) => match resp.get().and_then(|r| r.get_value()) {
            Ok(v) => match v.get_texts() {
                Ok(texts) => {
                    check_eq!("echoLists texts.len", texts.len(), 3);
                    let t1 = texts.get(1).ok().and_then(|t| t.to_str().ok()).unwrap_or("");
                    check_eq!("echoLists texts[1]", t1, "beta");
                }
                Err(e) => fail("echoLists get_texts", &e.to_string()),
            },
            Err(e) => fail("echoLists get_value", &e.to_string()),
        },
        Err(e) => fail("echoLists call", &e.to_string()),
    }
}

async fn test_echo_union(svc: &complex_test_service::Client) {
    println!("[4] echoUnion");
    let mut req = svc.echo_union_request();
    {
        let mut b = req.get().init_value();
        b.set_selector(7);
        b.get_payload().set_text("union from Rust");
    }
    match req.send().promise.await {
        Ok(resp) => match resp.get().and_then(|r| r.get_value()) {
            Ok(v) => {
                check_eq!("echoUnion selector", v.get_selector(), 7u32);
                match v.get_payload().which() {
                    Ok(named_union::payload::Which::Text(Ok(t))) => {
                        check_eq!("echoUnion text", t.to_str().unwrap_or(""), "union from Rust");
                    }
                    other => fail("echoUnion payload variant", &format!("{:?}", other.is_ok())),
                }
            }
            Err(e) => fail("echoUnion get_value", &e.to_string()),
        },
        Err(e) => fail("echoUnion call", &e.to_string()),
    }
}

async fn test_echo_any_pointer(svc: &complex_test_service::Client) {
    println!("[5] echoAnyPointer");
    let mut req = svc.echo_any_pointer_request();
    {
        let value = req.get().init_value();
        let mut scalars = value.init_as::<complex_capnp::all_scalars::Builder>();
        scalars.set_int32_value(777);
        scalars.set_text_value("any-pointer from Rust");
    }
    match req.send().promise.await {
        Ok(resp) => match resp.get().and_then(|r| r.get_value()) {
            Ok(v) => match v.get_as::<complex_capnp::all_scalars::Reader>() {
                Ok(s) => {
                    check_eq!("echoAnyPointer int32Value", s.get_int32_value(), 777);
                    let text = s.get_text_value().ok().and_then(|t| t.to_str().ok()).unwrap_or("");
                    check_eq!("echoAnyPointer textValue", text, "any-pointer from Rust");
                }
                Err(e) => fail("echoAnyPointer get_as", &e.to_string()),
            },
            Err(e) => fail("echoAnyPointer get_value", &e.to_string()),
        },
        Err(e) => fail("echoAnyPointer call", &e.to_string()),
    }
}

async fn test_make_pipeline(svc: &complex_test_service::Client) {
    println!("[6] makePipeline + ping");
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
    println!("[7] callObserver (Rust→Dart→Rust)");
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
    println!("[8] exchangeCapabilities (List(Interface) round-trip)");

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

async fn test_get_repository(svc: &complex_test_service::Client) {
    println!("[9] getRepository (Text, Person) CRUD");
    let repo = match svc.get_repository_request().send().promise.await {
        Ok(resp) => match resp.get().and_then(|r| r.get_repository()) {
            Ok(r) => r,
            Err(e) => { fail("getRepository get_repository", &e.to_string()); return; }
        },
        Err(e) => { fail("getRepository call", &e.to_string()); return; }
    };
    check!("getRepository returns capability", true);

    // put
    let mut put_req = repo.put_request();
    {
        let mut b = put_req.get();
        let _ = b.set_key("rust-key-1");
        let mut person = b.init_value();
        person.set_name("Rust Person");
        person.set_email("rust@example.com");
    }
    let rev1 = match put_req.send().promise.await {
        Ok(resp) => resp.get().map(|r| r.get_new_revision()).unwrap_or(0),
        Err(e) => { fail("getRepository put", &e.to_string()); return; }
    };
    check!("getRepository put revision > 0", rev1 > 0);

    // get
    let mut get_req = repo.get_request();
    let _ = get_req.get().set_key("rust-key-1");
    match get_req.send().promise.await {
        Ok(resp) => match resp.get() {
            Ok(r) => {
                check_eq!("getRepository get revision", r.get_revision(), rev1);
                match r.get_result() {
                    Ok(opt) => match opt.which() {
                        Ok(optional::Which::Some(Ok(person))) => {
                            let name = person.get_name().ok().and_then(|t| t.to_str().ok()).unwrap_or("");
                            check_eq!("getRepository get person name", name, "Rust Person");
                        }
                        other => fail("getRepository get result variant", &format!("{:?}", other.is_ok())),
                    },
                    Err(e) => fail("getRepository get_result", &e.to_string()),
                }
            }
            Err(e) => fail("getRepository get response", &e.to_string()),
        },
        Err(e) => fail("getRepository get call", &e.to_string()),
    }

    // remove
    let mut remove_req = repo.remove_request();
    let _ = remove_req.get().set_key("rust-key-1");
    match remove_req.send().promise.await {
        Ok(resp) => {
            let new_rev = resp.get().map(|r| r.get_new_revision()).unwrap_or(0);
            check!("getRepository remove revision > previous", new_rev > rev1);
        }
        Err(e) => fail("getRepository remove call", &e.to_string()),
    }

    // get after remove → none
    let mut get_req2 = repo.get_request();
    let _ = get_req2.get().set_key("rust-key-1");
    match get_req2.send().promise.await {
        Ok(resp) => match resp.get().and_then(|r| r.get_result()) {
            Ok(opt) => match opt.which() {
                Ok(optional::Which::None(())) => pass("getRepository removed key is none"),
                other => fail("getRepository removed key variant", &format!("{:?}", other.is_ok())),
            },
            Err(e) => fail("getRepository get_result", &e.to_string()),
        },
        Err(e) => fail("getRepository get-after-remove call", &e.to_string()),
    }
}

async fn test_use_diamond(svc: &complex_test_service::Client) {
    println!("[10] useDiamond (Dart→Rust callback)");
    let diamond_client: diamond::Client = capnp_rpc::new_client(RustDiamondImpl);

    let mut req = svc.use_diamond_request();
    {
        let mut b = req.get();
        b.set_diamond(diamond_client);
        b.set_value(21);
    }
    match req.send().promise.await {
        Ok(resp) => {
            let result = resp.get().map(|r| r.get_result()).unwrap_or(0);
            check_eq!("useDiamond result", result, 42i64);
        }
        Err(e) => fail("useDiamond call", &e.to_string()),
    }
}

async fn test_probe_pipeline_target(svc: &complex_test_service::Client) {
    println!("[11] probePipelineTarget (Dart→Rust callback)");
    let target: pipeline_target::Client = capnp_rpc::new_client(RustPipelineTargetImpl {
        name: "rust-probe-target".to_string(),
    });

    let mut req = svc.probe_pipeline_target_request();
    {
        let mut b = req.get();
        b.set_target(target);
        b.set_payload(&[9, 8, 7]);
    }
    match req.send().promise.await {
        Ok(resp) => {
            let payload = resp.get().and_then(|r| r.get_payload()).unwrap_or_default();
            check_eq!("probePipelineTarget echoed payload", payload, &[9, 8, 7][..]);
        }
        Err(e) => fail("probePipelineTarget call", &e.to_string()),
    }
}

async fn test_make_promised_pipeline(svc: &complex_test_service::Client) {
    println!("[12] makePromisedPipeline (promise pipelining)");
    let mut req = svc.make_promised_pipeline_request();
    req.get().set_delay_ms(50);

    // Pipeline the ping call onto the not-yet-resolved target without
    // awaiting makePromisedPipeline's response first.
    let pipeline = req.send();
    let target = pipeline.pipeline.get_target();
    let mut ping_req = target.ping_request();
    ping_req.get().set_payload(&[42]);

    match ping_req.send().promise.await {
        Ok(resp) => {
            let payload = resp.get().and_then(|r| r.get_payload()).unwrap_or_default();
            check_eq!("makePromisedPipeline pipelined ping[0]", payload.first().copied().unwrap_or(0), 42u8);
        }
        Err(e) => fail("makePromisedPipeline pipelined ping", &e.to_string()),
    }
}

async fn test_echo_pipeline_target_later(svc: &complex_test_service::Client) {
    println!("[13] echoPipelineTargetLater (Dart-delayed promise resolving to Rust cap)");
    let target: pipeline_target::Client = capnp_rpc::new_client(RustPipelineTargetImpl {
        name: "rust-echo-later-target".to_string(),
    });

    let mut req = svc.echo_pipeline_target_later_request();
    {
        let mut b = req.get();
        b.set_target(target);
        b.set_delay_ms(50);
    }
    match req.send().promise.await {
        Ok(resp) => match resp.get().and_then(|r| r.get_target()) {
            Ok(echoed) => {
                let mut ping_req = echoed.ping_request();
                ping_req.get().set_payload(&[5]);
                match ping_req.send().promise.await {
                    Ok(ping_resp) => {
                        let payload = ping_resp.get().and_then(|r| r.get_payload()).unwrap_or_default();
                        check_eq!("echoPipelineTargetLater ping[0]", payload.first().copied().unwrap_or(0), 5u8);
                    }
                    Err(e) => fail("echoPipelineTargetLater ping", &e.to_string()),
                }
            }
            Err(e) => fail("echoPipelineTargetLater get_target", &e.to_string()),
        },
        Err(e) => fail("echoPipelineTargetLater call", &e.to_string()),
    }
}

async fn test_get_factory(svc: &complex_test_service::Client) {
    println!("[14] getFactory + getUntyped");
    let factory = match svc.get_factory_request().send().promise.await {
        Ok(resp) => match resp.get().and_then(|r| r.get_factory()) {
            Ok(f) => f,
            Err(e) => { fail("getFactory get_factory", &e.to_string()); return; }
        },
        Err(e) => { fail("getFactory call", &e.to_string()); return; }
    };
    check!("getFactory returns capability", true);

    let mut req = factory.get_untyped_request();
    req.get().set_name("scalars");
    match req.send().promise.await {
        Ok(resp) => match resp.get().map(|r| r.get_value()) {
            Ok(v) => match v.get_as::<complex_capnp::all_scalars::Reader>() {
                Ok(s) => {
                    check_eq!("getUntyped int32Value", s.get_int32_value(), 20260717);
                }
                Err(e) => fail("getUntyped get_as", &e.to_string()),
            },
            Err(e) => fail("getUntyped get_value", &e.to_string()),
        },
        Err(e) => fail("getUntyped call", &e.to_string()),
    }
}

async fn test_fail_intentionally(svc: &complex_test_service::Client) {
    println!("[15] failIntentionally");
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

        test_echo(&svc).await;
        test_echo_scalars(&svc).await;
        test_echo_lists(&svc).await;
        test_echo_union(&svc).await;
        test_echo_any_pointer(&svc).await;
        test_make_pipeline(&svc).await;
        test_call_observer(&svc).await;
        test_exchange_capabilities(&svc).await;
        test_get_repository(&svc).await;
        test_use_diamond(&svc).await;
        test_probe_pipeline_target(&svc).await;
        test_make_promised_pipeline(&svc).await;
        test_echo_pipeline_target_later(&svc).await;
        test_get_factory(&svc).await;
        test_fail_intentionally(&svc).await;

        // Shutdown the Dart server
        println!("\n[16] shutdown");
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
