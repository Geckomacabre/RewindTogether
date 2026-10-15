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
//   * Give a GUEST's HUD calls a GameMode to go through (THE HUD STAND-IN,
//     below), so the panel for what is in their hands and the hints for what
//     they look at appear on their screen as they do on the host's.
//
//   * Empty UE4SS's member-name cache when the mod's Lua state starts and
//     closes (THE UE4SS NAME CACHE, below). It keeps pointers into Lua
//     strings that a hot reload frees, and a guest crashed on one in 1.7.0.
//
//   * Say whether the engine wrote a crash report since a given time, so the
//     mod can tell a crash from a closed window (Crash reports, below).
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
// UE4SS also exports its view of the engine's object table, which is how the
// stand-in tells a live object from a freed one without guessing at layouts.
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
// THE HUD STAND-IN (guest only)
//
// Every HUD call the game's Blueprints make goes through one function
// library, UI_Player_Interface_C (RetroRewind-decomp bp/UI_Player_Interface.txt):
// `UI - Set Visible Product in Hand`, `UI - Draw Context Menu`, `Change the
// Cursor of Style`, `UI - Set Visible Look at Detail`, `Toggle Cursor
// Visiblity`. Each is GetGameMode -> ToInterface<UI_Interface_C> -> the call,
// and Core_Gamemode_C implements that interface by forwarding to its one
// widget, "UI Game Interface". On a guest GetGameMode is null - the GameMode
// exists on the server only - so none of it ever reaches the guest's HUD.
//
// The HUD widget implements UI_Interface_C as well, but every one of its
// interface events is an empty stub (bp/UI_Player_Interface__game_ui.txt:
// EVENT Set ProductInHand UI @1031 is a bare pop_flow, and so are the rest),
// so answering GetGameMode with the widget would change nothing. What answers
// instead is Core_Gamemode_C's class default object with its "UI Game
// Interface" pointed at the guest's widget (Lua sets that): the GameMode's
// own forwarding events then run on the CDO and land on the guest's widget.
// The CDO never ran BeginPlay, and only those forwarding events ever run on it.
//
// It is handed out ONLY when every one of these holds:
//   * GetGameMode really answered null (the host and single player always
//     have a GameMode, so for them the thunk is a call and a compare);
//   * the caller is the Blueprint VM: FFrame::Code is non-null. ProcessEvent -
//     UE4SS Lua, engine C++ - runs a native function on a frame with no code,
//     so the mod's own UE.GetGameMode() still sees null;
//   * the Blueprint function asking (FFrame::Node) belongs to the HUD library.
//     The census of the dump: 78 GetGameMode calls, 51 followed by
//     Cast<Core_Gamemode_C>, 24 by ToInterface<UI_Interface_C>, 3 by other
//     casts. Everything outside the library - the GameMode casts, the skin UI
//     on shelves and walls (it would let a guest re-skin things only they can
//     see), the tool checks - keeps getting null, exactly as before;
//   * the very next statement is ToInterface<UI_Interface_C> of a local;
//   * the CDO and the widget are both still the live objects Lua armed it
//     with (the object-table slot recorded then still holds that pointer, it
//     is not being destroyed, its class is unchanged), the CDO has its
//     persistent ubergraph frame (the event stubs write their parameters into
//     it), and its "UI Game Interface" still holds exactly that widget.
// A stand-in that fails a liveness check disarms itself; Lua re-arms it.
//
// Everything here runs on the game thread: Lua calls in from the mod's tick,
// and Blueprints call the thunks from the game thread. Every raw memory read of
// an address Lua handed us is SEH-guarded.

#include <windows.h>
#include <cstdint>
#include <cstring>
#include <cwchar>

static const int kVersion = 3;

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
// UE4SS's view of the engine's object table
// ---------------------------------------------------------------------------
//
// The layouts these hide - the chunked GUObjectArray, FUObjectItem, where
// UObjectBase keeps its index, flags, class and outer - are UE4SS's to know
// for this engine build, and it exports them for C++ mods. Member functions
// are called as free functions taking `this` first (the x64 convention); the
// ones returning references hand back a pointer to the field.

struct UeApi
{
    void*           (*index_to_object)(int32_t index)    = nullptr;  // static FUObjectArray::IndexToObject
    void*           (*item_object)(const void* item)     = nullptr;  // FUObjectItem::GetUObject() const
    int32_t         (*internal_index)(const void* obj)   = nullptr;  // UObjectBase::GetInternalIndex() const
    const uint32_t* (*object_flags)(const void* obj)     = nullptr;  // UObjectBase::GetObjectFlags() const
    void* const*    (*class_private)(const void* obj)    = nullptr;  // UObjectBase::GetClassPrivate() const
    void* const*    (*outer_private)(const void* obj)    = nullptr;  // UObjectBase::GetOuterPrivate() const
    bool ok = false;
};
static UeApi g_ue;

