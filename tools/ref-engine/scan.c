#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

static void my_log(int level, const char* msg, int len){
    (void)level; (void)msg; (void)len;
}

int main(int argc, char** argv){
    long off = strtol(argv[2], 0, 0);
    static uint8_t cfg[512];
    memset(cfg, 0, sizeof cfg);
    *(const char**)(cfg+0x18) = "/Library/Input Methods/WeType.app/Contents/Resources";
    *(void**)(cfg+off) = (void*)my_log;
    void* H = dlopen(argv[1], RTLD_NOW|RTLD_LOCAL);
    if(!H){ printf("RESULT dlopen_fail\n"); return 3; }
    int (*init)(const void*) = (int(*)(const void*))dlsym(H, "wxime_initialize");
    if(!init){ printf("RESULT no_sym\n"); return 3; }
    init(cfg);
    printf("RESULT ok_off=%ld\n", off);
    return 0;
}
