MacBook Touch Bar 的“开发设计规范”主要来自两部分：

1. **Apple HIG（Human Interface Guidelines）：Design for the Touch Bar**
2. **AppKit 开发模型：`NSTouchBar` / `NSTouchBarItem`**

> 注：Touch Bar 已从 2021 年起逐步退出 MacBook Pro 产品线，2023 年后新 Mac 基本不再有。规范现在主要用于维护老项目或做历史/兼容开发。

------

## 一、核心定位：它是“输入设备”，不是第二块屏幕

Apple 明确强调：

- Touch Bar 技术上是一块 Retina 屏，但**应被当作键盘/触控板的延伸**

- 用户注意力应在主屏幕，不在 Touch Bar

- 不要

  放：

  - 弹窗 / Alert
  - 通知 / 消息
  - 滚动内容
  - 纯展示型静态内容
  - Widget / 状态看板

> “Don’t show alerts in the Touch Bar, and don’t use the Touch Bar for widgets.”

------

## 二、内容设计原则（HIG）

### 1. 情境化（Contextual）

Touch Bar 里只放**和当前主屏任务相关**的控件：

- 写文档 → 字体、加粗、颜色
- 看照片 → 滤镜、裁剪、旋转
- 剪视频 → 分割、标记、时间轴缩放

### 2. 快捷化

提供“比菜单/快捷键更快一步”的操作，而不是重复已有功能。

❌ 不建议做：

- 复制 / 粘贴 / 撤销 / 保存 / 打印 / 退出
- Page Up / Page Down 这类已有键位导航

✅ 适合做：

- 格式刷
- 颜色选择
- 媒体播放控制
- 快速标记 / 标签
- 内容浏览（Scrubber）

### 3. 主屏必须有等价操作

不是所有 Mac 都有 Touch Bar，用户也可能关掉 App 的 Touch Bar 控件。

> 任何 Touch Bar 能做的事，主屏/菜单/快捷键也要能做。

### 4. 状态一致

主屏按钮 disabled，Touch Bar 里也得 disabled；主屏选中，Touch Bar 也得选中。

### 5. 任务尽量在 Touch Bar 内完成

如果在 Touch Bar 里开始一个操作，就别逼用户马上切回主屏继续。

------

## 三、视觉与交互规范

### 布局

- 物理分辨率约 **2170 × 60 px**
- 逻辑尺寸约 **1085 × 30 pt**
- 右侧是系统 Control Strip（亮度/音量/Siri 等）
- App 区域在 Control Strip 左边
- 右侧还有 Touch ID（不能当普通按钮用）

### 颜色

- 优先用 macOS 系统色（`NSColor` 系统语义色）
- 外观接近物理键盘：**单色、克制**
- 蓝色：默认可交互
- 红色：危险/不可逆操作
- 支持 P3 广色域，但别花哨

### 动画

- **尽量避免动画**
- Touch Bar 是键盘延伸，用户对“键盘上动起来”没预期

### 手势

支持：

- 点按
- 水平滑动
- 长按（弹出二级操作）
- NSScrubber 浏览

谨慎使用：

- 多指手势 / 捏合（空间小、易误触）

### 可访问性

- 每个控件都要有 **accessibility label**
- VoiceOver 用户靠标签理解 Touch Bar 控件
- 自定义视图也要补 accessibility 信息

------

## 四、开发模型（AppKit）

Touch Bar 不是“检测硬件后再写一套 UI”，而是：

```
Responder Chain → makeTouchBar() → NSTouchBar → NSTouchBarItem
```

### 关键点

- 不需要判断“这台 Mac 有没有 Touch Bar”
- 系统在支持的设备上自动显示
- 不支持的设备：主屏 UI 完全不受影响

### 常见类

- `NSTouchBar`：一整条 bar
- `NSTouchBarItem`：单个控件容器
- `NSButtonTouchBarItem`：按钮
- `NSSliderTouchBarItem`：滑块
- `NSPopoverTouchBarItem`：弹出二级 bar
- `NSColorPickerTouchBarItem`：颜色
- `NSScrubber`：横向内容浏览器
- `NSGroupTouchBarItem`：分组
- `NSCandidateListTouchBarItem`：输入法候选词

### 典型实现

```
override func makeTouchBar() -> NSTouchBar? {
    let bar = NSTouchBar()
    bar.defaultItemIdentifiers = [
        .addNote,
        .flexibleSpace,
        .colorPicker,
        .scrubber
    ]
    return bar
}
```

### 自定义

- 用户可添加 / 删除 / 重排 App 的 Touch Bar 项目
- 用：
  - `customizationIdentifier`
  - `customizationAllowedItemIdentifiers`
  - `principalItemIdentifier`
- 常用功能给默认值，但允许用户改

------

## 五、设计/开发检查清单

做 Touch Bar 功能时可以照这个过一遍：

- [ ] 是否和当前上下文相关？
- [ ] 主屏有没有等价操作？
- [ ] 是不是在重复系统快捷键？
- [ ] 有没有放 alert / 通知 / 静态展示？
- [ ] 控件状态是否和主屏同步？
- [ ] 是否用了标准控件/系统图标？
- [ ] 颜色是否克制？
- [ ] 有没有不必要的动画？
- [ ] VoiceOver 标签是否完整？
- [ ] 用户能否自定义？
- [ ] 空间变小时布局是否还能用？

------

## 六、官方资料

- AppKit Touch Bar API 
  https://developer.apple.com/documentation/AppKit/touch-bar
- NSTouchBar 
  https://developer.apple.com/documentation/appkit/nstouchbar
- Creating and Customizing the Touch Bar 
  https://developer.apple.com/library/content/samplecode/NSTouchBarCatalog/Introduction/Intro.html