static bool load_ue_api()
{
    if (g_ue.ok) return true;
    HMODULE m = GetModuleHandleW(L"UE4SS.dll");
    if (!m) return false;
    bool all = true;
    all &= resolve(m, "?IndexToObject@FUObjectArray@Unreal@RC@@SAPEAUFUObjectItem@23@H@Z", g_ue.index_to_object);
    all &= resolve(m, "?GetUObject@FUObjectItem@Unreal@RC@@QEBAPEAVUObject@23@XZ", g_ue.item_object);
    all &= resolve(m, "?GetInternalIndex@UObjectBase@Unreal@RC@@QEBA?BHXZ", g_ue.internal_index);
    all &= resolve(m, "?GetObjectFlags@UObjectBase@Unreal@RC@@QEBAAEBW4EObjectFlags@23@XZ", g_ue.object_flags);
    all &= resolve(m, "?GetClassPrivate@UObjectBase@Unreal@RC@@QEBAAEAPEBVUClass@23@XZ", g_ue.class_private);
    all &= resolve(m, "?GetOuterPrivate@UObjectBase@Unreal@RC@@QEBAAEAPEBVUObject@23@XZ", g_ue.outer_private);
    g_ue.ok = all;
    return all;
}

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
// Live-object checks (the stand-in's only way of touching objects)
// ---------------------------------------------------------------------------

static const uint32_t RF_BeginDestroyed  = 0x00008000;
static const uint32_t RF_FinishDestroyed = 0x00010000;

// An object as it was when Lua armed the stand-in: its address, the slot it
// had in the object table then, and its class.
struct Tracked
{
    uintptr_t ptr   = 0;
    int32_t   index = -1;
    uintptr_t cls   = 0;
};

