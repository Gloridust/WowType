#define _DARWIN_C_SOURCE 1
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <cstdint>

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

int main(int argc,char**argv){
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
  void* res = deref(rm);
  sp_raw dm = *(sp_raw*)res;
  printf("rm=%p res=%p dm=%p", rm, res, dm.p); putchar(10);
  void* dmgr = dm.p ? dm.p : res;
  { void* vt0 = *(void**)res; Dl_info d0; memset(&d0,0,sizeof d0); dladdr(vt0,&d0);
    printf("res[0]=%p sym=%s", vt0, d0.dli_sname?d0.dli_sname:"?"); putchar(10); }
  if(dm.p){ void* vt = *(void**)dm.p; void* ti = ((void**)vt)[-1];
    const char* nm = *(const char**)((char*)ti+8);
    printf("dm.p type=%s", nm?nm:"?"); putchar(10); }
  return 0;
  void* found = 0;
  for (unsigned k=0;k<0x300;k++){
    sp_raw d; d.p=0; d.ctl=0;
    my_get(dmgr, (unsigned short)k, &d);
    if(!d.p) continue;
    void** vt = *(void***)d.p;
    void* ti = vt[-1];
    const char* nm = *(const char**)((char*)ti+8);
    printf("kind %u -> %s", k, nm?nm:"?"); putchar(10);
    if(nm && strstr(nm,"AssociateWb")) found=d.p;
  }
  printf("associate_wb found=%p", found); putchar(10);
  return 0;
}
