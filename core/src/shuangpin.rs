//! 双拼：每个音节两个键（声母键 + 韵母键）。
//!
//! 支持七种常用方案：自然码、小鹤、微软、搜狗、智能 ABC、紫光、拼音加加。
//! 键位表是这些方案公开的键盘布局；写好后逐个音节和 rime 的双拼方案核对过。
//!
//! 双拼只负责把键翻成全拼（`vsgo` -> `zhong'guo`），后面整句、语言模型、句首词、
//! 学习这些都和全拼走同一条路。最后单出来的一个键当声母（`vsg` -> `zhong'g`）。
//!
//! 零声母音节的打法各方案不同：
//! - 自然码、小鹤：单韵母双写（`aa` 啊），双字母韵母照打（`ai` 爱），
//!   也可以「韵母首字母 + 韵母键」（`al` 爱）；
//! - 微软、搜狗、拼音加加：`o` + 韵母键（`oj` 安），也可以「韵母首字母 + 韵母键」；
//! - 智能 ABC、紫光：只用 `o` + 韵母键。

use std::collections::HashMap;
use std::sync::OnceLock;

use crate::syllable::{split, SYLLABLES};

/// 变体上限，防止病态输入把候选数量炸开。
pub const MAX_VARIANTS: usize = 8;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Scheme {
    #[default]
    Ziranma,
    Xiaohe,
    Microsoft,
    Sogou,
    Abc,
    Ziguang,
    PinyinJiajia,
}

pub const SCHEMES: [Scheme; 7] = [
    Scheme::Ziranma,
    Scheme::Xiaohe,
    Scheme::Microsoft,
    Scheme::Sogou,
    Scheme::Abc,
    Scheme::Ziguang,
    Scheme::PinyinJiajia,
];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Zero {
    /// 单韵母双写、双字母韵母照打，或韵母首字母 + 韵母键（自然码、小鹤）
    Natural,
    /// `o` + 韵母键，或韵母首字母 + 韵母键（微软、搜狗、拼音加加）
    OOrFirst,
    /// 只有 `o` + 韵母键（智能 ABC、紫光）
    OOnly,
}

struct Layout {
    zh: u8,
    ch: u8,
    sh: u8,
    /// 多字母韵母（以及改了键的单韵母）的键；一个韵母可以有几个键。
    finals: &'static [(&'static str, u8)],
    zero: Zero,
}

const ZIRANMA: Layout = Layout {
    zh: b'v',
    ch: b'i',
    sh: b'u',
    finals: &[
        ("iu", b'q'),
        ("ia", b'w'),
        ("ua", b'w'),
        ("uan", b'r'),
        ("van", b'r'),
        ("ue", b't'),
        ("ve", b't'),
        ("ing", b'y'),
        ("uai", b'y'),
        ("uo", b'o'),
        ("un", b'p'),
        ("vn", b'p'),
        ("ong", b's'),
        ("iong", b's'),
        ("iang", b'd'),
        ("uang", b'd'),
        ("en", b'f'),
        ("eng", b'g'),
        ("ang", b'h'),
        ("ian", b'm'),
        ("an", b'j'),
        ("iao", b'c'),
        ("ao", b'k'),
        ("ai", b'l'),
        ("ei", b'z'),
        ("ie", b'x'),
        ("ui", b'v'),
        ("ou", b'b'),
        ("in", b'n'),
    ],
    zero: Zero::Natural,
};

const XIAOHE: Layout = Layout {
    zh: b'v',
    ch: b'i',
    sh: b'u',
    finals: &[
        ("iu", b'q'),
        ("ei", b'w'),
        ("uan", b'r'),
        ("ue", b't'),
        ("ve", b't'),
        ("un", b'y'),
        ("uo", b'o'),
        ("ie", b'p'),
        ("ong", b's'),
        ("iong", b's'),
        ("ing", b'k'),
        ("uai", b'k'),
        ("ai", b'd'),
        ("en", b'f'),
        ("eng", b'g'),
        ("iang", b'l'),
        ("uang", b'l'),
        ("ang", b'h'),
        ("ian", b'm'),
        ("an", b'j'),
        ("ou", b'z'),
        ("ia", b'x'),
        ("ua", b'x'),
        ("iao", b'n'),
        ("ao", b'c'),
        ("ui", b'v'),
        ("in", b'b'),
    ],
    zero: Zero::Natural,
};

