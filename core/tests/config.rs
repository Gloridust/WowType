//! 设置文本（wowtype.conf）的解析：键名、取值、默认值和插件一致。

use std::sync::Arc;

use wowtype_core::config::{self, Config, Layout, SelectKeys, ShiftToggle};
use wowtype_core::lm::BigramLm;
use wowtype_core::shuangpin::Scheme;
use wowtype_core::symbols::PunctStyle;
use wowtype_core::{Engine, Lexicon, MemoryLexicon};

#[test]
fn defaults_match_the_addon() {
    let c = Config::default();
    assert_eq!(c.candidate_layout, Layout::Horizontal);
    assert_eq!(c.page_size, 9);
    assert!(!c.fuzzy);
    // 和核心、插件的默认分组一样：z/c/s、an/en/in、ian/uan，不含 n=l、f=h、r=l、un=ong
    assert_eq!(c.fuzzy_groups(), wowtype_core::syllable::fuzzy::DEFAULT);
    assert!(c.page_keys_minus);
    assert!(!c.page_keys_bracket && !c.page_keys_comma && !c.page_keys_tab);
    assert_eq!(c.punctuation_style, PunctStyle::Fullwidth);
    assert!(c.toolbar && !c.clipboard_history);
    assert!(!c.auto_space && c.auto_space_letters && c.auto_space_digits);
    assert!(!c.voice_copy);
    assert!(!c.translate_local);
    assert_eq!(c.translate_local_model, "");
    assert_eq!(c.translate_llama_server, "");
    assert_eq!(c.translate_idle_minutes, 5);
    assert!(c.typo_correction);
    assert!(!c.shuangpin);
    assert_eq!(c.shuangpin_scheme, Scheme::Ziranma);
    assert_eq!(c.shift_toggle, ShiftToggle::Both);
    assert!(!c.traditional);
    assert_eq!(c.select_keys, SelectKeys::Off);
    assert!(c.date_time);
    assert!(c.calculator);
    assert!(c.voice);
    assert_eq!(c.voice_key, "Alt_R");
    assert!(c.emoji_suggest);
    assert_eq!(c.emoji_key, "Super+period");
    assert!(!c.translate);
    assert_eq!(c.translate_target, "en");
    assert_eq!(c.translate_base_url, "");
    assert_eq!(c.translate_model, "");
    assert!(!c.translate_formal);
    assert!(c.check_update);
}

#[test]
fn default_ini_parses_back_to_defaults() {
    let (parsed, bad) = config::parse(config::default_ini());
    assert_eq!(bad, 0, "默认设置文本里不该有认不出的行");
    assert_eq!(parsed, Config::default());
    // 空文本也是默认值
    assert_eq!(config::parse(""), (Config::default(), 0));
}

#[test]
fn default_ini_is_the_block_in_config_md() {
    // docs/CONFIG.md 里列的默认设置必须和代码一致
    let doc = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../docs/CONFIG.md"))
        .expect("读 docs/CONFIG.md");
    let start = doc.find("```ini\n").expect("CONFIG.md 里有 ini 代码块") + "```ini\n".len();
    let end = start + doc[start..].find("```").unwrap();
    assert_eq!(&doc[start..end], config::default_ini());
}

#[test]
fn every_addon_option_is_known() {
    // fcitx5 插件的 FCITX_CONFIGURATION 里的每个键（Settings 是按钮，不存进文件）
    let header = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../fcitx5-addon/src/wowtype_engine.h"
    ))
    .expect("读插件头文件");
    let mut names = Vec::new();
    for piece in header.split("this, \"").skip(1) {
        let name = &piece[..piece.find('"').unwrap()];
        if name != "Settings" {
            names.push(name.to_string());
        }
    }
    assert!(names.len() >= 30, "{names:?}");
    let known: Vec<&str> = config::key_names().collect();
    assert_eq!(names, known, "键名和顺序都要和插件一致");
}

