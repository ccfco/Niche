import SwiftUI

/// 设置页占位。M5 填入:绑定文件夹管理(增删/排序)、触发位置、全局快捷键、隐藏文件默认。
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TabView {
            Text("绑定文件夹管理(M5 实现)")
                .frame(width: 460, height: 300)
                .tabItem { Label("文件夹", systemImage: "folder") }
            Text("触发与快捷键(M5 实现)")
                .frame(width: 460, height: 300)
                .tabItem { Label("触发", systemImage: "bolt") }
        }
        .frame(width: 480, height: 340)
    }
}
