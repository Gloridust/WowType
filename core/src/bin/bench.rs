//! 词库压测：载入耗时与整条输入的延迟。
//!
//! 合成词库：cargo run --release -p wowtype-core --bin wowtype-bench
//! 真实词库：cargo run --release -p wowtype-core --bin wowtype-bench -- --lexicon lexicon.tsv

use std::sync::Arc;
use std::time::Instant;

use wowtype_core::lm::BigramLm;
use wowtype_core::{Engine, Lexicon, MemoryLexicon, SYLLABLES};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut lexicon_path: Option<String> = None;
    let mut total = 100_000usize;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--lexicon" => {
                i += 1;
                lexicon_path = args.get(i).cloned();
            }
            other => {
                if let Ok(n) = other.parse() {
                    total = n;
                } else {
                    eprintln!("未知参数: {other}");
                    std::process::exit(2);
                }
            }
        }
        i += 1;
    }

    let t0 = Instant::now();
    let (lexicon, label) = match &lexicon_path {
        Some(path) => {
            let lex = MemoryLexicon::from_tsv_path_cached(path).expect("载入词库失败");
            (lex, path.clone())
        }
        None => {
            // 合成词库：音节序列尽量分散，模拟真实分布
            let mut tsv = String::with_capacity(total * 24);
            let n = SYLLABLES.len();
            for k in 0..total {
                let a = SYLLABLES[k % n];
                let b = SYLLABLES[(k * 7 + 3) % n];
                tsv.push_str(a);
                tsv.push(' ');
                tsv.push_str(b);
                tsv.push('\t');
                tsv.push_str(&format!("词{k}"));
                tsv.push('\t');
                tsv.push_str(&format!("{}", 1000 + (k % 5000)));
                tsv.push('\n');
            }
            (
                MemoryLexicon::from_tsv_str(&tsv).expect("构造词库失败"),
                format!("合成 {total} 条"),
            )
        }
    };
    let load = t0.elapsed();
    println!(
        "载入 {label}：{} 条，{:?}（{:.1} 万条/秒）",
        lexicon.len(),
        load,
        lexicon.len() as f64 / load.as_secs_f64() / 10_000.0
    );

    let lm: Arc<dyn wowtype_core::LanguageModel> = Arc::new(BigramLm::default());
    let lex: Arc<dyn Lexicon> = Arc::new(lexicon);
    let engine = Engine::new(lex, lm);

    let queries = ["a", "zhong", "zhongguo", "nihao", "shurufa", "zhongg", "zg"];
    let rounds = 50;
    let mut worst = 0.0f64;
    for q in queries {
        let t = Instant::now();
        for _ in 0..rounds {
            let _ = engine.input(q);
        }
        let per = t.elapsed().as_secs_f64() * 1000.0 / rounds as f64;
        worst = worst.max(per);
        println!("input({q:>10}) : {per:8.3} ms/次");
    }
    println!("最慢一次输入：{worst:.3} ms");
}
