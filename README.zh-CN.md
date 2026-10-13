# 启动台(Launchpad)

[English](README.md) · **中文**

[![Release](https://img.shields.io/github/v/release/zxing258974/Launchpad)](https://github.com/zxing258974/Launchpad/releases/latest) [![Downloads](https://img.shields.io/github/downloads/zxing258974/Launchpad/total)](https://github.com/zxing258974/Launchpad/releases) ![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-1f6feb) ![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

macOS 26 去掉了启动台,这是一个原生重做版:全屏 App 网格、分页、搜索、拖拽排序、文件夹,外加**自己实现的触发角**。

## 下载安装

1. 到 [Releases](https://github.com/zxing258974/Launchpad/releases) 下载最新的 `Launchpad-x.y.z.dmg`,打开后把「启动台」拖进「应用程序」(也可以下 zip 解压)。
2. 发布包没有经过苹果公证,第一次打开会被拦下:到 **系统设置 › 隐私与安全性**,在页面下方找到「启动台」,点「仍要打开」。
3. 需要 macOS 14 及以上,Apple 芯片与 Intel 通用。主要为 macOS 26(已去掉启动台)而做。

## 功能

- **打开方式**
  - 触发角:光标推到屏幕角落(默认左下角,可多选、可要求同时按住修饰键、可设停留时间防误触),再推一次收起;多显示器下只认光标真正会被「卡住」的角
  - 四指捏合(拇指和三根手指合拢)打开、张开收起,同旧启动台;经私有框架 MultitouchSupport 读触控板原始触点识别,读不到时自动不可用
  - 全局快捷键(设置里录制,默认不设)
  - 点程序坞 / 访达 / 聚焦里的「启动台」图标,或菜单栏图标
- **网格**:默认每页 7×5,可调行列和图标大小;触控板横扫、鼠标滚轮、按住空白处拖动、点页码圆点、⌘← ⌘→ 翻页
- **搜索**:打开即可直接输入;支持中文名、英文名、全拼、首字母(「微信」可用 `wx`、`weixin` 搜到,多音字如「音乐」两种读音都认);回车打开第一个结果,方向键选择
- **整理**:拖动图标排序;拖到屏幕边缘停住翻页(拖过最后一页可新开一页);压在另一个图标正中停住再松手合成文件夹(按 App 分类自动起名);点文件夹名可改名;拖出文件夹面板即移出;右键可「在访达中显示」「移出文件夹」
- **旧排列导入**:首次运行自动读取旧启动台留下的排列(含文件夹);设置里也能手动重新导入
- **外观**:背景是当前桌面壁纸的模糊版(随外观切换的动态壁纸取对应深浅帧;壁纸太亮会自动压暗保证字看得清),「降低透明度」时改用纯深色;进出场、翻页、文件夹从图标处展开都有动效,「减弱动态效果」时改为淡入淡出
- **键盘与读屏**:方向键选择(文件夹里也行)、回车打开、Tab 改文件夹名;VoiceOver 可直接打开、在访达中显示、移出文件夹、移到上一页/下一页
- **稳妥**:App 更新/重装时会短暂消失,30 分钟内回来仍在原位(跨重启有效);同 bundle id 装了多份各占各的位置
- **收起**:Esc(依次取消输入法组字 / 清空搜索 / 关文件夹 / 收起)、点空白处、打开 App、切走、锁屏;收起后前台还给原来的 App

## 构建与安装

只需要命令行工具(不需要 Xcode):

```bash
scripts/build-app.sh --install   # 编译、签名、装到 /Applications 并启动(本机架构)
scripts/package.sh               # 打发布包:通用二进制、ad-hoc 签名,输出 dist/ 下的 dmg、zip、SHA256SUMS.txt
open /Applications/Launchpad.app --args --background   # 只在后台启动、不弹出面板
scripts/test.sh                  # 跑全部测试
scripts/test.sh --coverage       # 带覆盖率
```

签名:默认 ad-hoc。想用固定证书签名,把 `Config/local.env.example` 复制为 `Config/local.env` 填上 `SIGN_IDENTITY`(该文件不入库)。

图标由 `swift scripts/make-icon.swift <输出.iconset>` 生成,再用 `iconutil -c icns` 转成 `Resources/AppIcon.icns`。

## 用前提示

- 系统设置 › 桌面与程序坞 › **触发角** 里如果同一个角还设了别的动作(macOS 15 时代设成「启动台」的那个角尤其常见),两边会同时触发,建议改成「-」。设置页会检测并提醒。
- 想开机就能用:设置 › 通用 › 登录时自动启动。
- 隐藏菜单栏图标后,在启动台里按 ⌘, 回到设置。

## 结构

```
Sources/LaunchpadCore/   纯逻辑,不依赖 UI:排列引擎、拼音搜索、热角几何与状态机、网格几何、旧库读取、App 扫描、落盘
Sources/Launchpad/
  App/        AppDelegate、设置、App 目录与图标缓存、打开 App、登录项、菜单栏
  Overlay/    全屏面板(non-activating NSPanel)与交互状态模型(点击、拖拽、文件夹、翻页、键盘)
  Input/      面板事件分发、热角监听、全局快捷键(Carbon)
  Views/      SwiftUI 视图,位置全部来自 GridMetrics,与命中判断同源
  Settings/   设置窗口与快捷键录制
Tests/LaunchpadCoreTests/   核心逻辑单测
Tests/LaunchpadAppTests/    交互测试:用假 App 目录驱动面板模型的鼠标、键盘、滚动处理
```

数据:排列存在 `~/Library/Application Support/Launchpad/layout.json`(坏了会自动备份并重建),设置在 `com.zhangxing.Launchpad` 的 UserDefaults。

## 实现要点

- 面板打开时用 `activate(ignoringOtherApps:)` 激活本 App:macOS 14 起新的 `activate()` 是协作式的,由热角/快捷键触发时会被系统拒绝(实测),不激活的话前台 App 随时能抢走键盘焦点
- 鼠标、触控板、键盘都走面板上的本地事件监听,拖拽能跨越文件夹面板的出现与消失;输入法组字中的按键一律交给输入法
- 渲染与点击命中共用 `GridMetrics`,拖拽中只有跟手的残影随鼠标重绘

## 已知限制

- 四指捏合依赖未公开的系统框架,系统大版本更新后可能失效(失效时设置里会显示不可用,其他功能不受影响)。系统自带的四指捏合(macOS 26 里打开「App」)和张开(显示桌面)要在 系统设置 › 触控板 › 更多手势 里关掉,否则会同时触发;设置页会检测并提醒。
- 不提供长按抖动删除 App(卸载请用访达)。
- 只带传统 `.icns` 图标:macOS 26 在 16/32 像素处(访达列表等)会给它套一块灰底。要去掉需用 Xcode 的 actool 编出 `Assets.car` 并在 Info.plist 加 `CFBundleIconName`,仅靠命令行工具做不到。

## 许可证

[MIT](LICENSE)

## 致谢

- 触控板原始触点的数据结构与函数签名参照 [OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport)(MIT,Copyright © 2019 Takuto Nakamura)。
