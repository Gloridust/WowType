// 语音识别模型（微信输入法的离线语音包）：和 Linux 设置的「语音」页一样，从腾讯的 CDN 下载官方包，
// 校验后解出模型和词表放进数据目录的 wtlocal/。模型是腾讯的，不随安装包分发；和微信输入法装没装无关。
//
// 地址、大小和 voice/src/wtlocal/pack.rs、settings/wowtype-config 一样（那两边钉的是 MD5，
// 这里钉同一个包的 SHA256，下载器边下边算）。解包照 pack.rs：外层签名 zip 里只取
// ime_asr_decoder_model.zip，再扁平解出，只留 *.xnet 和 dict.decoder.utf8.txt。

import Foundation

enum VoiceModelInstaller {
    static let url = "https://download.z.weixin.qq.com/publish_words/v1/ime_asr_decoder_model/20260710220526250_ime_asr_decoder_model.apk"
    static let size: Int64 = 102_920_639
    /// MD5 28386481eb94ff73b28ee3949c0cf690（和 Linux 钉的一样）的那个包的 SHA256
    static let sha256 = "b3729fbe928b25740cc9cd781537175b1db4a445bd78bf464267c0c4633e0863"
    static let inner = "ime_asr_decoder_model.zip"
    static let dict = "dict.decoder.utf8.txt"

    static func folder(in supportDir: URL) -> URL {
        supportDir.appendingPathComponent("wtlocal", isDirectory: true)
    }

    /// 下载中的包（断了接着下）
    static func pack(in supportDir: URL) -> URL {
        supportDir.appendingPathComponent("wtlocal.apk")
    }

    /// 模型和词表都在（和 voice crate 的 is_ready 一样）
    static func isReady(supportDir: URL) -> Bool {
        isReady(folder(in: supportDir))
    }

    static func isReady(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent(dict).path),
              let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        return names.contains { $0.hasSuffix(".xnet") }
    }

    static func hasPartial(supportDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: pack(in: supportDir).path + ".part")
    }

    /// 下载（或从 file）装上模型，返回模型占的字节数（在后台线程上调）。
    /// control 取消时抛 DownloadCancelled，.part 留着下次接着下。
    @discardableResult
    static func install(supportDir: URL, from file: URL? = nil, control: DownloadControl,
                        progress: @escaping (Int64, Int64) -> Void) throws -> Int64 {
        let packFile: URL
        if let file {
            packFile = file
        } else {
            packFile = pack(in: supportDir)
            try LocalModelInstaller.download(url, sha256: sha256, to: packFile, control: control,
                                             progress: progress)
        }
        try unpack(packFile, into: folder(in: supportDir))
        if file == nil {
            try? FileManager.default.removeItem(at: packFile)
        }
        return LexiconPackInstaller.folderSize(folder(in: supportDir))
    }

    /// 解到 dir：先解到旁边的临时目录，模型和词表都在了再整体换进去。
    static func unpack(_ packFile: URL, into dir: URL) throws {
        let fm = FileManager.default
        let tmp = dir.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            _ = try LocalModelInstaller.run("/usr/bin/unzip", ["-o", "-q", packFile.path, inner, "-d", tmp.path])
            let innerZip = tmp.appendingPathComponent(inner)
            guard fm.fileExists(atPath: innerZip.path) else { throw PackError("语音包里没有 \(inner)") }
            _ = try LocalModelInstaller.run("/usr/bin/unzip", ["-o", "-q", "-j", innerZip.path, "-d", tmp.path])
            for name in try fm.contentsOfDirectory(atPath: tmp.path)
            where !(name.hasSuffix(".xnet") || name == dict) {
                try? fm.removeItem(at: tmp.appendingPathComponent(name))
            }
            guard isReady(tmp) else { throw PackError("语音包里没有模型或词表，不安装") }
            try? fm.removeItem(at: dir)
            try fm.moveItem(at: tmp, to: dir)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// 删掉模型（和下了一半的包），返回空出的字节数。
    @discardableResult
    static func remove(supportDir: URL) -> Int64 {
        let fm = FileManager.default
        let dir = folder(in: supportDir)
        let freed = LexiconPackInstaller.folderSize(dir)
            + LocalModelInstaller.fileSize(pack(in: supportDir).path + ".part")
        try? fm.removeItem(at: dir)
        try? fm.removeItem(atPath: pack(in: supportDir).path + ".part")
        return freed
    }
}
