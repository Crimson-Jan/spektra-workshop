//! C ABI for the HarmonyOS app shell.
//!
//! This crate is the only Rust surface the ArkTS side ever sees. Everything
//! crossing the boundary is a plain C scalar, a NUL-terminated UTF-8 string, or
//! a caller-owned byte buffer — no Rust type, no generic, no `Box`, so the
//! static library can be linked straight into the NAPI `.so` by CMake.
//!
//! Every entry point catches panics and converts them to an error code: a
//! panic unwinding across the FFI boundary would abort the HarmonyOS process.
//!
//! Threading: the engine uses rayon internally. Call these from a NAPI async
//! work callback, never from the UI thread.

use std::ffi::{c_char, CStr};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::time::Instant;

use spektrafilm_core::params::RuntimeParams;
use spektrafilm_core::pipeline::{self, Pipeline};
use spektrafilm_core::profile;
use spektrafilm_io::border::{FilmFormat, BorderOptions, BorderStyle};
use spektrafilm_io::crop::Crop;
use spektrafilm_io::save::SaveOptions;
use spektrafilm_math::colorspace::RgbColourspace;

/// Border request as JSON: `{"style":"35mm","width":0.03,"line":0.004,
/// "color":"#ffffff","line_color":"#000000"}`. Only `style` is required.
#[derive(serde::Deserialize)]
struct BorderSpec {
    style: String,
    #[serde(default)]
    width: Option<f64>,
    #[serde(default)]
    line: Option<f64>,
    #[serde(default)]
    color: Option<String>,
    #[serde(default)]
    line_color: Option<String>,
    /// The frame to build, e.g. "6x6"; omitted means "from the aspect ratio".
    #[serde(default)]
    format: Option<String>,
    /// Edge fog on the rebate, 0 to 1.
    #[serde(default)]
    fog: Option<f64>,
    /// Spool light leak at the ends of the strip, 0 to 1.
    #[serde(default)]
    leak: Option<f64>,
}

impl BorderSpec {
    fn build(self) -> Result<(BorderStyle, BorderOptions), String> {
        let style: BorderStyle = self.style.parse().map_err(|e| format!("{e}"))?;
        let mut options = BorderOptions::default();
        if let Some(width) = self.width {
            options.width = Some(width);
        }
        if let Some(line) = self.line {
            options.line = line;
        }
        if let Some(colour) = self.color {
            options.color = colour.parse().map_err(|e| format!("{e}"))?;
        }
        if let Some(colour) = self.line_color {
            options.line_color = colour.parse().map_err(|e| format!("{e}"))?;
        }
        if let Some(name) = self.format {
            options.format = Some(
                FilmFormat::from_name(&name)
                    .ok_or_else(|| format!("unknown frame format {name:?}"))?,
            );
        }
        if let Some(fog) = self.fog {
            options.fog = fog;
        }
        if let Some(leak) = self.leak {
            options.leak = leak;
        }
        Ok((style, options))
    }
}

/// Export request as JSON: `{"quality":92,"bit_depth":16}`. The file format is
/// decided by the output path's extension, as everywhere else in this ABI.
#[derive(serde::Deserialize, Default)]
struct OutputSpec {
    /// JPEG quality, 1-100. Ignored for PNG and TIFF.
    #[serde(default)]
    quality: Option<u8>,
    /// Bits per channel for PNG and TIFF: 8 or 16.
    #[serde(default)]
    bit_depth: Option<u8>,
}

/// Success.
pub const SF_OK: i32 = 0;
/// A required string argument was NULL, not UTF-8, or a path could not be read.
pub const SF_ERR_ARG: i32 = -1;
/// The engine rejected the render (missing profile, bad params, I/O, OOM).
pub const SF_ERR_RENDER: i32 = -2;
/// A Rust panic was caught at the boundary.
pub const SF_ERR_PANIC: i32 = -3;
/// The caller's output buffer was too small.
pub const SF_ERR_BUFFER: i32 = -4;

const VERSION: &[u8] = b"negs-0.13.0-ohos-cpu\0";

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/// # Safety
/// `p` must be NULL or a valid NUL-terminated C string.
unsafe fn to_str<'a>(p: *const c_char, what: &str) -> Result<&'a str, String> {
    if p.is_null() {
        return Err(format!("{what} must not be NULL"));
    }
    let c = unsafe { CStr::from_ptr(p) };
    c.to_str()
        .map_err(|e| format!("{what} is not valid UTF-8: {e}"))
}

/// # Safety
/// As [`to_str`], but NULL maps to `None` instead of an error.
unsafe fn to_opt_str<'a>(p: *const c_char) -> Result<Option<&'a str>, String> {
    if p.is_null() {
        return Ok(None);
    }
    let c = unsafe { CStr::from_ptr(p) };
    if c.is_empty() {
        return Ok(None);
    }
    c.to_str()
        .map(Some)
        .map_err(|e| format!("argument is not valid UTF-8: {e}"))
}

