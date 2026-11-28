#include "text_service.h"

#include <ctfutb.h>
#include <inputscope.h>
#include <shellapi.h>

#include <algorithm>
#include <cstring>
#include <fstream>
#include <new>

#include "../common/keys.h"
#include "../common/utf.h"
#include "display_attribute.h"
#include "edit_session.h"
#include "engine_host.h"
#include "globals.h"
#include "langbar.h"

using Microsoft::WRL::ComPtr;

namespace wowtype::tsf {

namespace {

/// 输入框所在的顶层窗口（WindowMode 看换没换窗口）：先问文档的视图，问不到看这个线程的键盘焦点。
HWND topLevelWindow(ITfDocumentMgr *focus) {
    HWND window = nullptr;
    ComPtr<ITfContext> context;
    ComPtr<ITfContextView> view;
    if (focus && SUCCEEDED(focus->GetTop(&context)) && context && SUCCEEDED(context->GetActiveView(&view)) && view) {
        view->GetWnd(&window);
    }
    if (!window) {
        window = GetFocus();
    }
    return window ? GetAncestor(window, GA_ROOT) : nullptr;
}

constexpr UINT_PTR kTranslateTimer = 1;
constexpr UINT_PTR kModeHintTimer = 2;
constexpr UINT_PTR kVoiceTimer = 3;
/// 互译时每 50 毫秒取一次结果（和 macOS 一样）
constexpr UINT kTranslatePollMs = 50;
/// 切到中 / 英 / 译以后在光标下面亮一下的提示
constexpr UINT kModeHintMs = 1000;

enum MenuId : UINT {
    kMenuSettings = 10,
    kMenuUpdate = 11,
    kMenuChinese = 1,
    kMenuEnglish,
    kMenuTranslate,
    kMenuConfig,
    kMenuDataDir,
};

uint32_t currentModifiers() {
    uint32_t m = 0;
    if (GetKeyState(VK_SHIFT) < 0) {
        m |= mod::shift;
    }
    if (GetKeyState(VK_CONTROL) < 0) {
        m |= mod::control;
    }
    if (GetKeyState(VK_MENU) < 0) {
        m |= mod::alt;
    }
    if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) {
        m |= mod::super;
    }
    if (GetKeyState(VK_CAPITAL) & 1) {
        m |= mod::caps;
    }
    if (GetKeyState(VK_NUMLOCK) & 1) {
        m |= mod::numlock;
    }
    return m;
}

/// 这个键打出的字符（考虑 Shift、CapsLock 和键盘布局）。带 Ctrl / Alt 时按没按它们算，免得拿到控制字符
/// （和 macOS 用 charactersIgnoringModifiers 一样）。打不出字是 0。
char32_t typedCharacter(UINT virtualKey, LPARAM lParam, uint32_t modifiers) {
    BYTE state[256] = {};
    if (!GetKeyboardState(state)) {
        return 0;
    }
    if (modifiers & (mod::control | mod::alt)) {
        for (const int modifier : {VK_CONTROL, VK_LCONTROL, VK_RCONTROL, VK_MENU, VK_LMENU, VK_RMENU}) {
            state[modifier] = 0;
        }
    }
    wchar_t buffer[8] = {};
    const UINT scan = (static_cast<UINT>(lParam) >> 16) & 0xFF;
    // 0x4：不改键盘状态（死键），Windows 10 1607 起
    const int n = ToUnicodeEx(virtualKey, scan, state, buffer, 8, 0x4, GetKeyboardLayout(0));
    return n == 1 ? static_cast<char32_t>(buffer[0]) : 0;
}

bool isShift(WPARAM vk) { return vk == VK_SHIFT || vk == VK_LSHIFT || vk == VK_RSHIFT; }

/// 同一次按键：TSF 先问（OnTestKeyDown）后给（OnKeyDown）时 lParam 的高位（之前的按键状态、重复次数）可能不一样，
/// 只比虚拟键码、扫描码和扩展键位。（CI 的端到端打字测试发现整个 lParam 比的话每个键都处理两遍。）
bool sameKey(WPARAM w1, LPARAM l1, WPARAM w2, LPARAM l2) {
    return w1 == w2 && ((static_cast<UINT>(l1) ^ static_cast<UINT>(l2)) & 0x01FF0000u) == 0;
}

/// 设了环境变量 WOWTYPE_DEBUG_KEYS 时把每个按键回调记进日志（查按键处理了几遍用）。
bool debugKeys() { return debugLogging(); }

void traceKey(const wchar_t *what, WPARAM wParam, LPARAM lParam, BOOL eaten) {
    if (debugKeys()) {
        wchar_t line[128];
        swprintf_s(line, L"%s vk=%02X lParam=%08X eaten=%d", what, static_cast<unsigned>(wParam),
                   static_cast<unsigned>(lParam), eaten);
        log(line);
    }
}

/// 放进系统剪贴板（语音结果，VoiceCopy）。
void copyToClipboard(const std::string &utf8) {
    const std::wstring text = widen(utf8);
    if (!OpenClipboard(nullptr)) {
        return;
    }
    EmptyClipboard();
    const SIZE_T bytes = (text.size() + 1) * sizeof(wchar_t);
    if (HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes)) {
        if (void *p = GlobalLock(memory)) {
            memcpy(p, text.c_str(), bytes);
            GlobalUnlock(memory);
            if (!SetClipboardData(CF_UNICODETEXT, memory)) {
                GlobalFree(memory);
            }
        } else {
            GlobalFree(memory);
        }
    }
    CloseClipboard();
}

bool isRightShift(WPARAM vk, LPARAM lParam) {
    return vk == VK_RSHIFT || ((static_cast<UINT>(lParam) >> 16) & 0xFF) == vk::rightShiftScan;
}

bool otherModifiersHeld() {
    return GetKeyState(VK_CONTROL) < 0 || GetKeyState(VK_MENU) < 0 || GetKeyState(VK_LWIN) < 0 ||
           GetKeyState(VK_RWIN) < 0;
}

ComPtr<ITfRange> selectionRange(TfEditCookie ec, ITfContext *context) {
    TF_SELECTION selection{};
    ULONG fetched = 0;
    if (FAILED(context->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) || fetched == 0 ||
        !selection.range) {
        return nullptr;
    }
    ComPtr<ITfRange> range;
    range.Attach(selection.range);
    return range;
}

