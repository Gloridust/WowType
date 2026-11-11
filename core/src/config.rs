//! 设置文件 wowtype.conf：键名、取值和默认值只写在这里（下面的 `FIELDS` 表）。
//!
//! 格式和 fcitx5 存的一样：一行 `Key=Value`，`#` 开头是注释，`[节]` 行忽略。
//! 取值也照 fcitx5：开关只认 `True` / `False`，选项名分大小写，PageSize 只收 3–9。
//! 认不出的行（没有 `=`、键名不认识、取值不合法）不报错，这个键保持默认值，只计个数。

use std::ffi::CString;
use std::sync::OnceLock;

use crate::shuangpin::Scheme;
use crate::symbols::PunctStyle;
use crate::Engine;

/// 每次输入最多要多少个候选（约 33 页 × 9 个）。插件里的 kMaxCandidates。
pub const MAX_CANDIDATES: usize = 300;

/// 候选排列。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layout {
    Horizontal,
    Vertical,
}

/// 单按哪个 Shift 切换中英文。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShiftToggle {
    Both,
    Left,
    Right,
    Off,
}

/// 分号、引号选第 2、3 个候选。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelectKeys {
    Off,
    Semicolon,
    SemicolonQuote,
}

/// 全部设置。默认值见 `FIELDS`。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    pub candidate_layout: Layout,
    pub page_size: usize,
    /// 打字途中翻页的键：- =、[ ]、, .、Shift+Tab Tab。
    pub page_keys_minus: bool,
    pub page_keys_bracket: bool,
    pub page_keys_comma: bool,
    pub page_keys_tab: bool,
    pub fuzzy: bool,
    pub fuzzy_zh: bool,
    pub fuzzy_ch: bool,
    pub fuzzy_sh: bool,
    pub fuzzy_nl: bool,
    pub fuzzy_fh: bool,
    pub fuzzy_rl: bool,
    pub fuzzy_an: bool,
    pub fuzzy_en: bool,
    pub fuzzy_in: bool,
    pub fuzzy_ian: bool,
    pub fuzzy_uan: bool,
    pub fuzzy_un: bool,
    pub typo_correction: bool,
    pub shuangpin: bool,
    pub shuangpin_scheme: Scheme,
    pub shift_toggle: ShiftToggle,
    pub traditional: bool,
    pub punctuation_style: PunctStyle,
    pub select_keys: SelectKeys,
    pub date_time: bool,
    pub calculator: bool,
    /// 下面几个是 fcitx5 外壳的功能（工具栏、剪贴板、自动空格），macOS 这一版不用，照样读写。
    pub toolbar: bool,
    pub clipboard_history: bool,
    pub auto_space: bool,
    pub auto_space_letters: bool,
    pub auto_space_digits: bool,
    pub voice: bool,
    /// fcitx5 的键名（Alt_R 等），这一版的会话不用。
    pub voice_key: String,
    pub voice_copy: bool,
    pub emoji_suggest: bool,
    /// fcitx5 的键名，空串表示不用快捷键。这一版的会话不用。
    pub emoji_key: String,
    pub check_update: bool,
    pub translate: bool,
    /// 互译语言代码，见 `translate::LANGUAGES`。
    pub translate_target: String,
    pub translate_base_url: String,
    pub translate_model: String,
    pub translate_formal: bool,
    pub translate_local: bool,
    pub translate_local_model: String,
    pub translate_llama_server: String,
    /// 本地翻译模型闲置几分钟后释放（0 不释放）。
    pub translate_idle_minutes: u32,
}

