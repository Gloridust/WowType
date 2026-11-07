//! C ABI：供 fcitx5 的 C++ 插件通过 cdylib 调用。
//!
//! 设计成“不透明句柄 + 候选句柄”，避免 C++ 侧解析 JSON。字符串一律 UTF-8。

// 安全契约见 core/include/wowtype_core.h：空指针、句柄生命周期由调用方保证。
#![allow(clippy::missing_safety_doc)]

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::panic;
use std::ptr;
use std::sync::Arc;

use crate::lexicon::{Lexicon, MemoryLexicon};
use crate::lm::{BigramLm, LanguageModel};
use crate::Engine;

thread_local! {
    static LAST_ERROR: RefCell<CString> =
        RefCell::new(CString::new("no error").expect("static error string"));
}

fn set_last_error(message: impl Into<String>) {
    let text = message.into().replace('\0', " ");
    let value = CString::new(text)
        .unwrap_or_else(|_| CString::new("unknown error").expect("static error string"));
    LAST_ERROR.with(|slot| *slot.borrow_mut() = value);
}

unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

/// 引擎句柄。
pub struct WowtypeEngineHandle {
    engine: Engine,
}

/// 一次输入产生的候选集合（预测结果也用这个结构承载）。
pub struct WowtypeCandidates {
    texts: Vec<CString>,
    scores: Vec<f64>,
    /// 候选对应的拼音（空格分隔音节）；预测、符号结果为空串。
    pinyins: Vec<CString>,
    /// 候选用掉了输入的多少字节；整句候选等于输入长度。
    consumed: Vec<usize>,
}

impl WowtypeCandidates {
    /// 只有文本和分数的结果（预测、符号）。
    fn plain(texts: Vec<CString>, scores: Vec<f64>) -> Self {
        let n = texts.len();
        Self {
            texts,
            scores,
            pinyins: vec![CString::default(); n],
            consumed: vec![0; n],
        }
    }
}

/// 创建引擎。
///
/// lexicon_tsv_path 必填；bigram_tsv_path 可为 NULL/空串，表示不加载 LM。
/// 失败返回 NULL，错误信息用 wowtype_last_error 获取。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_new(
    lexicon_tsv_path: *const c_char,
    bigram_tsv_path: *const c_char,
) -> *mut WowtypeEngineHandle {
    let lexicon_path = match unsafe { cstr_to_str(lexicon_tsv_path) } {
        Some(path) if !path.is_empty() => path,
        _ => {
            set_last_error("lexicon path is null or empty");
            return ptr::null_mut();
        }
    };

    let result = (|| -> anyhow::Result<Engine> {
        let lexicon = MemoryLexicon::from_tsv_path_cached(lexicon_path)?;
        let lexicon: Arc<dyn Lexicon> = Arc::new(lexicon);
        let lm: Arc<dyn LanguageModel> = match unsafe { cstr_to_str(bigram_tsv_path) } {
            Some(path) if !path.is_empty() => Arc::new(BigramLm::from_bigram_tsv_path(path)?),
            _ => Arc::new(BigramLm::default()),
        };
        Ok(Engine::new(lexicon, lm))
    })();

    match result {
        Ok(engine) => Box::into_raw(Box::new(WowtypeEngineHandle { engine })),
        Err(error) => {
            set_last_error(format!("{error:#}"));
            ptr::null_mut()
        }
    }
}

/// 释放引擎。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_free(engine: *mut WowtypeEngineHandle) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

/// 设置 beam size；返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_set_beam_size(
    engine: *mut WowtypeEngineHandle,
    beam_size: u32,
) -> c_int {
    match unsafe { engine.as_mut() } {
        Some(handle) => {
            handle.engine.set_beam_size(beam_size as usize);
            0
        }
        None => {
            set_last_error("engine handle is null");
            -1
        }
    }
}

