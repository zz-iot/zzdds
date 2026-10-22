/* Observe native loader membership without acquiring another module reference. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifdef _WIN32
#include <windows.h>
#include <stdlib.h>
int zidl_ts_module_loaded(const char *path) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!count) return -1;
    wchar_t *wide = (wchar_t *)malloc((size_t)count * sizeof(wchar_t));
    if (!wide) return -1;
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, count)) { free(wide); return -1; }
    HMODULE module = NULL;
    int loaded = GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, wide, &module) != 0;
    free(wide);
    return loaded;
}
#else
#include <dlfcn.h>
int zidl_ts_module_loaded(const char *path) {
    void *module = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
    if (!module) return 0;
    return dlclose(module) == 0 ? 1 : -1;
}
#endif
