use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let zzdds_lib = manifest_dir.join("../../../zzdds/zig-out/lib");

    println!("cargo:rustc-link-search=native={}", zzdds_lib.display());
    println!("cargo:rustc-link-search=native={}", manifest_dir.display());
    println!("cargo:rustc-link-lib=dylib=zzdds");
    println!("cargo:rustc-link-lib=dylib=spike_shim");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", zzdds_lib.display());
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", manifest_dir.display());
}