/// 微软和搜狗只差一处：微软的 üe 除了 t 还能打 v。
const MICROSOFT_FINALS: &[(&str, u8)] = &[
    ("iu", b'q'),
    ("ia", b'w'),
    ("ua", b'w'),
    ("er", b'r'),
    ("uan", b'r'),
    ("van", b'r'),
    ("ue", b't'),
    ("ve", b't'),
    ("ue", b'v'),
    ("ve", b'v'),
    ("v", b'y'),
    ("uai", b'y'),
    ("uo", b'o'),
    ("un", b'p'),
    ("vn", b'p'),
    ("ong", b's'),
    ("iong", b's'),
    ("iang", b'd'),
    ("uang", b'd'),
    ("en", b'f'),
    ("eng", b'g'),
    ("ang", b'h'),
    ("ian", b'm'),
    ("an", b'j'),
    ("iao", b'c'),
    ("ao", b'k'),
    ("ai", b'l'),
    ("ei", b'z'),
    ("ie", b'x'),
    ("ui", b'v'),
    ("ou", b'b'),
    ("in", b'n'),
    ("ing", b';'),
];

const MICROSOFT: Layout = Layout {
    zh: b'v',
    ch: b'i',
    sh: b'u',
    finals: MICROSOFT_FINALS,
    zero: Zero::OOrFirst,
};

const SOGOU: Layout = Layout {
    zh: b'v',
    ch: b'i',
    sh: b'u',
    finals: &[
        ("iu", b'q'),
        ("ia", b'w'),
        ("ua", b'w'),
        ("er", b'r'),
        ("uan", b'r'),
        ("van", b'r'),
        ("ue", b't'),
        ("ve", b't'),
        ("v", b'y'),
        ("uai", b'y'),
        ("uo", b'o'),
        ("un", b'p'),
        ("vn", b'p'),
        ("ong", b's'),
        ("iong", b's'),
        ("iang", b'd'),
        ("uang", b'd'),
        ("en", b'f'),
        ("eng", b'g'),
        ("ang", b'h'),
        ("ian", b'm'),
        ("an", b'j'),
        ("iao", b'c'),
        ("ao", b'k'),
        ("ai", b'l'),
        ("ei", b'z'),
        ("ie", b'x'),
        ("ui", b'v'),
        ("ou", b'b'),
        ("in", b'n'),
        ("ing", b';'),
    ],
    zero: Zero::OOrFirst,
};

const ABC: Layout = Layout {
    zh: b'a',
    ch: b'e',
    sh: b'v',
    finals: &[
        ("ei", b'q'),
        ("ian", b'w'),
        ("er", b'r'),
        ("iu", b'r'),
        ("iang", b't'),
        ("uang", b't'),
        ("ing", b'y'),
        ("uo", b'o'),
        ("uan", b'p'),
        ("ong", b's'),
        ("iong", b's'),
        ("ia", b'd'),
        ("ua", b'd'),
        ("en", b'f'),
        ("eng", b'g'),
        ("ang", b'h'),
        ("an", b'j'),
        ("iao", b'z'),
        ("ao", b'k'),
        ("in", b'c'),
        ("uai", b'c'),
        ("ai", b'l'),
        ("ie", b'x'),
        ("ou", b'b'),
        ("un", b'n'),
        ("ue", b'm'),
        ("ve", b'm'),
        ("ui", b'm'),
    ],
    zero: Zero::OOnly,
};

const ZIGUANG: Layout = Layout {
    zh: b'u',
    ch: b'a',
    sh: b'i',
    finals: &[
        ("en", b'w'),
        ("eng", b't'),
        ("in", b'y'),
        ("uai", b'y'),
        ("uo", b'o'),
        ("ai", b'p'),
        ("iang", b'g'),
        ("uang", b'g'),
        ("ang", b's'),
        ("ie", b'd'),
        ("ian", b'f'),
        ("ong", b'h'),
        ("iong", b'h'),
        ("er", b'j'),
        ("iu", b'j'),
        ("ei", b'k'),
        ("uan", b'l'),
        ("ing", b';'),
        ("ou", b'z'),
        ("ia", b'x'),
        ("ua", b'x'),
        ("iao", b'b'),
        ("ue", b'n'),
        ("ui", b'n'),
        ("ve", b'n'),
        ("un", b'm'),
        ("ao", b'q'),
        ("an", b'r'),
    ],
    zero: Zero::OOnly,
};

