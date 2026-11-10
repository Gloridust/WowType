/* WowType C ABI 冒烟测试：模拟 fcitx5 插件的调用序列。
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

    /* 句首词候选：consumed 小于输入长度，剩下的部分留给下一轮 */
    c = wowtype_engine_input(e, "nihaozhongguo");
    {
        int found = 0;
        size_t n = wowtype_candidates_len(c);
        for (size_t i = 0; c && i < n; i++) {
            const char *t = wowtype_candidates_text(c, i);
            if (t && strcmp(t, "你好") == 0 && wowtype_candidates_consumed(c, i) == 5) found = 1;
        }
        check(found, "prefix: nihaozhongguo 有 你好(用掉 5 字节)");
        check(c && wowtype_candidates_consumed(c, 0) == 13, "整句候选用掉全部输入");
        const char *py = c ? wowtype_candidates_pinyin(c, 0) : NULL;
        check(py && strcmp(py, "ni hao zhong guo") == 0, "candidates_pinyin");
    }
    wowtype_candidates_free(c);

    /* 按错键：zhonggup（o 旁边的 p） */
    c = wowtype_engine_input(e, "zhonggup");
    check(c && has_candidate(c, "中国"), "typo: zhonggup -> 中国");
    wowtype_candidates_free(c);
    check(wowtype_engine_set_typo_correction(e, 0) == 0, "set_typo_correction");
    c = wowtype_engine_input(e, "zhonggup");
    check(c && !has_candidate(c, "中国"), "纠错关闭后 zhonggup 不出 中国");
    wowtype_candidates_free(c);
    wowtype_engine_set_typo_correction(e, 1);
    check(wowtype_engine_set_max_candidates(e, 5) == 0, "set_max_candidates");

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
    {
        FILE *custom = fopen("/tmp/wowtype_abi_custom.tsv", "w");
        check(custom != NULL, "open custom.tsv");
        fputs("ni hao\t妮好\nnot pinyin zz\t坏\n", custom);
        fclose(custom);
        check(wowtype_engine_load_custom_words(e, "/tmp/wowtype_abi_custom.tsv") == 1,
              "load_custom_words");
        check(wowtype_engine_load_custom_words(e, "/tmp/wowtype_abi_no_such.tsv") == 0,
              "load_custom_words missing file clears");
        remove("/tmp/wowtype_abi_custom.tsv");
    }

    /* 自动学习：同一个词选 3 次后应当能直接打出来 */
    for (int i = 0; i < 3; i++) {
        wowtype_engine_record_selection_ex(e, "阿特", "a te");
    }
    c = wowtype_engine_input(e, "ate");
    check(c && has_candidate(c, "阿特"), "auto learn: ate -> 阿特");
    wowtype_candidates_free(c);

    c = wowtype_symbol_search("juhao", 3);
    check(c && wowtype_candidates_len(c) > 0 &&
              strcmp(wowtype_candidates_text(c, 0), "。") == 0,
          "symbol: juhao -> 。");
    wowtype_candidates_free(c);
    {
        const char *p = wowtype_fullwidth_punct(',');
        check(p && strcmp(p, "，") == 0, "punct: comma -> ，");
    }

    /* 输入会话（ABI 1.3）：字母进编辑区、选句首词、退格先撤销选词、切换输入法时上屏 */
    {
        WowtypeSession *s = wowtype_session_new(e, NULL);
        check(s != NULL, "session_new");
        const WowtypeFrame *f = NULL;
        const char *keys = "nihaoma";
        int letters_ok = 1;
        for (const char *k = keys; *k; ++k) {
            WowtypeKey key = {sizeof(WowtypeKey), (uint32_t)*k, 0, 0, 0};
            f = wowtype_session_key(s, &key);
            letters_ok = letters_ok && f && f->handled && f->size == sizeof(WowtypeFrame);
            WowtypeKey up = key;
            up.release = 1;
            letters_ok = letters_ok && !wowtype_session_key(s, &up)->handled;
        }
        check(letters_ok, "session: letters handled, releases not, frame size matches header");
        /* f 指向会话自己的 frame：上面的松开键已经覆盖了它，这里看的是松开后的编辑区 */
        check(f && strcmp(f->preedit, "nihaoma") == 0 && f->commit == NULL, "session: preedit nihaoma");
        wowtype_session_push_selection(s, "你好", "ni hao", 5);
        check(strcmp(wowtype_session_remaining(s), "ma") == 0, "session: remaining ma");
        check(wowtype_session_selection_count(s) == 1 &&
                  strcmp(wowtype_session_selection_pinyin(s, 0), "ni hao") == 0,
              "session: selection pinyin");
        WowtypeKey bs = {sizeof(WowtypeKey), 0xff08, 0, 0, 0};
        f = wowtype_session_key(s, &bs);
        check(f && f->handled && strcmp(f->preedit, "nihaoma") == 0, "session: backspace undoes selection");
        WowtypeKey space = {sizeof(WowtypeKey), ' ', 0, 0, 0};
        check(!wowtype_session_key(s, &space)->handled, "session: space still the shell's");
        f = wowtype_session_reset(s, 1);
        check(f && f->commit && strcmp(f->commit, "nihaoma") == 0 && f->preedit[0] == 0,
              "session: reset commits raw input");
        wowtype_session_free(s);
    }

    if (wowtype_abi_version() / 1000 != WOWTYPE_ABI_VERSION_MAJOR) {
        fprintf(stderr, "ABI 主版本不一致：库 %d，头文件 %d\n", wowtype_abi_version(),
                WOWTYPE_ABI_VERSION_MAJOR);
        return 1;
    }
    printf("abi=%d ", wowtype_abi_version());
    printf("version=%s", wowtype_version());
    putchar(10);
    wowtype_engine_free(e);

    printf(failures ? "ABI SMOKE FAILED" : "ABI SMOKE OK");
    putchar(10);
    return failures ? 1 : 0;
}