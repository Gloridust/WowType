/*
 * WowType Rust 核心的 C ABI。
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

/* 每次输入最多返回多少个整句候选（句首词候选另算）。返回 0 成功。 */
int wowtype_engine_set_max_candidates(WowtypeEngineHandle *engine, unsigned int max_candidates);

/* 开关按错键纠错（相邻键、两键按反、多按/漏按），默认开。返回 0 成功。 */
int wowtype_engine_set_typo_correction(WowtypeEngineHandle *engine, int on);

/* 载入英文词表（每行一个词，或 rime 的 en.dict.yaml）。
 * 载入后输入已知英文词（hello、github）时英文排在前面。返回累计词条数，失败返回 -1。 */
int wowtype_engine_load_english(WowtypeEngineHandle *engine, const char *path);

/* 载入微信输入法的字级神经语言模型（nlrgpt2_nnlm.bin，不随 WowType 分发），
 * 用来给整句候选重排。返回字表大小，失败返回 -1。 */
int wowtype_engine_load_nnlm(WowtypeEngineHandle *engine, const char *path);

/* 开关模糊音（z/zh、c/ch、s/sh、an/ang、en/eng、in/ing）。返回 0 成功。 */
int wowtype_engine_set_fuzzy(WowtypeEngineHandle *engine, int on);

/* 开关双拼（自然码方案）。返回 0 成功。 */
int wowtype_engine_set_shuangpin(WowtypeEngineHandle *engine, int on);

/* 开关繁体输出。返回 0 成功。 */
int wowtype_engine_set_traditional(WowtypeEngineHandle *engine, int on);

/* 载入简繁映射表（简体<TAB>繁体）。返回条目数，失败返回 -1。 */
int wowtype_engine_load_conversion(WowtypeEngineHandle *engine, const char *path);

/* ASCII 标点转中文标点；未收录返回 NULL。指针在下一次调用前有效。 */
const char *wowtype_fullwidth_punct(int ascii_codepoint);

/* 符号检索（拼音/中文名前缀），结果用 wowtype_candidates_* 读取并释放。 */
WowtypeCandidates *wowtype_symbol_search(const char *query, size_t limit);

/* 打字时的 emoji 推荐。text 是首选候选的文字；结果的 text 是显示文字，
 * 上屏用 wowtype_candidates_commit（整个词对上时只有 emoji，句尾对上时是整句 + emoji）。 */
WowtypeCandidates *wowtype_emoji_recommend(const char *text, size_t limit);

/* 表情面板搜索。query 为空给全部 emoji；否则按拼音（经引擎转成中文词）、英文、
 * 符号名一起找。engine 可为 NULL。 */
WowtypeCandidates *wowtype_engine_emoji_search(const WowtypeEngineHandle *engine,
                                               const char *query, size_t limit);

/* 记录一次选词，参与历史排序特征。返回 0 成功，-1 失败。 */
int wowtype_engine_record_selection(WowtypeEngineHandle *engine, const char *word);

/* 记录选词并带上拼音：选够次数后自动加入用户词库。pinyin 可为 NULL。 */
int wowtype_engine_record_selection_ex(WowtypeEngineHandle *engine,
                                       const char *word, const char *pinyin);

/* 设置光标前文本，参与上下文 bigram 特征。返回 0 成功，-1 失败。 */
int wowtype_engine_set_context(WowtypeEngineHandle *engine, const char *text);

/* 用户词库 */
int wowtype_engine_add_user_word(WowtypeEngineHandle *engine, const char *pinyin,
                                 const char *word);
int wowtype_engine_remove_user_word(WowtypeEngineHandle *engine, const char *word);
int wowtype_engine_save_user_dict(WowtypeEngineHandle *engine, const char *path);
int wowtype_engine_load_user_dict(WowtypeEngineHandle *engine, const char *path);
/* 自定义词（设置里添加的，custom.tsv：拼音<TAB>词[<TAB>频次]）：整体替换上一次读到的，
 * 文件不存在就清空；不写回用户词库。返回收下的条数，-1 表示出错。 */
int wowtype_engine_load_custom_words(WowtypeEngineHandle *engine, const char *path);

/* 用户输入习惯：选过的词的热度（30 天半衰期）和词搭配（上一个词 -> 这个词），
 * 参与排序，存成 TSV。save 返回 0 成功；load 返回条数，-1 表示出错。 */
int wowtype_engine_save_history(WowtypeEngineHandle *engine, const char *path);
int wowtype_engine_load_history(WowtypeEngineHandle *engine, const char *path);

/* 输入拼音串；失败返回 NULL。 */
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

