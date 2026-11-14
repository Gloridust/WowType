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
/// 语言模型最有把握的那个也不到 1%（ln）时，模型给的一个都不要：空着比一排凑数的好。
const MIN_BEST_LOGP: f64 = -4.6;
/// 比最有把握的那个低 e 倍以上的不要。
const RANGE: f64 = 1.0;
/// 单字（了、吗、的……）要 P ≥ 10% 才给：自己打也就两三个键，猜不准时最碍事。
const MIN_SINGLE_LOGP: f64 = -2.3;
/// 最多给几个（再多就是凑数，也更容易被数字键误选）。
const MAX_SHOWN: usize = 5;
/// 用过的搭配不在模型给的里面时，当它有这么可能（ln），再加学到的分，和模型给的排先后。
const LEARNED_BASE: f64 = -5.8;
/// 往回最多看几个字找上一个词（不是选词上屏的，比如五笔、以词定字）。
const MAX_PREV_CHARS: usize = 4;

impl Engine {
    /// 光标前是 context（刚上屏的字结尾）时，接下来可能打的词和分数（越大越可能），
    /// 最多 limit 个（不超过 5 个），按分数降序；没把握时是空的。开着繁体时给的是繁体。
    ///
    /// 模型给的要过门槛（[`MIN_BEST_LOGP`]、[`RANGE`]、单字）；用户自己用过的搭配总给，排在前面。
    pub fn predict(&self, context: &str, limit: usize) -> Vec<(String, f64)> {
        let context = context.trim_end();
        if limit == 0 || !context.chars().next_back().is_some_and(is_han) {
            return Vec::new();
        }
        // 第一次联想时配好语言模型要的词频（约 0.05 秒，只做一次；不开联想的不用花这个时间）
        self.lm.prepare_prediction(&*self.base_lexicon);
        let Some(prev) = self.prediction_prev(context) else {
            return Vec::new();
        };
        // 刚打过的不再给（明天见 → 明天见）；单字要很有把握
        let usable = |word: &str, score: f64| {
            word != prev
                && word.chars().all(is_han)
                && (word.chars().count() > 1 || score >= MIN_SINGLE_LOGP)
        };
        let mut found: Vec<(String, f64)> =
            self.lm.top_next(&prev, POOL).into_iter().filter(|(w, s)| usable(w, *s)).collect();
        let best = found.first().map_or(f64::NEG_INFINITY, |(_, s)| *s);
        found.retain(|(_, s)| best >= MIN_BEST_LOGP && *s >= best - RANGE);
        if let Ok(pairs) = self.pairs.read() {
            let now = crate::now_ms();
            for (word, entry) in pairs.followers(&prev) {
                let bonus = (PAIR_WEIGHT * (1.0 + decayed(entry, now)).ln()).min(PAIR_BONUS_CAP);
                match found.iter_mut().find(|(w, _)| w == word) {
                    Some(item) => item.1 += bonus,
                    None if usable(word, LEARNED_BASE + bonus) => {
                        found.push((word.to_owned(), LEARNED_BASE + bonus));
                    }
                    None => {}
                }
            }
        }
        found.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        let mut out: Vec<(String, f64)> = Vec::new();
        for (word, score) in found {
            if out.len() >= limit.min(MAX_SHOWN) {
                break;
            }
            let shown = self.shown_text(&word);
            // 繁体转换后重了的不给
            if out.iter().any(|(w, _)| *w == shown) {
                continue;
            }
            if self.config.traditional {
                // 和 input() 一样记下繁体对应的词库写法：选了以后学的、接着联想看的都是词库里的写法
                if let Ok(mut last) = self.last_words.write() {
                    last.insert(shown.clone(), vec![word]);
                }
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