/// Copy `msg` into the caller's buffer, always NUL-terminated, never overrunning.
///
/// # Safety
/// `buf` must be NULL or point at `cap` writable bytes.
unsafe fn write_out(buf: *mut c_char, cap: usize, msg: &str) {
    if buf.is_null() || cap == 0 {
        return;
    }
    let bytes = msg.as_bytes();
    let n = bytes.len().min(cap - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
}

fn err_code(err: String) -> i32 {
    let _ = err;
    SF_ERR_RENDER
}

/// Reads an optional `[x, y, width, height, angle]` array of fractions (plus
/// degrees) into a crop rectangle. NULL, a zero/negative width, or a
/// full-frame rectangle all mean "no crop".
///
/// # Safety
/// `p` must be NULL or point at 5 readable `f64`.
unsafe fn to_crop(p: *const f64) -> Option<Crop> {
    if p.is_null() {
        return None;
    }
    let v = unsafe { std::slice::from_raw_parts(p, 5) };
    let crop = Crop {
        x: v[0],
        y: v[1],
        width: v[2],
        height: v[3],
        angle: v[4],
    };
    if crop.width <= 0.0 || crop.height <= 0.0 {
        return None;
    }
    // A full frame with no straightening is not worth a resample.
    let full = (crop.x - 0.0).abs() < 1e-9
        && (crop.y - 0.0).abs() < 1e-9
        && (crop.width - 1.0).abs() < 1e-9
        && (crop.height - 1.0).abs() < 1e-9
        && crop.angle.abs() < 1e-9;
    if full { None } else { Some(crop) }
}

// ---------------------------------------------------------------------------
// version
// ---------------------------------------------------------------------------

/// A NUL-terminated engine version string. The pointer is static and must not
/// be freed.
#[unsafe(no_mangle)]
pub extern "C" fn sf_version() -> *const c_char {
    VERSION.as_ptr() as *const c_char
}

// ---------------------------------------------------------------------------
// profiles
// ---------------------------------------------------------------------------

/// Write the bundled profile catalogue to `out_json` as
/// `{"films":[{"name":..,"target_print":..}],"papers":[".."]}`.
///
/// Returns the number of bytes written (excluding the NUL), or a negative
/// error code. Pass `out_json = NULL, cap = 0` to query the required size.
///
/// # Safety
/// `data_dir` is a C string; `out_json` is NULL or `cap` writable bytes;
/// `err_buf` is NULL or `err_cap` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_catalog(
    data_dir: *const c_char,
    out_json: *mut c_char,
    cap: usize,
    err_buf: *mut c_char,
    err_cap: usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<String, String> {
        let data_dir = unsafe { to_str(data_dir, "data_dir") }?;
        build_catalog(Path::new(data_dir))
    }));

    match result {
        Ok(Ok(json)) => {
            let need = json.len() + 1;
            if out_json.is_null() || cap == 0 {
                return need as i32;
            }
            if cap < need {
                unsafe { write_out(err_buf, err_cap, "output buffer too small") };
                return SF_ERR_BUFFER;
            }
            unsafe { write_out(out_json, cap, &json) };
            json.len() as i32
        }
        Ok(Err(e)) => {
            unsafe { write_out(err_buf, err_cap, &e) };
            err_code(e)
        }
        Err(_) => {
            unsafe { write_out(err_buf, err_cap, "panic while building catalogue") };
            SF_ERR_PANIC
        }
    }
}

fn build_catalog(data_dir: &Path) -> Result<String, String> {
    use serde_json::{Value, json};

    let dir = data_dir.join("profiles");
    let mut films = Vec::new();
    let mut papers = Vec::new();

    let entries = std::fs::read_dir(&dir)
        .map_err(|e| format!("reading {}: {e}", dir.display()))?;

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Some(name) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        // Read the file directly rather than through the typed loader: the
        // catalogue only needs the `info` block, and `ProfileInfo` is
        // deserialise-only.
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        // One damaged file must not empty the picker.
        let Ok(value) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        let info = value.get("info").cloned().unwrap_or(Value::Null);
        let field = |key: &str| -> String {
            info.get(key).and_then(|v| v.as_str()).unwrap_or_default().to_string()
        };
        let label = {
            let named = field("name");
            if named.is_empty() { name.to_string() } else { named }
        };

        // Classified by the profile's own `support` field. The old rule — "has
        // a target_print" — put every reversal stock in the paper list, because
        // slides are viewed directly and print onto nothing.
        if field("support") == "paper" {
            papers.push(json!({ "name": name, "label": label }));
        } else {
            films.push(json!({
                "name": name,
                "label": label,
                "type": field("type"),
                "use": field("use"),
                "channel": field("channel_model"),
                "target_print": field("target_print"),
            }));
        }
    }

    films.sort_by(|a, b| a["label"].as_str().cmp(&b["label"].as_str()));
    papers.sort_by(|a, b| a["label"].as_str().cmp(&b["label"].as_str()));

    serde_json::to_string(&json!({ "films": films, "papers": papers }))
        .map_err(|e| format!("serialising catalogue: {e}"))
}
// ---------------------------------------------------------------------------
// render
// ---------------------------------------------------------------------------

