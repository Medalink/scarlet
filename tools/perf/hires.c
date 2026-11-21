/* hires.c: os.hires(), seconds from the OS's monotonic high resolution clock, for the perf harness.
 * Stock Lua 5.1 only has os.clock, which is 1 ms on Windows. The VM is untouched; build-lua51.sh
 * links this into the stock interpreter's host program. */
#include "lua.h"
#include "lauxlib.h"

#ifdef _WIN32
#include <windows.h>

static int hires(lua_State *L) {
    static LARGE_INTEGER freq;
    LARGE_INTEGER now;
    if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&now);
    lua_pushnumber(L, (lua_Number)now.QuadPart / (lua_Number)freq.QuadPart);
    return 1;
}
#else
#include <time.h>

static int hires(lua_State *L) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    lua_pushnumber(L, (lua_Number)t.tv_sec + (lua_Number)t.tv_nsec / 1e9);
    return 1;
}
#endif

int luaopen_hires(lua_State *L) {
    lua_getglobal(L, "os");
    lua_pushcfunction(L, hires);
    lua_setfield(L, -2, "hires");
    lua_pop(L, 1);
    return 0;
}
