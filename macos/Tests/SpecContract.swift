// 设置契约：拿 spec/config.json、spec/lexicon-pack.json 对照 macOS 的 WowtypeConfig 和 LexiconPack。
// Linux 那两端（fcitx5 插件、设置界面）在 scripts/test-config-contract.py 里对照同一份规格。
// 规格目录由 macos/test.sh 用 WOWTYPE_SPEC_DIR 传进来（没设时用当前目录下的 spec/）。

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// 规格里的值写进 wowtype.conf 的样子：True / False、十进制数字、原样的字符串。
private func fileText(_ value: JSON) -> String? {
    switch value {
    case .bool(let b): return b ? "True" : "False"
    case .number: return value.int.map { String($0) }
    case .string(let s): return s
    default: return nil
    }
}

/// 枚举的可选值：可以直接是字符串，也可以是 {"value": …, "name": …}。
private func enumValues(_ setting: JSON) -> [String] {
    (setting["values"]?.array ?? []).compactMap { $0.string ?? $0["value"]?.string }
}

private func loadSpec(_ name: String) -> JSON? {
    let dir = getenv("WOWTYPE_SPEC_DIR").map { String(cString: $0) } ?? "spec"
    guard let text = readFile(dir + "/" + name), let spec = JSON.parse(text) else {
        check(false, "契约：读 \(dir)/\(name)")
        return nil
    }
    return spec
}

private func matches(_ result: Result<Int, PackError>, count: Int?) -> Bool {
    switch result {
    case .success(let n): return n == count
    case .failure: return count == nil
    }
}

