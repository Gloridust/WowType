// 端到端打字测试（只在 Windows 上，CI 的 Windows 任务装好安装程序以后跑）：开一个带输入框的窗口，用 TSF 把这个进程的
// 输入法切到 WowType，用 SendInput 按真的键，再读输入框里的字。走的是和真实应用一样的路：系统的按键 → TSF → wowtype.dll
// （文本服务、Composer、核心的会话）→ 组字和上屏 → 输入框。另外看候选框窗口有没有出来、在不在输入框附近。
//
//   wowtype-windows-typing-test.exe
//
// 要已经注册好输入法（安装程序或 regsvr32）、装了真实词库；要有能用的桌面（GitHub 的 Windows runner 有）。
// 结果一行一个 ok / FAIL，退出码是没过的条数。

#include <windows.h>

#include <ctfutb.h>
#include <msctf.h>
#include <richedit.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

// 和 windows/src/tsf/globals.cpp 一样
const CLSID kClsid = {0xa895b83f, 0x8f60, 0x4990, {0xa4, 0x8f, 0x17, 0x82, 0x1e, 0x3b, 0xc1, 0x4a}};
const GUID kProfile = {0x8106db80, 0x2dc6, 0x4558, {0xb3, 0x68, 0x86, 0xd2, 0x6f, 0x78, 0xec, 0x68}};
constexpr LANGID kLangId = MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_SIMPLIFIED);

HWND g_window = nullptr;
HWND g_edit = nullptr;
int g_failures = 0;
ComPtr<ITfThreadMgr> g_threadMgr;
// GUID_LBI_INPUTMODE：任务栏输入指示器上的按钮（和 windows/src/tsf/globals.cpp 一样）
const GUID kLbiInputMode = {0x2c77a81e, 0x41cc, 0x4178, {0xa3, 0xa7, 0x5f, 0x8a, 0x98, 0x75, 0x68, 0xe6}};

std::string narrow(const std::wstring &w) {
    if (w.empty()) {
        return {};
    }
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<std::size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), out.data(), n, nullptr, nullptr);
    return out;
}

void check(bool ok, const char *name, const std::wstring &detail = L"") {
    if (ok) {
        std::printf("ok   %s\n", name);
    } else {
        ++g_failures;
        std::printf("FAIL %s  [%s]\n", name, narrow(detail).c_str());
    }
    std::fflush(stdout);
}

/// 处理一会儿消息（输入法的编辑会话、候选框、我们自己的窗口都在这个线程上）。
void pump(DWORD ms) {
    const ULONGLONG until = GetTickCount64() + ms;
    while (GetTickCount64() < until) {
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    }
}

void sendKey(WORD vk, bool up) {
    INPUT input{};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = vk;
    input.ki.wScan = static_cast<WORD>(MapVirtualKeyW(vk, MAPVK_VK_TO_VSC));
    input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
    SendInput(1, &input, sizeof input);
}

void tap(WORD vk) {
    sendKey(vk, false);
    pump(40);
    sendKey(vk, true);
    pump(60);
}

/// 按一串键：字母、数字、空格、逗号、句号照键盘上的键按；Shift 要的字符这里不用。
void typeKeys(const char *keys) {
    for (const char *p = keys; *p; ++p) {
        const char c = *p;
        WORD vk = 0;
        if (c >= 'a' && c <= 'z') {
            vk = static_cast<WORD>('A' + (c - 'a'));
        } else if (c >= '0' && c <= '9') {
            vk = static_cast<WORD>(c);
        } else if (c == ' ') {
            vk = VK_SPACE;
        } else if (c == ',') {
            vk = VK_OEM_COMMA;
        } else if (c == '.') {
            vk = VK_OEM_PERIOD;
        }
        tap(vk);
    }
}

std::wstring text() {
    const int n = GetWindowTextLengthW(g_edit);
    std::wstring s(static_cast<std::size_t>(n) + 1, L'\0');
    GetWindowTextW(g_edit, s.data(), n + 1);
    s.resize(static_cast<std::size_t>(n));
    return s;
}

void clear() {
    SetWindowTextW(g_edit, L"");
    pump(100);
}

