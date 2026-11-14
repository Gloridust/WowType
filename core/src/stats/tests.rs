use super::*;
use std::path::PathBuf;

fn temp_path(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "wowtype-stats-{}-{}-{}",
        std::process::id(),
        name,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir.join("stats.json")
}

fn local_ms(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> i64 {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = year - 1900;
    tm.tm_mon = month as i32 - 1;
    tm.tm_mday = day as i32;
    tm.tm_hour = hour as i32;
    tm.tm_min = minute as i32;
    tm.tm_sec = second as i32;
    tm.tm_isdst = -1;
    let time = unsafe { libc::mktime(&mut tm) };
    time as i64 * 1000
}

#[test]
fn classifies_characters() {
    let (count, kinds) = classify("你好 abc 123，。😀👍");
    assert_eq!(count, 12);
    assert_eq!(kinds.han, 2);
    assert_eq!(kinds.latin, 3);
    assert_eq!(kinds.number, 3);
    assert_eq!(kinds.punct, 2);
    assert_eq!(kinds.emoji, 2);
    assert_eq!(kinds.readable(), 5);
}

#[test]
fn whitespace_is_not_counted() {
    let (count, kinds) = classify("  \n\t ");
    assert_eq!(count, 0);
    assert_eq!(kinds, Kinds::default());
}

#[test]
fn joined_emoji_counts_once() {
    let (count, kinds) = classify("👨\u{200d}👩\u{200d}👧");
    assert_eq!(count, 1);
    assert_eq!(kinds.emoji, 1);
    // 没有连接符的两个表情仍然算两个。
    let (count, kinds) = classify("😀😀");
    assert_eq!(count, 2);
    assert_eq!(kinds.emoji, 2);
    // 变体选择符不另算。
    let (count, kinds) = classify("❤\u{fe0f}");
    assert_eq!(count, 1);
    assert_eq!(kinds.emoji, 1);
}

#[test]
fn key_ids_cover_both_platforms() {
    assert_eq!(key_id(0, 8 + 2), Some("Digit1"));
    assert_eq!(key_id(0, 8 + 30), Some("KeyA"));
    assert_eq!(key_id(0, 8 + 57), Some("Space"));
    assert_eq!(key_id(0, 8 + 464), Some("Fn"));
    assert_eq!(key_id(1, 0x12), Some("Digit1"));
    assert_eq!(key_id(1, 0x00), Some("KeyA"));
    assert_eq!(key_id(1, 0x7e), Some("ArrowUp"));
    assert_eq!(key_id(0, 8 + 200), None);
    assert_eq!(key_id(1, 0xff), None);
    assert_eq!(key_id(2, 1), None);
    // 低于 8 的 X11 键码没有对应的物理键。
    assert_eq!(key_id(0, 3), None);
}

#[test]
fn long_press_counts_once() {
    let path = temp_path("hold");
    let mut recorder = Recorder::new(&path);
    let now = local_ms(2026, 11, 14, 10, 0, 0);
    recorder.key(0, 8 + 30, true, now);
    recorder.key(0, 8 + 30, true, now + 30);
    recorder.key(0, 8 + 30, true, now + 60);
    recorder.flush(now).unwrap();
    let document = Document::load(&path).unwrap();
    let day = &document.days[&local_day(now)];
    assert_eq!(day.keys.get("KeyA"), Some(&1));
    assert_eq!(day.keys.len(), 1);
}

#[test]
fn synthetic_repeat_after_release_is_ignored() {
    let path = temp_path("repeat");
    let mut recorder = Recorder::new(&path);
    let now = local_ms(2026, 11, 14, 10, 0, 0);
    recorder.key(0, 8 + 30, true, now);
    recorder.key(0, 8 + 30, false, now + 1);
    recorder.key(0, 8 + 30, true, now + 2); // X11 合成的重复
    recorder.key(0, 8 + 30, false, now + 3);
    recorder.key(0, 8 + 30, true, now + 100); // 真正又按了一次
    recorder.flush(now).unwrap();
    let document = Document::load(&path).unwrap();
    assert_eq!(document.days[&local_day(now)].keys["KeyA"], 2);
}

#[test]
fn active_time_uses_ten_second_gap() {
    let path = temp_path("active");
    let mut recorder = Recorder::new(&path);
    let start = local_ms(2026, 11, 14, 10, 0, 0);
    recorder.commit("你好", "quanpin", "", 0, start);
    recorder.commit("世界", "quanpin", "", 0, start + 5_000);
    recorder.commit("再见", "quanpin", "", 0, start + 5_000 + 10_001);
    recorder.flush(start).unwrap();
    let document = Document::load(&path).unwrap();
    assert_eq!(document.days[&local_day(start)].active_ms, 5_000);
}

#[test]
fn selection_positions_are_counted() {
    let path = temp_path("selection");
    let mut recorder = Recorder::new(&path);
    let now = local_ms(2026, 11, 14, 10, 0, 0);
    recorder.commit("甲", "quanpin", "", 1, now);
    recorder.commit("乙", "quanpin", "", 3, now + 1_000);
    recorder.commit("丙", "quanpin", "", 12, now + 2_000);
    recorder.flush(now).unwrap();
    let document = Document::load(&path).unwrap();
    let day = &document.days[&local_day(now)];
    assert_eq!(day.selections[0], 1);
    assert_eq!(day.selections[2], 1);
    assert_eq!(day.beyond, 1);
    assert_eq!(day.chars, 3);
}

#[test]
fn sources_and_schemes_count_characters() {
    let path = temp_path("sources");
    let mut recorder = Recorder::new(&path);
    let now = local_ms(2026, 11, 14, 10, 0, 0);
    recorder.commit("你好", "shuangpin", "xiaohe", 0, now);
    recorder.commit("ab", "english", "", 0, now + 1_000);
    recorder.flush(now).unwrap();
    let document = Document::load(&path).unwrap();
    let day = &document.days[&local_day(now)];
    assert_eq!(day.sources["shuangpin"], 2);
    assert_eq!(day.sources["english"], 2);
    assert_eq!(day.schemes["xiaohe"], 2);
}

#[test]
fn clear_drops_counts_collected_before_it() {
    let path = temp_path("clear");
    let mut recorder = Recorder::new(&path);
    let now = local_ms(2026, 11, 14, 10, 0, 0);
    recorder.commit("旧", "quanpin", "", 1, now);
    recorder.flush(now).unwrap();
    assert_eq!(Document::load(&path).unwrap().days.len(), 1);

    clear_file(&path, 42).unwrap();
    // 清空之后输入法还攒着上屏：flush 发现代号变了，整批丢掉。
    recorder.commit("还攒着", "quanpin", "", 1, now + 1_000);
    assert!(recorder.held.iter().all(|bits| *bits == 0));
    recorder.flush(now + 1_000).unwrap();
    let document = Document::load(&path).unwrap();
    assert!(document.days.is_empty());
    assert_eq!(document.generation, 42);

    // 之后新打的照常记。
    recorder.commit("新的", "quanpin", "", 1, now + 2_000);
    recorder.flush(now + 2_000).unwrap();
    assert_eq!(Document::load(&path).unwrap().days[&local_day(now + 2_000)].chars, 2);
}

#[test]
fn disabled_statistics_write_nothing() {
    let path = temp_path("disabled");
    set_enabled(&path, false).unwrap();
    let mut recorder = Recorder::new(&path);
    let now = local_ms(2026, 11, 14, 10, 0, 0);
    recorder.commit("你好", "quanpin", "", 1, now);
    recorder.flush(now).unwrap();
    let document = Document::load(&path).unwrap();
    assert!(document.days.is_empty());
    assert!(!document.enabled);
}

#[test]
fn document_round_trips_through_json() {
    let mut document = Document::default();
    let day = Day {
        chars: 12,
        kinds: Kinds {
            han: 10,
            latin: 1,
            punct: 1,
            ..Kinds::default()
        },
        active_ms: 3_000,
        ..Day::default()
    };
    document.days.insert("2026-11-14".to_string(), day);
    document.last_commit_ms = 123;
    document.enabled = false;
    document.generation = 9;
    let bytes = document.to_bytes();
    let parsed = Document::from_bytes(&bytes).unwrap();
    assert_eq!(parsed, document);
}

#[test]
fn damaged_days_are_skipped() {
    let value = br#"{"version":1,"enabled":true,"days":{"2026-11-14":{"chars":2},"yesterday":{"chars":9}}}"#;
    let document = Document::from_bytes(value).unwrap();
    assert_eq!(document.days.len(), 1);
    assert_eq!(document.days["2026-11-14"].chars, 2);
}

#[test]
fn local_day_has_expected_shape() {
    let day = local_day(local_ms(2026, 11, 14, 0, 0, 1));
    assert_eq!(day.len(), 10);
    assert!(is_valid_day(&day));
}

#[test]
fn macos_presses_count_every_time() {
    let path = temp_path("macos");
    let mut recorder = Recorder::new(&path);
    let now = local_ms(2026, 11, 14, 10, 0, 0);
    // InputMethodKit 只送按下，没有松开：连续两次按下都要算。
    recorder.key(1, 0x00, true, now);
    recorder.key(1, 0x00, true, now + 1);
    recorder.key(1, 0x00, false, now + 2);
    recorder.flush(now).unwrap();
    let document = Document::load(&path).unwrap();
    assert_eq!(document.days[&local_day(now)].keys["KeyA"], 2);
}
