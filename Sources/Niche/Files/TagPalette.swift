import AppKit

/// Finder 7 个标准标签的「名称 → 显示色」单一调色板。
///
/// 右键内联色点行、网格/列表名称旁的叠层色点共用此源 —— 否则两处各自硬编码会漂移(改一处忘另一处)。
/// 颜色取 Finder 标签点的近似 sRGB(比 `systemX` 更柔,黄/灰不刺眼)。
///
/// 名称必须与系统标签名一致才能写成色标(写标签靠名字)。非标准名(用户自建/改名的标签)映射不到 →
/// 落 `fallback` 灰点(Finder 对无色自定义标签也显灰),不臆造颜色。
enum TagPalette {
    /// 有序(与 Finder 菜单同序)—— 供色点行从左到右铺设。
    static let standard: [(name: String, color: NSColor)] = [
        ("红色", NSColor(srgbRed: 0.98, green: 0.35, blue: 0.33, alpha: 1)),
        ("橙色", NSColor(srgbRed: 0.99, green: 0.65, blue: 0.25, alpha: 1)),
        ("黄色", NSColor(srgbRed: 0.97, green: 0.81, blue: 0.30, alpha: 1)),
        ("绿色", NSColor(srgbRed: 0.56, green: 0.80, blue: 0.33, alpha: 1)),
        ("蓝色", NSColor(srgbRed: 0.30, green: 0.64, blue: 0.97, alpha: 1)),
        ("紫色", NSColor(srgbRed: 0.74, green: 0.49, blue: 0.86, alpha: 1)),
        ("灰色", NSColor(srgbRed: 0.62, green: 0.63, blue: 0.65, alpha: 1)),
    ]

    /// 非标准标签的兜底色(灰)—— 自建标签虽无标准色,Finder 名称旁仍画灰点表存在,不静默吞掉。
    static let fallback = NSColor(srgbRed: 0.62, green: 0.63, blue: 0.65, alpha: 1)

    private static let byName: [String: NSColor] =
        Dictionary(uniqueKeysWithValues: standard.map { ($0.name, $0.color) })

    /// 标准名 → 标准色;非标准名 → nil(调用方决定是否落 `fallback`)。
    static func color(for name: String) -> NSColor? { byName[name] }
}
