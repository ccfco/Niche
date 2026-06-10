import AppKit
import Carbon.HIToolbox

/// 全局快捷键兜底呼出(spec §4.2:全局快捷键兜底)。用 Carbon RegisterEventHotKey —— 这是
/// 注册系统级热键的标准且无需辅助功能授权的途径(NSEvent 全局监听需 AX 授权,更重)。
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onTrigger: (() -> Void)?

    /// 默认 ⌃⌥⌘Space(具体值/展示文案收口 HotkeyPreference.default)。keyCode 49 = Space。
    /// **不能用 ⌥⌘Space**:那是系统 symbolic hotkey 65「Show Finder search window」(默认启用),
    /// 系统级 symbolic hotkey 优先于 RegisterEventHotKey,会把热键抢走、面板出不来(实测确认)。
    /// 也避开 ⌃⌘Space(emoji 选择器)。热键是兜底,主触发是刘海热区。
    /// 返回是否注册成功(自定义快捷键可能撞系统占用,失败必须可见,由调用方回退提示)。
    @discardableResult
    func register(keyCode: UInt32 = 49,
                  modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)) -> Bool {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async { hotkey.onTrigger?() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)
        guard installStatus == noErr else {
            Log.window.error("全局快捷键事件处理器安装失败:\(installStatus)")
            handlerRef = nil
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E494348) /* 'NICH' */, id: 1)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            Log.window.error("全局快捷键注册失败:\(registerStatus)")
            unregister()   // 回滚已装的 handler,避免半注册状态
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    deinit { unregister() }
}
