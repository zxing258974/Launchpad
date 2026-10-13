import Foundation
import Testing
@testable import LaunchpadCore

@Suite("SearchIndex")
struct SearchIndexTests {
    let apps: [AppEntry] = [
        AppEntry(id: "wechat", name: "微信", bundleName: "WeChat", url: URL(fileURLWithPath: "/a")),
        AppEntry(id: "settings", name: "系统设置", bundleName: "System Settings", url: URL(fileURLWithPath: "/b")),
        AppEntry(id: "word", name: "Microsoft Word", url: URL(fileURLWithPath: "/c")),
        AppEntry(id: "qqmusic", name: "QQ音乐", url: URL(fileURLWithPath: "/d")),
        AppEntry(id: "safari", name: "Safari浏览器", bundleName: "Safari", url: URL(fileURLWithPath: "/e")),
        AppEntry(id: "netease", name: "网易云音乐", url: URL(fileURLWithPath: "/f")),
    ]

    var index: SearchIndex { SearchIndex(apps: apps, order: apps.map(\.id)) }

    @Test("中文名、全拼、首字母都能命中", arguments: [
        ("微", "wechat"), ("weixin", "wechat"), ("wx", "wechat"), ("wechat", "wechat"),
        ("xtsz", "settings"), ("xitong", "settings"), ("settings", "settings"),
        ("mw", "word"), ("word", "word"),
        ("qqyy", "qqmusic"), ("qyy", "qqmusic"), ("音乐", "qqmusic"),
        ("liulanqi", "safari"),
        ("wyyyy", "netease"), ("yunyin", "netease"), ("wangyiyun", "netease"),
    ])
    func matches(query: String, expected: String) {
        #expect(index.search(query).first == expected)
    }

    @Test("查询忽略大小写和空格")
    func normalizesQuery() {
        #expect(index.search("  WEI xin ").first == "wechat")
    }

    @Test("空查询、无命中返回空")
    func emptyResults() {
        #expect(index.search("   ").isEmpty)
        #expect(index.search("zzzz").isEmpty)
    }

    @Test("前缀命中排在包含命中前面")
    func prefixBeatsContains() {
        let apps = [
            AppEntry(id: "1", name: "Notes Helper", url: URL(fileURLWithPath: "/1")),
            AppEntry(id: "2", name: "Helper", url: URL(fileURLWithPath: "/2")),
        ]
        let results = SearchIndex(apps: apps, order: ["1", "2"]).search("help")
        #expect(results == ["2", "1"])
    }

    @Test("同分时按显示顺序排")
    func tiesFollowOrder() {
        let apps = [
            AppEntry(id: "x", name: "Alpha", url: URL(fileURLWithPath: "/x")),
            AppEntry(id: "y", name: "Alps", url: URL(fileURLWithPath: "/y")),
        ]
        #expect(SearchIndex(apps: apps, order: ["y", "x"]).search("al") == ["y", "x"])
    }

    @Test("单字母不做模糊包含匹配,避免满屏噪音")
    func singleLetterOnlyMatchesPrefixes() {
        let apps = [AppEntry(id: "x", name: "Xcode", url: URL(fileURLWithPath: "/x"))]
        #expect(SearchIndex(apps: apps, order: []).search("d").isEmpty)
        #expect(SearchIndex(apps: apps, order: []).search("od") == ["x"])
    }

    @Test("多音字给出全部读音,组合数有上限")
    func polyphones() {
        #expect(Pinyin.readings(of: "乐") == ["le", "yue"])
        #expect(Pinyin.readings(of: "微") == ["wei"])
        let tokens = Pinyin.tokens(of: "乐乐乐乐乐乐乐")
        #expect(Pinyin.combinations(tokens, limit: 8) { _, reading in reading }.count == 8)
    }

    @Test("拼音分词")
    func pinyinTokens() {
        let tokens = Pinyin.tokens(of: "QQ 音乐-2")
        #expect(tokens.map(\.text) == ["qq", "yin", "le", "2"])
        #expect(tokens.map(\.isHan) == [false, true, true, false])
    }
}
