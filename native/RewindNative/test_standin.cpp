// Native test for RewindNative.cpp, without the game: test.bat builds and runs it.
//
// The thunks run inside the game's Blueprint VM, where a mistake is a crash
// rather than an error, so the decisions they make are exercised here first:
// the GetGameMode stand-in (when it may answer, when it must not, and that it
// stands down once an object it relies on is gone) and the player-0 redirect.
//
// RewindNative.cpp is compiled into this exe. What it would get from UE4SS -
// the object table and the UObjectBase accessors - is faked with plain
// structs, and so are the engine's FFrame and a few statements of bytecode.

#include "RewindNative.cpp"

#include <cstddef>
#include <cstdio>

static int g_failures = 0;
static void check(const char* name, bool ok)
{
    std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok) ++g_failures;
}

// ---- a fake object table and objects ----

struct FakeItem { void* object; };
static FakeItem g_table[64];

struct FakeObj
{
    uint32_t flags = 0;
    int32_t  index = -1;
    void*    cls   = nullptr;
    void*    outer = nullptr;
    unsigned char body[0x200] = {};
};

static void*           fake_index_to_object(int32_t i) { return (i >= 0 && i < 64) ? &g_table[i] : nullptr; }
static void*           fake_item_object(const void* item) { return static_cast<const FakeItem*>(item)->object; }
static int32_t         fake_internal_index(const void* o) { return static_cast<const FakeObj*>(o)->index; }
static const uint32_t* fake_object_flags(const void* o) { return &static_cast<const FakeObj*>(o)->flags; }
static void* const*    fake_class_private(const void* o) { return &static_cast<const FakeObj*>(o)->cls; }
static void* const*    fake_outer_private(const void* o) { return &static_cast<const FakeObj*>(o)->outer; }

static void spawn(FakeObj& o, int index, void* cls)
{
    o.index = index;
    o.cls = cls;
    o.flags = 0;
    g_table[index].object = &o;
}

static const int kFrameOff  = static_cast<int>(offsetof(FakeObj, body)) + 0x28;
static const int kWidgetOff = static_cast<int>(offsetof(FakeObj, body)) + 0x38;

static void put_ptr(FakeObj& o, int off, const void* p)
{
    auto v = reinterpret_cast<uintptr_t>(p);
    std::memcpy(reinterpret_cast<unsigned char*>(&o) + off, &v, sizeof(v));
}

// ---- FFrame and bytecode ----

struct FakeFrame
{
    void*          vtable = nullptr;
    unsigned char  bools[8] = {};
    void*          node = nullptr;     // 0x10
    void*          object = nullptr;   // 0x18
    const uint8_t* code = nullptr;     // 0x20
    void*          locals = nullptr;   // 0x28
};
static_assert(offsetof(FakeFrame, node) == 0x10 && offsetof(FakeFrame, code) == 0x20, "FFrame head");

// "X = ToInterface<cls>(Y)" and "X = Cast<cls>(Y)" as they sit in memory.
static void make_iface_cast(uint8_t (&c)[36], const void* cls)
{
    std::memset(c, 0xAB, sizeof(c));
    c[0] = EX_Let; c[9] = EX_LocalVariable; c[18] = EX_ObjToInterfaceCast; c[27] = EX_LocalVariable;
    auto v = reinterpret_cast<uintptr_t>(cls);
    std::memcpy(c + 19, &v, sizeof(v));
}
static void make_dynamic_cast(uint8_t (&c)[36], const void* cls)
{
    std::memset(c, 0xAB, sizeof(c));
    c[0] = 0x5F;                    // EX_LetObj
    c[1] = EX_LocalVariable;
    c[10] = 0x2E;                   // EX_DynamicCast
    auto v = reinterpret_cast<uintptr_t>(cls);
    std::memcpy(c + 11, &v, sizeof(v));
    c[19] = EX_LocalVariable;
}

// ---- the functions being wrapped ----

static uintptr_t g_realAnswer = 0;   // what the "engine" returns
static void fake_original(void*, void*, void* result) { *static_cast<uintptr_t*>(result) = g_realAnswer; }

struct FakeUFunction
{
    alignas(16) unsigned char bytes[0x200] = {};
    void set_func(NativeFn f) { auto v = reinterpret_cast<uintptr_t>(f); std::memcpy(bytes + 0xD8, &v, sizeof(v)); }
    NativeFn func() const { uintptr_t v; std::memcpy(&v, bytes + 0xD8, sizeof(v)); return reinterpret_cast<NativeFn>(v); }
    uintptr_t addr() const { return reinterpret_cast<uintptr_t>(bytes); }
};

