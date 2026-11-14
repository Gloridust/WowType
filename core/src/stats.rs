//! 打字统计：只记本机的聚合计数（每天多少字、每一类多少、每个键按了几次），
//! 不保存输入内容、按键顺序或上下文。设置界面读同一个 JSON 画统计页。
//!
//! 口径（和设置页的说明一致）：
//! - 速度只算汉字与字母（`han + latin`），数字、标点、表情不算；
//! - 两次上屏间隔超过 [`ACTIVE_GAP_MS`]（10 秒）视为休息，不计入活跃时长；
//! - 连续天数以最后一个有记录的日子为准，今天还没输入时从昨天起算；
//! - 长按只算一次，密码框里的按键不计。
//!
//! 文件由输入法进程写、设置界面只读（清空/开关除外），写入走临时文件 + rename，
//! 读到的永远是完整文件。清空会换一个 `generation`，输入法攒着没写的旧计数发现代号变了就丢掉，
//! 不会在清空之后又写回来。

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde_json::{json, Map, Value};

/// 两次上屏间隔不超过这个值，这段间隔算作活跃输入时间。
pub const ACTIVE_GAP_MS: i64 = 10_000;
/// 攒够这么久（或 [`FLUSH_COMMITS`] 次上屏）写一次文件。
const FLUSH_INTERVAL_MS: i64 = 30_000;
const FLUSH_COMMITS: u32 = 20;
/// 读文件的上限：损坏或恶意文件不能整个读进内存。
const MAX_FILE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_COUNT: u64 = 9_000_000_000_000_000;
const VERSION: u32 = 1;

/// 一天里的字符分类。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Kinds {
    pub han: u64,
    pub latin: u64,
    pub number: u64,
    pub punct: u64,
    pub emoji: u64,
    pub other: u64,
}

impl Kinds {
    pub fn add(&mut self, kind: Kind, amount: u64) {
        let slot = match kind {
            Kind::Han => &mut self.han,
            Kind::Latin => &mut self.latin,
            Kind::Number => &mut self.number,
            Kind::Punct => &mut self.punct,
            Kind::Emoji => &mut self.emoji,
            Kind::Other => &mut self.other,
        };
        *slot = slot.saturating_add(amount).min(MAX_COUNT);
    }

    pub fn readable(&self) -> u64 {
        self.han.saturating_add(self.latin)
    }

    fn merge(&mut self, other: &Self) {
        self.han = self.han.saturating_add(other.han).min(MAX_COUNT);
        self.latin = self.latin.saturating_add(other.latin).min(MAX_COUNT);
        self.number = self.number.saturating_add(other.number).min(MAX_COUNT);
        self.punct = self.punct.saturating_add(other.punct).min(MAX_COUNT);
        self.emoji = self.emoji.saturating_add(other.emoji).min(MAX_COUNT);
        self.other = self.other.saturating_add(other.other).min(MAX_COUNT);
    }

    fn to_json(&self) -> Value {
        json!({
            "han": self.han,
            "latin": self.latin,
            "number": self.number,
            "punct": self.punct,
            "emoji": self.emoji,
            "other": self.other,
        })
    }

    fn from_json(value: Option<&Value>) -> Self {
        let mut out = Self::default();
        let Some(map) = value.and_then(Value::as_object) else {
            return out;
        };
        out.han = number_of(map.get("han"));
        out.latin = number_of(map.get("latin"));
        out.number = number_of(map.get("number"));
        out.punct = number_of(map.get("punct"));
        out.emoji = number_of(map.get("emoji"));
        out.other = number_of(map.get("other"));
        out
    }
}

/// 一个本地日的计数。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Day {
    pub chars: u64,
    pub kinds: Kinds,
    pub active_ms: u64,
    /// 键位 id（W3C `KeyboardEvent.code`）→ 按下次数。
    pub keys: BTreeMap<String, u64>,
    /// 上屏来源（拼音、英文、互译……）→ 字符数。
    pub sources: BTreeMap<String, u64>,
    /// 双拼方案 → 字符数。
    pub schemes: BTreeMap<String, u64>,
    /// 候选位置 1..9 的上屏次数。
    pub selections: [u64; 9],
    /// 比第 9 个更靠后的候选的上屏次数。
    pub beyond: u64,
}

