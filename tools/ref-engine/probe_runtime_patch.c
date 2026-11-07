#define _DARWIN_C_SOURCE 1
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#define _XOPEN_SOURCE 700
#include <signal.h>
#include <ucontext.h>

typedef struct { void* fd; const char* path; uint32_t id; } item_t;
typedef struct { item_t* items; uint32_t count; const char* user_dir; } dictcfg_t;
static item_t items[] = {
#include "items.inc"
};
static void my_log(int l,const char*m,int n){(void)l;(void)m;(void)n;}

static unsigned long g_base;
static unsigned long loc(unsigned long vmaddr){ return g_base + (vmaddr - 0x100000000UL); }

static void set_verbosity(void){
  *(volatile int*)loc(0x10361f3f8UL) = 4;
}

static void on_segv(int s, siginfo_t* si, void* uc){
  void* pc=(void*)((ucontext_t*)uc)->uc_mcontext->__ss.__pc;
  Dl_info di; memset(&di,0,sizeof di); dladdr(pc,&di);
  fprintf(stderr,"SEGV addr=%p off=+0x%lx sym=%s", si->si_addr,
    di.dli_saddr?(unsigned long)((char*)pc-(char*)di.dli_saddr):0, di.dli_sname?di.dli_sname:"?");
  putc(10,stderr); _exit(9);
}

/* 用 mov w0,#0 + 3*nop 覆盖 4 条指令 */
static int patch_insn(unsigned long vmaddr, const uint32_t* words, int n){
  unsigned long addr = loc(vmaddr);
  unsigned long page = addr & ~0xFFFUL;
  unsigned long size = 0x4000;
  kern_return_t kr = mach_vm_protect(mach_task_self(), (mach_vm_address_t)page,
      (mach_vm_size_t)size, FALSE, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
  if(kr != KERN_SUCCESS){ fprintf(stderr, "mach_vm_protect failed: %d", kr); putc(10,stderr); return -1; }
  memcpy((void*)addr, words, n*4);
  sys_icache_invalidate((void*)addr, n*4);
  __builtin___clear_cache((char*)addr,(char*)addr+n*4);
  kr = mach_vm_protect(mach_task_self(), (mach_vm_address_t)page,
      (mach_vm_size_t)size, FALSE, VM_PROT_READ|VM_PROT_EXECUTE);
  if(kr != KERN_SUCCESS){ fprintf(stderr, "restore prot failed: %d", kr); putc(10,stderr); return -1; }
  return 0;
}

int main(int argc,char**argv){
  struct sigaction sa; memset(&sa,0,sizeof sa); sa.sa_sigaction=on_segv; sa.sa_flags=SA_SIGINFO;
  sigaction(SIGSEGV,&sa,0); sigaction(SIGBUS,&sa,0);

  void*H=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
  if(!H){puts("dlopen fail");return 1;}
  void* vsym=dlsym(H,"wxime_get_version");
  Dl_info di; memset(&di,0,sizeof di); dladdr(vsym,&di); g_base=(unsigned long)di.dli_fbase;
  printf("base=%#lx", g_base); putchar(10);

  int(*init)(const void*)=dlsym(H,"wxime_initialize");
  int(*cfg)(void*)=dlsym(H,"wxime_config_dict");
  unsigned long long(*create)(const void*)=dlsym(H,"wxime_create_session");

  static uint8_t c[512];
  *(const char**)(c+0x18)="/Library/Input Methods/WeType.app/Contents/Resources";
  *(void**)(c+0)=(void*)my_log;
  set_verbosity();
  printf("init=%d", init(c)); putchar(10);
  dictcfg_t dc; dc.items=items; dc.count=sizeof(items)/sizeof(items[0]); dc.user_dir="/tmp/wowtype-ref/userdata";
  printf("config_dict=%d", cfg(&dc)); putchar(10);

  /* 0x10173c7cc: ldr x0,[x19,#0x30]; ldr x8,[x0]; ldr x8,[x8,#0x98]; blr x8
     -> mov w0,#0; nop; nop; nop  */
  const uint32_t stub[4] = {0x52800000u, 0xD503201Fu, 0xD503201Fu, 0xD503201Fu};
  if(patch_insn(0x10173c7ccUL, stub, 4)!=0){ puts("patch failed"); return 2; }
  puts("patched sub-dict null branch");

  static uint8_t sc[512];
  unsigned long long sid=create(sc);
  printf("create sid=%llu", sid); putchar(10);
  return 0;
}
