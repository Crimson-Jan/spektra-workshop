/**
 * Native surface of libspektrafilmoh.so — a thin NAPI bridge over the Rust
 * spectral film engine (spektrafilm-core via spektrafilm-ffi).
 *
 * Declared as named exports rather than a default-exported interface, which is
 * the shape the ArkTS compiler resolves for a `.so` module.
 *
 * Rendering runs on a native worker thread and resolves a Promise; do not
 * assume it is fast. A 12 MP frame is seconds of CPU work.
 */

/** A crop rectangle as fractions of the unrotated frame, plus a clockwise
 *  straightening angle in degrees. */
export interface CropRect {
  x: number;
  y: number;
  width: number;
  height: number;
  angle?: number;
}

export interface RenderRequest {
  /** Directory holding `profiles/` (see DataStore.dataDir). */
  dataDir: string;
  /** Destination file; format follows the extension (.png/.tif/.jpg). */
  output: string;
  /** Film profile name from `getCatalog`. */
  film: string;
  /** Paper profile name; omit to use the film's own target print. */
  paper?: string;
  /** Source image path. */
  input: string;
  /** Optional RuntimeParams JSON overriding the engine defaults. */
  params?: string;
  /**
   * Optional film-border request as JSON: `{"style":"35mm"}`. Styles are
   * `35mm` (negative strip with edge print), `film` (120 frame), `white`
   * (plain mat) and `keyline` (mat with a hairline). Optional fields: width,
   * line, color and line_color (`#rrggbb`).
   */
  border?: string;
  /**
   * Export options as JSON: `{"quality":92,"bit_depth":16}`. The file format
   * follows `output`'s extension (.png/.jpg/.tif). `quality` applies to
   * JPEG only; `bit_depth` (8 or 16) applies to PNG and TIFF.
   */
  exportOptions?: string;
  /** Omit for the whole frame. */
  crop?: CropRect;
}

export interface TestPatternRequest {
  dataDir: string;
  output: string;
  film: string;
  paper?: string;
  width?: number;
  height?: number;
}

export interface RenderResult {
  output: string;
  elapsedMs: number;
  /** Output width in px. */
  width: number;
  /** Output height in px. */
  height: number;
}

export interface LutRequest {
  dataDir: string;
  film: string;
  paper?: string;
  params?: string;
  /** Grid edge length. 33 is the usual choice, 65 for smooth gradients. */
  size?: number;
  /** Destination .cube path. */
  output: string;
}

export interface FilmEntry {
  /** Profile id, e.g. `kodak_portra_400`. Pass this to the render calls. */
  name: string;
  /** Printed name, e.g. `Kodak Portra 400`; taken from the profile itself. */
  label: string;
  /** `negative` or `positive`. */
  type: string;
  /** `still` or `cine`. */
  use: string;
  /** `color` or `bw`. */
  channel: string;
  /** Paper this stock is normally printed on, empty when it has none. */
  target_print: string;
}

export interface PaperEntry {
  name: string;
  label: string;
}

export interface ProfileCatalog {
  films: FilmEntry[];
  papers: PaperEntry[];
}

/** Engine build string, e.g. "negs-0.13.0-ohos-cpu". */
export const version: () => string;

/** Catalogue as a JSON string; parse it into `ProfileCatalog`. */
export const getCatalog: (dataDir: string) => string;

export interface SolveRequest {
  dataDir: string;
  input: string;
  film: string;
  /** Omit for a reversal film, which prints onto its own curves. */
  paper?: string;
  params?: string;
  crop?: CropRect;
}

/** Result of 配光: the filter pack that makes the print neutral. */
export interface SolveResult {
  /** Yellow filtration, 0 to 180 CC. */
  y: number;
  /** Magenta filtration, 0 to 180 CC. */
  m: number;
  /** Cyan filtration; the solve leaves it alone and reports 0. */
  c: number;
  /** Residual cast in log units; under 0.004 is neutral to the eye. */
  cast: number[];
  paper: string;
  iterations: number;
}
export const renderFile: (options: RenderRequest) => Promise<RenderResult>;
export const solveFilters: (options: SolveRequest) => Promise<string>;

export const renderTestPattern: (options: TestPatternRequest) => Promise<RenderResult>;

/** Writes a .cube 3D LUT and returns the number of bytes written. */
export const exportLut: (options: LutRequest) => number;

/** A preset translated into this engine's terms. */
export interface ImportedPreset {
  film: string;
  paper: string;
  /** RuntimeParams JSON, already merged over the parameters passed in. */
  params: string;
}

/**
 * Import a Python-spektrafilm GUI preset (community `.json`).
 * `currentJson` is merged underneath, so device-owned settings survive.
 * Returns JSON for `ImportedPreset`; parse it.
 */
export const importPreset: (text: string, dataDir: string, currentJson?: string) => string;

/** Deep-merge two RuntimeParams JSON objects, `over` winning. Returns JSON. */
export const mergeParams: (baseJson: string, overJson: string) => string;

/** Writes a shareable preset file and returns the number of bytes written. */
export const exportPreset: (options: {
  dataDir: string;
  film: string;
  paper: string;
  params?: string;
  output: string;
}) => number;
