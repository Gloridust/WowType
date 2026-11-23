/*
 * Android 外壳和 Rust 核心之间的 JNI 桥。
 *
 * 核心只承诺 C 接口（docs/ABI.md），这里按 io.github.gloridust.wowtype.Native 的方法名
 * 一对一转过去：引擎建 / 释放、存学习数据，以及输入会话的按键、候选、上屏。
 *
 * 每次调用返回一个 Object[16]，Java 那边包成 Frame：
 *   0 handled(Integer)   1 commit(String|null)  2 preedit(String)  3 preeditCursor(Integer)
 *   4 aux(String|null)   5 panel(Integer)       6 candCount(Integer) 7 candCursor(Integer)
 *   8 hasPrev(Boolean)   9 hasNext(Boolean)    10 mode(Integer)    11 modeChanged(Boolean)
 *  12 learned(Boolean) 13 forgot(Boolean)      14 candidates(String[]) 15 comments(String[])
 *
 * 会话只能在主线程用（docs/ABI.md「线程」），Java 侧保证所有 *_key/_select/_frame 调用都在主线程。
 */

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "wowtype_core.h"

#define FRAME_FIELDS 22

static jclass g_integer = NULL;
static jclass g_boolean = NULL;
static jclass g_string = NULL;
static jclass g_object = NULL;
static jmethodID g_integer_init = NULL;
static jmethodID g_boolean_init = NULL;
static JavaVM *g_vm = NULL;

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    g_vm = vm;

    g_integer = (*env)->FindClass(env, "java/lang/Integer");
    g_boolean = (*env)->FindClass(env, "java/lang/Boolean");
    g_string = (*env)->FindClass(env, "java/lang/String");
    g_object = (*env)->FindClass(env, "java/lang/Object");
    if (!g_integer || !g_boolean || !g_string || !g_object) return JNI_ERR;

    g_integer = (jclass)(*env)->NewGlobalRef(env, g_integer);
    g_boolean = (jclass)(*env)->NewGlobalRef(env, g_boolean);
    g_string = (jclass)(*env)->NewGlobalRef(env, g_string);
    g_object = (jclass)(*env)->NewGlobalRef(env, g_object);
    if (!g_integer || !g_boolean || !g_string || !g_object) return JNI_ERR;

    g_integer_init = (*env)->GetMethodID(env, g_integer, "<init>", "(I)V");
    g_boolean_init = (*env)->GetMethodID(env, g_boolean, "<init>", "(Z)V");
    if (!g_integer_init || !g_boolean_init) return JNI_ERR;
    return JNI_VERSION_1_6;
}

/* UTF-8 -> jstring。不能直接用 NewStringUTF：它要的是 modified UTF-8，emoji 这类
 * 四字节序列会坏掉（候选里的 emoji 正是四字节）。这里自己解成 UTF-16。 */
static jstring u8_to_jstring(JNIEnv *env, const char *s) {
    if (s == NULL) return NULL;
    size_t n = strlen(s);
    /* 每个 code point 最多一个 UTF-16 单元（BMP），四字节的是两个：留两倍足够 */
    jchar *buf = (jchar *)malloc((n * 2 + 1) * sizeof(jchar));
    if (buf == NULL) return NULL;
    size_t out = 0;
    const unsigned char *p = (const unsigned char *)s;
    const unsigned char *end = p + n;
    while (p < end) {
        uint32_t cp;
        unsigned char c = *p++;
        if (c < 0x80) {
            cp = c;
        } else if ((c & 0xE0) == 0xC0 && p < end) {
            cp = ((uint32_t)(c & 0x1F) << 6) | (uint32_t)(*p++ & 0x3F);
            if (cp < 0x80) cp = 0xFFFD;
        } else if ((c & 0xF0) == 0xE0 && end - p >= 2) {
            cp = ((uint32_t)(c & 0x0F) << 12) | ((uint32_t)(p[0] & 0x3F) << 6) | (uint32_t)(p[1] & 0x3F);
            p += 2;
            if (cp < 0x800) cp = 0xFFFD;
        } else if ((c & 0xF8) == 0xF0 && end - p >= 3) {
            cp = ((uint32_t)(c & 0x07) << 18) | ((uint32_t)(p[0] & 0x3F) << 12) |
                 ((uint32_t)(p[1] & 0x3F) << 6) | (uint32_t)(p[2] & 0x3F);
            p += 3;
            if (cp < 0x10000 || cp > 0x10FFFF) cp = 0xFFFD;
        } else {
            cp = 0xFFFD;
        }
        if (cp >= 0x10000) {
            cp -= 0x10000;
            buf[out++] = (jchar)(0xD800 + (cp >> 10));
            buf[out++] = (jchar)(0xDC00 + (cp & 0x3FF));
        } else {
            buf[out++] = (jchar)cp;
        }
    }
    jstring result = (*env)->NewString(env, buf, (jsize)out);
    free(buf);
    return result;
}

