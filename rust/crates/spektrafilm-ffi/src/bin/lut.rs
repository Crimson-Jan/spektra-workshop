//! Export the current film + paper look as a `.cube` 3D LUT.
//!
//! Same artefact the app produces: a per-pixel colour map for Resolve,
//! Photoshop, Affinity and the rest. Spatial effects (grain, halation) are
//! excluded by design.
//!
//!   cargo run --release --bin sf-lut -- \
//!       --data data --film kodak_portra_400 --size 33 out.cube

use std::ffi::CString;

use spektrafilm::sf_export_lut;

fn main() {
    let mut data_dir = String::from("data");
    let mut film = String::from("kodak_portra_400");
    let mut paper: Option<String> = None;
    let mut size: u32 = 33;
    let mut positional: Vec<String> = Vec::new();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data" => data_dir = args.next().expect("--data needs a path"),
            "--film" => film = args.next().expect("--film needs a name"),
            "--paper" => paper = Some(args.next().expect("--paper needs a name")),
            "--size" => {
                size = args
                    .next()
                    .expect("--size needs a number")
                    .parse()
                    .expect("--size must be an integer")
            }
            "--help" | "-h" => {
                eprintln!(
                    "usage: sf-lut [--data DIR] [--film NAME] [--paper NAME] [--size N] OUT.cube"
                );
                return;
            }
            other => positional.push(other.to_string()),
        }
    }

    let out = positional.first().cloned().unwrap_or_else(|| "look.cube".into());

    let c_film = CString::new(film.as_str()).unwrap();
    let c_paper = paper.map(|p| CString::new(p).unwrap());
    let c_data = CString::new(data_dir.as_str()).unwrap();
    let c_out = CString::new(out.as_str()).unwrap();

    let mut err = [0i8; 2048];
    let written = unsafe {
        sf_export_lut(
            c_film.as_ptr(),
            c_paper.as_ref().map_or(std::ptr::null(), |p| p.as_ptr()),
            c_data.as_ptr(),
            std::ptr::null(),
            size,
            c_out.as_ptr(),
            err.as_mut_ptr(),
            err.len(),
        )
    };

    if written >= 0 {
        println!("OK  {out}  {written} bytes  {size}^3");
        // A .cube is text; print the header so the shape is visible in CI logs.
        let head = std::fs::read_to_string(&out).unwrap_or_default();
        for line in head.lines().take(4) {
            println!("  | {line}");
        }
    } else {
        let msg = unsafe { std::ffi::CStr::from_ptr(err.as_ptr()) }.to_string_lossy();
        eprintln!("FAILED (code {written}): {msg}");
        std::process::exit(1);
    }
}