void setSelection(TfEditCookie ec, ITfContext *context, ITfRange *range) {
    TF_SELECTION selection{};
    selection.range = range;
    selection.style.ase = TF_AE_NONE;
    selection.style.fInterimChar = FALSE;
    context->SetSelection(ec, 1, &selection);
}

/// range 里的第一个 UTF-16 单元（读不到是 nullopt）。
std::optional<wchar_t> firstUnit(TfEditCookie ec, ITfRange *range) {
    wchar_t buffer[2] = {};
    ULONG got = 0;
    if (FAILED(range->GetText(ec, 0, buffer, 1, &got)) || got != 1) {
        return std::nullopt;
    }
    return buffer[0];
}

} // namespace

TextService::TextService() { dllAddRef(); }

TextService::~TextService() { dllRelease(); }

STDMETHODIMP TextService::QueryInterface(REFIID riid, void **ppv) {
    if (!ppv) {
        return E_INVALIDARG;
    }
    *ppv = nullptr;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, __uuidof(ITfTextInputProcessor)) ||
        IsEqualIID(riid, __uuidof(ITfTextInputProcessorEx))) {
        *ppv = static_cast<ITfTextInputProcessorEx *>(this);
    } else if (IsEqualIID(riid, __uuidof(ITfThreadMgrEventSink))) {
        *ppv = static_cast<ITfThreadMgrEventSink *>(this);
    } else if (IsEqualIID(riid, __uuidof(ITfKeyEventSink))) {
        *ppv = static_cast<ITfKeyEventSink *>(this);
    } else if (IsEqualIID(riid, __uuidof(ITfCompositionSink))) {
        *ppv = static_cast<ITfCompositionSink *>(this);
    } else if (IsEqualIID(riid, __uuidof(ITfThreadFocusSink))) {
        *ppv = static_cast<ITfThreadFocusSink *>(this);
    } else if (IsEqualIID(riid, __uuidof(ITfDisplayAttributeProvider))) {
        *ppv = static_cast<ITfDisplayAttributeProvider *>(this);
    } else {
        return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) TextService::AddRef() { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }

STDMETHODIMP_(ULONG) TextService::Release() {
    const LONG n = InterlockedDecrement(&refs_);
    if (n == 0) {
        delete this;
    }
    return static_cast<ULONG>(n);
}

// ---------------------------------------------------------------- 启用、停用

STDMETHODIMP TextService::Activate(ITfThreadMgr *threadMgr, TfClientId clientId) {
    return ActivateEx(threadMgr, clientId, 0);
}

STDMETHODIMP TextService::ActivateEx(ITfThreadMgr *threadMgr, TfClientId clientId, DWORD) {
    threadMgr_ = threadMgr;
    clientId_ = clientId;
    auto &host = EngineHost::instance();
    std::lock_guard<std::recursive_mutex> lock(host.mutex());
    host.ensureLoading();

    ComPtr<ITfSource> source;
    if (SUCCEEDED(threadMgr_.As(&source))) {
        source->AdviseSink(__uuidof(ITfThreadMgrEventSink), static_cast<ITfThreadMgrEventSink *>(this),
                           &threadMgrSinkCookie_);
        source->AdviseSink(__uuidof(ITfThreadFocusSink), static_cast<ITfThreadFocusSink *>(this),
                           &threadFocusSinkCookie_);
    }
    ComPtr<ITfKeystrokeMgr> keystrokes;
    if (SUCCEEDED(threadMgr_.As(&keystrokes))) {
        keySinkAdvised_ =
            SUCCEEDED(keystrokes->AdviseKeyEventSink(clientId_, static_cast<ITfKeyEventSink *>(this), TRUE));
    }
    ComPtr<ITfCategoryMgr> categories;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&categories)))) {
        categories->RegisterGUID(kGuidDisplayAttributeInput, &inputAttribute_);
    }

    window_ = std::make_unique<CandidateWindow>();
    window_->onSelect = [this](int index) {
        std::lock_guard<std::recursive_mutex> inner(EngineHost::instance().mutex());
        if (composer_) {
            sync();
            composer_->select(index);
            flush(currentContext());
        }
    };
    window_->onPage = [this](bool forward) {
        std::lock_guard<std::recursive_mutex> inner(EngineHost::instance().mutex());
        if (composer_) {
            sync();
            composer_->turnPage(forward);
            flush(currentContext());
        }
    };
    // 右键「忘掉这个词」（#229）：学过的词才出菜单，点了和 Ctrl+Delete 一样
    window_->canForget = [this](int index) {
        std::lock_guard<std::recursive_mutex> inner(EngineHost::instance().mutex());
        return composer_ && composer_->canForget(index);
    };
    window_->onForget = [this](int index) {
        std::lock_guard<std::recursive_mutex> inner(EngineHost::instance().mutex());
        if (composer_) {
            sync();
            composer_->forget(index);
            flush(currentContext());
        }
    };
    window_->onTimer = [this](UINT_PTR id) { onTimer(id); };

    composer_ = std::make_unique<Composer>(host.engine(), this);
    composer_->onCommit = [](const std::string &) { EngineHost::instance().didCommit(); };
    composer_->onForget = [] { EngineHost::instance().didForget(); };
    composer_->onCommitStats = [this](const std::string &text, const std::string &source, const std::string &scheme,
                                      int index) {
        EngineHost::instance().recordCommit(text, source, scheme, index, around_.password);
    };
    composer_->onTranslatePoll = [this](uint32_t) {
        if (window_) {
            window_->setTimer(kTranslateTimer, kTranslatePollMs);
        }
    };
    configGeneration_ = 0;
    sync();
    // 从别的输入法切过来：按「切到 WowType 时」定中 / 英（InitialMode，和另两端一样）
    composer_->applyInitialMode();

    // 任务栏上的「中 / 英」
    ComPtr<ITfLangBarItemMgr> langBarMgr;
    if (SUCCEEDED(threadMgr_.As(&langBarMgr))) {
        langBar_ = new LangBarButton(this);
        if (FAILED(langBarMgr->AddItem(langBar_))) {
            langBar_->detach();
            langBar_->Release();
            langBar_ = nullptr;
        }
    }
    setKeyboardOpen(true);

    ComPtr<ITfDocumentMgr> focus;
    if (SUCCEEDED(threadMgr_->GetFocus(&focus)) && focus) {
        focus->GetTop(&focusContext_);
    }
    // 记下现在的窗口：切到 WowType 的这一下按上面的 InitialMode，之后换了窗口、应用再按 WindowMode（#254）
    lastWindow_ = topLevelWindow(focus.Get());
    // 每天最多查一次有没有新版本（后台，有新版时任务栏菜单里多一项），和 macOS 一样
    host.checkUpdateIfDue();
    return S_OK;
}

