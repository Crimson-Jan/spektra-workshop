use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

use spektrafilm_core::image_size;
use spektrafilm_core::params::RuntimeParams;
use spektrafilm_core::stages::filming::metering_preview;
use spektrafilm_io::crop::Crop;
use spektrafilm_io::{InputColour, InputInterpretation, LensCorrection, RawWhiteBalance};
use spektrafilm_math::image::ImageBuf;
use spektrafilm_math::precision::Scalar;

// Keep one working frame, including for a crop whose working size exceeds the
// preview's output size. Large crops can render without retaining another copy.
const MAX_CACHED_IMAGE_BYTES: usize = 32 * 1024 * 1024;
static PREVIEW_INPUT: Mutex<Option<CachedInput>> = Mutex::new(None);

#[derive(PartialEq)]
struct SourceKey {
    path: PathBuf,
    modified: SystemTime,
    bytes: u64,
    white_balance: RawWhiteBalance,
    lens: LensCorrection,
    interpretation: InputInterpretation,
}

impl SourceKey {
    fn new(path: &Path, params: &RuntimeParams) -> Option<Self> {
        let metadata = std::fs::metadata(path).ok()?;
        Some(Self {
            path: path.to_owned(),
            modified: metadata.modified().ok()?,
            bytes: metadata.len(),
            white_balance: params.io.raw_white_balance,
            lens: params.io.lens_correction,
            interpretation: params.io.input_interpretation.clone(),
        })
    }
}

#[derive(Clone)]
pub(crate) struct PreparedInput {
    pub image: ImageBuf,
    pub metering: Option<ImageBuf>,
}

struct CachedInput {
    key: SourceKey,
    source_size: (u32, u32),
    colour: InputColour,
    prepared: PreparedInput,
}

fn reuse_input(
    key: Option<&SourceKey>,
    params: &mut RuntimeParams,
    crop: Option<&Crop>,
) -> Result<Option<PreparedInput>, String> {
    let Ok(mut cache) = PREVIEW_INPUT.lock() else {
        return Ok(None);
    };
    if let Some(cached) = cache.as_ref().filter(|cached| key == Some(&cached.key)) {
        let size = image_size::resolve(params, cached.source_size, crop)
            .map_err(|err| format!("image size: {err}"))?;
        let working = &cached.prepared.image;
        if size.working == (working.width, working.height) {
            params.io.apply_input_colour(&cached.colour);
            image_size::clear(params);
            return Ok(Some(cached.prepared.clone()));
        }
    }
    // Drop the previous working buffer before decoding a large original.
    *cache = None;
    Ok(None)
}

pub(crate) fn prepare_input(
    path: &Path,
    params: &mut RuntimeParams,
    crop: Option<&Crop>,
    preview: bool,
) -> Result<PreparedInput, String> {
    let key = preview.then(|| SourceKey::new(path, params)).flatten();
    if let Some(prepared) = reuse_input(key.as_ref(), params, crop)? {
        return Ok(prepared);
    }

    let loaded = spektrafilm_io::load_image_colour(
        path,
        spektrafilm_io::Formats::Any,
        params.io.raw_white_balance,
        params.io.lens_correction,
        &params.io.input_interpretation,
    )
    .map_err(|err| format!("decoding {}: {err}", path.display()))?;
    params.io.apply_input_colour(&loaded.colour);

    // Keep the meter's view of the full source, before resize or crop,
    // so a cache hit produces exactly the same exposure.
    let metering =
        (params.camera.auto_exposure || key.is_some()).then(|| metering_preview(&loaded.image));
    let (image, size) = image_size::prepare(loaded.image, params, crop)
        .map_err(|err| format!("image size: {err}"))?;
    let prepared = PreparedInput { image, metering };
    if let Some(key) = key
        && prepared.image.data.len() <= MAX_CACHED_IMAGE_BYTES / size_of::<Scalar>()
        && let Ok(mut cache) = PREVIEW_INPUT.lock()
    {
        *cache = Some(CachedInput {
            key,
            source_size: size.source,
            colour: loaded.colour,
            prepared: prepared.clone(),
        });
    }
    Ok(prepared)
}

#[cfg(test)]
mod tests {
    use super::*;
    use spektrafilm_io::save::{SaveOptions, save_image_with_options};

    #[test]
    fn cached_frame_keeps_source_metering_and_rejects_changed_input_size_or_decode() {
        let path = std::env::temp_dir().join(format!(
            "spektrafilm-cache-test-{}.png",
            std::process::id()
        ));
        let mut source = ImageBuf::new(320, 200);
        for (index, value) in source.data.iter_mut().enumerate() {
            *value = (index % 127) as Scalar / 126.0;
        }
        save_image_with_options(&source, &path, None, &SaveOptions::default()).unwrap();

        let mut params = RuntimeParams::default();
        params.camera.auto_exposure = false;
        params.io.photo_long_side_px = Some(128);
        let cached = prepare_input(&path, &mut params.clone(), None, true).unwrap();

        let mut warm_params = params.clone();
        warm_params.camera.auto_exposure = true;
        warm_params.camera.exposure_compensation_ev = 1.0;
        let key = SourceKey::new(&path, &warm_params).unwrap();
        let warm = reuse_input(Some(&key), &mut warm_params, None)
            .unwrap()
            .expect("exposure edits reuse the input");
        assert_eq!(warm.image.data, cached.image.data);
        assert_eq!(warm_params.io.photo_long_side_px, None);
        let exact = prepare_input(&path, &mut params.clone(), None, false).unwrap();
        assert_eq!(warm.image.data, exact.image.data);

        prepare_input(&path, &mut params.clone(), None, true).unwrap();
        let crop = Crop { x: 0.25, y: 0.25, width: 0.5, height: 0.5, angle: 0.0 };
        assert!(reuse_input(Some(&key), &mut params.clone(), Some(&crop)).unwrap().is_none());
        let cropped = prepare_input(&path, &mut params.clone(), Some(&crop), true).unwrap();
        assert_eq!((cropped.image.width, cropped.image.height), (256, 160));
        assert_eq!(warm.metering.unwrap().data, cropped.metering.unwrap().data);

        params.io.lens_correction.enabled = true;
        let changed = SourceKey::new(&path, &params).unwrap();
        assert!(reuse_input(Some(&changed), &mut params, Some(&crop)).unwrap().is_none());
        std::fs::remove_file(path).unwrap();
    }
}
