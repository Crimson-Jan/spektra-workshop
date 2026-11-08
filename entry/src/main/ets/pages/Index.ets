/**
 * Spektrafilm — HarmonyOS shell.
 *
 * Laid out like a desktop darkroom app rather than a phone utility: film list on
 * the left, a large canvas in the middle with a toolbar, and grouped parameters
 * on the right. Every control here is wired to a real engine parameter — nothing
 * is decorative.
 *
 * The page never touches an ability context. EntryAbility extracts the bundled
 * spectral data with its own context and publishes plain paths through
 * AppStorage; see the note there for why a page cannot do it itself on API 26.
 */

import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { image as imageKit } from '@kit.ImageKit';
import native, { CropRect, FilmEntry, ImportedPreset, PaperEntry, ProfileCatalog, RenderRequest, RenderResult, SolveRequest, SolveResult } from 'libspektrafilmoh.so';



/** Preview long side in px. Big enough to judge the look, cheap enough to be
 *  interactive on a tablet CPU. Export bypasses this entirely. */
const PREVIEW_LONG_SIDE: number = 1280;

/** Above this the full-resolution export may hit the memory ceiling on a
 *  phone-class device. Not a hard stop — just an honest warning. */
const BIG_FRAME_PX: number = 20000000;

/** Export targets. The engine picks the encoder from the output extension. */
interface ExportFormat {
  label: string;
  ext: string;
}

const EXPORT_FORMATS: ExportFormat[] = [
  { label: 'PNG', ext: '.png' },
  { label: 'JPEG', ext: '.jpg' },
  { label: 'TIFF', ext: '.tif' }
];

/** Longest side choices for export, in px. 0 keeps the frame's own size. */
const EXPORT_SIDES: number[] = [0, 2048, 3000, 4096];

/** Undo depth. Snapshots are a few hundred bytes each. */
const HISTORY_LIMIT: number = 50;

/** Canvas magnification limit. Beyond 8x the preview is just interpolated
 *  pixels, and the 1280px proxy has nothing left to show. */
const MAX_ZOOM: number = 8;


/**
 * Film borders. `style` is the engine's BorderStyle string; the engine picks
 * its own default width and colour per style, so nothing is passed but the name.
 * The 35mm strip needs the per-stock edge textures bundled under data/borders.
 */
interface BorderChoice {
  label: string;
  style: string;
}

const BORDERS: BorderChoice[] = [
  { label: '关', style: '' },
  { label: '片边', style: '35mm' },
  { label: '白边', style: 'white' },
  { label: '画线', style: 'keyline' }
];
/**
 * Frame formats. One tap sets both the crop and the gate the strip is built
 * around: the engine lays the film out in millimetres, so the frame has to be
 * named — 3:2 is both 135 and 6×9, and no aspect can tell them apart.
 */
interface FrameFormat {
  label: string;
  ratio: number;
  style: string;
  /** The gate name the engine builds, e.g. "6x6"; empty means "fit the crop". */
  frame: string;
}

/**
 * Everything that decides how a photograph looks. Snapshotted per photo so the
 * bottom strip can hold several images, each with its own grade, and so a
 * future undo stack has one object to push.
 */
interface LookState {
  ev: number;
  scanFilm: boolean;
  grain: boolean;
  halation: boolean;
  glare: boolean;
  lensCorrection: boolean;
  temperature: number;
  tint: number;
  printEv: number;
  postContrast: number;
  postSaturation: number;
  postWhites: number;
  postBlacks: number;
  cropRatio: number;
  formatIndex: number;
  borderIndex: number;
  edgeFog: number;
  edgeLeak: number;
  /** 配光 is per photograph: a solve made for one film must not follow
   *  the next one, which is why it lives in the snapshot. */
  filtersSolved: boolean;
  filterY: number;
  filterM: number;
  filmIndex: number;
  paperIndex: number;
  presetJson: string;
}

/** One imported photograph in the bottom strip. */
interface PhotoItem {
  id: string;
  path: string;
  name: string;
  /** ile:// URI of the 180 px proxy, empty until it is rendered. */
  thumb: string;
  look: LookState;
}
const FORMATS: FrameFormat[] = [
  { label: '原图', ratio: 0, style: '', frame: '' },
  // 135 full frame: 36 × 24 mm, landscape.
  { label: '135', ratio: 3 / 2, style: '35mm', frame: 'full' },
  // Half frame is the same 135 turned upright and halved: 18 × 24 mm. Portrait
  // here is what keeps the strip horizontal, so the perforations land above and
  // below the picture instead of beside it.
  { label: '半格', ratio: 3 / 4, style: '35mm', frame: 'half' },
  // XPan is the same stock through a 65 × 24 mm gate.
  { label: 'XPan', ratio: 65 / 24, style: '35mm', frame: 'xpan' },
  // 120 roll film: 61 mm wide, 56 mm of gate, no perforations. The ratios are
  // the gates', not rounded names: 6×7 is 69.5 by 56.
  { label: '645', ratio: 56 / 41.5, style: '35mm', frame: '645' },
  { label: '6×6', ratio: 1, style: '35mm', frame: '6x6' },
  { label: '6×7', ratio: 69.5 / 56, style: '35mm', frame: '6x7' },
  { label: '6×8', ratio: 76 / 56, style: '35mm', frame: '6x8' },
  { label: '6×9', ratio: 84 / 56, style: '35mm', frame: '6x9' },
  { label: '6×12', ratio: 2, style: '35mm', frame: '6x12' },
  { label: '6×17', ratio: 3, style: '35mm', frame: '6x17' }
];

const INK = '#F3EFE7';
const MUTED = '#8C8578';
const DIM = '#6E675B';
const PANEL = '#12100D';
const PANEL_2 = '#0E0C0A';
const ACCENT = '#C9A227';
const LINE = '#241F19';

/**
 * Profile ids are file names (`kodak_portra_400`); the lists show stock names.
 * A plain capitaliser mangles the parts that carry meaning (XTRA, C200, 400H),
 * so those go through a table first.
 */
/** One line of the film list: either a group caption or a stock. */
interface FilmRow {
  label: string;
  /** Index into `films`, or -1 for a caption. */
  filmIndex: number;
  isCaption: boolean;
}

/** Reversal stocks, which the list separates from the negatives. */
function isSlide(film: FilmEntry): boolean {
  return film.type === 'positive';
}

function buildFilmRows(films: FilmEntry[]): FilmRow[] {
  const slides: FilmRow[] = [];
  const negatives: FilmRow[] = [];
  for (let i = 0; i < films.length; i++) {
    const row: FilmRow = { label: '', filmIndex: i, isCaption: false };
    if (isSlide(films[i])) {
      slides.push(row);
    } else {
      negatives.push(row);
    }
  }
  const rows: FilmRow[] = [];
  if (slides.length > 0) {
    rows.push({ label: '正片', filmIndex: -1, isCaption: true });
    for (const row of slides) {
      rows.push(row);
    }
  }
  if (negatives.length > 0) {
    rows.push({ label: '负片', filmIndex: -1, isCaption: true });
    for (const row of negatives) {
      rows.push(row);
    }
  }
  return rows;
}
function badgeKind(film: FilmEntry): string {
  // Black and white wins over cine: Double-X and Tri-X Reversal are both, and
  // the B&W card says more about the look than the film's distribution does.
  if (film.channel === 'bw') {
    return 'bw';
  }
  if (film.use === 'cine') {
    return 'cine';
  }
  if (film.type === 'positive') {
    if (film.name.indexOf('provia') >= 0) {
      return 'provia';
    }
    if (film.name.indexOf('velvia') >= 0) {
      return 'velvia';
    }
    if (film.name.indexOf('ektachrome') >= 0) {
      return 'ektachrome';
    }
  }
  if (film.name.indexOf('fujifilm') === 0) {
    return 'fuji';
  }
  return 'kodak';
}
@Entry
@Component
struct Index {
  @State private engineVersion: string = '';
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private status: string = '正在解压光谱数据…';
  @State private films: FilmEntry[] = [];
  /** Films flattened with their 正片 / 负片 captions, for the grouped list. */
  @State private filmRows: FilmRow[] = [];
  @State private papers: PaperEntry[] = [];
  @State private filmIndex: number = 0;
  @State private paperIndex: number = 0;

  // --- look parameters, all real RuntimeParams fields -----------------------
  @State private ev: number = 0;
  @State private scanFilm: boolean = false;
  @State private grain: boolean = true;
  @State private halation: boolean = true;
  @State private glare: boolean = true;
  @State private lensCorrection: boolean = false;
  @State private temperature: number = 5500;
  /** RAW tint: 1.0 is neutral, below leans green, above magenta. */
  @State private tint: number = 1.0;
  /**
   * Print exposure in stops, applied as a multiplier. The engine's
   * `print_exposure` is absolute (1.0 = as metered, 0.0 = an unexposed white
   * sheet), so the UI speaks EV and converts.
   */
  @State private printEv: number = 0;
  /** Post params. Named `post*` because `contrast` and `saturation` collide with
   *  built-in ArkUI component attributes. */
  @State private postContrast: number = 0;
  @State private postSaturation: number = 0;
  @State private postWhites: number = 0;
  @State private postBlacks: number = 0;

  /** Crop aspect picked from the 片边 format row; 0 keeps the whole frame. */
  @State private cropRatio: number = 0;
  @State private formatIndex: number = 0;
  @State private borderIndex: number = 0;
  // --- resizable rails --------------------------------------------------
  /** Rail widths in vp. Dragging commits on release; the drag itself only
   *  moves a guide line, so the lists inside never re-measure mid-gesture. */
  @State private leftW: number = 220;
  @State private rightW: number = 300;
  @State private windowW: number = 0;
  private dragFrom: number = 0;
  private dragSide: number = 0;
  /** 配光: the solved enlarger filter pack, in CC. */
  @State private filterY: number = 55;
  @State private filterM: number = 65;
  @State private filtersSolved: boolean = false;
  /** Edge fog and spool light leak on the rebate, 0 to 1. */
  @State private edgeFog: number = 0;
  @State private edgeLeak: number = 0;

  // --- view state -----------------------------------------------------------
  @State private showOriginal: boolean = false;
  @State private openCamera: boolean = true;
  @State private openPrint: boolean = true;
  @State private openFrame: boolean = true;
  @State private openBorder: boolean = false;
  @State private openPost: boolean = true;
  @State private srcAspect: number = 0;
  @State private presetJson: string = '';
  @State private sourceUri: string = '';
  // --- bottom strip ---
  @State private photos: PhotoItem[] = [];
  @State private activeId: string = '';
  @State private stripOpen: boolean = true;

  // --- export options ---
  @State private exportOpen: boolean = false;
  @State private exportFormat: number = 0;
  @State private exportQuality: number = 92;
  /** 0 = 8 bit, 1 = 16 bit. PNG and TIFF only; JPEG is always 8. */
  @State private exportBitDepth: number = 0;
  @State private exportSide: number = 0;
  @State private exportBorder: boolean = true;

  // --- history ---
  /** Snapshots of LookState. Snapshot rather than inverse commands: a film
   *  change can drag the paper along with it, and replaying that backwards is
   *  where command stacks rot. */
  @State private undoStack: LookState[] = [];
  @State private redoStack: LookState[] = [];
  /**
   * The look as it was before the latest change. Snapshots must record the
   * *previous* state: pushing the current one makes the first undo a no-op,
   * because popping it restores exactly what is already on screen.
   */
  private lastLook: LookState | null = null;
  private commitTimer: number = -1;
  /** Set while a snapshot is being applied, so restoring one does not record it. */
  private restoringHistory: boolean = false;
  @State private previewUri: string = '';
  /** Waveform overlay: on/off, and the bins it draws from. */
  @State private showWaveform: boolean = false;
  /** Crop rectangle in fractions of the frame, as the engine takes it. */
  @State private cropMode: boolean = false;
  private aboutDialog: CustomDialogController = new CustomDialogController({
    builder: AboutDialog({}),
    alignment: DialogAlignment.Center,
    autoCancel: true,
    customStyle: true
  });
  // --- 片边构图: see where the gate will crop before committing to it ------
  @State private composeMode: boolean = false;
  /** Full, uncropped preview shown while composing. */
  @State private composeUri: string = '';
  private composePath: string = '';
  @State private cropX: number = 0;
  @State private cropY: number = 0;
  @State private cropW: number = 1;
  @State private cropH: number = 1;
  @State private cropApplied: boolean = false;
  private dragCrop: number[] = [0, 0, 1, 1];
  @State private wave: number[] = [];
  @State private waveMax: number = 1;
  private waveCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  @State private timing: string = '';
  @State private frameInfo: string = '';
  @State private fileName: string = '';

  // --- canvas view ---
  /** 1 = fit. Pinch changes it, the toolbar percentage resets it. */
  @State private zoom: number = 1;
  @State private panX: number = 0;
  @State private panY: number = 0;
  private zoomStart: number = 1;
  private panStartX: number = 0;
  private panStartY: number = 0;
  /** Canvas size, needed to keep a pan from dragging the picture off screen. */
  private canvasW: number = 0;
  private canvasH: number = 0;

  /** System bar heights in raw pixels, published by EntryAbility. */
  @StorageProp('safeTopPx') private safeTopPx: number = 0;
  @StorageProp('safeBottomPx') private safeBottomPx: number = 0;

