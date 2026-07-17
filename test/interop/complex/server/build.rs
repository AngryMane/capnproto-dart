fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let schema_dir = std::path::Path::new(&manifest).parent().unwrap().join("schema");
    capnpc::CompilerCommand::new()
        .src_prefix(&schema_dir)
        // Needed to resolve the absolute import "/capnp/stream.capnp" from the stub in schema/capnp/.
        .import_path(&schema_dir)
        .file(schema_dir.join("complex.capnp"))
        .run()
        .expect("capnp schema compilation failed");
}
