//! 部件拆字反查（`uU` + 部件拼音 → 汉字），移植自雾凇 `search.lua` + `radical_lookup`。
//!
//! 数据来自 rime-ice 的 `radical_pinyin.dict.yaml`（原始方案 mirtlecn/rime_radical_pinyin，GPL-3.0），
//! 编译期用 `include_str!` 编进二进制：`码（部件拼音连写，无分隔符）\t汉字\t权重`。
//!
//! 内存设计（呼应 PR #283 的低内存目标）：不在运行时把 13 万条建进 HashMap——那样每条都要
//! 堆分配一个 String、额外几倍内存。这里只在首次用到时建一个「每行起始字节偏移」数组
//! （约 13 万 × 4 字节 = 0.5 MB），行文本本身仍在静态只读区，查询时切片比较、零拷贝。
//! 表已按码排序，二分定位前缀起点后顺序收集，命中前缀的行是连续的。

use std::sync::OnceLock;

/// 部件拆字表：码（部件拼音连写）<TAB> 汉字 <TAB> 权重，按码字典序排序。
const RADICAL_TSV: &str = include_str!("radical.tsv");

struct RadicalTable {
    /// 每个数据行在 RADICAL_TSV 里的起始字节偏移（跳过注释行），按码排序。
    lines: Vec<u32>,
}

fn table() -> &'static RadicalTable {
    static TABLE: OnceLock<RadicalTable> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut lines = Vec::with_capacity(140_000);
        let mut off = 0usize;
        for line in RADICAL_TSV.split_inclusive('\n') {
            if !line.starts_with('#') {
                lines.push(off as u32);
            }
            off += line.len();
        }
        RadicalTable { lines }
    })
}

/// 第 idx 个数据行的字节区间。
fn line_range(t: &RadicalTable, idx: usize) -> (usize, usize) {
    let start = t.lines[idx] as usize;
    let end = if idx + 1 < t.lines.len() {
        t.lines[idx + 1] as usize
    } else {
        RADICAL_TSV.len()
    };
    (start, end)
}

/// 第 idx 行的码（第一个字段，去掉行尾换行）。
fn code_at(t: &RadicalTable, idx: usize) -> &str {
    let (start, end) = line_range(t, idx);
    let line = &RADICAL_TSV[start..end];
    let line = line.trim_end_matches('\n').trim_end_matches('\r');
    line.split('\t').next().unwrap_or("")
}

/// 按部件码查汉字。码是部件拼音连写（如 `koushu` = 口+竖 → 中，`longlonglonglong` → 𪚥）。
///
/// 用前缀匹配（rime 的 table_translator 同样支持编码补全）：输入是完整码的前缀时也列出候选，
/// 这样 `uUshi` 能列出所有以 shi 开头的拆字结果。返回 (汉字, 权重)，按权重降序、去重。
pub fn lookup(code: &str) -> Vec<(String, u32)> {
    // rime 的拆字方案 algebra 里有 xform/'//：隔音符和空格都不算进部件码。
    // 用户打 uU'shi、uUshi、uU shou bing 都能查到。
    let code: String = code
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '\'')
        .map(|c| c.to_ascii_lowercase())
        .collect();
    if code.is_empty() || !code.bytes().all(|b| b.is_ascii_lowercase()) {
        return Vec::new();
    }
    let t = table();
    // 第一个 code >= 查询码的行（表按码排序，手写二分避免为比较重复切片分配）
    let mut left = 0usize;
    let mut right = t.lines.len();
    while left < right {
        let mid = (left + right) / 2;
        if code_at(t, mid) < code.as_str() {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    let mut out: Vec<(String, u32)> = Vec::new();
    let mut i = left;
    while i < t.lines.len() {
        let c = code_at(t, i);
        if !c.starts_with(&code) {
            break;
        }
        let (start, end) = line_range(t, i);
        let line = &RADICAL_TSV[start..end];
        let mut cols = line.split('\t');
        let _code = cols.next(); // 第一列是码
        let ch = cols.next().unwrap_or("").trim(); // 第二列是汉字
        let weight = cols
            .next()
            .and_then(|w| w.trim().parse::<u32>().ok())
            .unwrap_or(0);
        if !ch.is_empty() {
            out.push((ch.to_string(), weight));
        }
        i += 1;
    }
    out.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    out.dedup_by(|a, b| a.0 == b.0);
    out.truncate(50);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_lookup() {
        let r = lookup("koushu"); // 口 + 竖 = 中
        assert!(r.iter().any(|(ch, _)| ch == "中"), "koushu 要查出「中」: {r:?}");
        let r = lookup("shoubing"); // 手 + 并 = 拼
        assert!(r.iter().any(|(ch, _)| ch == "拼"), "shoubing 要查出「拼」: {r:?}");
    }

    #[test]
    fn rare_char() {
        let r = lookup("longlonglonglong"); // 四个龙 = 𪚥
        assert!(r.iter().any(|(ch, _)| ch == "𪚥"), "longlonglonglong 要查出「𪚥」: {r:?}");
    }

    #[test]
    fn prefix_lookup() {
        let r = lookup("shi"); // 前缀匹配，出一批以 shi 开头的拆字
        assert!(!r.is_empty());
    }

    #[test]
    fn rejects_non_alpha() {
        assert!(lookup("").is_empty());
        assert!(lookup("123").is_empty());
        assert!(lookup("ab1").is_empty());
    }
}
