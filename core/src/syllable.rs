//! 拼音音节表、音节切分与输入串预处理。
//!
//! 说明：
//! - 表里使用 ASCII 的 v 表示 ü（例如 nv/lve/jv/yvan）。
//! - 在 WeType 音节表片段的基础上补齐了标准拼音音节，并保留了 WeType 的
//!   扩展音节：yvan/xvan/jvan/qvan、yve/xve/jve/qve、yvn/xvn/jvn/qvn、
//!   yv/xv/jv/qv、lve/nve、hng/hm/ng、fiao/nou/nun。
//! - 隔音符 ' 只用来强制切分边界，不进入音节文本。
//! - 儿化：尾部 r（如 huar）或隔音符后的 r（如 hua'r）会标记前一个音节为儿化。

use std::fmt;

/// 音节 ID，对应 SYLLABLES 的下标。
pub type SyllableId = u16;

/// 可出现在音节开头的声母（按长度降序，保证 zh/ch/sh 优先于 z/c/s）。
pub const INITIALS: &[&str] = &[
    "zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r",
    "z", "c", "s", "y", "w",
];

/// 韵母表。必须按字节序升序排列，供二分查找使用。
pub const FINALS: &[&str] = &[
    "a", "ai", "an", "ang", "ao", "e", "ei", "en", "eng", "er", "hm", "hng", "i", "ia", "ian",
    "iang", "iao", "ie", "in", "ing", "iong", "iu", "ng", "o", "ong", "ou", "u", "ua", "uai",
    "uan", "uang", "ue", "ui", "un", "uo", "v", "van", "ve", "vn",
];

/// 整体认读/叹词类音节，不按“声母+韵母”常规拆分。
const WHOLE_SYLLABLES: &[&str] = &["hm", "hng", "ng"];

/// 最长音节长度（zhuang/chuang/shuang = 6）。
pub const MAX_SYLLABLE_LEN: usize = 6;

/// 合法音节表，按字节序升序排列。
///
/// 顺序即音节 ID。新增条目时必须保持有序，单元测试会检查。
pub const SYLLABLES: &[&str] = &[
    "a", "ai", "an", "ang", "ao", "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi",
    "bian", "biao", "bie", "bin", "bing", "bo", "bu", "ca", "cai", "can", "cang", "cao", "ce",
    "cen", "ceng", "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong",
    "chou", "chu", "chua", "chuai", "chuan", "chuang", "chui", "chun", "chuo", "ci", "cong", "cou",
    "cu", "cuan", "cui", "cun", "cuo", "da", "dai", "dan", "dang", "dao", "de", "dei", "den",
    "deng", "di", "dia", "dian", "diao", "die", "ding", "diu", "dong", "dou", "du", "duan", "dui",
    "dun", "duo", "e", "ei", "en", "eng", "er", "fa", "fan", "fang", "fei", "fen", "feng", "fiao",
    "fo", "fou", "fu", "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong",
    "gou", "gu", "gua", "guai", "guan", "guang", "gui", "gun", "guo", "ha", "hai", "han", "hang",
    "hao", "he", "hei", "hen", "heng", "hm", "hng", "hong", "hou", "hu", "hua", "huai", "huan",
    "huang", "hui", "hun", "huo", "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing",
    "jiong", "jiu", "ju", "juan", "jue", "jun", "jv", "jvan", "jve", "jvn", "ka", "kai", "kan",
    "kang", "kao", "ke", "kei", "ken", "keng", "kong", "kou", "ku", "kua", "kuai", "kuan", "kuang",
    "kui", "kun", "kuo", "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia",
    "lian", "liang", "liao", "lie", "lin", "ling", "liu", "lo", "long", "lou", "lu", "luan", "lun",
    "luo", "lv", "lve", "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi",
    "mian", "miao", "mie", "min", "ming", "miu", "mo", "mou", "mu", "na", "nai", "nan", "nang",
    "nao", "ne", "nei", "nen", "neng", "ng", "ni", "nian", "niang", "niao", "nie", "nin", "ning",
    "niu", "nong", "nou", "nu", "nuan", "nun", "nuo", "nv", "nve", "o", "ou", "pa", "pai", "pan",
    "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping", "po", "pou",
    "pu", "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu", "quan",
    "que", "qun", "qv", "qvan", "qve", "qvn", "ran", "rang", "rao", "re", "ren", "reng", "ri",
    "rong", "rou", "ru", "rua", "ruan", "rui", "run", "ruo", "sa", "sai", "san", "sang", "sao",
    "se", "sen", "seng", "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen", "sheng",
    "shi", "shou", "shu", "shua", "shuai", "shuan", "shuang", "shui", "shun", "shuo", "si", "song",
    "sou", "su", "suan", "sui", "sun", "suo", "ta", "tai", "tan", "tang", "tao", "te", "tei",
    "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu", "tuan", "tui", "tun", "tuo",
    "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu", "xi", "xia", "xian", "xiang",
    "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun", "xv", "xvan", "xve",
    "xvn", "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu",
    "yuan", "yue", "yun", "yv", "yvan", "yve", "yvn", "za", "zai", "zan", "zang", "zao", "ze",
    "zei", "zen", "zeng", "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen", "zheng",
    "zhi", "zhong", "zhou", "zhu", "zhua", "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo",
    "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo",
];