/// Render one photograph through the film simulation.
///
/// * `input`      source image (TIFF, PNG, JPEG or camera RAW)
/// * `output`     destination; format follows the extension (.png/.tif/.jpg)
/// * `film`       a profile name from `sf_catalog`'s `films`
/// * `paper`      a profile name from `papers`; NULL/empty uses the film's
///                own `target_print`
/// * `data_dir`   directory containing `profiles/`
/// * `params_json` optional `RuntimeParams` JSON overriding the defaults;
///                NULL or empty means defaults
/// * `crop`       optional `[x, y, width, height, angle]`: a rectangle as
///                fractions of the unrotated photograph with the origin top
///                left, then a clockwise straightening angle in degrees.
///                NULL, or a full frame with no angle, means no crop.
/// * `out_width`  optional pointer receiving the output width in px
/// * `out_height` optional pointer receiving the output height in px
/// * `out_ms`     optional pointer receiving the elapsed milliseconds
///
/// Returns [`SF_OK`] or a negative error code, with a UTF-8 message in
/// `err_buf` on failure.
///
/// # Safety
/// All pointers must satisfy the same contract as [`sf_catalog`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_render_file(
    input: *const c_char,
    output: *const c_char,
    film: *const c_char,
    paper: *const c_char,
    data_dir: *const c_char,
    params_json: *const c_char,
    crop: *const f64,
    border_json: *const c_char,
    output_json: *const c_char,
    out_width: *mut u32,
    out_height: *mut u32,
    out_ms: *mut u64,
    err_buf: *mut c_char,
    err_cap: usize,
) -> i32 {
    let started = Instant::now();

    let result = catch_unwind(AssertUnwindSafe(|| -> Result<(u32, u32), String> {
        let input = unsafe { to_str(input, "input") }?;
        let output = unsafe { to_str(output, "output") }?;
        let film = unsafe { to_str(film, "film") }?;
        let paper = unsafe { to_opt_str(paper)? };
        let data_dir = unsafe { to_str(data_dir, "data_dir") }?;
        let params_json = unsafe { to_opt_str(params_json)? };
        let crop = unsafe { to_crop(crop) };

        let border = match unsafe { to_opt_str(border_json)? } {
            Some(json) if !json.is_empty() => {
                let spec: BorderSpec =
                    serde_json::from_str(json).map_err(|e| format!("parsing border: {e}"))?;
                Some(spec.build()?)
            }
            _ => None,
        };

        let output_spec = match unsafe { to_opt_str(output_json)? } {
            Some(json) if !json.is_empty() => serde_json::from_str(json)
                .map_err(|e| format!("parsing output options: {e}"))?,
            _ => OutputSpec::default(),
        };

        render(
            Path::new(input),
            Path::new(output),
            film,
            paper,
            Path::new(data_dir),
            params_json,
            crop,
            border,
            output_spec,
        )
    }));

    let code = match result {
        Ok(Ok((w, h))) => {
            if !out_width.is_null() {
                unsafe { *out_width = w };
            }
            if !out_height.is_null() {
                unsafe { *out_height = h };
            }
            SF_OK
        }
        Ok(Err(e)) => {
            unsafe { write_out(err_buf, err_cap, &e) };
            err_code(e)
        }
        Err(_) => {
            unsafe { write_out(err_buf, err_cap, "engine panicked") };
            SF_ERR_PANIC
        }
    };

    if !out_ms.is_null() {
        unsafe { *out_ms = started.elapsed().as_millis() as u64 };
    }
    code
}

