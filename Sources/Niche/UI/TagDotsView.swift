import SwiftUI

/// 文件名旁的「叠层标签色点」—— 复刻 Finder:多个标签时圆点水平错位重叠,白描边 + 微阴影显立体。
///
/// 颜色取自共享 [TagPalette];非标准标签(用户自建/改名)落灰点,不臆造、也不静默丢。
/// 最多显 3 个(Finder 同上限),超出不再堆叠(视觉糊成一团,且 3 个已足够区分)。
struct TagDotsView: View {
    let tags: [String]
    var diameter: CGFloat = 9

    var body: some View {
        // 负间距 → 圆点错位重叠;HStack 后绘的点压在前点右缘上方,白描边把两点分开 → 立体层叠。
        HStack(spacing: -diameter * 0.42) {
            ForEach(Array(tags.prefix(3).enumerated()), id: \.offset) { _, name in
                Circle()
                    .fill(Color(nsColor: TagPalette.color(for: name) ?? TagPalette.fallback))
                    .overlay(Circle().strokeBorder(.white, lineWidth: diameter * 0.11))
                    .frame(width: diameter, height: diameter)
                    .shadow(color: .black.opacity(0.18), radius: 0.4, y: 0.3)
            }
        }
        .accessibilityHidden(true)   // 标签语义不靠这排点传达,避免 VoiceOver 重复
    }
}
