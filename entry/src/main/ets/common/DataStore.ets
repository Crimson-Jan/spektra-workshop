/**
 * First-run extraction of the bundled spectral data.
 *
 * The Rust engine opens profiles, LUTs and border textures through `std::fs`, so
 * the data shipped in `resources/rawfile/` has to exist as real files inside the
 * app sandbox before the first render. Copying once into `filesDir/data` keeps
 * the engine untouched and keeps subsequent launches instant.
 *
 * This runs from EntryAbility, which holds a real ability context. Pages on
 * API 26 cannot obtain one — `getContext(this)` is gone, and a `getHostContext()`
 * result cast through `as` has its undefined check compiled away — so the page
 * only ever receives the resulting paths as plain strings.
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

/** Any file here means a complete extraction: it is written last. */
const MARKER = 'profiles/kodak_portra_400.json';

/** Records how many files the current extraction holds, so an app update that
 *  adds assets (border textures, new profiles) re-extracts instead of silently
 *  serving a stale tree. */
const VERSION_FILE = '.manifest-count';

export class DataStore {
  /** Absolute path to pass as `dataDir` on every native call. */
  readonly dataDir: string;

  private readonly ctx: common.UIAbilityContext;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
    this.dataDir = `${ctx.filesDir}/data`;
  }

  /** True when the sandbox already holds a complete copy. */
  isReady(): boolean {
    return fs.accessSync(`${this.dataDir}/${MARKER}`);
  }

  /**
   * `fs.mkdirSync` raises EEXIST even with the recursion flag on some builds, so
   * existence is checked first. Extraction has to be resumable anyway: a
   * half-finished first run must be able to carry on.
   */
  private ensureDir(path: string): void {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path, true);
    }
  }

  private readText(path: string): string {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
    } finally {
      fs.closeSync(file);
    }
  }

  private writeText(path: string, text: string): void {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  /**
   * Copies every file listed in `rawfile/data-manifest.json` out of the HAP into
   * the sandbox. Synchronous on purpose: it runs before the first page is
   * loaded, so the UI never renders a half-initialised state. Only the first
   * launch — and the first launch after a data change — pays the cost.
   */
  ensure(): void {
    const manifestBytes = this.ctx.resourceManager.getRawFileContentSync('data-manifest.json');
    // Strip a UTF-8 BOM defensively: TextDecoder usually removes it, but a
    // manifest rewritten by a Windows tool may carry one and JSON.parse would
    // then fail on launch.
    const manifestText = util.TextDecoder.create('utf-8')
      .decodeToString(manifestBytes)
      .replace(/^\uFEFF/, '');
    const manifest: string[] = JSON.parse(manifestText) as string[];
    const expected = `${manifest.length}`;

    const versionPath = `${this.dataDir}/${VERSION_FILE}`;
    if (this.isReady() && fs.accessSync(versionPath)) {
      if (this.readText(versionPath).trim() === expected) {
        return;
      }
      console.info('spektrafilm: data changed, re-extracting');
    }

    const started = Date.now();
    this.ensureDir(this.dataDir);

    for (const rel of manifest) {
      const dest = `${this.dataDir}/${rel}`;
      const slash = dest.lastIndexOf('/');
      if (slash > 0) {
        this.ensureDir(dest.substring(0, slash));
      }
      const bytes = this.ctx.resourceManager.getRawFileContentSync(`data/${rel}`);
      const file = fs.openSync(dest, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      } finally {
        fs.closeSync(file);
      }
    }

    this.writeText(versionPath, expected);
    console.info(`spektrafilm: extracted ${manifest.length} data files in ${Date.now() - started} ms`);
  }
}
