import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Niche

/// 缩略图路由的单一真相:媒体优先内容预览(标签点由文件名旁承担),文件夹外观/非媒体文档
/// 才走 Finder 彩色图标。
@Suite("ThumbnailCache 路由")
struct ThumbnailCacheRouteTests {
    @Test("无标签普通文档不生成内容缩略图")
    func plainUntaggedDocumentHasNoThumbnail() {
        let item = TestSupport.item("notes.txt", type: .plainText)
        #expect(ThumbnailCache.route(for: item) == .none)
    }

    @Test("带标签普通文档走 Finder 图标以保留标签色")
    func taggedDocumentUsesFinderIcon() {
        let item = TestSupport.item("notes.txt", type: .plainText, tags: ["工作"])
        #expect(ThumbnailCache.route(for: item) == .finderIcon)
    }

    @Test("带标签图片仍优先内容缩略图")
    func taggedImagePrefersContentThumbnail() {
        let item = TestSupport.item("photo.jpg", type: .jpeg, tags: ["工作"])
        #expect(ThumbnailCache.route(for: item) == .image)
    }

    @Test("带标签视频/PDF 走 QL 内容缩略图")
    func taggedMediaUsesQuickLookThumbnail() {
        #expect(ThumbnailCache.route(for: TestSupport.item("clip.mp4", type: .mpeg4Movie, tags: ["工作"])) == .quickLook)
        #expect(ThumbnailCache.route(for: TestSupport.item("doc.pdf", type: .pdf, tags: ["工作"])) == .quickLook)
    }

    @Test("带标签文件夹仍走 Finder 图标以保留文件夹染色")
    func taggedFolderUsesFinderIcon() {
        let item = TestSupport.item("Design", dir: true, type: .folder, tags: ["工作"])
        #expect(ThumbnailCache.route(for: item) == .finderIcon)
    }

    @Test("文件夹自定义外观优先于类型判断")
    func customFolderAppearanceUsesFinderIcon() {
        let item = TestSupport.item("Design", dir: true, type: .folder, sig: "symbol=star")
        #expect(ThumbnailCache.route(for: item) == .finderIcon)
    }

    @Test("dataless 一律不生成缩略图")
    func datalessNeverGenerates() {
        let item = TestSupport.item("photo.jpg", type: .jpeg, dataless: true)
        #expect(ThumbnailCache.route(for: item) == .none)
    }
}