void focus() {
    // 抢到前台：从后台起的进程直接 SetForegroundWindow 常被系统拦，借前台线程的输入状态一下
    const DWORD fg = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
    const DWORD me = GetCurrentThreadId();
    if (fg != me) {
        AttachThreadInput(fg, me, TRUE);
    }
    ShowWindow(g_window, SW_SHOW);
    BringWindowToTop(g_window);
    SetForegroundWindow(g_window);
    SetFocus(g_edit);
    if (fg != me) {
        AttachThreadInput(fg, me, FALSE);
    }
    pump(200);
}

HWND candidateWindow() { return FindWindowW(L"WowTypeCandidateWindow", nullptr); }

/// 截一张屏幕上 rect 那一块存成 BMP（WOWTYPE_SCREENSHOT_DIR 设了才截，CI 把它们传上去看候选框画得对不对）。
void screenshot(RECT rect, const wchar_t *name) {
    wchar_t dir[MAX_PATH] = {};
    if (GetEnvironmentVariableW(L"WOWTYPE_SCREENSHOT_DIR", dir, MAX_PATH) == 0) {
        return;
    }
    const int w = rect.right - rect.left;
    const int h = rect.bottom - rect.top;
    if (w <= 0 || h <= 0) {
        return;
    }
    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateCompatibleBitmap(screen, w, h);
    HGDIOBJ old = SelectObject(memory, bitmap);
    BitBlt(memory, 0, 0, w, h, screen, rect.left, rect.top, SRCCOPY | CAPTUREBLT);
    SelectObject(memory, old);
    BITMAPINFOHEADER info{};
    info.biSize = sizeof info;
    info.biWidth = w;
    info.biHeight = h;
    info.biPlanes = 1;
    info.biBitCount = 24;
    info.biCompression = BI_RGB;
    const DWORD stride = ((static_cast<DWORD>(w) * 3 + 3) / 4) * 4;
    std::vector<unsigned char> pixels(static_cast<std::size_t>(stride) * h);
    GetDIBits(memory, bitmap, 0, static_cast<UINT>(h), pixels.data(), reinterpret_cast<BITMAPINFO *>(&info), DIB_RGB_COLORS);
    BITMAPFILEHEADER file{};
    file.bfType = 0x4D42;
    file.bfOffBits = sizeof file + sizeof info;
    file.bfSize = file.bfOffBits + static_cast<DWORD>(pixels.size());
    const std::wstring path = std::wstring(dir) + L"\\" + name + L".bmp";
    FILE *f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"wb") == 0 && f) {
        std::fwrite(&file, sizeof file, 1, f);
        std::fwrite(&info, sizeof info, 1, f);
        std::fwrite(pixels.data(), 1, pixels.size(), f);
        std::fclose(f);
    }
    DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
}

bool candidatesShown() {
    const HWND h = candidateWindow();
    return h && IsWindowVisible(h);
}

/// 任务栏输入指示器上 WowType 那个按钮现在写的字（中 / 英 / 译）；没有这个按钮是空串。
std::wstring langBarText() {
    ComPtr<ITfLangBarItemMgr> items;
    ComPtr<ITfLangBarItem> item;
    ComPtr<ITfLangBarItemButton> button;
    if (!g_threadMgr || FAILED(g_threadMgr.As(&items)) || FAILED(items->GetItem(kLbiInputMode, &item)) ||
        FAILED(item.As(&button))) {
        return L"";
    }
    TF_LANGBARITEMINFO info{};
    if (FAILED(item->GetInfo(&info)) || !IsEqualCLSID(info.clsidService, kClsid)) {
        return L"（不是 WowType 的）";
    }
    BSTR text = nullptr;
    if (FAILED(button->GetText(&text)) || !text) {
        return L"";
    }
    std::wstring out(text);
    SysFreeString(text);
    return out;
}

/// 截任务栏右边那一段（输入指示器在那里）
void shootTaskbar(const wchar_t *name) {
    if (const HWND tray = FindWindowW(L"Shell_TrayWnd", nullptr)) {
        RECT r{};
        GetWindowRect(tray, &r);
        r.left = std::max(r.left, r.right - 500);
        screenshot(r, name);
    }
}

