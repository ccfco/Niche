import SwiftUI

/// 空态/异常态(spec §4.1.1 卷卸载、§4.1 TCC 拒绝、§4.1.2 iCloud 占位)。
struct EmptyStateView: View {
    enum Kind: Equatable {
        case noFolders                 // 首次运行/未绑定任何文件夹,引导添加(spec §4.1 首启引导)
        case empty
        case permissionDenied          // TCC 被拒,需引导授权(spec §4.1.1 失败即引导)
        case volumeUnmounted(String)   // 绑定目录整卷卸载
        case loading
    }

    let kind: Kind
    /// 主动作回调(noFolders → 添加文件夹;permissionDenied → 授权并重试)。
    var onAuthorize: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            if let buttonTitle, let onAuthorize {
                Button(buttonTitle, action: onAuthorize)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch kind {
        case .noFolders: return "folder.badge.plus"
        case .empty: return "tray"
        case .permissionDenied: return "lock.shield"
        case .volumeUnmounted: return "externaldrive.badge.xmark"
        case .loading: return "hourglass"
        }
    }

    private var title: String {
        switch kind {
        case .noFolders: return "还没有绑定文件夹"
        case .empty: return "此文件夹为空"
        case .permissionDenied: return "需要访问授权"
        case let .volumeUnmounted(name): return "卷「\(name)」已卸载"
        case .loading: return "载入中…"
        }
    }

    /// 主动作按钮文案(仅 noFolders / permissionDenied 有按钮)。
    private var buttonTitle: String? {
        switch kind {
        case .noFolders: return "添加文件夹"
        case .permissionDenied: return "点此授权并重试"
        case .empty, .volumeUnmounted, .loading: return nil
        }
    }
}
