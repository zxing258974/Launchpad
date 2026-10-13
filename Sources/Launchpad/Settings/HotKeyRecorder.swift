import AppKit
import SwiftUI

/// 录制快捷键:点按钮后按下组合键;Esc 取消,⌫ 清除。录制期间暂停全局快捷键,免得按下旧组合直接弹出启动台。
@MainActor
@Observable
final class HotKeyRecorderModel {
    private(set) var isRecording = false
    private(set) var hint: String?

    @ObservationIgnored var onRecordingChange: ((Bool) -> Void)?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var apply: ((KeyCombo?) -> Void)?

    func start(apply: @escaping (KeyCombo?) -> Void) {
        guard !isRecording else { return }
        self.apply = apply
        isRecording = true
        hint = nil
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers
            MainActor.assumeIsolated { self?.handle(keyCode: keyCode, modifiers: modifiers, characters: characters) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        apply = nil
        if isRecording {
            isRecording = false
            onRecordingChange?(false)
        }
    }

    private func handle(keyCode: UInt16, modifiers flags: NSEvent.ModifierFlags, characters: String?) {
        switch keyCode {
        case KeyCode.escape where flags.isEmpty:
            stop()
        case KeyCode.delete where flags.isEmpty, KeyCode.forwardDelete where flags.isEmpty:
            apply?(nil)
            stop()
        default:
            guard KeyCombo.isAcceptable(keyCode: keyCode, modifiers: flags) else {
                hint = "需要带上 ⌘、⌥ 或 ⌃(F 键可单按)"
                return
            }
            apply?(KeyCombo(
                keyCode: UInt32(keyCode),
                modifiers: flags.intersection([.command, .option, .control, .shift]).rawValue,
                keyLabel: KeyCombo.label(keyCode: keyCode, characters: characters)
            ))
            stop()
        }
    }
}

struct HotKeyRecorderView: View {
    let model: HotKeyRecorderModel
    @Binding var combo: KeyCombo?

    var body: some View {
        let canClear = combo != nil && !model.isRecording
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                recordButton
                // 始终占位,按钮出现消失时录制按钮不左右跳
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .opacity(canClear ? 1 : 0)
                .disabled(!canClear)
                .help("清除快捷键")
                .accessibilityLabel("清除快捷键")
                .accessibilityHidden(!canClear)
            }
            // 提示行一直占位,开始/结束录制时表单不上下跳
            Group {
                if let hint = model.hint, model.isRecording {
                    Label {
                        Text(hint)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                } else {
                    Text("Esc 取消 · ⌫ 清除").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .opacity(model.isRecording ? 1 : 0)
            .accessibilityHidden(!model.isRecording)
        }
        .onDisappear { model.stop() }
    }

    /// 录制中用醒目按钮;快捷键本身用等宽字,提示语不用
    @ViewBuilder
    private var recordButton: some View {
        if model.isRecording {
            Button { model.stop() } label: {
                Text("请按下快捷键…").frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button { model.start { combo = $0 } } label: {
                Group {
                    if let combo { Text(combo.display).monospaced() } else { Text("点击录制") }
                }
                .frame(minWidth: 110)
            }
            .accessibilityLabel(combo.map { "快捷键 \($0.display),点按重新录制" } ?? "录制快捷键")
        }
    }
}