/// 截 owner 窗口和候选框一起的那一块（候选框在屏幕上的样子）
void shootWithCandidates(HWND owner, const wchar_t *name) {
    RECT a{};
    GetWindowRect(owner, &a);
    RECT b{};
    if (const HWND c = candidateWindow(); c && IsWindowVisible(c)) {
        GetWindowRect(c, &b);
        UnionRect(&a, &a, &b);
    }
    InflateRect(&a, 20, 20);
    screenshot(a, name);
}

/// 让另一个进程的窗口到前台（AttachThreadInput 借一下前台线程的输入状态）。
void bringToFront(HWND hwnd) {
    const DWORD fg = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
    const DWORD me = GetCurrentThreadId();
    if (fg != me) {
        AttachThreadInput(fg, me, TRUE);
    }
    ShowWindow(hwnd, SW_RESTORE);
    BringWindowToTop(hwnd);
    SetForegroundWindow(hwnd);
    if (fg != me) {
        AttachThreadInput(fg, me, FALSE);
    }
}

void clickAt(int x, int y) {
    SetCursorPos(x, y);
    INPUT inputs[2] = {};
    inputs[0].type = INPUT_MOUSE;
    inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    inputs[1].type = INPUT_MOUSE;
    inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    SendInput(2, inputs, sizeof(INPUT));
    pump(200);
}

/// Win + 空格：用户切输入法的办法（在键盘列表里往下切一个）。
void winSpace() {
    sendKey(VK_LWIN, false);
    pump(50);
    tap(VK_SPACE);
    sendKey(VK_LWIN, true);
    pump(800);
}

// ---------------------------------------------------------------- Edge（Chromium 的 TSF，Chrome、VS Code 这些 Electron 应用一样）

HWND g_edge = nullptr;

BOOL CALLBACK findEdge(HWND hwnd, LPARAM) {
    wchar_t title[256] = {};
    GetWindowTextW(hwnd, title, 256);
    if (IsWindowVisible(hwnd) && wcsncmp(title, L"wt", 2) == 0) {
        g_edge = hwnd;
        return FALSE;
    }
    return TRUE;
}

/// 网页把输入框里的字写进标题：wt[字]
std::wstring edgeText() {
    wchar_t title[512] = {};
    GetWindowTextW(g_edge, title, 512);
    std::wstring t(title);
    const auto open = t.find(L"wt[");
    const auto close = t.rfind(L']');
    if (open == std::wstring::npos || close == std::wstring::npos || close < open + 3) {
        return L"";
    }
    return t.substr(open + 3, close - open - 3);
}

void edgeClear() {
    sendKey(VK_CONTROL, false);
    tap('A');
    sendKey(VK_CONTROL, true);
    tap(VK_BACK);
    pump(300);
}

