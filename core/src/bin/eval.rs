//! 排序评测：给定 (输入, 期望) 的 TSV，统计 top-1 / top-3 命中率。
//!
//! ```
//! cargo run --release -p wowtype-core --bin wowtype-eval -- \
//!     --lexicon lexicon.tsv --eval cases.tsv [--weights coverage_score=1.5,prob=0]
//! ```
//!
//! 用例格式：输入<TAB>期望词（多个可接受答案用 | 分隔）。
//! 这是调排序权重时唯一靠谱的依据——没有数据就是盲调。

use std::sync::Arc;

use wowtype_core::lm::{ArpaLm, BigramLm, LanguageModel};
use wowtype_core::rank::{FeatureWeights, LinearRanker};
use wowtype_core::{Engine, EngineConfig, Lexicon, MemoryLexicon};

fn fail(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(1);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut lexicon_path = String::new();
    let mut eval_path = String::new();
    let mut lm_path: Option<String> = None;
    let mut arpa_path: Option<String> = None;
    let mut beam: Option<usize> = None;
    let mut max_candidates = 10usize;
    let mut top_k = 3usize;
    let mut weights = FeatureWeights::default();
    let mut fuzzy = false;
    let mut shuangpin = false;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--lexicon" => {
                i += 1;
                lexicon_path = args
                    .get(i)
                    .cloned()
                    .unwrap_or_else(|| fail("--lexicon 需要路径"));
            }
            "--eval" => {
                i += 1;
                eval_path = args
                    .get(i)
                    .cloned()
                    .unwrap_or_else(|| fail("--eval 需要路径"));
            }
            "--lm" => {
                i += 1;
                lm_path = args.get(i).cloned();
            }
            "--arpa" => {
                i += 1;
                arpa_path = args.get(i).cloned();
            }
            "--beam" => {
                i += 1;
                beam = args.get(i).and_then(|v| v.parse().ok());
            }
            "--max" => {
                i += 1;
                max_candidates = args.get(i).and_then(|v| v.parse().ok()).unwrap_or(10);
            }
            "--k" => {
                i += 1;
                top_k = args.get(i).and_then(|v| v.parse().ok()).unwrap_or(3).max(1);
            }
            "--weights" => {
                i += 1;
                let spec = args.get(i).cloned().unwrap_or_default();
                if let Err(e) = weights.apply_pairs(&spec) {
                    fail(&e);
                }
            }
            "--fuzzy" => fuzzy = true,
            "--shuangpin" => shuangpin = true,
            "-h" | "--help" => {
                println!(
                    "wowtype-eval --lexicon <tsv> --eval <tsv> [--lm|--arpa <file>] [--beam n] [--k n]"
                );
                println!("            [--max n] [--weights name=v,...] [--fuzzy] [--shuangpin]");
                return;
            }
            other => fail(&format!("未知参数: {other}")),
        }
        i += 1;
    }

    if lexicon_path.is_empty() || eval_path.is_empty() {
        fail("需要 --lexicon 与 --eval");
    }

    let lexicon = match MemoryLexicon::from_tsv_path(&lexicon_path) {
        Ok(v) => v,
        Err(e) => fail(&format!("{e:#}")),
    };
    let lm: Arc<dyn LanguageModel> = if let Some(path) = &arpa_path {
        match ArpaLm::from_arpa_path(path) {
            Ok(v) => Arc::new(v),
            Err(e) => fail(&format!("{e:#}")),
        }
    } else if let Some(path) = &lm_path {
        match BigramLm::from_bigram_tsv_path(path) {
            Ok(v) => Arc::new(v),
            Err(e) => fail(&format!("{e:#}")),
        }
    } else {
        Arc::new(BigramLm::default())
    };

    let lex: Arc<dyn Lexicon> = Arc::new(lexicon);
    let ranker = Arc::new(LinearRanker::new(weights));
    let mut config = EngineConfig::default();
    config.max_candidates = max_candidates;
    config.fuzzy = fuzzy;
    config.shuangpin = shuangpin;
    if let Some(size) = beam {
        config.beam.beam_size = size.max(1);
    }
    let engine = Engine::new(lex, lm).with_config(config).with_ranker(ranker);

    let data = match std::fs::read_to_string(&eval_path) {
        Ok(v) => v,
        Err(e) => fail(&format!("读取用例失败: {e}")),
    };

    let mut total = 0usize;
    let mut top1 = 0usize;
    let mut top3 = 0usize;
    let mut misses: Vec<String> = Vec::new();

    for line in data.lines() {
        let line = line.trim_end();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut cols = line.split('\t');
        let (Some(input), Some(expected)) = (cols.next(), cols.next()) else {
            continue;
        };
        let accepted: Vec<&str> = expected.split('|').map(str::trim).collect();
        let candidates = engine.input(input);
        total += 1;
        let texts: Vec<&str> = candidates.iter().map(|c| c.text.as_str()).collect();
        let hit1 = texts.first().map(|t| accepted.contains(t)).unwrap_or(false);
        if hit1 {
            top1 += 1;
        }
        let hit3 = texts.iter().take(top_k).any(|t| accepted.contains(t));
        if hit3 {
            top3 += 1;
        }
        if !hit3 {
            misses.push(format!(
                "  {input:<12} 期望 {:<6} 实际 {}",
                expected,
                texts.join(", ")
            ));
        }
    }

    if total == 0 {
        fail("没有可用的用例");
    }
    let pct = |n: usize| n as f64 * 100.0 / total as f64;
    println!(
        "用例 {total}  top1 {top1} ({:.1}%)  top{top_k} {top3} ({:.1}%)",
        pct(top1),
        pct(top3)
    );
    if !misses.is_empty() {
        println!("未进前 {top_k}：");
        for line in misses {
            println!("{line}");
        }
    }
}
