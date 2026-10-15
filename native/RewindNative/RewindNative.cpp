// RewindNative - the small native half of Rewind Together.
//
// WHY THIS EXISTS
//
// The mod is Lua under UE4SS, and stays Lua. This DLL does the few things the
// Lua bridge cannot do safely or cheaply, measured in 1.7.0:
//
//   * Make the game's Blueprints treat a GUEST as "player 0" for the length of
//     one replayed action. Every interaction Blueprint in this single-player
//     game finds "the player" with GameplayStatics GetPlayerController(0) /
//     GetPlayerCharacter(0); on a listen server that is always the host. A Lua
//     hook cannot replace a native function's return value, and these are
//     called by Blueprints every frame - Lua on that path would be expensive.
//
// HOW IT GETS IN
//
// UE4SS's private C++ SDK dependency is not available to us, so this is NOT a
// UE4SS C++ mod. The Lua mod loads it with package.loadlib (enabled in this
// UE4SS build), and each exported function is an ordinary lua_CFunction. To
// read arguments and push results it uses the C++ Lua wrapper UE4SS itself
// exports (RC::LuaMadeSimple::Lua): constructed around the lua_State it is
// handed, never owning it - its destructor deliberately does not close the
// state (LuaMadeSimple.cpp at UE4SS commit 0196ef29, the build installed).
//
// HOW THE REDIRECT WORKS
//
// A native UFunction stores its implementation as a plain pointer,
// UFunction::Func. The Blueprint VM and UE4SS's ProcessEvent both call through
// it. For each function Lua asks us to wrap, we swap that pointer for a thunk
// that calls the original and then, ONLY while a redirect window is open,
// replaces a returned pointer found in the from->to table. Outside the window
// the thunk is a call and a branch.
//
// Everything here runs on the game thread: Lua calls in from the mod's tick,
// and Blueprints call the thunks from the game thread. Every raw memory read of
// an address Lua handed us is SEH-guarded.

#include <windows.h>
#include <cstdint>
#include <cstring>

static const int kVersion = 1;

// ---------------------------------------------------------------------------
// UE4SS's exported Lua wrapper
// ---------------------------------------------------------------------------

struct LuaApi
{
    void    (*ctor)(void* self, void* L)            = nullptr;
    void    (*dtor)(void* self)                     = nullptr;
    int64_t (*get_integer)(const void* self, int i) = nullptr;
    bool    (*is_integer)(const void* self, int i)  = nullptr;
    int     (*get_stack_size)(const void* self)     = nullptr;
    void    (*set_integer)(const void* self, int64_t v) = nullptr;
    void    (*set_bool)(const void* self, bool v)   = nullptr;
    void    (*set_string)(const void* self, const char* s, size_t n) = nullptr;
    void    (*set_nil)(const void* self)            = nullptr;
    bool ok = false;
};
static LuaApi g_lua;

template <typename T>
static bool resolve(HMODULE m, const char* name, T& out)
{
    out = reinterpret_cast<T>(GetProcAddress(m, name));
    return out != nullptr;
}

static bool load_lua_api()
{
    if (g_lua.ok) return true;
    HMODULE m = GetModuleHandleW(L"UE4SS.dll");
    if (!m) return false;
    bool all = true;
    all &= resolve(m, "??0Lua@LuaMadeSimple@RC@@QEAA@PEAUlua_State@@@Z", g_lua.ctor);
    all &= resolve(m, "??1Lua@LuaMadeSimple@RC@@QEAA@XZ", g_lua.dtor);
    all &= resolve(m, "?get_integer@Lua@LuaMadeSimple@RC@@QEBA_JH@Z", g_lua.get_integer);
    all &= resolve(m, "?is_integer@Lua@LuaMadeSimple@RC@@QEBA_NH@Z", g_lua.is_integer);
    all &= resolve(m, "?get_stack_size@Lua@LuaMadeSimple@RC@@QEBAHXZ", g_lua.get_stack_size);
    all &= resolve(m, "?set_integer@Lua@LuaMadeSimple@RC@@QEBAX_J@Z", g_lua.set_integer);
    all &= resolve(m, "?set_bool@Lua@LuaMadeSimple@RC@@QEBAX_N@Z", g_lua.set_bool);
    all &= resolve(m, "?set_string@Lua@LuaMadeSimple@RC@@QEBAXPEBD_K@Z", g_lua.set_string);
    all &= resolve(m, "?set_nil@Lua@LuaMadeSimple@RC@@QEBAXXZ", g_lua.set_nil);
    g_lua.ok = all;
    return all;
}

// A RC::LuaMadeSimple::Lua living on our stack. Its real size is well under
// 128 bytes (a lua_State*, a std::vector, a string_view, an int and a
// registry holding a reference); 512 leaves room for a different STL layout.
class Lua
{
    alignas(16) unsigned char m_storage[512];

