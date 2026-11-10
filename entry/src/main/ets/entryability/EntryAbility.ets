import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { DataStore } from '../common/DataStore';

const DOMAIN = 0x0000;
const TAG = 'Spektrafilm';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);

    // Everything that needs a real ability context happens here, because a page
    // cannot get one on API 26: `getContext(this)` is gone, and casting
    // `getUIContext().getHostContext()` through `as` makes ArkTS compile the
    // undefined check away, so undefined reaches the page unnoticed.
    // The page only ever reads plain strings out of AppStorage.
    AppStorage.setOrCreate('filesDir', this.context.filesDir);
    AppStorage.setOrCreate('cacheDir', this.context.cacheDir);
    // Needed by the page for the media-library dialog (the only API there that
    // insists on a real Context). Everything else travels as plain strings.
    AppStorage.setOrCreate('abilityContext', this.context);

    try {
      const store = new DataStore(this.context);
      store.ensure();
      AppStorage.setOrCreate('dataDir', store.dataDir);
      hilog.info(DOMAIN, TAG, 'data ready at %{public}s', store.dataDir);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'data extraction failed: %{public}s', err.message);
      AppStorage.setOrCreate('dataError', err.message);
    }

    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s', 'Content loaded');
    });

    const mainWindow = windowStage.getMainWindowSync();
    // 窗口宽度决定页面用单栏还是三栏。必须由窗口给，不能由画布自己量：
    // 画布宽度是断点的函数，用它判断会形成「收栏→变宽→跳回」的死循环。
    try {
      const rect = mainWindow.getWindowProperties().windowRect;
      AppStorage.setOrCreate('windowWidthPx', rect.width);
      AppStorage.setOrCreate('windowHeightPx', rect.height);
      mainWindow.on('windowSizeChange', (size: window.Size) => {
        AppStorage.setOrCreate('windowWidthPx', size.width);
        AppStorage.setOrCreate('windowHeightPx', size.height);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'window size probe failed: %{public}s', (e as Error).message);
    }
    // Same colour as the page background, so the icons sit on the app rather
    // than on a band of another colour.
    mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#0B0A08',
      statusBarContentColor: '#F3EFE7',
      navigationBarColor: '#0B0A08',
      navigationBarContentColor: '#F3EFE7'
    });

    // Draw the layout under both bars and hand their heights to the page: the
    // content then starts below the status bar on its own instead of the window
    // shrinking and leaving empty bands.
    mainWindow.setWindowLayoutFullScreen(true).then(() => {
      const top = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
      const bottom =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
      // Raw pixels here; the page converts with px2vp, which only exists in a
      // UI context.
      AppStorage.setOrCreate('safeTopPx', top);
      AppStorage.setOrCreate('safeBottomPx', bottom);
      hilog.info(DOMAIN, TAG, 'insets top=%{public}d bottom=%{public}d px', top, bottom);
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'full screen layout failed: %{public}s', e.message);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }
}
