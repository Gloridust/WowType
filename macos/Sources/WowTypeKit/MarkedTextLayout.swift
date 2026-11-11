// 编辑区：核心给的是 UTF-8 字节位置，AppKit 要 UTF-16 位置。
// 落在一个字中间的位置往前取整，超出的夹到末尾。
public struct MarkedTextLayout: Sendable, Equatable {
    public let text: String
    /// 前面不加下划线的部分（已选的词）有多长。
    public let plainUTF16: Int
    public let caretUTF16: Int
    public let lengthUTF16: Int

    public init(text: String, plainBytes: Int, cursorBytes: Int) {
        self.text = text
        plainUTF16 = Self.utf16Offset(text, bytes: plainBytes)
        caretUTF16 = Self.utf16Offset(text, bytes: cursorBytes)
        lengthUTF16 = text.utf16.count
    }

    static func utf16Offset(_ text: String, bytes: Int) -> Int {
        var units = 0
        var used = 0
        for scalar in text.unicodeScalars {
            let size = UTF8.width(scalar)
            if used + size > bytes { break }
            used += size
            units += UTF16.width(scalar)
        }
        return units
    }
}