fn bsearch(table: &'static [&'static str], text: &str) -> Option<usize> {
    table.binary_search_by(|s| (*s).cmp(text)).ok()
}

/// 模糊音归一：把容易混淆的音节映射到同一个规范形式。
///
/// 目前覆盖最常见的三组：
/// - 平翘舌：zh/ch/sh -> z/c/s
/// - 前后鼻音：ang/eng/ing -> an/en/in（含 iang/uang）
///
/// 返回的规范形式本身也是合法音节（例如 zhang -> zan），所以可以直接用音节 ID 比较。
pub fn fuzzy_canon(text: &str) -> String {
    let (head, rest) = if let Some(r) = text.strip_prefix("zh") {
        ("z", r)
    } else if let Some(r) = text.strip_prefix("ch") {
        ("c", r)
    } else if let Some(r) = text.strip_prefix("sh") {
        ("s", r)
    } else {
        ("", text)
    };
    let tail = if let Some(r) = rest.strip_suffix("iang") {
        format!("{r}ian")
    } else if let Some(r) = rest.strip_suffix("uang") {
        format!("{r}uan")
    } else if let Some(r) = rest.strip_suffix("ang") {
        format!("{r}an")
    } else if let Some(r) = rest.strip_suffix("eng") {
        format!("{r}en")
    } else if let Some(r) = rest.strip_suffix("ing") {
        format!("{r}in")
    } else {
        rest.to_string()
    };
    format!("{head}{tail}")
}

/// 音节在模糊音下的规范 ID；找不到对应规范音节时返回自身。
pub fn fuzzy_id(id: SyllableId) -> Option<SyllableId> {
    let text = *SYLLABLES.get(id as usize)?;
    let canon = fuzzy_canon(text);
    Some(Syllable::from_text(&canon).map(|s| s.id).unwrap_or(id))
}

pub fn is_valid(text: &str) -> bool {
    bsearch(SYLLABLES, text).is_some()
}

/// 查音节 ID。
pub fn id_of(text: &str) -> Option<SyllableId> {
    bsearch(SYLLABLES, text).map(|i| i as SyllableId)
}

/// 把音节拆成声母 + 韵母；零声母音节的声母为空串。
///
/// 返回的字符串都是静态表里的规范形式。
pub fn split(text: &str) -> Option<(&'static str, &'static str)> {
    if !is_valid(text) {
        return None;
    }
    if WHOLE_SYLLABLES.contains(&text) {
        let final_ = FINALS[bsearch(FINALS, text)?];
        return Some(("", final_));
    }
    for initial in INITIALS {
        if let Some(rest) = text.strip_prefix(initial) {
            if rest.is_empty() {
                continue;
            }
            if let Some(final_) = bsearch(FINALS, rest) {
                return Some((initial, FINALS[final_]));
            }
        }
    }
    // 零声母：a/an/er 等。
    let final_ = FINALS[bsearch(FINALS, text)?];
    Some(("", final_))
}

/// 一个具体音节。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Syllable {
    pub id: SyllableId,
    pub text: &'static str,
    pub initial: &'static str,
    pub final_: &'static str,
}

impl Syllable {
    /// 由文本构造音节。
    pub fn from_text(text: &str) -> Option<Self> {
        let id = id_of(text)?;
        let (initial, final_) = split(text)?;
        Some(Self {
            id,
            text: SYLLABLES[id as usize],
            initial,
            final_,
        })
    }

    /// 由 ID 构造音节。
    pub fn from_id(id: SyllableId) -> Option<Self> {
        let text = *SYLLABLES.get(id as usize)?;
        Self::from_text(text)
    }

    /// 首字母（简拼用的那一维）。
    pub fn initial_letter(&self) -> u8 {
        self.text.as_bytes()[0]
    }

    /// 转成词典查询键。
    pub fn query(&self, erhua: bool) -> SyllableQuery {
        SyllableQuery::Full { id: self.id, erhua }
    }
}

