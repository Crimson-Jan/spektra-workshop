# AppGallery 上架清单

最后更新：2026-11-03

## 一、已就绪

| 项 | 状态 | 位置 |
|---|---|---|
| 包名 | `com.negs.spektrafilm` | `AppScope/app.json5` |
| 版本 | `versionName 0.1.0` / `versionCode 1000000` | 同上 |
| 目标 API | target 26，compatible 12 | `build-profile.json5` |
| 架构 | arm64-v8a | 同上 |
| HAP 体积 | 57.5 MB（含 16 MB 片边素材 / 26 MB 光谱数据） | `entry/build/.../entry-default-signed.hap` |
| 权限 | **无**。选图、选文件、保存全部走系统选择器 | `module.json5` 无 `requestPermissions` |
| 应用图标 | 分层图标 1024×1024 + 商店用平面图 1024/512/216 | `AppScope/.../media/`、`appgallery/` |
| 许可证署名 | 关于页：spektrafilm (GPL-3.0 / CC BY-SA 4.0)、negs (GPL-3.0-only)、本移植、源码可得性 | `ets/pages/About.ets` |
| 隐私声明 | 关于页：全部本机计算、不联网、无统计/广告 SDK、无隐私权限 | 同上 |
| 真机验证 | MatePad Pro 12.2（MRDI-W10 / HarmonyOS 7.0.0.111 / API 26） | README「真机实测」 |

## 二、需要你提供或操作

1. **AGC 账号与应用创建**：在 AppGallery Connect 建应用，包名必须与 `com.negs.spektrafilm` 完全一致。
2. **release 签名**：现在 `build-profile.json5` 里是调试证书（`default_spektrafilm-ohos_*.p12`）。
   上架需要 AGC 下发的 release 证书 `.cer` 与 Profile `.p7b`，替换 `signingConfigs` 后重新
   `assembleHap`。调试证书不能用于商店分发。
3. **隐私政策**：应用内已有声明，但 AGC 通常还要求一个可访问的 URL。可以把关于页文案托管到任意静态页。
4. **商店文案**：应用简介、详细描述、关键词、分类（建议「摄影」）。
5. **截图**：`out/` 下已有真机截图可用（`ui-pro-6.jpeg`、`border-ui-1.jpeg`、`about-3.jpeg` 等），
   需要按 AGC 要求裁成规定比例。

## 三、已知风险

- **包体 57.5 MB**。若超限，最直接的减法是片边素材（16.2 MB）只保留常用胶片，
  或改为首次使用时从网络下载——但那会引入联网，与"不联网"的隐私声明冲突。
- **compatibleSdkVersion 是 12，但只在 API 26 设备上验证过**。API 12 的
  `getUIContext().getHostContext()`、`picker.PhotoViewPicker.save()` 行为未实测。
  保守做法是把 compatible 提到 18 或 20，减少低版本兼容风险。
- **调试证书签名**：当前签名仅适合内测分发。
- **未验证项**：LUT 导出与预设导入在真机上只走过桌面验证，UI 路径没点过。