void edgeTest() {
    wchar_t programFiles[MAX_PATH] = {};
    std::wstring edge;
    for (const wchar_t *var : {L"ProgramFiles(x86)", L"ProgramFiles"}) {
        if (GetEnvironmentVariableW(var, programFiles, MAX_PATH) > 0) {
            const std::wstring path = std::wstring(programFiles) + L"\\Microsoft\\Edge\\Application\\msedge.exe";
            if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) {
                edge = path;
                break;
            }
        }
    }
    if (edge.empty()) {
        std::printf("skip Edge（没装）\n");
        return;
    }
    wchar_t temp[MAX_PATH] = {};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring page = std::wstring(temp) + L"wowtype-edge-test.html";
    {
        const char *html =
            "<!doctype html><meta charset=utf-8><title>wt-ready</title>"
            "<textarea id=t autofocus style='width:90%;height:200px;font-size:24px'></textarea>"
            "<script>const t=document.getElementById('t');t.focus();"
            "t.addEventListener('input',()=>{document.title='wt['+t.value+']'});</script>";
        FILE *f = _wfopen(page.c_str(), L"wb");
        if (f) {
            std::fputs(html, f);
            std::fclose(f);
        }
    }
    std::wstring url = L"file:///" + page;
    for (auto &c : url) {
        if (c == L'\\') {
            c = L'/';
        }
    }
    std::wstring command = L"\"" + edge + L"\" --app=\"" + url + L"\" --user-data-dir=\"" + temp +
                           L"wowtype-edge-profile\" --no-first-run --no-default-browser-check --disable-sync "
                           L"--window-size=800,400 --window-position=100,380";
    STARTUPINFOW startup{};
    startup.cb = sizeof startup;
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &process)) {
        check(false, "起 Edge");
        return;
    }
    for (int i = 0; i < 60 && !g_edge; ++i) {
        EnumWindows(findEdge, 0);
        pump(500);
    }
    check(g_edge != nullptr, "Edge 的窗口出来了");
    if (!g_edge) {
        return;
    }
    pump(2000);
    RECT r{};
    GetWindowRect(g_edge, &r);
    bringToFront(g_edge);
    clickAt((r.left + r.right) / 2, r.top + 120);
    // 用户的切法：Win + 空格在键盘列表里往下切，直到打字时出来的是 WowType 的候选框（不是系统自带的微软拼音）
    bool wowtype = false;
    for (int attempt = 0; attempt < 5 && !wowtype; ++attempt) {
        bringToFront(g_edge);
        typeKeys("ni");
        pump(600);
        wowtype = candidatesShown();
        tap(VK_ESCAPE);
        edgeClear();
        if (!wowtype) {
            winSpace();
        }
    }
    check(wowtype, "Edge 里用 Win + 空格切到了 WowType（打字时出来的是 WowType 的候选框）");
    if (wowtype) {
        // 词库在 Edge 的进程里另载一份：等一会儿
        bool typed = false;
        for (int attempt = 0; attempt < 20 && !typed; ++attempt) {
            edgeClear();
            typeKeys("nihao ");
            pump(500);
            typed = edgeText() == L"你好";
            if (!typed) {
                pump(1500);
            }
        }
        check(typed, "Edge（Chromium）里 nihao 空格 → 你好", edgeText());
        edgeClear();
        typeKeys("shi");
        pump(500);
        RECT box{};
        const bool shown = candidatesShown() && GetWindowRect(candidateWindow(), &box);
        check(shown && box.top >= r.top && box.top <= r.bottom + 200, "Edge 里候选框在输入框附近");
        shootWithCandidates(g_edge, L"edge-shi");
        tap('2');
        pump(400);
        check(edgeText().size() == 1, "Edge 里数字选候选", edgeText());
        edgeClear();
        typeKeys("nihao,");
        pump(500);
        check(edgeText() == L"你好，", "Edge 里打字途中按逗号", edgeText());
    }
    PostMessageW(g_edge, WM_CLOSE, 0, 0);
    if (WaitForSingleObject(process.hProcess, 5000) == WAIT_TIMEOUT) {
        TerminateProcess(process.hProcess, 0);
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
}

LRESULT CALLBACK proc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

} // namespace

// ---------------------------------------------------------------- 两个进程之间的学习（Windows 上每个应用各有一个引擎）
//
//   wowtype-windows-typing-test.exe --peer-wait <目录>   B：先开着，记下 shi 空格出的字，等 A 学完再打一次
//   wowtype-windows-typing-test.exe --peer-learn <目录>  A：等 B 准备好，连着选 shi 的第三个候选几次（学到它），等存盘
// 两个进程在 <目录> 里用小文件打招呼。B 第二次出的字应该是 A 学到的（各个应用学到的词几秒内都有，docs/WINDOWS.md）。
// 接着 A 用 Ctrl+退格忘掉这个字：B 也忘了；B 存过盘以后 A 再合并，也不会回来。

bool waitForFile(const std::wstring &path, DWORD ms) {
    const ULONGLONG until = GetTickCount64() + ms;
    while (GetTickCount64() < until) {
        if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) {
            return true;
        }
        pump(200);
    }
    return false;
}

void writeFile(const std::wstring &path, const std::wstring &text) {
    FILE *f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"wb") == 0 && f) {
        const std::string utf8 = narrow(text);
        std::fwrite(utf8.data(), 1, utf8.size(), f);
        std::fclose(f);
    }
}

