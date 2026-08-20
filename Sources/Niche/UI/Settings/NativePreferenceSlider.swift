import AppKit
import SwiftUI

/// macOS 原生连续刻度滑杆：tick 只提供参考档位，不强制吸附；外观与面板底栏 Slider
/// 同属系统控件，在 macOS 26/27 自动获得当前 Liquid Glass 样式。
struct NativePreferenceSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tickCount: Int = 5
    var accessibilityLabel: String
    var accessibilityValue: String
    var onEditingEnded: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FinalizingNSSlider {
        let slider = FinalizingNSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        slider.numberOfTickMarks = max(0, tickCount)
        slider.allowsTickMarkValuesOnly = false
        slider.tickMarkPosition = .below
        slider.controlSize = .small
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.presentedAccessibilityValue = accessibilityValue
        slider.onEditingEnded = { context.coordinator.editingEnded() }
        return slider
    }

    func updateNSView(_ slider: FinalizingNSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.numberOfTickMarks = max(0, tickCount)
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.presentedAccessibilityValue = accessibilityValue
        slider.onEditingEnded = { context.coordinator.editingEnded() }
        if abs(slider.doubleValue - value) > 0.000_1 {
            slider.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var parent: NativePreferenceSlider

        init(parent: NativePreferenceSlider) { self.parent = parent }

        @objc func valueChanged(_ sender: NSSlider) {
            parent.value = sender.doubleValue
        }

        func editingEnded() { parent.onEditingEnded() }
    }
}

final class FinalizingNSSlider: NSSlider {
    var onEditingEnded: (() -> Void)?
    /// 只覆盖 VoiceOver 读取值。不能调用 setAccessibilityValue：NSSlider 会把传入字符串
    /// 当作真实 control value 反写并发送 action，对数映射滑杆因此会静默漂移偏好。
    var presentedAccessibilityValue: String?

    override func accessibilityValue() -> Any? {
        presentedAccessibilityValue ?? super.accessibilityValue()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onEditingEnded?()
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        onEditingEnded?()
    }
}

/// 设置 Form 中统一的“标题 + 当前值 + 原生滑杆 + 语义端点”排版。
struct PreferenceSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tickCount: Int = 5
    let minimumLabel: String
    let maximumLabel: String
    var onEditingEnded: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: EdgeMetrics.standard.innerSpacing) {
            HStack {
                Text(title)
                Spacer(minLength: EdgeMetrics.standard.itemSpacing)
                Text(valueText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            NativePreferenceSlider(
                value: $value,
                range: range,
                tickCount: tickCount,
                accessibilityLabel: title,
                accessibilityValue: valueText,
                onEditingEnded: onEditingEnded
            )
            HStack {
                Text(minimumLabel)
                Spacer()
                Text(maximumLabel)
            }
            .settingsCaption()
        }
        .padding(.vertical, EdgeMetrics.standard.badgeInset)
    }
}