#[test]
fn ini_syntax() {
    let text =
        "# 注释\n[Group]\n\nPageSize=5\n  CandidateLayout = Vertical  \nnot a line\nNoSuchKey=1\n";
    let (c, bad) = config::parse(text);
    assert_eq!(c.page_size, 5);
    assert_eq!(c.candidate_layout, Layout::Vertical);
    assert_eq!(bad, 2, "没有 = 的行和不认识的键都算认不出");
    // 同一个键写两次，只看最后一行（fcitx 的 RawConfig 后写的盖掉先写的，再检查取值）：
    // 最后一行不合法就回到默认值，不留前面合法的那行；前面被盖掉的行不检查
    assert_eq!(config::parse("PageSize=4\nPageSize=6\n").0.page_size, 6);
    assert_eq!(
        config::parse("PageSize=7\nPageSize=99\n"),
        (Config::default(), 1)
    );
    assert_eq!(
        config::parse("PageSize=99\nPageSize=7\n"),
        (
            Config {
                page_size: 7,
                ..Config::default()
            },
            0
        )
    );
    // CRLF 也行
    let want = Config {
        page_size: 4,
        fuzzy: true,
        ..Config::default()
    };
    assert_eq!(config::parse("PageSize=4\r\nFuzzy=True\r\n"), (want, 0));
    // fcitx 写字符串时可能加引号
    assert_eq!(
        config::parse("TranslateBaseUrl=\"http://a b/v1\"\n")
            .0
            .translate_base_url,
        "http://a b/v1"
    );
    // 空值合法的键
    let (c, bad) = config::parse("EmojiKey=\n");
    assert_eq!((c.emoji_key.as_str(), bad), ("", 0));
}

#[test]
fn invalid_values_fall_back_to_defaults() {
    for line in [
        "PageSize=12",
        "PageSize=2",
        "PageSize=nine",
        "Fuzzy=yes",
        "Fuzzy=true",
        "CandidateLayout=Diagonal",
        "ShuangpinScheme=Dvorak",
        "ShuangpinScheme=abc",
        "ShiftToggle=Middle",
        "SelectKeys=Quote",
        "TranslateTarget=zz",
        "PunctuationStyle=fullwidth",
        "PageKeysTab=1",
        "TranslateIdleMinutes=241",
        "TranslateIdleMinutes=-1",
    ] {
        let (c, bad) = config::parse(line);
        assert_eq!(bad, 1, "{line} 应当算认不出");
        assert_eq!(c, Config::default(), "{line} 应当保持默认");
    }
    // 边界值
    assert_eq!(config::parse("PageSize=3").0.page_size, 3);
    assert_eq!(config::parse("PageSize=9").0.page_size, 9);
    assert_eq!(
        config::parse("TranslateIdleMinutes=0")
            .0
            .translate_idle_minutes,
        0
    );
    assert_eq!(
        config::parse("TranslateIdleMinutes=240")
            .0
            .translate_idle_minutes,
        240
    );
}

#[test]
fn enum_values() {
    let (c, bad) = config::parse(
        "ShuangpinScheme=ABC\nShiftToggle=Right\nSelectKeys=SemicolonQuote\nTranslateTarget=ja\n",
    );
    assert_eq!(bad, 0);
    assert_eq!(c.shuangpin_scheme, Scheme::Abc);
    assert_eq!(c.shift_toggle, ShiftToggle::Right);
    assert_eq!(c.select_keys, SelectKeys::SemicolonQuote);
    assert_eq!(c.translate_target, "ja");
    for (name, scheme) in [
        ("Ziranma", Scheme::Ziranma),
        ("Xiaohe", Scheme::Xiaohe),
        ("Microsoft", Scheme::Microsoft),
        ("Sogou", Scheme::Sogou),
        ("Ziguang", Scheme::Ziguang),
        ("PinyinJiajia", Scheme::PinyinJiajia),
    ] {
        let (c, bad) = config::parse(&format!("ShuangpinScheme={name}"));
        assert_eq!((c.shuangpin_scheme, bad), (scheme, 0));
    }
    assert_eq!(
        config::parse("ShiftToggle=Off").0.shift_toggle,
        ShiftToggle::Off
    );
    assert_eq!(
        config::parse("ShiftToggle=Left").0.shift_toggle,
        ShiftToggle::Left
    );
    assert_eq!(
        config::parse("SelectKeys=Semicolon").0.select_keys,
        SelectKeys::Semicolon
    );
    let (c, bad) = config::parse("PunctuationStyle=Halfwidth\nPageKeysCommaPeriod=True\n");
    assert_eq!(bad, 0);
    assert_eq!(c.punctuation_style, PunctStyle::Halfwidth);
    assert!(c.page_keys_comma);
}

