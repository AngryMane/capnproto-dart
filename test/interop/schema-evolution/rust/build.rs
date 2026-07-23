fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let schema_dir = std::path::Path::new(&manifest).parent().unwrap().join("schema");
    let out_dir = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());

    // Both v1/widget.capnp and v2/widget.capnp generate a file named
    // `widget_capnp.rs`; give each version its own output subdirectory so
    // they don't clobber each other in OUT_DIR.
    let v1_out = out_dir.join("v1");
    let v2_out = out_dir.join("v2");
    std::fs::create_dir_all(&v1_out).unwrap();
    std::fs::create_dir_all(&v2_out).unwrap();

    capnpc::CompilerCommand::new()
        .src_prefix(schema_dir.join("v1"))
        .file(schema_dir.join("v1").join("widget.capnp"))
        .output_path(&v1_out)
        .default_parent_module(vec!["v1_capnp".to_string()])
        .run()
        .expect("v1 schema compilation failed");

    capnpc::CompilerCommand::new()
        .src_prefix(schema_dir.join("v2"))
        .file(schema_dir.join("v2").join("widget.capnp"))
        .output_path(&v2_out)
        .default_parent_module(vec!["v2_capnp".to_string()])
        .run()
        .expect("v2 schema compilation failed");
}
