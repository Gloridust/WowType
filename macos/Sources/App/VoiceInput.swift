// 语音输入（和 Linux 插件的 handleVoiceKey / pollVoice 一样）：
// 按下语音键开始听，按住超过 300ms 松开即结束；更短算点按，继续听到静音 1.5 秒或再按一次。
// 正在听时编辑区里是识别到一半的字，候选框里是麦克风和跟着音量动的波形；出结果就上屏。
// 说话途中按 Esc 取消；按别的键也不要这次的语音，键照常处理。正在打拼音时不抢语音键。
//
// 识别在核心里（wowtype_voice_*，开麦克风、读模型、解码都在后台线程），这里每 50 毫秒取一次状态。
// 模型在设置窗口的「语音」页下载到数据目录的 wtlocal/（VoiceModelInstaller）。

import AppKit
import AVFoundation
import Carbon
import CWowtype

/// 语音输入要在哪个输入框里显示、上屏（WowTypeInputController 实现）。
protocol VoiceHost: AnyObject {
    /// status 是候选框里的提示（nil 收起），partial 是编辑区里识别到一半的字
    func voiceShow(status: String?, partial: String)
    func voiceCommit(_ text: String)
}

final class VoiceInput {
    static let shared = VoiceInput()
    static let pollInterval: TimeInterval = 0.05

    private var handle: OpaquePointer?
    private(set) var key: VoiceKey?
    private var copyResult = false
    private var modelDir = ""
    /// 没下载模型时按下了语音键（修饰键）：松开前没按别的键才提示去下载，
    /// 免得 Option+方向键 这些常用组合每次都闪一下提示
    private var pendingHint = false
    /// 语音键按着
    private var keyDown = false
    /// 这次语音在哪个输入框里
    private weak var host: VoiceHost?
    private var showing = false
    private var timer: Timer?
    private var levels: [Int] = []
    private var frame = 0
    /// 出错或提示时留到这个时候再收起
    private var holdUntil: TimeInterval = 0

    /// 照设置配语音键；第一次要用时才建核心的语音对象（不碰麦克风、不读模型，按键时才读）。
    func configure(_ config: WowtypeConfig, modelDir: String) {
        let wanted = config.voice ? VoiceKey(name: config.voiceKey) : nil
        if wanted != key {
            if showing { cancel() }
            keyDown = false
        }
        key = wanted
        copyResult = config.voiceCopy
        self.modelDir = modelDir
        if key != nil && handle == nil {
            handle = wowtype_voice_new(modelDir)
        }
    }

    var isActive: Bool { showing }

    /// flagsChanged：语音键是修饰键（右 Option 等）时看它按下 / 松开。修饰键照样交给应用，所以不返回吃没吃。
    func flagsChanged(keyCode: UInt16, rawFlags: UInt, composing: Bool, host: VoiceHost) {
        guard let key, key.isModifier, keyCode == key.keyCode else {
            pendingHint = false // 按着语音键时又按了别的修饰键（Option+Command…）：不是要说话
            return
        }
        _ = press(down: key.isDown(rawFlags: rawFlags), composing: composing, host: host)
    }

    /// keyDown / keyUp。返回 true 表示吃掉了这个键。
    func keyEvent(keyCode: UInt16, up: Bool, composing: Bool, host: VoiceHost) -> Bool {
        if let key, !key.isModifier, keyCode == key.keyCode {
            return press(down: !up, composing: composing, host: host)
        }
        if !up { pendingHint = false }
        guard showing, !up, self.host === host else { return false }
        if keyCode == VirtualKey.escape {
            cancel()
            return true
        }
        // 说话途中打别的键：不要这次的语音，键照常处理
        cancel()
        return false
    }

    /// 这个输入框没了（切走、失去焦点）：这次说的话不要了
    func cancel(for host: VoiceHost) {
        if self.host === host { cancel() }
    }

    func cancel() {
        if let handle { wowtype_voice_cancel(handle) }
        finish()
    }