const PINYIN_JIAJIA: Layout = Layout {
    zh: b'v',
    ch: b'u',
    sh: b'i',
    finals: &[
        ("iu", b'n'),
        ("ia", b'b'),
        ("ua", b'b'),
        ("er", b'q'),
        ("ing", b'q'),
        ("uan", b'c'),
        ("van", b'c'),
        ("ue", b'x'),
        ("ve", b'x'),
        ("uai", b'x'),
        ("uo", b'o'),
        ("un", b'z'),
        ("vn", b'z'),
        ("ong", b'y'),
        ("iong", b'y'),
        ("iang", b'h'),
        ("uang", b'h'),
        ("en", b'r'),
        ("eng", b't'),
        ("ang", b'g'),
        ("ian", b'j'),
        ("an", b'f'),
        ("iao", b'k'),
        ("ao", b'd'),
        ("ai", b's'),
        ("ei", b'w'),
        ("ie", b'm'),
        ("ui", b'v'),
        ("ou", b'p'),
        ("in", b'l'),
    ],
    zero: Zero::OOrFirst,
};

impl Scheme {
    /// 配置文件里的名字。
    pub fn id(self) -> &'static str {
        match self {
            Scheme::Ziranma => "ziranma",
            Scheme::Xiaohe => "xiaohe",
            Scheme::Microsoft => "microsoft",
            Scheme::Sogou => "sogou",
            Scheme::Abc => "abc",
            Scheme::Ziguang => "ziguang",
            Scheme::PinyinJiajia => "pinyinjiajia",
        }
    }

    /// 界面上显示的名字。
    pub fn name(self) -> &'static str {
        match self {
            Scheme::Ziranma => "自然码",
            Scheme::Xiaohe => "小鹤双拼",
            Scheme::Microsoft => "微软双拼",
            Scheme::Sogou => "搜狗双拼",
            Scheme::Abc => "智能 ABC",
            Scheme::Ziguang => "紫光双拼",
            Scheme::PinyinJiajia => "拼音加加",
        }
    }

    /// 认 id、中文名和几个常见别名（flypy、mspy、jiajia），不分大小写。
    pub fn from_name(name: &str) -> Option<Self> {
        let key: String = name
            .trim()
            .chars()
            .filter(|c| !c.is_whitespace() && *c != '_' && *c != '-')
            .flat_map(char::to_lowercase)
            .collect();
        let alias = match key.as_str() {
            "flypy" | "xiaoheshuangpin" | "小鹤" => "xiaohe",
            "mspy" | "ms" | "微软" => "microsoft",
            "搜狗" => "sogou",
            "智能abc" => "abc",
            "紫光" => "ziguang",
            "jiajia" | "pyjj" => "pinyinjiajia",
            other => other,
        };
        SCHEMES
            .into_iter()
            .find(|s| s.id() == alias || s.name().replace(' ', "").to_lowercase() == alias)
    }

    fn layout(self) -> &'static Layout {
        match self {
            Scheme::Ziranma => &ZIRANMA,
            Scheme::Xiaohe => &XIAOHE,
            Scheme::Microsoft => &MICROSOFT,
            Scheme::Sogou => &SOGOU,
            Scheme::Abc => &ABC,
            Scheme::Ziguang => &ZIGUANG,
            Scheme::PinyinJiajia => &PINYIN_JIAJIA,
        }
    }

    /// 这个方案有没有用分号键（微软、搜狗、紫光的 ing）。
    pub fn uses_semicolon(self) -> bool {
        self.layout().finals.iter().any(|&(_, k)| k == b';')
    }

    /// 是不是这个方案的键（字母，加上用得到的分号）。
    pub fn is_key(self, b: u8) -> bool {
        b.is_ascii_lowercase() || (b == b';' && self.uses_semicolon())
    }
}

fn final_keys(layout: &Layout, final_: &str) -> Vec<u8> {
    let keys: Vec<u8> = layout
        .finals
        .iter()
        .filter(|(f, _)| *f == final_)
        .map(|&(_, k)| k)
        .collect();
    if !keys.is_empty() {
        return keys;
    }
    match final_.as_bytes() {
        [b @ (b'a' | b'o' | b'e' | b'i' | b'u' | b'v')] => vec![*b],
        _ => Vec::new(),
    }
}

/// j q x y 后面的 u 其实是 ü，表里同时有 ju 和 jv 两种写法；只编码 u 的写法。
fn is_v_spelling(syllable: &str) -> bool {
    let b = syllable.as_bytes();
    b.len() >= 2 && matches!(b[0], b'j' | b'q' | b'x' | b'y') && b[1] == b'v'
}

