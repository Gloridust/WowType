#define _DARWIN_C_SOURCE 1
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <csignal>
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
extern "C" void* g_real_get = nullptr;
extern "C" void my_get(void* self, unsigned short kind, sp_raw* out);
asm(
"  .globl _my_get\n"
"  _my_get:\n"
"    adrp x9, _g_real_get@PAGE\n"
"    add  x9, x9, _g_real_get@PAGEOFF\n"
"    ldr  x9, [x9]\n"
"    mov  x8, x2\n"
"    br   x9\n"
);
static void on_segv(int, siginfo_t*, void*){ const char m[]="CRASH\n"; write(2,m,sizeof m-1); _exit(7); }

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
  g_real_get = (void*)loc(0x1017eccf8UL);
  void* rm = inst();
  void* resptr = deref(rm);
  void* res = *(void**)resptr;
  void* dmgr = *(void**)((char*)res + 0x0);
  printf("dmgr=%p", dmgr); putchar(10);
  int hits=0;
  for (unsigned k=0;k<0x400;k++){
    sp_raw d; d.p=0; d.ctl=0;
    my_get(dmgr, (unsigned short)k, &d);
    if(!d.p) continue;
    void** vt = *(void***)d.p;
    void* ti = vt[-1];
    const char* nm = *(const char**)((char*)ti+8);
    printf("kind %u -> %s", k, nm?nm:"?"); putchar(10);
    hits++;
  }
  printf("total %d", hits); putchar(10);
  return 0;
}
