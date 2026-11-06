#define _DARWIN_C_SOURCE 1
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
static void my_log(int l,const char*m,int n){(void)l;(void)m;(void)n;}
static void set_verbosity(void* H){
  void* sym = dlsym(H, "wxime_get_version");
  Dl_info di; memset(&di,0,sizeof di);
  if(!dladdr(sym,&di) || !di.dli_fbase) return;
  unsigned long base=(unsigned long)di.dli_fbase;
  *(volatile int*)(base + (0x10361f3f8UL - 0x100000000UL)) = 9;
}
int main(int argc,char**argv){
  void*H=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
  if(!H){puts("dlopen fail");return 1;}
  int(*init)(const void*)=dlsym(H,"wxime_initialize");
  int(*addcell)(const char*,int,const void*)=dlsym(H,"wxime_add_cell_dict");
  static uint8_t c[512];
  *(const char**)(c+0x18)="/Library/Input Methods/WeType.app/Contents/Resources";
  *(void**)(c+0)=(void*)my_log;
  set_verbosity(H);
  int ri=init(c); printf("init=%d", ri); putchar(10);
  const char* path="/Library/Input Methods/WeType.app/Contents/Resources/imeData.bundle/cell_dict.sc.zh";
  for(int t=0;t<=20;t++){
    set_verbosity(H);
    int rc=addcell(path,t,0);
    printf("TYPE %d -> rc=%d", t, rc); putchar(10);
  }
  return 0;
}
