/* Wowtype C ABI 冒烟测试：模拟 fcitx5 插件的调用序列。
 *
 * 覆盖：引擎创建 -> 输入 -> 取候选 -> 记录选词 -> 设置上下文 -> 预测下一词
 *      -> 用户词增删 -> 用户词库持久化。
 */
#include <stdio.h>
#include <string.h>
#include "wowtype_core.h"

static int failures = 0;

static void check(int cond, const char *what) {
    if (!cond) {
        failures++;
        printf("FAIL %s", what);
        putchar(10);
    } else {
        printf("ok   %s", what);
        putchar(10);
    }
}

static int has_candidate(WowtypeCandidates *c, const char *text) {
    size_t n = wowtype_candidates_len(c);
    for (size_t i = 0; i < n; i++) {
        const char *t = wowtype_candidates_text(c, i);
        if (t && strcmp(t, text) == 0) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *lexicon = argc > 1 ? argv[1] : "/tmp/wowtype_abi.tsv";
    const char *bigram = argc > 2 ? argv[2] : "";
    WowtypeEngineHandle *e = wowtype_engine_new(lexicon, bigram);
    if (!e) {
        printf("engine_new failed: %s", wowtype_last_error());
        putchar(10);
        return 1;
    }

    WowtypeCandidates *c = wowtype_engine_input(e, "nihao");
    check(c && has_candidate(c, "你好"), "exact: nihao -> 你好");
    wowtype_candidates_free(c);

    c = wowtype_engine_input(e, "nih");
    check(c && has_candidate(c, "你好"), "partial: nih -> 你好");
    wowtype_candidates_free(c);

    c = wowtype_engine_input(e, "hello");
    check(c && has_candidate(c, "hello"), "english: hello -> hello");
    wowtype_candidates_free(c);

    check(wowtype_engine_record_selection(e, "你好") == 0, "record_selection");
    check(wowtype_engine_set_context(e, "今天") == 0, "set_context");

    c = wowtype_engine_input(e, "tian");
    check(c && has_candidate(c, "天"), "context: tian -> 天");
    wowtype_candidates_free(c);

    c = wowtype_engine_predict_next(e, "今天", 3);
    check(c && wowtype_candidates_len(c) > 0, "predict_next 有结果");
    wowtype_candidates_free(c);

    check(wowtype_engine_add_user_word(e, "wo wo te", "我特") == 0, "add_user_word");
    c = wowtype_engine_input(e, "wowote");
    check(c && has_candidate(c, "我特"), "user word 可输入");
    wowtype_candidates_free(c);

    check(wowtype_engine_set_fuzzy(e, 1) == 0, "set_fuzzy");
    c = wowtype_engine_input(e, "zidao");
    check(c && has_candidate(c, "知道"), "fuzzy: zidao -> 知道");
    wowtype_candidates_free(c);

    check(wowtype_engine_set_shuangpin(e, 1) == 0, "set_shuangpin");
    c = wowtype_engine_input(e, "vsgo");
    check(c && has_candidate(c, "中国"), "shuangpin: vsgo -> 中国");
    wowtype_candidates_free(c);
    wowtype_engine_set_shuangpin(e, 0);

    const char *s2t = argc > 3 ? argv[3] : "";
    if (*s2t) {
        check(wowtype_engine_load_conversion(e, s2t) > 0, "load_conversion");
        check(wowtype_engine_set_traditional(e, 1) == 0, "set_traditional");
        c = wowtype_engine_input(e, "zhongguo");
        check(c && has_candidate(c, "中國"), "traditional: zhongguo -> 中國");
        wowtype_candidates_free(c);
        wowtype_engine_set_traditional(e, 0);
    }

    check(wowtype_engine_save_user_dict(e, "/tmp/wowtype_abi_user.tsv") == 0, "save_user_dict");
    check(wowtype_engine_remove_user_word(e, "我特") == 1, "remove_user_word");
    check(wowtype_engine_load_user_dict(e, "/tmp/wowtype_abi_user.tsv") >= 1, "load_user_dict");

    c = wowtype_symbol_search("juhao", 3);
    check(c && wowtype_candidates_len(c) > 0 &&
              strcmp(wowtype_candidates_text(c, 0), "。") == 0,
          "symbol: juhao -> 。");
    wowtype_candidates_free(c);
    {
        const char *p = wowtype_fullwidth_punct(',');
        check(p && strcmp(p, "，") == 0, "punct: comma -> ，");
    }

    printf("version=%s", wowtype_version());
    putchar(10);
    wowtype_engine_free(e);

    printf(failures ? "ABI SMOKE FAILED" : "ABI SMOKE OK");
    putchar(10);
    return failures ? 1 : 0;
}