/// 一个全拼音节在这个方案下所有的两键打法。
pub fn encode(scheme: Scheme, syllable: &str) -> Vec<[u8; 2]> {
    let mut out = Vec::new();
    if is_v_spelling(syllable) {
        return out;
    }
    let Some((initial, final_)) = split(syllable) else {
        return out;
    };
    let layout = scheme.layout();
    let keys = final_keys(layout, final_);
    let f = final_.as_bytes();
    let mut push = |code: [u8; 2]| {
        if !out.contains(&code) {
            out.push(code);
        }
    };
    if initial.is_empty() {
        if !matches!(f.first(), Some(b'a' | b'o' | b'e')) {
            return out; // ng、hm 这类没有双拼打法
        }
        if layout.zero == Zero::Natural && f.len() <= 2 {
            push(if f.len() == 1 {
                [f[0], f[0]]
            } else {
                [f[0], f[1]]
            });
        }
        // 微软、搜狗、拼音加加的 ou 也能照打
        if layout.zero == Zero::OOrFirst && final_ == "ou" {
            push([b'o', b'u']);
        }
        for &k in &keys {
            if layout.zero != Zero::OOnly {
                push([f[0], k]);
            }
            if layout.zero != Zero::Natural {
                push([b'o', k]);
            }
        }
        return out;
    }
    let ini = match initial {
        "zh" => layout.zh,
        "ch" => layout.ch,
        "sh" => layout.sh,
        other => other.as_bytes()[0],
    };
    for &k in &keys {
        push([ini, k]);
    }
    // ju、jue、juan、jun 也能按 ü 的键打
    if matches!(initial, "j" | "q" | "x" | "y") && f.first() == Some(&b'u') {
        let v_final = format!("v{}", &final_[1..]);
        for k in final_keys(layout, &v_final) {
            push([ini, k]);
        }
    }
    out
}

fn table(scheme: Scheme) -> &'static HashMap<[u8; 2], Vec<&'static str>> {
    static TABLES: [OnceLock<HashMap<[u8; 2], Vec<&'static str>>>; 7] =
        [const { OnceLock::new() }; 7];
    let idx = SCHEMES.iter().position(|&s| s == scheme).unwrap_or(0);
    TABLES[idx].get_or_init(|| {
        let mut map: HashMap<[u8; 2], Vec<&'static str>> = HashMap::new();
        for syllable in SYLLABLES {
            for code in encode(scheme, syllable) {
                let list = map.entry(code).or_default();
                if !list.contains(syllable) {
                    list.push(*syllable);
                }
            }
        }
        // 重码时冷门读音排后面：SYLLABLES 按字母序，lo（只有「咯」）会排在 luo 前面，
        // 编辑区就显示成 lo'ji（#226）。候选不受影响，各读法的候选按分数合并
        for list in map.values_mut() {
            list.sort_by_key(|s| RARE_READINGS.contains(s));
        }
        map
    })
}

/// 和别的音节撞码时排在后面的冷门读音。
const RARE_READINGS: &[&str] = &["lo"];

/// 两键对应的所有音节（个别方案有少量重码）。
pub fn decode_all(scheme: Scheme, a: u8, b: u8) -> &'static [&'static str] {
    table(scheme)
        .get(&[a.to_ascii_lowercase(), b.to_ascii_lowercase()])
        .map(|v| v.as_slice())
        .unwrap_or(&[])
}

const LETTERS: [&str; 26] = [
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r",
    "s", "t", "u", "v", "w", "x", "y", "z",
];

/// 双拼键对没有合法音节时，按前后鼻音分组把韵母补成 `ing` / `ang` / `eng` 等
/// （小鹤 `db` = d + in -> ding，`tb` -> ting；#306）。
fn fuzzy_pair_options(scheme: Scheme, a: u8, b: u8, groups: u32) -> Vec<&'static str> {
    let layout = scheme.layout();
    let initial = match a {
        key if key == layout.zh => "zh",
        key if key == layout.ch => "ch",
        key if key == layout.sh => "sh",
        b'a'..=b'z' if !matches!(a, b'a' | b'e' | b'o' | b'i' | b'u' | b'v') => {
            LETTERS[(a - b'a') as usize]
        }
        _ => return Vec::new(),
    };
    let mut out = Vec::new();
    for &(final_, key) in layout.finals {
        if key != b {
            continue;
        }
        let (group, completed_final) = match final_ {
            "in" => (crate::syllable::fuzzy::IN, "ing"),
            "an" => (crate::syllable::fuzzy::AN, "ang"),
            "en" => (crate::syllable::fuzzy::EN, "eng"),
            "ian" => (crate::syllable::fuzzy::IAN, "iang"),
            "uan" => (crate::syllable::fuzzy::UAN, "uang"),
            _ => continue,
        };
        if groups & group == 0 {
            continue;
        }
        let completed = format!("{initial}{completed_final}");
        if let Some(syllable) = crate::syllable::Syllable::from_text(&completed) {
            if !out.contains(&syllable.text) {
                out.push(syllable.text);
            }
        }
    }
    out
}