STDMETHODIMP TextService::Deactivate() {
    auto &host = EngineHost::instance();
    std::lock_guard<std::recursive_mutex> lock(host.mutex());
    host.voice().cancel(this);
    endComposition();
    if (window_) {
        window_->killTimer(kVoiceTimer);
        window_->killTimer(kTranslateTimer);
        window_->killTimer(kModeHintTimer);
        window_->hide();
    }
    host.save();
    host.flushStats();
    if (langBar_) {
        ComPtr<ITfLangBarItemMgr> langBarMgr;
        if (threadMgr_ && SUCCEEDED(threadMgr_.As(&langBarMgr))) {
            langBarMgr->RemoveItem(langBar_);
        }
        langBar_->detach();
        langBar_->Release();
        langBar_ = nullptr;
    }
    if (threadMgr_) {
        ComPtr<ITfSource> source;
        if (SUCCEEDED(threadMgr_.As(&source))) {
            if (threadMgrSinkCookie_ != TF_INVALID_COOKIE) {
                source->UnadviseSink(threadMgrSinkCookie_);
            }
            if (threadFocusSinkCookie_ != TF_INVALID_COOKIE) {
                source->UnadviseSink(threadFocusSinkCookie_);
            }
        }
        ComPtr<ITfKeystrokeMgr> keystrokes;
        if (keySinkAdvised_ && SUCCEEDED(threadMgr_.As(&keystrokes))) {
            keystrokes->UnadviseKeyEventSink(clientId_);
        }
    }
    threadMgrSinkCookie_ = threadFocusSinkCookie_ = TF_INVALID_COOKIE;
    keySinkAdvised_ = false;
    composer_.reset();
    window_.reset();
    page_.reset();
    focusContext_.Reset();
    threadMgr_.Reset();
    clientId_ = TF_CLIENTID_NULL;
    return S_OK;
}

// ---------------------------------------------------------------- 跟上设置、引擎

void TextService::sync() {
    auto &host = EngineHost::instance();
    host.ensureLoading();
    host.checkForChanges();
    if (!composer_) {
        return;
    }
    if (host.engine() != composer_->engine()) {
        composer_->setEngine(host.engine());
    }
    composer_->setTranslator(host.translator());
    if (configGeneration_ != host.configGeneration()) {
        configGeneration_ = host.configGeneration();
        composer_->apply(host.config());
    }
}

ITfContext *TextService::currentContext() {
    if (composition_ && compositionContext_) {
        return compositionContext_.Get();
    }
    return focusContext_.Get();
}

bool TextService::keyboardDisabled(ITfContext *context) {
    ComPtr<ITfCompartmentMgr> compartments;
    if (!context || FAILED(context->QueryInterface(IID_PPV_ARGS(&compartments)))) {
        return false;
    }
    for (const GUID &guid : {GUID_COMPARTMENT_KEYBOARD_DISABLED, GUID_COMPARTMENT_EMPTYCONTEXT}) {
        ComPtr<ITfCompartment> compartment;
        VARIANT value;
        VariantInit(&value);
        if (SUCCEEDED(compartments->GetCompartment(guid, &compartment)) &&
            compartment->GetValue(&value) == S_OK && value.vt == VT_I4 && value.lVal != 0) {
            return true;
        }
    }
    return false;
}

bool TextService::keyboardOpen() {
    ComPtr<ITfCompartmentMgr> compartments;
    ComPtr<ITfCompartment> compartment;
    VARIANT value;
    VariantInit(&value);
    if (!threadMgr_ || FAILED(threadMgr_.As(&compartments)) ||
        FAILED(compartments->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, &compartment)) ||
        compartment->GetValue(&value) != S_OK || value.vt != VT_I4) {
        return true;
    }
    return value.lVal != 0;
}

void TextService::setKeyboardOpen(bool open) {
    ComPtr<ITfCompartmentMgr> compartments;
    ComPtr<ITfCompartment> compartment;
    if (!threadMgr_ || FAILED(threadMgr_.As(&compartments)) ||
        FAILED(compartments->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, &compartment))) {
        return;
    }
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_I4;
    value.lVal = open ? TRUE : FALSE;
    compartment->SetValue(clientId_, &value);
}

// ---------------------------------------------------------------- 按键

STDMETHODIMP TextService::OnTestKeyDown(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    if (!eaten) {
        return E_INVALIDARG;
    }
    // 同一个键问了两遍（有的应用会），照第一次答，不再处理
    if (pendingDown_ && sameKey(pendingDown_->wParam, pendingDown_->lParam, wParam, lParam)) {
        *eaten = TRUE;
        traceKey(L"OnTestKeyDown（问过了）", wParam, lParam, *eaten);
        return S_OK;
    }
    pendingDown_.reset();
    handledUp_.reset();
    *eaten = processKeyDown(context, wParam, lParam) ? TRUE : FALSE;
    if (*eaten) {
        // 吃掉的键接着会来 OnKeyDown：那时照这次的答
        pendingDown_ = PendingKey{wParam, lParam};
    }
    traceKey(L"OnTestKeyDown", wParam, lParam, *eaten);
    return S_OK;
}

STDMETHODIMP TextService::OnKeyDown(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    if (!eaten) {
        return E_INVALIDARG;
    }
    if (pendingDown_ && sameKey(pendingDown_->wParam, pendingDown_->lParam, wParam, lParam)) {
        pendingDown_.reset();
        *eaten = TRUE;
        traceKey(L"OnKeyDown（问的时候处理过了）", wParam, lParam, *eaten);
        return S_OK;
    }
    // 没先问就直接给的（应用自己调 KeyDown）：现在处理
    pendingDown_.reset();
    handledUp_.reset();
    *eaten = processKeyDown(context, wParam, lParam) ? TRUE : FALSE;
    traceKey(L"OnKeyDown", wParam, lParam, *eaten);
    return S_OK;
}