impl Day {
    fn merge(&mut self, other: &Self) {
        self.chars = self.chars.saturating_add(other.chars).min(MAX_COUNT);
        self.kinds.merge(&other.kinds);
        self.active_ms = self
            .active_ms
            .saturating_add(other.active_ms)
            .min(24 * 60 * 60 * 1000);
        for (key, count) in &other.keys {
            let slot = self.keys.entry(key.clone()).or_default();
            *slot = slot.saturating_add(*count).min(MAX_COUNT);
        }
        for (key, count) in &other.sources {
            let slot = self.sources.entry(key.clone()).or_default();
            *slot = slot.saturating_add(*count).min(MAX_COUNT);
        }
        for (key, count) in &other.schemes {
            let slot = self.schemes.entry(key.clone()).or_default();
            *slot = slot.saturating_add(*count).min(MAX_COUNT);
        }
        for (slot, count) in self.selections.iter_mut().zip(other.selections) {
            *slot = slot.saturating_add(count).min(MAX_COUNT);
        }
        self.beyond = self.beyond.saturating_add(other.beyond).min(MAX_COUNT);
    }

    fn to_json(&self) -> Value {
        let selections: Vec<u64> = self.selections.to_vec();
        json!({
            "chars": self.chars,
            "kinds": self.kinds.to_json(),
            "activeMs": self.active_ms,
            "keys": string_map_json(&self.keys),
            "sources": string_map_json(&self.sources),
            "schemes": string_map_json(&self.schemes),
            "selections": selections,
            "beyond": self.beyond,
        })
    }

    fn from_json(value: &Value) -> Self {
        let Some(map) = value.as_object() else {
            return Self::default();
        };
        let mut out = Self {
            chars: number_of(map.get("chars")),
            kinds: Kinds::from_json(map.get("kinds")),
            active_ms: number_of(map.get("activeMs")),
            keys: map_of_numbers(map.get("keys")),
            sources: map_of_numbers(map.get("sources")),
            schemes: map_of_numbers(map.get("schemes")),
            selections: [0; 9],
            beyond: number_of(map.get("beyond")),
        };
        if let Some(ranks) = map.get("selections").and_then(Value::as_array) {
            for (slot, value) in out.selections.iter_mut().zip(ranks) {
                *slot = number_of(Some(value));
            }
        }
        out
    }
}

/// 整份统计文件。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Document {
    /// 用户有没有打开统计。文件不存在时默认打开。
    pub enabled: bool,
    /// 清空代号：每次清空换一个随机数，输入法据此丢掉清空之前攒着的计数。
    pub generation: u64,
    /// 上一次计入统计的上屏时刻（Unix 毫秒），用来算两次上屏的间隔。
    pub last_commit_ms: i64,
    pub days: BTreeMap<String, Day>,
}

impl Default for Document {
    fn default() -> Self {
        Self {
            enabled: true,
            generation: 0,
            last_commit_ms: 0,
            days: BTreeMap::new(),
        }
    }
}

impl Document {
    /// 读统计文件；不存在时是默认文档。JSON 坏了返回错误，不覆盖原文件。
    pub fn load(path: &Path) -> Result<Self, String> {
        let metadata = match fs::metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self::default());
            }
            Err(error) => return Err(format!("读统计文件失败：{error}")),
        };
        if !metadata.is_file() {
            return Err("统计文件不是普通文件".to_string());
        }
        if metadata.len() > MAX_FILE_BYTES {
            return Err("统计文件太大".to_string());
        }
        let bytes = fs::read(path).map_err(|error| format!("读统计文件失败：{error}"))?;
        Self::from_bytes(&bytes)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, String> {
        let value: Value = serde_json::from_slice(bytes).map_err(|_| "统计文件不是合法 JSON".to_string())?;
        let Some(map) = value.as_object() else {
            return Err("统计文件不是对象".to_string());
        };
        let mut days = BTreeMap::new();
        if let Some(entries) = map.get("days").and_then(Value::as_object) {
            for (day, value) in entries {
                if !is_valid_day(day) {
                    continue;
                }
                days.insert(day.clone(), Day::from_json(value));
            }
        }
        Ok(Self {
            enabled: map.get("enabled").and_then(Value::as_bool).unwrap_or(true),
            generation: number_of(map.get("generation")),
            last_commit_ms: map
                .get("lastCommitMs")
                .and_then(Value::as_i64)
                .unwrap_or(0),
            days,
        })
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let days: Map<String, Value> = self
            .days
            .iter()
            .map(|(day, value)| (day.clone(), value.to_json()))
            .collect();
        let document = json!({
            "version": VERSION,
            "enabled": self.enabled,
            "generation": self.generation,
            "lastCommitMs": self.last_commit_ms,
            "days": days,
        });
        serde_json::to_vec_pretty(&document).unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        let bytes = self.to_bytes();
        write_atomic(path, &bytes)
    }

    fn merge(&mut self, other: &Self) {
        for (day, value) in &other.days {
            self.days.entry(day.clone()).or_default().merge(value);
        }
        if other.last_commit_ms > 0 {
            self.last_commit_ms = other.last_commit_ms;
        }
    }
}

