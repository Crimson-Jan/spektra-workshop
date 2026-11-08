# 光谱工坊 · Spektrafilm for HarmonyOS

应用市场上架名：**光谱工坊**（包名 com.negs.spektrafilm）。

光谱胶片仿真引擎的鸿蒙原生移植。界面是 ArkUI，引擎是原样复用的 Rust 实现。

> 本项目是 [negs](https://github.com/noahhaasis/negs)（GPL-3.0-only）的衍生物，
> 而 negs 又是 [spektrafilm](https://github.com/andreavolpato/spektrafilm)
> （Andrea Volpato，GPL-3.0）的 Rust 重写。胶片/相纸 profile 与 LUT 数据由
> spektrafilm 提供，按 **CC BY-SA 4.0** 授权，见 `SPEKTRAFILM_LICENSE.txt`。

## 当前状态

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | aarch64-unknown-linux-ohos 交叉编译 + NAPI 桥接 | ✅ |
| P0 | 真机安装、启动、出图 | ✅ MatePad Pro 12.2（MRDI-W10 / HarmonyOS 7.0.0.111 / API 26） |
| P1 | ArkUI MVP：选图 / 预览 / 胶片与相纸 / 曝光 / 导出 | ✅ 真机验证 |
| P2 | 参数、预设、边框、裁剪、RAW、LUT、内存 | ✅ 除下述缺口外全部打通 |
| 许可 | GPL-3.0 + CC BY-SA 4.0 署名 | ✅ 应用内「关于」页 |
| 上架 | AppGallery | ⏳ 缺 release 证书，见 `appgallery/SUBMISSION.md` |

## 结构

```
entry/src/main/ets/pages/Index.ets      三栏界面（左：胶片/相纸/片边　中：画布　右：参数）
entry/src/main/ets/pages/About.ets      署名与隐私
entry/src/main/ets/common/DataStore.ets 首启解压光谱数据与边框素材
entry/src/main/cpp/napi_init.cpp        NAPI 桥（文件进、文件出，Rust 类型不过界）
entry/src/main/cpp/types/.../index.d.ts 原生模块类型声明（ArkTS 必须从这里 import 类型）
rust/crates/spektrafilm-ffi/src/lib.rs  C ABI：sf_render_file 等
rust/crates/spektrafilm-io/src/border.rs    边框合成
rust/crates/spektrafilm-io/src/film35.rs    35mm 胶卷条渲染器
```

## 界面

三栏暗色布局：

- **左栏**：导航缩略图、`胶片` 列表（每款带色标）、`相纸` 列表、`片边`（画幅 + 样式）。
- **中栏**：`选择照片` / `文件` / 成片·原图 / 文件名 / 耗时 / 缩放 / 测试图 / 导出，下方画布，底部状态条，
  再下面是**选片条**（缩略图 + 文件名，选中项金色描边，状态栏右侧 `▾` 可折叠）。
- **右栏**：`输入/相机`、`印相`、`画面`、`后期` 四组折叠参数，标题栏有 `关于`。

### 选片条

每张导入的照片是一个 `PhotoItem`，自带一份 `LookState` 快照（胶片、相纸、画幅、边框、
全部滑块）。切换时先把当前控件写回上一张，再套用目标那张的设置，所以每张图各留各的调色。

缩略图是**引擎真实渲染的 180 px**（`photo_long_side_px: 180`），不是原图缩放——否则选片时
看不出各自的胶片效果。渲染失败只影响缩略图，条目保留占位。

## 片边（胶片边框）

在**左栏**。`画幅` 一次同时决定裁剪比例和边框族：

| 画幅 | 裁剪 | 边框 | 形态 |
|---|---|---|---|
| 原图 | 不裁 | 跟随样式 | — |
| 135 | 3:2 横 | 35mm 条 | 齿孔在上下 |
| 半格 | 3:4 竖 | 35mm 条 | 18×24 闸口，条子不转向，齿孔在上下 |
| XPan | 65:24 | 35mm 条 | 同一胶卷拉长到 14 个齿距 |
| 645 / 6×6 / 6×7 / 6×9 / 6×17 | 4:3 / 1:1 / 7:6 / 3:2 / 17:6 | 120 边框 | 九宫格贴图，6×6 得正方形 |

下面的样式行（关 / 35mm / 120 / 白边 / 画线）可覆盖画幅给的默认值。

实现要点：

- **条子随照片转向**：`Strip::turned()` 比较闸口方向与照片方向。半格是 18×24 竖闸口，
  配竖图时条子保持水平，齿孔落在上下；配横图会转成竖条、齿孔跑到左右。
- **35mm 只接受 3:2 / 3:4 / 65:24**，其它比例引擎直接报错。ArkTS 侧 `buildBorder()`
  把不匹配的 35mm 降级为 120 边框，避免整张渲染失败。比较必须用 `max/min`（引擎口径），
  直接用宽/高会把所有竖构图判成不匹配——真机上的表现就是「半格没有边框」。
- **XPan 是对引擎的扩展**：`FilmFormat::Xpan`（65×24 mm，14×4.75 mm 长），复用同一份
  `borders/35mm/material.png` 与程序化齿孔/边字，不需要新素材。

素材体积：`data/borders` 16.2 MB，HAP 从 40.9 MB 涨到 **57.5 MB**。

### 没有的东西

- **120 的"有内容"方框**：SpektraLab 的 6×6 是带边字（FUJI 200 / 24）的方框，但 negs 的
  `borders/film.png` 只是一圈扫描的不规则黑边，没有边字。要做需另写 120 边字渲染
  （类似 35mm 的 `EdgePrint`，但不画齿孔）。
- **光圈 / 边缘灰雾 / 片轴漏光**：三个上游都没有实现（见下节）。

## 片轴漏光：原程序里没有

- **negs（Rust）**：`light_leak` / `spool` / `canister` 零命中；`BorderOptions` 只有
  `width` / `line` / `color` / `line_color`。
- **spektrafilm（Python 原版）**：181 个源文件里 `spool` 零命中，`leak` 只出现在文档字符串里。
- negs 的 `docs/35mm-scan-sources.md` 写着 "later, light leaks should be **procedural**"，
  说明是尚未实现的计划功能。

桌面版 SpektraLab 是 Tauri + Vulkan 的独立产品（引擎与 UI 都编译进 exe），没有可读源码。

## 放大机参数：测过之后没有做

`EnlargerParams` 里有对应字段，但实测不可用：

| 参数 | 设置 | 结果 |
|---|---|---|
| 基准 | — | 平均 RGB 61.8 / 59.0 / 57.8 |
| `y_filter_shift` | 2.0 | 60.7 / 58.6 / 58.7，几乎无变化 |
| `lens_blur` | 0.5 | 输出字节数与基准完全相同，空实现 |
| `preflash_exposure` | 0.03 | p05 14.9→14.2，p95 203.3→164.3，只压高光不提暗部 |

黄/品红被印相阶段的自动曝光中和；预曝光方向与"提亮暗部"相反。因此这一组没有进 UI，
`enlarger` 只保留 `print_exposure`。

## RAW / DNG

引擎按文件扩展名分派解码器，所以 RAW 只能从**文件选择器**进入（相册只索引可显示的图片）。
工具条的 `文件` 按钮走 `picker.DocumentViewPicker`，选中的文件原样复制到缓存并保留扩展名
再交给引擎——把 DNG 改名成 `.jpg` 会按 JPEG 解码然后失败。

- 桌面验证 ✅ `sample.dng` 1707×2560 → 16-bit PNG，5.73 秒
- 真机验证 ✅ 从文件管理器选中 DNG 后正常打开、耗时正常

## 画布缩放与平移

- 双指捏合 1×–8×，双击在 1× / 2× 间切换
- 工具条 `−` / `＋` 按 1.5 倍步进，点百分比数字复位
- 放大后单指拖动平移，位移按 `(zoom-1)/2 × 画布边长` 夹住
- 画布 `.clip(true)`，放大不溢出到工具条与参数面板

## 数据版本标记

`filesDir/data/.manifest-count` 记录解压的文件数。清单变化（例如新增边框素材）时自动
重新解压，避免升级后继续用旧的残缺数据树。

## 真机实测（MRDI-W10 / HarmonyOS 7 / API 26）

- 引擎版本串 ✅ `negs-0.13.0-ohos-cpu`
- 数据解压 ✅ 125 个文件，105 ms
- 目录加载 ✅ 17 款胶片 / 16 款相纸
- 测试图 1024×683 ✅ 1824 ms（桌面 x86_64 同图 1143 ms）
- 1280px 预览 ✅ 2884–2929 ms
- 全尺寸导出 ✅ 10342 ms，进程未崩、无 OOM
- RAW 导入 ✅ 正常

## 保存到相册用的是系统保存选择器

`photoAccessHelper.showAssetsCreationDialog` 需要真实的 ability `Context`，而页面在 API 26
上拿不到（Context 塞进 AppStorage 再取出来也不可用）。改用 `picker.PhotoViewPicker().save()`：
构造函数不需要 Context，弹的是同一个系统保存对话框。

## 上真机踩到的坑（都已修）

1. **页面拿不到 ability context。** `getContext(this)` 在 API 26 失效；
   `getUIContext().getHostContext() as common.UIAbilityContext` 的 `as` 会让 ArkTS 把
   `=== undefined` 判断当死代码删掉，undefined 漏进业务代码。最终方案：需要 context 的
   工作全部放在 EntryAbility，页面只通过 `AppStorage` + `@StorageProp` 拿字符串路径。
2. **`fs.mkdirSync(path, true)` 目录已存在时仍抛 EEXIST。** 必须先 `accessSync` 判断。
3. **hvigor 增量编译可能复用旧字节码。** 改了 ArkTS 行为却没变时，删掉 `entry/build`
   全量重建，并用字符串比对 `modules.abc` 确认新逻辑进去了。

## 构建

需要 `D:\DevEco Studio` 的 SDK 与 hvigor，以及本仓库内的 Rust 工具链路径：

```powershell
$env:CARGO_HOME='E:\DevEcoProjects\tools\cargo'
$env:RUSTUP_HOME='E:\DevEcoProjects\tools\rustup'
Set-Location rust
cargo build --release --offline --target aarch64-unknown-linux-ohos -p spektrafilm-ffi --lib
```

```powershell
$env:DEVECO_SDK_HOME='D:\DevEco Studio\sdk'
$env:HVIGOR_USER_HOME='E:\DevEcoProjects\tools\hvigor-home'
$env:HVIGOR_PNPM_STORE_PATH='E:\DevEcoProjects\tools\pnpm-store'
$env:npm_config_cache='E:\DevEcoProjects\tools\npm-cache'
$env:npm_config_userconfig='E:\DevEcoProjects\tools\npmrc'
Set-Location E:\DevEcoProjects\spektrafilm-ohos
& 'D:\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap --mode module -p product=default --no-daemon
```

hvigor 每次构建都会重装工具链包，因此需要完整文件与网络访问。

安装与启动：

```powershell
$hdc='D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
& $hdc install -r entry\build\default\outputs\default\entry-default-signed.hap
& $hdc shell aa start -a EntryAbility -b com.negs.spektrafilm
```

## 已知限制

- 包体 57.5 MB，其中片边素材 16.2 MB、光谱数据 26 MB。
- `compatibleSdkVersion` 写的是 12，但只在 API 26 设备上验证过。
- LUT 导出与预设导入的真机 UI 路径尚未逐个点过（引擎侧桌面验证通过）。
- 120 边框没有边字；6×6 不是带内容的方框。

## 许可

代码 GPL-3.0-only；胶片/相纸 profile 与 LUT 数据 CC BY-SA 4.0（Andrea Volpato）。
应用内「关于」页列出全部署名与源码声明。
