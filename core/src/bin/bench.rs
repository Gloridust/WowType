//! 词库规模压测：用合成词库看查询与整条输入的耗时。
//!
//! cargo run --release -p wowtype-core --bin wowtype-bench

use std::sync::Arc;
use std::time::Instant;

use wowtype_core::lm::BigramLm;
use wowtype_core::{Engine, Lexicon, MemoryLexicon, SYLLABLES};

fn main() {
    let total: usize = std::env::args()
        .nth(1)
        .and_then(|v| v.parse().ok())
        .unwrap_or(100_000);

    // 构造合成词库：音节序列尽量分散，模拟真实分布。
    let mut tsv = String::with_capacity(total * 24);
    let n = SYLLABLES.len();
    for i in 0..total {
        let a = SYLLABLES[i % n];
        let b = SYLLABLES[(i * 7 + 3) % n];
        tsv.push_str(a);
        tsv.push(' ');
        tsv.push_str(b);
        tsv.push('\t');
        tsv.push_str(&format!("词{i}"));
        tsv.push('\t');
        tsv.push_str(&format!("{}", 1000 + (i % 5000)));
        tsv.push('\n');
    }

    let t0 = Instant::now();
    let lexicon = MemoryLexicon::from_tsv_str(&tsv).expect("构造词库失败");
    println!("载入 {total} 条：{:?}", t0.elapsed());

    let lm: Arc<dyn wowtype_core::LanguageModel> = Arc::new(BigramLm::default());
    let lex: Arc<dyn Lexicon> = Arc::new(lexicon);
    let engine = Engine::new(lex, lm);

    // 整条输入（含音节图 + 束搜索 + 排序）
    // 最后两个是半成品输入，会触发尾部补全（最多 32 次完整搜索）
    let queries = ["a", "zhong", "zhongguo", "nihao", "shurufa", "zhongg", "zg"];
    for q in queries {
        let t = Instant::now();
        let rounds = 50;
        for _ in 0..rounds {
            let _ = engine.input(q);
        }
        let per = t.elapsed().as_secs_f64() * 1000.0 / rounds as f64;
        println!("input({q:>10}) : {per:8.3} ms/次");
    }
}
