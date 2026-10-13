import Foundation

/// 新建文件夹时的默认名:和旧启动台一样按 App 分类(LSApplicationCategoryType)起名。
public enum FolderNaming {
    public static let utilitiesName = "其他"
    public static let fallbackName = "未命名文件夹"

    private static let names: [String: String] = [
        "business": "商务",
        "developer-tools": "开发工具",
        "education": "教育",
        "entertainment": "娱乐",
        "finance": "财务",
        "games": "游戏",
        "graphics-design": "图形与设计",
        "healthcare-fitness": "健康健美",
        "lifestyle": "生活",
        "medical": "医疗",
        "music": "音乐",
        "news": "新闻",
        "photography": "摄影",
        "productivity": "效率",
        "reference": "参考",
        "social-networking": "社交",
        "sports": "体育",
        "travel": "旅游",
        "utilities": "工具",
        "video": "视频",
        "weather": "天气",
    ]

    /// 依次看各 App 的分类,第一个认得的就用它。
    public static func name(forCategories categories: [String?]) -> String {
        for category in categories.compactMap({ $0 }) {
            if let name = name(forCategory: category) { return name }
        }
        return fallbackName
    }

    static func name(forCategory category: String) -> String? {
        let key = category.lowercased()
            .replacingOccurrences(of: "public.app-category.", with: "")
        if let name = names[key] { return name }
        // 游戏有很多子类:public.app-category.action-games 等
        return key.hasSuffix("-games") ? names["games"] : nil
    }
}