func checkConfigContract() {
    guard let spec = loadSpec("config.json"), let all = spec["settings"]?.array else {
        return
    }
    let mine = all.filter { s in s["platforms"]?.array?.contains { $0.string == "macos" } == true }
    let specKeys = Set(mine.compactMap { $0["key"]?.string })
    let ours = Set(WowtypeConfig.keys)
    check(ours == specKeys, "契约：macOS 认的键和规格一样",
          "规格里有、macOS 没有：\(specKeys.subtracting(ours).sorted())；macOS 有、规格里没有：\(ours.subtracting(specKeys).sorted())")

    let d = WowtypeConfig()
    let policy = spec["readRules"]?["outOfRange"]?["macos"]?.string ?? "?"
    for s in mine {
        guard let key = s["key"]?.string, let type = s["type"]?.string,
              let def = (s["platformDefault"]?["macos"] ?? s["default"]).flatMap(fileText)
        else {
            check(false, "契约：规格里的设置项写得不全", s["key"]?.string ?? "?")
            continue
        }
        check(d.value(forKey: key) == def, "契约：\(key) 的默认值是 \(def)", d.value(forKey: key) ?? "（不认这个键）")
        /// 文件里写的是 raw，读出来是什么
        func readBack(_ raw: String) -> String? {
            var c = WowtypeConfig()
            c.setValue(raw, forKey: key)
            return c.value(forKey: key)
        }
        switch type {
        case "bool":
            check(readBack("True") == "True" && readBack("False") == "False", "契约：\(key) 是开关")
        case "int":
            guard let low = s["min"]?.int, let high = s["max"]?.int else {
                check(false, "契约：\(key) 没写范围")
                continue
            }
            for (raw, edge) in [(low, low), (high, high), (low - 1, low), (high + 1, high)] {
                let expect: String
                switch policy {
                case "clamp": expect = String(edge)
                case "keep": expect = String(raw)
                default: expect = raw == edge ? String(raw) : def
                }
                let got = readBack(String(raw))
                check(got == expect, "契约：\(key)=\(raw) 读出来是 \(expect)（超出范围：\(policy)）", got ?? "nil")
            }
        case "enum":
            for v in enumValues(s) {
                check(readBack(v) == v, "契约：\(key) 认 \(v)", readBack(v) ?? "nil")
            }
        case "string":
            check(readBack("~/契约 测试/a.tsv") == "~/契约 测试/a.tsv", "契约：\(key) 原样存字符串")
        case "key":
            check(readBack(def) == def && readBack("") == "", "契约：\(key) 是快捷键，留空不用", readBack(def) ?? "nil")
            if s["platformDefault"]?["macos"] != nil, let shared = s["default"].flatMap(fileText) {
                // 别的端的默认值拷过来，读成 macOS 的默认值（EmojiKey：Super 当 Control，原因见规格的 why）
                check(readBack(shared) == def, "契约：\(key) 写 \(shared) 读成 \(def)", readBack(shared) ?? "nil")
            }
        default:
            check(false, "契约：\(key) 的类型 \(type) 不认识")
        }

        // 文件里没写这一项时的规矩（TranslateLocal 跟着 TranslateBaseUrl 走）；写回去再读还是一样
        for c in s["whenMissing"]?["cases"]?.array ?? [] {
            let file = (c["file"]?.object ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.string ?? "")\n" }.joined()
            let expect = c["expect"].flatMap(fileText)
            let parsed = WowtypeConfig.parse(file)
            check(parsed.value(forKey: key) == expect, "契约：文件是 \(file.debugDescription) 时 \(key) 是 \(expect ?? "?")",
                  parsed.value(forKey: key) ?? "nil")
            let written = parsed.serialized(into: file)
            check(WowtypeConfig.parse(written) == parsed, "契约：文件是 \(file.debugDescription) 时写回去再读一样", written)
        }
    }

    // 选项列表
    var byKey: [String: JSON] = [:]
    for s in all {
        if let key = s["key"]?.string { byKey[key] = s }
    }
    let lists: [(String, [String])] = [
        ("ShuangpinScheme", WowtypeConfig.shuangpinSchemes),
        ("ShiftToggle", WowtypeConfig.ShiftToggle.allCases.map(\.rawValue)),
        ("SelectKeys", WowtypeConfig.SelectKeys.allCases.map(\.rawValue)),
        ("TranslateTarget", WowtypeConfig.translateTargets),
    ]
    for (key, values) in lists {
        let expected = byKey[key].map(enumValues) ?? []
        check(values == expected, "契约：\(key) 的可选值", "规格 \(expected)，macOS \(values)")
    }
    let languages = (byKey["TranslateTarget"]?["values"]?.array ?? []).map {
        ($0["name"]?.string ?? "", $0["value"]?.string ?? "")
    }
    check(WowtypeConfig.translateLanguages.map { $0.0 } == languages.map { $0.0 }
          && WowtypeConfig.translateLanguages.map { $0.1 } == languages.map { $0.1 },
          "契约：互译语言的名字和代码", "规格 \(languages)，macOS \(WowtypeConfig.translateLanguages)")
    let providers = (spec["translateProviders"]?["items"]?.array ?? []).map {
        [$0["name"]?.string ?? "", $0["url"]?.string ?? "", $0["model"]?.string ?? ""]
    }
    // 语音键：设置窗口能选的和规格里 presets.macos 一样，每个都对得上 Mac 的键码
    let voicePresets = byKey["VoiceKey"]?["presets"]?["macos"]?.array?.compactMap { $0.string } ?? []
    check(VoiceKey.presets.map(\.name) == voicePresets, "契约：语音键的选项（macOS）",
          "规格 \(voicePresets)，macOS \(VoiceKey.presets.map(\.name))")
    check(VoiceKey.presets.allSatisfy { VoiceKey(name: $0.name) != nil }, "契约：语音键的选项都认得")
    let ourProviders = WowtypeConfig.translateProviders.map { [$0.name, $0.url, $0.model] }
    check(ourProviders == providers, "契约：翻译服务商", "规格 \(providers)，macOS \(ourProviders)")

    // 读文件的规矩（三端一样）：整份 wowtype.conf 读出来是什么；写回去再读还是一样
    for c in spec["readRules"]?["cases"]?["items"]?.array ?? [] {
        guard let file = c["file"]?.string, let expect = c["expect"]?.object else {
            check(false, "契约：readRules.cases 的例子写得不全")
            continue
        }
        let parsed = WowtypeConfig.parse(file)
        for (key, value) in expect.sorted(by: { $0.key < $1.key }) {
            let want = value.string ?? "?"
            check(parsed.value(forKey: key) == want, "契约：文件是 \(file.debugDescription) 时 \(key) 是 \(want)",
                  parsed.value(forKey: key) ?? "nil")
        }
        let written = parsed.serialized(into: file)
        check(WowtypeConfig.parse(written) == parsed, "契约：文件是 \(file.debugDescription) 时写回去再读一样", written)
    }
}

