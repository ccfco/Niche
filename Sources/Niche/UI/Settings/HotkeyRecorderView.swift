import SwiftUI
import AppKit

/// 快捷键录制控件:点击进入录制态,捕获下一次按键组合(必须含 ⌘/⌃/⌥ 任一),Esc 取消。
/// 系统无公开的录制控件,自建:设置窗是普通可激活窗口,局部 keyDown monitor 在录制态
/// 抓键即可;无效组合(裸键/纯 ⇧)吞掉不退出录制,等用户按出有效组合。
struct HotkeyRecorderView: View {
    @Binding var hotkey: HotkeyPreference
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "按下新快捷键…" : hotkey.display)
                    .frame(minWidth: 120)
            }
            .help(isRecording ? "按 Esc 取消" : "点击后按下新的快捷键组合(需含 ⌘/⌃/⌥)")
            if hotkey != .default {
                Button("还原默认") { hotkey = .default }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopRecording() }   // 窗口关了别让监听器泄漏挂着吞全局按键
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {   // Esc 取消录制
                stopRecording()
                return nil
            }
            guard let captured = HotkeyPreference.from(event: event) else {
                return nil   // 无效组合(缺修饰键):吞掉,停留在录制态
            }
            hotkey = captured
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