/// 输入法进程里的记录器：按键与上屏先攒在内存，再按节流合并进文件。
pub struct Recorder {
    path: PathBuf,
    enabled: bool,
    generation: u64,
    last_commit_ms: i64,
    pending: Document,
    has_pending: bool,
    pending_commits: u32,
    last_write_ms: i64,
    last_refresh_ms: i64,
    /// 按下的键（长按只算一次）：[0] 是 X11 键码，[1] 是 macOS 虚拟键码。
    held: [u64; 8],
    /// 上一次松开的键，用来识破 X11 没有 detectable-repeat 时合成的「松开+按下」。
    last_release: Option<(u32, u32, i64)>,
}

impl Recorder {
    /// 打开一个统计文件；读不出来时按默认文档处理，下一次写会建立文件。
    pub fn new(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let mut recorder = Self {
            path,
            enabled: true,
            generation: 0,
            last_commit_ms: 0,
            pending: Document::default(),
            has_pending: false,
            pending_commits: 0,
            last_write_ms: 0,
            last_refresh_ms: 0,
            held: [0; 8],
            last_release: None,
        };
        recorder.refresh(0);
        recorder
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// 重读文件里的开关、清空代号和上一次上屏时刻。统计关着时丢掉攒着的计数。
    pub fn refresh(&mut self, now_ms: i64) {
        self.last_refresh_ms = now_ms;
        let Ok(document) = Document::load(&self.path) else {
            return;
        };
        self.enabled = document.enabled;
        if document.generation != self.generation {
            // 设置界面清空过：攒着的这批是清空之前打的，丢掉。
            self.generation = document.generation;
            self.pending = Document::default();
            self.has_pending = false;
            self.pending_commits = 0;
            self.last_commit_ms = document.last_commit_ms;
            return;
        }
        if !self.enabled {
            self.pending = Document::default();
            self.has_pending = false;
            self.pending_commits = 0;
        }
        if document.last_commit_ms > 0 {
            self.last_commit_ms = document.last_commit_ms;
        }
    }

    fn maybe_refresh(&mut self, now_ms: i64) {
        if now_ms - self.last_refresh_ms >= FLUSH_INTERVAL_MS {
            self.refresh(now_ms);
        }
    }

    /// 一次物理按键。`down` 为假时只松开（用来识别长按和合成重复）。
    ///
    /// `platform`：0 = X11/fcitx5（`code` 是 XKB 键码，内部减 8 成 evdev），1 = macOS（`NSEvent.keyCode`）。
    pub fn key(&mut self, platform: i32, code: u32, down: bool, now_ms: i64) {
        self.maybe_refresh(now_ms);
        if platform != 0 && platform != 1 {
            return;
        }
        // macOS 的 InputMethodKit 只送按下（没有松开），自动重复由外壳的 `isARepeat` 挡掉，
        // 所以这里不做长按去重；松开事件对 macOS 没有意义。
        if platform == 1 {
            if !down || !self.enabled {
                return;
            }
            let Some(id) = key_id(1, code) else {
                return;
            };
            let day = local_day(now_ms);
            if day.is_empty() {
                return;
            }
            *self
                .pending
                .days
                .entry(day)
                .or_default()
                .keys
                .entry(id.to_string())
                .or_default() += 1;
            self.has_pending = true;
            return;
        }
        let slot = platform as usize;
        if code >= 512 {
            return;
        }
        let Some(id) = key_id(platform, code) else {
            return;
        };
        if !down {
            self.held[slot] &= !(1_u64 << code);
            self.last_release = Some((slot as u32, code, now_ms));
            return;
        }
        if !self.enabled {
            return;
        }
        if self.held[slot] & (1_u64 << code) != 0 {
            return; // 长按的自动重复
        }
        self.held[slot] |= 1_u64 << code;
        if let Some((released_slot, released_code, at)) = self.last_release {
            if released_slot == slot as u32
                && released_code == code
                && now_ms >= at
                && now_ms - at <= 2
            {
                return; // X11 合成的一次重复
            }
        }
        let day = local_day(now_ms);
        if day.is_empty() {
            return;
        }
        *self
            .pending
            .days
            .entry(day)
            .or_default()
            .keys
            .entry(id.to_string())
            .or_default() += 1;
        self.has_pending = true;
    }

    /// 一次上屏。`text` 只用来分类计数，不落盘。
    ///
    /// `cand_index` 是候选在列表里的位置（1 起）；不是选候选上屏时为 0。
    pub fn commit(
        &mut self,
        text: &str,
        source: &str,
        scheme: &str,
        cand_index: u32,
        now_ms: i64,
    ) {
        self.maybe_refresh(now_ms);
        if !self.enabled {
            return;
        }
        let (chars, kinds) = classify(text);
        if chars == 0 {
            return;
        }
        let day = local_day(now_ms);
        if day.is_empty() {
            return;
        }
        let entry = self.pending.days.entry(day).or_default();
        entry.chars = entry.chars.saturating_add(chars).min(MAX_COUNT);
        entry.kinds.merge(&kinds);
        if !source.is_empty() {
            let slot = entry.sources.entry(source.to_string()).or_default();
            *slot = slot.saturating_add(chars).min(MAX_COUNT);
        }
        if !scheme.is_empty() {
            let slot = entry.schemes.entry(scheme.to_string()).or_default();
            *slot = slot.saturating_add(chars).min(MAX_COUNT);
        }
        match cand_index {
            1..=9 => {
                let slot = &mut entry.selections[cand_index as usize - 1];
                *slot = slot.saturating_add(1).min(MAX_COUNT);
            }
            10.. => {
                entry.beyond = entry.beyond.saturating_add(1).min(MAX_COUNT);
            }
            _ => {}
        }
        let gap = now_ms - self.last_commit_ms;
        if self.last_commit_ms > 0 && gap > 0 && gap <= ACTIVE_GAP_MS {
            entry.active_ms = entry
                .active_ms
                .saturating_add(gap as u64)
                .min(24 * 60 * 60 * 1000);
        }
        self.last_commit_ms = now_ms;
        self.pending.last_commit_ms = now_ms;
        self.has_pending = true;
        self.pending_commits += 1;
        if self.pending_commits >= FLUSH_COMMITS
            || now_ms - self.last_write_ms >= FLUSH_INTERVAL_MS
        {
            let _ = self.flush(now_ms);
        }
    }

    /// 把攒着的计数合并进文件。文件被清空过（代号变了）或统计关着时整批丢掉。
    pub fn flush(&mut self, now_ms: i64) -> Result<(), String> {
        self.last_refresh_ms = now_ms;
        let mut document = Document::load(&self.path)?;
        self.enabled = document.enabled;
        if document.generation != self.generation {
            self.generation = document.generation;
            self.pending = Document::default();
            self.has_pending = false;
            self.pending_commits = 0;
            self.last_commit_ms = document.last_commit_ms;
            return Ok(());
        }
        if !self.has_pending {
            return Ok(());
        }
        if !document.enabled {
            self.pending = Document::default();
            self.has_pending = false;
            self.pending_commits = 0;
            return Ok(());
        }
        document.merge(&self.pending);
        document.save(&self.path)?;
        self.last_commit_ms = document.last_commit_ms;
        self.pending = Document::default();
        self.has_pending = false;
        self.pending_commits = 0;
        self.last_write_ms = now_ms;
        Ok(())
    }
}

/// 设置界面用：把清空请求写进文件（保留开关，换一个新代号）。
///
/// 输入法下一次写文件时看到代号变了，丢掉清空之前攒着的计数。
pub fn clear_file(path: &Path, generation: u64) -> Result<(), String> {
    let mut document = Document::load(path).unwrap_or_default();
    document.generation = generation;
    document.days.clear();
    document.last_commit_ms = 0;
    document.save(path)
}

/// 设置界面用：改开关。
pub fn set_enabled(path: &Path, enabled: bool) -> Result<(), String> {
    let mut document = Document::load(path).unwrap_or_default();
    document.enabled = enabled;
    document.save(path)
}

// ---------------- 字符分类

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Han,
    Latin,
    Number,
    Punct,
    Emoji,
    Other,
}