/// 输入拼音串，返回候选句柄；失败返回 NULL。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_input(
    engine: *mut WowtypeEngineHandle,
    input: *const c_char,
) -> *mut WowtypeCandidates {
    let handle = match unsafe { engine.as_ref() } {
        Some(handle) => handle,
        None => {
            set_last_error("engine handle is null");
            return ptr::null_mut();
        }
    };
    let input = match unsafe { cstr_to_str(input) } {
        Some(input) => input,
        None => {
            set_last_error("input is null or not valid UTF-8");
            return ptr::null_mut();
        }
    };

    let outcome = panic::catch_unwind(panic::AssertUnwindSafe(|| handle.engine.try_input(input)));
    match outcome {
        Ok(Ok(candidates)) => {
            let mut texts = Vec::with_capacity(candidates.len());
            let mut scores = Vec::with_capacity(candidates.len());
            let mut pinyins = Vec::with_capacity(candidates.len());
            let mut consumed = Vec::with_capacity(candidates.len());
            for candidate in candidates {
                let text = candidate.text.replace('\0', " ");
                texts.push(CString::new(text).unwrap_or_default());
                scores.push(candidate.score);
                pinyins.push(CString::new(candidate.pinyin.replace('\0', " ")).unwrap_or_default());
                consumed.push(candidate.consumed.min(input.len()));
            }
            Box::into_raw(Box::new(WowtypeCandidates {
                texts,
                scores,
                pinyins,
                consumed,
            }))
        }
        Ok(Err(error)) => {
            set_last_error(format!("{error:#}"));
            ptr::null_mut()
        }
        Err(_) => {
            set_last_error("Rust panic while processing input");
            ptr::null_mut()
        }
    }
}

/// 基于上一词的预测（预测词库）。
///
/// 成功返回候选集合句柄（text 是预测词，score 是对数概率），
/// 失败返回 NULL；结果同样用 wowtype_candidates_free 释放。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_predict_next(
    engine: *const WowtypeEngineHandle,
    prev_word: *const c_char,
    limit: usize,
) -> *mut WowtypeCandidates {
    let outcome = panic::catch_unwind(panic::AssertUnwindSafe(|| {
        if engine.is_null() {
            set_last_error("engine is null");
            return ptr::null_mut();
        }
        let Some(prev) = (unsafe { cstr_to_str(prev_word) }) else {
            set_last_error("prev_word is null or not utf8");
            return ptr::null_mut();
        };
        let items = unsafe { &*engine }.engine.predict_next(prev, limit);
        let mut texts = Vec::with_capacity(items.len());
        let mut scores = Vec::with_capacity(items.len());
        for (word, score) in items {
            match CString::new(word) {
                Ok(text) => {
                    texts.push(text);
                    scores.push(score);
                }
                Err(_) => continue,
            }
        }
        Box::into_raw(Box::new(WowtypeCandidates::plain(texts, scores)))
    }));
    match outcome {
        Ok(candidates) => candidates,
        Err(_) => {
            set_last_error("panic in wowtype_engine_predict_next");
            ptr::null_mut()
        }
    }
}

/// 记录一次选词，用于历史特征。返回 0 表示成功。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_record_selection(
    engine: *mut WowtypeEngineHandle,
    word: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(word) = (unsafe { cstr_to_str(word) }) else {
        set_last_error("word is null or not utf8");
        return -1;
    };
    unsafe { &*engine }.engine.record_selection(word);
    0
}

/// 设置光标前文本，用于上下文 bigram 特征。返回 0 表示成功。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_set_context(
    engine: *mut WowtypeEngineHandle,
    text: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(text) = (unsafe { cstr_to_str(text) }) else {
        set_last_error("context is null or not utf8");
        return -1;
    };
    unsafe { &*engine }.engine.set_context(text);
    0
}

