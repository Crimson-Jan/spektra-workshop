//! Host-side driver for the file-in / file-out path the app uses.
//!
//! Exercises exactly the same FFI entry point as the HarmonyOS shell
//! (`sf_render_file`): decode (including RAW), build the spectral pipeline,
//! render, encode. Use it to validate engine changes on the desktop before
//! rebuilding the HAP.
//!
//!   cargo run --release --bin sf-render -- \
//!       --data data --film kodak_portra_400 in.dng out.png [--ev 0.3] [--scan]

use std::ffi::CString;

use spektrafilm::sf_render_file;

fn main() {
    let mut data_dir = String::from("data");
    let mut film = String::from("kodak_portra_400");
    let mut paper: Option<String> = None;
    let mut ev: Option<f32> = None;
    let mut scan_film = false;
    let mut raw_params: Option<String> = None;
    let mut crop: Option<Vec<f64>> = None;
    let mut border: Option<String> = None;
    let mut solve = false;
    let mut positional: Vec<String> = Vec::new();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data" => data_dir = args.next().expect("--data needs a path"),
            "--film" => film = args.next().expect("--film needs a name"),
            "--paper" => paper = Some(args.next().expect("--paper needs a name")),
            "--params" => raw_params = Some(args.next().expect("--params needs JSON")),
            // Same thing, but read from a file. Shells mangle quotes when
            // passing JSON as an argument, so scripts should prefer this.
            "--params-file" => {
                let path = args.next().expect("--params-file needs a path");
                raw_params = Some(std::fs::read_to_string(&path).unwrap_or_else(|e| {
                    panic!("reading {path}: {e}")
                }));
            }
            "--ev" => {
                ev = Some(
                    args.next()
                        .expect("--ev needs a number")
                        .parse()
                        .expect("--ev must be a number"),
                )
            }
            "--scan" => scan_film = true,
            // Print the filter pack the 配光 solve lands on, then exit.
            "--solve" => solve = true,
            // 35mm | film | keyline | white
            "--border" => {
                let style = args.next().expect("--border needs a style");
                border = Some(format!("{{\"style\":\"{style}\"}}"));
            }
            "--border-json" => {
                border = Some(args.next().expect("--border-json needs JSON"));
            }
            // x,y,width,height as fractions of the frame, optional angle in
            // degrees: --crop 0.1,0.1,0.8,0.8 or --crop 0,0,1,1,2.5
            "--crop" => {
                let raw = args.next().expect("--crop needs x,y,w,h[,angle]");
                let mut vals: Vec<f64> = raw
                    .split(',')
                    .map(|s| s.trim().parse::<f64>().expect("--crop values must be numbers"))
                    .collect();
                if vals.len() == 4 {
                    vals.push(0.0);
                }
                assert_eq!(vals.len(), 5, "--crop needs 4 or 5 comma-separated numbers");
                crop = Some(vals);
            }
            "--help" | "-h" => {
                eprintln!(
                    "usage: sf-render [--data DIR] [--film NAME] [--paper NAME] \
                     [--ev F] [--scan] INPUT OUTPUT"
                );
                return;
            }
            other => positional.push(other.to_string()),
        }
    }

    if positional.len() != 2 {
        eprintln!("expected INPUT and OUTPUT paths");
        std::process::exit(2);
    }
    let (input, output) = (&positional[0], &positional[1]);

    if solve {
        let c_input = CString::new(input.as_str()).unwrap();
        let c_data = CString::new(data_dir.as_str()).unwrap();
        let c_film = CString::new(film.as_str()).unwrap();
        let c_paper = paper.as_ref().map(|p| CString::new(p.as_str()).unwrap());
        let mut out: *mut std::os::raw::c_char = std::ptr::null_mut();
        let mut err = [0i8; 512];
        let code = unsafe {
            spektrafilm::sf_solve_filters(
                c_input.as_ptr(),
                c_data.as_ptr(),
                c_film.as_ptr(),
                c_paper.as_ref().map_or(std::ptr::null(), |p| p.as_ptr()),
                std::ptr::null(),
                std::ptr::null(),
                4,
                &mut out,
                err.as_mut_ptr(),
                err.len(),
            )
        };
        if code != 0 {
            let message = unsafe { std::ffi::CStr::from_ptr(err.as_ptr()) }.to_string_lossy();
            eprintln!("solve failed ({code}): {message}");
            std::process::exit(3);
        }
        let json = unsafe { std::ffi::CStr::from_ptr(out) }.to_string_lossy().into_owned();
        println!("{json}");
        return;
    }

    // Build the RuntimeParams override as JSON, the same way the app would.
    let mut params = String::new();
    if let Some(json) = raw_params {
        params = json;
    } else if ev.is_some() || scan_film {
        let mut parts: Vec<String> = Vec::new();
        if let Some(ev) = ev {
            parts.push(format!(
                "\"camera\":{{\"exposure_compensation_ev\":{ev},\"auto_exposure\":false}}"
            ));
        }
        if scan_film {
            parts.push("\"io\":{\"scan_film\":true}".to_string());
        }
        params = format!("{{{}}}", parts.join(","));
    }

    let c_input = CString::new(input.as_str()).unwrap();
    let c_output = CString::new(output.as_str()).unwrap();
    let c_film = CString::new(film.as_str()).unwrap();
    let c_paper = paper.map(|p| CString::new(p).unwrap());
    let c_data = CString::new(data_dir.as_str()).unwrap();
    let c_params = if params.is_empty() {
        None
    } else {
        Some(CString::new(params.clone()).unwrap())
    };
    let c_border = border.map(|b| CString::new(b).unwrap());

    let mut ms: u64 = 0;
    let mut width: u32 = 0;
    let mut height: u32 = 0;
    let mut err = [0i8; 2048];

    let code = unsafe {
        sf_render_file(
            c_input.as_ptr(),
            c_output.as_ptr(),
            c_film.as_ptr(),
            c_paper.as_ref().map_or(std::ptr::null(), |p| p.as_ptr()),
            c_data.as_ptr(),
            c_params.as_ref().map_or(std::ptr::null(), |p| p.as_ptr()),
            crop.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
            c_border.as_ref().map_or(std::ptr::null(), |b| b.as_ptr()),
            std::ptr::null(),
            &mut width,
            &mut height,
            &mut ms,
            err.as_mut_ptr(),
            err.len(),
        )
    };

    if code == 0 {
        let size = std::fs::metadata(output).map(|m| m.len()).unwrap_or(0);
        println!("OK  {output}  {width}x{height}  {size} bytes  {ms} ms");
        if !params.is_empty() {
            println!("params: {params}");
        }
    } else {
        let msg = unsafe { std::ffi::CStr::from_ptr(err.as_ptr()) }.to_string_lossy();
        eprintln!("FAILED (code {code}) after {ms} ms: {msg}");
        std::process::exit(1);
    }
}