std::wstring readFile(const std::wstring &path) {
    FILE *f = nullptr;
    std::string utf8;
    if (_wfopen_s(&f, path.c_str(), L"rb") == 0 && f) {
        char buffer[256];
        std::size_t n;
        while ((n = std::fread(buffer, 1, sizeof buffer, f)) > 0) {
            utf8.append(buffer, n);
        }
        std::fclose(f);
    }
    const int n = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    std::wstring out(static_cast<std::size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), out.data(), n);
    return out;
}

/// 打 shi 空格，返回上屏的那个字（输入框清空后打）。
std::wstring commitShi() {
    clear();
    focus();
    typeKeys("shi ");
    pump(400);
    return text();
}

int peerWait(const std::wstring &dir) {
    const std::wstring before = commitShi();
    check(before.size() == 1, "B：shi 空格出一个字", before);
    writeFile(dir + L"\\ready", before);
    const bool learned = waitForFile(dir + L"\\learned", 120000);
    check(learned, "B：等到 A 学完");
    pump(1000); // 下一次按键时合并 A 存的
    const std::wstring wanted = readFile(dir + L"\\learned");
    const std::wstring after = commitShi();
    check(after == wanted, "B：A 在另一个进程里学到的字，B 不用重开就排到了第一（几秒内各个应用都有）",
          L"之前 " + before + L"，A 学的 " + wanted + L"，现在 " + after);
    writeFile(dir + L"\\b-checked", after);
    // A 忘掉它：B 下一次按键合并以后也忘了
    check(waitForFile(dir + L"\\forgot", 120000), "B：等到 A 忘掉");
    pump(1000);
    const std::wstring afterForget = commitShi();
    check(afterForget.size() == 1 && afterForget != wanted, "B：A 在另一个进程里忘掉的字，B 也忘了",
          L"A 忘掉的 " + wanted + L"，现在 " + afterForget);
    // 让 B 存一次盘（存之前先合并 A 存的：A 忘掉的不会被 B 写回去）
    pump(3000);
    typeKeys("a");
    tap(VK_ESCAPE);
    pump(2000);
    writeFile(dir + L"\\b-saved", afterForget);
    return g_failures;
}

int peerLearn(const std::wstring &dir) {
    check(waitForFile(dir + L"\\ready", 120000), "A：等到 B 准备好");
    const std::wstring before = readFile(dir + L"\\ready");
    // 选一次 shi 的第三个候选，记下是哪个字；再选几次同一个字。它学了以后会往前挪：按 1、2、3 找，
    // 选错的紧接着退格（应用删掉，核心把这次学到的退回去）。每次都在清空的输入框里打，上文是空的
    clear();
    focus();
    typeKeys("shi");
    tap('3');
    pump(300);
    const std::wstring picked = text();
    for (int round = 0; round < 5; ++round) {
        for (char index = '1'; index <= '3'; ++index) {
            clear();
            focus();
            typeKeys("shi");
            tap(index);
            pump(300);
            if (text() == picked) {
                break;
            }
            tap(VK_BACK);
            pump(200);
        }
    }
    const std::wstring top = commitShi();
    check(picked.size() == 1 && picked != before, "A：选了 shi 的第三个候选", picked);
    check(top == picked, "A：选了几次以后它排到了第一", L"选的 " + picked + L"，现在第一 " + top);
    // 等存盘（学到了词最多隔 2 秒存一次，存盘在核心的线程上）
    pump(4000);
    typeKeys("a");
    tap(VK_ESCAPE);
    pump(2000);
    writeFile(dir + L"\\learned", top);
    // B 看过了：A 用 Ctrl+退格忘掉第一个候选（学到的那个），马上存
    check(waitForFile(dir + L"\\b-checked", 120000), "A：等到 B 看过");
    pump(1000);
    clear();
    focus();
    typeKeys("shi");
    sendKey(VK_CONTROL, false);
    tap(VK_BACK);
    sendKey(VK_CONTROL, true);
    pump(300);
    tap(VK_ESCAPE);
    pump(300);
    const std::wstring afterForget = commitShi();
    check(afterForget.size() == 1 && afterForget != top, "A：Ctrl+退格忘掉学到的字", L"忘掉的 " + top + L"，现在 " + afterForget);
    pump(1500);
    writeFile(dir + L"\\forgot", top);
    // B 存过盘（B 内存里还有这个字的时候学的那些）：A 合并以后也不会回来
    check(waitForFile(dir + L"\\b-saved", 120000), "A：等到 B 存盘");
    pump(1000);
    const std::wstring last = commitShi();
    check(last.size() == 1 && last != top, "A：B 存过盘以后，A 忘掉的字也没有回来", L"忘掉的 " + top + L"，现在 " + last);
    return g_failures;
}

