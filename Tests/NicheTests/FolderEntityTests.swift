import Testing
@testable import Niche

@Suite("FolderEntity 映射")
struct FolderEntityTests {
    @Test("身份取绑定 UUID,展示名取用户别名")
    func mapsBindingIdentityAndAlias() {
        let binding = FolderBinding(path: "/tmp/Design", displayName: "设计稿")
        let entity = FolderEntity(binding: binding)

        #expect(entity.id == binding.id.uuidString)
        #expect(entity.name == "设计稿")
        #expect(entity.path == "/tmp/Design")
    }

    @Test("Spotlight 元数据沿用 tab 别名与真实路径")
    func attributeSetCarriesAliasAndPath() {
        let binding = FolderBinding(path: "/tmp/Design", displayName: "设计稿")
        let attributes = FolderEntity(binding: binding).attributeSet

        #expect(attributes.title == "设计稿")
        #expect(attributes.displayName == "设计稿")
        #expect(attributes.path == "/tmp/Design")
    }

    @Test("索引签名与 tab 排序无关")
    func signatureIgnoresOrder() {
        let a = FolderBinding(path: "/tmp/A", displayName: "A")
        let b = FolderBinding(path: "/tmp/B", displayName: "B")
        #expect(FolderIndexer.signature(for: [a, b]) == FolderIndexer.signature(for: [b, a]))
    }

    @Test("改名、改路径、增删都会改变签名")
    func signatureTracksContent() {
        var a = FolderBinding(path: "/tmp/A", displayName: "A")
        let b = FolderBinding(path: "/tmp/B", displayName: "B")
        let base = FolderIndexer.signature(for: [a])

        a.displayName = "A2"
        #expect(FolderIndexer.signature(for: [a]) != base)

        a.displayName = "A"
        a.path = "/tmp/A2"
        #expect(FolderIndexer.signature(for: [a]) != base)

        #expect(FolderIndexer.signature(for: [a, b]).contains(FolderIndexer.signature(for: [b])))
        #expect(FolderIndexer.signature(for: [a, b]) != FolderIndexer.signature(for: [a]))
    }
}