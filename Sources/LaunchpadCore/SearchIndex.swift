import Foundation

/// 把名称拆成「词」:每个汉字一词(转成拼音,多音字给出全部读音),连续字母数字一词。
enum Pinyin {
    struct Token: Equatable {
        /// 候选读音;非汉字词只有一个
        let readings: [String]
        let isHan: Bool

        var text: String { readings[0] }
    }

    /// 系统转写不看上下文(「音乐」会转成 yin le),常见多音字补上其他读音
    static let polyphones: [Character: [String]] = [
        "乐": ["le", "yue"], "行": ["xing", "hang"], "长": ["chang", "zhang"], "重": ["zhong", "chong"],
        "调": ["tiao", "diao"], "会": ["hui", "kuai"], "还": ["huan", "hai"], "和": ["he", "huo", "hu"],
        "藏": ["cang", "zang"], "传": ["chuan", "zhuan"], "地": ["di", "de"], "得": ["de", "dei"],
        "都": ["du", "dou"], "角": ["jiao", "jue"], "区": ["qu", "ou"], "便": ["bian", "pian"],
        "卡": ["ka", "qia"], "着": ["zhe", "zhao", "zhuo"], "车": ["che", "ju"], "参": ["can", "shen"],
        "曾": ["zeng", "ceng"], "差": ["cha", "chai"], "朝": ["chao", "zhao"], "大": ["da", "dai"],
        "单": ["dan", "shan"], "弹": ["tan", "dan"], "解": ["jie", "xie"], "系": ["xi", "ji"],
        "校": ["xiao", "jiao"], "省": ["sheng", "xing"], "盛": ["sheng", "cheng"], "期": ["qi", "ji"],
        "奇": ["qi", "ji"], "度": ["du", "duo"], "了": ["le", "liao"], "没": ["mei", "mo"],
        "模": ["mo", "mu"], "屏": ["ping", "bing"], "色": ["se", "shai"], "提": ["ti", "di"],
        "血": ["xue", "xie"], "载": ["zai"], "转": ["zhuan"], "空": ["kong"], "数": ["shu"],
        "银": ["yin"], "薄": ["bao", "bo"], "降": ["jiang", "xiang"], "秘": ["mi", "bi"],
    ]

    static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        func flushWord() {
            if !word.isEmpty { tokens.append(Token(readings: [word.lowercased()], isHan: false)) }
            word = ""
        }
        for character in text {
            if isHan(character) {
                flushWord()
                tokens.append(Token(readings: readings(of: character), isHan: true))
            } else if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                flushWord()
            }
        }
        flushWord()
        return tokens
    }

    static func readings(of character: Character) -> [String] {
        ([syllable(of: character)] + (polyphones[character] ?? [])).filter { !$0.isEmpty }.uniqued()
    }

    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2EBEF: true
            default: false
            }
        }
    }

    static func syllable(of character: Character) -> String {
        let latin = NSMutableString(string: String(character))
        CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripDiacritics, false)
        return (latin as String).lowercased().filter { $0.isLetter }
    }

    /// 每个词取一种写法拼起来,枚举全部组合(上限 `limit` 种,防多音字组合爆炸)
    static func combinations(_ tokens: [Token], limit: Int = 32, _ form: (Token, String) -> String) -> [String] {
        tokens.reduce([""]) { partial, token in
            let pieces = token.readings.map { form(token, $0) }
            return Array(partial.lazy.flatMap { prefix in pieces.map { prefix + $0 } }.prefix(limit))
        }
    }
}

/// 启动台搜索:名称、英文名、全拼、首字母都能命中。
/// 「微信」可用 微 / weixin / wx 搜到,「Microsoft Word」可用 word / mw 搜到。
public struct SearchIndex: Sendable {
    struct Entry: Sendable {
        let appID: String
        let name: String
        let nameWords: [String]
        let bundleName: String
        /// 全拼、首字母、「字母词保留 + 汉字取首字母」三种写法,多音字各有多个变体
        let spellings: [String]
    }

    private let entries: [Entry]
    private let rank: [String: Int]

    /// 拼音转写较贵,只在 App 列表变化时建一次;排列变了用 `reordered(by:)` 换排序即可。
    /// - Parameter order: App id 的显示顺序,分数相同时按它排。
    public init(apps: [AppEntry], order: [String]) {
        entries = apps.map { app in
            let tokens = Pinyin.tokens(of: app.name)
            return Entry(
                appID: app.id,
                name: app.name.lowercased(),
                nameWords: tokens.filter { !$0.isHan }.map(\.text),
                bundleName: (app.bundleName ?? "").lowercased(),
                spellings: Self.spellings(of: tokens)
            )
        }
        rank = Self.rank(of: order)
    }

    private init(entries: [Entry], rank: [String: Int]) {
        self.entries = entries
        self.rank = rank
    }

    /// 同一批 App、新的显示顺序
    public func reordered(by order: [String]) -> SearchIndex {
        SearchIndex(entries: entries, rank: Self.rank(of: order))
    }

    private static func rank(of order: [String]) -> [String: Int] {
        Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 返回命中的 App id,按相关度、再按显示顺序排序。
    public func search(_ query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let compact = needle.filter { !$0.isWhitespace }
        return entries
            .compactMap { entry in Self.score(entry, needle: needle, compact: compact).map { (entry, $0) } }
            .sorted { lhs, rhs in
                guard lhs.1 == rhs.1 else { return lhs.1 > rhs.1 }
                return (rank[lhs.0.appID] ?? .max, lhs.0.appID) < (rank[rhs.0.appID] ?? .max, rhs.0.appID)
            }
            .map(\.0.appID)
    }

    static func spellings(of tokens: [Pinyin.Token]) -> [String] {
        let full = Pinyin.combinations(tokens) { _, reading in reading }
        let initials = Pinyin.combinations(tokens) { _, reading in String(reading.prefix(1)) }
        let mixed = Pinyin.combinations(tokens) { token, reading in token.isHan ? String(reading.prefix(1)) : reading }
        return (full + initials + mixed).filter { !$0.isEmpty }.uniqued()
    }

    static func score(_ entry: Entry, needle: String, compact: String) -> Int? {
        if entry.name == needle { return 100 }
        if entry.name.hasPrefix(needle) { return 90 }
        if entry.nameWords.contains(where: { $0.hasPrefix(compact) }) { return 80 }
        if !entry.bundleName.isEmpty && entry.bundleName.hasPrefix(needle) { return 75 }
        if entry.spellings.contains(where: { $0.hasPrefix(compact) }) { return 70 }
        // 单个字母的「包含」命中太多,只认前缀;单个汉字照常
        guard compact.count >= 2 || !compact.allSatisfy(\.isASCII) else { return nil }
        if entry.name.contains(needle) { return 60 }
        if !entry.bundleName.isEmpty && entry.bundleName.contains(needle) { return 55 }
        if entry.spellings.contains(where: { $0.contains(compact) }) { return 50 }
        return nil
    }
}