STDMETHODIMP TextService::OnTestKeyUp(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    if (!eaten) {
        return E_INVALIDARG;
    }
    if (handledUp_ && sameKey(handledUp_->wParam, handledUp_->lParam, wParam, lParam)) {
        *eaten = handledUp_->eaten ? TRUE : FALSE;
        return S_OK;
    }
    const bool up = processKeyUp(context, wParam, lParam);
    handledUp_ = PendingKey{wParam, lParam, up};
    *eaten = up ? TRUE : FALSE;
    return S_OK;
}

STDMETHODIMP TextService::OnKeyUp(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    return OnTestKeyUp(context, wParam, lParam, eaten);
}

bool TextService::processKeyDown(ITfContext *context, WPARAM wParam, LPARAM lParam) {
    auto &host = EngineHost::instance();
    std::lock_guard<std::recursive_mutex> lock(host.mutex());
    if (!composer_) {
        return false;
    }
    if (context) {
        focusContext_ = context;
    }
    sync();
    if (keyboardDisabled(context) || !keyboardOpen()) {
        return false;
    }
    const auto virtualKey = static_cast<UINT>(wParam);
    const bool repeat = (lParam & (1 << 30)) != 0;
    if (!repeat) {
        // 按键热力图（TypingStats 开着时）：扫描码，扩展键或上 0xE000；自动重复不算，密码框在下面读到以后才知道，
        // 这里先按上一个键读到的算（和 macOS 看系统的安全输入一样，只是近似）
        const uint32_t scan = (static_cast<uint32_t>(lParam) >> 16) & 0xFF;
        const uint32_t code = scan | ((lParam & (1 << 24)) ? 0xE000u : 0u);
        host.recordKey(code, around_.password);
    }
    const Composer::Mode modeBefore = composer_->mode();
    if (const auto voice = voiceKey(context, wParam, lParam, true)) {
        return *voice;
    }
    if (isShift(wParam)) {
        // Shift 的按下交给会话判断单按；按住不放的自动重复不算（会话不重新计时）。修饰键永远交给应用
        if (!repeat) {
            composer_->shiftChanged(true, otherModifiersHeld(), monotonicMs(), isRightShift(wParam, lParam));
        }
        if (composer_->mode() != modeBefore) {
            // 过了双击间隔才按下 Shift（定时器晚了）：等着的那一下单按在这里切（#253）
            modeChanged();
        }
        flush(context);
        return false;
    }
    if (isModifierKey(virtualKey)) {
        // 按住 Shift 时按了 Ctrl、Alt、Win：这次 Shift 不算单按（等双击的那一下单按先切，#253）
        if (virtualKey != VK_CAPITAL && virtualKey != VK_NUMLOCK && virtualKey != VK_SCROLL) {
            composer_->otherModifierChanged();
        }
        if (composer_->mode() != modeBefore) {
            modeChanged();
            flush(context);
        }
        return false;
    }
    // 说话途中按了别的键：Esc 取消这次语音（吃掉），别的键也不要这次的语音，键照常处理
    if (host.voice().otherKey(virtualKey == VK_ESCAPE, this)) {
        flush(context);
        return true;
    }
    readSurroundings(context);
    const uint32_t modifiers = currentModifiers();
    const bool extended = (lParam & (1 << 24)) != 0;
    const auto key = translateVirtualKey(virtualKey, typedCharacter(virtualKey, lParam, modifiers), modifiers, extended);
    bool eaten;
    if (!key) {
        // 翻不出来的键（F 键、别的键盘布局打出的非 ASCII 字符）：打字途中、互译攒着原文、
        // 工具栏或表情面板开着时吃掉，免得应用里的光标跑到别处
        composer_->otherModifierChanged();
        eaten = composer_->hasPendingText() || composer_->openPanel() != Composer::Panel::None;
    } else {
        eaten = composer_->handle(*key);
        if (!eaten) {
            // 交给应用的键也记下来（读不到光标前的字时，20:22 的冒号要知道前面是数字）；快捷键之后就不知道了
            const auto ascii = key->ascii();
            lastInserted_ = key->hasShortcutModifier() || !ascii ? 0 : *ascii;
        }
    }
    if (composer_->mode() != modeBefore) {
        modeChanged();
    }
    flush(context);
    return eaten;
}

bool TextService::processKeyUp(ITfContext *context, WPARAM wParam, LPARAM lParam) {
    auto &host = EngineHost::instance();
    std::lock_guard<std::recursive_mutex> lock(host.mutex());
    if (!composer_) {
        return false;
    }
    if (context) {
        focusContext_ = context;
    }
    if (keyboardDisabled(context) || !keyboardOpen()) {
        return false;
    }
    if (const auto voice = voiceKey(context, wParam, lParam, false)) {
        return *voice;
    }
    if (!isShift(wParam)) {
        return false;
    }
    // 单按 Shift 在松开时才算：打到一半切英文时会话把打的字母放进 commit
    if (composer_->shiftChanged(false, otherModifiersHeld(), monotonicMs(), isRightShift(wParam, lParam))) {
        modeChanged();
    }
    flush(context);
    return false;
}

std::optional<bool> TextService::voiceKey(ITfContext *context, WPARAM wParam, LPARAM lParam, bool down) {
    auto &voice = EngineHost::instance().voice();
    const auto &key = voice.key();
    const bool right = (lParam & (1 << 24)) != 0;
    if (!key || !key->matches(static_cast<uint32_t>(wParam), right)) {
        return std::nullopt;
    }
    voice.onStartPolling = [this] {
        if (window_) {
            window_->setTimer(kVoiceTimer, VoiceInput::kPollMs);
        }
    };
    voice.copyToClipboard = [this](const std::string &text) {
        // 密码框里说的话不进剪贴板
        if (!around_.password) {
            copyToClipboard(text);
        }
    };
    if (down && key->modifier) {
        // 和别的修饰键一样：按住 Shift 时按了它，这次 Shift 不算单按（等双击的那一下单按先切，#253）
        const Composer::Mode modeBefore = composer_->mode();
        composer_->otherModifierChanged();
        if (composer_->mode() != modeBefore) {
            modeChanged();
        }
    }
    const bool repeat = (lParam & (1 << 30)) != 0;
    const bool eaten = voice.press(down, down && repeat, composer_->isComposing(), this);
    flush(context);
    return eaten;
}

void TextService::voiceShow(const std::optional<std::string> &status, const std::string &partial) {
    setMarkedText(partial, static_cast<int>(partial.size()));
    if (status) {
        CandidatePage page;
        page.aux = *status;
        showCandidates(&page);
    } else {
        showCandidates(nullptr);
    }
}