/* 候选拼音（空格分隔音节，纠错后的写法），可传给 record_selection_ex；
 * 预测/符号结果为空串，越界返回 NULL。 */
const char *wowtype_candidates_pinyin(const WowtypeCandidates *candidates, size_t index);

/* 候选用掉了输入的多少字节。等于输入长度是整句候选；小于时是句首词候选，
 * 上屏后应把 input + consumed 之后的部分留在编辑区继续输入。越界返回 0。 */
size_t wowtype_candidates_consumed(const WowtypeCandidates *candidates, size_t index);

/* 选中后上屏的文字（emoji 推荐可能和显示的不同），其他候选等于 text。越界返回 NULL。 */
const char *wowtype_candidates_commit(const WowtypeCandidates *candidates, size_t index);

/* 释放候选集合。 */
void wowtype_candidates_free(WowtypeCandidates *candidates);

/* 编辑区显示用：按候选拼音（空格分隔，wowtype_candidates_pinyin）给输入分词，
 * hengxiang + "heng xiang" -> heng'xiang。保留用户打的字母（大小写、按错的键）。
 * 切不了（英文、双拼、差得太多）返回 NULL；返回的串在同一线程下一次调用前有效。 */
const char *wowtype_segment_input(const char *input, const char *pinyin);

/* 最近一次错误信息，可能为空串。 */
const char *wowtype_last_error(void);

/* 版本号，例如 0.1.0。 */
const char *wowtype_version(void);

/*
 * 语音输入（核心带 voice 特性编译时才有，默认带）。
 *
 * 识别用微信输入法的离线模型：不随软件分发，第一次按热键时从腾讯 CDN 下载（约 100MB）
 * 到 model_dir，之后常驻内存。所有函数都不阻塞：开麦克风、下载、解码都在后台线程。
 *
 * 用法：热键按下/松开调 key_down/key_up；录音期间每几十毫秒调一次 poll，
 * 按返回的状态显示提示或上屏 wowtype_voice_text。
 * 按住超过 300ms 松开即结束；更短算点按，继续听到静音 1.5 秒或再按一次热键。
 * 设了环境变量 WOWTYPE_VOICE_WAV 时不开麦克风，改读这个 WAV 文件（测试用）。
 */
typedef struct WowtypeVoice WowtypeVoice;

enum {
    WOWTYPE_VOICE_IDLE = 0,
    WOWTYPE_VOICE_LISTENING = 1,   /* 正在听；文本是中间结果（可能为空） */
    WOWTYPE_VOICE_RECOGNIZING = 2, /* 录完了，正在出最终结果 */
    WOWTYPE_VOICE_RESULT = 3,      /* 最终结果，文本即要上屏的字；只返回一次 */
    WOWTYPE_VOICE_ERROR = 4,       /* 出错或没听清，文本是原因；只返回一次 */
};

enum {
    WOWTYPE_VOICE_MODEL_NONE = 0,
    WOWTYPE_VOICE_MODEL_DOWNLOADING = 1,
    WOWTYPE_VOICE_MODEL_LOADING = 2,
    WOWTYPE_VOICE_MODEL_READY = 3,
    WOWTYPE_VOICE_MODEL_FAILED = 4,
};

/* model_dir 为 NULL/空串时用 ~/.local/share/wowtype/wtlocal。
 * 核心不带 voice 特性编译时返回 NULL（其余函数接受 NULL，什么也不做）。 */
WowtypeVoice *wowtype_voice_new(const char *model_dir);
void wowtype_voice_free(WowtypeVoice *voice);
void wowtype_voice_key_down(WowtypeVoice *voice);
void wowtype_voice_key_up(WowtypeVoice *voice);
/* 丢掉这次说的话（Esc、切走输入框）。 */
void wowtype_voice_cancel(WowtypeVoice *voice);
/* 返回 WOWTYPE_VOICE_*。 */
int wowtype_voice_poll(WowtypeVoice *voice);
/* 上一次 poll 对应的文本；下一次 poll 或释放前有效。 */
const char *wowtype_voice_text(const WowtypeVoice *voice);
/* 正在听时最近的音量，0–100（画波形用）。 */
int wowtype_voice_level(const WowtypeVoice *voice);
/* 返回 WOWTYPE_VOICE_MODEL_*。 */
int wowtype_voice_model_state(const WowtypeVoice *voice);
/* 松开热键后还在听（点按模式）时返回 1。 */
int wowtype_voice_is_tap(const WowtypeVoice *voice);

#ifdef __cplusplus
}
#endif

#endif /* WOWTYPE_CORE_H */