/// 音节图/束搜索向词典查询时使用的音节引用。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SyllableQuery {
    /// 全拼：按音节 ID 精确匹配；儿化单独标记。
    Full { id: SyllableId, erhua: bool },
    /// 简拼：只给出该音节的首字母。
    Jianpin { letter: u8 },
}

impl SyllableQuery {
    /// 用于展示/日志的拼音文本。
    pub fn display(self) -> String {
        match self {
            Self::Full { id, erhua } => {
                let text = Syllable::from_id(id).map(|s| s.text).unwrap_or("?");
                if erhua {
                    format!("{text}r")
                } else {
                    text.to_string()
                }
            }
            Self::Jianpin { letter } => jianpin_text(letter).to_string(),
        }
    }

    pub fn is_jianpin(self) -> bool {
        matches!(self, Self::Jianpin { .. })
    }
}

/// 两字母声母 zh/ch/sh 的简拼在查询里的写法：用大写字母和单字母的 z/c/s 区分开。
///
/// 只打 `z` 时 z 和 zh 开头的音节都算（`zg` -> 中国），打了 `zh` 就只算 zh 开头的
/// （`zhch` -> 支持，`zhchi` -> 支持）。
pub const JIANPIN_ZH: u8 = b'Z';
pub const JIANPIN_CH: u8 = b'C';
pub const JIANPIN_SH: u8 = b'S';

/// 两个字母（zh/ch/sh）对应的简拼写法；不是这三个返回 None。
pub fn jianpin_digraph(first: u8, second: u8) -> Option<u8> {
    match (first, second) {
        (b'z', b'h') => Some(JIANPIN_ZH),
        (b'c', b'h') => Some(JIANPIN_CH),
        (b's', b'h') => Some(JIANPIN_SH),
        _ => None,
    }
}

/// 简拼写法对应的拼音文本（`Z` -> `zh`，`g` -> `g`）。
pub fn jianpin_text(letter: u8) -> &'static str {
    const SINGLE: [&str; 26] = [
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r",
        "s", "t", "u", "v", "w", "x", "y", "z",
    ];
    match letter {
        JIANPIN_ZH => "zh",
        JIANPIN_CH => "ch",
        JIANPIN_SH => "sh",
        b'a'..=b'z' => SINGLE[(letter - b'a') as usize],
        _ => "?",
    }
}

/// 简拼写法对应的首字母（词条按首字母建索引）：`Z` -> `z`。
pub fn jianpin_first_letter(letter: u8) -> u8 {
    letter.to_ascii_lowercase()
}

/// 简拼写法是否只认某个两字母声母；是的话返回那个声母。
pub fn jianpin_required_initial(letter: u8) -> Option<&'static str> {
    matches!(letter, JIANPIN_ZH | JIANPIN_CH | JIANPIN_SH).then(|| jianpin_text(letter))
}

/// 候选拼音里的一个音节是不是只打了声母（`z`、`zh`，不算 `zhi`）。
pub fn is_abbrev_syllable(text: &str) -> bool {
    match text.as_bytes() {
        [letter] => is_jianpin_letter(*letter),
        [a, b] => jianpin_digraph(*a, *b).is_some(),
        _ => false,
    }
}

/// 简拼首字母是否合法（a/o/e/i/u/v 不能单独作声母）。
pub fn is_jianpin_letter(letter: u8) -> bool {
    matches!(
        letter,
        b'b' | b'c'
            | b'd'
            | b'f'
            | b'g'
            | b'h'
            | b'j'
            | b'k'
            | b'l'
            | b'm'
            | b'n'
            | b'p'
            | b'q'
            | b'r'
            | b's'
            | b't'
            | b'w'
            | b'x'
            | b'y'
            | b'z'
    )
}

/// 预处理后的输入串。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedInput {
    /// 去掉隔音符后的小写字母。
    pub letters: Vec<u8>,
    /// 必须发生切分的位置（隔音符位置），已去重且升序。
    pub forced_boundaries: Vec<usize>,
    /// 这些位置之前需要附加儿化标记（如 hua'r 中的位置 3）。
    pub erhua_at: Vec<usize>,
}

impl ParsedInput {
    pub fn len(&self) -> usize {
        self.letters.len()
    }

    pub fn is_empty(&self) -> bool {
        self.letters.is_empty()
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.letters).into_owned()
    }

    /// [start, end) 内部是否有强制切分点。
    pub fn forced_between(&self, start: usize, end: usize) -> bool {
        self.forced_boundaries.iter().any(|&b| b > start && b < end)
    }

    /// 结束于 pos 的音节是否需要标记儿化。
    pub fn has_erhua(&self, pos: usize) -> bool {
        self.erhua_at.contains(&pos)
    }
}