void TextService::voiceCommit(const std::string &text) {
    setMarkedText("", 0);
    showCandidates(nullptr);
    if (!text.empty() && composer_) {
        // 和打字上屏一样走 Composer：自动加空格、记上文；互译时进原文
        composer_->insert(text);
    }
}

void TextService::readSurroundings(ITfContext *context) {
    around_ = Surroundings{};
    if (!context) {
        return;
    }
    Surroundings found;
    HRESULT result = E_FAIL;
    const HRESULT hr = EditSession::run(
        context, clientId_, TF_ES_SYNC | TF_ES_READ,
        [&](TfEditCookie ec) -> HRESULT {
            ComPtr<ITfRange> range;
            bool emptySelection = true;
            if (composition_) {
                composition_->GetRange(&range);
            } else {
                range = selectionRange(ec, context);
                BOOL empty = TRUE;
                if (range && SUCCEEDED(range->IsEmpty(ec, &empty))) {
                    emptySelection = empty != FALSE;
                }
            }
            if (!range) {
                return E_FAIL;
            }
            // 光标（或编辑区）前一个字
            ComPtr<ITfRange> before;
            if (SUCCEEDED(range->Clone(&before))) {
                before->Collapse(ec, TF_ANCHOR_START);
                LONG moved = 0;
                if (SUCCEEDED(before->ShiftStart(ec, -1, &moved, nullptr)) && moved == -1) {
                    const auto unit = firstUnit(ec, before.Get());
                    if (!unit) {
                        return E_FAIL;
                    }
                    found.prev = *unit;
                    if (*unit >= 0xDC00 && *unit < 0xE000 && SUCCEEDED(before->ShiftStart(ec, -1, &moved, nullptr)) &&
                        moved == -1) {
                        wchar_t pair[2] = {};
                        ULONG got = 0;
                        if (SUCCEEDED(before->GetText(ec, 0, pair, 2, &got)) && got == 2 && pair[0] >= 0xD800 &&
                            pair[0] < 0xDC00) {
                            found.prev = 0x10000u + ((static_cast<uint32_t>(pair[0]) - 0xD800u) << 10) +
                                         (static_cast<uint32_t>(pair[1]) - 0xDC00u);
                        }
                    }
                }
            }
            // 光标（或编辑区）后一个字；有选区时不报（打的字会换掉选中的）
            if (emptySelection) {
                ComPtr<ITfRange> after;
                if (SUCCEEDED(range->Clone(&after))) {
                    after->Collapse(ec, TF_ANCHOR_END);
                    LONG moved = 0;
                    if (SUCCEEDED(after->ShiftEnd(ec, 1, &moved, nullptr)) && moved == 1) {
                        if (const auto unit = firstUnit(ec, after.Get())) {
                            found.next = *unit;
                        }
                    } else {
                        found.next = 0u; // 光标后确实没有字
                    }
                }
            }
            found.editable = emptySelection;
            // 输入框的类型（InputScope）：密码框不学词、不翻译，网址、邮箱、数字框不补空格
            ComPtr<ITfProperty> property;
            if (SUCCEEDED(context->GetProperty(kGuidPropInputScope, &property))) {
                VARIANT value;
                VariantInit(&value);
                if (SUCCEEDED(property->GetValue(ec, range.Get(), &value)) && value.vt == VT_UNKNOWN && value.punkVal) {
                    ComPtr<ITfInputScope> scope;
                    if (SUCCEEDED(value.punkVal->QueryInterface(IID_PPV_ARGS(&scope)))) {
                        InputScope *scopes = nullptr;
                        UINT count = 0;
                        if (SUCCEEDED(scope->GetInputScopes(&scopes, &count)) && scopes) {
                            for (UINT i = 0; i < count; ++i) {
                                switch (scopes[i]) {
                                case IS_PASSWORD:
                                    found.password = true;
                                    found.noAutoSpace = true;
                                    break;
                                case IS_URL:
                                case IS_EMAIL_SMTPEMAILADDRESS:
                                case IS_EMAIL_USERNAME:
                                case IS_NUMBER:
                                case IS_DIGITS:
                                case IS_TELEPHONE_FULLTELEPHONENUMBER:
                                    found.noAutoSpace = true;
                                    break;
                                default:
                                    break;
                                }
                            }
                            CoTaskMemFree(scopes);
                        }
                    }
                }
                VariantClear(&value);
            }
            found.known = true;
            return S_OK;
        },
        &result);
    if (SUCCEEDED(hr) && SUCCEEDED(result) && found.known) {
        around_ = found;
    }
}

uint32_t TextService::previousCharacter() { return around_.known ? around_.prev : lastInserted_; }

uint32_t TextService::inputHints() {
    uint32_t hints = 0;
    if (around_.password) {
        hints |= WOWTYPE_KEY_HINT_NO_LEARN | WOWTYPE_KEY_HINT_NO_TRANSLATE;
    }
    if (around_.noAutoSpace) {
        hints |= WOWTYPE_KEY_HINT_NO_AUTO_SPACE;
    }
    return hints;
}

// ---------------------------------------------------------------- Composer 的回调：先排着，flush 时做

void TextService::insertText(const std::string &text) {
    ops_.push_back(Op{Op::Kind::Insert, widen(text), 0});
    if (const uint32_t last = lastCodepoint(text)) {
        lastInserted_ = last;
        // 同一个键里接着上屏的（标点跟在候选后面）看到的光标前的字是刚上屏的这个
        around_.prev = last;
    }
}

void TextService::setMarkedText(const std::string &text, int cursorBytes) {
    ops_.push_back(Op{Op::Kind::Mark, widen(text), utf16Offset(text, cursorBytes)});
}

void TextService::showCandidates(const CandidatePage *page) {
    if (window_) {
        window_->killTimer(kModeHintTimer);
    }
    modeHint_ = false;
    if (page) {
        page_ = *page;
    } else {
        page_.reset();
    }
    pageDirty_ = true;
}

bool TextService::moveCaret(int delta) {
    if (!canEditAroundCaret()) {
        return false;
    }
    ops_.push_back(Op{Op::Kind::MoveCaret, L"", delta});
    return true;
}

bool TextService::deletePair() {
    if (!canEditAroundCaret()) {
        return false;
    }
    ops_.push_back(Op{Op::Kind::DeletePair, L"", 0});
    return true;
}

