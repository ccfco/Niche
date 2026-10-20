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
}