static uintptr_t call(const FakeUFunction& fn, FakeFrame* frame)
{
    uintptr_t result = 0xDEAD;      // the original must overwrite it
    fn.func()(nullptr, frame, &result);
    return result;
}

int main()
{
    std::printf("RewindNative native test\n");
    fill_thunks(Seq<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>{});
    g_ue.index_to_object = fake_index_to_object;
    g_ue.item_object     = fake_item_object;
    g_ue.internal_index  = fake_internal_index;
    g_ue.object_flags    = fake_object_flags;
    g_ue.class_private   = fake_class_private;
    g_ue.outer_private   = fake_outer_private;
    g_ue.ok = true;

    // Classes and functions are only ever compared by address.
    static unsigned char gmClass[8], widgetClass[8], uiIface[8], ghostIface[8], gmCast[8];
    static unsigned char hudLibrary[8], pawnClass[8], otherClass[8];
    FakeObj hudFunction; hudFunction.outer = hudLibrary;     // "UI - Set Visible Product in Hand"
    FakeObj pawnFunction; pawnFunction.outer = pawnClass;    // Player_Character's ubergraph

    FakeObj cdo, widget, widget2, frameMem;
    spawn(cdo, 3, gmClass);
    spawn(widget, 7, widgetClass);
    spawn(widget2, 9, widgetClass);
    put_ptr(cdo, kFrameOff, &frameMem);
    put_ptr(cdo, kWidgetOff, &widget);

    uint8_t uiCast[36], ghostCast[36], gmCastCode[36];
    make_iface_cast(uiCast, uiIface);
    make_iface_cast(ghostCast, ghostIface);
    make_dynamic_cast(gmCastCode, gmCast);

    FakeFrame hudCall;   hudCall.node = &hudFunction;   hudCall.code = uiCast;
    FakeFrame pawnCall;  pawnCall.node = &pawnFunction; pawnCall.code = uiCast;
    FakeFrame hudGhost;  hudGhost.node = &hudFunction;  hudGhost.code = ghostCast;
    FakeFrame hudGmCast; hudGmCast.node = &hudFunction; hudGmCast.code = gmCastCode;
    FakeFrame luaCall;   luaCall.node = &hudFunction;   luaCall.code = nullptr;   // ProcessEvent

    const auto CDO = reinterpret_cast<uintptr_t>(&cdo);

    std::printf("\n-- wrapping GetGameMode --\n");
    FakeUFunction getGameMode;
    getGameMode.set_func(&fake_original);
    check("GetGameMode is wrapped, Func found at +0xD8", hook(getGameMode.addr(), kStandIn) == 0xD8);
    check("its Func now points at a thunk", is_our_thunk(reinterpret_cast<uintptr_t>(getGameMode.func())));
    check("wrapping it again as the other kind is refused", hook(getGameMode.addr(), kRedirect) == -5);
    check("wrapping it again as the same kind is a no-op", hook(getGameMode.addr(), kStandIn) == 0xD8);

    std::printf("\n-- before it is armed --\n");
    g_realAnswer = 0;
    check("null stays null", call(getGameMode, &hudCall) == 0);

    std::printf("\n-- arming --\n");
    check("refused without an address", arm_stand_in(0, reinterpret_cast<uintptr_t>(&widget), kFrameOff, kWidgetOff,
          reinterpret_cast<uintptr_t>(uiIface), reinterpret_cast<uintptr_t>(hudLibrary)) == -1);
    put_ptr(cdo, kFrameOff, nullptr);
    check("refused when the object has no ubergraph frame", arm_stand_in(CDO, reinterpret_cast<uintptr_t>(&widget),
          kFrameOff, kWidgetOff, reinterpret_cast<uintptr_t>(uiIface), reinterpret_cast<uintptr_t>(hudLibrary)) == -3);
    put_ptr(cdo, kFrameOff, &frameMem);
    check("refused when its UI Game Interface is another widget", arm_stand_in(CDO, reinterpret_cast<uintptr_t>(&widget2),
          kFrameOff, kWidgetOff, reinterpret_cast<uintptr_t>(uiIface), reinterpret_cast<uintptr_t>(hudLibrary)) == -4);
    g_table[7].object = nullptr;
    check("refused when the widget is not a live object", arm_stand_in(CDO, reinterpret_cast<uintptr_t>(&widget),
          kFrameOff, kWidgetOff, reinterpret_cast<uintptr_t>(uiIface), reinterpret_cast<uintptr_t>(hudLibrary)) == -2);
    g_table[7].object = &widget;
    check("armed with everything in place", arm_stand_in(CDO, reinterpret_cast<uintptr_t>(&widget),
          kFrameOff, kWidgetOff, reinterpret_cast<uintptr_t>(uiIface), reinterpret_cast<uintptr_t>(hudLibrary)) == 1);

    std::printf("\n-- who gets the stand-in --\n");
    const int64_t handedBefore = g_siHanded;
    check("the HUD library's ToInterface<UI_Interface_C> gets it", call(getGameMode, &hudCall) == CDO);
    check("and it is counted", g_siHanded == handedBefore + 1);
    check("ProcessEvent (Lua, C++) still gets null", call(getGameMode, &luaCall) == 0);
    check("a Blueprint outside the HUD library still gets null", call(getGameMode, &pawnCall) == 0);
    check("a Cast<Core_Gamemode_C> after the call still gets null", call(getGameMode, &hudGmCast) == 0);
    check("a cast to another interface still gets null", call(getGameMode, &hudGhost) == 0);
    g_realAnswer = 0x123450;
    check("a real GameMode is never replaced", call(getGameMode, &hudCall) == 0x123450);
    g_realAnswer = 0;
    check("still armed after all that", g_siArmed);

    std::printf("\n-- standing down --\n");
    put_ptr(cdo, kWidgetOff, &widget2);
    check("its UI Game Interface changed: null", call(getGameMode, &hudCall) == 0);
    check("and it disarmed itself", !g_siArmed);
    put_ptr(cdo, kWidgetOff, &widget);

    arm_stand_in(CDO, reinterpret_cast<uintptr_t>(&widget), kFrameOff, kWidgetOff,
                 reinterpret_cast<uintptr_t>(uiIface), reinterpret_cast<uintptr_t>(hudLibrary));
    g_table[7].object = nullptr;                              // the widget was freed
    const int64_t staleBefore = g_siStale;
    check("the widget was freed: null", call(getGameMode, &hudCall) == 0);
    check("disarmed and counted as stale", !g_siArmed && g_siStale == staleBefore + 1);
    g_table[7].object = &widget;

    arm_stand_in(CDO, reinterpret_cast<uintptr_t>(&widget), kFrameOff, kWidgetOff,
                 reinterpret_cast<uintptr_t>(uiIface), reinterpret_cast<uintptr_t>(hudLibrary));
    cdo.flags = RF_BeginDestroyed;
    check("the object began destruction: null", call(getGameMode, &hudCall) == 0 && !g_siArmed);
    cdo.flags = 0;

    arm_stand_in(CDO, reinterpret_cast<uintptr_t>(&widget), kFrameOff, kWidgetOff,
                 reinterpret_cast<uintptr_t>(uiIface), reinterpret_cast<uintptr_t>(hudLibrary));
    widget.cls = otherClass;                                  // its memory holds something else now
    check("the widget's slot holds another class: null", call(getGameMode, &hudCall) == 0 && !g_siArmed);
    widget.cls = widgetClass;

    arm_stand_in(CDO, reinterpret_cast<uintptr_t>(&widget), kFrameOff, kWidgetOff,
                 reinterpret_cast<uintptr_t>(uiIface), reinterpret_cast<uintptr_t>(hudLibrary));
    g_table[3].object = &widget2;                             // the CDO's slot was reused
    check("the object's slot was reused: null", call(getGameMode, &hudCall) == 0 && !g_siArmed);
    g_table[3].object = &cdo;

    arm_stand_in(CDO, reinterpret_cast<uintptr_t>(&widget), kFrameOff, kWidgetOff,
                 reinterpret_cast<uintptr_t>(uiIface), reinterpret_cast<uintptr_t>(hudLibrary));
    put_ptr(cdo, kFrameOff, nullptr);
    check("the ubergraph frame went away: null", call(getGameMode, &hudCall) == 0 && !g_siArmed);
    put_ptr(cdo, kFrameOff, &frameMem);

    std::printf("\n-- the player-0 redirect is unchanged --\n");
    FakeUFunction getPlayerController;
    getPlayerController.set_func(&fake_original);
    check("GetPlayerController is wrapped", hook(getPlayerController.addr(), kRedirect) == 0xD8);
    g_realAnswer = 0x1000;                                    // the host's controller
    check("outside a window the host is player 0", call(getPlayerController, &pawnCall) == 0x1000);
    g_from[0] = 0x1000; g_to[0] = 0x2000; g_pairCount = 1; g_active = true; g_swaps = 0;
    check("inside a window the guest is", call(getPlayerController, &pawnCall) == 0x2000);
    check("and GetGameMode is not part of the window", call(getGameMode, &pawnCall) == 0x1000);
    g_active = false; g_pairCount = 0;
    check("after the window the host again", call(getPlayerController, &pawnCall) == 0x1000);
    g_realAnswer = 0;

    std::printf("\n%s\n", g_failures ? "SOME CHECKS FAILED" : "All native checks passed.");
    return g_failures ? 1 : 0;
}