    private func press(down: Bool, composing: Bool, host: VoiceHost) -> Bool {
        guard let handle, let key else { return false }
        if !VoiceModelInstaller.isReady(URL(fileURLWithPath: modelDir)) {
            // 还没下载模型：不碰麦克风（不弹权限框），只提示去设置里下载（提示文字是核心给的）
            if down {
                if composing && !showing { return false }
                pendingHint = true
                // 修饰键松开时再提示；F 键这类按下就提示
                if key.isModifier { return false }
            } else if !pendingHint {
                return false
            }
            pendingHint = false
            if showing && self.host !== host { cancel() }
            self.host = host
            showing = true
            holdUntil = 0
            wowtype_voice_key_down(handle)
            wowtype_voice_key_up(handle)
            poll()
            startTimer()
            return true
        }
        if !down {
            guard keyDown else { return false }
            keyDown = false
            if showing && self.host === host {
                wowtype_voice_key_up(handle)
                poll()
            }
            return true
        }
        if keyDown { return true } // 按住时的自动重复
        if composing && !showing { return false } // 正在打拼音时不抢这个键
        if showing && self.host !== host { cancel() }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // 第一次用：系统弹窗问要不要允许，同意以后再按一次
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            hint("请允许 WowType 使用麦克风，然后再按一次语音键", host: host)
            return true
        default:
            hint("麦克风没打开：系统设置 → 隐私与安全性 → 麦克风，打开 WowType", host: host)
            return true
        }
        keyDown = true
        if !showing {
            self.host = host
            showing = true
            levels = []
            frame = 0
            holdUntil = 0
        }
        wowtype_voice_key_down(handle)
        poll()
        startTimer()
        return true
    }

    private func hint(_ text: String, host: VoiceHost) {
        if showing && self.host !== host { cancel() }
        self.host = host
        showing = true
        holdUntil = ProcessInfo.processInfo.systemUptime + 4
        host.voiceShow(status: "🎙 " + text, partial: "")
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self, self.poll() else { self?.stopTimer(); return }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 取一次状态，画出来；返回 false 表示不用再取了。
    @discardableResult
    private func poll() -> Bool {
        guard let handle, showing else { return false }
        guard let host else {
            // 输入框没了
            cancel()
            return false
        }
        let phase = Int(wowtype_voice_poll(handle))
        let text = wowtype_voice_text(handle).map { String(cString: $0) } ?? ""
        let now = ProcessInfo.processInfo.systemUptime
        switch phase {
        case Int(WOWTYPE_VOICE_LISTENING):
            levels.append(Int(wowtype_voice_level(handle)))
            if levels.count > 6 { levels.removeFirst() }
            host.voiceShow(status: "🎙 " + voiceWave(levels), partial: text)
            return true
        case Int(WOWTYPE_VOICE_RECOGNIZING):
            let dots = ["·    ", "··   ", "···  ", "···· ", "·····"]
            host.voiceShow(status: "🎙 " + dots[(frame / 3) % dots.count], partial: text)
            frame += 1
            return true
        case Int(WOWTYPE_VOICE_RESULT):
            finish()
            host.voiceCommit(text)
            // 上屏以后再复制；密码框里（开了安全输入）说的话不进剪贴板
            if copyResult && !text.isEmpty && !IsSecureEventInputEnabled() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return false
        case Int(WOWTYPE_VOICE_ERROR):
            NSLog("WowType: 语音 %@", text)
            host.voiceShow(status: "🎙 " + text, partial: "")
            // 没下载模型的提示要去设置里操作，多留一会儿
            let missing = Int(wowtype_voice_model_state(handle)) == Int(WOWTYPE_VOICE_MODEL_MISSING)
            holdUntil = now + (missing ? 4 : 1.5)
            return true
        default:
            if now < holdUntil { return true }
            finish()
            return false
        }
    }

    private func finish() {
        stopTimer()
        keyDown = false
        if showing {
            showing = false
            host?.voiceShow(status: nil, partial: "")
        }
        host = nil
    }
}