/// 按字符分类；返回（计数字符数, 各类别计数）。空白不计，组合表情算一个字符。
pub fn classify(text: &str) -> (u64, Kinds) {
    let mut kinds = Kinds::default();
    let mut count = 0_u64;
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch.is_whitespace() {
            continue;
        }
        if is_emoji(ch) {
            // 吞掉变体选择符、肤色修饰、键帽组合、零宽连接符和它后面的表情；
            // 没有连接符的两个表情仍然算两个。
            loop {
                let Some(&next) = chars.peek() else { break };
                let code = next as u32;
                if code == 0xfe0f || code == 0x20e3 || (0x1f3fb..=0x1f3ff).contains(&code) {
                    chars.next();
                    continue;
                }
                if code == 0x200d {
                    chars.next();
                    if chars.peek().is_some_and(|c| is_emoji(*c)) {
                        chars.next();
                    }
                    continue;
                }
                break;
            }
            kinds.add(Kind::Emoji, 1);
            count += 1;
            continue;
        }
        kinds.add(kind_of(ch), 1);
        count += 1;
    }
    (count, kinds)
}

fn kind_of(ch: char) -> Kind {
    let code = ch as u32;
    if is_han(code) {
        return Kind::Han;
    }
    if is_latin(code) {
        return Kind::Latin;
    }
    if is_number(code) {
        return Kind::Number;
    }
    if is_punct(code) {
        return Kind::Punct;
    }
    Kind::Other
}

