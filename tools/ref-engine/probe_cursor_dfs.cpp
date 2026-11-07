#define _DARWIN_C_SOURCE 1
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <csignal>
#include <string>
#include <unistd.h>

struct sp_raw { void* p; void* ctl; };
typedef struct { void* fd; const char* path; uint32_t id; } item_t;
typedef struct { item_t* items; uint32_t count; const char* user_dir; } dictcfg_t;
static item_t items[] = {
#include "items.inc"
};
static void my_log(int l,const char*m,int n){(void)l;(void)m;(void)n;}
static unsigned long g_base;
static unsigned long loc(unsigned long v){ return g_base + (v - 0x100000000UL); }
extern "C" void* g_get2 = nullptr;
extern "C" void* g_dm_get = nullptr;
extern "C" void call2(void* a, void* b);
extern "C" void dm_get(void* dm, unsigned short k, sp_raw* out);
asm(
"  .globl _call2\n"
"  _call2:\n"
"    adrp x9, _g_get2@PAGE\n"
"    add  x9, x9, _g_get2@PAGEOFF\n"
"    ldr  x9, [x9]\n"
"    mov  x8, x1\n"
"    br   x9\n"
"  .globl _dm_get\n"
"  _dm_get:\n"
"    adrp x9, _g_dm_get@PAGE\n"
"    add  x9, x9, _g_dm_get@PAGEOFF\n"
"    ldr  x9, [x9]\n"
"    mov  x8, x2\n"
"    br   x9\n"
);
static void on_segv(int, siginfo_t*, void*){ const char m[]="CRASH\n"; write(2,m,sizeof m-1); _exit(7); }

static std::string read_str(const void* s){
  const unsigned char* b=(const unsigned char*)s;
  unsigned long long cap=*(const unsigned long long*)(b+16);
  unsigned long long sz=*(const unsigned long long*)(b+8);
  unsigned long long dp=*(const unsigned long long*)(b);
  // 长串：data@0 / size@8 / cap@16（LSB 标记）；做个合理性检查，避免把短串误判成长串
  if((cap & 1ULL) && sz < 4096 && dp > 0x10000ULL && dp < 0x800000000000ULL){
    return std::string((const char*)dp, (size_t)sz);
  }
  unsigned char last=b[23];
  size_t n=last & 0x7f;
  if(n>22) n=22;
  return std::string((const char*)b,n);
}
typedef bool (*movefn)(void*, int);
typedef unsigned long long (*freqfn)(const void*);
typedef bool (*leaffn)(const void*);
static movefn mv; static freqfn fq; static leaffn lf;
static long g_labels=0, g_leaves=0, max_nodes=200000, nodes=0, printed=0;

static void walk(unsigned char* cur, int depth){
  if(++nodes > max_nodes) return;
  if(lf(cur)){
    unsigned long long f=fq(cur);
    if(f & (1ULL<<32)){
      g_leaves++;
      if(printed < 40){
        std::string word=read_str(cur+0x2c);
        std::string syl=read_str(cur+0x44);
        printf("%s\\t%s\\t%u", word.c_str(), syl.c_str(), (unsigned)(f & 0xffffffffu));
        putchar(10); printed++;
      }
    }
  }
  if(depth >= 6) return;
  for(long i=0;i<g_labels;i++){
    unsigned char ch[0x60];
    memcpy(ch,cur,sizeof ch);
    if(!mv(ch,i)) continue;
    walk(ch, depth+1);
    if(nodes>max_nodes) return;
  }
}

int main(int argc,char**argv){
  struct sigaction sa; memset(&sa,0,sizeof sa); sa.sa_sigaction=on_segv; sa.sa_flags=SA_SIGINFO;
  sigaction(SIGSEGV,&sa,0); sigaction(SIGBUS,&sa,0);
  void* H = dlopen(argv[1], RTLD_NOW|RTLD_LOCAL);
  if(!H){ puts("dlopen fail"); return 1; }
  void* vs = dlsym(H, "wxime_get_version");
  Dl_info di; memset(&di,0,sizeof di); dladdr(vs,&di); g_base=(unsigned long)di.dli_fbase;
  auto init = (int(*)(const void*))dlsym(H,"wxime_initialize");
  auto cfg  = (int(*)(void*))dlsym(H,"wxime_config_dict");
  static uint8_t c[512];
  *(const char**)(c+0x18)="/Library/Input Methods/WeType.app/Contents/Resources";
  *(void**)(c+0)=(void*)my_log;
  init(c);
  static dictcfg_t dc; dc.items=items; dc.count=sizeof(items)/sizeof(items[0]); dc.user_dir="/tmp/wowtype-ref/userdata";
  cfg(&dc);

  auto inst  = (void*(*)())loc(0x101c453b4UL);
  auto deref = (void*(*)(void*))loc(0x101c430c4UL);
  g_dm_get = (void*)loc(0x1017eccf8UL);
  g_get2   = (void*)loc(0x1019286d4UL);
  void* res = *(void**)deref(inst());
  void* dmgr = *(void**)res;
  unsigned kind = (unsigned)strtoul(argv[2],0,0);
  sp_raw d; d.p=0; d.ctl=0;
  dm_get(dmgr, (unsigned short)kind, &d);
  printf("dict %u -> %p", kind, d.p); putchar(10);
  if(!d.p) return 0;

  g_labels = argc>3 ? atol(argv[3]) : 600;
  printf("labels=%ld", g_labels); putchar(10);

  unsigned char root[0x60]; memset(root,0,sizeof root);
  call2(d.p, root);
  mv=(movefn)loc(0x101928708UL);
  fq=(freqfn)loc(0x101928814UL);
  lf=(leaffn)loc(0x101928830UL);
  walk(root,0);
  printf("leaves=%ld nodes=%ld", g_leaves, nodes); putchar(10);
  return 0;
}
