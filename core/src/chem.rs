//! 化学式候选与错音错字提示。
//!
//! 数据来自万象拼音 `super_tips` 的 277 条化学式 + 118 个元素符号 + 常见离子，
//! 以及雾凇拼音 `lua/corrector.lua` 的 236 条错音错字表。
//!
//! 两张表在编译期用 `include_str!` 编进二进制，运行时零 IO、不依赖词库——
//! 所以雾凇、万象两种词库下都生效（这正是把它们放进 core 而不是词库脚本的原因）。
//!
//! 用法：
//! - 打 `liusuan` / `liu suan` → 候选里直接出现 `H₂SO₄`，数字键上屏；
//! - 打 `tie li zi` → `Fe³⁺`；打 `na` → 除「那」外还出元素符号 `Na`；
//! - 打出错音词（如 `gei yu` 得到「给予」）→ 该候选后面注释显示正确读音 `jǐ yǔ`。

use std::collections::HashMap;
use std::sync::OnceLock;

/// 化学式表：拼音(空格分音节，无声调) <TAB> 符号 <TAB> 中文名 <TAB> 来源
const CHEM_TSV: &str = include_str!("chem.tsv");
/// 错音表：拼音 <TAB> 词 <TAB> 提示
const CORRECTOR_TSV: &str = include_str!("corrector.tsv");

/// 一条化学式。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Formula {
    /// 上屏的符号，如 `H₂SO₄`、`Fe³⁺`。
    pub symbol: String,
    /// 中文名，如「硫酸」。用于注释和排序。
    pub name: String,
}

struct ChemTable {
    /// 归一化拼音（去空格隔音符，全小写）-> 化学式列表。
    by_pinyin: HashMap<String, Vec<Formula>>,
    /// 中文名 -> 化学式（给中文候选加注释用）。
    by_name: HashMap<String, String>,
}

fn normalize(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_whitespace() && *c != '\'')
        .flat_map(char::to_lowercase)
        .collect()
}

fn build_chem() -> ChemTable {
    let mut by_pinyin: HashMap<String, Vec<Formula>> = HashMap::new();
    let mut by_name: HashMap<String, String> = HashMap::new();
    for line in CHEM_TSV.lines() {
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() < 3 {
            continue;
        }
        let key = normalize(cols[0]);
        let f = Formula {
            symbol: cols[1].to_string(),
            name: cols[2].to_string(),
        };
        by_pinyin.entry(key).or_default().push(f.clone());
        // 同名多符号时留第一个（表里已按拼音、符号排序，稳定）
        by_name.entry(cols[2].to_string()).or_insert(f.symbol);
    }
    ChemTable { by_pinyin, by_name }
}

fn chem() -> &'static ChemTable {
    static TABLE: OnceLock<ChemTable> = OnceLock::new();
    TABLE.get_or_init(build_chem)
}

struct CorrectorTable {
    /// 归一化拼音 -> [(词, 提示)]
    by_pinyin: HashMap<String, Vec<(String, String)>>,
}

fn build_corrector() -> CorrectorTable {
    let mut by_pinyin: HashMap<String, Vec<(String, String)>> = HashMap::new();
    for line in CORRECTOR_TSV.lines() {
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() < 3 {
            continue;
        }
        let key = normalize(cols[0]);
        by_pinyin
            .entry(key)
            .or_default()
            .push((cols[1].to_string(), cols[2].to_string()));
    }
    CorrectorTable { by_pinyin }
}

fn corrector() -> &'static CorrectorTable {
    static TABLE: OnceLock<CorrectorTable> = OnceLock::new();
    TABLE.get_or_init(build_corrector)
}

/// 拼音（可带空格/隔音符、可全拼连写）对应的化学式。
///
/// 用「整串归一化」精确匹配：打 `liusuan` 和 `liu suan` 都能命中 `liu suan`。
pub fn formulas_for(pinyin: &str) -> Vec<Formula> {
    chem().by_pinyin.get(&normalize(pinyin)).cloned().unwrap_or_default()
}

/// 中文名对应的化学式符号（用于给「硫酸」候选加注释 `H₂SO₄`）。
pub fn formula_for_name(name: &str) -> Option<&'static str> {
    chem().by_name.get(name).map(|s| s.as_str())
}

/// 错音错字提示：给定候选的完整拼音和候选词，返回应该显示的注释。
///
/// 与雾凇 corrector.lua 一致——按「拼音 + 词」联合查表，避免同音词串味。
pub fn correction(pinyin: &str, word: &str) -> Option<&'static str> {
    let key = normalize(pinyin);
    let rows = corrector().by_pinyin.get(&key)?;
    rows.iter()
        .find(|(w, _)| w == word)
        .map(|(_, tip)| tip.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formula_lookup() {
        let f = formulas_for("liu suan");
        assert!(f.iter().any(|x| x.symbol == "H₂SO₄"), "{f:?}");
        let f = formulas_for("liusuan");
        assert!(f.iter().any(|x| x.symbol == "H₂SO₄"));
        let f = formulas_for("tie li zi");
        assert!(f.iter().any(|x| x.symbol == "Fe³⁺"), "{f:?}");
        let f = formulas_for("na");
        assert!(f.iter().any(|x| x.symbol == "Na"), "{f:?}");
    }

    #[test]
    fn name_lookup() {
        assert_eq!(formula_for_name("硫酸"), Some("H₂SO₄"));
        assert_eq!(formula_for_name("铁离子"), Some("Fe³⁺"));
    }

    #[test]
    fn corrector_lookup() {
        assert_eq!(correction("gei yu", "给予"), Some("jǐ yǔ"));
        assert_eq!(correction("zhu jiao", "主角"), Some("zhǔ jué"));
        assert_eq!(correction("gei yu", "给与"), None);
    }
}
