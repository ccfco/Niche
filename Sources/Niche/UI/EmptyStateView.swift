import SwiftUI

/// 空态/异常态(spec §4.1.1 卷卸载、§4.1 TCC 拒绝、§4.1.2 iCloud 占位)。
struct EmptyStateView: View {
    enum Kind: Equatable {
        case empty
        case permissionDenied          // TCC 被拒,需引导授权(spec §4.1.1 失败即引导)
        case volumeUnmounted(String)   // 绑定目录整卷卸载
        case loading
    }

    let kind: Kind
    /// "点此授权并重试"动作(仅 permissionDenied 显示)。
    var onAuthorize: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            if case .permissionDenied = kind, let onAuthorize {
                Button("点此授权并重试", action: onAuthorize)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch kind {
        case .empty: return "tray"
        case .permissionDenied: return "lock.shield"
        case .volumeUnmounted: return "externaldrive.badge.xmark"
        case .loading: return "hourglass"
        }
    }

    private var title: String {
        switch kind {
        case .empty: return "此文件夹为空"
        case .permissionDenied: return "需要访问授权"
        case let .volumeUnmounted(name): return "卷「\(name)」已卸载"
        case .loading: return "载入中…"
        }
    }
}