  /** Paths published by EntryAbility. */
  @StorageProp('dataDir') private dataDir: string = '';
  @StorageProp('filesDir') private filesDir: string = '';
  @StorageProp('cacheDir') private cacheDir: string = '';
  @StorageProp('dataError') private dataError: string = '';

  private picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
  private phAccess: photoAccessHelper.PhotoAccessHelper | null = null;
  private debounce: number = -1;
  private previewQueued: boolean = false;
  private lastPreviewPath: string = '';

  aboutToAppear(): void {
    this.boot();
  }

  aboutToDisappear(): void {
    if (this.debounce >= 0) {
      clearTimeout(this.debounce);
    }
    if (this.commitTimer >= 0) {
      clearTimeout(this.commitTimer);
    }
  }

  private async boot(): Promise<void> {
    try {
      this.engineVersion = native.version();
      if (this.dataError.length > 0) {
        throw new Error(`数据解压失败：${this.dataError}`);
      }
      if (this.dataDir.length === 0) {
        throw new Error('数据目录未就绪');
      }
      const catalog: ProfileCatalog = JSON.parse(native.getCatalog(this.dataDir)) as ProfileCatalog;
      this.films = catalog.films;
      this.filmRows = buildFilmRows(this.films);
      // The list is alphabetical, so index 0 is a slide. A negative is the
      // sane default: most photographs are taken on one, and a slide curve
      // turns an ordinary frame blue.
      const preferred = this.films.findIndex((f: FilmEntry) => f.name === 'kodak_portra_400');
      const firstNegative = this.films.findIndex((f: FilmEntry) => f.type === 'negative');
      this.filmIndex = preferred >= 0 ? preferred : (firstNegative >= 0 ? firstNegative : 0);
      this.syncPaperToFilm();
      this.papers = catalog.papers;
      this.selectDefaultFilm();
      this.ready = true;
      // Baseline for the first undo: without it the very first change has no
      // "before" state to return to.
      this.lastLook = this.captureLook();
      this.status = `${this.films.length} 款胶片 · ${this.papers.length} 款相纸`;
    } catch (e) {
      const err = e as BusinessError;
      this.status = `初始化失败：${err.message}`;
      console.error(`spektrafilm: boot failed: ${err.message}`);
    }
  }

  // --- selection helpers ----------------------------------------------------

  private selectDefaultFilm(): void {
    const preferred = this.films.findIndex((f: FilmEntry) => f.name === 'kodak_portra_400');
    this.filmIndex = preferred >= 0 ? preferred : 0;
    this.syncPaperToFilm();
  }

  private syncPaperToFilm(): void {
    if (this.films.length === 0) {
      return;
    }
    // A reversal film is viewed, not printed: it has no target paper, and
    // printing it would put a second emulsion between the picture and the
    // scan. -1 is the no-paper row at the top of the list.
    // A solve belongs to one film and one paper; anything that changes the
    // pair has to clear it, or the previous film keeps applying.
    this.filtersSolved = false;
    if (this.films[this.filmIndex].type === 'positive') {
      this.paperIndex = -1;
      // A slide is scanned directly: the engine's slide path needs this,
      // and printing it onto paper would be physically wrong.
      this.scanFilm = true;
      return;
    }
    const target = this.films[this.filmIndex].target_print;
    const idx = this.papers.findIndex((p: PaperEntry) => p.name === target);
    this.paperIndex = idx >= 0 ? idx : 0;
    this.scanFilm = false;
  }

  private currentFilm(): string {
    return this.films.length > 0 ? this.films[this.filmIndex].name : '';
  }

  private currentPaper(): string {
    if (this.paperIndex < 0 || this.papers.length === 0) {
      return '';
    }
    return this.papers[this.paperIndex].name;
  }

  private selectFilmByName(name: string): void {
    const idx = this.films.findIndex((f: FilmEntry) => f.name === name);
    if (idx >= 0) {
      this.filmIndex = idx;
    }
  }

  private selectPaperByName(name: string): void {
    const idx = this.papers.findIndex((p: PaperEntry) => p.name === name);
    if (idx >= 0) {
      this.paperIndex = idx;
    }
  }

  // --- parameters -----------------------------------------------------------

  /**
   * RuntimeParams override JSON for the live controls.
   *
   * `photo_long_side_px` is what makes the preview usable: the engine resizes
   * the source *before* the film stage, so the preview shows the same grain and
   * halation the full-size export will have, at a fraction of the cost.
   */
  private buildParams(longSide: number, includeFilters: boolean = true): string {
    const camera = `"camera":{"exposure_compensation_ev":${this.ev.toFixed(2)},"auto_exposure":true}`;
    const render =
      `"film_render":{"grain":{"active":${this.grain}},` +
      `"halation":{"active":${this.halation}},` +
      `"glare":{"active":${this.glare}}}`;
    // 2^stops: 1.0 is "as metered", which is what the engine's default means.
    const factor = Math.pow(2, this.printEv).toFixed(4);
    // Only print_exposure is sent. The enlarger's other knobs were measured on
    // the device and are not usable in this engine build: y/m_filter_shift are
    // neutralised by the print's auto exposure, lens_blur is a no-op, and
    // preflash_exposure only crushes highlights instead of lifting shadows.
    // 配光 sends the solved filter pack; until it runs, the engine keeps its
    // own database of neutral filters.
    let enlarger = `"enlarger":{"print_exposure":${factor}`;
    if (includeFilters && this.filtersSolved) {
      enlarger += `,"y_filter_neutral":${this.filterY.toFixed(1)},"m_filter_neutral":${this.filterM.toFixed(1)}`;
    }
    enlarger += `}`;
    const post =
      `"post":{"contrast":${this.postContrast.toFixed(3)},"saturation":${this.postSaturation.toFixed(3)},` +
      `"whites":${this.postWhites.toFixed(3)},"blacks":${this.postBlacks.toFixed(3)}}`;

    let io = `"scan_film":${this.scanFilm}`;
    io += `,"lens_correction":{"enabled":${this.lensCorrection}}`;
    // Only RAW files carry white balance; on JPEG/PNG the engine ignores it.
    io += `,"raw_white_balance":{"mode":"custom","temperature":${this.temperature.toFixed(0)},"tint":${this.tint.toFixed(2)}}`;
    if (longSide > 0) {
      io += `,"photo_long_side_px":${longSide}`;
    }

    // The solve owns the filters, so the database must not overwrite them.
    const settings = (includeFilters && this.filtersSolved)
      ? `,"settings":{"neutral_print_filters_from_database":false}`
      : '';
    const overrides = `{${camera},${render},${enlarger},${post}${settings},"io":{${io}}}`;

    if (this.presetJson.length === 0) {
      return overrides;
    }
    // Preset first, live controls on top: the preset's grain curves, filters and
    // halation tuning survive while the sliders still do what they say.
    return native.mergeParams(this.presetJson, overrides);
  }

  /**
   * Centred crop for the chosen aspect, as fractions of the frame.
   *
   * The presets are ratios but the engine wants a rectangle, so this needs the
   * source aspect — learned from the first uncropped preview, which already
   * reports the rendered dimensions. Until then the frame is left alone.
   */
  /** The part of the canvas the photograph occupies, in vp. */
  /** The gate's frame for the chosen 画幅, centred and as large as fits. */

  /**
   * Renders the whole frame, uncropped and without a border, so the gate can
   * be placed against everything the camera saw rather than against the slice
   * that survived the last crop.
   */
  /** The gate's rectangle on screen: centred, 80% of the canvas, format's shape. */
  private gateRect(): number[] {
    const ratio = FORMATS[this.formatIndex].ratio;
    if (this.canvasW <= 0 || this.canvasH <= 0) {
      return [0, 0, this.canvasW, this.canvasH];
    }
    const r = ratio > 0 ? ratio : (this.srcAspect > 0 ? this.srcAspect : 1.5);
    let w = this.canvasW * 0.8;
    let h = w / r;
    if (h > this.canvasH * 0.8) {
      h = this.canvasH * 0.8;
      w = h * r;
    }
    return [(this.canvasW - w) / 2, (this.canvasH - h) / 2, w, h];
  }

  /**
   * The crop that the current transform leaves inside the gate, as fractions
   * of the source. The image is drawn Contain, then scaled about the canvas
   * centre and translated, so its on-screen rectangle is known exactly.
   */
  private gateToCrop(): number[] {
    const box = this.imageBox();
    const gate = this.gateRect();
    const w = box[2] * this.zoom;
    const h = box[3] * this.zoom;
    const left = box[0] + (box[2] - w) / 2 + this.panX;
    const top = box[1] + (box[3] - h) / 2 + this.panY;
    const x = (gate[0] - left) / w;
    const y = (gate[1] - top) / h;
    const cw = gate[2] / w;
    const ch = gate[3] / h;
    return [
      Math.max(0, Math.min(1 - cw, x)),
      Math.max(0, Math.min(1 - ch, y)),
      Math.max(0.02, Math.min(1, cw)),
      Math.max(0.02, Math.min(1, ch))
    ];
  }

  private async openCompose(): Promise<void> {
    if (!this.ready || this.busy || this.sourceUri.length === 0) {
      return;
    }
    this.busy = true;
    this.status = '准备构图预览…';
    try {
      const output = `${this.cacheDir}/compose_${Date.now()}.png`;
      const request: RenderRequest = {
        dataDir: this.dataDir,
        input: this.sourceUri,
        output: output,
        film: this.currentFilm(),
        paper: this.currentPaper(),
        params: this.buildParams(1280)
      };
      const result: RenderResult = await native.renderFile(request);
      if (this.composePath.length > 0) {
        this.removeQuietly(this.composePath);
      }
      this.composePath = result.output;
      this.composeUri = `file://${result.output}`;
      this.cropApplied = false;
      this.composeMode = true;
      // Park the picture at the zoom that just fills the gate: the
      // largest crop the format allows, which is where a user starts.
      const box = this.imageBox();
      const gate = this.gateRect();
      this.zoom = Math.max(1, Math.max(gate[2] / Math.max(1, box[2]), gate[3] / Math.max(1, box[3])));
      this.panX = 0;
      this.panY = 0;
      this.status = '拖动或缩放，决定片边保留哪一块';
    } catch (e) {
      this.status = `构图预览失败：${(e as BusinessError).message}`;
    } finally {
      this.busy = false;
    }
  }

  private closeCompose(): void {
    this.composeMode = false;
    if (this.composePath.length > 0) {
      this.removeQuietly(this.composePath);
      this.composePath = '';
    }
    this.composeUri = '';
  }

  /** Commits the gate as the crop the engine will cut with. */
  private applyGate(): void {
    const rect = this.gateToCrop();
    this.cropX = rect[0];
    this.cropY = rect[1];
    this.cropW = rect[2];
    this.cropH = rect[3];
    this.cropApplied = true;
    this.closeCompose();
    this.schedulePreview();
  }

  /**
   * Resizes the gate from one corner. The opposite corner stays put, and the
   * size comes off the base frame so the format's ratio never drifts.
   */


  private imageBox(): number[] {
    if (this.canvasW <= 0 || this.canvasH <= 0 || this.srcAspect <= 0) {
      return [0, 0, this.canvasW, this.canvasH];
    }
    const width = Math.min(this.canvasW, this.canvasH * this.srcAspect);
    const height = width / this.srcAspect;
    return [(this.canvasW - width) / 2, (this.canvasH - height) / 2, width, height];
  }

  /** Opens crop mode on the rectangle already in effect. */
  private beginCrop(): void {
    const existing = this.cropApplied;
    this.cropMode = true;
    if (!existing) {
      const rect = this.currentCrop();
      if (rect !== null) {
        this.cropX = rect.x;
        this.cropY = rect.y;
        this.cropW = rect.width;
        this.cropH = rect.height;
      } else {
        this.cropX = 0;
        this.cropY = 0;
        this.cropW = 1;
        this.cropH = 1;
      }
    }
  }

  /** Keeps the chosen画幅 shape while a handle is dragged. */
  private lockCropAspect(): void {
    if (this.cropRatio <= 0 || this.srcAspect <= 0) {
      return;
    }
    const box = this.imageBox();
    const imageAspect = box[2] / Math.max(1, box[3]);
    // height in fractions for the wanted display ratio
    const wanted = this.cropW * imageAspect / this.cropRatio / Math.max(0.0001, this.srcAspect);
    this.cropH = Math.max(0.08, Math.min(1 - this.cropY, wanted));
    this.cropW = Math.min(this.cropW, 1 - this.cropX);
  }

  private clampCrop(): void {
    this.cropW = Math.max(0.08, Math.min(1, this.cropW));
    this.cropH = Math.max(0.08, Math.min(1, this.cropH));
    this.cropX = Math.max(0, Math.min(1 - this.cropW, this.cropX));
    this.cropY = Math.max(0, Math.min(1 - this.cropH, this.cropY));
  }

  private resetCrop(): void {
    this.cropX = 0;
    this.cropY = 0;
    this.cropW = 1;
    this.cropH = 1;
    this.cropApplied = false;
  }