/// 添加用户词。返回 0 成功，-1 失败（拼音非法等）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_add_user_word(
    engine: *mut WowtypeEngineHandle,
    pinyin: *const c_char,
    word: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let (Some(pinyin), Some(word)) = (unsafe { cstr_to_str(pinyin) }, unsafe { cstr_to_str(word) })
    else {
        set_last_error("pinyin or word is null/not utf8");
        return -1;
    };
    match unsafe { &*engine }
        .engine
        .add_user_word(pinyin, word, 5000.0)
    {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 删除用户词。返回 1 删掉了，0 没找到，-1 出错。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_remove_user_word(
    engine: *mut WowtypeEngineHandle,
    word: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(word) = (unsafe { cstr_to_str(word) }) else {
        set_last_error("word is null or not utf8");
        return -1;
    };
    if unsafe { &*engine }.engine.remove_user_word(word) {
        1
    } else {
        0
    }
}

/// 保存用户词到 TSV。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_save_user_dict(
    engine: *mut WowtypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.save_user_dict(path) {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 从 TSV 载入用户词，返回载入条数，-1 表示出错。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_load_user_dict(
    engine: *mut WowtypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_user_dict(path) {
        Ok(n) => n as c_int,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 保存用户输入习惯（选过的词的热度、词搭配）到 TSV。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_save_history(
    engine: *mut WowtypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.save_history(path) {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 读回用户输入习惯，返回条数，-1 表示出错（文件不存在也是 -1）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_load_history(
    engine: *mut WowtypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_history(path) {
        Ok(n) => n as c_int,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 每次输入最多返回多少个整句候选（句首词候选另算）。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_set_max_candidates(
    engine: *mut WowtypeEngineHandle,
    max_candidates: u32,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    unsafe { &mut *engine }
        .engine
        .set_max_candidates(max_candidates as usize);
    0
}

/// 开关按错键纠错（相邻键、两键按反、多按/漏按）。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_set_typo_correction(
    engine: *mut WowtypeEngineHandle,
    on: c_int,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    unsafe { &mut *engine }.engine.set_typo_correction(on != 0);
    0
}

/// 载入英文词表（每行一个词，或 rime 的 en.dict.yaml），返回累计词条数；失败返回 -1。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_load_english(
    engine: *mut WowtypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_english(path) {
        Ok(n) => n.min(c_int::MAX as usize) as c_int,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 开关模糊音（z/zh、an/ang 等）。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_set_fuzzy(
    engine: *mut WowtypeEngineHandle,
    on: c_int,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    unsafe { &mut *engine }.engine.set_fuzzy(on != 0);
    0
}

/// 开关双拼（自然码）。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_set_shuangpin(
    engine: *mut WowtypeEngineHandle,
    on: c_int,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    unsafe { &mut *engine }.engine.set_shuangpin(on != 0);
    0
}

/// 开关繁体输出。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_set_traditional(
    engine: *mut WowtypeEngineHandle,
    on: c_int,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    unsafe { &mut *engine }.engine.set_traditional(on != 0);
    0
}

/// 载入简繁映射表（简体<TAB>繁体），返回条目数；失败返回 -1。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_load_conversion(
    engine: *mut WowtypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_conversion(path) {
        Ok(n) => n as c_int,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

thread_local! {
    static PUNCT_BUF: RefCell<CString> =
        RefCell::new(CString::new("，").expect("static punct"));
}

/// ASCII 标点转中文标点。返回的指针在下一次调用前有效，未收录返回 NULL。
#[no_mangle]
pub extern "C" fn wowtype_fullwidth_punct(code: c_int) -> *const c_char {
    let Some(ch) = char::from_u32(code as u32) else {
        return ptr::null();
    };
    let Some(text) = crate::symbols::fullwidth_punct(ch) else {
        return ptr::null();
    };
    PUNCT_BUF.with(|slot| {
        *slot.borrow_mut() = CString::new(text).unwrap_or_default();
        slot.borrow().as_ptr()
    })
}

/// 符号检索。query 为拼音或中文名前缀，结果放在候选结构里（score 恒为 0）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_symbol_search(
    query: *const c_char,
    limit: usize,
) -> *mut WowtypeCandidates {
    let Some(query) = (unsafe { cstr_to_str(query) }) else {
        set_last_error("query is null or not utf8");
        return ptr::null_mut();
    };
    let mut texts = Vec::new();
    let mut scores = Vec::new();
    for symbol in crate::symbols::search(query, limit) {
        match CString::new(symbol.text) {
            Ok(text) => {
                texts.push(text);
                scores.push(0.0);
            }
            Err(_) => continue,
        }
    }
    Box::into_raw(Box::new(WowtypeCandidates::plain(texts, scores)))
}

/// 记录选词并可携带拼音：选够次数后自动加入用户词库。pinyin 可为 NULL。
#[no_mangle]
pub unsafe extern "C" fn wowtype_engine_record_selection_ex(
    engine: *mut WowtypeEngineHandle,
    word: *const c_char,
    pinyin: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(word) = (unsafe { cstr_to_str(word) }) else {
        set_last_error("word is null or not utf8");
        return -1;
    };
    let pinyin = unsafe { cstr_to_str(pinyin) }.filter(|p| !p.is_empty());
    unsafe { &*engine }
        .engine
        .record_selection_with_pinyin(word, pinyin);
    0
}

/// 候选数量。
#[no_mangle]
pub unsafe extern "C" fn wowtype_candidates_len(candidates: *const WowtypeCandidates) -> usize {
    unsafe { candidates.as_ref() }
        .map(|c| c.texts.len())
        .unwrap_or(0)
}

/// 候选文本（UTF-8，以 NUL 结尾）。索引越界返回 NULL。
#[no_mangle]
pub unsafe extern "C" fn wowtype_candidates_text(
    candidates: *const WowtypeCandidates,
    index: usize,
) -> *const c_char {
    unsafe { candidates.as_ref() }
        .and_then(|c| c.texts.get(index))
        .map(|text| text.as_ptr())
        .unwrap_or(ptr::null())
}

/// 候选分数。索引越界返回 0。
#[no_mangle]
pub unsafe extern "C" fn wowtype_candidates_score(
    candidates: *const WowtypeCandidates,
    index: usize,
) -> f64 {
    unsafe { candidates.as_ref() }
        .and_then(|c| c.scores.get(index).copied())
        .unwrap_or(0.0)
}

/// 候选的拼音（空格分隔，按纠错后的音节）；没有拼音或越界返回空串/NULL。
#[no_mangle]
pub unsafe extern "C" fn wowtype_candidates_pinyin(
    candidates: *const WowtypeCandidates,
    index: usize,
) -> *const c_char {
    unsafe { candidates.as_ref() }
        .and_then(|c| c.pinyins.get(index))
        .map(|text| text.as_ptr())
        .unwrap_or(ptr::null())
}

/// 候选用掉了输入的多少字节。小于输入长度时是句首词候选：
/// 上屏这个词后，剩下的输入（从这个偏移开始）继续留在编辑区。越界返回 0。
#[no_mangle]
pub unsafe extern "C" fn wowtype_candidates_consumed(
    candidates: *const WowtypeCandidates,
    index: usize,
) -> usize {
    unsafe { candidates.as_ref() }
        .and_then(|c| c.consumed.get(index).copied())
        .unwrap_or(0)
}

/// 释放候选集合。
#[no_mangle]
pub unsafe extern "C" fn wowtype_candidates_free(candidates: *mut WowtypeCandidates) {
    if !candidates.is_null() {
        drop(unsafe { Box::from_raw(candidates) });
    }
}

/// 最近一次错误。返回的指针在下一次调用本 API 前有效。
#[no_mangle]
pub extern "C" fn wowtype_last_error() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ptr())
}

/// 版本号。
#[no_mangle]
pub extern "C" fn wowtype_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_roundtrip() {
        let lexicon = concat!(env!("CARGO_MANIFEST_DIR"), "/data/demo_lexicon.tsv");
        let lexicon = CString::new(lexicon).unwrap();
        let engine = unsafe { wowtype_engine_new(lexicon.as_ptr(), ptr::null()) };
        assert!(!engine.is_null(), "engine_new 失败: 见 last_error");

        let input = CString::new("xian").unwrap();
        let candidates = unsafe { wowtype_engine_input(engine, input.as_ptr()) };
        assert!(!candidates.is_null());
        let count = unsafe { wowtype_candidates_len(candidates) };
        assert!(count >= 2, "xian 应至少有 先/西安 两个候选，实际 {count}");

        let first = unsafe { wowtype_candidates_text(candidates, 0) };
        assert!(!first.is_null());
        let first = unsafe { CStr::from_ptr(first) }.to_str().unwrap();
        assert!(!first.is_empty());

        let len = unsafe { wowtype_candidates_consumed(candidates, 0) };
        assert_eq!(len, 4, "整句候选用掉全部输入");
        let pinyin = unsafe { wowtype_candidates_pinyin(candidates, 0) };
        assert!(!pinyin.is_null());
        assert!(unsafe { wowtype_candidates_pinyin(candidates, 99) }.is_null());

        unsafe {
            wowtype_candidates_free(candidates);
            wowtype_engine_free(engine);
        }

        let version = wowtype_version();
        assert!(!version.is_null());
    }
}
