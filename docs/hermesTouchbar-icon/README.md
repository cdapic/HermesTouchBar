# Hermes Touchbar 图标 — macOS 图标交付物

源图：AI 生成的白底方形图标（Hermes 触控条角色）

## 文件清单

| 文件 | 用途 |
|---|---|
| `icon-transparent-full.png` | 透明底全尺寸原图（1254px，可直接导入 Photoshop） |
| `icon_1024x1024.png` | HIG 主尺寸（主体按 824px 居中） |
| `AppIcon.iconset/` | 全套 10 个 PNG（16→1024，含 @2x） |
| `AppIcon.icns` | macOS 应用图标包（1.3 MB） |

## 遵循的 HIG 要点

- macOS 11+ 规范：主体约占 1024 画布的 824px，已按源图主体宽度 985px 等比缩放居中。
- 透明背景，Dock 浅色/深色模式均无白边或灰圈（阴影已转半透明）。

## 生成命令（复现）

```bash
python remove_bg.py <源图> icon-transparent-full.png
# 测主体宽度（mid-row alpha 跨度）= 985
python make_iconset.py icon-transparent-full.png . --body-width 985
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

## 三种使用方式

1. **Photoshop**：直接打开 `icon-transparent-full.png`（已带 alpha 通道）。
2. **Xcode**：把 `AppIcon.iconset/` 内 10 张图拖入 Assets.xcassets 的 macOS AppIcon 槽位。
3. **替换 App 图标**：用预览打开 `icon_512x512.png` → 全选复制 → 选中目标 App → 「显示简介」→ 点左上角图标 → ⌘V 粘贴。

## 注意事项

- 源图自带圆角 squircle 造型。如需接入 Liquid Glass / Icon Composer（需要背景层 + 前景层分层源文件），需另行制作分层版本。
- App Store 上架时商店主图要求不透明背景，请用 `icon_1024x1024.png` 铺纯色底。