impl Config {
    /// 打开的模糊音分组（位掩码，和 `syllable::fuzzy` 一致）。
    pub fn fuzzy_groups(&self) -> u32 {
        use crate::syllable::fuzzy;
        [
            (self.fuzzy_zh, fuzzy::ZH),
            (self.fuzzy_ch, fuzzy::CH),
            (self.fuzzy_sh, fuzzy::SH),
            (self.fuzzy_nl, fuzzy::NL),
            (self.fuzzy_fh, fuzzy::FH),
            (self.fuzzy_rl, fuzzy::RL),
            (self.fuzzy_an, fuzzy::AN),
            (self.fuzzy_en, fuzzy::EN),
            (self.fuzzy_in, fuzzy::IN),
            (self.fuzzy_ian, fuzzy::IAN),
            (self.fuzzy_uan, fuzzy::UAN),
            (self.fuzzy_un, fuzzy::UN),
        ]
        .into_iter()
        .filter(|(on, _)| *on)
        .fold(0, |acc, (_, bit)| acc | bit)
    }

    /// 只是 `Default` 的起点：每个字段马上会被 `FIELDS` 里的默认值盖掉。
    fn blank() -> Self {
        Self {
            candidate_layout: Layout::Horizontal,
            page_size: 0,
            page_keys_minus: false,
            page_keys_bracket: false,
            page_keys_comma: false,
            page_keys_tab: false,
            fuzzy: false,
            fuzzy_zh: false,
            fuzzy_ch: false,
            fuzzy_sh: false,
            fuzzy_nl: false,
            fuzzy_fh: false,
            fuzzy_rl: false,
            fuzzy_an: false,
            fuzzy_en: false,
            fuzzy_in: false,
            fuzzy_ian: false,
            fuzzy_uan: false,
            fuzzy_un: false,
            typo_correction: false,
            shuangpin: false,
            shuangpin_scheme: Scheme::Ziranma,
            shift_toggle: ShiftToggle::Both,
            traditional: false,
            punctuation_style: PunctStyle::Fullwidth,
            select_keys: SelectKeys::Off,
            date_time: false,
            calculator: false,
            toolbar: false,
            clipboard_history: false,
            auto_space: false,
            auto_space_letters: false,
            auto_space_digits: false,
            voice: false,
            voice_key: String::new(),
            voice_copy: false,
            emoji_suggest: false,
            emoji_key: String::new(),
            check_update: false,
            translate: false,
            translate_target: String::new(),
            translate_base_url: String::new(),
            translate_model: String::new(),
            translate_formal: false,
            translate_local: false,
            translate_local_model: String::new(),
            translate_llama_server: String::new(),
            translate_idle_minutes: 0,
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        let mut config = Self::blank();
        for field in FIELDS {
            let ok = (field.set)(&mut config, field.default);
            debug_assert!(ok, "{} 的默认值自己都认不出", field.name);
        }
        config
    }
}

/// 一个键：名字、默认值（按文件里的写法）和怎么把取值写进 `Config`。
struct Field {
    name: &'static str,
    default: &'static str,
    /// 取值不合法时返回 false，不改 `Config`。
    set: fn(&mut Config, &str) -> bool,
}

fn boolean(value: &str) -> Option<bool> {
    match value {
        "True" => Some(true),
        "False" => Some(false),
        _ => None,
    }
}

fn pick<T: Copy>(names: &[(&str, T)], value: &str) -> Option<T> {
    names
        .iter()
        .find(|(name, _)| *name == value)
        .map(|(_, v)| *v)
}

const LAYOUTS: &[(&str, Layout)] = &[
    ("Horizontal", Layout::Horizontal),
    ("Vertical", Layout::Vertical),
];
const SHIFT_TOGGLES: &[(&str, ShiftToggle)] = &[
    ("Both", ShiftToggle::Both),
    ("Left", ShiftToggle::Left),
    ("Right", ShiftToggle::Right),
    ("Off", ShiftToggle::Off),
];
const SELECT_KEYS: &[(&str, SelectKeys)] = &[
    ("Off", SelectKeys::Off),
    ("Semicolon", SelectKeys::Semicolon),
    ("SemicolonQuote", SelectKeys::SemicolonQuote),
];
const PUNCT_STYLES: &[(&str, PunctStyle)] = &[
    ("Fullwidth", PunctStyle::Fullwidth),
    ("Halfwidth", PunctStyle::Halfwidth),
];
/// 文件里的双拼方案名（插件的 WowtypeShuangpinScheme）。
const SCHEMES: &[(&str, Scheme)] = &[
    ("Ziranma", Scheme::Ziranma),
    ("Xiaohe", Scheme::Xiaohe),
    ("Microsoft", Scheme::Microsoft),
    ("Sogou", Scheme::Sogou),
    ("ABC", Scheme::Abc),
    ("Ziguang", Scheme::Ziguang),
    ("PinyinJiajia", Scheme::PinyinJiajia),
];

macro_rules! flag {
    ($name:literal, $default:literal, $field:ident) => {
        Field {
            name: $name,
            default: $default,
            set: |c, v| boolean(v).map(|b| c.$field = b).is_some(),
        }
    };
}

macro_rules! text {
    ($name:literal, $default:literal, $field:ident) => {
        Field {
            name: $name,
            default: $default,
            set: |c, v| {
                c.$field = v.to_string();
                true
            },
        }
    };
}

macro_rules! choice {
    ($name:literal, $default:literal, $field:ident, $table:expr) => {
        Field {
            name: $name,
            default: $default,
            set: |c, v| pick($table, v).map(|x| c.$field = x).is_some(),
        }
    };
}

/// 全部键，顺序和插件的 FCITX_CONFIGURATION 一致（fcitx5 按这个顺序存文件）。
const FIELDS: &[Field] = &[
    choice!("CandidateLayout", "Horizontal", candidate_layout, LAYOUTS),
    Field {
        name: "PageSize",
        default: "9",
        set: |c, v| match v.parse::<usize>() {
            Ok(n) if (3..=9).contains(&n) => {
                c.page_size = n;
                true
            }
            _ => false,
        },
    },
    flag!("PageKeysMinusEqual", "True", page_keys_minus),
    flag!("PageKeysBracket", "False", page_keys_bracket),
    flag!("PageKeysCommaPeriod", "False", page_keys_comma),
    flag!("PageKeysTab", "False", page_keys_tab),
    flag!("Fuzzy", "False", fuzzy),
    flag!("FuzzyZh", "True", fuzzy_zh),
    flag!("FuzzyCh", "True", fuzzy_ch),
    flag!("FuzzySh", "True", fuzzy_sh),
    flag!("FuzzyNL", "False", fuzzy_nl),
    flag!("FuzzyFH", "False", fuzzy_fh),
    flag!("FuzzyRL", "False", fuzzy_rl),
    flag!("FuzzyAn", "True", fuzzy_an),
    flag!("FuzzyEn", "True", fuzzy_en),
    flag!("FuzzyIn", "True", fuzzy_in),
    flag!("FuzzyIan", "True", fuzzy_ian),
    flag!("FuzzyUan", "True", fuzzy_uan),
    flag!("FuzzyUn", "False", fuzzy_un),
    flag!("TypoCorrection", "True", typo_correction),
    flag!("Shuangpin", "False", shuangpin),
    choice!("ShuangpinScheme", "Ziranma", shuangpin_scheme, SCHEMES),
    choice!("ShiftToggle", "Both", shift_toggle, SHIFT_TOGGLES),
    flag!("Traditional", "False", traditional),
    choice!(
        "PunctuationStyle",
        "Fullwidth",
        punctuation_style,
        PUNCT_STYLES
    ),
    choice!("SelectKeys", "Off", select_keys, SELECT_KEYS),
    flag!("DateTime", "True", date_time),
    flag!("Calculator", "True", calculator),
    flag!("Toolbar", "True", toolbar),
    flag!("ClipboardHistory", "False", clipboard_history),
    flag!("AutoSpace", "False", auto_space),
    flag!("AutoSpaceLetters", "True", auto_space_letters),
    flag!("AutoSpaceDigits", "True", auto_space_digits),
    flag!("Voice", "True", voice),
    text!("VoiceKey", "Alt_R", voice_key),
    flag!("VoiceCopy", "False", voice_copy),
    flag!("EmojiSuggest", "True", emoji_suggest),
    text!("EmojiKey", "Super+period", emoji_key),
    flag!("CheckUpdate", "True", check_update),
    flag!("Translate", "False", translate),
    Field {
        name: "TranslateTarget",
        default: "en",
        set: |c, v| {
            let known = crate::translate::LANGUAGES
                .iter()
                .any(|(code, _, _)| *code == v);
            if known {
                c.translate_target = v.to_string();
            }
            known
        },
    },
    text!("TranslateBaseUrl", "", translate_base_url),
    text!("TranslateModel", "", translate_model),
    flag!("TranslateFormal", "False", translate_formal),
    flag!("TranslateLocal", "False", translate_local),
    text!("TranslateLocalModel", "", translate_local_model),
    text!("TranslateLlamaServer", "", translate_llama_server),
    Field {
        name: "TranslateIdleMinutes",
        default: "5",
        set: |c, v| match v.parse::<u32>() {
            Ok(n) if n <= 240 => {
                c.translate_idle_minutes = n;
                true
            }
            _ => false,
        },
    },
];

/// 全部键名，按文件里的顺序。
pub fn key_names() -> impl Iterator<Item = &'static str> {
    FIELDS.iter().map(|f| f.name)
}