  private currentCrop(): CropRect | null {
    // A rectangle the user set by hand replaces the centred one that the
    // 画幅 chips imply.
    if (this.cropApplied) {
      return {
        x: this.cropX,
        y: this.cropY,
        width: this.cropW,
        height: this.cropH,
        angle: 0
      };
    }
    const ratio = this.cropRatio;
    if (ratio <= 0 || this.srcAspect <= 0) {
      return null;
    }
    let width = 1;
    let height = 1;
    if (ratio >= this.srcAspect) {
      height = this.srcAspect / ratio;
    } else {
      width = ratio / this.srcAspect;
    }
    return {
      x: (1 - width) / 2,
      y: (1 - height) / 2,
      width: width,
      height: height,
      angle: 0
    };
  }

  // --- rendering ------------------------------------------------------------

  /** Border request JSON, or an empty string when no border is selected. */
  /** Index of a border style by its engine name, or 0 (关) if unknown. */
  private borderIndexOf(style: string): number {
    const found = BORDERS.findIndex((b: BorderChoice) => b.style === style);
    return found >= 0 ? found : 0;
  }

  private buildBorder(): string {
    const style = BORDERS[this.borderIndex].style;
    if (style.length === 0) {
      return '';
    }
    if (style !== '35mm') {
      return `{"style":"${style}"}`;
    }
    // The strip is laid out in millimetres around a named gate, so the frame
    // travels with the request. Without it the engine falls back to the crop's
    // aspect — and 3:2 is both 135 and 6×9.
    const frame = FORMATS[this.formatIndex].frame;
    const fog = this.edgeFog.toFixed(2);
    const leak = this.edgeLeak.toFixed(2);
    if (frame.length === 0) {
      return `{"style":"35mm","fog":${fog},"leak":${leak}}`;
    }
    return `{"style":"35mm","format":"${frame}","fog":${fog},"leak":${leak}}`;
  }

  private schedulePreview(): void {
    if (this.debounce >= 0) {
      clearTimeout(this.debounce);
    }
    // Every look change funnels through here, so this is the one place that
    // has to arm the history commit.
    this.scheduleCommit();
    this.debounce = setTimeout(() => {
      this.debounce = -1;
      if (this.sourceUri.length > 0) {
        this.renderPreview();
      }
    }, 450);
  }