// ---------------------------------------------------------------- 编辑会话里改文字

void TextService::flush(ITfContext *context) {
    if (ops_.empty() && !pageDirty_) {
        return;
    }
    if (!context) {
        // 没有输入框（桌面、没有焦点）：改不了字，候选框收起
        ops_.clear();
        if (pageDirty_ && window_ && !page_) {
            window_->hide();
        }
        pageDirty_ = false;
        return;
    }
    ComPtr<TextService> self(this);
    ComPtr<ITfContext> target(context);
    EditSession::run(context, clientId_, TF_ES_ASYNCDONTCARE | TF_ES_READWRITE, [self, target](TfEditCookie ec) {
        std::lock_guard<std::recursive_mutex> lock(EngineHost::instance().mutex());
        self->applyOps(ec, target.Get());
        return S_OK;
    });
}

void TextService::applyOps(TfEditCookie ec, ITfContext *context) {
    std::vector<Op> ops;
    ops.swap(ops_);
    for (const Op &op : ops) {
        switch (op.kind) {
        case Op::Kind::Insert: commitText(ec, context, op.text); break;
        case Op::Kind::Mark: setComposition(ec, context, op.text, op.value); break;
        case Op::Kind::MoveCaret: applyCaretMove(ec, context, op.value); break;
        case Op::Kind::DeletePair: applyDeletePair(ec, context); break;
        }
    }
    if (pageDirty_) {
        updateWindow(ec, context);
    }
}

bool TextService::startComposition(TfEditCookie ec, ITfContext *context) {
    ComPtr<ITfInsertAtSelection> insert;
    ComPtr<ITfContextComposition> contextComposition;
    if (FAILED(context->QueryInterface(IID_PPV_ARGS(&insert))) ||
        FAILED(context->QueryInterface(IID_PPV_ARGS(&contextComposition)))) {
        return false;
    }
    ComPtr<ITfRange> range;
    if (FAILED(insert->InsertTextAtSelection(ec, TF_IAS_QUERYONLY, nullptr, 0, &range)) || !range) {
        return false;
    }
    ComPtr<ITfComposition> composition;
    if (FAILED(contextComposition->StartComposition(ec, range.Get(), static_cast<ITfCompositionSink *>(this),
                                                     &composition)) ||
        !composition) {
        return false;
    }
    composition_ = composition;
    compositionContext_ = context;
    setSelection(ec, context, range.Get());
    return true;
}

void TextService::commitText(TfEditCookie ec, ITfContext *context, const std::wstring &text) {
    if (!composition_ && !startComposition(ec, context)) {
        // 应用不让开组字：直接插在光标处
        ComPtr<ITfInsertAtSelection> insert;
        ComPtr<ITfRange> range;
        if (SUCCEEDED(context->QueryInterface(IID_PPV_ARGS(&insert))) &&
            SUCCEEDED(insert->InsertTextAtSelection(ec, 0, text.c_str(), static_cast<LONG>(text.size()), &range)) &&
            range) {
            range->Collapse(ec, TF_ANCHOR_END);
            setSelection(ec, context, range.Get());
        }
        return;
    }
    ComPtr<ITfRange> range;
    if (FAILED(composition_->GetRange(&range)) || !range) {
        return;
    }
    range->SetText(ec, 0, text.c_str(), static_cast<LONG>(text.size()));
    setAttribute(ec, context, range.Get(), false);
    range->Collapse(ec, TF_ANCHOR_END);
    setSelection(ec, context, range.Get());
    if (!terminating_) {
        composition_->EndComposition(ec);
    }
    composition_.Reset();
    compositionContext_.Reset();
}

void TextService::setComposition(TfEditCookie ec, ITfContext *context, const std::wstring &text, int cursor) {
    if (text.empty()) {
        if (composition_) {
            ComPtr<ITfRange> range;
            if (SUCCEEDED(composition_->GetRange(&range)) && range) {
                range->SetText(ec, 0, L"", 0);
            }
            if (!terminating_) {
                composition_->EndComposition(ec);
            }
            composition_.Reset();
            compositionContext_.Reset();
        }
        return;
    }
    if (terminating_) {
        return;
    }
    if (!composition_ && !startComposition(ec, context)) {
        return;
    }
    ComPtr<ITfRange> range;
    if (FAILED(composition_->GetRange(&range)) || !range) {
        return;
    }
    range->SetText(ec, TF_ST_CORRECTION, text.c_str(), static_cast<LONG>(text.size()));
    setAttribute(ec, context, range.Get(), true);
    // 光标放在编辑区里会话说的位置
    ComPtr<ITfRange> caret;
    if (SUCCEEDED(range->Clone(&caret))) {
        caret->Collapse(ec, TF_ANCHOR_START);
        LONG moved = 0;
        caret->ShiftEnd(ec, cursor, &moved, nullptr);
        caret->Collapse(ec, TF_ANCHOR_END);
        setSelection(ec, context, caret.Get());
    }
}

void TextService::applyCaretMove(TfEditCookie ec, ITfContext *context, int delta) {
    ComPtr<ITfRange> range = selectionRange(ec, context);
    if (!range) {
        return;
    }
    LONG moved = 0;
    if (delta < 0) {
        range->Collapse(ec, TF_ANCHOR_START);
        range->ShiftStart(ec, delta, &moved, nullptr);
        range->Collapse(ec, TF_ANCHOR_START);
    } else {
        range->Collapse(ec, TF_ANCHOR_END);
        range->ShiftEnd(ec, delta, &moved, nullptr);
        range->Collapse(ec, TF_ANCHOR_END);
    }
    setSelection(ec, context, range.Get());
}

void TextService::applyDeletePair(TfEditCookie ec, ITfContext *context) {
    ComPtr<ITfRange> range = selectionRange(ec, context);
    if (!range) {
        return;
    }
    LONG moved = 0;
    range->ShiftStart(ec, -1, &moved, nullptr);
    range->ShiftEnd(ec, 1, &moved, nullptr);
    range->SetText(ec, 0, L"", 0);
}

void TextService::setAttribute(TfEditCookie ec, ITfContext *context, ITfRange *range, bool on) {
    ComPtr<ITfProperty> property;
    if (inputAttribute_ == TF_INVALID_GUIDATOM || FAILED(context->GetProperty(GUID_PROP_ATTRIBUTE, &property))) {
        return;
    }
    if (!on) {
        property->Clear(ec, range);
        return;
    }
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_I4;
    value.lVal = static_cast<LONG>(inputAttribute_);
    property->SetValue(ec, range, &value);
}

