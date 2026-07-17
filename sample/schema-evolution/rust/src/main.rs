// Cross-language schema-evolution runtime compat driver (Rust side).
//
// See sample/schema-evolution/README.md for the full picture. This binary
// only implements one language's half; ci/run-tests.sh interleaves it with
// the Dart binary (sample/schema-evolution/dart) so that messages written by
// one language's vN schema are read back by the other language's vM schema.
//
// Usage:
//   schema-evolution-rust write-v1 <path>
//   schema-evolution-rust read-v2  <path>
//   schema-evolution-rust write-v2 <path>
//   schema-evolution-rust read-v1  <path>

// `default_parent_module(["v1_capnp"])` in build.rs makes the generated code
// reference itself as `crate::v1_capnp::widget_capnp::...`, so the include
// must be nested to match (same convention as the `capnpc` crate docs for
// compiling more than one schema file with colliding stems into one crate).
pub mod v1_capnp {
    pub mod widget_capnp {
        include!(concat!(env!("OUT_DIR"), "/v1/widget_capnp.rs"));
    }
}
pub mod v2_capnp {
    pub mod widget_capnp {
        include!(concat!(env!("OUT_DIR"), "/v2/widget_capnp.rs"));
    }
}

use std::fs;

const EXPECTED_ID_1: u64 = 42;
const EXPECTED_NAME_1: &str = "Widget-A";
const EXPECTED_COLOR_1: &str = "red";

const EXPECTED_ID_2: u64 = 99;
const EXPECTED_NAME_2: &str = "Widget-B";
const EXPECTED_COLOR_2: &str = "blue";
const EXPECTED_WEIGHT_2: f64 = 3.5;
const EXPECTED_TAGS_2: [&str; 2] = ["shiny", "new"];

fn check_eq<T: PartialEq + std::fmt::Debug>(label: &str, got: T, expected: T) {
    if got != expected {
        eprintln!("MISMATCH {label}: got={got:?} expected={expected:?}");
        std::process::exit(1);
    }
    println!("  ok: {label} = {got:?}");
}

fn write_v1(path: &str) {
    let mut message = capnp::message::Builder::new_default();
    {
        let mut w = message.init_root::<v1_capnp::widget_capnp::widget::Builder>();
        w.set_id(EXPECTED_ID_1);
        w.set_name(EXPECTED_NAME_1);
        w.set_color(EXPECTED_COLOR_1);
    }
    let bytes = capnp::serialize::write_message_to_words(&message);
    fs::write(path, bytes).expect("write v1 message");
    println!("rust write-v1 -> {path}");
}

fn read_v2(path: &str) {
    let bytes = fs::read(path).expect("read v1-encoded message");
    let reader = capnp::serialize::read_message_from_flat_slice(
        &mut bytes.as_slice(),
        Default::default(),
    )
    .expect("parse message");
    let w = reader
        .get_root::<v2_capnp::widget_capnp::widget::Reader>()
        .expect("get_root v2");
    println!("rust read-v2 <- {path} (message was written against v1)");
    check_eq("id", w.get_id(), EXPECTED_ID_1);
    check_eq(
        "name",
        w.get_name().unwrap().to_str().unwrap().to_string(),
        EXPECTED_NAME_1.to_string(),
    );
    check_eq(
        "color",
        w.get_color().unwrap().to_str().unwrap().to_string(),
        EXPECTED_COLOR_1.to_string(),
    );
    // Fields absent from the v1-encoded message must resolve to v2's
    // declared defaults, not crash or return garbage.
    check_eq("weight (v2-only, defaulted)", w.get_weight(), 1.0f64);
    check_eq(
        "tags (v2-only, absent -> empty)",
        w.get_tags().map(|l| l.len()).unwrap_or(0),
        0u32,
    );
    check_eq(
        "status (v2-only, defaulted)",
        w.get_status().unwrap(),
        v2_capnp::widget_capnp::Status::Active,
    );
}

fn write_v2(path: &str) {
    let mut message = capnp::message::Builder::new_default();
    {
        let mut w = message.init_root::<v2_capnp::widget_capnp::widget::Builder>();
        w.set_id(EXPECTED_ID_2);
        w.set_name(EXPECTED_NAME_2);
        w.set_color(EXPECTED_COLOR_2);
        w.set_weight(EXPECTED_WEIGHT_2);
        {
            let mut tags = w.reborrow().init_tags(EXPECTED_TAGS_2.len() as u32);
            for (i, t) in EXPECTED_TAGS_2.iter().enumerate() {
                tags.set(i as u32, *t);
            }
        }
        w.set_status(v2_capnp::widget_capnp::Status::Discontinued);
    }
    let bytes = capnp::serialize::write_message_to_words(&message);
    fs::write(path, bytes).expect("write v2 message");
    println!("rust write-v2 -> {path}");
}

fn read_v1(path: &str) {
    let bytes = fs::read(path).expect("read v2-encoded message");
    let reader = capnp::serialize::read_message_from_flat_slice(
        &mut bytes.as_slice(),
        Default::default(),
    )
    .expect("parse message");
    let w = reader
        .get_root::<v1_capnp::widget_capnp::widget::Reader>()
        .expect("get_root v1");
    println!("rust read-v1 <- {path} (message was written against v2)");
    // v1 code has never heard of weight/tags/status; the point of this test
    // is that it doesn't need to — it must still read the fields it knows
    // about correctly and must not error on the unknown trailing data.
    check_eq("id", w.get_id(), EXPECTED_ID_2);
    check_eq(
        "name",
        w.get_name().unwrap().to_str().unwrap().to_string(),
        EXPECTED_NAME_2.to_string(),
    );
    check_eq(
        "color",
        w.get_color().unwrap().to_str().unwrap().to_string(),
        EXPECTED_COLOR_2.to_string(),
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: {} <write-v1|read-v2|write-v2|read-v1> <path>", args[0]);
        std::process::exit(2);
    }
    let mode = args[1].as_str();
    let path = args[2].as_str();
    match mode {
        "write-v1" => write_v1(path),
        "read-v2" => read_v2(path),
        "write-v2" => write_v2(path),
        "read-v1" => read_v1(path),
        other => {
            eprintln!("unknown mode: {other}");
            std::process::exit(2);
        }
    }
}
