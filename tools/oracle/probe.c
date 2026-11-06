#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char** argv){
    void* h = dlopen(argv[1], RTLD_NOW|RTLD_LOCAL);
    if(!h){ printf("dlopen FAILED: %s\n", dlerror()); return 1; }
    printf("dlopen OK\n");
    const char* (*getver)(void) = (const char*(*)(void))dlsym(h, "wxime_get_version");
    printf("wxime_get_version = %p\n", (void*)getver);
    if(getver){ printf("version: %s\n", getver()); }
    return 0;
}
