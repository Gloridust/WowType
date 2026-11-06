//! 命令行 demo：读入拼音串，打印候选。
//!
//! 用法：
//!   cargo run --bin wowtype-demo -- xian
//!   cargo run --bin wowtype-demo -- --lexicon data/demo_lexicon.tsv nihao
//!   echo "zg" | cargo run --bin wowtype-demo
//!
//! 不传拼音参数时从 stdin 逐行读取。

use std::env;
use std::io::{self, BufRead};
use std::process;
use std::sync::Arc;

use wowtype_core::lm::{ArpaLm, BigramLm, LanguageModel};
use wowtype_core::{Engine, Lexicon, MemoryLexicon};

fn usage(program: &str) {
    println!("用法: {program} [选项] [拼音...]");
    println!();
    println!("选项:");
    println!("  --lexicon <file>  TSV 词典（拼音<TAB>词<TAB>频次）");
    println!("  --lm <file>       bigram TSV（prev<TAB>cur<TAB>count），可选");
    println!("  --arpa <file>     ARPA 语言模型（与 --lm 二选一）");
    println!("  --beam <n>        beam size，默认 20");
    println!("  --fuzzy           开启模糊音（z/zh、an/ang 等）");
    println!("  --max <n>         最多显示候选数，默认 10");
    println!("  -h, --help        显示帮助");
    println!();
    println!("默认词典: {}", default_lexicon_path());
}

fn default_lexicon_path() -> String {
    format!("{}/data/demo_lexicon.tsv", env!("CARGO_MANIFEST_DIR"))
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let program = args.first().map(String::as_str).unwrap_or("wowtype-demo");
    let mut lexicon_path = default_lexicon_path();
    let mut lm_path: Option<String> = None;
    let mut arpa_path: Option<String> = None;
    let mut beam: Option<usize> = None;
    let mut fuzzy = false;
    let mut max_candidates = 10usize;
    let mut queries: Vec<String> = Vec::new();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => {
                usage(program);
                return;
            }
            "--lexicon" => {
                i += 1;
                match args.get(i) {
                    Some(value) => lexicon_path = value.clone(),
                    None => fail("--lexicon 需要一个文件路径"),
                }
            }
            "--lm" => {
                i += 1;
                match args.get(i) {
                    Some(value) => lm_path = Some(value.clone()),
                    None => fail("--lm 需要一个文件路径"),
                }
            }
            "--arpa" => {
                i += 1;
                match args.get(i) {
                    Some(value) => arpa_path = Some(value.clone()),
                    None => fail("--arpa 需要一个文件路径"),
                }
            }
            "--beam" => {
                i += 1;
                beam = Some(parse_usize(args.get(i), "--beam"));
            }
            "--fuzzy" => fuzzy = true,
            "--max" => {
                i += 1;
                max_candidates = parse_usize(args.get(i), "--max");
            }
            other if other.starts_with('-') => fail(&format!("未知选项: {other}")),
            other => queries.push(other.to_string()),
        }
        i += 1;
    }

    let lexicon = match MemoryLexicon::from_tsv_path(&lexicon_path) {
        Ok(lexicon) => lexicon,
        Err(error) => fail(&format!("{error:#}")),
    };
    let lm: Arc<dyn LanguageModel> = if let Some(path) = &arpa_path {
        match ArpaLm::from_arpa_path(path) {
            Ok(lm) => Arc::new(lm),
            Err(error) => fail(&format!("{error:#}")),
        }
    } else {
        match &lm_path {
            Some(path) => match BigramLm::from_bigram_tsv_path(path) {
                Ok(lm) => Arc::new(lm),
                Err(error) => fail(&format!("{error:#}")),
            },
            None => Arc::new(BigramLm::default()),
        }
    };
    let lexicon: Arc<dyn Lexicon> = Arc::new(lexicon);
    let mut engine = Engine::new(lexicon, lm);
    if let Some(beam) = beam {
        engine.set_beam_size(beam);
    }
    engine.set_fuzzy(fuzzy);
    engine.set_max_candidates(max_candidates);

    if queries.is_empty() {
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            match line {
                Ok(line) => {
                    let query = line.trim();
                    if !query.is_empty() {
                        run_query(&engine, query);
                    }
                }
                Err(error) => fail(&format!("读取 stdin 失败: {error}")),
            }
        }
    } else {
        for query in &queries {
            run_query(&engine, query);
        }
    }
}

fn parse_usize(value: Option<&String>, flag: &str) -> usize {
    match value {
        Some(value) => match value.parse() {
            Ok(parsed) => parsed,
            Err(_) => fail(&format!("{flag} 需要正整数，收到 {value}")),
        },
        None => fail(&format!("{flag} 需要一个参数")),
    }
}

fn fail(message: &str) -> ! {
    eprintln!("错误: {message}");
    process::exit(2);
}

fn run_query(engine: &Engine, query: &str) {
    let candidates = match engine.try_input(query) {
        Ok(candidates) => candidates,
        Err(error) => {
            println!("输入: {query}");
            println!("  错误: {error:#}");
            return;
        }
    };
    println!("输入: {query}");
    if candidates.is_empty() {
        println!("  (无候选)");
        return;
    }
    for (index, candidate) in candidates.iter().enumerate() {
        let segmentation = candidate
            .words
            .iter()
            .map(|word| word.text.as_str())
            .collect::<Vec<_>>()
            .join(" | ");
        println!(
            "  {:>2}. {}  score={:.4}  pinyin={}  分词={}",
            index + 1,
            candidate.text,
            candidate.score,
            candidate.pinyin,
            segmentation
        );
    }
}