/// 全部默认值的设置文本（前端第一次写设置文件用）。
pub fn default_ini() -> &'static str {
    default_ini_c().to_str().unwrap_or_default()
}

/// 同 [`default_ini`]，给 C ABI 用（静态，不用释放）。
pub fn default_ini_c() -> &'static std::ffi::CStr {
    static TEXT: OnceLock<CString> = OnceLock::new();
    TEXT.get_or_init(|| {
        let text: String = FIELDS
            .iter()
            .map(|f| format!("{}={}\n", f.name, f.default))
            .collect();
        CString::new(text).unwrap_or_default()
    })
}

/// fcitx5 存字符串时可能加双引号（值里有空格等），去掉引号并还原 \" \\ \n。
fn unquote(value: &str) -> String {
    let Some(inner) = value
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
    else {
        return value.to_string();
    };
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

/// 解析设置文本。返回设置和认不出的行数；没写的键用默认值。
/// 同一个键写两次只看最后一行（和 fcitx 一样：先读成键值表，后写的盖掉先写的，再检查取值），
/// 最后一行不合法就用默认值，前面被盖掉的行不检查。
pub fn parse(text: &str) -> (Config, usize) {
    let mut config = Config::default();
    let mut bad = 0;
    // 每个认识的键最后一次写的值，下标和 FIELDS 一致
    let mut last: Vec<Option<String>> = vec![None; FIELDS.len()];
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with('[') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            bad += 1;
            continue;
        };
        let key = key.trim();
        let value = unquote(value.trim());
        match FIELDS.iter().position(|f| f.name == key) {
            Some(index) => last[index] = Some(value),
            None => bad += 1,
        }
    }
    for (field, value) in FIELDS.iter().zip(&last) {
        if let Some(value) = value {
            if !(field.set)(&mut config, value) {
                bad += 1;
            }
        }
    }
    (config, bad)
}

/// 把和引擎有关的设置用到引擎上，照插件的 applyCoreSettings：候选上限 300、模糊音（总开关 + 分组）、
/// 双拼和方案、纠错、繁体（简繁表要先用 `load_conversion` 载入，没载入时不开）。
pub fn apply_to_engine(engine: &mut Engine, config: &Config) {
    engine.set_max_candidates(MAX_CANDIDATES);
    engine.set_fuzzy(config.fuzzy);
    engine.set_fuzzy_groups(config.fuzzy_groups());
    engine.set_shuangpin(config.shuangpin);
    engine.set_shuangpin_scheme(config.shuangpin_scheme);
    engine.set_typo_correction(config.typo_correction);
    engine.set_traditional(config.traditional && engine.conversion_len() > 0);
}
