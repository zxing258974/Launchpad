import os

enum Log {
    static let app = Logger(subsystem: "com.zhangxing.Launchpad", category: "app")
    static let layout = Logger(subsystem: "com.zhangxing.Launchpad", category: "layout")
}