/// 最后单出来的一个键当声母：自然码的 v -> zh，b -> b，a -> a。
pub fn trailing_initial(scheme: Scheme, key: u8) -> Option<&'static str> {
    let layout = scheme.layout();
    let key = key.to_ascii_lowercase();
    if key == layout.zh {
        return Some("zh");
    }
    if key == layout.ch {
        return Some("ch");
    }
    if key == layout.sh {
        return Some("sh");
    }
    const LETTERS: &[&str] = &[
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r",
        "s", "t", "u", "v", "w", "x", "y", "z",
    ];
    match key {
        // 不是声母的元音键：a e o 可以开头（啊、饿、哦），i u v 不行
        b'i' | b'u' | b'v' => None,
        b'a'..=b'z' => Some(LETTERS[(key - b'a') as usize]),
        _ => None,
    }
}

/// 一种解码结果：全拼（音节之间用隔音符）和每个音节在原始输入里的结束位置。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decoded {
    /// `zhong'guo`、`zhong'g`
    pub pinyin: String,
    /// 每个音节：(在 pinyin 里的结束字节, 在原始输入里的结束字节)
    pub ends: Vec<(usize, usize)>,
}

impl Decoded {
    /// 全拼里用掉前 `pinyin_bytes` 字节，对应原始输入的前多少字节；
    /// 落在音节中间时往前取整，一个音节都不到返回 0。
    pub fn raw_bytes(&self, pinyin_bytes: usize, raw_len: usize) -> usize {
        if pinyin_bytes >= self.pinyin.len() {
            return raw_len;
        }
        self.ends
            .iter()
            .take_while(|(p, _)| *p <= pinyin_bytes)
            .last()
            .map(|&(_, r)| r)
            .unwrap_or(0)
    }
}

/// 把双拼输入翻成全拼。有重码时给出几种（最多 [`MAX_VARIANTS`]）；
/// 有一对键对不上任何音节时返回空。用户打的隔音符跳过。
pub fn decode(scheme: Scheme, input: &str) -> Vec<Decoded> {
    decode_with_fuzzy(scheme, input, None)
}

/// 和 [`decode`] 一样，但双拼键对不出来合法音节时，按打开的前后鼻音分组补一个
/// （小鹤 `db` = d + in -> ding，`tb` -> ting；#306）。
pub fn decode_fuzzy(scheme: Scheme, input: &str, groups: u32) -> Vec<Decoded> {
    decode_with_fuzzy(scheme, input, Some(groups))
}

fn decode_with_fuzzy(scheme: Scheme, input: &str, fuzzy_groups: Option<u32>) -> Vec<Decoded> {
    // (键, 这个键之后在原始输入里的字节位置，含紧跟着的隔音符)
    let bytes = input.as_bytes();
    let mut keys: Vec<(u8, usize)> = Vec::new();
    for (i, &b) in bytes.iter().enumerate() {
        let lower = b.to_ascii_lowercase();
        if scheme.is_key(lower) {
            keys.push((lower, i + 1));
        } else if b == b'\'' {
            if let Some(last) = keys.last_mut() {
                last.1 = i + 1;
            }
        } else {
            return Vec::new();
        }
    }
    if keys.is_empty() {
        return Vec::new();
    }
    // 第一个键不能是分号
    if keys[0].0 == b';' {
        return Vec::new();
    }
    let mut variants = vec![Decoded {
        pinyin: String::new(),
        ends: Vec::new(),
    }];
    let pairs = keys.len() / 2;
    for p in 0..pairs {
        let (a, _) = keys[2 * p];
        let (b, end) = keys[2 * p + 1];
        let mut options = decode_all(scheme, a, b).to_vec();
        if options.is_empty() {
            if let Some(groups) = fuzzy_groups {
                options = fuzzy_pair_options(scheme, a, b, groups);
            }
            if options.is_empty() {
                return Vec::new();
            }
        }
        let mut next = Vec::new();
        for prefix in &variants {
            for syllable in &options {
                if next.len() >= MAX_VARIANTS {
                    break;
                }
                let mut d = prefix.clone();
                if !d.pinyin.is_empty() {
                    d.pinyin.push('\'');
                }
                d.pinyin.push_str(syllable);
                d.ends.push((d.pinyin.len(), end));
                next.push(d);
            }
        }
        variants = next;
    }
    if keys.len() % 2 == 1 {
        let (key, end) = keys[keys.len() - 1];
        if let Some(initial) = trailing_initial(scheme, key) {
            for d in &mut variants {
                if !d.pinyin.is_empty() {
                    d.pinyin.push('\'');
                }
                d.pinyin.push_str(initial);
                d.ends.push((d.pinyin.len(), end));
            }
        }
        // 当不了声母的键（i u v）先不管，等下一个键
    }
    variants.retain(|d| !d.ends.is_empty());
    variants
}