/// 输入预处理错误。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    InvalidChar(char),
    DanglingErhua,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidChar(c) => write!(f, "非法字符 {c:?}：拼音输入只允许 a-z 和隔音符 '"),
            Self::DanglingErhua => write!(f, "孤立的儿化标记 r：前面没有可儿化的音节"),
        }
    }
}

impl std::error::Error for ParseError {}

/// 解析输入串：小写 a-z + 隔音符 '。
///
/// 例：
/// - xi'an -> letters=xian, forced=[2]
/// - hua'r -> letters=hua, erhua_at=[3]
/// - huar  -> letters=huar（儿化由音节图识别尾部 r）
pub fn parse(input: &str) -> Result<ParsedInput, ParseError> {
    let mut letters = Vec::with_capacity(input.len());
    let mut forced_boundaries = Vec::new();
    let mut erhua_at = Vec::new();

    for chunk in input.split('\'') {
        if chunk.is_empty() {
            continue;
        }
        if chunk == "r" {
            if letters.is_empty() {
                return Err(ParseError::DanglingErhua);
            }
            let pos = letters.len();
            if !erhua_at.contains(&pos) {
                erhua_at.push(pos);
            }
            continue;
        }

        // 在追加本段之前记录强制边界。
        if !letters.is_empty() {
            let pos = letters.len();
            if forced_boundaries.last().copied() != Some(pos) {
                forced_boundaries.push(pos);
            }
        }
        for c in chunk.chars() {
            if !c.is_ascii_lowercase() {
                return Err(ParseError::InvalidChar(c));
            }
            letters.push(c as u8);
        }
    }

    Ok(ParsedInput {
        letters,
        forced_boundaries,
        erhua_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn syllable_table_is_sorted_and_unique() {
        for pair in SYLLABLES.windows(2) {
            assert!(
                pair[0] < pair[1],
                "音节表未排序或重复: {:?} {:?}",
                pair[0],
                pair[1]
            );
        }
        for pair in FINALS.windows(2) {
            assert!(
                pair[0] < pair[1],
                "韵母表未排序或重复: {:?} {:?}",
                pair[0],
                pair[1]
            );
        }
    }

    #[test]
    fn standard_syllables() {
        assert!(is_valid("xian"));
        assert!(is_valid("xi"));
        assert!(is_valid("an"));
        assert!(is_valid("zhuang"));
        assert!(is_valid("nve"));
        assert!(is_valid("lve"));
        assert!(!is_valid("xiann"));
        assert!(!is_valid("abc"));
        assert!(!is_valid(""));
    }

    #[test]
    fn extended_syllables() {
        for s in [
            "yvan", "xvan", "jvan", "qvan", "yve", "xve", "jve", "qve", "yvn", "xvn", "jvn", "qvn",
            "yv", "xv", "jv", "qv", "hng", "hm", "ng", "fiao", "nou", "nun",
        ] {
            assert!(is_valid(s), "扩展音节缺失: {s}");
        }
    }

    #[test]
    fn split_xian_vs_xi_an() {
        assert_eq!(split("xian"), Some(("x", "ian")));
        assert_eq!(split("xi"), Some(("x", "i")));
        assert_eq!(split("an"), Some(("", "an")));
        assert_eq!(split("er"), Some(("", "er")));
        assert_eq!(split("zhuang"), Some(("zh", "uang")));
        assert_eq!(split("yvan"), Some(("y", "van")));
        assert_eq!(split("jv"), Some(("j", "v")));
        assert_eq!(split("hng"), Some(("", "hng")));
    }

    #[test]
    fn parse_apostrophe_forces_boundary() {
        let p = parse("xi'an").unwrap();
        assert_eq!(p.letters, b"xian");
        assert_eq!(p.forced_boundaries, vec![2]);
        assert!(p.forced_between(0, 4));
        assert!(!p.forced_between(0, 2));
    }

    #[test]
    fn parse_erhua_marker() {
        let p = parse("hua'r").unwrap();
        assert_eq!(p.letters, b"hua");
        assert!(p.erhua_at.contains(&3));
        assert!(p.forced_boundaries.is_empty());
    }

    #[test]
    fn parse_rejects_non_lowercase() {
        assert_eq!(parse("Xian"), Err(ParseError::InvalidChar('X')));
        assert_eq!(parse("xi1an"), Err(ParseError::InvalidChar('1')));
        assert_eq!(parse("r"), Err(ParseError::DanglingErhua));
    }
}