fn is_han(code: u32) -> bool {
    (0x3400..=0x4dbf).contains(&code)
        || (0x4e00..=0x9fff).contains(&code)
        || (0xf900..=0xfaff).contains(&code)
        || (0x20000..=0x323af).contains(&code)
}

fn is_latin(code: u32) -> bool {
    (0x41..=0x5a).contains(&code)
        || (0x61..=0x7a).contains(&code)
        || (0xc0..=0x24f).contains(&code)
        || (0x1e00..=0x1eff).contains(&code)
        || (0xff21..=0xff3a).contains(&code)
        || (0xff41..=0xff5a).contains(&code)
}

fn is_number(code: u32) -> bool {
    (0x30..=0x39).contains(&code) || (0xff10..=0xff19).contains(&code)
}

fn is_punct(code: u32) -> bool {
    (0x21..=0x2f).contains(&code)
        || (0x3a..=0x40).contains(&code)
        || (0x5b..=0x60).contains(&code)
        || (0x7b..=0x7e).contains(&code)
        || (0x3000..=0x303f).contains(&code)
        || (0xfe10..=0xfe1f).contains(&code)
        || (0xfe30..=0xfe4f).contains(&code)
        || (0xff01..=0xff20).contains(&code)
        || (0xff3b..=0xff40).contains(&code)
        || (0xff5b..=0xff65).contains(&code)
}

fn is_emoji(ch: char) -> bool {
    let code = ch as u32;
    (0x1f000..=0x1faff).contains(&code)
        || (0x2600..=0x27bf).contains(&code)
        || (0x2b00..=0x2bff).contains(&code)
        || (0x1f1e6..=0x1f1ff).contains(&code)
}

// ---------------- 键位

/// 物理键码 → `KeyboardEvent.code` 风格的 id。
///
/// `platform`：0 = X11（XKB 键码，evdev + 8；fcitx5 给的就是这个），1 = macOS（`NSEvent.keyCode`）。
/// 热力图画不出的键（F13 以后、媒体键、打印屏幕……）返回 `None`，不计入。
pub fn key_id(platform: i32, code: u32) -> Option<&'static str> {
    match platform {
        0 => x11_key_id(code.checked_sub(8)?),
        1 => macos_key_id(code as u16),
        _ => None,
    }
}

