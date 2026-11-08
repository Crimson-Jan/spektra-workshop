//! Host-side smoke test for the FFI surface.
//!
//! Renders the synthetic test pattern through a film/paper pair and writes a
//! PNG. Run it before a device build: it proves the engine still produces an
//! image after the HarmonyOS patches (BLAS removal, feature trimming), without
//! needing a tablet in the loop.
//!
//!   cargo run --bin sf-selftest -- <data-dir> <out.png> [film] [paper]

use std::ffi::CString;
use std::path::PathBuf;

// The package's lib target is named `spektrafilm` (see [lib] name), so the
// sibling bin refers to it by that name, not by the package name.
use spektrafilm::sf_render_test_pattern;

fn main() {
    let mut args = std::env::args().skip(1);
    let data_dir = PathBuf::from(args.next().unwrap_or_else(|| "data".into()));
    let out = args.next().unwrap_or_else(|| "selftest.png".into());
    let film = args.next().unwrap_or_else(|| "kodak_portra_400".into());
    let paper = args.next();

    let c_data = CString::new(data_dir.to_string_lossy().as_ref()).unwrap();
    let c_out = CString::new(out.as_str()).unwrap();
    let c_film = CString::new(film.as_str()).unwrap();
    let c_paper = paper.as_ref().map(|p| CString::new(p.as_str()).unwrap());

    let mut ms: u64 = 0;
    let mut width: u32 = 0;
    let mut height: u32 = 0;
    let mut err = [0i8; 1024];

    let code = unsafe {
        sf_render_test_pattern(
            1024,
            683,
            c_out.as_ptr(),
            c_film.as_ptr(),
            c_paper.as_ref().map_or(std::ptr::null(), |p| p.as_ptr()),
            c_data.as_ptr(),
            &mut width,
            &mut height,
            &mut ms,
            err.as_mut_ptr(),
            err.len(),
        )
    };

    let version = unsafe {
        std::ffi::CStr::from_ptr(spektrafilm::sf_version())
            .to_string_lossy()
            .into_owned()
    };
    println!("engine: {version}");

    if code == 0 {
        let size = std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0);
        println!("OK  {out}  {width}x{height}  {size} bytes  {ms} ms");
    } else {
        let msg = unsafe { std::ffi::CStr::from_ptr(err.as_ptr()) }.to_string_lossy();
        eprintln!("FAILED (code {code}) after {ms} ms: {msg}");
        std::process::exit(1);
    }
}
