//! 数学符号候选（万象 `others.txt` 符号片段 + 通用拼音直打符号清单）。
//!
//! 数据一部分来自万象拼音 `super_tips` 用的 `others.txt`：希腊字母（alpha→α、pi→π）、
//! 数学运算（根号→√、约等于→≈、不等于→≠、无穷大→∞、≤≥、±）、
//! 上下标（平方→²、立方→³、十次方→¹⁰）、分数（二分之一→½）、
//! 单位（摄氏度→℃、华氏度→℉）；另一部分是通用「拼音直打符号」清单：
//! 运算关系（dengyu→=、jiajian→±、chenghao→×、chuhao→÷、wuqiong→∞）、
//! 几何微积分（jiaodu→∠、chuizhi→⊥、pingxing→∥、jifen→∫、qiuhe→∑、piandao→∂）、
//! 集合逻辑（shuyu→∈、kongji→∅、jiaoji→∩、bingji→∪、yinwei→∵、suoyi→∴）、
//! 希腊字母音译与大小写（aerfa→α、beita→β、xigema→Σ/σ、oumeiga→Ω/ω、pai→π、
//! namuda→Λ/λ）等，共 198 条。
//!
//! 表在编译期用 `include_str!` 编进二进制，运行时零 IO、不依赖词库——
//! 所以雾凇、万象两种词库下都生效（和化学式、拆字表一个路子）。
//!
//! 用法：
//! - 打 `genhao` / `gen hao` → 候选里直接出现 `√`，数字键上屏；
//! - 打 `pi` → `π`；打 `alpha` → `α`；打 `yuedengyu` → `≈`；
//! - 打中文「根号」时，在它后面注释里也写上 `√`。

use std::collections::HashMap;
use std::sync::OnceLock;

/// 拼音(连写,无声调) <TAB> 符号 <TAB> 名字
const MATHSYM_TSV: &str = include_str!("mathsym.tsv");

/// 一条数学符号。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MathSymbol {
    /// 上屏的符号，如 `√`、`π`、`²`。
    pub symbol: String,
    /// 名字，如「根号」「alpha」。用于注释和排序。
    pub name: String,
}

struct MathTable {
    /// 归一化拼音（去空格隔音符，全小写）-> 符号列表。
    by_pinyin: HashMap<String, Vec<MathSymbol>>,
    /// 中文名 -> 符号（给中文候选加注释用）。
    by_name: HashMap<String, String>,
}

fn normalize(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_whitespace() && *c != '\'')
        .flat_map(char::to_lowercase)
        .collect()
}

fn build() -> MathTable {
    let mut by_pinyin: HashMap<String, Vec<MathSymbol>> = HashMap::new();
    let mut by_name: HashMap<String, String> = HashMap::new();
    for line in MATHSYM_TSV.lines() {
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() < 3 {
            continue;
        }
        let key = normalize(cols[0]);
        let item = MathSymbol {
            symbol: cols[1].to_string(),
            name: cols[2].to_string(),
        };
        let list = by_pinyin.entry(key).or_default();
        if !list.iter().any(|x| x.symbol == item.symbol) {
            list.push(item.clone());
        }
        // 同名多符号时留第一个
        by_name.entry(cols[2].to_string()).or_insert(item.symbol);
    }
    MathTable { by_pinyin, by_name }
}

fn table() -> &'static MathTable {
    static T: OnceLock<MathTable> = OnceLock::new();
    T.get_or_init(build)
}

/// 拼音（可带空格/隔音符、可全拼连写）对应的数学符号。
pub fn symbols_for(pinyin: &str) -> Vec<MathSymbol> {
    table()
        .by_pinyin
        .get(&normalize(pinyin))
        .cloned()
        .unwrap_or_default()
}

/// 中文名对应的数学符号（用于给「根号」候选加注释 `√`）。
pub fn symbol_for_name(name: &str) -> Option<&'static str> {
    table().by_name.get(name).map(|s| s.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pinyin_lookup() {
        assert!(symbols_for("genhao").iter().any(|x| x.symbol == "√"));
        assert!(symbols_for("gen hao").iter().any(|x| x.symbol == "√"));
        assert!(symbols_for("pi").iter().any(|x| x.symbol == "π"));
        assert!(symbols_for("yuedengyu").iter().any(|x| x.symbol == "≈"));
        assert!(symbols_for("budengyu").iter().any(|x| x.symbol == "≠"));
        assert!(symbols_for("wuqiongda").iter().any(|x| x.symbol == "∞"));
        assert!(symbols_for("alpha").iter().any(|x| x.symbol == "α"));
        assert!(symbols_for("xiaoyudengyu").iter().any(|x| x.symbol == "≤"));
        // 通用拼音直打符号清单（用户反馈补全）
        for (pinyin, sym) in [
            ("dengyu", "="), ("jiajian", "±"), ("chenghao", "×"), ("chuhao", "÷"),
            ("wuqiong", "∞"), ("jiaodu", "∠"), ("chuizhi", "⊥"), ("pingxing", "∥"),
            ("sanjiaoxing", "△"), ("jifen", "∫"), ("qiuhe", "∑"), ("piandao", "∂"),
            ("shuyu", "∈"), ("bushuyu", "∉"), ("kongji", "∅"), ("jiaoji", "∩"),
            ("bingji", "∪"), ("yinwei", "∵"), ("suoyi", "∴"), ("xigema", "Σ"),
            ("oumeiga", "Ω"), ("pai", "π"), ("namuda", "λ"), ("deerta", "Δ"),
        ] {
            assert!(
                symbols_for(pinyin).iter().any(|x| x.symbol == sym),
                "{pinyin} 应出 {sym}"
            );
        }
    }

    #[test]
    fn name_lookup() {
        assert_eq!(symbol_for_name("根号"), Some("√"));
        assert_eq!(symbol_for_name("约等于"), Some("≈"));
        assert_eq!(symbol_for_name("圆周率"), Some("π"));
        assert_eq!(symbol_for_name("摄氏度"), Some("℃"));
        assert_eq!(symbol_for_name("二分之一"), Some("½"));
    }

    #[test]
    fn no_match() {
        assert!(symbols_for("zzzznotasymbol").is_empty());
    }
}