// Is `t` still that live object? Nothing is read through the pointer until the
// object table says that slot still holds it - so a freed object is never
// dereferenced - and one that has begun destruction, or whose memory now holds
// an object of another class, does not count.
static bool still_live(const Tracked& t)
{
    if (!t.ptr || t.index < 0) return false;
    __try
    {
        void* item = g_ue.index_to_object(t.index);
        if (!item || reinterpret_cast<uintptr_t>(g_ue.item_object(item)) != t.ptr) return false;
        const void* o = reinterpret_cast<const void*>(t.ptr);
        if (*g_ue.object_flags(o) & (RF_BeginDestroyed | RF_FinishDestroyed)) return false;
        return reinterpret_cast<uintptr_t>(*g_ue.class_private(o)) == t.cls;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

// Record an object Lua found alive this tick. The reads before the liveness
// check are of an address Lua vouched for, and guarded anyway.
static bool track(uintptr_t ptr, Tracked& out)
{
    out = Tracked{};
    if (!ptr) return false;
    __try
    {
        const void* o = reinterpret_cast<const void*>(ptr);
        out.index = g_ue.internal_index(o);
        out.cls   = reinterpret_cast<uintptr_t>(*g_ue.class_private(o));
        out.ptr   = ptr;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        out = Tracked{};
        return false;
    }
    return still_live(out);
}

// ---------------------------------------------------------------------------
// The HUD stand-in
// ---------------------------------------------------------------------------

// FFrame (CoreUObject Stack.h): FOutputDevice (vtable and two bools, 0x10),
// then Node, Object, Code, Locals - the same head since UE 4.0, and the same in
// UE4SS's FFrame_50_AndBelow and FFrame_51_AndAbove.
static const int kFrameNode = 0x10;
static const int kFrameCode = 0x20;

// EExprToken (CoreUObject Script.h). After the call, the HUD library's next
// statement is, with 8-byte pointers in memory:
//   [0] EX_Let  [1] FProperty*  [9] EX_LocalVariable  [10] FProperty*
//   [18] EX_ObjToInterfaceCast  [19] UClass*  [27] EX_LocalVariable  [28] FProperty*
// which is "K2Node_DynamicCast_AsUI_Interface = ToInterface<UI_Interface_C>(
// CallFunc_GetGameMode_ReturnValue)" - 36 bytes, as the dump's offsets show.
static const uint8_t EX_LocalVariable      = 0x00;
static const uint8_t EX_Let                = 0x0F;
static const uint8_t EX_ObjToInterfaceCast = 0x52;

static bool      g_siArmed     = false;
static Tracked   g_siObject;          // what GetGameMode answers: Core_Gamemode_C's CDO
static Tracked   g_siWidget;          // what its "UI Game Interface" must still hold
static int       g_siFrameOff  = 0;   // its UberGraphFrame (FPointerToUberGraphFrame)
static int       g_siWidgetOff = 0;   // its "UI Game Interface"
static uintptr_t g_siInterface = 0;   // UI_Interface_C: the cast the next statement makes
static uintptr_t g_siLibrary   = 0;   // UI_Player_Interface_C, the HUD function library
static int64_t   g_siAsked     = 0;   // Blueprint calls that got null while armed
static int64_t   g_siScoped    = 0;   // ...of which from the HUD library, casting to UI_Interface_C
static int64_t   g_siHanded    = 0;   // ...answered with the stand-in
static int64_t   g_siStale     = 0;   // ...refused because an object was no longer live

static bool next_is_ui_cast(uintptr_t code)
{
    __try
    {
        const auto* c = reinterpret_cast<const uint8_t*>(code);
        if (c[0] != EX_Let || c[9] != EX_LocalVariable || c[18] != EX_ObjToInterfaceCast
            || c[27] != EX_LocalVariable)
            return false;
        uintptr_t cls = 0;
        std::memcpy(&cls, c + 19, sizeof(cls));
        return cls == g_siInterface;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

static bool frame_in_library(uintptr_t node)
{
    __try
    {
        return reinterpret_cast<uintptr_t>(*g_ue.outer_private(reinterpret_cast<const void*>(node))) == g_siLibrary;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

static bool stand_in_still_valid()
{
    if (!still_live(g_siObject)) return false;
    uintptr_t frame = 0, widget = 0;
    if (!safe_read_ptr(g_siObject.ptr + g_siFrameOff, frame) || !frame) return false;
    if (!safe_read_ptr(g_siObject.ptr + g_siWidgetOff, widget) || widget != g_siWidget.ptr) return false;
    return still_live(g_siWidget);
}

// Called by the GetGameMode thunk after the original has written its answer.
static void stand_in(void* stack, void* result)
{
    if (!g_siArmed || !stack) return;
    auto* out = static_cast<uintptr_t*>(result);
    if (*out) return;                                         // a real GameMode
    const auto frame = reinterpret_cast<uintptr_t>(stack);
    uintptr_t code = 0, node = 0;
    if (!safe_read_ptr(frame + kFrameCode, code) || !code) return;   // ProcessEvent: Lua, C++
    ++g_siAsked;
    if (!safe_read_ptr(frame + kFrameNode, node) || !node) return;
    if (!frame_in_library(node) || !next_is_ui_cast(code)) return;
    ++g_siScoped;
    if (!stand_in_still_valid())
    {
        g_siArmed = false;
        ++g_siStale;
        return;
    }
    *out = g_siObject.ptr;
    ++g_siHanded;
}

// Arm it. Returns 1, or why not:
//   -1 an address or offset is missing, -2 the object or the widget is not a
//   live object, -3 the object has no persistent ubergraph frame, -4 its
//   "UI Game Interface" does not hold the widget, -5 UE4SS's object-table
//   exports were not found.
static int arm_stand_in(uintptr_t object, uintptr_t widget, int64_t frameOff, int64_t widgetOff,
                        uintptr_t uiInterface, uintptr_t library)
{
    g_siArmed = false;
    if (!load_ue_api()) return -5;
    if (!object || !widget || !uiInterface || !library) return -1;
    if (frameOff <= 0 || frameOff >= 0x10000 || widgetOff <= 0 || widgetOff >= 0x10000) return -1;

    Tracked o, w;
    if (!track(object, o) || !track(widget, w)) return -2;
    uintptr_t frame = 0, held = 0;
    if (!safe_read_ptr(object + static_cast<uintptr_t>(frameOff), frame) || !frame) return -3;
    if (!safe_read_ptr(object + static_cast<uintptr_t>(widgetOff), held) || held != widget) return -4;

    g_siObject    = o;
    g_siWidget    = w;
    g_siFrameOff  = static_cast<int>(frameOff);
    g_siWidgetOff = static_cast<int>(widgetOff);
    g_siInterface = uiInterface;
    g_siLibrary   = library;
    g_siArmed     = true;
    return 1;
}

// ---------------------------------------------------------------------------
// Return-value redirect
// ---------------------------------------------------------------------------

using NativeFn = void (*)(void* context, void* stack, void* result);

static const int kSlots = 16;
static const int kPairs = 8;

// What a wrapped function's thunk does after calling the original.
enum SlotKind
{
    kRedirect = 0,   // player-0 getters: swap from->to inside a window
    kStandIn  = 1,   // GetGameMode: the HUD stand-in for a null answer
};

struct Slot
{
    uintptr_t ufunction = 0;
    NativeFn  original  = nullptr;
    NativeFn  thunk     = nullptr;
    int       kind      = kRedirect;
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
    if (!result) return;
    if (g_slots[I].kind == kStandIn)
    {
        stand_in(stack, result);
        return;
    }
    if (!g_active) return;
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

// Wrap one UFunction. Returns the Func offset (>0) on success, or
//   -1 unreadable address, -2 no exec thunk found, -3 out of slots,
//   -4 the thunk is not in executable memory, -5 already wrapped as the other kind
static int64_t hook(uintptr_t ufn, int kind)
{
    for (auto& s : g_slots)
        if (s.ufunction == ufn) return s.kind == kind ? g_funcOffset : -5;

    if (!g_funcOffset)
    {
        const int off = find_func_offset(ufn);
        if (off < 0) return -1;
        if (off == 0) return -2;
        g_funcOffset = off;
    }

    uintptr_t current = 0;
    if (!safe_read_ptr(ufn + g_funcOffset, current)) return -1;
    if (is_our_thunk(current)) return g_funcOffset;
    // Something else (UE4SS's own hook trampoline, say) may already own the
    // pointer. That is fine - we wrap whatever is there - as long as it is code.
    if (!is_executable(current)) return -4;

    for (auto& s : g_slots)
    {
        if (s.ufunction) continue;
        s.ufunction = ufn;
        s.original  = reinterpret_cast<NativeFn>(current);
        s.kind      = kind;
        *reinterpret_cast<volatile uintptr_t*>(ufn + g_funcOffset) = reinterpret_cast<uintptr_t>(s.thunk);
        return g_funcOffset;
    }
    return -3;
}

// ---------------------------------------------------------------------------
// THE UE4SS NAME CACHE (host and guest)
// ---------------------------------------------------------------------------
//
// Measured in a guest's crash dump (1.7.0, UECC-...-1919342548779CCA2F2A5BAEF49442F2):
// an access violation on the game thread at UE4SS.dll+0x22ba30, with FNV-1a's
// offset basis and prime in RAX and R11 and a 32-byte key at a decommitted
// address in R9. That is the rehash loop of a static
// std::unordered_map<std::string_view, std::wstring> behind a std::shared_mutex,
// which UE4SS's UObject member access (UE4SS+0x22b590, under the __index and
// __newindex metamethods) uses to remember each member name's wide form.
//
// Its keys are string_views straight into the Lua strings the names arrived
// as (UE4SS+0x848050 is lua_tolstring, strlen, lua_remove): the characters are
// never copied. So a name string that dies leaves a key pointing at freed
// memory - every string, when a UE4SS hot reload closes the Lua state; one
// built at run time, when Lua collects it. The next insert that grows the
// table re-hashes every key, and reads it. In the dump it was the 513th name
// (R10 = 0x3ff, 512 -> 1024 buckets), a minute after the guest's second hot
// reload, dressing the host's pawn (bodies.lua) when it came back into
// network range - the module had nothing to do with it.
//
// The repair empties the cache, under UE4SS's own lock: every bucket goes
// back to the list's sentinel, the sentinel points at itself, the count goes
// to zero. The nodes are LEAKED, not freed: this DLL links its own CRT, so
// freeing UE4SS's nodes would be freeing into another heap, and UE4SS goes on
// using a node's string for a moment after it drops the lock. Lua runs it as
// the mod starts and from a finalizer as its state closes, so no key outlives
// the strings it points at across a reload; within a state the mod never
// indexes an object with a name Lua could collect (ue.lua, UE.pin). A few
// hundred names leak per reload - kilobytes.
//
// The cache is found, not assumed. Its address comes from the one place in
// UE4SS's code that takes its lock and starts hashing a name, and that same
// function's "size() == max_size()" check must name the address MSVC's layout
// puts the element count at. Before every write the layout must hold together
// as read under the lock: bucket count a power of two with the mask one less,
// two bucket pointers per bucket, and a list that comes back to its sentinel
// in exactly as many steps as the count says. Anything else and nothing is
// touched.

// Offsets from the lock, MSVC x64 (VS 2015 on): std::shared_mutex is one
// SRWLOCK; then std::unordered_map: its traits (the float max_load_factor),
// the list { _Myhead, _Mysize }, the bucket vector { _Myfirst, _Mylast,
// _Myend }, _Mask, _Maxidx. test_namecache.cpp checks the map's half against
// the STL it is built with.
static const uintptr_t kNcHead    = 0x10;
static const uintptr_t kNcSize    = 0x18;
static const uintptr_t kNcFirst   = 0x20;
static const uintptr_t kNcLast    = 0x28;
static const uintptr_t kNcMask    = 0x38;
static const uintptr_t kNcBuckets = 0x40;
static const uintptr_t kNcEnd     = 0x48;
static const size_t    kNcMaxEntries = size_t(1) << 22;

// Where UE4SS takes the lock and starts hashing (UE4SS+0x2285d1 on the
// installed build); -1 matches any byte:
//   lea r12,[rip+lock]; mov [rbp+x],r12; mov byte [rbp+y],1; mov rcx,r12;
//   call AcquireSRWLockShared; nop; movups xmm0,[rsi]; movaps [rbp+z],xmm0;
//   mov rbx,0xcbf29ce484222325
static const int16_t kNcLockSig[] = {
    0x4C, 0x8D, 0x25, -1, -1, -1, -1,
    0x4C, 0x89, 0x65, -1,
    0xC6, 0x45, -1, 0x01,
    0x49, 0x8B, 0xCC,
    0xE8, -1, -1, -1, -1,
    0x90,
    0x0F, 0x10, 0x06,
    0x0F, 0x29, 0x45, -1,
    0x48, 0xBB, 0x25, 0x23, 0x22, 0x84, 0xE4, 0x9C, 0xF2, 0xCB,
};
// Further on in the same function (+0x2286a0): "if (size() == max_size())".
//   mov rax,0x03ffffffffffffff; cmp [rip+size],rax
static const int16_t kNcSizeSig[] = {
    0x48, 0xB8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x03,
    0x48, 0x39, 0x05, -1, -1, -1, -1,
};
static const size_t kNcSizeWindow = 0x400;   // how far after the first to look for the second

template <size_t N>
static bool sig_at(const uint8_t* p, const int16_t (&sig)[N])
{
    for (size_t i = 0; i < N; ++i)
        if (sig[i] >= 0 && p[i] != static_cast<uint8_t>(sig[i])) return false;
    return true;
}

// The address a RIP-relative operand names: the 32-bit displacement at
// insn+at, relative to the end of the instruction (insn+len).
static uintptr_t rip_target(const uint8_t* insn, size_t at, size_t len)
{
    int32_t d = 0;
    std::memcpy(&d, insn + at, sizeof(d));
    return reinterpret_cast<uintptr_t>(insn) + len + static_cast<intptr_t>(d);
}

// Look through code [text, text+n) for the cache. Counts the candidates whose
// whole map lies in [dataLo, dataHi); *out gets the first. Only a count of
// exactly one is ever used.
static int find_name_cache(const uint8_t* text, size_t n, uintptr_t dataLo, uintptr_t dataHi,
                           uintptr_t* out)
{
    int found = 0;
    const size_t lockLen = sizeof(kNcLockSig) / sizeof(kNcLockSig[0]);
    const size_t sizeLen = sizeof(kNcSizeSig) / sizeof(kNcSizeSig[0]);
    for (size_t i = 0; i + lockLen <= n; ++i)
    {
        if (text[i] != 0x4C || !sig_at(text + i, kNcLockSig)) continue;
        const uintptr_t lock = rip_target(text + i, 3, 7);
        if (lock < dataLo || lock + kNcEnd > dataHi) continue;
        const size_t end = (i + kNcSizeWindow + sizeLen < n) ? i + kNcSizeWindow : n - sizeLen;
        for (size_t j = i + lockLen; j <= end; ++j)
        {
            if (text[j] != 0x48 || !sig_at(text + j, kNcSizeSig)) continue;
            if (rip_target(text + j, 13, sizeLen) == lock + kNcSize)
            {
                if (found++ == 0 && out) *out = lock;
                break;
            }
        }
    }
    return found;
}

// A section of a mapped image, by name.
static bool module_section(uintptr_t base, const char* name, Range& out)
{
    __try
    {
        auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
        if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
        auto nt  = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE) return false;
        auto sec = IMAGE_FIRST_SECTION(nt);
        for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++sec)
        {
            if (std::strncmp(reinterpret_cast<const char*>(sec->Name), name, IMAGE_SIZEOF_SHORT_NAME) == 0)
            {
                out.lo = base + sec->VirtualAddress;
                out.hi = out.lo + sec->Misc.VirtualSize;
                return true;
            }
        }
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
    }
    return false;
}

struct NcShape
{
    uintptr_t  head    = 0;
    size_t     size    = 0;
    uintptr_t* first   = nullptr;
    size_t     buckets = 0;
};

// Read the cache at `base` with its lock held. 1: it holds together; 0: never
// used (no sentinel node yet); -1: it does not hold together.
static int nc_shape(uintptr_t base, NcShape& s)
{
    __try
    {
        s = NcShape{};
        s.head = *reinterpret_cast<const uintptr_t*>(base + kNcHead);
        if (!s.head) return 0;
        s.size    = *reinterpret_cast<const size_t*>(base + kNcSize);
        s.first   = *reinterpret_cast<uintptr_t* const*>(base + kNcFirst);
        auto last = *reinterpret_cast<uintptr_t* const*>(base + kNcLast);
        auto mask = *reinterpret_cast<const size_t*>(base + kNcMask);
        s.buckets = *reinterpret_cast<const size_t*>(base + kNcBuckets);
        if (s.buckets < 8 || (s.buckets & (s.buckets - 1)) != 0 || mask != s.buckets - 1) return -1;
        if (!s.first || last < s.first || static_cast<size_t>(last - s.first) != 2 * s.buckets) return -1;
        if (s.size > kNcMaxEntries) return -1;
        for (size_t b = 0; b < 2 * s.buckets; ++b)
            if (!s.first[b]) return -1;
        // Node: { _Next, _Prev, value }. Around the ring once, every link both ways.
        uintptr_t prev = s.head;
        uintptr_t node = *reinterpret_cast<const uintptr_t*>(s.head);
        size_t count = 0;
        while (node != s.head)
        {
            if (!node || ++count > s.size) return -1;
            if (*reinterpret_cast<const uintptr_t*>(node + 8) != prev) return -1;
            prev = node;
            node = *reinterpret_cast<const uintptr_t*>(node);
        }
        if (count != s.size || *reinterpret_cast<const uintptr_t*>(s.head + 8) != prev) return -1;
        return 1;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return -1;
    }
}

static bool nc_unlink_all(uintptr_t base, const NcShape& s)
{
    __try
    {
        for (size_t b = 0; b < 2 * s.buckets; ++b) s.first[b] = s.head;
        auto* sentinel = reinterpret_cast<uintptr_t*>(s.head);
        sentinel[0] = s.head;
        sentinel[1] = s.head;
        *reinterpret_cast<size_t*>(base + kNcSize) = 0;
        return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

// Empty the cache at `base`. Returns the names dropped, 0 when it was never
// used, -2 when it does not hold together (and was left alone).
static int64_t nc_purge(uintptr_t base)
{
    auto* lock = reinterpret_cast<PSRWLOCK>(base);
    AcquireSRWLockExclusive(lock);
    NcShape s;
    const int st = nc_shape(base, s);
    int64_t dropped = st == 0 ? 0 : -2;
    if (st > 0 && nc_unlink_all(base, s)) dropped = static_cast<int64_t>(s.size);
    ReleaseSRWLockExclusive(lock);
    return dropped;
}

static int nc_read(uintptr_t base, NcShape& s)
{
    auto* lock = reinterpret_cast<PSRWLOCK>(base);
    AcquireSRWLockShared(lock);
    const int st = nc_shape(base, s);
    ReleaseSRWLockShared(lock);
    return st;
}

static int       g_ncState   = 0;   // 0 not looked for, 1 found, -1 not on this UE4SS build
static uintptr_t g_ncBase    = 0;
static int64_t   g_ncDropped = 0;   // names dropped by every purge in this process
static int64_t   g_ncPurges  = 0;

static bool locate_live_name_cache()
{
    if (g_ncState) return g_ncState > 0;
    g_ncState = -1;
    const auto base = reinterpret_cast<uintptr_t>(GetModuleHandleW(L"UE4SS.dll"));
    Range text, data;
    if (!base || !module_section(base, ".text", text) || !module_section(base, ".data", data))
        return false;
    uintptr_t lock = 0;
    if (find_name_cache(reinterpret_cast<const uint8_t*>(text.lo), text.hi - text.lo,
                        data.lo, data.hi, &lock) != 1)
        return false;
    g_ncBase  = lock;
    g_ncState = 1;
    return true;
}

// ---------------------------------------------------------------------------
// Crash reports (both sides)
// ---------------------------------------------------------------------------
//
// safety.lua's record says what the mod was doing when the last run stopped,
// not WHY it stopped: a crash, the window being closed, Steam's Stop and a
// killed process all leave the same record behind. The engine tells them
// apart for us - a crash writes a report folder under
// %LOCALAPPDATA%\RetroRewind\Saved\Crashes (UECC-Windows-<guid>_0000, the
// minidump inside) before the process dies; nothing else does. Lua cannot
// list a folder without starting a shell, so this does it.

// Unix seconds from a FILETIME (100 ns ticks since 1601-01-01 UTC).
static int64_t unix_seconds(const FILETIME& ft)
{
    const int64_t ticks = (static_cast<int64_t>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return (ticks - 116444736000000000LL) / 10000000LL;
}

// The process a report folder is about: CrashContext.runtime-xml's
// <ProcessId>, near the top of the file. 0 when it cannot be read.
static int64_t report_pid(const wchar_t* folder)
{
    wchar_t path[MAX_PATH];
    if (swprintf_s(path, MAX_PATH, L"%s\\CrashContext.runtime-xml", folder) < 0) return 0;
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return 0;
    char buf[4096];
    DWORD got = 0;
    const BOOL ok = ReadFile(f, buf, sizeof(buf) - 1, &got, nullptr);
    CloseHandle(f);
    if (!ok) return 0;
    buf[got] = 0;
    const char* tag = std::strstr(buf, "<ProcessId>");
    if (!tag) return 0;
    int64_t pid = 0;
    for (const char* c = tag + 11; *c >= '0' && *c <= '9'; ++c) pid = pid * 10 + (*c - '0');
    return pid;
}

// Report folders in `dir` made at or after `since` (Unix seconds) - about
// process `pid` when it is not 0 (two copies of the game share the folder);
// a report whose process cannot be read counts. *newest gets the latest
// one's time, or 0. -1 when the folder cannot be read.
static int64_t count_crash_folders(const wchar_t* dir, int64_t since, int64_t* newest, int64_t pid = 0)
{
    if (newest) *newest = 0;
    wchar_t pattern[MAX_PATH];
    if (swprintf_s(pattern, MAX_PATH, L"%s\\*", dir) < 0) return -1;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE)
    {
        // No folder (the game has never crashed here) or nothing in it: no report.
        const DWORD e = GetLastError();
        return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND) ? 0 : -1;
    }
    int64_t n = 0;
    do
    {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || fd.cFileName[0] == L'.') continue;
        const int64_t made = unix_seconds(fd.ftCreationTime);
        const int64_t wrote = unix_seconds(fd.ftLastWriteTime);
        const int64_t t = made > wrote ? made : wrote;
        if (newest && t > *newest) *newest = t;
        if (t < since) continue;
        if (pid > 0)
        {
            wchar_t folder[MAX_PATH];
            if (swprintf_s(folder, MAX_PATH, L"%s\\%s", dir, fd.cFileName) < 0) continue;
            const int64_t about = report_pid(folder);
            if (about != 0 && about != pid) continue;
        }
        ++n;
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return n;
}

static bool crash_dir(wchar_t (&out)[MAX_PATH])
{
    wchar_t base[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    return swprintf_s(out, MAX_PATH, L"%s\\RetroRewind\\Saved\\Crashes", base) >= 0;
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
    lua.push("RewindNative 3 (player-0 redirect, HUD stand-in, UE4SS name-cache repair, crash reports)");
    return 2;
}

// rt_namecache() -> 1 found, 0 not on this UE4SS build, -1 found but it does
//   not hold together; names in it now; its buckets; names dropped so far
//   by rt_namecache_purge in this process; purges so far
RT_EXPORT int rt_namecache(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    NcShape s;
    int64_t state = 0;
    if (locate_live_name_cache()) state = nc_read(g_ncBase, s) < 0 ? -1 : 1;
    lua.push(state);
    lua.push(static_cast<int64_t>(s.size));
    lua.push(static_cast<int64_t>(s.buckets));
    lua.push(g_ncDropped);
    lua.push(g_ncPurges);
    return 5;
}

// rt_crashes_since(unixSeconds [, pid]) -> crash report folders made at or
//   after it (about that process, if given), and the newest one's time (0 if
//   none); -1 when the folder cannot be read
RT_EXPORT int rt_crashes_since(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    if (lua.args() < 1 || !lua.is_int()) { lua.push(static_cast<int64_t>(-1)); return 1; }
    const int64_t since = lua.pop_int();
    const int64_t pid = (lua.args() >= 1 && lua.is_int()) ? lua.pop_int() : 0;
    wchar_t dir[MAX_PATH];
    int64_t newest = 0;
    const int64_t n = crash_dir(dir) ? count_crash_folders(dir, since, &newest, pid) : -1;
    lua.push(n);
    lua.push(newest);
    return 2;
}

// Is `pid` a running copy of the game (this executable's name)? 1 yes, 0 no
// (gone, or the id now belongs to something else), -1 cannot tell.
static int pid_alive(int64_t pid)
{
    if (pid <= 0 || pid > 0xFFFFFFFFLL) return 0;
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, static_cast<DWORD>(pid));
    if (!p) return GetLastError() == ERROR_INVALID_PARAMETER ? 0 : -1;
    DWORD code = 0;
    int alive = GetExitCodeProcess(p, &code) ? (code == STILL_ACTIVE ? 1 : 0) : -1;
    if (alive == 1)
    {
        wchar_t theirs[MAX_PATH], ours[MAX_PATH];
        DWORD n = MAX_PATH;
        const bool named = QueryFullProcessImageNameW(p, 0, theirs, &n) != 0;
        const DWORD m = GetModuleFileNameW(nullptr, ours, MAX_PATH);
        if (named && m > 0 && m < MAX_PATH)
        {
            const wchar_t* a = std::wcsrchr(theirs, L'\\');
            const wchar_t* b = std::wcsrchr(ours, L'\\');
            if (_wcsicmp(a ? a + 1 : theirs, b ? b + 1 : ours) != 0) alive = 0;
        }
    }
    CloseHandle(p);
    return alive;
}

// rt_pid_alive(pid) -> 1 a running copy of the game, 0 not, -1 cannot tell
RT_EXPORT int rt_pid_alive(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    if (lua.args() < 1 || !lua.is_int()) { lua.push(static_cast<int64_t>(-1)); return 1; }
    lua.push(static_cast<int64_t>(pid_alive(lua.pop_int())));
    return 1;
}

// rt_pid() -> this process's id (crash reports name the process they are about)
RT_EXPORT int rt_pid(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    lua.push(static_cast<int64_t>(GetCurrentProcessId()));
    return 1;
}

// rt_namecache_purge() -> names dropped (>= 0); -1 this UE4SS build has no
//   such cache (nothing to repair); -2 it does not hold together (left alone)
RT_EXPORT int rt_namecache_purge(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    if (!locate_live_name_cache()) { lua.push(static_cast<int64_t>(-1)); return 1; }
    const int64_t dropped = nc_purge(g_ncBase);
    if (dropped >= 0)
    {
        g_ncDropped += dropped;
        ++g_ncPurges;
    }
    lua.push(dropped);
    return 1;
}

// rt_hook_return(ufunctionAddress) -> Func offset (>0) on success, or
//   -1 unreadable address, -2 no exec thunk found, -3 out of slots,
//   -4 the thunk is not in executable memory, -5 already wrapped as a stand-in
RT_EXPORT int rt_hook_return(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    if (lua.args() < 1 || !lua.is_int()) { lua.push(static_cast<int64_t>(-1)); return 1; }
    const auto ufn = static_cast<uintptr_t>(lua.pop_int());
    lua.push(hook(ufn, kRedirect));
    return 1;
}

// rt_hook_null(ufunctionAddress) -> as rt_hook_return, for GetGameMode: the
// thunk can answer a null result with the HUD stand-in once it is armed.
RT_EXPORT int rt_hook_null(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    if (lua.args() < 1 || !lua.is_int()) { lua.push(static_cast<int64_t>(-1)); return 1; }
    const auto ufn = static_cast<uintptr_t>(lua.pop_int());
    lua.push(hook(ufn, kStandIn));
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

// rt_standin_arm(object, widget, frameOffset, widgetOffset, uiInterface, hudLibrary)
//   -> 1 armed, or the reason it was not (arm_stand_in above)
RT_EXPORT int rt_standin_arm(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    int64_t a[6] = {};
    for (auto& v : a)
    {
        if (lua.args() < 1 || !lua.is_int()) { g_siArmed = false; lua.push(static_cast<int64_t>(-1)); return 1; }
        v = lua.pop_int();
    }
    lua.push(static_cast<int64_t>(arm_stand_in(static_cast<uintptr_t>(a[0]), static_cast<uintptr_t>(a[1]),
                                               a[2], a[3], static_cast<uintptr_t>(a[4]),
                                               static_cast<uintptr_t>(a[5]))));
    return 1;
}

// rt_standin_disarm() -> how many answers the stand-in has given, in total
RT_EXPORT int rt_standin_disarm(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    g_siArmed = false;
    lua.push(g_siHanded);
    return 1;
}

// rt_standin_stats() -> armed (0/1), Blueprint calls answered null while armed,
//   of those from the HUD library, answered with the stand-in, refused as stale
RT_EXPORT int rt_standin_stats(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    lua.push(static_cast<int64_t>(g_siArmed ? 1 : 0));
    lua.push(g_siAsked);
    lua.push(g_siScoped);
    lua.push(g_siHanded);
    lua.push(g_siStale);
    return 5;
}

// rt_unhook_all() -> how many functions were put back
RT_EXPORT int rt_unhook_all(void* L)
{
    if (!load_lua_api()) return 0;
    Lua lua(L);
    g_active = false;
    g_siArmed = false;
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
        s.kind = kRedirect;
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