void TextService::updateWindow(TfEditCookie ec, ITfContext *context) {
    pageDirty_ = false;
    if (!window_) {
        return;
    }
    if (!page_) {
        window_->hide();
        return;
    }
    // 问应用编辑区（没有编辑区时是光标）在屏幕的哪里
    ComPtr<ITfRange> range;
    if (composition_) {
        composition_->GetRange(&range);
    } else {
        range = selectionRange(ec, context);
    }
    ComPtr<ITfContextView> view;
    RECT rect{};
    BOOL clipped = FALSE;
    if (range && SUCCEEDED(context->GetActiveView(&view)) && view &&
        SUCCEEDED(view->GetTextExt(ec, range.Get(), &rect, &clipped)) && (rect.bottom > rect.top || rect.right > rect.left)) {
        anchor_ = rect;
    } else {
        // 应用说不出（还没排好版）：用系统的光标位置，再不然用上一次的位置
        GUITHREADINFO info{};
        info.cbSize = sizeof info;
        if (GetGUIThreadInfo(GetCurrentThreadId(), &info) && info.hwndCaret) {
            POINT topLeft{info.rcCaret.left, info.rcCaret.top};
            POINT bottomRight{info.rcCaret.right, info.rcCaret.bottom};
            ClientToScreen(info.hwndCaret, &topLeft);
            ClientToScreen(info.hwndCaret, &bottomRight);
            anchor_ = RECT{topLeft.x, topLeft.y, bottomRight.x, bottomRight.y};
        }
    }
    window_->show(*page_, anchor_, EngineHost::instance().config().candidateFontSize());
}

// ---------------------------------------------------------------- 组字被打断、换输入框

STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie ec, ITfComposition *composition) {
    std::lock_guard<std::recursive_mutex> lock(EngineHost::instance().mutex());
    if (!composition_ || !composer_) {
        composition_.Reset();
        compositionContext_.Reset();
        return S_OK;
    }
    // 应用结束了组字（点了别处、换了输入框）：打的字母原样上屏（和 macOS 一样），这时只能改组字里的字
    ComPtr<ITfContext> context = compositionContext_;
    terminating_ = true;
    composer_->commitComposition();
    if (context) {
        applyOps(ec, context.Get());
    }
    terminating_ = false;
    ops_.clear();
    composition_.Reset();
    compositionContext_.Reset();
    (void)composition;
    if (window_) {
        window_->hide();
    }
    return S_OK;
}

void TextService::endComposition() {
    if (!composer_) {
        return;
    }
    ComPtr<ITfContext> context = composition_ ? compositionContext_ : focusContext_;
    composer_->commitComposition();
    flush(context.Get());
    if (window_) {
        window_->killTimer(kTranslateTimer);
        window_->hide();
    }
    page_.reset();
}

STDMETHODIMP TextService::OnSetFocus(ITfDocumentMgr *focus, ITfDocumentMgr *) {
    std::lock_guard<std::recursive_mutex> lock(EngineHost::instance().mutex());
    // 换了输入框：这次说的话不要了；上一个里打到一半的原样上屏，会话记的上文作废
    EngineHost::instance().voice().cancel(this);
    endComposition();
    focusContext_.Reset();
    if (focus) {
        focus->GetTop(&focusContext_);
    }
    around_ = Surroundings{};
    lastInserted_ = 0;
    pendingDown_.reset();
    handledUp_.reset();
    // 换到别的窗口：设了「默认中/英文」就定一次（WindowMode，#254；同一个窗口里换输入框不算）
    if (focus) {
        noteWindow(topLevelWindow(focus), false);
    }
    return S_OK;
}

void TextService::noteWindow(HWND window, bool appChanged) {
    const bool moved = appChanged || (window && window != lastWindow_);
    if (window) {
        lastWindow_ = window;
    }
    // 打到一半切走又切回来（Alt+Tab）的接着打，不换模式
    if (!moved || !composer_ || composer_->hasPendingText()) {
        return;
    }
    sync();
    const Composer::Mode before = composer_->mode();
    composer_->applyWindowMode();
    if (composer_->mode() != before && langBar_) {
        langBar_->update();
    }
    flush(currentContext());
}

STDMETHODIMP TextService::OnSetThreadFocus() {
    std::lock_guard<std::recursive_mutex> lock(EngineHost::instance().mutex());
    // 从别的应用切回来：设了「默认中/英文」就定一次（WindowMode，#254）
    ComPtr<ITfDocumentMgr> focus;
    if (threadMgr_ && SUCCEEDED(threadMgr_->GetFocus(&focus)) && focus) {
        noteWindow(topLevelWindow(focus.Get()), true);
    }
    if (window_ && page_ && composer_ && composer_->hasPendingText()) {
        window_->show(*page_, anchor_, EngineHost::instance().config().candidateFontSize());
    }
    return S_OK;
}

STDMETHODIMP TextService::OnKillThreadFocus() {
    if (window_) {
        window_->hide();
    }
    EngineHost::instance().flushStats();
    return S_OK;
}

// ---------------------------------------------------------------- 显示属性

STDMETHODIMP TextService::EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo **enumInfo) {
    if (!enumInfo) {
        return E_INVALIDARG;
    }
    *enumInfo = new (std::nothrow) wowtype::tsf::EnumDisplayAttributeInfo();
    return *enumInfo ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP TextService::GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo **info) {
    if (!info) {
        return E_INVALIDARG;
    }
    *info = nullptr;
    if (!IsEqualGUID(guid, kGuidDisplayAttributeInput)) {
        return E_INVALIDARG;
    }
    *info = new (std::nothrow) DisplayAttributeInfo();
    return *info ? S_OK : E_OUTOFMEMORY;
}

// ---------------------------------------------------------------- 模式、任务栏按钮、定时器

void TextService::modeChanged() {
    if (langBar_) {
        langBar_->update();
    }
    showModeHint();
}

void TextService::showModeHint() {
    // 切到中 / 英 / 译以后在光标下面亮一下，过一会儿收起；还有没上屏的字时不画（候选框正画着它们）
    if (!composer_ || composer_->hasPendingText() || !window_) {
        return;
    }
    CandidatePage hint;
    hint.aux = narrow(modeTooltip());
    page_ = hint;
    pageDirty_ = true;
    modeHint_ = true;
    window_->setTimer(kModeHintTimer, kModeHintMs);
}