/// 简拼（只打声母）里一个键代表的声母：这个方案的 zh / ch / sh 键（自然码、小鹤的 `v` `i` `u`，
/// 智能 ABC 的 `a` `e` `v`）是两字母声母，辅音字母是它自己（`s` 照全拼的简拼算 s 和 sh 开头的都行）。
/// 元音键（零声母音节的开头）和分号不算声母：只打声母时用不到。
pub fn abbrev_initial(scheme: Scheme, key: u8) -> Option<&'static str> {
    let layout = scheme.layout();
    let key = key.to_ascii_lowercase();
    if key == layout.zh {
        return Some("zh");
    }
    if key == layout.ch {
        return Some("ch");
    }
    if key == layout.sh {
        return Some("sh");
    }
    if !crate::syllable::is_jianpin_letter(key) {
        return None;
    }
    trailing_initial(scheme, key)
}

/// 双拼的简拼：每个键都是声母（`sm` -> s'm 什么，自然码 `vg` -> zh'g 中国）时，把每个键当成一个音节的
/// 声母翻成全拼简拼（音节之间加隔音符，`zh` 这种一个键的两字母声母不会再拆成 z、h），`ends` 一个键一项。
/// 少于两个键、有哪个键不是声母时返回 None。用户打的隔音符跳过。
///
/// 和 [`decode`] 不冲突：同样的键按双拼也读得通时（小鹤的 `zg` 是 zeng），由调用方决定两边怎么排
/// （照着打的双拼读法在前，见 `Engine::shuangpin_candidates`）。
pub fn abbrev(scheme: Scheme, input: &str) -> Option<Decoded> {
    let mut d = Decoded {
        pinyin: String::new(),
        ends: Vec::new(),
    };
    for (i, &b) in input.as_bytes().iter().enumerate() {
        if b == b'\'' {
            if let Some(last) = d.ends.last_mut() {
                last.1 = i + 1;
            }
            continue;
        }
        let initial = abbrev_initial(scheme, b)?;
        if !d.pinyin.is_empty() {
            d.pinyin.push('\'');
        }
        d.pinyin.push_str(initial);
        d.ends.push((d.pinyin.len(), i + 1));
    }
    (d.ends.len() >= 2).then_some(d)
}

/// 编辑区显示：`vsgo` -> `zhong'guo`，打了一半 `vsg` -> `zhong'g`。
/// 翻不了的照原样显示。
pub fn display(scheme: Scheme, input: &str) -> String {
    display_with_fuzzy(scheme, input, None)
}

/// 和 [`display`] 一样；模糊音打开时把 `db` 显示成 `ding`（#306）。
pub fn display_fuzzy(scheme: Scheme, input: &str, groups: u32) -> String {
    display_with_fuzzy(scheme, input, Some(groups))
}

fn display_with_fuzzy(scheme: Scheme, input: &str, fuzzy_groups: Option<u32>) -> String {
    let decoded = match fuzzy_groups {
        Some(groups) => decode_fuzzy(scheme, input, groups),
        None => decode(scheme, input),
    };
    match decoded.into_iter().next() {
        Some(d) => {
            let used = d.ends.last().map(|&(_, r)| r).unwrap_or(0);
            let mut shown = d.pinyin;
            if used < input.len() {
                shown.push('\'');
                shown.push_str(&input[used..]);
            }
            shown
        }
        None => input.to_string(),
    }
}

