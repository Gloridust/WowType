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

static std::string read_str(void* s){
  unsigned char* b=(unsigned char*)s;
  unsigned char last=b[23];
  if(last & 0x80){ size_t n=last & 0x7f; if(n>22)n=22; return std::string((char*)b,n); }
  char* p=*(char**)(b+16); size_t n=*(size_t*)(b+8);
  if(!p) return std::string();
  return std::string(p,n);
}

typedef bool (*tryfn)(const void*, int);
typedef bool (*movefn)(void*, int);
typedef unsigned long long (*freqfn)(const void*);
typedef bool (*leaffn)(const void*);

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
  static dictcfg_t dc; dc.items=items; dc.count=sizeof(items)/sizeof(items[0]); dc.user_dir="/tmp/oracle/userdata";
  cfg(&dc);

  auto inst  = (void*(*)())loc(0x101c453b4UL);
  auto deref = (void*(*)(void*))loc(0x101c430c4UL);
  g_dm_get = (void*)loc(0x1017eccf8UL);
  g_get2   = (void*)loc(0x1019286d4UL);
  void* res = *(void**)deref(inst());
  void* dmgr = *(void**)res;
  unsigned kind = (unsigned)strtoul(argv[2],0,0);
  int max_label = (int)strtoul(argv[3],0,0);
  sp_raw d; d.p=0; d.ctl=0;
  dm_get(dmgr, (unsigned short)kind, &d);
  printf("dict %u -> %p", kind, d.p); putchar(10);
  if(!d.p) return 0;

  unsigned char root[0x80]; memset(root,0,sizeof root);
  call2(d.p, root);
  void* syl=(void*)(root+0x44);
  printf("root syllable='%s' leaf=%d", read_str(syl).c_str(), (int)((leaffn)loc(0x101928830UL))(root)); putchar(10);

  movefn mv=(movefn)loc(0x101928708UL);
  freqfn fq=(freqfn)loc(0x101928814UL);
  int hits=0;
  for(int i=0;i<max_label;i++){
    unsigned char ch[0x80]; memcpy(ch,root,sizeof ch);
    if(!mv(ch,i)) continue;
    std::string s=read_str((void*)(ch+0x44));
    unsigned long long f=fq(ch);
    char* lbase=*(char**)((char*)loc(0x10367a768UL));
    char* lp=0; unsigned long ln=0;
    if(lbase){
      lp=*(char**)(lbase + (long)i*16);
      ln=*(unsigned long*)(lbase + (long)i*16 + 8);
    }
    printf("label %d -> path='%s' labelstr='%.*s' freq=%u leaf=%d", i, s.c_str(), (int)(ln>32?32:ln), lp?lp:"", (unsigned)(f & 0xffffffffu), (int)((leaffn)loc(0x101928830UL))(ch)); putchar(10);
    if(++hits>=12) break;
  }
  printf("hits=%d", hits); putchar(10);
  return 0;
}
