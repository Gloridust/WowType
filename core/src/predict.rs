//! 联想（#89）：上屏以后不用打字，先给出接下来最可能打的词。
//!
//! 「上一个词」是会话刚上屏的那句里引擎分出来的最后一个词（今天天气不错 → 不错），
//! 后面接什么看两样：词级语言模型的 ln P(词 | 上一个词)，加上用户自己用过的搭配（输入习惯）。
//! 宁缺毋滥：没把握就什么都不给，单字只在很有把握时给，见下面几个门槛。

use crate::autospace::is_han;
use crate::learn::{decayed, PAIR_BONUS_CAP, PAIR_WEIGHT};
use crate::Engine;

/// 从语言模型里最多拿多少个来筛。
const POOL: usize = 64;
/// ln P 低于这个（P < 0.3%）的不给。
const MIN_LOGP: f64 = -5.8;
/// 单字（了、吗、的……）要 P ≥ 5% 才给：自己打也就两三个键，猜不准时最碍事。
const MIN_SINGLE_LOGP: f64 = -3.0;
/// 比最好的那个低这么多（ln，约 12 倍）的不给。
const RANGE: f64 = 2.5;
/// 学过的搭配不在模型里时，先当它是 MIN_LOGP 那么可能，再加学到的分：用过一次就给得出来。
const LEARNED_BASE: f64 = MIN_LOGP;
/// 往回最多看几个字找上一个词（不是选词上屏的，比如以词定字、语音）。
const MAX_PREV_CHARS: usize = 4;

impl Engine {
    /// 光标前是 context（刚上屏的字结尾）时，接下来可能打的词和分数（越大越可能），
    /// 最多 limit 个，按分数降序；没把握时是空的。开着繁体时给的是繁体。
    pub fn predict(&self, context: &str, limit: usize) -> Vec<(String, f64)> {
        let context = context.trim_end();
        if limit == 0 || !context.chars().next_back().is_some_and(is_han) {
            return Vec::new();
        }
        // 平常载入词库时已经准备好了（只做一次）
        self.prepare_prediction();
        let Some(prev) = self.prediction_prev(context) else {
            return Vec::new();
        };
        let mut found = self.lm.top_next(&prev, POOL);
        if let Ok(pairs) = self.pairs.read() {
            let now = crate::now_ms();
            for (word, entry) in pairs.followers(&prev) {
                let bonus = (PAIR_WEIGHT * (1.0 + decayed(entry, now)).ln()).min(PAIR_BONUS_CAP);
                match found.iter_mut().find(|(w, _)| w == word) {
                    Some(item) => item.1 += bonus,
                    None => found.push((word.to_owned(), LEARNED_BASE + bonus)),
                }
            }
        }
        found.retain(|(word, score)| {
            let chars = word.chars().count();
            let floor = if chars == 1 { MIN_SINGLE_LOGP } else { MIN_LOGP };
            *score >= floor && *word != prev && word.chars().all(is_han)
        });
        found.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        let Some(best) = found.first().map(|(_, s)| *s) else {
            return Vec::new();
        };
        let mut out: Vec<(String, f64)> = Vec::new();
        for (word, score) in found {
            if score < best - RANGE || out.len() >= limit {
                break;
            }
            let shown = self.shown_text(&word);
            // 刚打过的（明天见 → 明天见）、繁体转换后重了的不给
            if context.ends_with(&shown) || out.iter().any(|(w, _)| *w == shown) {
                continue;
            }
            out.push((shown, score));
        }
        out
    }

    /// 联想看的上一个词：会话选词上屏时引擎记下的最后一个词（光标前正好是它）；不是选词上屏的，
    /// 取光标前最长的、语言模型认识的两到四个字。单字（我、的、了）后面能接的太杂，不联想。
    fn prediction_prev(&self, context: &str) -> Option<String> {
        let last = self.last_word.read().ok()?.clone();
        if !last.is_empty() && context.ends_with(&self.shown_text(&last)) {
            return (last.chars().count() >= 2).then_some(last);
        }
        let chars: Vec<char> = context.chars().collect();
        (2..=MAX_PREV_CHARS.min(chars.len()))
            .rev()
            .map(|n| chars[chars.len() - n..].iter().collect::<String>())
            .find(|word| self.lm.knows_word(word) != Some(false))
    }
}