func checkLexiconPackContract() {
    guard let pack = loadSpec("lexicon-pack.json") else {
        return
    }
    let files = Set((pack["files"]?.array ?? []).compactMap(\.string))
    check(LexiconPack.files == files, "契约：词库包里许有的文件", "规格 \(files.sorted())，macOS \(LexiconPack.files.sorted())")
    check(LexiconPack.minEntries == pack["minEntries"]?.int, "契约：词库包最少条数", "\(LexiconPack.minEntries)")
    check(LexiconPack.folderName == pack["folder"]?.string, "契约：词库包装在数据目录的哪里", LexiconPack.folderName)
    check(LexiconPack.assetPrefix == pack["assetPrefix"]?.string && LexiconPack.assetSuffix == pack["assetSuffix"]?.string,
          "契约：发布页上词库包的文件名", LexiconPack.assetPrefix + "…" + LexiconPack.assetSuffix)
    check(LexiconPack.checksumFile == pack["checksumFile"]?.string, "契约：校验和文件", LexiconPack.checksumFile)

    let cases = pack["cases"]
    for c in cases?["assetVersion"]?.array ?? [] {
        let name = c["name"]?.string ?? ""
        let got = LexiconPack.assetVersion(name)
        check(got == c["version"]?.string, "契约：词库包文件名 \(name)", got ?? "nil")
    }
    for c in cases?["pickAsset"]?.array ?? [] {
        let names = (c["names"]?.array ?? []).compactMap(\.string)
        let got = LexiconPack.pickAsset(names)?.name
        check(got == c["pick"]?.string, "契约：从 \(names) 里挑词库包", got ?? "nil")
    }
    let wanted = cases?["checksums"]?["wanted"]?.string ?? ""
    for c in cases?["checksums"]?["cases"]?.array ?? [] {
        let text = c["text"]?.string ?? ""
        var got: String?
        if case .success(let sums) = LexiconPack.checksums(text, wanted: [wanted]) {
            got = sums[wanted]
        }
        check(got == c["digest"]?.string, "契约：\(LexiconPack.checksumFile) 是 \(text.debugDescription)", got ?? "不装")
    }
    for c in cases?["entryName"]?.array ?? [] {
        let raw = c["raw"]?.string ?? ""
        let got = LexiconPack.entryName(raw)
        check(got == c["name"]?.string, "契约：包里的条目 \(raw.debugDescription)", got.map { $0.debugDescription } ?? "不许")
    }

    let dir = "/tmp/wowtype-macos-harness-\(getpid())-contract"
    mkdir(dir, 0o755)
    let lexicon = dir + "/lexicon.tsv"
    for c in cases?["lexicon"]?["cases"]?.array ?? [] {
        let text = c["text"]?.string ?? ""
        let count = c["count"]?.int
        writeFile(lexicon, text)
        if let count {
            check(matches(LexiconPack.checkLexicon(at: lexicon, minimum: count), count: count)
                  && matches(LexiconPack.checkLexicon(at: lexicon, minimum: count + 1), count: nil),
                  "契约：lexicon.tsv 是 \(text.debugDescription) 时有 \(count) 条")
        } else {
            check(matches(LexiconPack.checkLexicon(at: lexicon, minimum: 0), count: nil),
                  "契约：lexicon.tsv 是 \(text.debugDescription) 时不装")
        }
        unlink(lexicon)
    }
    for c in cases?["installedVersion"]?.array ?? [] {
        let files = c["files"]?.object ?? [:]
        for (name, text) in files {
            writeFile(dir + "/" + name, text.string ?? "")
        }
        let got = LexiconPack.installedVersion(folder: dir)
        check(got == c["version"]?.string, "契约：装好的词库包 \(files.keys.sorted()) 的版本", got ?? "nil")
        for name in files.keys {
            unlink(dir + "/" + name)
        }
    }
    rmdir(dir)
}