fn render(
    input: &Path,
    output: &Path,
    film_name: &str,
    paper_name: Option<&str>,
    data_dir: &Path,
    params_json: Option<&str>,
    crop: Option<Crop>,
    border: Option<(BorderStyle, BorderOptions)>,
    output_spec: OutputSpec,
) -> Result<(u32, u32), String> {
    // --- profiles -----------------------------------------------------------
    let film = profile::load_profile_by_name(data_dir, film_name)
        .map_err(|e| format!("loading film profile '{film_name}': {e}"))?;

    // A reversal film has no paper: it is projected, or scanned directly.
    // The engine still wants a print profile, so the film prints onto its own
    // curves and the scan path skips the paper entirely.
    let print_stock = match paper_name {
        Some(p) => p.to_string(),
        None => match film.info.target_print.clone() {
            Some(target) => target,
            None => film_name.to_string(),
        },
    };
    let print = profile::load_profile_by_name(data_dir, &print_stock)
        .map_err(|e| format!("loading print profile '{print_stock}': {e}"))?;

    // --- parameters ---------------------------------------------------------
    let mut params: RuntimeParams = match params_json {
        Some(json) => serde_json::from_str(json).map_err(|e| format!("parsing params: {e}"))?,
        None => RuntimeParams::default(),
    };
    params
        .io
        .input_interpretation
        .validate()
        .map_err(|e| format!("input interpretation: {e}"))?;

    let encoded = params.io.output_cctf_encoding;
    let rotate_cw = params.io.rotate_cw;

    // --- decode -------------------------------------------------------------
    let loaded = spektrafilm_io::load_image_colour(
        input,
        spektrafilm_io::Formats::Any,
        params.io.raw_white_balance,
        params.io.lens_correction,
        &params.io.input_interpretation,
    )
    .map_err(|e| format!("decoding {}: {e}", input.display()))?;
    params.io.apply_input_colour(&loaded.colour);
    let image = loaded.image;

    // Meter the full source before any resize, matching the export path.
    let metering = params
        .camera
        .auto_exposure
        .then(|| spektrafilm_core::stages::filming::metering_preview(&image));

    // Image Size resizes before the film so grain forms at working size. The
    // crop is passed in because a "long side" target describes the *cropped*
    // photograph, not the source frame.
    let (image, _size) = spektrafilm_core::image_size::prepare(image, &mut params, crop.as_ref())
        .map_err(|e| format!("image size: {e}"))?;

    // --- pipeline -----------------------------------------------------------
    let mut pipeline = Pipeline::new_with_spectral(film, print, params.clone(), data_dir)
        .map_err(|e| format!("building spectral pipeline: {e}"))?;
    if let Some(metering) = metering {
        pipeline = pipeline.with_metering_preview(metering);
    }

    let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
    let (mut result, _backend_name) = pipeline.process_with_backend(image, &backend);

    // --- output -------------------------------------------------------------
    // Crop/border/resize work on the file as written, so clip first; the
    // writer clips anyway but the encoder expects display-referred values.
    pipeline::clip_to_display(&mut result, encoded);
    // Order matters and matches the desktop app: crop (which may straighten by
    // resampling), then the quarter-turn rotation.
    let result = match crop {
        Some(c) => c.apply(&result),
        None => result,
    };
    let result = result.rotated_cw(rotate_cw);

    // The border is added last, exactly as the desktop export does: it frames
    // the photograph as it will be written, so it must come after crop and
    // rotation and before any resize.
    let result = match border {
        Some((style, options)) => {
            let finish = spektrafilm_io::encoding::Encoding::new(
                &params.io.output_color_space,
                encoded,
            );
            spektrafilm_io::border::add_border(
                &result, style, &options, film_name, finish, data_dir,
            )
            .map_err(|e| format!("adding border: {e}"))?
        }
        None => result,
    };

    let mut save_options = SaveOptions::default();
    save_options.color_space = RgbColourspace::output(&params.io.output_color_space)
        .name
        .into();
    save_options.linear = !encoded;
    if let Some(quality) = output_spec.quality {
        save_options.jpeg_quality = quality;
    }
    if let Some(depth) = output_spec.bit_depth {
        save_options.bit_depth = Some(depth);
    }
    save_options
        .check(output)
        .map_err(|e| format!("cannot write {}: {e}", output.display()))?;

    let metadata = spektrafilm_io::read_metadata(input);
    spektrafilm_io::save::save_image_with_options(&result, output, metadata.as_ref(), &save_options)
        .map_err(|e| format!("saving {}: {e}", output.display()))?;

    Ok((result.width, result.height))
}

// ---------------------------------------------------------------------------
// presets
// ---------------------------------------------------------------------------

/// Import a Python-spektrafilm GUI preset (the community `.json` format).
///
/// The engine translates it into its own parameters, resolves the film and
/// paper, and merges the result over `current_json` so settings that belong to
/// this device (input interpretation, output colour space, post edits) survive
/// and only the *look* changes.
///
/// Writes `{"film": .., "paper": .., "params": { ..RuntimeParams.. }}` to
/// `out_json` and returns its length. Pass `out_json = NULL, cap = 0` to query
/// the required size.
///
/// # Safety
/// Same contract as [`sf_catalog`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_preset_import(
    text: *const c_char,
    data_dir: *const c_char,
    current_json: *const c_char,
    out_json: *mut c_char,
    cap: usize,
    err_buf: *mut c_char,
    err_cap: usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<String, String> {
        let text = unsafe { to_str(text, "preset text") }?;
        let data_dir = unsafe { to_str(data_dir, "data_dir") }?;
        let current_json = unsafe { to_opt_str(current_json)? };

        let preset = spektrafilm_core::presets::import(text, Path::new(data_dir))?;
        let current: RuntimeParams = match current_json {
            Some(json) => {
                serde_json::from_str(json).map_err(|e| format!("parsing current params: {e}"))?
            }
            None => RuntimeParams::default(),
        };
        let merged = spektrafilm_core::presets::apply(&preset.params, &current);

        serde_json::to_string(&serde_json::json!({
            "film": preset.film,
            "paper": preset.paper,
            "params": merged,
        }))
        .map_err(|e| format!("serialising preset: {e}"))
    }));

    match result {
        Ok(Ok(json)) => {
            let need = json.len() + 1;
            if out_json.is_null() || cap == 0 {
                return need as i32;
            }
            if cap < need {
                unsafe { write_out(err_buf, err_cap, "output buffer too small") };
                return SF_ERR_BUFFER;
            }
            unsafe { write_out(out_json, cap, &json) };
            json.len() as i32
        }
        Ok(Err(e)) => {
            unsafe { write_out(err_buf, err_cap, &e) };
            err_code(e)
        }
        Err(_) => {
            unsafe { write_out(err_buf, err_cap, "engine panicked") };
            SF_ERR_PANIC
        }
    }
}