void TextService::onTimer(UINT_PTR id) {
    std::lock_guard<std::recursive_mutex> lock(EngineHost::instance().mutex());
    if (!window_) {
        return;
    }
    if (id == kModeHintTimer) {
        window_->killTimer(kModeHintTimer);
        if (modeHint_) {
            modeHint_ = false;
            page_.reset();
            window_->hide();
        }
        return;
    }
    if (id == kVoiceTimer) {
        if (!EngineHost::instance().voice().poll()) {
            window_->killTimer(kVoiceTimer);
        }
        flush(currentContext());
        return;
    }
    if (id == kTranslateTimer) {
        if (!composer_) {
            window_->killTimer(kTranslateTimer);
            return;
        }
        const Composer::Mode modeBefore = composer_->mode();
        const uint32_t wake = composer_->pollTranslation();
        if (composer_->mode() != modeBefore) {
            // 单按 Shift 等双击等到了时间（#253）：这时才切，任务栏和提示跟上
            modeChanged();
        }
        flush(currentContext());
        if (wake == 0) {
            window_->killTimer(kTranslateTimer);
        }
    }
}

std::wstring TextService::modeLabel() {
    if (!composer_) {
        return L"中";
    }
    switch (composer_->mode()) {
    case Composer::Mode::English: return L"英";
    case Composer::Mode::Translate: return L"译";
    default: return L"中";
    }
}

std::wstring TextService::modeTooltip() {
    std::wstring label = modeLabel();
    if (composer_ && composer_->mode() == Composer::Mode::Translate) {
        if (WowtypeTranslator *translator = EngineHost::instance().translator()) {
            const char *tag = wowtype_translate_tag(translator, "");
            if (tag && *tag) {
                label += L" " + widen(tag);
            }
        }
    }
    return label;
}

void TextService::toggleModeFromButton() {
    std::lock_guard<std::recursive_mutex> lock(EngineHost::instance().mutex());
    if (!composer_) {
        return;
    }
    sync();
    composer_->switchMode(composer_->mode() == Composer::Mode::Chinese ? Composer::Mode::English
                                                                       : Composer::Mode::Chinese);
    if (langBar_) {
        langBar_->update();
    }
    flush(currentContext());
}

std::vector<TextService::MenuItem> TextService::menuItems() {
    std::lock_guard<std::recursive_mutex> lock(EngineHost::instance().mutex());
    const Composer::Mode mode = composer_ ? composer_->mode() : Composer::Mode::Chinese;
    const bool translate = composer_ && composer_->translateAvailable();
    const auto update = EngineHost::instance().availableUpdate();
    const auto radio = [&](Composer::Mode m) { return mode == m ? static_cast<DWORD>(TF_LBMENUF_RADIOCHECKED) : 0u; };
    std::vector<MenuItem> items;
    if (update) {
        // 新版本在设置窗口「常规」页下载安装（不在输入法所在的应用进程里装）
        items.push_back({kMenuUpdate, 0, L"有新版本 " + widen(*update) + L"，下载并安装…"});
        items.push_back({0, TF_LBMENUF_SEPARATOR, L""});
    }
    std::vector<MenuItem> rest = {
        {kMenuChinese, radio(Composer::Mode::Chinese), L"中文"},
        {kMenuEnglish, radio(Composer::Mode::English), L"英文"},
        {kMenuTranslate, radio(Composer::Mode::Translate) | (translate ? 0u : static_cast<DWORD>(TF_LBMENUF_GRAYED)),
         L"互译"},
        {0, TF_LBMENUF_SEPARATOR, L""},
        {kMenuSettings, 0, L"WowType 设置…"},
        {kMenuConfig, 0, L"打开设置文件（wowtype.conf）"},
        {kMenuDataDir, 0, L"打开数据目录"},
    };
    items.insert(items.end(), rest.begin(), rest.end());
    return items;
}

namespace {

/// 用记事本打开设置文件（没有就先建一个带说明的模板），存了以后下一次按键就生效。
void openConfigFile() {
    auto &host = EngineHost::instance();
    CreateDirectoryW(host.dataDir().c_str(), nullptr);
    const std::wstring path = host.configPath();
    if (!fileExists(path)) {
        std::ofstream out(path, std::ios::binary);
        out << Config::templateText();
    }
    ShellExecuteW(nullptr, L"open", L"notepad.exe", path.c_str(), nullptr, SW_SHOWNORMAL);
}

} // namespace

void TextService::menuCommand(UINT id) {
    auto &host = EngineHost::instance();
    std::lock_guard<std::recursive_mutex> lock(host.mutex());
    switch (id) {
    case kMenuChinese:
    case kMenuEnglish:
    case kMenuTranslate:
        if (composer_) {
            sync();
            composer_->switchMode(id == kMenuChinese   ? Composer::Mode::Chinese
                                  : id == kMenuEnglish ? Composer::Mode::English
                                                       : Composer::Mode::Translate);
            if (langBar_) {
                langBar_->update();
            }
            flush(currentContext());
        }
        break;
    case kMenuSettings: {
        // 设置窗口是安装目录里单独的程序（输入法在别人的进程里，不在这里开窗口）；没有就用记事本开设置文件
        const std::wstring exe = moduleDir() + L"\\wowtype-settings.exe";
        if (fileExists(exe)) {
            ShellExecuteW(nullptr, L"open", exe.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        } else {
            openConfigFile();
        }
        break;
    }
    case kMenuConfig:
        openConfigFile();
        break;
    case kMenuUpdate: {
        const std::wstring exe = moduleDir() + L"\\wowtype-settings.exe";
        if (fileExists(exe)) {
            ShellExecuteW(nullptr, L"open", exe.c_str(), L"--update", nullptr, SW_SHOWNORMAL);
        } else {
            ShellExecuteW(nullptr, L"open", L"https://github.com/Gloridust/WowType/releases", nullptr, nullptr, SW_SHOWNORMAL);
        }
        break;
    }
    case kMenuDataDir:
        CreateDirectoryW(host.dataDir().c_str(), nullptr);
        ShellExecuteW(nullptr, L"open", host.dataDir().c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        break;
    default:
        break;
    }
}

} // namespace wowtype::tsf
