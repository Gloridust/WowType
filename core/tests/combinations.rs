//! 组合场景测试：多个特性同时开启时是否互相干扰。
//!
//! 之前每个特性都单独测过，但它们组合起来没测过。

use std::sync::Arc;

use wowtype_core::convert::Converter;
use wowtype_core::lm::BigramLm;
use wowtype_core::{Engine, Lexicon, MemoryLexicon};

fn engine(lexicon_tsv: &str) -> Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(lexicon_tsv).unwrap());
    Engine::new(lexicon, Arc::new(BigramLm::default()))
}

#[test]
fn shuangpin_with_fuzzy() {
    // 双拼输入 zidk = zi + dao，词库里只有 zhi dao，需要模糊音兜底
    let mut e = engine("zhi dao\t知道\t5000\n");
    e.set_shuangpin(true);
    e.set_fuzzy(true);
    let list = e.input("zidk");
    assert!(
        list.iter().any(|c| c.text == "知道"),
        "双拼 + 模糊音应当命中 知道: {:?}",
        list.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
}

#[test]
fn traditional_with_user_word() {
    let mut e = engine("ni hao\t你好\t5000\n");
    e.install_converter(Converter::from_tsv_str("国\t國\n").unwrap());
    e.set_traditional(true);
    e.add_user_word("zhong guo", "中国", 1000.0).unwrap();
    let list = e.input("zhongguo");
    assert!(
        list.iter().any(|c| c.text == "中國"),
        "用户词也要跟着转繁体: {:?}",
        list.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
}

#[test]
fn traditional_with_context() {
    let mut e = engine("xian\t先\t50000\nxi an\t西安\t1000\n");
    e.install_converter(Converter::from_tsv_str("安\t安\n").unwrap());
    e.set_traditional(true);
    e.set_context("我");
    // 上下文应当仍然生效（西安），只是输出被转换
    let list = e.input("xian");
    assert!(list.iter().any(|c| c.text == "西安"));
}

#[test]
fn shuangpin_keeps_raw_candidate() {
    let mut e = engine("ni hao\t你好\t5000\n");
    e.set_shuangpin(true);
    // 双拼模式下打英文，原始串要原样给出，而不是被当成双拼键位
    let list = e.input("hello");
    assert!(
        list.iter().any(|c| c.text == "hello"),
        "英文串应当保留: {:?}",
        list.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
}

#[test]
fn repeated_selection_boosts_candidate() {
    // 两个同拼音候选，频次相差不大；连续选低频的那个应当把它顶上来
    let mut e = engine("shi\t是\t1000\nshi\t事\t900\n");
    assert_eq!(e.input("shi")[0].text, "是");
    for _ in 0..6 {
        e.record_selection("事");
    }
    let list = e.input("shi");
    assert_eq!(
        list[0].text,
        "事",
        "多次选用后应当排到前面: {:?}",
        list.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
}
#[test]
fn auto_learn_under_shuangpin() {
    // 插件在双拼模式下会把「键位串」当拼音传进来，自动学习要把它们展开成全拼
    let mut e = engine("ni hao\t你好\t5000\n");
    e.set_shuangpin(true);
    // 阿 = aa，特 = te
    for _ in 0..3 {
        e.record_selection_with_pinyin("阿特", Some("aate"));
    }
    assert_eq!(e.user_words().len(), 1, "双拼下的选词应当能进用户词库");
    let list = e.input("aate");
    assert!(
        list.iter().any(|c| c.text == "阿特"),
        "学到的词应当能用双拼打出来: {:?}",
        list.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
}

#[test]
fn shuangpin_with_traditional() {
    let mut e = engine("zhong guo\t中国\t8000\n");
    e.set_shuangpin(true);
    e.set_traditional(true);
    e.install_converter(Converter::from_tsv_str("国\t國\n").unwrap());
    let list = e.input("vsgo");
    assert!(
        list.iter().any(|c| c.text == "中國"),
        "双拼 + 繁体: {:?}",
        list.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
}

#[test]
fn fuzzy_with_traditional() {
    let mut e = engine("zhong guo\t中国\t8000\n");
    e.set_fuzzy(true);
    e.set_traditional(true);
    e.install_converter(Converter::from_tsv_str("国\t國\n").unwrap());
    // zongguo 靠模糊音匹配 zhong guo，输出再转繁体
    let list = e.input("zongguo");
    assert!(
        list.iter().any(|c| c.text == "中國"),
        "模糊音 + 繁体: {:?}",
        list.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
}