/// Write the current look as a preset file Python spektrafilm can open.
///
/// This is the sharing direction: the file round-trips into the desktop app and
/// into anyone else's install, so a look can be handed to a collaborator.
/// Returns the number of bytes written.
///
/// # Safety
/// Same contract as [`sf_catalog`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_preset_export(
    film: *const c_char,
    paper: *const c_char,
    params_json: *const c_char,
    data_dir: *const c_char,
    output: *const c_char,
    err_buf: *mut c_char,
    err_cap: usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<usize, String> {
        let film = unsafe { to_str(film, "film") }?;
        let paper = unsafe { to_str(paper, "paper") }?;
        let params_json = unsafe { to_opt_str(params_json)? };
        let data_dir = unsafe { to_str(data_dir, "data_dir") }?;
        let output = unsafe { to_str(output, "output") }?;

        let params: RuntimeParams = match params_json {
            Some(json) => serde_json::from_str(json).map_err(|e| format!("parsing params: {e}"))?,
            None => RuntimeParams::default(),
        };

        let text = spektrafilm_core::presets::export(film, paper, &params, Path::new(data_dir))?;
        std::fs::write(output, text.as_bytes()).map_err(|e| format!("writing {output}: {e}"))?;
        Ok(text.len())
    }));

    match result {
        Ok(Ok(n)) => n as i32,
        Ok(Err(e)) => {
            unsafe { write_out(err_buf, err_cap, &e) };
            err_code(e)
        }
        Err(_) => {
            unsafe { write_out(err_buf, err_cap, "engine panicked") };
            SF_ERR_PANIC
        }
    }
}

// ---------------------------------------------------------------------------
// parameter merging
// ---------------------------------------------------------------------------

/// Deep-merge two `RuntimeParams` JSON objects, `over` winning, into a single
/// JSON object.
///
/// The UI keeps a loaded preset as the base and the live controls as the
/// override, so adjusting a slider does not throw away the rest of the preset.
/// Doing this in Rust keeps the JSON handling out of ArkTS, where untyped
/// object manipulation is awkward.
///
/// # Safety
/// Same contract as [`sf_catalog`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_merge_params(
    base_json: *const c_char,
    over_json: *const c_char,
    out_json: *mut c_char,
    cap: usize,
    err_buf: *mut c_char,
    err_cap: usize,
) -> i32 {
    fn deep_merge(base: &mut serde_json::Value, over: &serde_json::Value) {
        match (base, over) {
            (serde_json::Value::Object(b), serde_json::Value::Object(o)) => {
                for (k, v) in o {
                    match b.get_mut(k) {
                        Some(bv) => deep_merge(bv, v),
                        None => {
                            b.insert(k.clone(), v.clone());
                        }
                    }
                }
            }
            (b, o) => *b = o.clone(),
        }
    }

    let result = catch_unwind(AssertUnwindSafe(|| -> Result<String, String> {
        let base = unsafe { to_opt_str(base_json)? }.unwrap_or("{}");
        let over = unsafe { to_opt_str(over_json)? }.unwrap_or("{}");

        let mut base: serde_json::Value =
            serde_json::from_str(base).map_err(|e| format!("parsing base params: {e}"))?;
        let over: serde_json::Value =
            serde_json::from_str(over).map_err(|e| format!("parsing override params: {e}"))?;
        deep_merge(&mut base, &over);
        serde_json::to_string(&base).map_err(|e| format!("serialising params: {e}"))
    }));

    match result {
        Ok(Ok(json)) => {
            let need = json.len() + 1;
            if out_json.is_null() || cap == 0 {
                return need as i32;
            }
            if cap < need {
                unsafe { write_out(err_buf, err_cap, "output buffer too small") };
                return SF_ERR_BUFFER;
            }
            unsafe { write_out(out_json, cap, &json) };
            json.len() as i32
        }
        Ok(Err(e)) => {
            unsafe { write_out(err_buf, err_cap, &e) };
            err_code(e)
        }
        Err(_) => {
            unsafe { write_out(err_buf, err_cap, "engine panicked") };
            SF_ERR_PANIC
        }
    }
}