/* jstring（UTF-16）-> 标准 UTF-8。GetStringUTFChars 给的是 modified UTF-8，emoji 会坏。 */
static char *jstring_to_utf8(JNIEnv *env, jstring s) {
    if (s == NULL) return NULL;
    jsize n = (*env)->GetStringLength(env, s);
    const jchar *u = (*env)->GetStringChars(env, s, NULL);
    if (u == NULL) return NULL;
    size_t cap = (size_t)n * 4 + 1;
    char *out = (char *)malloc(cap);
    if (out == NULL) {
        (*env)->ReleaseStringChars(env, s, u);
        return NULL;
    }
    size_t at = 0;
    for (jsize i = 0; i < n; i++) {
        uint32_t cp = u[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < n) {
            uint32_t low = u[i + 1];
            if (low >= 0xDC00 && low <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                i++;
            }
        }
        if (cp < 0x80) {
            out[at++] = (char)cp;
        } else if (cp < 0x800) {
            out[at++] = (char)(0xC0 | (cp >> 6));
            out[at++] = (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out[at++] = (char)(0xE0 | (cp >> 12));
            out[at++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[at++] = (char)(0x80 | (cp & 0x3F));
        } else {
            out[at++] = (char)(0xF0 | (cp >> 18));
            out[at++] = (char)(0x80 | ((cp >> 12) & 0x3F));
            out[at++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[at++] = (char)(0x80 | (cp & 0x3F));
        }
    }
    out[at] = 0;
    (*env)->ReleaseStringChars(env, s, u);
    return out;
}

static void set_slot(JNIEnv *env, jobjectArray arr, jsize i, jobject value) {
    if (value != NULL) {
        (*env)->SetObjectArrayElement(env, arr, i, value);
        (*env)->DeleteLocalRef(env, value);
    }
}

static void set_int(JNIEnv *env, jobjectArray arr, jsize i, jint value) {
    set_slot(env, arr, i, (*env)->NewObject(env, g_integer, g_integer_init, value));
}

static void set_bool(JNIEnv *env, jobjectArray arr, jsize i, jboolean value) {
    set_slot(env, arr, i, (*env)->NewObject(env, g_boolean, g_boolean_init, value));
}

static jobject empty_frame(JNIEnv *env) {
    jobjectArray arr = (*env)->NewObjectArray(env, FRAME_FIELDS, g_object, NULL);
    if (arr == NULL) return NULL;
    set_int(env, arr, 0, 0);
    set_slot(env, arr, 1, NULL);
    set_slot(env, arr, 2, u8_to_jstring(env, ""));
    set_int(env, arr, 3, 0);
    set_slot(env, arr, 4, NULL);
    set_int(env, arr, 5, 0);
    set_int(env, arr, 6, 0);
    set_int(env, arr, 7, -1);
    set_bool(env, arr, 8, JNI_FALSE);
    set_bool(env, arr, 9, JNI_FALSE);
    set_int(env, arr, 10, 0);
    set_bool(env, arr, 11, JNI_FALSE);
    set_bool(env, arr, 12, JNI_FALSE);
    set_bool(env, arr, 13, JNI_FALSE);
    set_slot(env, arr, 14, (*env)->NewObjectArray(env, 0, g_string, NULL));
    set_slot(env, arr, 15, (*env)->NewObjectArray(env, 0, g_string, NULL));
    set_int(env, arr, 16, 0);
    set_slot(env, arr, 17, u8_to_jstring(env, ""));
    set_slot(env, arr, 18, u8_to_jstring(env, ""));
    set_slot(env, arr, 19, u8_to_jstring(env, ""));
    set_slot(env, arr, 20, u8_to_jstring(env, ""));
    set_bool(env, arr, 21, JNI_FALSE);
    return arr;
}

/* WowtypeFrame -> Object[]。会话的 frame 只在下一次调用前有效，这里当场拷走。 */
static jobject frame_to_java(JNIEnv *env, WowtypeSession *session, const WowtypeFrame *f) {
    if (f == NULL) return empty_frame(env);
    jobjectArray arr = (*env)->NewObjectArray(env, FRAME_FIELDS, g_object, NULL);
    if (arr == NULL) return NULL;

    set_int(env, arr, 0, f->handled);
    set_slot(env, arr, 1, u8_to_jstring(env, f->commit));
    set_slot(env, arr, 2, u8_to_jstring(env, f->preedit != NULL ? f->preedit : ""));
    set_int(env, arr, 3, f->preedit_cursor);
    set_slot(env, arr, 4, u8_to_jstring(env, f->aux));
    set_int(env, arr, 5, f->panel);
    set_int(env, arr, 6, (jint)f->cand_count);
    set_int(env, arr, 7, f->cand_cursor);
    set_bool(env, arr, 8, f->has_prev ? JNI_TRUE : JNI_FALSE);
    set_bool(env, arr, 9, f->has_next ? JNI_TRUE : JNI_FALSE);
    set_int(env, arr, 10, f->mode);
    set_bool(env, arr, 11, f->mode_changed ? JNI_TRUE : JNI_FALSE);
    set_bool(env, arr, 12, f->learned ? JNI_TRUE : JNI_FALSE);
    set_bool(env, arr, 13, f->forgot ? JNI_TRUE : JNI_FALSE);

    jsize count = f->cand_count > 0 ? (jsize)f->cand_count : 0;
    jobjectArray texts = (*env)->NewObjectArray(env, count, g_string, NULL);
    jobjectArray comments = (*env)->NewObjectArray(env, count, g_string, NULL);
    for (jsize i = 0; i < count; i++) {
        const char *text = wowtype_session_candidate(session, (size_t)i);
        const char *comment = wowtype_session_candidate_comment(session, (size_t)i);
        if (texts != NULL) set_slot(env, texts, i, u8_to_jstring(env, text != NULL ? text : ""));
        if (comments != NULL) set_slot(env, comments, i, u8_to_jstring(env, comment != NULL ? comment : ""));
    }
    set_slot(env, arr, 14, texts);
    set_slot(env, arr, 15, comments);
    set_int(env, arr, 16, (jint)f->wake_after_ms);
    set_slot(env, arr, 17, u8_to_jstring(env, f->translate_source));
    set_slot(env, arr, 18, u8_to_jstring(env, f->translate_text));
    set_slot(env, arr, 19, u8_to_jstring(env, f->translate_title));
    set_slot(env, arr, 20, u8_to_jstring(env, f->translate_status));
    set_bool(env, arr, 21, f->translate_done ? JNI_TRUE : JNI_FALSE);
    return arr;
}

static WowtypeSession *session_of(jlong handle) { return (WowtypeSession *)(intptr_t)handle; }
static WowtypeEngineHandle *engine_of(jlong handle) { return (WowtypeEngineHandle *)(intptr_t)handle; }

static char *dup_utf8(JNIEnv *env, jstring s) {
    if (s == NULL) return NULL;
    const char *chars = (*env)->GetStringUTFChars(env, s, NULL);
    if (chars == NULL) return NULL;
    char *copy = strdup(chars);
    (*env)->ReleaseStringUTFChars(env, s, chars);
    return copy;
}

JNIEXPORT jint JNICALL Java_io_github_gloridust_wowtype_Native_version(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return wowtype_abi_version();
}

JNIEXPORT jlong JNICALL Java_io_github_gloridust_wowtype_Native_newEngine(
    JNIEnv *env, jclass cls, jstring lexicon, jstring bigram, jstring english,
    jstring user_dict, jstring history, jstring recent_emoji) {
    (void)cls;
    if (lexicon == NULL) return 0;
    char *lex = dup_utf8(env, lexicon);
    char *big = dup_utf8(env, bigram);
    char *eng = dup_utf8(env, english);
    char *dict = dup_utf8(env, user_dict);
    char *hist = dup_utf8(env, history);
    char *recent = dup_utf8(env, recent_emoji);
    if (lex == NULL) {
        free(big); free(eng); free(dict); free(hist); free(recent);
        return 0;
    }
    WowtypeEngineHandle *engine = wowtype_engine_new(lex, big);
    free(lex);
    free(big);
    if (engine == NULL) {
        free(eng); free(dict); free(hist); free(recent);
        return 0;
    }
    /* 翻页时一个音节的字要列全（yi 有八百多个字），和 macOS 外壳一样给 1000 */
    wowtype_engine_set_max_candidates(engine, 1000);
    if (eng != NULL && eng[0] != 0) wowtype_engine_load_english(engine, eng);
    if (dict != NULL && dict[0] != 0) wowtype_engine_load_user_dict(engine, dict);
    if (hist != NULL && hist[0] != 0) wowtype_engine_load_history(engine, hist);
    wowtype_recent_emoji_path(recent != NULL && recent[0] != 0 ? recent : NULL);
    free(eng);
    free(dict);
    free(hist);
    free(recent);
    return (jlong)(intptr_t)engine;
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_saveState(
    JNIEnv *env, jclass cls, jlong engine, jstring user_dict, jstring history) {
    (void)cls;
    WowtypeEngineHandle *e = engine_of(engine);
    if (e == NULL) return;
    char *dict = dup_utf8(env, user_dict);
    char *hist = dup_utf8(env, history);
    if (dict != NULL && dict[0] != 0) wowtype_engine_save_user_dict(e, dict);
    if (hist != NULL && hist[0] != 0) wowtype_engine_save_history(e, hist);
    free(dict);
    free(hist);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_loadCustomWords(
    JNIEnv *env, jclass cls, jlong engine, jstring path) {
    (void)cls;
    WowtypeEngineHandle *e = engine_of(engine);
    if (e == NULL) return;
    char *p = dup_utf8(env, path);
    if (p != NULL && p[0] != 0) wowtype_engine_load_custom_words(e, p);
    free(p);
}

JNIEXPORT jobjectArray JNICALL Java_io_github_gloridust_wowtype_Native_customPhrases(
    JNIEnv *env, jclass cls, jlong engine) {
    (void)cls;
    WowtypeCandidates *candidates = wowtype_engine_custom_phrases(engine_of(engine));
    size_t n = candidates == NULL ? 0 : wowtype_candidates_len(candidates);
    jobjectArray out = (*env)->NewObjectArray(env, (jsize)n, g_string, NULL);
    for (size_t i = 0; i < n && out != NULL; i++) {
        jstring text = u8_to_jstring(env, wowtype_candidates_text(candidates, i));
        if (text != NULL) {
            (*env)->SetObjectArrayElement(env, out, (jsize)i, text);
            (*env)->DeleteLocalRef(env, text);
        }
    }
    if (candidates != NULL) wowtype_candidates_free(candidates);
    return out;
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_freeEngine(JNIEnv *env, jclass cls, jlong engine) {
    (void)env;
    (void)cls;
    if (engine != 0) wowtype_engine_free(engine_of(engine));
}

/* 会话设置数组的一项；数组短了（旧 Java）或没有数组就用默认值。
 * 顺序和 Prefs.sessionConfig() 一致，改一边要改另一边。 */
static jint cfg_int(JNIEnv *env, jintArray arr, jsize len, jsize i, jint fallback) {
    if (arr == NULL || i >= len) return fallback;
    jint v = 0;
    (*env)->GetIntArrayRegion(env, arr, i, 1, &v);
    return v;
}

static void fill_session_config(JNIEnv *env, jintArray arr, WowtypeSessionConfig *cfg) {
    memset(cfg, 0, sizeof(*cfg));
    cfg->size = sizeof(*cfg);
    jsize len = arr == NULL ? 0 : (*env)->GetArrayLength(env, arr);
    cfg->page_size = (uint32_t)cfg_int(env, arr, len, 0, 9);
    cfg->calculator = cfg_int(env, arr, len, 1, 1);
    cfg->date_time = cfg_int(env, arr, len, 2, 1);
    cfg->emoji_suggest = cfg_int(env, arr, len, 3, 1);
    cfg->horizontal = cfg_int(env, arr, len, 4, 1);
    cfg->page_keys = (uint32_t)cfg_int(env, arr, len, 5, WOWTYPE_PAGE_KEYS_MINUS);
    cfg->select_keys = cfg_int(env, arr, len, 6, WOWTYPE_SELECT_KEYS_OFF);
    cfg->pick_char = cfg_int(env, arr, len, 7, 1);
    cfg->punct_style = cfg_int(env, arr, len, 8, 0);
    cfg->auto_space = (uint32_t)cfg_int(env, arr, len, 9, 0);
    cfg->shift_toggle = cfg_int(env, arr, len, 10, WOWTYPE_SHIFT_TOGGLE_OFF);
    cfg->translate_mode = cfg_int(env, arr, len, 11, 0);
    cfg->toolbar = cfg_int(env, arr, len, 12, 0);
    cfg->clipboard_history = cfg_int(env, arr, len, 13, 0);
    cfg->shuangpin_keys = cfg_int(env, arr, len, 14, 0);
    cfg->arrow_keys = cfg_int(env, arr, len, 15, WOWTYPE_ARROW_KEYS_CANDIDATES);
    cfg->wubi = cfg_int(env, arr, len, 16, 0);
    cfg->wubi_auto_commit = cfg_int(env, arr, len, 17, 1);
    cfg->wubi_hint = cfg_int(env, arr, len, 18, 1);
    cfg->translate_key = cfg_int(env, arr, len, 19, 0);
    cfg->association = cfg_int(env, arr, len, 20, 0);
    cfg->auto_pair_punct = cfg_int(env, arr, len, 21, 0);
    cfg->shift_double_tap = cfg_int(env, arr, len, 22, 0);
    cfg->translate_one_shot = cfg_int(env, arr, len, 23, 0);
}

JNIEXPORT jlong JNICALL Java_io_github_gloridust_wowtype_Native_newSession(
    JNIEnv *env, jclass cls, jlong engine, jintArray config) {
    (void)cls;
    WowtypeSessionConfig cfg;
    fill_session_config(env, config, &cfg);
    WowtypeSession *session = wowtype_session_new(engine_of(engine), &cfg);
    return (jlong)(intptr_t)session;
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_configureSession(
    JNIEnv *env, jclass cls, jlong session, jintArray config) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return;
    WowtypeSessionConfig cfg;
    fill_session_config(env, config, &cfg);
    wowtype_session_configure(s, &cfg);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_setFuzzy(
    JNIEnv *env, jclass cls, jlong engine, jint on, jint groups) {
    (void)env;
    (void)cls;
    WowtypeEngineHandle *e = engine_of(engine);
    if (e == NULL) return;
    wowtype_engine_set_fuzzy(e, on);
    wowtype_engine_set_fuzzy_groups(e, (unsigned int)groups);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_setShuangpin(
    JNIEnv *env, jclass cls, jlong engine, jint on, jstring scheme, jint abbrev) {
    (void)cls;
    WowtypeEngineHandle *e = engine_of(engine);
    if (e == NULL) return;
    wowtype_engine_set_shuangpin(e, on);
    if (on) {
        char *name = dup_utf8(env, scheme);
        if (name == NULL || name[0] == 0 || wowtype_engine_set_shuangpin_scheme(e, name) != 0) {
            wowtype_engine_set_shuangpin_scheme(e, "ziranma");
        }
        free(name);
        wowtype_engine_set_shuangpin_abbrev(e, abbrev);
    }
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_setTypo(
    JNIEnv *env, jclass cls, jlong engine, jint on) {
    (void)env;
    (void)cls;
    WowtypeEngineHandle *e = engine_of(engine);
    if (e != NULL) wowtype_engine_set_typo_correction(e, on);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_setRareExt(
    JNIEnv *env, jclass cls, jlong engine, jint on) {
    (void)env;
    (void)cls;
    WowtypeEngineHandle *e = engine_of(engine);
    if (e != NULL) wowtype_engine_set_rare_ext_chars(e, on);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_setTraditional(
    JNIEnv *env, jclass cls, jlong engine, jint on) {
    (void)env;
    (void)cls;
    WowtypeEngineHandle *e = engine_of(engine);
    if (e != NULL) wowtype_engine_set_traditional(e, on);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_loadWubi(
    JNIEnv *env, jclass cls, jlong engine, jstring path) {
    (void)cls;
    WowtypeEngineHandle *e = engine_of(engine);
    if (e == NULL) return;
    char *p = dup_utf8(env, path);
    if (p != NULL && p[0] != 0) wowtype_engine_load_wubi(e, p);
    free(p);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_loadConversion(
    JNIEnv *env, jclass cls, jlong engine, jstring path) {
    (void)cls;
    WowtypeEngineHandle *e = engine_of(engine);
    if (e == NULL) return;
    char *p = dup_utf8(env, path);
    if (p != NULL && p[0] != 0) wowtype_engine_load_conversion(e, p);
    free(p);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_freeSession(
    JNIEnv *env, jclass cls, jlong session) {
    (void)env;
    (void)cls;
    if (session != 0) wowtype_session_free(session_of(session));
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_clipboardRemember(
    JNIEnv *env, jclass cls, jstring text) {
    (void)cls;
    char *s = dup_utf8(env, text);
    if (s != NULL) {
        wowtype_clipboard_remember(s);
        free(s);
    }
}

JNIEXPORT jobject JNICALL Java_io_github_gloridust_wowtype_Native_toggleEmoji(
    JNIEnv *env, jclass cls, jlong session) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return empty_frame(env);
    return frame_to_java(env, s, wowtype_session_toggle_emoji_panel(s));
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_setEngine(
    JNIEnv *env, jclass cls, jlong session, jlong engine) {
    (void)env;
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s != NULL) wowtype_session_set_engine(s, engine_of(engine));
}

JNIEXPORT jobject JNICALL Java_io_github_gloridust_wowtype_Native_key(
    JNIEnv *env, jclass cls, jlong session, jint keysym, jint modifiers, jboolean release,
    jint prev_char, jint action, jint hints, jint code, jboolean repeat, jlong time_ms) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return empty_frame(env);
    WowtypeKey key;
    memset(&key, 0, sizeof(key));
    key.size = sizeof(key);
    key.keysym = (uint32_t)keysym;
    key.modifiers = (uint32_t)modifiers;
    key.release = release ? 1 : 0;
    key.prev_char = (uint32_t)prev_char;
    key.action = (uint32_t)action;
    key.hints = (uint32_t)hints;
    key.code = (uint32_t)code;
    key.repeat = repeat ? 1 : 0;
    key.time_ms = (uint64_t)time_ms;
    const WowtypeFrame *frame = wowtype_session_key(s, &key);
    return frame_to_java(env, s, frame);
}

JNIEXPORT jobject JNICALL Java_io_github_gloridust_wowtype_Native_frame(
    JNIEnv *env, jclass cls, jlong session) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return empty_frame(env);
    return frame_to_java(env, s, wowtype_session_frame(s));
}

JNIEXPORT jobject JNICALL Java_io_github_gloridust_wowtype_Native_select(
    JNIEnv *env, jclass cls, jlong session, jint index) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return empty_frame(env);
    return frame_to_java(env, s, wowtype_session_select(s, (size_t)index));
}

JNIEXPORT jobject JNICALL Java_io_github_gloridust_wowtype_Native_reset(
    JNIEnv *env, jclass cls, jlong session, jboolean commit_pending) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return empty_frame(env);
    return frame_to_java(env, s, wowtype_session_reset(s, commit_pending ? 1 : 0));
}

JNIEXPORT jobject JNICALL Java_io_github_gloridust_wowtype_Native_setMode(
    JNIEnv *env, jclass cls, jlong session, jint mode) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return empty_frame(env);
    return frame_to_java(env, s, wowtype_session_set_mode(s, mode));
}

JNIEXPORT jint JNICALL Java_io_github_gloridust_wowtype_Native_mode(
    JNIEnv *env, jclass cls, jlong session) {
    (void)env;
    (void)cls;
    WowtypeSession *s = session_of(session);
    return s == NULL ? 0 : wowtype_session_mode(s);
}

JNIEXPORT jlong JNICALL Java_io_github_gloridust_wowtype_Native_statsNew(
    JNIEnv *env, jclass cls, jstring path) {
    (void)cls;
    char *p = dup_utf8(env, path);
    if (p == NULL || p[0] == 0) {
        free(p);
        return 0;
    }
    WowtypeStats *stats = wowtype_stats_new(p);
    free(p);
    return (jlong)(intptr_t)stats;
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_statsFree(
    JNIEnv *env, jclass cls, jlong stats) {
    (void)env;
    (void)cls;
    if (stats != 0) wowtype_stats_free((WowtypeStats *)(intptr_t)stats);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_statsSetEnabled(
    JNIEnv *env, jclass cls, jlong stats, jint enabled) {
    (void)env;
    (void)cls;
    if (stats != 0) wowtype_stats_set_enabled((WowtypeStats *)(intptr_t)stats, enabled);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_statsKey(
    JNIEnv *env, jclass cls, jlong stats, jint code, jint down, jint flags, jlong now_ms) {
    (void)env;
    (void)cls;
    if (stats != 0) {
        wowtype_stats_key((WowtypeStats *)(intptr_t)stats, 3, (unsigned int)code, down,
                          (unsigned int)flags, (int64_t)now_ms);
    }
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_statsCommit(
    JNIEnv *env, jclass cls, jlong stats, jstring text, jstring source, jstring scheme,
    jint candidate, jint flags, jlong now_ms) {
    (void)cls;
    if (stats == 0 || text == NULL) return;
    char *t = dup_utf8(env, text);
    char *src = dup_utf8(env, source);
    char *sch = dup_utf8(env, scheme);
    if (t != NULL) {
        wowtype_stats_commit((WowtypeStats *)(intptr_t)stats, t,
                             src != NULL && src[0] != 0 ? src : NULL,
                             sch != NULL && sch[0] != 0 ? sch : NULL,
                             candidate, (unsigned int)flags, (int64_t)now_ms);
    }
    free(t);
    free(src);
    free(sch);
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_statsFlush(
    JNIEnv *env, jclass cls, jlong stats, jlong now_ms) {
    (void)env;
    (void)cls;
    if (stats != 0) wowtype_stats_flush((WowtypeStats *)(intptr_t)stats, (int64_t)now_ms);
}

JNIEXPORT jint JNICALL Java_io_github_gloridust_wowtype_Native_statsClear(
    JNIEnv *env, jclass cls, jstring path) {
    (void)cls;
    char *p = dup_utf8(env, path);
    int rc = -1;
    if (p != NULL && p[0] != 0) rc = wowtype_stats_clear(p);
    free(p);
    return rc;
}

JNIEXPORT jobject JNICALL Java_io_github_gloridust_wowtype_Native_tick(
    JNIEnv *env, jclass cls, jlong session, jlong now_ms) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return empty_frame(env);
    return frame_to_java(env, s, wowtype_session_tick(s, (uint64_t)now_ms));
}

/* ---------------- 互译：Java TranslateHost 的函数表 ---------------- */

typedef struct {
    jobject host;
    jmethodID start, cancel, poll, text, source, error, tag;
    char *buf_source, *buf_text, *buf_error, *buf_tag;
} TranslateUser;

static TranslateUser g_translate;
static jclass g_translate_class = NULL;
static WowtypeTranslateBackend g_translate_backend;

static JNIEnv *translate_env(void) {
    if (g_vm == NULL) return NULL;
    JNIEnv *env = NULL;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return NULL;
    return env;
}

static void translate_replace(JNIEnv *env, char **slot, jstring value) {
    free(*slot);
    *slot = value == NULL ? NULL : jstring_to_utf8(env, value);
}

static void translate_start(void *user, const char *text) {
    TranslateUser *u = (TranslateUser *)user;
    JNIEnv *env = translate_env();
    if (env == NULL || u->host == NULL) return;
    jstring input = u8_to_jstring(env, text);
    (*env)->CallVoidMethod(env, u->host, u->start, input);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (input != NULL) (*env)->DeleteLocalRef(env, input);
}

static void translate_cancel(void *user) {
    TranslateUser *u = (TranslateUser *)user;
    JNIEnv *env = translate_env();
    if (env == NULL || u->host == NULL) return;
    (*env)->CallVoidMethod(env, u->host, u->cancel);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

static int translate_poll(void *user, const char **source, const char **text, const char **error) {
    TranslateUser *u = (TranslateUser *)user;
    JNIEnv *env = translate_env();
    if (env == NULL || u->host == NULL) {
        *source = "";
        *text = "";
        *error = "";
        return 0;
    }
    int status = (*env)->CallIntMethod(env, u->host, u->poll);
    jstring s = (jstring)(*env)->CallObjectMethod(env, u->host, u->source);
    translate_replace(env, &u->buf_source, s);
    if (s != NULL) (*env)->DeleteLocalRef(env, s);
    jstring t = (jstring)(*env)->CallObjectMethod(env, u->host, u->text);
    translate_replace(env, &u->buf_text, t);
    if (t != NULL) (*env)->DeleteLocalRef(env, t);
    jstring e = (jstring)(*env)->CallObjectMethod(env, u->host, u->error);
    translate_replace(env, &u->buf_error, e);
    if (e != NULL) (*env)->DeleteLocalRef(env, e);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    *source = u->buf_source == NULL ? "" : u->buf_source;
    *text = u->buf_text == NULL ? "" : u->buf_text;
    *error = u->buf_error == NULL ? "" : u->buf_error;
    return status;
}

static const char *translate_tag(void *user, const char *text) {
    TranslateUser *u = (TranslateUser *)user;
    JNIEnv *env = translate_env();
    if (env == NULL || u->host == NULL) return "译";
    jstring input = u8_to_jstring(env, text);
    jstring tag = (jstring)(*env)->CallObjectMethod(env, u->host, u->tag, input);
    if (input != NULL) (*env)->DeleteLocalRef(env, input);
    translate_replace(env, &u->buf_tag, tag);
    if (tag != NULL) (*env)->DeleteLocalRef(env, tag);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    return u->buf_tag == NULL ? "译" : u->buf_tag;
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_setTranslateBackend(
    JNIEnv *env, jclass cls, jlong session, jobject host) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return;
    if (host == NULL) {
        wowtype_session_set_translate_backend(s, NULL);
        if (g_translate.host != NULL) {
            (*env)->DeleteGlobalRef(env, g_translate.host);
            g_translate.host = NULL;
        }
        return;
    }
    if (g_translate_class == NULL) {
        jclass local = (*env)->FindClass(env, "io/github/gloridust/wowtype/TranslateHost");
        if (local == NULL) return;
        g_translate_class = (jclass)(*env)->NewGlobalRef(env, local);
        (*env)->DeleteLocalRef(env, local);
    }
    if (g_translate.host != NULL) (*env)->DeleteGlobalRef(env, g_translate.host);
    memset(&g_translate, 0, sizeof(g_translate));
    g_translate.host = (*env)->NewGlobalRef(env, host);
    g_translate.start = (*env)->GetMethodID(env, g_translate_class, "start", "(Ljava/lang/String;)V");
    g_translate.cancel = (*env)->GetMethodID(env, g_translate_class, "cancel", "()V");
    g_translate.poll = (*env)->GetMethodID(env, g_translate_class, "poll", "()I");
    g_translate.text = (*env)->GetMethodID(env, g_translate_class, "text", "()Ljava/lang/String;");
    g_translate.source = (*env)->GetMethodID(env, g_translate_class, "source", "()Ljava/lang/String;");
    g_translate.error = (*env)->GetMethodID(env, g_translate_class, "error", "()Ljava/lang/String;");
    g_translate.tag = (*env)->GetMethodID(env, g_translate_class, "tagFor",
                                          "(Ljava/lang/String;)Ljava/lang/String;");
    if (g_translate.start == NULL || g_translate.poll == NULL || g_translate.text == NULL) return;
    memset(&g_translate_backend, 0, sizeof(g_translate_backend));
    g_translate_backend.size = sizeof(g_translate_backend);
    g_translate_backend.user = &g_translate;
    g_translate_backend.start = translate_start;
    g_translate_backend.cancel = translate_cancel;
    g_translate_backend.poll = translate_poll;
    g_translate_backend.tag = translate_tag;
    wowtype_session_set_translate_backend(s, &g_translate_backend);
}

JNIEXPORT jobject JNICALL Java_io_github_gloridust_wowtype_Native_commitText(
    JNIEnv *env, jclass cls, jlong session, jstring text, jint prev_char) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return empty_frame(env);
    char *input = dup_utf8(env, text);
    if (input == NULL) return empty_frame(env);
    jobject frame = frame_to_java(env, s,
                                  wowtype_session_commit_text(s, input, (uint32_t)prev_char));
    free(input);
    return frame;
}

JNIEXPORT jstring JNICALL Java_io_github_gloridust_wowtype_Native_input(
    JNIEnv *env, jclass cls, jlong session) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return u8_to_jstring(env, "");
    const char *input = wowtype_session_input(s);
    return u8_to_jstring(env, input != NULL ? input : "");
}
