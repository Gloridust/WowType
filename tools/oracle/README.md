# WeType 引擎 Oracle（逆向用）

把 WeType 的主二进制改造成可 dlopen 的 bundle，直接调用它导出的 `wxime_*` C API，
用来导出词库/候选/分数，也作为蒸馏时的 teacher。

## 1. 制作可加载的 bundle

```sh
lipo -thin arm64 "/Library/Input Methods/WeType.app/Contents/MacOS/WeType" -output /tmp/WeType_arm64
cp /tmp/WeType_arm64 /tmp/WeType_bundle
python3 - <<'EOF'
import struct
p='/tmp/WeType_bundle'
d=bytearray(open(p,'rb').read())
struct.pack_into('<I', d, 12, 8)   # filetype: MH_EXECUTE(2) -> MH_BUNDLE(8)
open(p,'wb').write(d)
EOF
codesign -s - -f /tmp/WeType_bundle
```

运行需要一个假的 .app 结构，让引擎能按 `../Resources` 找到模块：

```sh
mkdir -p /tmp/WeTypeFake.app/Contents/MacOS
cp /tmp/WeType_bundle /tmp/WeTypeFake.app/Contents/MacOS/libwxime.dylib
ln -s '/Library/Input Methods/WeType.app/Contents/Resources'  /tmp/WeTypeFake.app/Contents/Resources
ln -s '/Library/Input Methods/WeType.app/Contents/Frameworks' /tmp/WeTypeFake.app/Contents/Frameworks
export DYLD_FRAMEWORK_PATH='/Library/Input Methods/WeType.app/Contents/Frameworks'
export DYLD_LIBRARY_PATH='/Library/Input Methods/WeType.app/Contents/Frameworks'
```

验证：

```
dlopen OK
wxime_get_version -> 0.45.0.weekly_release/2026.09.23.b2f7520b2
```

## 2. 已还原的结构体布局

```c
// _wxime_config （wxime_initialize 的入参，≥0xc0 字节）
char*    resource_dir;        // +0x18  会做 fs::create_directories 校验
bool     safe_mode;           // +0x29
uint32_t device_pref;         // +0x38
bool     test_mode;           // +0x3c
void*    logger;              // +0x00  ← 置非空即可跳过 "logger_ != nullptr"
void*    report_cb;           // +0x88  SetReportExceptionCallBack
float    score_cpu;           // +0xb8
float    score_gpu;           // +0xbc

// _wxime_dict_config
struct item { void* fd_desc; const char* path; uint32_t id; };  // stride 0x18
item*    items;               // +0x00
uint32_t count;               // +0x08   （日志写的是 total size，实际是条数）
char*    user_dict_dir;       // +0x10

// _wxime_session_config = 0x138 字节
//   +0x98 : _wxime_cloud_resource_display_config
//   +0xc0 : _wxime_app_env

// C API
void     wxime_process_input(uint64_t sid, const char* s, uint32_t len,
                             const void* aux, uint32_t aux_len);
int      wxime_config_dict(_wxime_dict_config*);   // 需先 initialize
uint64_t wxime_create_session(const _wxime_session_config*); // 返回 sid
```

`item.id` 取 `imeData.bundle/index.json` 里的 `type` 字段
（bwcnmac=65536, bwcnenmac=65537, bwcnmacv8=65581, lmcnmac=131072,
hpmac_base=262144, swbd*=524291）。

## 3. 当前状态

- `wxime_initialize` 成功
- `wxime_config_dict` 返回 1（28 个词典全部装载）
- `wxime_create_session` 在 `ZhMostLikelySequelSearcherV2` 构造 +0x330 处崩：
  `ldr x0,[x19,#0x30]` 取到 null，随即 `ldr x8,[x0]` 段错误。
  即该 searcher 依赖的某个 dict / 关联模型没装上。

## 4. 下一步

1. 在 `SessionCreator::operator()` 里找构造 `MostLikelySequel::InitContext` 的那段，
   看它从 ResourceMgr 取的是哪个 dict 类型 → 补进 items（或改用 `wxime_add_cell_dict`）。
2. 打通后：`process_input` + `wxime_candidate_next` 批量 dump 候选与分数。
3. 用这份数据产出 `lexicon.tsv` 与排序蒸馏集。