// ---------------------------------------------------------------------------
// self-test
// ---------------------------------------------------------------------------

/// Render a synthetic gradient through a film/paper pair without touching the
/// filesystem for input. Useful as a device-side smoke test and for the
/// host-vs-device parity harness the port needs.
///
/// Writes the result to `output` and returns [`SF_OK`].
///
/// # Safety
/// Same contract as [`sf_render_file`], minus `input`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_render_test_pattern(
    width: u32,
    height: u32,
    output: *const c_char,
    film: *const c_char,
    paper: *const c_char,
    data_dir: *const c_char,
    out_width: *mut u32,
    out_height: *mut u32,
    out_ms: *mut u64,
    err_buf: *mut c_char,
    err_cap: usize,
) -> i32 {
    let started = Instant::now();

    let result = catch_unwind(AssertUnwindSafe(|| -> Result<(u32, u32), String> {
        let output = unsafe { to_str(output, "output") }?;
        let film_name = unsafe { to_str(film, "film") }?;
        let paper = unsafe { to_opt_str(paper)? };
        let data_dir = unsafe { to_str(data_dir, "data_dir") }?;
        test_pattern(
            width,
            height,
            Path::new(output),
            film_name,
            paper,
            Path::new(data_dir),
        )
    }));

    let code = match result {
        Ok(Ok((w, h))) => {
            if !out_width.is_null() {
                unsafe { *out_width = w };
            }
            if !out_height.is_null() {
                unsafe { *out_height = h };
            }
            SF_OK
        }
        Ok(Err(e)) => {
            unsafe { write_out(err_buf, err_cap, &e) };
            err_code(e)
        }
        Err(_) => {
            unsafe { write_out(err_buf, err_cap, "engine panicked") };
            SF_ERR_PANIC
        }
    };

    if !out_ms.is_null() {
        unsafe { *out_ms = started.elapsed().as_millis() as u64 };
    }
    code
}

fn test_pattern(
    width: u32,
    height: u32,
    output: &Path,
    film_name: &str,
    paper_name: Option<&str>,
    data_dir: &Path,
) -> Result<(u32, u32), String> {
    use spektrafilm_math::image::ImageBuf;

    let film = profile::load_profile_by_name(data_dir, film_name)
        .map_err(|e| format!("loading film profile '{film_name}': {e}"))?;
    let print_stock = match paper_name {
        Some(p) => p.to_string(),
        None => film
            .info
            .target_print
            .clone()
            .ok_or_else(|| format!("film '{film_name}' has no target_print"))?,
    };
    let print = profile::load_profile_by_name(data_dir, &print_stock)
        .map_err(|e| format!("loading print profile '{print_stock}': {e}"))?;

    let params = RuntimeParams::default();

    // Scene-linear ramp plus saturated patches: enough to expose a wrong
    // colour matrix, a broken tone curve or a transposed buffer.
    let mut img = ImageBuf::new(width.max(8), height.max(8));
    let w = img.width as f32;
    let h = img.height as f32;
    for y in 0..img.height {
        for x in 0..img.width {
            let u = x as f32 / (w - 1.0);
            let v = y as f32 / (h - 1.0);
            let band = (v * 4.0).floor() / 4.0;
            let base = u * u; // gamma-2 ramp so shadow detail is visible
            let (r, g, b) = match band {
                0.0 => (base, base, base),
                0.25 => (base, base * 0.25, base * 0.05),
                0.5 => (base * 0.05, base, base * 0.15),
                0.75 => (base * 0.05, base * 0.12, base),
                _ => (base, base * 0.5, base),
            };
            let i = img.idx(x, y, 0);
            img.data[i] = r;
            img.data[i + 1] = g;
            img.data[i + 2] = b;
        }
    }

    let mut pipeline = Pipeline::new_with_spectral(film, print, params.clone(), data_dir)
        .map_err(|e| format!("building spectral pipeline: {e}"))?;
    let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
    let (mut result, _backend_name) = pipeline.process_with_backend(img, &backend);
    pipeline::clip_to_display(&mut result, params.io.output_cctf_encoding);

    let mut save_options = SaveOptions::default();
    save_options.linear = !params.io.output_cctf_encoding;
    save_options
        .check(output)
        .map_err(|e| format!("cannot write {}: {e}", output.display()))?;
    spektrafilm_io::save::save_image_with_options(&result, output, None, &save_options)
        .map_err(|e| format!("saving {}: {e}", output.display()))?;
    Ok((result.width, result.height))
}

// ---------------------------------------------------------------------------
// 配光: solve the enlarger's filter pack
// ---------------------------------------------------------------------------