  /** Deletes a file if it exists. Cleanup must never break a render. */
  private removeQuietly(path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      console.warn(`spektrafilm: could not remove ${path}: ${(e as BusinessError).message}`);
    }
  }

  /**
   * Shows a rendered frame. The path is always fresh (timestamped), so no cache
   * busting is needed — and a `?t=` suffix would break file resolution.
   */
  private showPreview(path: string): void {
    if (this.lastPreviewPath.length > 0 && this.lastPreviewPath !== path) {
      this.removeQuietly(this.lastPreviewPath);
    }
    this.lastPreviewPath = path;
    this.previewUri = `file://${path}`;
    // The overlay reads the same file the canvas shows, so it always
    // describes the frame on screen.
    if (this.showWaveform) {
      this.measureWaveform(path);
    }
    this.showOriginal = false;
  }

  /**
   * Builds the waveform from the rendered preview: a histogram per channel,
   * 256 levels wide, taken from the same PNG the canvas is showing.
   *
   * Reading it here rather than from the engine keeps one source of truth:
   * whatever the canvas displays is what the overlay measures, grain and all.
   */
  private async measureWaveform(path: string): Promise<void> {
    try {
      const source: imageKit.ImageSource = imageKit.createImageSource(path);
      // 192 px is plenty for a 208 vp overlay, and keeps this off the render's
      // critical path.
      const pixelMap: imageKit.PixelMap = await source.createPixelMap({
        desiredSize: { width: 192, height: 192 }
      });
      const info: imageKit.ImageInfo = await pixelMap.getImageInfo();
      const size = info.size;
      const buffer: ArrayBuffer = new ArrayBuffer(pixelMap.getPixelBytesNumber());
      await pixelMap.readPixelsToBuffer(buffer);
      const bytes = new Uint8Array(buffer);
      const bins: number[] = new Array<number>(768).fill(0);
      const rowBytes = size.width * 4;
      for (let y = 0; y < size.height; y++) {
        for (let x = 0; x < size.width; x++) {
          const i = y * rowBytes + x * 4;
          bins[bytes[i]] += 1;
          bins[256 + bytes[i + 1]] += 1;
          bins[512 + bytes[i + 2]] += 1;
        }
      }
      let peak = 1;
      for (let i = 0; i < bins.length; i++) {
        if (bins[i] > peak) {
          peak = bins[i];
        }
      }
      this.wave = bins;
      this.waveMax = peak;
      pixelMap.release();
      source.release();
      this.drawWaveform();
    } catch (e) {
      this.status = `波形读取失败：${(e as BusinessError).message}`;
    }
  }

  /** Draws the three channel curves into the overlay canvas. */
  /** Draws the three channels as curves: a histogram of the frame on screen. */
  private drawWaveform(): void {
    const w = 208;
    const h = 96;
    this.waveCtx.clearRect(0, 0, w, h);
    if (this.wave.length < 768) {
      return;
    }
    // Faint grid at quarter stops, so a flat stretch still reads as "nothing
    // here" rather than as a blank overlay.
    this.waveCtx.strokeStyle = '#221F19';
    this.waveCtx.lineWidth = 1;
    for (let i = 1; i < 4; i++) {
      const x = w * i / 4;
      this.waveCtx.beginPath();
      this.waveCtx.moveTo(x, 0);
      this.waveCtx.lineTo(x, h);
      this.waveCtx.stroke();
    }
    const channels: string[] = ['#C86A5A', '#6FA86A', '#5A86C8'];
    const peak = Math.log(1 + this.waveMax);
    this.waveCtx.lineWidth = 1.2;
    this.waveCtx.globalAlpha = 0.85;
    for (let c = 0; c < 3; c++) {
      this.waveCtx.strokeStyle = channels[c];
      this.waveCtx.beginPath();
      let started = false;
      for (let level = 0; level < 256; level++) {
        const count = this.wave[c * 256 + level];
        // Log scaling: a linear histogram is one spike and nothing else.
        const height = Math.log(1 + count) / peak * (h - 4);
        const x = level / 255 * w;
        const y = h - height;
        if (!started) {
          this.waveCtx.moveTo(x, y);
          started = true;
        } else {
          this.waveCtx.lineTo(x, y);
        }
      }
      this.waveCtx.stroke();
    }
    this.waveCtx.globalAlpha = 1;
  }

  private async renderPreview(): Promise<void> {
    if (!this.ready) {
      return;
    }
    if (this.busy) {
      this.previewQueued = true;
      return;
    }
    if (this.sourceUri.length === 0) {
      // No photograph yet: the canvas already shows the empty state.
      this.status = '';
      return;
    }
    this.busy = true;
    this.status = '显影中…';
    try {
      const output = `${this.cacheDir}/preview_${Date.now()}.png`;
      const crop: CropRect | null = this.currentCrop();
      const request: RenderRequest = {
        dataDir: this.dataDir,
        input: this.sourceUri,
        output: output,
        film: this.currentFilm(),
        paper: this.currentPaper(),
        params: this.buildParams(PREVIEW_LONG_SIDE)
      };
      if (crop !== null) {
        request.crop = crop;
      }
      const border = this.buildBorder();
      if (border.length > 0) {
        request.border = border;
      }
      const result: RenderResult = await native.renderFile(request);
      if (crop === null && result.height > 0) {
        this.srcAspect = result.width / result.height;
      }
      this.showPreview(result.output);
      this.timing = `${result.elapsedMs} ms`;
      this.frameInfo = `${result.width}×${result.height}`;
      this.status = '预览已更新';
    } catch (e) {
      this.status = `显影失败：${(e as BusinessError).message}`;
    } finally {
      this.busy = false;
      if (this.previewQueued) {
        this.previewQueued = false;
        this.renderPreview();
      }
    }
  }


  /** Keeps the picture inside the canvas: at zoom z the image is z times wider
   *  than its box, so it can travel (z-1)/2 of the box length in each direction. */
  private clampPan(value: number, extent: number): number {
    if (extent <= 0) {
      return 0;
    }
    const limit = Math.max(0, (this.zoom - 1) * extent / 2);
    return Math.min(limit, Math.max(-limit, value));
  }

  private resetView(): void {
    this.zoom = 1;
    this.panX = 0;
    this.panY = 0;
  }

  /** Steps the magnification. Buttons exist because pinch is undiscoverable and
   *  awkward with two hands on a 12" tablet; they are also the only way to drive
   *  this from an automation harness. */
  private zoomBy(factor: number): void {
    const next = Math.min(MAX_ZOOM, Math.max(1, this.zoom * factor));
    this.zoom = next;
    if (next <= 1.01) {
      this.panX = 0;
      this.panY = 0;
      return;
    }
    this.panX = this.clampPan(this.panX, this.canvasW);
    this.panY = this.clampPan(this.panY, this.canvasH);
  }

  /**
   * Copies whatever the user picked into the cache under a fresh name and
   * renders it.
   *
   * The engine dispatches on the file extension, so the source's own extension
   * has to survive the copy — a DNG renamed to `.jpg` would decode as JPEG and
   * fail.
   */
  // --- photo session --------------------------------------------------------

  private captureLook(): LookState {
    return {
      ev: this.ev,
      scanFilm: this.scanFilm,
      grain: this.grain,
      halation: this.halation,
      glare: this.glare,
      lensCorrection: this.lensCorrection,
      temperature: this.temperature,
      tint: this.tint,
      printEv: this.printEv,
      postContrast: this.postContrast,
      postSaturation: this.postSaturation,
      postWhites: this.postWhites,
      postBlacks: this.postBlacks,
      cropRatio: this.cropRatio,
      formatIndex: this.formatIndex,
      borderIndex: this.borderIndex,
      edgeFog: this.edgeFog,
      edgeLeak: this.edgeLeak,
      filtersSolved: this.filtersSolved,
      filterY: this.filterY,
      filterM: this.filterM,
      filmIndex: this.filmIndex,
      paperIndex: this.paperIndex,
      presetJson: this.presetJson
    };
  }

  private applyLook(look: LookState): void {
    this.ev = look.ev;
    this.scanFilm = look.scanFilm;
    this.grain = look.grain;
    this.halation = look.halation;
    this.glare = look.glare;
    this.lensCorrection = look.lensCorrection;
    this.temperature = look.temperature;
    this.tint = look.tint;
    this.printEv = look.printEv;
    this.postContrast = look.postContrast;
    this.postSaturation = look.postSaturation;
    this.postWhites = look.postWhites;
    this.postBlacks = look.postBlacks;
    this.cropRatio = look.cropRatio;
    this.formatIndex = look.formatIndex;
    this.borderIndex = look.borderIndex;
    this.edgeFog = look.edgeFog;
    this.edgeLeak = look.edgeLeak;
    this.filtersSolved = look.filtersSolved;
    this.filterY = look.filterY;
    this.filterM = look.filterM;
    this.filmIndex = look.filmIndex;
    this.paperIndex = look.paperIndex;
    this.presetJson = look.presetJson;
  }

  /** Writes the live controls back onto the active strip entry. */
  private saveActiveLook(): void {
    const id = this.activeId;
    if (id.length === 0) {
      return;
    }
    const look = this.captureLook();
    // A new array, because ArkUI only re-renders on a new array reference.
    this.photos = this.photos.map((p: PhotoItem) => {
      if (p.id !== id) {
        return p;
      }
      return { id: p.id, path: p.path, name: p.name, thumb: p.thumb, look: look } as PhotoItem;
    });
  }

  private replacePhoto(updated: PhotoItem): void {
    this.photos = this.photos.map((p: PhotoItem) => p.id === updated.id ? updated : p);
  }

  /**
   * Adds a freshly imported file to the strip and makes it active.
   *
   * The thumbnail is a real engine render at 180 px, not a downscale of the
   * source: the strip has to show the grade, otherwise every thumbnail looks
   * the same and it is useless for choosing between photographs.
   */
  private async addPhoto(path: string, name: string): Promise<void> {
    const id = `p${Date.now()}`;
    // Park the grade of whatever was open before switching, otherwise the
    // previous entry keeps the look it had when it was imported.
    this.saveActiveLook();
    const look = this.captureLook();
    this.activeId = id;
    this.undoStack = [];
    this.redoStack = [];
    this.lastLook = this.captureLook();
    this.photos = this.photos.concat([
      { id: id, path: path, name: name, thumb: '', look: look } as PhotoItem
    ]);
    this.sourceUri = path;
    this.fileName = name;
    this.srcAspect = 0;
    this.resetView();
    this.renderPreview();
    this.makeThumb(id, path);
  }

  private async makeThumb(id: string, path: string): Promise<void> {
    try {
      const output = `${this.cacheDir}/thumb_${id}.png`;
      const result: RenderResult = await native.renderFile({
        dataDir: this.dataDir,
        input: path,
        output: output,
        film: this.currentFilm(),
        paper: this.currentPaper(),
        params: '{"io":{"photo_long_side_px":180}}'
      });
      const uri = `file://${result.output}`;
      this.photos = this.photos.map((p: PhotoItem) => {
        if (p.id !== id) {
          return p;
        }
        return { id: p.id, path: p.path, name: p.name, thumb: uri, look: p.look } as PhotoItem;
      });
    } catch (e) {
      // A missing thumbnail is cosmetic; the entry keeps its placeholder.
      console.warn(`spektrafilm: thumbnail failed: ${(e as BusinessError).message}`);
    }
  }
  private selectPhoto(id: string): void {
    if (id === this.activeId || this.busy) {
      return;
    }
    this.saveActiveLook();
    const target = this.photos.find((p: PhotoItem) => p.id === id);
    if (target === undefined) {
      return;
    }
    this.activeId = id;
    // History is per photograph: the snapshots describe this image's grade, so
    // carrying them across a switch would undo the wrong picture.
    this.undoStack = [];
    this.redoStack = [];
    this.sourceUri = target.path;
    this.fileName = target.name;
    this.srcAspect = 0;
    this.applyLook(target.look);
    // Re-base after the look is in place, otherwise the first edit on the
    // newly opened photo has no "before" state.
    this.lastLook = this.captureLook();
    this.resetView();
    this.renderPreview();
  }
  // --- history --------------------------------------------------------------

  private pushHistory(): void {
    if (this.restoringHistory) {
      return;
    }
    const current = this.captureLook();
    if (this.lastLook === null) {
      this.lastLook = current;
      return;
    }
    const previous = this.lastLook;
    if (JSON.stringify(previous) === JSON.stringify(current)) {
      return;
    }
    // The entry is the state the user is leaving, not the one they arrived at.
    const next = this.undoStack.concat([previous]);
    this.undoStack = next.length > HISTORY_LIMIT ? next.slice(next.length - HISTORY_LIMIT) : next;
    this.lastLook = current;
    // Any fresh edit invalidates the redo branch.
    this.redoStack = [];
  }

  /**
   * Records the look once the user stops moving things.
   *
   * Sliders fire continuously; committing every tick would fill the stack with
   * near-identical states and make a single undo feel like nothing happened.
   */
  private scheduleCommit(): void {
    if (this.commitTimer >= 0) {
      clearTimeout(this.commitTimer);
    }
    this.commitTimer = setTimeout(() => {
      this.commitTimer = -1;
      this.pushHistory();
    }, 700);
  }

  private undo(): void {
    if (this.undoStack.length === 0 || this.busy) {
      return;
    }
    const current = this.captureLook();
    const target = this.undoStack[this.undoStack.length - 1];
    this.undoStack = this.undoStack.slice(0, this.undoStack.length - 1);
    this.redoStack = this.redoStack.concat([current]);
    this.restore(target);
  }

  private redo(): void {
    if (this.redoStack.length === 0 || this.busy) {
      return;
    }
    const current = this.captureLook();
    const target = this.redoStack[this.redoStack.length - 1];
    this.redoStack = this.redoStack.slice(0, this.redoStack.length - 1);
    this.undoStack = this.undoStack.concat([current]);
    this.restore(target);
  }

  private restore(target: LookState): void {
    this.restoringHistory = true;
    this.applyLook(target);
    this.lastLook = this.captureLook();
    this.restoringHistory = false;
    this.renderPreview();
  }

  private async adoptSource(uri: string): Promise<void> {
    try {
      const dot = uri.lastIndexOf('.');
      const ext = dot > 0 ? uri.substring(dot) : '.jpg';
      const input = `${this.cacheDir}/input_${Date.now()}${ext}`;
      const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        fs.copyFileSync(src.fd, input);
      } finally {
        fs.closeSync(src);
      }
      await this.addPhoto(input, uri.substring(uri.lastIndexOf('/') + 1));
    } catch (e) {
      this.status = `读取文件失败：${(e as BusinessError).message}`;
    }
  }

  private async pickSource(): Promise<void> {
    if (this.busy) {
      return;
    }
    let uri = '';
    try {
      const selection = await this.picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (selection.photoUris.length === 0) {
        return;
      }
      uri = selection.photoUris[0];
    } catch (e) {
      this.status = `无法打开相册：${(e as BusinessError).message}`;
      return;
    }
    await this.adoptSource(uri);
  }

  /**
   * Opens any file the system file manager can see.
   *
   * This is the only way to bring in a RAW/DNG: the gallery deliberately
   * indexes displayable images, so a `.dng` may never appear in the photo
   * picker at all.
   */
  private async pickFile(): Promise<void> {
    if (this.busy) {
      return;
    }
    let uri = '';
    try {
      const docPicker = new picker.DocumentViewPicker();
      const selectOptions = new picker.DocumentSelectOptions();
      selectOptions.maxSelectNumber = 1;
      const uris: string[] = await docPicker.select(selectOptions);
      if (uris.length === 0) {
        return;
      }
      uri = uris[0];
    } catch (e) {
      this.status = `打开文件失败：${(e as BusinessError).message}`;
      return;
    }
    await this.adoptSource(uri);
  }

  // --- export ---------------------------------------------------------------

  private sideLabel(side: number): string {
    return side === 0 ? '原始' : `${side}`;
  }
  /** Export option JSON for the engine: quality for JPEG, depth for the rest. */
  private exportSpec(): string {
    const format = EXPORT_FORMATS[this.exportFormat];
    if (format.ext === '.jpg') {
      return `{"quality":${Math.round(this.exportQuality)}}`;
    }
    return this.exportBitDepth === 1 ? '{"bit_depth":16}' : '{}';
  }

  /** Full-resolution render into the sandbox, then out through the save dialog. */
  /**
   * 配光: solve the enlarger filter pack for the current photograph.
   *
   * The engine renders a small proxy a few times and reports the yellow and
   * magenta that make the print neutral — the same thing an enlarger operator
   * does by eye, only faster.
   */
  private async solveFilters(): Promise<void> {
    if (!this.ready || this.busy || this.sourceUri.length === 0) {
      return;
    }
    this.busy = true;
    this.status = '配光中…';
    try {
      const request: SolveRequest = {
        dataDir: this.dataDir,
        input: this.sourceUri,
        film: this.currentFilm(),
        // No filters here: the solver must start from the same state every
        // time, or each solve lands somewhere different.
        params: this.buildParams(0, false)
      };
      const paper = this.currentPaper();
      if (paper.length > 0) {
        request.paper = paper;
      }
      const crop: CropRect | null = this.currentCrop();
      if (crop !== null) {
        request.crop = crop;
      }
      const json: string = await native.solveFilters(request);
      const result: SolveResult = JSON.parse(json) as SolveResult;
      this.filterY = result.y;
      this.filterM = result.m;
      this.filtersSolved = true;
      this.status = `配光完成 Y${result.y.toFixed(0)} M${result.m.toFixed(0)}`;
      this.schedulePreview();
    } catch (e) {
      this.status = `配光失败：${(e as BusinessError).message}`;
    } finally {
      this.busy = false;
    }
  }

  private async exportFull(): Promise<void> {
    if (!this.ready || this.busy || this.sourceUri.length === 0) {
      return;
    }
    this.busy = true;
    this.exportOpen = false;
    this.status = '全尺寸显影中…';
    try {
      const stamp = `${Date.now()}`;
      const format = EXPORT_FORMATS[this.exportFormat];
      const output = `${this.filesDir}/spektrafilm_${stamp}${format.ext}`;
      const crop: CropRect | null = this.currentCrop();
      const request: RenderRequest = {
        dataDir: this.dataDir,
        input: this.sourceUri,
        output: output,
        film: this.currentFilm(),
        paper: this.currentPaper(),
        // 0 means "keep the frame's own size"; anything else resizes the source
        // before the film stage, exactly as the preview does, so the grain
        // scales with the export.
        params: this.buildParams(EXPORT_SIDES[this.exportSide]),
        exportOptions: this.exportSpec()
      };
      if (crop !== null) {
        request.crop = crop;
      }
      if (this.exportBorder) {
        const border = this.buildBorder();
        if (border.length > 0) {
          request.border = border;
        }
      }
      const result: RenderResult = await native.renderFile(request);
      this.status = `已显影 ${result.width}×${result.height}（${result.elapsedMs} ms）`;
      if (result.width * result.height > BIG_FRAME_PX) {
        this.status = `${result.width}×${result.height} 完成（大图，内存紧张时可能失败）`;
      }
      await this.saveToGallery(result.output, stamp, format.ext);
    } catch (e) {
      this.status = `导出失败：${(e as BusinessError).message}`;
    } finally {
      this.busy = false;
    }
  }
  private async exportLut(): Promise<void> {
    if (!this.ready || this.busy) {
      return;
    }
    this.busy = true;
    this.status = '生成 3D LUT…';
    try {
      const name = `${this.currentFilm()}_${this.currentPaper()}_33.cube`;
      const sandbox = `${this.filesDir}/${name}`;
      const bytes: number = native.exportLut({
        dataDir: this.dataDir,
        film: this.currentFilm(),
        paper: this.currentPaper(),
        params: this.buildParams(0),
        size: 33,
        output: sandbox
      });

      const docPicker = new picker.DocumentViewPicker();
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = [name];
      const uris: string[] = await docPicker.save(saveOptions);
      if (uris.length === 0) {
        this.status = `已取消（LUT 在 ${sandbox}）`;
        return;
      }
      const dest = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(sandbox, dest.fd);
      } finally {
        fs.closeSync(dest);
      }
      this.status = `LUT 已保存（${bytes} 字节）`;
    } catch (e) {
      this.status = `LUT 导出失败：${(e as BusinessError).message}`;
    } finally {
      this.busy = false;
    }
  }

  // --- presets --------------------------------------------------------------

  private readTextUri(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
    } finally {
      fs.closeSync(file);
    }
  }

  private async loadPreset(): Promise<void> {
    if (!this.ready || this.busy) {
      return;
    }
    let uri = '';
    try {
      const docPicker = new picker.DocumentViewPicker();
      const selectOptions = new picker.DocumentSelectOptions();
      selectOptions.maxSelectNumber = 1;
      const uris: string[] = await docPicker.select(selectOptions);
      if (uris.length === 0) {
        return;
      }
      uri = uris[0];
    } catch (e) {
      this.status = `打开预设失败：${(e as BusinessError).message}`;
      return;
    }

    this.busy = true;
    try {
      const text = this.readTextUri(uri);
      const current = this.presetJson.length > 0 ? this.buildParams(0) : '';
      const imported: ImportedPreset =
        JSON.parse(native.importPreset(text, this.dataDir, current)) as ImportedPreset;
      this.selectFilmByName(imported.film);
      this.selectPaperByName(imported.paper);
      this.presetJson = imported.params;
      this.status = `已载入预设 ${imported.film}`;
      this.schedulePreview();
    } catch (e) {
      this.status = `预设解析失败：${(e as BusinessError).message}`;
    } finally {
      this.busy = false;
    }
  }

  private clearPreset(): void {
    this.presetJson = '';
    this.status = '已清除预设';
    this.schedulePreview();
  }

  private async savePreset(): Promise<void> {
    if (!this.ready || this.busy || this.films.length === 0) {
      return;
    }
    this.busy = true;
    try {
      const name = `${this.currentFilm()}_${this.currentPaper()}_${Date.now()}.json`;
      const sandbox = `${this.filesDir}/${name}`;
      const bytes: number = native.exportPreset({
        dataDir: this.dataDir,
        film: this.currentFilm(),
        paper: this.currentPaper(),
        params: this.buildParams(0),
        output: sandbox
      });

      const docPicker = new picker.DocumentViewPicker();
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = [name];
      const uris: string[] = await docPicker.save(saveOptions);
      if (uris.length === 0) {
        this.status = `已取消（预设留在 ${sandbox}）`;
        return;
      }
      const dest = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(sandbox, dest.fd);
      } finally {
        fs.closeSync(dest);
      }
      this.status = `预设已保存（${bytes} 字节）`;
    } catch (e) {
      this.status = `预设导出失败：${(e as BusinessError).message}`;
    } finally {
      this.busy = false;
    }
  }

  /**
   * Hands the finished file to the system save dialog and copies it wherever the
   * user chose.
   *
   * Deliberately `picker.PhotoViewPicker` rather than `photoAccessHelper`: the
   * media library's creation dialog needs a real ability `Context`, which a page
   * cannot obtain on API 26, and a Context stored through AppStorage does not
   * come back usable. The save picker has a context-free constructor and does
   * the same job with the user's explicit consent.
   */
  private async saveToGallery(sandboxPath: string, stamp: string, ext: string): Promise<void> {
    const name = `spektrafilm_${stamp}${ext}`;
    try {
      const photoPicker = new picker.PhotoViewPicker();
      const saveOptions = new picker.PhotoSaveOptions();
      saveOptions.newFileNames = [name];
      const uris: string[] = await photoPicker.save(saveOptions);
      if (uris.length === 0) {
        this.status = `已取消（文件在 ${sandboxPath}）`;
        return;
      }
      const dest = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(sandboxPath, dest.fd);
      } finally {
        fs.closeSync(dest);
      }
      this.status = `已保存 ${name}`;
    } catch (e) {
      const err = e as BusinessError;
      this.status = `保存失败(${err.code}) ${err.message}`;
      console.error(`spektrafilm: gallery save failed ${err.code} ${err.message}`);
    }
  }

  // --- UI pieces ------------------------------------------------------------

  /** Section header with a chevron; tapping toggles the body. */
  /** Section state is addressed by key so the header builder stays generic. */
  private isOpen(key: string): boolean {
    if (key === 'cam') {
      return this.openCamera;
    }
    if (key === 'print') {
      return this.openPrint;
    }
    if (key === 'frame') {
      return this.openFrame;
    }

    if (key === 'border') {
      return this.openBorder;
    }
    return this.openPost;
  }

  private toggleSection(key: string): void {
    if (key === 'cam') {
      this.openCamera = !this.openCamera;
    } else if (key === 'print') {
      this.openPrint = !this.openPrint;
    } else if (key === 'frame') {
      this.openFrame = !this.openFrame;

    } else if (key === 'border') {
      this.openBorder = !this.openBorder;
    } else {
      this.openPost = !this.openPost;
    }
  }

  @Builder
  sectionHeader(title: string, key: string) {
    Row() {
      Text(this.isOpen(key) ? '▾' : '▸')
        .fontSize(11)
        .fontColor(MUTED)
        .width(14)
      Text(title).fontSize(12).fontColor(INK).fontWeight(FontWeight.Medium)
      Blank()
    }
    .width('100%')
    .height(34)
    .padding({ left: 12, right: 12 })
    .onClick(() => {
      this.toggleSection(key);
    })
  }

  @Builder
  hintLine(text: string) {
    Text(text)
      .fontSize(9)
      .fontColor(DIM)
      .width('100%')
      .padding({ left: 12, right: 12, top: 2 })
  }

  private displayUri(): string {
    if (this.showOriginal && this.sourceUri.length > 0) {
      return `file://${this.sourceUri}`;
    }
    return this.previewUri;
  }

  /**
   * Export dialog, laid out like the desktop app's: file facts on the left, a
   * preview in the middle, settings on the right, actions bottom right.
   * Only the options the engine actually has are shown.
   */
  @Builder
  exportDialog() {
    if (this.exportOpen) {
      Column() {
        Row({ space: 0 }) {
          // --- left: what is being written ------------------------------
          Column({ space: 12 }) {
            Text('导出').fontSize(12).fontColor(MUTED).width('100%')

            Stack() {
              if (this.previewUri.length > 0) {
                Image(this.previewUri).objectFit(ImageFit.Contain).width('100%').height('100%')
              }
            }
            .width('100%')
            .height(96)
            .backgroundColor('#0A0908')
            .borderRadius(6)
            .clip(true)

            Column({ space: 3 }) {
              Text(this.fileName.length > 0 ? this.fileName : '未命名')
                .fontSize(12).fontColor(INK).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
              Text(EXPORT_FORMATS[this.exportFormat].label)
                .fontSize(10).fontColor(ACCENT)
              Text(this.exportSide === 0 ? '原始尺寸' : `长边 ${this.exportSide} px`)
                .fontSize(10).fontColor(MUTED)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')

            Blank()
          }
          .width(210)
          .height('100%')
          .padding(16)
          .backgroundColor('#12100D')

          // --- middle: preview ------------------------------------------
          Column() {
            Stack() {
              if (this.previewUri.length > 0) {
                Image(this.previewUri).objectFit(ImageFit.Contain).width('100%').height('100%')
              } else {
                Text('无预览').fontSize(12).fontColor('#4A453C')
              }
            }
            .width('100%')
            .layoutWeight(1)
          }
          .layoutWeight(1)
          .padding(16)
          .backgroundColor('#0E0C0A')

          // --- right: settings ------------------------------------------
          Column({ space: 14 }) {
            Column({ space: 8 }) {
              Text('文件设置').fontSize(11).fontColor(INK).width('100%')
              Row({ space: 6 }) {
                ForEach(EXPORT_FORMATS, (f: ExportFormat, i: number) => {
                  Text(f.label)
                    .fontSize(11)
                    .fontColor(i === this.exportFormat ? '#1A1713' : MUTED)
                    .backgroundColor(i === this.exportFormat ? ACCENT : '#1C1915')
                    .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                    .borderRadius(5)
                    .onClick(() => { this.exportFormat = i; })
                }, (f: ExportFormat) => f.label)
                Blank()
              }
              .width('100%')

              if (EXPORT_FORMATS[this.exportFormat].ext === '.jpg') {
                Row() {
                  Text('品质').fontSize(10).fontColor(MUTED)
                  Blank()
                  Text(`${Math.round(this.exportQuality)}`).fontSize(11).fontColor(INK)
                }
                .width('100%')
                Slider({ value: this.exportQuality, min: 70, max: 100, step: 1, style: SliderStyle.OutSet })
                  .selectedColor(ACCENT).trackColor('#241F19').blockColor(INK)
                  .width('100%')
                  .onChange((v: number) => { this.exportQuality = v; })
              }
            }
            .width('100%')

            Divider().color(LINE)

            Column({ space: 8 }) {
              Text('图像大小').fontSize(11).fontColor(INK).width('100%')
              Row({ space: 6 }) {
                ForEach(EXPORT_SIDES, (side: number, i: number) => {
                  Text(this.sideLabel(side))
                    .fontSize(11)
                    .fontColor(i === this.exportSide ? '#1A1713' : MUTED)
                    .backgroundColor(i === this.exportSide ? ACCENT : '#1C1915')
                    .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                    .borderRadius(5)
                    .onClick(() => { this.exportSide = i; })
                }, (side: number) => `${side}`)
                Blank()
              }
              .width('100%')
              if (EXPORT_FORMATS[this.exportFormat].ext !== '.jpg') {
                // Title on its own line, chips below: same rhythm as the other
                // sections instead of an inline label.
                Text('位深').fontSize(11).fontColor(INK).width('100%')
                Row({ space: 6 }) {
                  Text('8 bit')
                    .fontSize(11)
                    .fontColor(this.exportBitDepth === 0 ? '#1A1713' : MUTED)
                    .backgroundColor(this.exportBitDepth === 0 ? ACCENT : '#1C1915')
                    .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                    .borderRadius(5)
                    .onClick(() => { this.exportBitDepth = 0; })
                  Text('16 bit')
                    .fontSize(11)
                    .fontColor(this.exportBitDepth === 1 ? '#1A1713' : MUTED)
                    .backgroundColor(this.exportBitDepth === 1 ? ACCENT : '#1C1915')
                    .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                    .borderRadius(5)
                    .onClick(() => { this.exportBitDepth = 1; })
                  Blank()
                }
                .width('100%')
              }
            }
            .width('100%')

            Divider().color(LINE)

            Column({ space: 8 }) {
              Text('画布').fontSize(11).fontColor(INK).width('100%')
              Row() {
                Text('包含片边').fontSize(11).fontColor('#A79E8E')
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.exportBorder })
                  .selectedColor(ACCENT)
                  .onChange((on: boolean) => { this.exportBorder = on; })
              }
              .width('100%')
            }
            .width('100%')

            Blank()

            Row({ space: 8 }) {
              Button('取消')
                .fontSize(12).height(34).layoutWeight(1)
                .backgroundColor('#1C1915').fontColor('#C9BDA6')
                .type(ButtonType.Normal).borderRadius(6)
                .onClick(() => { this.exportOpen = false; })
              Button('导出')
                .fontSize(12).height(34).layoutWeight(1)
                .backgroundColor(ACCENT).fontColor('#1A1713')
                .type(ButtonType.Normal).borderRadius(6)
                .onClick(() => { this.exportFull(); })
            }
            .width('100%')
          }
          .width(270)
          .height('100%')
          .padding(16)
          .backgroundColor('#12100D')
        }
        .width(960)
        .height(520)
        .backgroundColor('#17140F')
        .borderRadius(12)
        .border({ width: 1, color: LINE })
        .clip(true)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#CC000000')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({
        top: px2vp(this.safeTopPx),
        bottom: px2vp(this.safeBottomPx),
        left: 24,
        right: 24
      })
    }
  }

  /**
   * A stock's brand card: the colour scheme its carton uses, drawn with a few
   * rectangles. Deliberately abstract — recognisable as Fuji or Kodak at a
   * glance without shipping anyone's packaging or artwork.
   */
  @Builder
  stockCard(film: FilmEntry) {
    if (badgeKind(film) === 'cine') {
      Row() {
        Text('CINE').fontSize(5).fontColor('#20160A').fontWeight(FontWeight.Bold)
      }
      .width(23).height(9)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#E8853C')
      .borderRadius(4)
    } else if (badgeKind(film) === 'bw') {
      Row() {
        Text('B&W').fontSize(5).fontColor('#141414').fontWeight(FontWeight.Bold)
      }
      .width(23).height(9)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#F4F4F4')
      .borderRadius(2)
    } else if (badgeKind(film) === 'fuji') {
      // Green, silver, green, with the two separators the carton has.
      Column() {
        Row().width('100%').height(2).backgroundColor('#1E7A45')
        Row().width('100%').height(1).backgroundColor('#0E0C0A')
        Row().width('100%').height(3).backgroundColor('#C9CECF')
        Row().width('100%').height(1).backgroundColor('#0E0C0A')
        Row().width('100%').height(2).backgroundColor('#1E7A45')
      }
      .width(23).height(9).borderRadius(1).clip(true)
    } else if (badgeKind(film) === 'kodak') {
      // Yellow over purple, one rule between.
      Column() {
        Row().width('100%').height(4).backgroundColor('#F5C518')
        Row().width('100%').height(1).backgroundColor('#0E0C0A')
        Row().width('100%').height(4).backgroundColor('#5B2D82')
      }
      .width(23).height(9).borderRadius(1).clip(true)
    } else if (badgeKind(film) === 'provia') {
      Column() {
        Row().width('100%').height(4).backgroundColor('#1E7A45')
        Row().width('100%').height(5).backgroundColor('#123A6B')
      }
      .width(23).height(9).borderRadius(1).clip(true)
    } else if (badgeKind(film) === 'velvia') {
      // Blue with the white panel, over green.
      Column() {
        Stack() {
          Row().width('100%').height('100%').backgroundColor('#1565A8')
          Row().width(7).height(3).backgroundColor('#F2F2F2').borderRadius(1)
        }
        .width('100%').height(5)
        Row().width('100%').height(4).backgroundColor('#2E7D32')
      }
      .width(23).height(9).borderRadius(1).clip(true)
    } else if (badgeKind(film) === 'ektachrome') {
      Column() {
        Row().width('100%').height(5).backgroundColor('#1565A8')
        Row().width('100%').height(4).backgroundColor('#F2F2F2')
      }
      .width(23).height(9).borderRadius(1).clip(true)
    } else {
      Row().width(23).height(9)
    }
  }
  /**
   * A rail's drag handle. The rail follows the finger: clamping is arithmetic on
   * the width itself, so no absolute window coordinate is needed — asking the
   * root for its width failed and left the right handle pinned at its minimum.
   */
  @Builder
  railHandle(side: number) {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(this.dragSide === side ? 2 : 1)
        .height('100%')
        .backgroundColor(this.dragSide === side ? ACCENT : LINE)
        // A short grip in the middle of the gap: two hairlines alone read as a
        // boundary rather than as something you can pull.
        Row()
          .width(4)
          .height(38)
          .borderRadius(2)
          // The rail starts below the status bar, so its own centre sits half
          // that height below the window's. Pull it back so the grip reads as
          // centred on the screen rather than on the rail.
          // Half the gap: the rail's own border is the left line, the handle
          // draws the right one, so the grip belongs between them, not on
          // top of the right line.
          // The gap is on opposite sides of the handle: the left rail's border
          // is its right edge, the right rail's is its left edge.
          .offset({ x: side === 1 ? -3.5 : 3.5, y: -px2vp(this.safeTopPx) / 2 })
          .backgroundColor(this.dragSide === side ? ACCENT : '#4C463B')
    }
    .width(14)
    .height('100%')
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal })
        .onActionStart(() => {
          this.dragSide = side;
          this.dragFrom = side === 1 ? this.leftW : this.rightW;
        })
        .onActionUpdate((e: GestureEvent) => {
          const moved = side === 1 ? this.dragFrom + e.offsetX : this.dragFrom - e.offsetX;
          const low = side === 1 ? 180 : 240;
          const high = side === 1 ? 420 : 520;
          const width = Math.max(low, Math.min(high, moved));
          if (side === 1) {
            this.leftW = width;
          } else {
            this.rightW = width;
          }
        })
        .onActionEnd(() => { this.dragSide = 0; })
        .onActionCancel(() => { this.dragSide = 0; })
    )
  }


  /**
   * A slider whose track shows what the parameter does: dark to light for
   * exposure, blue to yellow for temperature, grey to muted colour for
   * saturation. Lightroom's idea, in this app's palette — the ramps are
   * deliberately dim so the picture stays the brightest thing on screen.
   */
  @Builder
  paramSlider(which: string, value: number, min: number, max: number, step: number, from: string, to: string) {
    Stack() {
      Row()
        .width('90%')
        .height(4)
        .borderRadius(2)
        .linearGradient({ angle: 90, colors: [[from, 0.0], [to, 1.0]] })
      Slider({ value: value, min: min, max: max, step: step, style: SliderStyle.OutSet })
        .selectedColor(Color.Transparent)
        .trackColor(Color.Transparent)
        .blockColor('#CFC7B8')
        .blockSize({ width: 10, height: 10 })
        .width('90%')
        .onChange((v: number) => { this.setParam(which, v); })
    }
    .width('100%')
    .height(36)
  }

  /** Writes a slider back to its own field; the ramps share one call site. */
  private setParam(which: string, v: number): void {
    if (which === 'ev') {
      this.ev = v;
    } else if (which === 'temperature') {
      this.temperature = v;
    } else if (which === 'printEv') {
      this.printEv = v;
    } else if (which === 'tint') {
      this.tint = v;
    } else if (which === 'postContrast') {
      this.postContrast = v;
    } else if (which === 'postSaturation') {
      this.postSaturation = v;
    } else if (which === 'postWhites') {
      this.postWhites = v;
    } else if (which === 'postBlacks') {
      this.postBlacks = v;
    }
    this.schedulePreview();
  }

  /**
   * Saturation's track runs grey to colour, the way Lightroom's does: the
   * ramp itself is the legend, so the panel needs no label explaining which
   * end is which. The colour stops are mixed down towards the panel grey so
   * the ramp does not out-shout the photograph.
   */
  @Builder
  satSlider(value: number) {
    Stack() {
      Row()
        .width('90%')
        .height(4)
        .borderRadius(2)
        .linearGradient({
          angle: 90,
          colors: [['#2B2B29', 0.0], ['#38432F', 0.3], ['#4A4630', 0.5],
                   ['#57382F', 0.72], ['#4E2F3F', 1.0]]
        })
      Slider({ value: value, min: -1, max: 1, step: 0.05, style: SliderStyle.OutSet })
        .selectedColor(Color.Transparent)
        .trackColor(Color.Transparent)
        .blockColor('#CFC7B8')
        .blockSize({ width: 10, height: 10 })
        .width('90%')
        .onChange((v: number) => { this.setParam('postSaturation', v); })
    }
    .width('100%')
    .height(36)
  }

  /** The crop rectangle and its handles, drawn over the picture. */
  @Builder
  cropOverlay() {
    Stack() {
      // Everything outside the rectangle goes dim, in four pieces.
      Row()
        .width('100%')
        .height(this.imageBox()[1] + this.cropY * this.imageBox()[3])
        .position({ x: 0, y: 0 })
        .backgroundColor('#99000000')
      Row()
        .width('100%')
        .height(this.imageBox()[1] + (1 - this.cropY - this.cropH) * this.imageBox()[3])
        .position({ x: 0, y: this.imageBox()[1] + (this.cropY + this.cropH) * this.imageBox()[3] })
        .backgroundColor('#99000000')
      Row()
        .width(this.imageBox()[0] + this.cropX * this.imageBox()[2])
        .height(this.cropH * this.imageBox()[3])
        .position({ x: 0, y: this.imageBox()[1] + this.cropY * this.imageBox()[3] })
        .backgroundColor('#99000000')
      Row()
        .width(this.imageBox()[0] + (1 - this.cropX - this.cropW) * this.imageBox()[2])
        .height(this.cropH * this.imageBox()[3])
        .position({ x: this.imageBox()[0] + (this.cropX + this.cropW) * this.imageBox()[2], y: this.imageBox()[1] + this.cropY * this.imageBox()[3] })
        .backgroundColor('#99000000')

      // The rectangle itself: a bright border with corner grips.
      Stack() {
        Row()
          .width('100%')
          .height('100%')
          .border({ width: 1, color: '#E8E0D0' })
        // Corner grips, 22 vp squares so a finger can find them.
        Row()
          .width(22).height(22)
          .backgroundColor('#E8E0D0')
          .position({ x: -11, y: -11 })
          .gesture(PanGesture({ direction: PanDirection.All })
            .onActionStart(() => { this.dragCrop = [this.cropX, this.cropY, this.cropW, this.cropH]; })
            .onActionUpdate((e: GestureEvent) => {
              const box = this.imageBox();
              this.cropX = this.dragCrop[0] + e.offsetX / Math.max(1, box[2]);
              this.cropY = this.dragCrop[1] + e.offsetY / Math.max(1, box[3]);
              this.cropW = this.dragCrop[2] - e.offsetX / Math.max(1, box[2]);
              this.cropH = this.dragCrop[3] - e.offsetY / Math.max(1, box[3]);
              this.clampCrop();
              this.lockCropAspect();
            }))
        Row()
          .width(22).height(22)
          .backgroundColor('#E8E0D0')
          .position({ x: '100%', y: -11 })
          .markAnchor({ x: 11, y: 0 })
          .gesture(PanGesture({ direction: PanDirection.All })
            .onActionStart(() => { this.dragCrop = [this.cropX, this.cropY, this.cropW, this.cropH]; })
            .onActionUpdate((e: GestureEvent) => {
              const box = this.imageBox();
              this.cropY = this.dragCrop[1] + e.offsetY / Math.max(1, box[3]);
              this.cropW = this.dragCrop[2] + e.offsetX / Math.max(1, box[2]);
              this.cropH = this.dragCrop[3] - e.offsetY / Math.max(1, box[3]);
              this.clampCrop();
              this.lockCropAspect();
            }))
        Row()
          .width(22).height(22)
          .backgroundColor('#E8E0D0')
          .position({ x: -11, y: '100%' })
          .markAnchor({ x: 0, y: 11 })
          .gesture(PanGesture({ direction: PanDirection.All })
            .onActionStart(() => { this.dragCrop = [this.cropX, this.cropY, this.cropW, this.cropH]; })
            .onActionUpdate((e: GestureEvent) => {
              const box = this.imageBox();
              this.cropX = this.dragCrop[0] + e.offsetX / Math.max(1, box[2]);
              this.cropW = this.dragCrop[2] - e.offsetX / Math.max(1, box[2]);
              this.cropH = this.dragCrop[3] + e.offsetY / Math.max(1, box[3]);
              this.clampCrop();
              this.lockCropAspect();
            }))
        Row()
          .width(22).height(22)
          .backgroundColor('#E8E0D0')
          .position({ x: '100%', y: '100%' })
          .markAnchor({ x: 11, y: 11 })
          .gesture(PanGesture({ direction: PanDirection.All })
            .onActionStart(() => { this.dragCrop = [this.cropX, this.cropY, this.cropW, this.cropH]; })
            .onActionUpdate((e: GestureEvent) => {
              const box = this.imageBox();
              this.cropW = this.dragCrop[2] + e.offsetX / Math.max(1, box[2]);
              this.cropH = this.dragCrop[3] + e.offsetY / Math.max(1, box[3]);
              this.clampCrop();
              this.lockCropAspect();
            }))
      }
      .width(this.cropW * this.imageBox()[2])
      .height(this.cropH * this.imageBox()[3])
      .position({ x: this.imageBox()[0] + this.cropX * this.imageBox()[2], y: this.imageBox()[1] + this.cropY * this.imageBox()[3] })
      .gesture(PanGesture({ direction: PanDirection.All })
        .onActionStart(() => { this.dragCrop = [this.cropX, this.cropY, this.cropW, this.cropH]; })
        .onActionUpdate((e: GestureEvent) => {
          const box = this.imageBox();
          this.cropX = this.dragCrop[0] + e.offsetX / Math.max(1, box[2]);
          this.cropY = this.dragCrop[1] + e.offsetY / Math.max(1, box[3]);
          this.clampCrop();
        }))
    }
    .width('100%')
    .height('100%')
  }

  /**
   * The gate, drawn over the full frame. Everything outside it dims, because
   * that is exactly what the border will cut away.
   */

  /** 视图: overlays that do not change the render, only what is drawn on top. */
  @Builder
  viewMenu() {
    Menu() {
      MenuItem({ content: this.showWaveform ? '✓ 波形' : '波形' })
        .onClick(() => {
          this.showWaveform = !this.showWaveform;
          if (this.showWaveform && this.lastPreviewPath.length > 0) {
            this.measureWaveform(this.lastPreviewPath);
          }
        })
      MenuItem({ content: '片边构图' })
        .enabled(this.ready && !this.busy && this.sourceUri.length > 0)
        .onClick(() => { this.openCompose(); })
    }
  }

  build() {
    Stack() {
      Row() {
      // ================= LEFT: film and paper ==============================
      Column() {
        Row() {
          Text('胶片与相纸').fontSize(13).fontColor(INK).fontWeight(FontWeight.Medium)
          Blank()
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 8 })

        Row() {
          Text('导航').fontSize(12).fontColor(INK).fontWeight(FontWeight.Medium)
          Blank()
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 4 })

        // Navigator thumbnail, mirroring the desktop's top-left preview.
        Stack() {
          if (this.previewUri.length > 0) {
            Image(this.displayUri()).objectFit(ImageFit.Contain).width('100%').height('100%')
          } else {
            Text('无图像').fontSize(11).fontColor('#4A453C')
          }
        }
        .width('100%')
        .height(96)
        .backgroundColor('#0A0908')
        .borderRadius(6)
        .margin({ left: 14, right: 14, bottom: 10 })

        Text('胶片').fontSize(12).fontColor(INK).fontWeight(FontWeight.Medium).width('100%').padding({ left: 14, top: 4, bottom: 2 })

        List({ space: 0 }) {
          ForEach(this.filmRows, (row: FilmRow) => {
            ListItem() {
              if (row.isCaption) {
                Text(row.label)
                  .fontSize(9)
                  .fontColor('#6E675B')
                  .width('100%')
                  .padding({ left: 8, top: 7, bottom: 3 })
              } else {
                Row({ space: 8 }) {
                  Text(this.films[row.filmIndex].label)
                    .fontSize(12)
                    .fontColor(row.filmIndex === this.filmIndex ? '#171410' : '#D8CFBE')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  this.stockCard(this.films[row.filmIndex])
                }
                .width('100%')
                .padding({ left: 7, right: 8, top: 4, bottom: 4 })
                .backgroundColor(row.filmIndex === this.filmIndex ? '#F0EBE1' : Color.Transparent)
                .borderRadius(9)
                .onClick(() => {
                  this.filmIndex = row.filmIndex;
                  this.syncPaperToFilm();
                  this.schedulePreview();
                })
              }
            }
          }, (row: FilmRow) => row.isCaption ? row.label : this.films[row.filmIndex].name)
        }
        .layoutWeight(3)
        .width('100%')
        .width('90%').margin({ left: 10 })
        .scrollBar(BarState.Off)

        Divider().color(LINE).margin({ top: 6, bottom: 6 })

        Text('相纸').fontSize(12).fontColor(INK).fontWeight(FontWeight.Medium).width('100%').padding({ left: 14, top: 4, bottom: 2 })

        List({ space: 0 }) {
          // Reversal films print onto nothing, so the list needs a row that
          // means exactly that; it is what selecting a slide lands on.
          ListItem() {
            Text('不使用相纸配置')
              .fontSize(12)
              .fontColor(this.paperIndex < 0 ? '#171410' : '#D8CFBE')
              .maxLines(1)
              .width('100%')
              .padding({ left: 7, right: 8, top: 5, bottom: 5 })
              .backgroundColor(this.paperIndex < 0 ? '#F0EBE1' : Color.Transparent)
              .borderRadius(9)
              .onClick(() => {
                this.paperIndex = -1;
      // A slide is scanned directly: the engine's slide path needs this,
      // and printing it onto paper would be physically wrong.
      this.scanFilm = true;
                this.schedulePreview();
              })
          }
          ForEach(this.papers, (paper: PaperEntry, index: number) => {
            ListItem() {
              Text(paper.label)
                .fontSize(12)
                .fontColor(index === this.paperIndex ? '#171410' : '#D8CFBE')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ left: 7, right: 8, top: 5, bottom: 5 })
                .backgroundColor(index === this.paperIndex ? '#F0EBE1' : Color.Transparent)
                .borderRadius(9)
                .onClick(() => {
                  this.paperIndex = index;
                  this.schedulePreview();
                })
            }
          }, (paper: PaperEntry) => paper.name)
        }
        .layoutWeight(2)
        .width('100%')
        .padding({ left: 8, right: 8, bottom: 8 })
        .scrollBar(BarState.Off)

        Divider().color(LINE).margin({ top: 4, bottom: 8 })

        Row() {
          Text('片边').fontSize(10).fontColor(MUTED)
          Blank()
          Text(BORDERS[this.borderIndex].label).fontSize(9).fontColor(DIM)
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 4 })

        // 画幅 sets the crop and the border family together. 135 frames are cut
        // from the 35mm strip (which turns with the picture, so half frame shows
        // its perforations above and below); 120 frames use the nine-patch 120
        // border, which is why 6×6 comes out square.
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(FORMATS, (f: FrameFormat, i: number) => {
            Text(f.label)
              .fontSize(10)
              .fontColor(i === this.formatIndex ? '#1A1713' : MUTED)
              .backgroundColor(i === this.formatIndex ? ACCENT : '#1C1915')
              .padding({ left: 7, right: 7, top: 4, bottom: 4 })
              .borderRadius(4)
              .margin({ right: 4, bottom: 4 })
              .onClick(() => {
                this.formatIndex = i;
                this.cropRatio = f.ratio;
                if (f.style.length > 0) {
                  this.borderIndex = this.borderIndexOf(f.style);
                }
                this.schedulePreview();
              })
          }, (f: FrameFormat) => f.label)
        }
        .width('100%')
        .padding({ left: 12, right: 8 })

        // Style override, so a 135 crop can still take a plain mat if wanted.
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(BORDERS, (b: BorderChoice, i: number) => {
            Text(b.label)
              .fontSize(10)
              .fontColor(i === this.borderIndex ? '#1A1713' : MUTED)
              .backgroundColor(i === this.borderIndex ? ACCENT : '#1C1915')
              .padding({ left: 7, right: 7, top: 4, bottom: 4 })
              .borderRadius(4)
              .margin({ right: 4, bottom: 4 })
              .onClick(() => {
                this.borderIndex = i;
                this.schedulePreview();
              })
          }, (b: BorderChoice) => b.label)
        }
        .width('100%')
        .padding({ left: 12, right: 8, bottom: 10 + px2vp(this.safeBottomPx) })

        // The two things that were on the spool rather than in the gate.
        if (BORDERS[this.borderIndex].style === '35mm') {
          Row() {
            Text('灰雾').fontSize(10).fontColor(MUTED).width(34)
            Slider({ value: this.edgeFog, min: 0, max: 1, step: 0.02, style: SliderStyle.OutSet })
              .selectedColor(ACCENT)
              .trackColor('#241F19')
              .blockColor(INK)
              .layoutWeight(1)
              .onChange((v: number) => {
                this.edgeFog = v;
                this.schedulePreview();
              })
            Text(`${Math.round(this.edgeFog * 100)}`)
              .fontSize(9)
              .fontColor(DIM)
              .width(22)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 4 })

          Row() {
            Text('漏光').fontSize(10).fontColor(MUTED).width(34)
            Slider({ value: this.edgeLeak, min: 0, max: 1, step: 0.02, style: SliderStyle.OutSet })
              .selectedColor(ACCENT)
              .trackColor('#241F19')
              .blockColor(INK)
              .layoutWeight(1)
              .onChange((v: number) => {
                this.edgeLeak = v;
                this.schedulePreview();
              })
            Text(`${Math.round(this.edgeLeak * 100)}`)
              .fontSize(9)
              .fontColor(DIM)
              .width(22)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding({ left: 14, right: 14 })
        }
      }
      .width(this.leftW)
      .height('100%')
      .backgroundColor(PANEL_2)
      .border({ width: { right: 1 }, color: LINE })

      this.railHandle(1)

      // ================= CENTER: canvas ====================================
      Column() {
        // toolbar
        Row({ space: 8 }) {
          // One entry point for opening a photograph. The two pickers differ in
          // what they can see — the gallery indexes displayable images, the file
          // manager also hands over RAW/DNG — so both stay available, just not
          // side by side in the toolbar.
          Button('导入')
            .fontSize(12)
            .height(32)
            .backgroundColor('#1C1915')
            .fontColor('#C9BDA6')
            .type(ButtonType.Normal)
            .borderRadius(6)
            .enabled(this.ready && !this.busy)
            .bindMenu([
              {
                value: '从相册导入',
                action: () => { this.pickSource(); }
              },
              {
                value: '从文件导入',
                action: () => { this.pickFile(); }
              }
            ])

          Button('视图')
            .fontSize(12).height(32)
            .backgroundColor('#1C1915').fontColor('#C9BDA6')
            .type(ButtonType.Normal).borderRadius(6)
            .bindMenu(this.viewMenu)

          // 成片 / 原图 toggle, like the desktop's 配光 / 原图 switch
          Row() {
            Text('成片')
              .fontSize(12)
              .fontColor(this.showOriginal ? MUTED : '#1A1713')
              .backgroundColor(this.showOriginal ? Color.Transparent : ACCENT)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(5)
              .onClick(() => { this.showOriginal = false; })
            Text('原图')
              .fontSize(12)
              .fontColor(this.showOriginal ? '#1A1713' : MUTED)
              .backgroundColor(this.showOriginal ? ACCENT : Color.Transparent)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(5)
              .onClick(() => { this.showOriginal = true; })
          }
          .backgroundColor('#1C1915')
          .borderRadius(6)
          .padding(2)

          Text(this.fileName.length > 0 ? this.fileName :
            (this.frameInfo.length > 0 ? this.frameInfo : '未选择照片'))
            .fontSize(11)
            .fontColor(DIM)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Blank()

          if (this.busy) {
            LoadingProgress().width(18).height(18).color(ACCENT)
          }
          Text(this.timing).fontSize(11).fontColor(DIM)

          // Tap to return to fit; doubles as the zoom readout.
          Text(`${Math.round(this.zoom * 100)}%`)
            .fontSize(11)
            .fontColor(this.zoom > 1.01 ? ACCENT : DIM)
            .width(42)
            .textAlign(TextAlign.End)
            .onClick(() => { this.resetView(); })

          Text('↶')
            .fontSize(16)
            .fontColor(this.undoStack.length > 0 ? '#C9BDA6' : '#3E3A33')
            .width(28)
            .height(28)
            .textAlign(TextAlign.Center)
            .borderRadius(14)
            .backgroundColor('#1C1915')
            .onClick(() => { this.undo(); })
          Text('↷')
            .fontSize(16)
            .fontColor(this.redoStack.length > 0 ? '#C9BDA6' : '#3E3A33')
            .width(28)
            .height(28)
            .textAlign(TextAlign.Center)
            .borderRadius(14)
            .backgroundColor('#1C1915')
            .onClick(() => { this.redo(); })


          Button('波形')
            .fontSize(12)
            .height(32)
            .backgroundColor(this.showWaveform ? ACCENT : '#1C1915')
            .fontColor(this.showWaveform ? '#1A1713' : '#C9BDA6')
            .type(ButtonType.Normal)
            .borderRadius(6)
            .onClick(() => {
              this.showWaveform = !this.showWaveform;
              if (this.showWaveform && this.lastPreviewPath.length > 0) {
                this.measureWaveform(this.lastPreviewPath);
              }
            })



          Button('导出')
            .fontSize(12)
            .height(32)
            .backgroundColor(ACCENT)
            .fontColor('#1A1713')
            .type(ButtonType.Normal)
            .borderRadius(6)
            .enabled(this.ready && !this.busy && this.sourceUri.length > 0)
            .onClick(() => { this.exportOpen = true; })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })

        // canvas
        Stack() {
          if (this.displayUri().length > 0) {
            Image(this.displayUri())
              .objectFit(ImageFit.Contain)
              .width('100%')
              .height('100%')
              .scale({ x: this.zoom, y: this.zoom })
              .translate({ x: this.panX, y: this.panY })
          } else {
            Column({ space: 10 }) {
              Text('选择一张照片开始').fontSize(14).fontColor('#5E584E')
              // Two doors into the same room: gallery and file manager. Same
              // size and colour, because neither is the "right" one.
              Button('从相册选择')
                .fontSize(13)
                .height(38)
                .width(168)
                .backgroundColor('#1C1915')
                .fontColor('#C9BDA6')
                .type(ButtonType.Normal)
                .borderRadius(7)
                .enabled(this.ready && !this.busy)
                .onClick(() => { this.pickSource(); })
              Button('从文件选择')
                .fontSize(13)
                .height(38)
                .width(168)
                .backgroundColor('#1C1915')
                .fontColor('#C9BDA6')
                .type(ButtonType.Normal)
                .borderRadius(7)
                .enabled(this.ready && !this.busy)
                .onClick(() => { this.pickFile(); })
            }
            .justifyContent(FlexAlign.Center)
            .height('100%')
          }

          // Crop mode: the rectangle plus its 应用 / 取消 pair.

          // 片边构图: the full frame with the gate on top of it.
          if (this.composeMode) {
            Column() {
              Image(this.composeUri)
                .objectFit(ImageFit.Contain)
                .width('100%')
                .height('100%')
                // The gate stays put; the picture moves under it,
                // using the same transform the preview already uses.
                .scale({ x: this.zoom, y: this.zoom })
                .translate({ x: this.panX, y: this.panY })
            }
            .width('100%')
            .height('100%')
            .backgroundColor('#0A0908')

            // The gate: a fixed frame in the format's shape. It takes no
            // gesture at all, so the canvas underneath keeps every event and
            // there is nothing to arbitrate against.
            Column() {
              Row()
                .width('100%')
                .height('100%')
                .border({ width: 1, color: '#E8E0D0' })
            }
            .width(this.gateRect()[2])
            .height(this.gateRect()[3])
            .position({ x: this.gateRect()[0], y: this.gateRect()[1] })
            .hitTestBehavior(HitTestMode.None)

            Row({ space: 8 }) {
              Blank()
              Button('取消')
                .fontSize(12).height(32)
                .backgroundColor('#1C1915').fontColor('#C9BDA6')
                .type(ButtonType.Normal).borderRadius(6)
                .onClick(() => { this.closeCompose(); })
              Button('应用')
                .fontSize(12).height(32)
                .backgroundColor(ACCENT).fontColor('#1A1713')
                .type(ButtonType.Normal).borderRadius(6)
                .onClick(() => { this.applyGate(); })
            }
            .width('100%')
            .height('100%')
            .padding({ right: 16, bottom: 12 })
            .alignItems(VerticalAlign.Bottom)
            .hitTestBehavior(HitTestMode.Transparent)
          }

          // Waveform overlay, parked in the top-right corner of the canvas.
          if (this.showWaveform && !this.composeMode) {
            Row() {
              Blank()
              Column({ space: 4 }) {
                Text('波形')
                  .fontSize(9)
                  .fontColor('#7A7365')
                  .width('100%')
                Canvas(this.waveCtx)
                  .width(208)
                  .height(96)
                  .onReady(() => { this.drawWaveform(); })
              }
              .width(228)
              .padding(10)
              .backgroundColor('#5C080705')
              .borderRadius(10)
              .border({ width: 1, color: '#2A2A24' })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .height('100%')
            .padding({ top: 12, right: 16 })
            .alignItems(VerticalAlign.Top)
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#0A0908')
        // Clipping matters: without it a zoomed image spills over the toolbar
        // and the parameter panel.
        .clip(true)
        .onAreaChange((_old: Area, now: Area) => {
          this.canvasW = Number(now.width);
          this.canvasH = Number(now.height);
        })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            // Double tap toggles 2x, and resets from anything else. Pinch is
            // exact but two fingers on a 12" tablet are awkward; this is the
            // gesture people actually reach for.
            TapGesture({ count: 2 })
              .onAction(() => {
                if (this.zoom <= 1.01) {
                  this.zoom = 2;
                  this.panX = 0;
                  this.panY = 0;
                } else {
                  this.resetView();
                }
              }),
            // One finger pans, but only once zoomed in: at 100% a drag would
            // just slide the picture around inside its own frame.
            PanGesture({ fingers: 1, distance: 3 })
              .onActionStart(() => {
                this.panStartX = this.panX;
                this.panStartY = this.panY;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.zoom <= 1.01 && !this.composeMode) {
                  return;
                }
                this.panX = this.clampPan(this.panStartX + event.offsetX, this.canvasW);
                this.panY = this.clampPan(this.panStartY + event.offsetY, this.canvasH);
              }),
            // Two fingers zoom. Panning while pinching would fight the gesture,
            // so the offset is only re-clamped here.
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.zoomStart = this.zoom;
              })
              .onActionUpdate((event: GestureEvent) => {
                const next = Math.min(MAX_ZOOM, Math.max(1, this.zoomStart * event.scale));
                this.zoom = next;
                if (next <= 1.01) {
                  this.panX = 0;
                  this.panY = 0;
                } else {
                  this.panX = this.clampPan(this.panX, this.canvasW);
                  this.panY = this.clampPan(this.panY, this.canvasH);
                }
              })
          )
        )

        // status bar
        Row({ space: 10 }) {
          Text(this.currentFilm()).fontSize(10).fontColor(MUTED)
          Text('·').fontSize(10).fontColor(DIM)
          Text(this.currentPaper()).fontSize(10).fontColor(MUTED)
          if (this.scanFilm) {
            Text('· 直扫负片').fontSize(10).fontColor(MUTED)
          }
          if (this.presetJson.length > 0) {
            Text('· 预设').fontSize(10).fontColor(ACCENT)
          }
          Blank()
          Text(this.status).fontSize(10).fontColor(DIM).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.photos.length > 0) {
            Text(this.stripOpen ? '▾' : '▸')
              .fontSize(12)
              .fontColor(MUTED)
              .padding({ left: 10, right: 2 })
              .onClick(() => { this.stripOpen = !this.stripOpen; })
          }
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 6, bottom: 6 + (this.stripOpen ? 0 : px2vp(this.safeBottomPx)) })
        .backgroundColor(PANEL_2)
        .border({ width: { top: 1 }, color: LINE })

        // Filmstrip, as on the desktop app: pick between imported photographs
        // without leaving the editor. Each tile is a real 180 px render, so the
        // strip shows the grade rather than the raw file.
        if (this.photos.length > 0 && this.stripOpen) {
          Row() {
            List({ space: 8 }) {
              ForEach(this.photos, (p: PhotoItem) => {
                ListItem() {
                  Column({ space: 3 }) {
                    Stack() {
                      if (p.thumb.length > 0) {
                        Image(p.thumb).objectFit(ImageFit.Cover).width('100%').height('100%')
                      } else {
                        LoadingProgress().width(18).height(18).color('#5E584E')
                      }
                    }
                    .width(84)
                    .height(84)
                    .backgroundColor('#14120F')
                    .borderRadius(4)
                    .clip(true)
                    .border({
                      width: p.id === this.activeId ? 2 : 1,
                      color: p.id === this.activeId ? ACCENT : '#241F19'
                    })

                    Text(p.name)
                      .fontSize(9)
                      .fontColor(p.id === this.activeId ? INK : DIM)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width(84)
                      .textAlign(TextAlign.Center)
                  }
                  .onClick(() => { this.selectPhoto(p.id); })
                }
              }, (p: PhotoItem) => `${p.id}|${p.thumb.length > 0 ? 1 : 0}|${p.id === this.activeId ? 1 : 0}`)
            }
            .listDirection(Axis.Horizontal)
            .layoutWeight(1)
            .height(108)
            .scrollBar(BarState.Off)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 6, bottom: 8 + px2vp(this.safeBottomPx) })
          .backgroundColor(PANEL_2)
          .border({ width: { top: 1 }, color: LINE })
        }
      }
      .layoutWeight(1)
      .height('100%')

      this.railHandle(2)

      // ================= RIGHT: parameters ==================================
      Column() {
        Row() {
          Text('参数').fontSize(13).fontColor(INK).fontWeight(FontWeight.Medium)
          Blank()
          Text('关于').fontSize(11).fontColor('#C9BDA6')
            .padding({ left: 10, right: 10, top: 2, bottom: 2 })
            .onClick(() => {
              this.aboutDialog.open();
            })
          Text('显影后').fontSize(10).fontColor('#1A1713')
            .backgroundColor(ACCENT)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(9)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 8 })

        Scroll() {
          Column() {
            // --- 输入 / 相机 ---------------------------------------------
            this.sectionHeader('输入 / 相机', 'cam')
            if (this.openCamera) {
              Row() {
                Text('胶片曝光').fontSize(11).fontColor('#A79E8E')
                Blank()
                Text(`${this.ev > 0 ? '+' : ''}${this.ev.toFixed(1)}`).fontSize(11).fontColor(INK).padding({ bottom: 1 }).border({ width: { bottom: 1 }, color: '#443E33' })
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
              this.paramSlider('ev', this.ev, -3, 3, 0.1, '#161310', '#B4AC9C')

              Row() {
                Text('色温').fontSize(11).fontColor('#A79E8E')
                Text(' RAW').fontSize(9).fontColor(DIM)
                Blank()
                Text(`${this.temperature.toFixed(0)}K`).fontSize(11).fontColor(INK).padding({ bottom: 1 }).border({ width: { bottom: 1 }, color: '#443E33' })
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
              this.paramSlider('temperature', this.temperature, 2500, 10000, 50, '#1B2A3E', '#4A3F26')

              Row() {
                Text('色调').fontSize(11).fontColor('#A79E8E')
                Blank()
                Text(this.tint.toFixed(2))
                  .fontSize(11).fontColor(INK)
                  .padding({ bottom: 1 })
                  .border({ width: { bottom: 1 }, color: '#443E33' })
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
              this.paramSlider('tint', this.tint, 0.5, 2, 0.01, '#2E4232', '#4E2B3D')

              Row() {
                Text('镜头校正').fontSize(11).fontColor('#A79E8E')
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.lensCorrection })
                  .selectedColor(ACCENT)
                  .onChange((on: boolean) => {
                    this.lensCorrection = on;
                    this.schedulePreview();
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 4, bottom: 8 })
              this.hintLine('色温仅对 RAW 生效；JPEG/PNG 由相机白平衡决定')
            }

            Divider().color(LINE)

            // --- 印相 -----------------------------------------------------
            this.sectionHeader('印相', 'print')
            if (this.openPrint) {
              Row() {
                Text('印相曝光').fontSize(11).fontColor('#A79E8E')
                Blank()
                Text(`${this.printEv > 0 ? '+' : ''}${this.printEv.toFixed(1)} EV`)
                  .fontSize(11).fontColor(INK)
                  .padding({ bottom: 1 })
                  .border({ width: { bottom: 1 }, color: '#443E33' })
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
              this.paramSlider('printEv', this.printEv, -2, 2, 0.1, '#161310', '#B4AC9C')

              // 配光: balance the enlarger head for this photograph.
              Row({ space: 8 }) {
                Text(this.filtersSolved
                  ? `滤镜组 Y${this.filterY.toFixed(0)} M${this.filterM.toFixed(0)}`
                  : '滤镜组：未配光')
                  .fontSize(11)
                  .fontColor(this.filtersSolved ? '#C9BDA6' : '#8C8578')
                Blank()
                Text('配光')
                  .fontSize(11)
                  .fontColor(this.ready && !this.busy && this.sourceUri.length > 0 ? '#1A1713' : '#6E675B')
                  .backgroundColor(this.ready && !this.busy && this.sourceUri.length > 0 ? ACCENT : '#1C1915')
                  .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                  .borderRadius(5)
                  .onClick(() => { this.solveFilters(); })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 6 })

              Row() {
                Text('颗粒').fontSize(11).fontColor('#A79E8E')
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.grain })
                  .selectedColor(ACCENT)
                  .onChange((on: boolean) => {
                    this.grain = on;
                    this.schedulePreview();
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 2 })

              Row() {
                Text('光晕').fontSize(11).fontColor('#A79E8E')
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.halation })
                  .selectedColor(ACCENT)
                  .onChange((on: boolean) => {
                    this.halation = on;
                    this.schedulePreview();
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 2 })

              Row() {
                Text('镜晕').fontSize(11).fontColor('#A79E8E')
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.glare })
                  .selectedColor(ACCENT)
                  .onChange((on: boolean) => {
                    this.glare = on;
                    this.schedulePreview();
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 2, bottom: 8 })
            }

            Divider().color(LINE)

            // --- 画面 -----------------------------------------------------
            this.sectionHeader('画面', 'frame')
            if (this.openFrame) {
              Row() {
                Text('直扫负片').fontSize(11).fontColor('#A79E8E')
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.scanFilm })
                  .selectedColor(ACCENT)
                  .onChange((on: boolean) => {
                    this.scanFilm = on;
                    this.schedulePreview();
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 6, bottom: 8 + px2vp(this.safeBottomPx) })
              this.hintLine('画幅与片边在左栏')
            }

            Divider().color(LINE)

            // --- 后期 -----------------------------------------------------
            this.sectionHeader('后期', 'post')
            if (this.openPost) {
              Row() {
                Text('对比度').fontSize(11).fontColor('#A79E8E')
                Blank()
                Text(this.postContrast.toFixed(2)).fontSize(11).fontColor(INK).padding({ bottom: 1 }).border({ width: { bottom: 1 }, color: '#443E33' })
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
              this.paramSlider('postContrast', this.postContrast, -1, 1, 0.05, '#141210', '#A8A093')

              Row() {
                Text('饱和度').fontSize(11).fontColor('#A79E8E')
                Blank()
                Text(this.postSaturation.toFixed(2)).fontSize(11).fontColor(INK).padding({ bottom: 1 }).border({ width: { bottom: 1 }, color: '#443E33' })
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
              this.satSlider(this.postSaturation)

              Row() {
                Text('白场').fontSize(11).fontColor('#A79E8E')
                Blank()
                Text(this.postWhites.toFixed(2)).fontSize(11).fontColor(INK).padding({ bottom: 1 }).border({ width: { bottom: 1 }, color: '#443E33' })
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
              this.paramSlider('postWhites', this.postWhites, -1, 1, 0.05, '#141210', '#C4BCAC')

              Row() {
                Text('黑场').fontSize(11).fontColor('#A79E8E')
                Blank()
                Text(this.postBlacks.toFixed(2)).fontSize(11).fontColor(INK).padding({ bottom: 1 }).border({ width: { bottom: 1 }, color: '#443E33' })
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
              this.paramSlider('postBlacks', this.postBlacks, -1, 1, 0.05, '#0E0D0B', '#6A6357')
            }

            Divider().color(LINE)

            // --- 文件 -----------------------------------------------------
            Column({ space: 8 }) {
              Row({ space: 6 }) {
                Button('LUT').fontSize(11).height(30).layoutWeight(1)
                  .backgroundColor('#1C1915').fontColor('#C9BDA6').type(ButtonType.Normal).borderRadius(5)
                  .enabled(this.ready && !this.busy && this.films.length > 0)
                  .onClick(() => { this.exportLut(); })
                Button('存预设').fontSize(11).height(30).layoutWeight(1)
                  .backgroundColor('#1C1915').fontColor('#C9BDA6').type(ButtonType.Normal).borderRadius(5)
                  .enabled(this.ready && !this.busy && this.films.length > 0)
                  .onClick(() => { this.savePreset(); })
              }
              .width('100%')

              Row({ space: 6 }) {
                Button('载入预设').fontSize(11).height(30).layoutWeight(1)
                  .backgroundColor('#1C1915').fontColor('#C9BDA6').type(ButtonType.Normal).borderRadius(5)
                  .enabled(this.ready && !this.busy)
                  .onClick(() => { this.loadPreset(); })
                if (this.presetJson.length > 0) {
                  Button('清除预设').fontSize(11).height(30).layoutWeight(1)
                    .backgroundColor('#0E0C0A').fontColor(MUTED).type(ButtonType.Normal).borderRadius(5)
                    .onClick(() => { this.clearPreset(); })
                }
              }
              .width('100%')

              Text(`engine ${this.engineVersion}`).fontSize(9).fontColor('#3E3A33')

              Text('spektrafilm by Andrea Volpato · CC BY-SA 4.0 · port of negs · GPL-3.0')
                .fontSize(9).fontColor('#3E3A33')
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 16 + px2vp(this.safeBottomPx) })
          }
          .width('100%')
          // Keeps controls off the screen edge: the panel is the last thing on
          // the right, and a flush slider reads as a clipped one.
          .padding({ right: 14 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width(this.rightW)
      .height('100%')
      .backgroundColor(PANEL)
      .border({ width: { left: 1 }, color: LINE })
    }
      .width('100%')
      .height('100%')
      .backgroundColor('#0B0A08')
      // Only the top is inset: the panels and the bottom bar have to run all the
      // way down so their backgrounds reach the screen edge instead of stopping
      // at a band of another colour. Each panel applies its own bottom inset.
      .padding({ top: px2vp(this.safeTopPx) })

      this.exportDialog()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B0A08')
  }
}

/**
 * 关于: licence and privacy, shown as a centred dialog rather than a separate
 * page. Two reasons it lives here — a dialog keeps the current photo on screen
 * behind it, and GPL-3.0 only asks that the source be reachable, not that it
 * interrupt the work.
 */
@CustomDialog
struct AboutDialog {
  controller?: CustomDialogController;
  @State tab: number = 0;

  @Builder
  tabButton(label: string, index: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.tab === index ? '#1A1713' : '#A79E8E')
      .backgroundColor(this.tab === index ? '#C9A227' : '#1C1915')
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(6)
      .onClick(() => { this.tab = index; })
  }

  build() {
    Column() {
      Row() {
        Text('关于').fontSize(16).fontColor('#EDE6D8').fontWeight(FontWeight.Medium)
        Blank()
        Text('关闭')
          .fontSize(12)
          .fontColor('#A79E8E')
          .padding({ left: 10, right: 4, top: 4, bottom: 4 })
          .onClick(() => { this.controller?.close(); })
      }
      .width('100%')
      .padding({ bottom: 12 })

      Row({ space: 8 }) {
        this.tabButton('开源许可', 0)
        this.tabButton('隐私声明', 1)
        Blank()
      }
      .width('100%')
      .padding({ bottom: 10 })

      Scroll() {
        Column({ space: 8 }) {
          if (this.tab === 0) {
            Text('光谱工坊 1.0.0').fontSize(13).fontColor('#C9BDA6').width('100%')
            Text('本应用以 GNU General Public License v3.0 分发。')
              .fontSize(12).fontColor('#A79E8E').width('100%')
            Text('引擎移植自 JamesQiu2005/SpektraLab（GPL-3.0），界面与 native 桥接为本项目新增，同样以 GPL-3.0 发布。')
              .fontSize(12).fontColor('#A79E8E').width('100%')
            Text('本应用源码：https://github.com/Crimson-Jan/spektra-workshop')
              .fontSize(12).fontColor('#C9A227').width('100%')
            Text('完整的 GPL-3.0 文本随源码仓库一同提供。您有权获取、修改并以相同许可证再分发本软件的源码。')
              .fontSize(12).fontColor('#A79E8E').width('100%')
          } else {
            Text('图像处理全部在本机完成').fontSize(13).fontColor('#C9BDA6').width('100%')
            Text('本应用不会将您的照片、编辑参数或任何使用数据上传至服务器。所有显影、配光与导出运算都在设备本地执行。')
              .fontSize(12).fontColor('#A79E8E').width('100%')
            Text('文件访问').fontSize(13).fontColor('#C9BDA6').width('100%')
            Text('应用通过系统文件选择器读取您主动选择的照片，不申请相册读取权限，也不会访问您未选择的文件。')
              .fontSize(12).fontColor('#A79E8E').width('100%')
            Text('数据收集').fontSize(13).fontColor('#C9BDA6').width('100%')
            Text('不收集设备标识符、位置信息、联系人或其他个人信息，不含任何统计或广告 SDK。')
              .fontSize(12).fontColor('#A79E8E').width('100%')
            Text('导出文件').fontSize(13).fontColor('#C9BDA6').width('100%')
            Text('导出的图片保存在您指定的本地目录，应用不保留副本。')
              .fontSize(12).fontColor('#A79E8E').width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(300)
      .scrollBar(BarState.Auto)
    }
    .width(560)
    .padding(20)
    .backgroundColor('#141210')
    .borderRadius(14)
    .border({ width: 1, color: '#2E2A22' })
    .alignItems(HorizontalAlign.Start)
  }
}