  public:
    explicit Lua(void* L) { std::memset(m_storage, 0, sizeof(m_storage)); g_lua.ctor(m_storage, L); }
    ~Lua() { g_lua.dtor(m_storage); }
    Lua(const Lua&) = delete;
    Lua& operator=(const Lua&) = delete;

    int  args() const               { return g_lua.get_stack_size(m_storage); }
    bool is_int() const             { return g_lua.is_integer(m_storage, 1); }
    // Reads stack index 1 and removes it, so successive calls walk the args.
    int64_t pop_int() const         { return g_lua.get_integer(m_storage, 1); }
    void push(int64_t v) const      { g_lua.set_integer(m_storage, v); }
    void push(bool v) const         { g_lua.set_bool(m_storage, v); }
    void push(const char* s) const  { g_lua.set_string(m_storage, s, std::strlen(s)); }
    void push_nil() const           { g_lua.set_nil(m_storage); }
};

// ---------------------------------------------------------------------------
// Memory helpers
// ---------------------------------------------------------------------------

static bool safe_read_ptr(uintptr_t addr, uintptr_t& out)
{
    __try
    {
        out = *reinterpret_cast<const volatile uintptr_t*>(addr);
        return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

struct Range { uintptr_t lo = 0, hi = 0; bool has(uintptr_t p) const { return p >= lo && p < hi; } };

// The game executable's .text section: where every engine exec thunk lives.
static Range exe_text()
{
    static Range r;
    if (r.lo) return r;
    auto base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    auto dos  = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto nt   = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    auto sec  = IMAGE_FIRST_SECTION(nt);
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++sec)
    {
        if (std::memcmp(sec->Name, ".text", 5) == 0)
        {
            r.lo = base + sec->VirtualAddress;
            r.hi = r.lo + sec->Misc.VirtualSize;
            break;
        }
    }
    return r;
}

static bool is_executable(uintptr_t p)
{
    MEMORY_BASIC_INFORMATION mbi{};
    if (!VirtualQuery(reinterpret_cast<void*>(p), &mbi, sizeof(mbi))) return false;
    const DWORD exec = PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    return mbi.State == MEM_COMMIT && (mbi.Protect & exec) != 0;
}

// ---------------------------------------------------------------------------
// Return-value redirect
// ---------------------------------------------------------------------------

using NativeFn = void (*)(void* context, void* stack, void* result);

static const int kSlots = 16;
static const int kPairs = 8;

struct Slot
{
    uintptr_t ufunction = 0;
    NativeFn  original  = nullptr;
    NativeFn  thunk     = nullptr;
};
static Slot      g_slots[kSlots];
static int       g_funcOffset = 0;      // offset of UFunction::Func, found once
static bool      g_active     = false;
static int       g_pairCount  = 0;
static uintptr_t g_from[kPairs];
static uintptr_t g_to[kPairs];
static int64_t   g_calls      = 0;      // thunk calls while a window was open
static int64_t   g_swaps      = 0;      // results replaced in the current window
static int64_t   g_swapsTotal = 0;

template <int I>
static void thunk(void* context, void* stack, void* result)
{
    g_slots[I].original(context, stack, result);
    if (!g_active || !result) return;
    ++g_calls;
    auto out = static_cast<uintptr_t*>(result);
    const uintptr_t got = *out;
    for (int k = 0; k < g_pairCount; ++k)
    {
        if (got == g_from[k])
        {
            *out = g_to[k];
            ++g_swaps;
            return;
        }
    }
}

template <int... I> struct Seq {};
template <int... I>
static void fill_thunks(Seq<I...>)
{
    NativeFn all[] = { &thunk<I>... };
    for (int i = 0; i < kSlots; ++i) g_slots[i].thunk = all[i];
}

static bool is_our_thunk(uintptr_t p)
{
    for (auto& s : g_slots)
        if (reinterpret_cast<uintptr_t>(s.thunk) == p) return true;
    return false;
}

// Find UFunction::Func the first time: the first pointer after the UStruct
// header that points into the game's .text is the exec thunk (everything else
// in that range is heap data). UObject's vtable is in .rdata, not .text.
static int find_func_offset(uintptr_t ufn)
{
    const Range text = exe_text();
    for (int off = 0x60; off <= 0x180; off += 8)
    {
        uintptr_t v = 0;
        if (!safe_read_ptr(ufn + off, v)) return -1;
        if (text.has(v)) return off;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Exports (each is a lua_CFunction)
// ---------------------------------------------------------------------------

#define RT_EXPORT extern "C" __declspec(dllexport)

// rt_version() -> integer version, string
RT_EXPORT int rt_version(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    lua.push(static_cast<int64_t>(kVersion));
    lua.push("RewindNative 1 (player-0 redirect)");
    return 2;
}

// rt_hook_return(ufunctionAddress) -> Func offset (>0) on success, or
//   -1 unreadable address, -2 no exec thunk found, -3 out of slots,
//   -4 the thunk is not in executable memory
RT_EXPORT int rt_hook_return(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    if (lua.args() < 1 || !lua.is_int()) { lua.push(static_cast<int64_t>(-1)); return 1; }
    const auto ufn = static_cast<uintptr_t>(lua.pop_int());

    for (auto& s : g_slots)
        if (s.ufunction == ufn) { lua.push(static_cast<int64_t>(g_funcOffset)); return 1; }

    if (!g_funcOffset)
    {
        const int off = find_func_offset(ufn);
        if (off < 0) { lua.push(static_cast<int64_t>(-1)); return 1; }
        if (off == 0) { lua.push(static_cast<int64_t>(-2)); return 1; }
        g_funcOffset = off;
    }

    uintptr_t current = 0;
    if (!safe_read_ptr(ufn + g_funcOffset, current)) { lua.push(static_cast<int64_t>(-1)); return 1; }
    if (is_our_thunk(current)) { lua.push(static_cast<int64_t>(g_funcOffset)); return 1; }
    // Something else (UE4SS's own hook trampoline, say) may already own the
    // pointer. That is fine - we wrap whatever is there - as long as it is code.
    if (!is_executable(current)) { lua.push(static_cast<int64_t>(-4)); return 1; }

    for (auto& s : g_slots)
    {
        if (s.ufunction) continue;
        s.ufunction = ufn;
        s.original  = reinterpret_cast<NativeFn>(current);
        *reinterpret_cast<volatile uintptr_t*>(ufn + g_funcOffset) = reinterpret_cast<uintptr_t>(s.thunk);
        lua.push(static_cast<int64_t>(g_funcOffset));
        return 1;
    }
    lua.push(static_cast<int64_t>(-3));
    return 1;
}

// rt_redirect_begin(from1, to1, from2, to2, ...) -> pairs accepted
RT_EXPORT int rt_redirect_begin(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    int n = 0;
    while (lua.args() >= 2 && n < kPairs)
    {
        const auto from = static_cast<uintptr_t>(lua.pop_int());
        const auto to   = static_cast<uintptr_t>(lua.pop_int());
        if (from && to) { g_from[n] = from; g_to[n] = to; ++n; }
    }
    g_pairCount = n;
    g_swaps = 0;
    g_active = n > 0;
    lua.push(static_cast<int64_t>(n));
    return 1;
}

// rt_redirect_end() -> how many results were replaced inside the window
RT_EXPORT int rt_redirect_end(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    g_active = false;
    g_pairCount = 0;
    g_swapsTotal += g_swaps;
    lua.push(g_swaps);
    g_swaps = 0;
    return 1;
}

// rt_unhook_all() -> how many functions were put back
RT_EXPORT int rt_unhook_all(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    g_active = false;
    int64_t n = 0;
    for (auto& s : g_slots)
    {
        if (!s.ufunction) continue;
        uintptr_t current = 0;
        if (safe_read_ptr(s.ufunction + g_funcOffset, current) && is_our_thunk(current))
        {
            *reinterpret_cast<volatile uintptr_t*>(s.ufunction + g_funcOffset) =
                reinterpret_cast<uintptr_t>(s.original);
            ++n;
        }
        s.ufunction = 0;
        s.original = nullptr;
    }
    lua.push(n);
    return 1;
}

// rt_stats() -> hooked functions, Func offset, thunk calls in windows, swaps total
RT_EXPORT int rt_stats(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    int64_t hooked = 0;
    for (auto& s : g_slots) if (s.ufunction) ++hooked;
    lua.push(hooked);
    lua.push(static_cast<int64_t>(g_funcOffset));
    lua.push(g_calls);
    lua.push(g_swapsTotal);
    return 4;
}

// rt_read_ptr(address) -> the pointer-sized value there, or nil if unreadable.
// For investigation from the dev bridge (e.g. reading engine fields that have
// no reflection data); never on a hot path.
RT_EXPORT int rt_read_ptr(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    if (lua.args() < 1 || !lua.is_int()) { lua.push_nil(); return 1; }
    const auto addr = static_cast<uintptr_t>(lua.pop_int());
    uintptr_t v = 0;
    if (safe_read_ptr(addr, v)) lua.push(static_cast<int64_t>(v));
    else lua.push_nil();
    return 1;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        // package.loadlib keeps the library loaded for the life of the Lua
        // state, and UE4SS hot-reload makes a new state that loads it again:
        // the thunks and their slots must survive both, so nothing here is
        // torn down on detach either.
        DisableThreadLibraryCalls(module);
        fill_thunks(Seq<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>{});
        // Pin: Lua 5.4 FreeLibrary()s package.loadlib libraries when its state
        // is collected, which a UE4SS hot-reload does. Unloading us while engine
        // UFunctions still point at our thunks would crash the next call, so
        // this module stays mapped for the life of the process.
        HMODULE pinned = nullptr;
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                           reinterpret_cast<LPCWSTR>(&DllMain), &pinned);
    }
    return TRUE;
}