/// Mean linear RGB of the middle of a rendered frame, and how far its blue and
/// red sit from green in log terms — the two numbers an enlarger's yellow and
/// magenta filters trade in.
fn print_cast(image: &spektrafilm_math::image::ImageBuf) -> (f64, f64, f64) {
    let (x0, x1) = (image.width / 4, image.width * 3 / 4);
    let (y0, y1) = (image.height / 4, image.height * 3 / 4);
    let mut sum = [0.0f64; 3];
    let mut count = 0.0f64;
    for y in y0..y1 {
        for x in x0..x1 {
            let i = ((y * image.width + x) * 3) as usize;
            for c in 0..3 {
                sum[c] += image.data[i + c] as f64;
            }
            count += 1.0;
        }
    }
    let mean = [sum[0] / count, sum[1] / count, sum[2] / count];
    // Guard against a black frame, where a log ratio is meaningless.
    let g = mean[1].max(1e-6);
    ((mean[2] / g).max(1e-6).ln(), (mean[0] / g).max(1e-6).ln(), mean[1])
}

/// Iterate the enlarger's filter pack until the print's midtones are neutral.
///
/// A real enlarger is balanced by eye the same way: add yellow when the print
/// is too blue, magenta when it is too green, and look again. Four passes on a
/// small frame get within a couple of CC points, which is finer than the eye.
#[allow(clippy::too_many_arguments)]
fn solve_filters(
    input: &Path,
    data_dir: &Path,
    film_name: &str,
    paper_name: Option<&str>,
    params_json: Option<&str>,
    crop: Option<&Crop>,
    iterations: u32,
) -> Result<String, String> {
    let film = profile::load_profile_by_name(data_dir, film_name)
        .map_err(|e| format!("loading film profile '{film_name}': {e}"))?;
    let print_stock = match paper_name {
        Some(p) => p.to_string(),
        None => match film.info.target_print.clone() {
            Some(target) => target,
            None => film_name.to_string(),
        },
    };
    let print = profile::load_profile_by_name(data_dir, &print_stock)
        .map_err(|e| format!("loading print profile '{print_stock}': {e}"))?;

    let mut params: RuntimeParams = match params_json {
        Some(json) => serde_json::from_str(json).map_err(|e| format!("parsing params: {e}"))?,
        None => RuntimeParams::default(),
    };
    // The solve owns the filter pack from here on.
    params.settings.neutral_print_filters_from_database = false;
    params.enlarger.y_filter_neutral = 0.0;
    params.enlarger.m_filter_neutral = 0.0;

    let loaded = spektrafilm_io::load_image_colour(
        input,
        spektrafilm_io::Formats::Any,
        params.io.raw_white_balance,
        params.io.lens_correction,
        &params.io.input_interpretation,
    )
    .map_err(|e| format!("decoding {}: {e}", input.display()))?;
    params.io.apply_input_colour(&loaded.colour);

    // Small enough to iterate in a second, large enough to average away grain.
    let mut source = loaded.image;
    let long = source.width.max(source.height);
    if long > 256 {
        let scale = 256.0 / long as f64;
        let (w, h) = (
            ((source.width as f64 * scale) as u32).max(8),
            ((source.height as f64 * scale) as u32).max(8),
        );
        source = spektrafilm_io::resize::catmull_rom(&source, (w, h));
    }

    let backend = spektrafilm_gpu::cpu_backend::CpuBackend;

    // One measurement: render at (y, m) and read the cast off the print.
    let measure = |y: f32, m: f32| -> Result<(f64, f64), String> {
        let mut trial = params.clone();
        trial.enlarger.y_filter_neutral = y;
        trial.enlarger.m_filter_neutral = m;
        let mut pipeline =
            Pipeline::new_with_spectral(film.clone(), print.clone(), trial, data_dir)
                .map_err(|e| format!("building spectral pipeline: {e}"))?;
        let (mut result, _) = pipeline.process_with_backend(source.clone(), &backend);
        pipeline::clip_to_display(&mut result, true);
        let (blue, red, _) = print_cast(&result);
        Ok((blue, red))
    };

    // Newton on the two filters, with the Jacobian measured rather than
    // assumed: whether yellow cools or warms depends on the paper's layers and
    // on how the scan is read, and guessing the sign the first time gave a
    // solver that walked away from the answer.
    let mut y = 0.0f32;
    let mut m = 0.0f32;
    let mut cast = measure(y, m)?;
    let mut level = 0.0;
    let steps = iterations.clamp(1, 5);
    for _ in 0..steps {
        let (dy, dm) = (measure(y + 10.0, m)?, measure(y, m + 10.0)?);
        let (j11, j12) = ((dy.0 - cast.0) / 10.0, (dm.0 - cast.0) / 10.0);
        let (j21, j22) = ((dy.1 - cast.1) / 10.0, (dm.1 - cast.1) / 10.0);
        let det = j11 * j22 - j12 * j21;
        if det.abs() < 1e-9 {
            break;
        }
        let step_y = (-cast.0 * j22 + cast.1 * j12) / det;
        let step_m = (-cast.1 * j11 + cast.0 * j21) / det;
        y = (y + (step_y as f32).clamp(-60.0, 60.0)).clamp(0.0, 180.0);
        m = (m + (step_m as f32).clamp(-60.0, 60.0)).clamp(0.0, 180.0);
        cast = measure(y, m)?;
        level = y + m; // keeps the last value from being optimised away
        if cast.0.abs() < 0.004 && cast.1.abs() < 0.004 {
            break;
        }
    }
    let _ = level;
    Ok(serde_json::json!({
        "y": (y * 10.0).round() / 10.0,
        "m": (m * 10.0).round() / 10.0,
        "c": 0.0,
        "cast": [(cast.0 * 1000.0).round() / 1000.0, (cast.1 * 1000.0).round() / 1000.0],
        "level": (level * 1000.0).round() / 1000.0,
        "paper": print_stock,
        "iterations": iterations.max(1),
    })
    .to_string())
}
// ---------------------------------------------------------------------------
// 配光: solve the enlarger's filter pack
// ---------------------------------------------------------------------------

