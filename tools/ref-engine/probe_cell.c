#define _DARWIN_C_SOURCE 1
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
typedef struct { void* fd; const char* path; uint32_t id; } item_t;
typedef struct { item_t* items; uint32_t count; const char* user_dir; } dictcfg_t;
static item_t items[] = {
#include "items.inc"
};
static void my_log(int l,const char*m,int n){(void)l;(void)m;(void)n;}
int main(int argc,char**argv){
  void*H=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
  if(!H){puts("dlopen fail");return 1;}
  int(*init)(const void*)=dlsym(H,"wxime_initialize");
  int(*cfg)(void*)=dlsym(H,"wxime_config_dict");
  int(*addcell)(const char*,int,const void*)=dlsym(H,"wxime_add_cell_dict");
  static uint8_t c[512];
  *(const char**)(c+0x18)="/Library/Input Methods/WeType.app/Contents/Resources";
  *(void**)(c+0)=(void*)my_log;
  init(c);
  dictcfg_t dc; dc.items=items; dc.count=sizeof(items)/sizeof(items[0]); dc.user_dir="/tmp/wowtype-ref/userdata";
  cfg(&dc);
  int slot=atoi(argv[3]);
  int rc=addcell(argv[2], slot, 0);
  printf("SLOT %d rc=%d", slot, rc); putchar(10);
  return 0;
}
