// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Launchpad",
    platforms: [.macOS(.v14)],
    targets: [
        // 纯逻辑:布局、搜索、热角几何、旧库导入、App 扫描 —— 不依赖 UI,单测覆盖
        .target(
            name: "LaunchpadCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // 私有框架 MultitouchSupport 的运行时加载封装(四指捏合手势)
        .target(name: "CMultitouch", linkerSettings: [.linkedFramework("IOKit")]),
        // AppKit + SwiftUI 外壳
        .executableTarget(
            name: "Launchpad",
            dependencies: ["LaunchpadCore", "CMultitouch"]
        ),
        .testTarget(
            name: "LaunchpadCoreTests",
            dependencies: ["LaunchpadCore"]
        ),
        // 交互层:用假 App 目录驱动面板模型的鼠标/键盘处理
        .testTarget(
            name: "LaunchpadAppTests",
            dependencies: ["Launchpad", "LaunchpadCore", "CMultitouch"]
        ),
    ]
)
