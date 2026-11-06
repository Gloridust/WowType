/*
 * Wowtype Rust 核心的 C ABI。
 *
 * 生命周期：
 * - wowtype_engine_new 成功返回句柄，必须用 wowtype_engine_free 释放；
 * - wowtype_engine_input 返回的候选句柄必须用 wowtype_candidates_free 释放；
 * - 返回的字符串指针在对应句柄释放前有效（错误串在下一次 API 调用前有效）。
 */
#ifndef WOWTYPE_CORE_H
#define WOWTYPE_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WowtypeEngineHandle WowtypeEngineHandle;
typedef struct WowtypeCandidates WowtypeCandidates;

/* 创建引擎；bigram_tsv_path 可为 NULL 或空串。失败返回 NULL。 */
WowtypeEngineHandle *wowtype_engine_new(const char *lexicon_tsv_path,
                                        const char *bigram_tsv_path);

/* 释放引擎。 */
void wowtype_engine_free(WowtypeEngineHandle *engine);

/* 设置 beam size；成功返回 0，失败返回 -1。 */
int wowtype_engine_set_beam_size(WowtypeEngineHandle *engine, unsigned int beam_size);

/* 记录一次选词，参与历史排序特征。返回 0 成功，-1 失败。 */
int wowtype_engine_record_selection(WowtypeEngineHandle *engine, const char *word);

/* 设置光标前文本，参与上下文 bigram 特征。返回 0 成功，-1 失败。 */
int wowtype_engine_set_context(WowtypeEngineHandle *engine, const char *text);

/* 输入拼音串；失败返回 NULL。 */
/* 用户词库 */
int wowtype_engine_add_user_word(WowtypeEngineHandle *engine, const char *pinyin,
                                 const char *word);
int wowtype_engine_remove_user_word(WowtypeEngineHandle *engine, const char *word);
int wowtype_engine_save_user_dict(WowtypeEngineHandle *engine, const char *path);
int wowtype_engine_load_user_dict(WowtypeEngineHandle *engine, const char *path);

WowtypeCandidates *wowtype_engine_input(WowtypeEngineHandle *engine, const char *input);

/**
 * 基于上一词的预测（预测词库）。
 * 成功返回候选集合（text 为预测词，score 为对数概率），必须 wowtype_candidates_free；
 * 失败返回 NULL，用 wowtype_last_error 取原因。
 */
WowtypeCandidates *wowtype_engine_predict_next(const WowtypeEngineHandle *engine,
                                               const char *prev_word,
                                               size_t limit);

/* 候选数量。 */
size_t wowtype_candidates_len(const WowtypeCandidates *candidates);

/* 候选文本（UTF-8，NUL 结尾）；索引越界返回 NULL。 */
const char *wowtype_candidates_text(const WowtypeCandidates *candidates, size_t index);

/* 候选分数；索引越界返回 0。 */
double wowtype_candidates_score(const WowtypeCandidates *candidates, size_t index);

/* 释放候选集合。 */
void wowtype_candidates_free(WowtypeCandidates *candidates);

/* 最近一次错误信息，可能为空串。 */
const char *wowtype_last_error(void);

/* 版本号，例如 0.1.0。 */
const char *wowtype_version(void);

#ifdef __cplusplus
}
#endif

#endif /* WOWTYPE_CORE_H */
