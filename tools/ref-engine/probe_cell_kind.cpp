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
static item_t base_items[] = {
#include "items.inc"
};
static item_t items[64];
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
  *(volatile int*)loc(0x10361f3f8UL)=4;
  init(c);
  *(volatile int*)loc(0x10361f3f8UL)=4;

  unsigned n = sizeof(base_items)/sizeof(base_items[0]);
  memcpy(items, base_items, n*sizeof(item_t));

  static dictcfg_t dc; dc.items=items; dc.count=n; dc.user_dir="/tmp/wowtype-ref/userdata";
  int rc=cfg(&dc); printf("config=%d items=%u", rc, n); putchar(10);
  auto addcell = (int(*)(const char*,int,const void*))dlsym(H,"wxime_add_cell_dict");
  int ctype = (int)strtoul(argv[2],0,0);
  for(int i=3;i<argc;i++){ printf("addcell %s type %d -> %d", argv[i], ctype, addcell(argv[i], ctype, 0)); putchar(10); }

  auto inst  = (void*(*)())loc(0x101c453b4UL);
  auto deref = (void*(*)(void*))loc(0x101c430c4UL);
  g_real_get = (void*)loc(0x1017eccf8UL);
  void* res = *(void**)deref(inst());
  void* dmgr = *(void**)res;
  for (unsigned k=0;k<0x400;k++){
    sp_raw d; d.p=0; d.ctl=0;
    my_get(dmgr, (unsigned short)k, &d);
    if(!d.p) continue;
    void** vt = *(void***)d.p;
    const char* nm = *(const char**)((char*)((void**)vt[-1])+8);
    printf("kind %u %s", k, nm?nm:"?"); putchar(10);
    (void)0;
  }
  return 0;
}