#[test]
fn fuzzy_group_bitmask() {
    let (c, _) = config::parse(
        "FuzzyZh=False\nFuzzyCh=False\nFuzzySh=False\nFuzzyNL=True\nFuzzyFH=True\nFuzzyRL=True\n\
         FuzzyAn=False\nFuzzyEn=False\nFuzzyIn=False\nFuzzyIan=False\nFuzzyUan=False\nFuzzyUn=True\n",
    );
    assert_eq!(c.fuzzy_groups(), 8 | 16 | 32 | 2048);
}

fn engine() -> Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(
            "niu nai\t牛奶\t5000\nliu\t流\t3000\nnai\t耐\t3000\nzhong guo\t中国\t8000\n\
             zhi dao\t知道\t6000\n",
        )
        .unwrap(),
    );
    Engine::new(lexicon, Arc::new(BigramLm::default()))
}

fn texts(e: &Engine, input: &str) -> Vec<String> {
    e.input(input).into_iter().map(|c| c.text).collect()
}

#[test]
fn apply_to_engine_like_apply_core_settings() {
    let mut e = engine();
    config::apply_to_engine(&mut e, &Config::default());
    assert_eq!(e.config().max_candidates, 300, "候选上限和插件一样 300");
    assert!(!e.config().fuzzy);
    assert!(e.config().typo_correction);
    assert!(!e.config().shuangpin);

    let (c, _) = config::parse("Fuzzy=True\nTypoCorrection=False\n");
    config::apply_to_engine(&mut e, &c);
    assert!(
        !texts(&e, "liunai").contains(&"牛奶".to_string()),
        "n=l 默认不开"
    );
    let (c, _) = config::parse("Fuzzy=True\nFuzzyNL=True\nTypoCorrection=False\n");
    config::apply_to_engine(&mut e, &c);
    assert_eq!(e.config().fuzzy_groups, c.fuzzy_groups());
    assert!(texts(&e, "liunai").contains(&"牛奶".to_string()));

    let (c, _) = config::parse("Shuangpin=True\nShuangpinScheme=Microsoft\n");
    config::apply_to_engine(&mut e, &c);
    assert!(e.config().shuangpin);
    assert_eq!(e.config().shuangpin_scheme, Scheme::Microsoft);
    assert_eq!(texts(&e, "vsgo")[0], "中国");
}

#[test]
fn traditional_needs_the_conversion_table() {
    let mut e = engine();
    let (c, _) = config::parse("Traditional=True\n");
    config::apply_to_engine(&mut e, &c);
    assert!(
        !e.config().traditional,
        "没载入简繁表时不开繁体（和插件一样）"
    );
    let table = std::env::temp_dir().join(format!("wowtype_cfg_s2t_{}.tsv", std::process::id()));
    std::fs::write(&table, "国\t國\n").unwrap();
    e.load_conversion(&table).unwrap();
    config::apply_to_engine(&mut e, &c);
    assert!(e.config().traditional);
    assert_eq!(texts(&e, "zhongguo")[0], "中國");
    let _ = std::fs::remove_file(&table);
}
