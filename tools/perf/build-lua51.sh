#!/bin/sh
# build-lua51.sh <outdir>: builds stock Lua 5.1.5 (what WoW runs; not LuaJIT) plus os.hires from
# hires.c into <outdir>/lua5.1 (lua5.1.exe on Windows). Needs gcc and curl. Scratch goes to
# <outdir>/src; nothing is written outside <outdir>.
set -e
out=${1:?usage: build-lua51.sh <outdir>}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out/src"
cd "$out/src"
if [ ! -d lua-5.1.5 ]; then
    curl -sSL -o lua-5.1.5.tar.gz https://www.lua.org/ftp/lua-5.1.5.tar.gz
    sum=$(sha256sum lua-5.1.5.tar.gz | cut -d' ' -f1)
    [ "$sum" = 2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333 ] || { echo "bad checksum $sum"; exit 1; }
    tar xzf lua-5.1.5.tar.gz
fi
cd lua-5.1.5/src
cp "$here/hires.c" hires.c
# Call luaopen_hires right after the standard libraries open.
sed -i 's|luaL_openlibs(L);  /\* open libraries \*/|luaL_openlibs(L); luaopen_hires(L);|' lua.c
grep -q luaopen_hires lua.c
sed -i '0,/#include "lualib.h"/s//#include "lualib.h"\nextern int luaopen_hires(lua_State *L);/' lua.c
case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*) flags=""; libs="-lm"; exe=lua5.1.exe ;;
    *) flags="-DLUA_USE_POSIX -DLUA_USE_DLOPEN"; libs="-lm -ldl"; exe=lua5.1 ;;
esac
core="lapi lcode ldebug ldo ldump lfunc lgc llex lmem lobject lopcodes lparser lstate lstring ltable ltm lundump lvm lzio"
lib="lauxlib lbaselib ldblib liolib lmathlib loslib ltablib lstrlib loadlib linit"
objs=""
for f in $core $lib lua hires; do
    gcc -O2 $flags -c $f.c -o $f.o 2>/dev/null
    objs="$objs $f.o"
done
gcc -o "$out/$exe" $objs $libs
"$out/$exe" -e 'assert(_VERSION == "Lua 5.1" and os.hires() > 0); print(_VERSION, "os.hires ok")'
