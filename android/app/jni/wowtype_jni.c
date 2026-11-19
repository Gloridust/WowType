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

#include "wowtype_core.h"

#define FRAME_FIELDS 16

static jclass g_integer = NULL;
static jclass g_boolean = NULL;
static jclass g_string = NULL;
static jclass g_object = NULL;
static jmethodID g_integer_init = NULL;
static jmethodID g_boolean_init = NULL;

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;

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

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_freeEngine(JNIEnv *env, jclass cls, jlong engine) {
    (void)env;
    (void)cls;
    if (engine != 0) wowtype_engine_free(engine_of(engine));
}

JNIEXPORT jlong JNICALL Java_io_github_gloridust_wowtype_Native_newSession(
    JNIEnv *env, jclass cls, jlong engine) {
    (void)env;
    (void)cls;
    WowtypeSessionConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.size = sizeof(cfg);
    cfg.page_size = 9;
    cfg.calculator = 1;
    cfg.date_time = 1;
    cfg.emoji_suggest = 1;
    cfg.horizontal = 1;
    cfg.pick_char = 1;
    cfg.punct_style = 0; /* 全角中文标点，和桌面版默认一致 */
    cfg.auto_space = 0;
    /* 软键盘上的 Shift 只管大小写，不切中英文；切模式用专门的「中/英」键
     * （WOWTYPE_KEY_ACTION_TOGGLE_MODE）。 */
    cfg.shift_toggle = WOWTYPE_SHIFT_TOGGLE_OFF;
    cfg.translate_mode = 0;
    cfg.toolbar = 0; /* 安卓外壳还没有工具栏和表情面板，别让 v + 空格开出一个看不见的面板 */
    cfg.clipboard_history = 0;
    cfg.arrow_keys = WOWTYPE_ARROW_KEYS_CANDIDATES;
    WowtypeSession *session = wowtype_session_new(engine_of(engine), &cfg);
    return (jlong)(intptr_t)session;
}

JNIEXPORT void JNICALL Java_io_github_gloridust_wowtype_Native_freeSession(
    JNIEnv *env, jclass cls, jlong session) {
    (void)env;
    (void)cls;
    if (session != 0) wowtype_session_free(session_of(session));
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

JNIEXPORT jstring JNICALL Java_io_github_gloridust_wowtype_Native_input(
    JNIEnv *env, jclass cls, jlong session) {
    (void)cls;
    WowtypeSession *s = session_of(session);
    if (s == NULL) return u8_to_jstring(env, "");
    const char *input = wowtype_session_input(s);
    return u8_to_jstring(env, input != NULL ? input : "");
}