/// Frees a string an entry point handed back through an `out` pointer.
///
/// # Safety
/// `s` must come from this library, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { std::ffi::CString::from_raw(s) });
    }
}

/// Solve the enlarger's filter pack for `input`, writing the result as JSON to
/// `out_json` (caller frees with `sf_string_free`).
///
/// The desktop's 配光 button: it renders a small proxy a few times and returns
/// the yellow and magenta values that make the print neutral, so the picture
/// stops leaning blue or yellow the way an unbalanced head makes it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_solve_filters(
    input: *const c_char,
    data_dir: *const c_char,
    film: *const c_char,
    paper: *const c_char,
    params_json: *const c_char,
    crop: *const f64,
    iterations: u32,
    out_json: *mut *mut c_char,
    err_buf: *mut c_char,
    err_cap: usize,
) -> i32 {
    let cap = err_cap;
    let result = (|| -> Result<String, String> {
        let input = Path::new(unsafe { to_str(input, "input")? });
        let data_dir = Path::new(unsafe { to_str(data_dir, "data_dir")? });
        let film = unsafe { to_str(film, "film")? };
        let paper = unsafe { to_opt_str(paper)? };
        let params_json = unsafe { to_opt_str(params_json)? };
        let crop = unsafe { to_crop(crop) };
        solve_filters(input, data_dir, film, paper, params_json, crop.as_ref(), iterations)
    })();
    match result {
        Ok(json) => {
            unsafe { *out_json = std::ffi::CString::new(json).unwrap().into_raw() };
            0
        }
        Err(message) => {
            unsafe { write_out(err_buf, cap, &message) };
            -2
        }
    }
}
// ---------------------------------------------------------------------------
// 3D LUT export
// ---------------------------------------------------------------------------

/// Export the current film + paper look as a .cube 3D LUT.
///
/// This is how the look travels to Resolve, Photoshop and the rest — the same
/// artefact the desktop app offers. Spatial effects (grain, halation) and post
/// edits are excluded by definition: a LUT is a per-pixel map.
///
/// * `size` — grid edge length; 33 is the usual choice, 65 for smooth gradients.
///
/// Returns the number of bytes written to `output`.
///
/// # Safety
/// Same contract as [`sf_catalog`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_export_lut(
    film: *const c_char,
    paper: *const c_char,
    data_dir: *const c_char,
    params_json: *const c_char,
    size: u32,
    output: *const c_char,
    err_buf: *mut c_char,
    err_cap: usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<usize, String> {
        let film = unsafe { to_str(film, "film") }?;
        let paper = unsafe { to_opt_str(paper)? };
        let data_dir = unsafe { to_str(data_dir, "data_dir") }?;
        let params_json = unsafe { to_opt_str(params_json)? };
        let output = unsafe { to_str(output, "output") }?;

        if size < 2 || size > 129 {
            return Err(format!("LUT size must be between 2 and 129, got {size}"));
        }

        let params: RuntimeParams = match params_json {
            Some(json) => serde_json::from_str(json).map_err(|e| format!("parsing params: {e}"))?,
            None => RuntimeParams::default(),
        };

        let print_stock = match paper {
            Some(p) => p.to_string(),
            None => profile::load_profile_by_name(Path::new(data_dir), film)
                .map_err(|e| format!("loading film profile '{film}': {e}"))?
                .info
                .target_print
                .clone()
                .ok_or_else(|| format!("film '{film}' has no target_print; pass a paper"))?,
        };

        let cube = spektrafilm_core::lut_export::cube(
            Path::new(data_dir),
            film,
            &print_stock,
            params,
            size,
        )?;

        std::fs::write(output, cube.as_bytes())
            .map_err(|e| format!("writing {output}: {e}"))?;
        Ok(cube.len())
    }));

    match result {
        Ok(Ok(n)) => n as i32,
        Ok(Err(e)) => {
            unsafe { write_out(err_buf, err_cap, &e) };
            err_code(e)
        }
        Err(_) => {
            unsafe { write_out(err_buf, err_cap, "engine panicked") };
            SF_ERR_PANIC
        }
    }
}
