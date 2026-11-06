//! 连续会话测试：选词 → 上下文 → 再输入，以及用户词库的持久化。
//!
//! 这些模拟插件实际的使用顺序（commitText 里先记选词、再设上下文）。

use std::sync::Arc;

use wowtype_core::lm::BigramLm;
use wowtype_core::{Engine, Lexicon, MemoryLexicon};

fn engine(lexicon_tsv: &str) -> Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(lexicon_tsv).unwrap());
    Engine::new(lexicon, Arc::new(BigramLm::default()))
}

#[test]
fn context_does_not_leak() {
    let e = engine("xian\t先\t50000\nxi an\t西安\t1000\n");
    e.set_context("我");
    // 没有 LM 时上下文不起作用，但也不该把结果搞坏
    assert!(!e.input("xian").is_empty());
    let before = e.input("xian")[0].text.clone();
    e.set_context("");
    assert_eq!(e.input("xian")[0].text, before);
}

#[test]
fn learned_word_survives_save_load() {
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t5000\n").unwrap());
    let path = std::env::temp_dir().join(format!("wowtype_session_{}.tsv", std::process::id()));
    let _ = std::fs::remove_file(&path);

    {
        // 第一个「进程」：学一个词库外的词
        let e = Engine::new(lexicon.clone(), Arc::new(BigramLm::default()));
        for _ in 0..3 {
            e.record_selection_with_pinyin("阿特", Some("a te"));
        }
        assert_eq!(e.user_words().len(), 1);
        e.save_user_dict(&path).expect("保存用户词库失败");
    }

    {
        // 第二个「进程」：重新加载后应当还能打出来
        let e = Engine::new(lexicon, Arc::new(BigramLm::default()));
        let loaded = e.load_user_dict(&path).expect("加载用户词库失败");
        assert_eq!(loaded, 1);
        assert!(
            e.input("ate").iter().any(|c| c.text == "阿特"),
            "重启后学到的词应当还在: {:?}",
            e.input("ate").iter().map(|c| &c.text).collect::<Vec<_>>()
        );
    }
    let _ = std::fs::remove_file(&path);
}

#[test]
fn typing_two_words_in_sequence() {
    let e = engine("ni hao\t你好\t10000\nshi jie\t世界\t8000\n");
    assert_eq!(e.input("nihao")[0].text, "你好");
    e.record_selection_with_pinyin("你好", Some("ni hao"));
    e.set_context("你好");
    assert_eq!(e.input("shijie")[0].text, "世界");
    e.record_selection_with_pinyin("世界", Some("shi jie"));
    e.set_context("你好世界");
    // 第三个词仍然正常
    assert_eq!(e.input("nihao")[0].text, "你好");
}

#[test]
fn history_does_not_cross_words() {
    // 选了很多次 事，不该影响别的拼音
    let e = engine("shi\t是\t1000\nshi\t事\t900\nni hao\t你好\t5000\n");
    for _ in 0..10 {
        e.record_selection("事");
    }
    assert_eq!(e.input("nihao")[0].text, "你好");
    // 同一个拼音下才会被历史影响
    assert_eq!(e.input("shi")[0].text, "事");
}
#[test]
fn loading_user_dict_twice_does_not_duplicate() {
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t5000\n").unwrap());
    let path = std::env::temp_dir().join(format!("wowtype_dup_{}.tsv", std::process::id()));
    let _ = std::fs::remove_file(&path);

    let e = Engine::new(lexicon, Arc::new(BigramLm::default()));
    e.add_user_word("a te", "阿特", 1000.0).unwrap();
    e.save_user_dict(&path).unwrap();

    let e2 = Engine::new(
        Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t5000\n").unwrap()),
        Arc::new(BigramLm::default()),
    );
    e2.load_user_dict(&path).unwrap();
    e2.load_user_dict(&path).unwrap();
    assert_eq!(
        e2.user_words().len(),
        1,
        "重复加载同一份词库不该产生重复词条"
    );
    let list = e2.input("ate");
    assert_eq!(list.iter().filter(|c| c.text == "阿特").count(), 1);
    let _ = std::fs::remove_file(&path);
}
