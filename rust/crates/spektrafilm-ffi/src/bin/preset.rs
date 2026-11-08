//! Import/export spektrafilm GUI presets.
//!
//! Two directions, both on the same code the app uses:
//!   import — a community `.json` becomes this engine's parameters
//!   export — the current look becomes a file the desktop app can open
//!
//!   cargo run --release --bin sf-preset -- import preset.json --data data
//!   cargo run --release --bin sf-preset -- export --film kodak_portra_400 \
//!       --paper kodak_portra_endura --data data out.json

use std::ffi::CString;

use spektrafilm::{sf_preset_export, sf_preset_import};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        usage();
        std::process::exit(2);
    }

    let mut data_dir = String::from("data");
    let mut film: Option<String> = None;
    let mut paper: Option<String> = None;
    let mut params_file: Option<String> = None;
    let mut positional: Vec<String> = Vec::new();

    let mut i = 1; // args[0] is the subcommand
    while i < args.len() {
        match args[i].as_str() {
            "--data" => {
                data_dir = args[i + 1].clone();
                i += 2;
            }
            "--film" => {
                film = Some(args[i + 1].clone());
                i += 2;
            }
            "--paper" => {
                paper = Some(args[i + 1].clone());
                i += 2;
            }
            "--params" => {
                params_file = Some(args[i + 1].clone());
                i += 2;
            }
            other => {
                positional.push(other.to_string());
                i += 1;
            }
        }
    }

    let current_json = params_file.as_ref().map(|p| {
        std::fs::read_to_string(p).unwrap_or_else(|e| panic!("reading {p}: {e}"))
    });
    let c_data = CString::new(data_dir.as_str()).unwrap();
    let c_current = current_json
        .as_ref()
        .map(|j| CString::new(j.as_str()).unwrap());

    match args[0].as_str() {
        "merge" => {
            merge_cmd(&positional);
        }
        "import" => {
            let Some(path) = positional.first() else {
                usage();
                std::process::exit(2);
            };
            let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("reading {path}: {e}"));
            let c_text = CString::new(text).unwrap();

            let mut err = [0i8; 2048];
            let need = unsafe {
                sf_preset_import(
                    c_text.as_ptr(),
                    c_data.as_ptr(),
                    c_current.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
                    std::ptr::null_mut(),
                    0,
                    err.as_mut_ptr(),
                    err.len(),
                )
            };
            if need < 0 {
                fail(&err, need);
            }
            let mut buf = vec![0i8; need as usize];
            let written = unsafe {
                sf_preset_import(
                    c_text.as_ptr(),
                    c_data.as_ptr(),
                    c_current.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
                    buf.as_mut_ptr(),
                    buf.len(),
                    err.as_mut_ptr(),
                    err.len(),
                )
            };
            if written < 0 {
                fail(&err, written);
            }
            let json = unsafe { std::ffi::CStr::from_ptr(buf.as_ptr()) }.to_string_lossy();
            let value: serde_json::Value = serde_json::from_str(&json).expect("engine emits JSON");
            println!(
                "film={} paper={}",
                value["film"].as_str().unwrap_or("?"),
                value["paper"].as_str().unwrap_or("?")
            );
            println!("params={}", serde_json::to_string(&value["params"]).unwrap());
        }
        "export" => {
            let Some(output) = positional.first() else {
                usage();
                std::process::exit(2);
            };
            let (Some(film), Some(paper)) = (film, paper) else {
                eprintln!("export needs --film and --paper");
                std::process::exit(2);
            };
            let c_film = CString::new(film.as_str()).unwrap();
            let c_paper = CString::new(paper.as_str()).unwrap();
            let c_out = CString::new(output.as_str()).unwrap();
            let mut err = [0i8; 2048];
            let n = unsafe {
                sf_preset_export(
                    c_film.as_ptr(),
                    c_paper.as_ptr(),
                    c_current.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
                    c_data.as_ptr(),
                    c_out.as_ptr(),
                    err.as_mut_ptr(),
                    err.len(),
                )
            };
            if n < 0 {
                fail(&err, n);
            }
            println!("OK  {output}  {n} bytes");
        }
        _ => {
            usage();
            std::process::exit(2);
        }
    }
}

/// `merge base.json over.json` — deep-merges two RuntimeParams JSON objects.
fn merge_cmd(positional: &[String]) {
    if positional.len() < 2 {
        usage();
        std::process::exit(2);
    }
    let base = std::fs::read_to_string(&positional[0]).expect("reading base");
    let over = std::fs::read_to_string(&positional[1]).expect("reading override");
    let c_base = CString::new(base).unwrap();
    let c_over = CString::new(over).unwrap();
    let mut err = [0i8; 2048];

    let need = unsafe {
        spektrafilm::sf_merge_params(
            c_base.as_ptr(),
            c_over.as_ptr(),
            std::ptr::null_mut(),
            0,
            err.as_mut_ptr(),
            err.len(),
        )
    };
    if need < 0 {
        fail(&err, need);
    }
    let mut buf = vec![0i8; need as usize];
    let written = unsafe {
        spektrafilm::sf_merge_params(
            c_base.as_ptr(),
            c_over.as_ptr(),
            buf.as_mut_ptr(),
            buf.len(),
            err.as_mut_ptr(),
            err.len(),
        )
    };
    if written < 0 {
        fail(&err, written);
    }
    let json = unsafe { std::ffi::CStr::from_ptr(buf.as_ptr()) }.to_string_lossy();
    println!("{json}");
}

fn fail(err: &[i8; 2048], code: i32) -> ! {
    let msg = unsafe { std::ffi::CStr::from_ptr(err.as_ptr()) }.to_string_lossy();
    eprintln!("FAILED (code {code}): {msg}");
    std::process::exit(1);
}

fn usage() {
    eprintln!(
        "usage:\n  sf-preset import <preset.json> [--data DIR] [--params current.json]\n  \
         sf-preset export --film NAME --paper NAME [--data DIR] [--params p.json] out.json"
    );
}