fn x11_key_id(evdev: u32) -> Option<&'static str> {
    Some(match evdev {
        1 => "Escape",
        2 => "Digit1",
        3 => "Digit2",
        4 => "Digit3",
        5 => "Digit4",
        6 => "Digit5",
        7 => "Digit6",
        8 => "Digit7",
        9 => "Digit8",
        10 => "Digit9",
        11 => "Digit0",
        12 => "Minus",
        13 => "Equal",
        14 => "Backspace",
        15 => "Tab",
        16 => "KeyQ",
        17 => "KeyW",
        18 => "KeyE",
        19 => "KeyR",
        20 => "KeyT",
        21 => "KeyY",
        22 => "KeyU",
        23 => "KeyI",
        24 => "KeyO",
        25 => "KeyP",
        26 => "BracketLeft",
        27 => "BracketRight",
        28 => "Enter",
        29 => "ControlLeft",
        30 => "KeyA",
        31 => "KeyS",
        32 => "KeyD",
        33 => "KeyF",
        34 => "KeyG",
        35 => "KeyH",
        36 => "KeyJ",
        37 => "KeyK",
        38 => "KeyL",
        39 => "Semicolon",
        40 => "Quote",
        41 => "Backquote",
        42 => "ShiftLeft",
        43 => "Backslash",
        44 => "KeyZ",
        45 => "KeyX",
        46 => "KeyC",
        47 => "KeyV",
        48 => "KeyB",
        49 => "KeyN",
        50 => "KeyM",
        51 => "Comma",
        52 => "Period",
        53 => "Slash",
        54 => "ShiftRight",
        55 => "NumpadMultiply",
        56 => "AltLeft",
        57 => "Space",
        58 => "CapsLock",
        59 => "F1",
        60 => "F2",
        61 => "F3",
        62 => "F4",
        63 => "F5",
        64 => "F6",
        65 => "F7",
        66 => "F8",
        67 => "F9",
        68 => "F10",
        69 => "NumLock",
        70 => "ScrollLock",
        71 => "Numpad7",
        72 => "Numpad8",
        73 => "Numpad9",
        74 => "NumpadSubtract",
        75 => "Numpad4",
        76 => "Numpad5",
        77 => "Numpad6",
        78 => "NumpadAdd",
        79 => "Numpad1",
        80 => "Numpad2",
        81 => "Numpad3",
        82 => "Numpad0",
        83 => "NumpadDecimal",
        86 => "IntlBackslash",
        87 => "F11",
        88 => "F12",
        89 => "IntlRo",
        92 => "Convert",
        93 => "KanaMode",
        94 => "NonConvert",
        96 => "NumpadEnter",
        97 => "ControlRight",
        98 => "NumpadDivide",
        100 => "AltRight",
        102 => "Home",
        103 => "ArrowUp",
        104 => "PageUp",
        105 => "ArrowLeft",
        106 => "ArrowRight",
        107 => "End",
        108 => "ArrowDown",
        109 => "PageDown",
        110 => "Insert",
        111 => "Delete",
        122 => "Lang1",
        123 => "Lang2",
        124 => "IntlYen",
        125 => "MetaLeft",
        126 => "MetaRight",
        127 => "ContextMenu",
        464 => "Fn",
        _ => return None,
    })
}