int main(int argc, char **argv) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // 输入法把每个按键回调记进日志：没过的时候 CI 打出来看
    SetEnvironmentVariableW(L"WOWTYPE_DEBUG_KEYS", L"1");
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"WowTypeTypingTest";
    wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    RegisterClassExW(&wc);
    g_window = CreateWindowExW(0, wc.lpszClassName, L"WowType 打字测试", WS_OVERLAPPEDWINDOW, 100, 100, 640, 240,
                               nullptr, nullptr, wc.hInstance, nullptr);
    g_edit = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_BORDER | ES_MULTILINE | ES_AUTOVSCROLL, 10, 10,
                             600, 160, g_window, nullptr, wc.hInstance, nullptr);
    focus();

    // 安装程序已经把 WowType 加进了当前用户的键盘列表；再加一次也没关系（runner 上可能是别的用户装的）
    {
        using InstallLayoutOrTipFn = BOOL(WINAPI *)(LPCWSTR, DWORD);
        if (HMODULE input = LoadLibraryW(L"input.dll")) {
            if (const auto install = reinterpret_cast<InstallLayoutOrTipFn>(GetProcAddress(input, "InstallLayoutOrTip"))) {
                check(install(L"0804:{A895B83F-8F60-4990-A48F-17821E3BC14A}{8106DB80-2DC6-4558-B368-86D26F78EC68}", 0) != FALSE,
                      "WowType 在键盘列表里");
            }
        }
    }
    // 这个线程上先起 TSF（输入框会用同一个线程管理器），再把这个进程的输入法切到 WowType
    TfClientId client = TF_CLIENTID_NULL;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&g_threadMgr)))) {
        g_threadMgr->Activate(&client);
    }
    ComPtr<ITfInputProcessorProfileMgr> profiles;
    HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&profiles));
    check(SUCCEEDED(hr), "建 ITfInputProcessorProfileMgr");
    if (FAILED(hr)) {
        return 1;
    }
    ComPtr<ITfInputProcessorProfiles> legacy;
    profiles.As(&legacy);

    // 诊断：装了哪些键盘布局、WowType 的配置在不在、开没开
    {
        HKL layouts[32] = {};
        const int n = GetKeyboardLayoutList(32, layouts);
        std::printf("键盘布局：");
        for (int i = 0; i < n; ++i) {
            std::printf(" %08llx", static_cast<unsigned long long>(reinterpret_cast<UINT_PTR>(layouts[i])));
        }
        std::printf("\n");
        TF_INPUTPROCESSORPROFILE info{};
        if (SUCCEEDED(profiles->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR, kLangId, kClsid, kProfile, nullptr, &info))) {
            std::printf("WowType 配置：flags=%lx（1 是开着）\n", static_cast<unsigned long>(info.dwFlags));
        } else {
            std::printf("WowType 配置：取不到\n");
        }
        std::fflush(stdout);
    }

    const auto isActive = [&] {
        TF_INPUTPROCESSORPROFILE active{};
        return SUCCEEDED(profiles->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD, &active)) &&
               IsEqualCLSID(active.clsid, kClsid);
    };
    // 一个一个试系统给的几种切法，切上了就停
    const auto attempt = [&](const char *how, HRESULT result) {
        pump(300);
        std::printf("  %s：hr=%08lx，现在%s WowType\n", how, static_cast<unsigned long>(result), isActive() ? "是" : "不是");
        std::fflush(stdout);
        return isActive();
    };
    bool switched = attempt("ActivateProfile", profiles->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, kLangId, kClsid,
                                                                          kProfile, nullptr,
                                                                          TF_IPPMF_FORPROCESS | TF_IPPMF_ENABLEPROFILE |
                                                                              TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE));
    if (!switched && legacy) {
        legacy->EnableLanguageProfile(kClsid, kLangId, kProfile, TRUE);
        legacy->ChangeCurrentLanguage(kLangId);
        switched = attempt("ActivateLanguageProfile", legacy->ActivateLanguageProfile(kClsid, kLangId, kProfile));
    }
    if (!switched) {
        // 先把这个进程的键盘布局换成简体中文，再切
        const HKL chinese = LoadKeyboardLayoutW(L"00000804", KLF_ACTIVATE | KLF_SETFORPROCESS);
        std::printf("  LoadKeyboardLayout(00000804)：%p\n", static_cast<void *>(chinese));
        switched = attempt("换了布局以后 ActivateProfile",
                           profiles->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, kLangId, kClsid, kProfile, nullptr,
                                                     TF_IPPMF_FORPROCESS | TF_IPPMF_ENABLEPROFILE));
    }
    check(switched, "切到 WowType");
    focus();

    // 词库在后台载入：先按一个拼音试试，出来的还是字母就是还没载好，等一会儿再试（最多 60 秒）
    bool loaded = false;
    for (int attempt = 0; attempt < 30 && !loaded; ++attempt) {
        clear();
        focus();
        typeKeys("nihao ");
        pump(300);
        loaded = text() == L"你好";
        if (!loaded) {
            pump(2000);
        }
    }
    check(loaded, "nihao 空格 → 你好（词库载好、按键经过 TSF、上屏到输入框）", text());
    if (argc == 3 && (std::string(argv[1]) == "--peer-wait" || std::string(argv[1]) == "--peer-learn")) {
        const int n = MultiByteToWideChar(CP_ACP, 0, argv[2], -1, nullptr, 0);
        std::wstring dir(static_cast<std::size_t>(n), L'\0');
        MultiByteToWideChar(CP_ACP, 0, argv[2], -1, dir.data(), n);
        dir.resize(wcslen(dir.c_str()));
        const int failures = std::string(argv[1]) == "--peer-wait" ? peerWait(dir) : peerLearn(dir);
        DestroyWindow(g_window);
        pump(200);
        std::printf(failures ? "\n%d 项没过\n" : "\nwindows peer ok\n", failures);
        return failures;
    }

    // 打字途中有编辑区、有候选框，候选框在输入框附近
    clear();
    focus();
    typeKeys("shi");
    pump(300);
    HWND candidates = candidateWindow();
    const bool shown = candidates && IsWindowVisible(candidates);
    check(shown, "打字途中候选框出来了");
    if (shown) {
        RECT box{};
        RECT edit{};
        GetWindowRect(candidates, &box);
        GetWindowRect(g_edit, &edit);
        const bool nearby = box.top >= edit.top - 400 && box.top <= edit.bottom + 400 && box.left >= edit.left - 400 &&
                          box.left <= edit.right + 400;
        check(nearby, "候选框在输入框附近",
              std::to_wstring(box.left) + L"," + std::to_wstring(box.top) + L" / " + std::to_wstring(edit.left) + L"," +
                  std::to_wstring(edit.top));
    }
    shootWithCandidates(g_window, L"edit-shi");
    tap(VK_DOWN);
    pump(300);
    shootWithCandidates(g_window, L"edit-shi-expanded");
    tap(VK_UP);
    pump(200);
    tap('2');
    pump(300);
    check(text().size() == 1 && text() != L"s", "数字 2 选第二个候选", text());
    check(!candidateWindow() || !IsWindowVisible(candidateWindow()), "上屏以后候选框收起");

    clear();
    focus();
    typeKeys("nihao,");
    pump(300);
    check(text() == L"你好，", "打字途中按逗号：先上屏候选再上屏中文逗号", text());
    typeKeys(".");
    pump(200);
    check(text() == L"你好，。", "没在打字时句号是中文句号", text());

    clear();
    focus();
    typeKeys("nihao");
    tap(VK_RETURN);
    pump(300);
    check(text() == L"nihao", "回车上屏原始字母", text());

    clear();
    focus();
    typeKeys("nihh");
    tap(VK_BACK);
    typeKeys("ao ");
    pump(300);
    check(text() == L"你好", "退格删一个字母再接着打", text());

    clear();
    focus();
    typeKeys("nih");
    tap(VK_ESCAPE);
    pump(300);
    check(text().empty(), "Esc 清空不上屏", text());

    // 单按 Shift 切英文：字母原样进输入框；再按一下切回中文
    clear();
    focus();
    check(langBarText() == L"中", "任务栏的输入指示器：中", langBarText());
    shootTaskbar(L"taskbar-zh");
    // 没在打字时单按松开就切（#310），任务栏和光标下面的提示马上跟上；0.35 秒内的第二下才切回去（#253）
    tap(VK_LSHIFT);
    pump(100);
    check(langBarText() == L"英", "单按 Shift 马上切：任务栏的输入指示器是英", langBarText());
    pump(500);
    shootWithCandidates(g_window, L"edit-mode-hint");
    check(langBarText() == L"英", "单按 Shift 以后任务栏的输入指示器：英", langBarText());
    shootTaskbar(L"taskbar-en");
    typeKeys("abc ");
    pump(200);
    check(text() == L"abc ", "单按 Shift 切英文，字母原样上屏", text());
    tap(VK_LSHIFT);
    pump(300);
    typeKeys("nihao ");
    pump(300);
    check(text() == L"abc 你好", "再单按 Shift 切回中文", text());
    check(langBarText() == L"中", "切回来以后任务栏的输入指示器：中", langBarText());

    // 双击 Shift（JetBrains 的到处搜索，#253）：第一下切了英、第二下切回来，最后还是中，接着打的还是中文
    clear();
    focus();
    tap(VK_LSHIFT);
    tap(VK_LSHIFT);
    pump(600);
    check(langBarText() == L"中", "双击 Shift 不切：任务栏的输入指示器还是中", langBarText());
    typeKeys("nihao ");
    pump(300);
    check(text() == L"你好", "双击 Shift 以后还是中文", text());

    // 打到一半点了别处（失去焦点）：打的字母原样上屏（和 macOS 一样）
    clear();
    focus();
    typeKeys("ceshi");
    pump(200);
    SetFocus(nullptr);
    pump(400);
    SetFocus(g_edit);
    pump(200);
    check(text() == L"ceshi" || text() == L"测试", "打到一半失去焦点：不会留下编辑区", text());

    // RichEdit（TSF 原生的输入框，写字板、很多应用的富文本框用它）
    if (LoadLibraryW(L"msftedit.dll")) {
        HWND plain = g_edit;
        ShowWindow(plain, SW_HIDE);
        g_edit = CreateWindowExW(0, MSFTEDIT_CLASS, L"", WS_CHILD | WS_VISIBLE | WS_BORDER | ES_MULTILINE, 10, 10, 600, 160,
                                 g_window, nullptr, GetModuleHandleW(nullptr), nullptr);
        SendMessageW(g_edit, EM_SETEDITSTYLE, SES_USECTF, SES_USECTF);
        focus();
        clear();
        focus();
        typeKeys("nihao ");
        pump(400);
        check(text() == L"你好", "RichEdit 里 nihao 空格 → 你好", text());
        typeKeys("shi");
        pump(300);
        check(candidatesShown(), "RichEdit 里打字途中候选框出来了");
        shootWithCandidates(g_window, L"richedit-shi");
        tap(VK_RETURN);
        pump(300);
        check(text() == L"你好shi", "RichEdit 里回车上屏原始字母", text());
        DestroyWindow(g_edit);
        g_edit = plain;
    }

    DestroyWindow(g_window);
    pump(500);

    // Edge：另一个进程，用户的切法（Win + 空格）
    edgeTest();

    std::printf(g_failures ? "\n%d 项没过\n" : "\nwindows typing ok\n", g_failures);
    CoUninitialize();
    return g_failures;
}
