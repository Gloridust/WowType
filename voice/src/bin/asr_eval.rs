//! 离线识别评测：按 10ms 一块模拟流式输入，统计定稿字错率、中间结果跳动。
//!
//! wowtype-asr-eval [--dir 模型目录] [--final-only] list.tsv 音频目录
//!
//! list.tsv 每行 `文件名(不带 .wav)<TAB>参考文本`。字错率去掉标点、数字换成汉字再比。
//! 输出每种定稿算法的整体字错率；中间结果：说完那一刻（定稿前最后一次）的字错率、
//! 「已显示的字被改掉」的次数（越少越不跳），以及第一次出字的时间。

use std::path::PathBuf;
use std::time::Instant;

use wowtype_voice::wav;
use wowtype_voice::wtlocal::{download, load, FinalMode, Stream};

const PARTIAL_EVERY_FRAMES: usize = 30;

fn normalize(s: &str) -> Vec<char> {
    const DIGITS: [char; 10] = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
    s.chars()
        .filter_map(|c| match c {
            '0'..='9' => Some(DIGITS[c as usize - '0' as usize]),
            c if c.is_alphanumeric() => Some(c.to_ascii_lowercase()),
            _ => None,
        })
        .collect()
}

fn edits(a: &[char], b: &[char]) -> usize {
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.iter().enumerate() {
        let mut cur = vec![i + 1; b.len() + 1];
        for (j, cb) in b.iter().enumerate() {
            cur[j + 1] = (prev[j] + usize::from(ca != cb))
                .min(prev[j + 1] + 1)
                .min(cur[j] + 1);
        }
        prev = cur;
    }
    prev[b.len()]
}

/// 新的中间结果改掉了多少个已经显示过的字（只看两者共同长度以内）。
fn rewrites(old: &[char], new: &[char]) -> usize {
    let common = old.iter().zip(new).take_while(|(a, b)| a == b).count();
    old.len() - common
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut dir: Option<PathBuf> = None;
    let mut final_only = false;
    let mut rest = Vec::new();
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--final-only" {
            final_only = true;
        } else if args[i] == "--dir" {
            i += 1;
            dir = args.get(i).map(PathBuf::from);
        } else {
            rest.push(args[i].clone());
        }
        i += 1;
    }
    let [list, audio] = rest.as_slice() else {
        eprintln!("用法: wowtype-asr-eval [--dir 模型目录] list.tsv 音频目录");
        std::process::exit(2);
    };
    let dir = dir.unwrap_or_else(download::default_dir);
    let model = load(&dir).expect("加载模型失败");
    let text = std::fs::read_to_string(list).expect("读 list.tsv");

    let modes = [
        ("整段", FinalMode::Whole),
        ("整段+补静音", FinalMode::WholePad),
        ("分块", FinalMode::Blocks),
    ];
    let partials: &[(&str, usize)] = if final_only {
        &[]
    } else {
        &[("中间·前文100", 100), ("中间·前文200", 200)]
    };
    let modes = if final_only { &modes[..1] } else { &modes[..] };
    let mut final_err = vec![0usize; modes.len()];
    let mut part_err = vec![0usize; partials.len()];
    let mut part_rw = vec![0usize; partials.len()];
    let mut stab_rw = vec![0usize; partials.len()];
    let mut first_ms = vec![0f64; partials.len()];
    let mut total = 0usize;
    let mut items = 0usize;

    for line in text
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
    {
        let Some((name, reference)) = line.split_once('\t') else {
            continue;
        };
        let path = format!("{audio}/{name}.wav");
        let Ok((16_000, 1, pcm)) = wav::read_wav(&path) else {
            eprintln!("跳过 {path}");
            continue;
        };
        let r = normalize(reference);
        total += r.len();
        items += 1;
        let mut row = format!("{name}");
        for (k, (_, prev)) in partials.iter().enumerate() {
            let mut st = Stream::new(model.clone());
            let mut shown: Vec<char> = Vec::new();
            let mut first: Option<usize> = None;
            let mut stab = wowtype_voice::wtlocal::Stabilizer::default();
            let mut stab_shown: Vec<char> = Vec::new();
            for (n, chunk) in pcm.chunks(160).enumerate() {
                st.push(chunk);
                if st.fresh() >= PARTIAL_EVERY_FRAMES {
                    let p: Vec<char> = st.partial_with(*prev).chars().collect();
                    if !p.is_empty() && first.is_none() {
                        first = Some(n * 10);
                    }
                    part_rw[k] += rewrites(&shown, &p);
                    shown = p.clone();
                    let d: Vec<char> = stab.update(&p.iter().collect::<String>()).chars().collect();
                    stab_rw[k] += rewrites(&stab_shown, &d);
                    stab_shown = d;
                }
            }
            let p: Vec<char> = st.partial_with(*prev).chars().collect();
            part_rw[k] += rewrites(&shown, &p);
            part_err[k] += edits(&normalize(&p.iter().collect::<String>()), &r);
            first_ms[k] += first.unwrap_or(pcm.len() / 16) as f64;
        }
        for (k, (_, mode)) in modes.iter().enumerate() {
            let mut st = Stream::new(model.clone());
            for chunk in pcm.chunks(160) {
                st.push(chunk);
            }
            let t = Instant::now();
            let out = st.finish_with(*mode);
            let ms = t.elapsed().as_millis();
            let e = edits(&normalize(&out), &r);
            final_err[k] += e;
            if k == 0 || e > 0 {
                row.push_str(&format!("  [{}:{e} {ms}ms] {out}", modes[k].0));
            }
        }
        println!("{row}");
    }
    println!("\n{items} 条，参考 {total} 字");
    for (k, (label, _)) in modes.iter().enumerate() {
        println!(
            "定稿 {label:<8} 字错率 {:.2}%",
            100.0 * final_err[k] as f64 / total.max(1) as f64
        );
    }
    for (k, (label, _)) in partials.iter().enumerate() {
        println!(
            "{label} 说完时字错率 {:.2}%  改字 {} 次（稳定显示 {} 次）  首字 {:.0}ms",
            100.0 * part_err[k] as f64 / total.max(1) as f64,
            part_rw[k],
            stab_rw[k],
            first_ms[k] / items.max(1) as f64
        );
    }
}