/// 双拼键串翻成全拼音节（空格分隔），取第一种；翻不了返回空串。
pub fn to_full_pinyin(scheme: Scheme, input: &str) -> String {
    decode(scheme, input)
        .into_iter()
        .next()
        .map(|d| d.pinyin.replace('\'', " "))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn codes(scheme: Scheme, syllable: &str) -> Vec<String> {
        encode(scheme, syllable)
            .into_iter()
            .map(|[a, b]| format!("{}{}", a as char, b as char))
            .collect()
    }

    #[test]
    fn ziranma_layout() {
        let s = Scheme::Ziranma;
        assert_eq!(codes(s, "zhong"), ["vs"]);
        assert_eq!(codes(s, "guo"), ["go"]);
        assert_eq!(codes(s, "hao"), ["hk"]);
        assert_eq!(codes(s, "xie"), ["xx"]);
        assert_eq!(codes(s, "xiao"), ["xc"]);
        assert_eq!(codes(s, "xin"), ["xn"]);
        assert_eq!(codes(s, "jia"), ["jw"]);
        assert_eq!(codes(s, "a"), ["aa"]);
        assert_eq!(codes(s, "ai"), ["ai", "al"]);
        assert_eq!(codes(s, "ang"), ["ah"]);
        assert_eq!(codes(s, "er"), ["er"]);
        assert!(codes(s, "jue").contains(&"jt".to_string()));
    }

    #[test]
    fn other_layouts() {
        assert_eq!(codes(Scheme::Xiaohe, "xie"), ["xp"]);
        assert_eq!(codes(Scheme::Xiaohe, "zhuang"), ["vl"]);
        assert_eq!(codes(Scheme::Xiaohe, "ou"), ["ou", "oz"]);
        assert_eq!(codes(Scheme::Microsoft, "ming"), ["m;"]);
        assert_eq!(codes(Scheme::Microsoft, "an"), ["aj", "oj"]);
        assert_eq!(codes(Scheme::Microsoft, "lv"), ["ly"]);
        assert!(codes(Scheme::Microsoft, "lve").contains(&"lv".to_string()));
        assert!(!codes(Scheme::Sogou, "lve").contains(&"lv".to_string()));
        assert_eq!(codes(Scheme::Abc, "zhang"), ["ah"]);
        assert_eq!(codes(Scheme::Abc, "ai"), ["ol"]);
        assert_eq!(codes(Scheme::Ziguang, "chang"), ["as"]);
        assert_eq!(codes(Scheme::Ziguang, "qing"), ["q;"]);
        assert_eq!(codes(Scheme::PinyinJiajia, "shi"), ["ii"]);
        assert_eq!(codes(Scheme::PinyinJiajia, "chu"), ["uu"]);
    }

    #[test]
    fn every_scheme_round_trips() {
        for scheme in SCHEMES {
            let mut total = 0;
            for syllable in SYLLABLES {
                for [a, b] in encode(scheme, syllable) {
                    total += 1;
                    assert!(
                        decode_all(scheme, a, b).contains(syllable),
                        "{scheme:?} {syllable}"
                    );
                }
            }
            assert!(total > 390, "{scheme:?}: 可编码音节太少 {total}");
        }
    }

    #[test]
    fn scheme_names() {
        assert_eq!(Scheme::from_name("flypy"), Some(Scheme::Xiaohe));
        assert_eq!(Scheme::from_name("Microsoft"), Some(Scheme::Microsoft));
        assert_eq!(Scheme::from_name("智能 ABC"), Some(Scheme::Abc));
        assert_eq!(Scheme::from_name("拼音加加"), Some(Scheme::PinyinJiajia));
        assert_eq!(Scheme::from_name("nope"), None);
        for s in SCHEMES {
            assert_eq!(Scheme::from_name(s.id()), Some(s));
        }
    }

    #[test]
    fn decodes_input() {
        let s = Scheme::Ziranma;
        let d = decode(s, "vsgo");
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].pinyin, "zhong'guo");
        assert_eq!(d[0].ends, vec![(5, 2), (9, 4)]);
        // 单出来的键当声母
        assert_eq!(decode(s, "vsg")[0].pinyin, "zhong'g");
        assert_eq!(decode(s, "vsv")[0].pinyin, "zhong'zh");
        // i u v 当不了声母，先不算
        assert_eq!(decode(s, "vsu")[0].pinyin, "zhong'sh");
        assert_eq!(decode(Scheme::Xiaohe, "nii")[0].pinyin, "ni'ch");
        assert!(decode(s, "bb").is_empty());
        assert_eq!(display(s, "nihk"), "ni'hao");
        assert_eq!(to_full_pinyin(s, "nihk"), "ni hao");
        // 分号只在用它的方案里算键
        assert_eq!(decode(Scheme::Microsoft, "m;")[0].pinyin, "ming");
        assert!(decode(Scheme::Ziranma, "m;").is_empty());
    }

    #[test]
    fn fuzzy_fills_in_ing_for_shuangpin() {
        use crate::syllable::fuzzy;
        // 小鹤：d + b = din（不是合法音节），打开 in=ing 以后应该按 ding 走
        let d = decode_fuzzy(Scheme::Xiaohe, "db", fuzzy::IN);
        assert_eq!(d.first().map(|d| d.pinyin.as_str()), Some("ding"));
        let d = decode_fuzzy(Scheme::Xiaohe, "tb", fuzzy::IN);
        assert_eq!(d.first().map(|d| d.pinyin.as_str()), Some("ting"));
        assert_eq!(display_fuzzy(Scheme::Xiaohe, "db", fuzzy::IN), "ding");
        // 没开 in=ing 就还是原来的简拼读法
        assert!(decode_fuzzy(Scheme::Xiaohe, "db", fuzzy::AN).is_empty());
        assert!(decode(Scheme::Xiaohe, "db").is_empty());
        // 本来就合法的音节不受影响
        assert_eq!(decode_fuzzy(Scheme::Xiaohe, "vs", fuzzy::IN)[0].pinyin, "zhong");
    }

    #[test]
    fn abbrev_keys() {
        let pinyin = |s: Scheme, input: &str| abbrev(s, input).map(|d| d.pinyin);
        assert_eq!(pinyin(Scheme::Ziranma, "sm").as_deref(), Some("s'm"));
        assert_eq!(pinyin(Scheme::Ziranma, "vg").as_deref(), Some("zh'g"));
        assert_eq!(pinyin(Scheme::Xiaohe, "uiv").as_deref(), Some("sh'ch'zh"));
        // 智能 ABC 的 zh ch sh 是 a e v
        assert_eq!(pinyin(Scheme::Abc, "aev").as_deref(), Some("zh'ch'sh"));
        assert_eq!(pinyin(Scheme::Abc, "ui"), None);
        // 元音键、单个键不算简拼
        assert_eq!(pinyin(Scheme::Ziranma, "sa"), None);
        assert_eq!(pinyin(Scheme::Ziranma, "s"), None);
        assert_eq!(pinyin(Scheme::Microsoft, "m;"), None);
        let d = abbrev(Scheme::Ziranma, "v'g").unwrap();
        assert_eq!(d.pinyin, "zh'g");
        assert_eq!(d.ends, vec![(2, 2), (4, 3)]);
        assert_eq!(d.raw_bytes(2, 3), 2);
        // 每个方案的 zh ch sh 键都是声母
        for s in SCHEMES {
            let l = s.layout();
            for (key, initial) in [(l.zh, "zh"), (l.ch, "ch"), (l.sh, "sh")] {
                assert_eq!(abbrev_initial(s, key), Some(initial), "{s:?}");
            }
        }
    }

    #[test]
    fn maps_consumed_bytes() {
        let d = &decode(Scheme::Ziranma, "vs'go")[0];
        assert_eq!(d.raw_bytes(5, 5), 3);
        assert_eq!(d.raw_bytes(6, 5), 3);
        assert_eq!(d.raw_bytes(9, 5), 5);
        assert_eq!(d.raw_bytes(2, 5), 0);
    }

    #[test]
    fn common_reading_of_colliding_keys_comes_first() {
        // 各方案里唯一的重码是 lo / luo：常用的 luo 排前面，编辑区显示 luo'ji 而不是 lo'ji（#226）
        for s in SCHEMES {
            for (code, list) in table(s) {
                if list.len() > 1 {
                    assert_eq!(list.as_slice(), &["luo", "lo"], "{s:?} {code:?}");
                }
            }
        }
        assert_eq!(display(Scheme::Ziranma, "loji"), "luo'ji");
        let d = decode(Scheme::Xiaohe, "loji");
        assert_eq!(d.len(), 2);
        assert_eq!(d[1].pinyin, "lo'ji");
    }
}
