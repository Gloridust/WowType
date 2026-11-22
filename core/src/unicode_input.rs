//! Unicode 码点输入（`U` + 十六进制），移植自雾凇 `lua/unicode.lua`。
//!
//! 打 `U62fc` 出「拼」，同时把该码点后面 16 个码点（低四位 0~f）也列出来，
//! 方便在一段区间里翻找——和雾凇的行为一致。

/// 判断输入是不是 Unicode 模式：`U` 后面至少两位十六进制。
pub fn active(input: &str, prefix: char) -> bool {
    let Some(rest) = input.strip_prefix(prefix) else {
        return false;
    };
    rest.len() >= 2 && rest.bytes().all(|b| b.is_ascii_hexdigit())
}

/// 候选：(字符, 注释)。注释形如 `U62fc`、区间是 `U62f0~f`。
pub fn candidates(input: &str, prefix: char) -> Vec<(String, String)> {
    let Some(rest) = input.strip_prefix(prefix) else {
        return Vec::new();
    };
    if rest.len() < 2 || !rest.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Vec::new();
    }
    let Ok(code) = u32::from_str_radix(rest, 16) else {
        return Vec::new();
    };
    if code > 0x10FFFF || (0xD800..=0xDFFF).contains(&code) {
        return vec![("数值超限！".to_string(), String::new())];
    }
    let mut out = Vec::new();
    if let Some(ch) = char::from_u32(code) {
        out.push((ch.to_string(), format!("U{code:x}")));
    }
    // 低四位区间：把码点低 4 位清零后枚举 0~f（雾凇的 U62fc 会列出 U62f0~U62ff）
    if code < 0x10000 {
        let base = code & !0xF;
        for i in 0..=0xF {
            let c = base | i;
            if let Some(ch) = char::from_u32(c) {
                out.push((ch.to_string(), format!("U{c:x}~{i:x}")));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic() {
        assert!(active("U62fc", 'U'));
        assert!(!active("U6", 'U'));
        assert!(!active("Uzz", 'U'));
        let c = candidates("U62fc", 'U');
        assert_eq!(c[0].0, "拼");
        assert_eq!(c[0].1, "U62fc");
        assert!(c.len() > 1);
    }

    #[test]
    fn overflow() {
        let c = candidates("U110000", 'U');
        assert_eq!(c[0].0, "数值超限！");
    }
}