fn macos_key_id(code: u16) -> Option<&'static str> {
    Some(match code {
        0x00 => "KeyA",
        0x01 => "KeyS",
        0x02 => "KeyD",
        0x03 => "KeyF",
        0x04 => "KeyH",
        0x05 => "KeyG",
        0x06 => "KeyZ",
        0x07 => "KeyX",
        0x08 => "KeyC",
        0x09 => "KeyV",
        0x0a => "IntlBackslash",
        0x0b => "KeyB",
        0x0c => "KeyQ",
        0x0d => "KeyW",
        0x0e => "KeyE",
        0x0f => "KeyR",
        0x10 => "KeyY",
        0x11 => "KeyT",
        0x12 => "Digit1",
        0x13 => "Digit2",
        0x14 => "Digit3",
        0x15 => "Digit4",
        0x16 => "Digit6",
        0x17 => "Digit5",
        0x18 => "Equal",
        0x19 => "Digit9",
        0x1a => "Digit7",
        0x1b => "Minus",
        0x1c => "Digit8",
        0x1d => "Digit0",
        0x1e => "BracketRight",
        0x1f => "KeyO",
        0x20 => "KeyU",
        0x21 => "BracketLeft",
        0x22 => "KeyI",
        0x23 => "KeyP",
        0x24 => "Enter",
        0x25 => "KeyL",
        0x26 => "KeyJ",
        0x27 => "Quote",
        0x28 => "KeyK",
        0x29 => "Semicolon",
        0x2a => "Backslash",
        0x2b => "Comma",
        0x2c => "Slash",
        0x2d => "KeyN",
        0x2e => "KeyM",
        0x2f => "Period",
        0x30 => "Tab",
        0x31 => "Space",
        0x32 => "Backquote",
        0x33 => "Backspace",
        0x35 => "Escape",
        0x36 => "MetaRight",
        0x37 => "MetaLeft",
        0x38 => "ShiftLeft",
        0x39 => "CapsLock",
        0x3a => "AltLeft",
        0x3b => "ControlLeft",
        0x3c => "ShiftRight",
        0x3d => "AltRight",
        0x3e => "ControlRight",
        0x3f => "Fn",
        0x41 => "NumpadDecimal",
        0x43 => "NumpadMultiply",
        0x45 => "NumpadAdd",
        0x47 => "NumLock",
        0x4b => "NumpadDivide",
        0x4c => "NumpadEnter",
        0x4e => "NumpadSubtract",
        0x52 => "Numpad0",
        0x53 => "Numpad1",
        0x54 => "Numpad2",
        0x55 => "Numpad3",
        0x56 => "Numpad4",
        0x57 => "Numpad5",
        0x58 => "Numpad6",
        0x59 => "Numpad7",
        0x5b => "Numpad8",
        0x5c => "Numpad9",
        0x5d => "IntlYen",
        0x5e => "IntlRo",
        0x60 => "F5",
        0x61 => "F6",
        0x62 => "F7",
        0x63 => "F3",
        0x64 => "F8",
        0x65 => "F9",
        0x66 => "Lang2",
        0x67 => "F11",
        0x68 => "Lang1",
        0x6d => "F10",
        0x6e => "ContextMenu",
        0x6f => "F12",
        0x72 => "Insert",
        0x73 => "Home",
        0x74 => "PageUp",
        0x75 => "Delete",
        0x76 => "F4",
        0x77 => "End",
        0x78 => "F2",
        0x79 => "PageDown",
        0x7a => "F1",
        0x7b => "ArrowLeft",
        0x7c => "ArrowRight",
        0x7d => "ArrowDown",
        0x7e => "ArrowUp",
        _ => return None,
    })
}

// ---------------- 工具

/// Unix 毫秒 → 本地日期 `YYYY-MM-DD`。
pub fn local_day(now_ms: i64) -> String {
    let seconds = now_ms.div_euclid(1000);
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let time = seconds as libc::time_t;
    if unsafe { libc::localtime_r(&time, &mut tm) }.is_null() {
        return String::new();
    }
    format!(
        "{:04}-{:02}-{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday
    )
}

pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn is_valid_day(day: &str) -> bool {
    let bytes = day.as_bytes();
    bytes.len() == 10
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes[..4].iter().all(u8::is_ascii_digit)
        && bytes[5..7].iter().all(u8::is_ascii_digit)
        && bytes[8..].iter().all(u8::is_ascii_digit)
}

fn number_of(value: Option<&Value>) -> u64 {
    value
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .min(MAX_COUNT)
}

fn map_of_numbers(value: Option<&Value>) -> BTreeMap<String, u64> {
    let mut out = BTreeMap::new();
    let Some(map) = value.and_then(Value::as_object) else {
        return out;
    };
    for (key, value) in map {
        let count = number_of(Some(value));
        if count > 0 {
            out.insert(key.clone(), count);
        }
    }
    out
}

fn string_map_json(map: &BTreeMap<String, u64>) -> Value {
    let mut out = Map::new();
    for (key, value) in map {
        out.insert(key.clone(), json!(value));
    }
    Value::Object(out)
}

/// 原子写：同目录临时文件写完后 rename，读到的永远是完整文件。
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let Some(parent) = path.parent() else {
        return Err("统计文件没有目录".to_string());
    };
    fs::create_dir_all(parent).map_err(|error| format!("建统计目录失败：{error}"))?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("stats.json");
    let temporary = parent.join(format!(".{name}.tmp.{}", std::process::id()));
    let result = (|| -> std::io::Result<()> {
        let mut file = {
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                fs::OpenOptions::new()
                    .write(true)
                    .create(true)
                    .truncate(true)
                    .mode(0o600)
                    .open(&temporary)?
            }
            #[cfg(not(unix))]
            {
                fs::File::create(&temporary)?
            }
        };
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if let Err(error) = result {
        let _ = fs::remove_file(&temporary);
        return Err(format!("写统计文件失败：{error}"));
    }
    Ok(())
}

#[cfg(test)]
mod tests;
