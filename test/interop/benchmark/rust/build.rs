fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let schema_dir = std::path::Path::new(&manifest).parent().unwrap().join("schema");
    capnpc::CompilerCommand::new()
        .src_prefix(&schema_dir)
        .file(schema_dir.join("metrics.capnp"))
        .file(schema_dir.join("echo.capnp"))
        .run()
        .expect("capnp schema compilation failed");
}
