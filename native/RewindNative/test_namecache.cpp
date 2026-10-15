// Native test for the UE4SS name-cache repair in RewindNative.cpp, without the
// game: build.bat builds and runs it before it builds the DLL.
//
// The repair writes into UE4SS's memory, so what it decides is exercised here
// first, on a real MSVC std::unordered_map<std::string_view, std::wstring>
// laid out the way the crash dump shows UE4SS's: an SRWLOCK, then the map.
// The dump's failure is reproduced (names whose characters were freed, then
// the insert that grows the table and re-hashes them), then the repair is
// shown to prevent it. When the game's UE4SS.dll is on this machine, the
// signature is run against it as well.

#include "RewindNative.cpp"

#include <cstdio>
#include <ctime>
#include <string>
#include <string_view>
#include <unordered_map>

static int g_failures = 0;
static void check(const char* name, bool ok)
{
    std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok) ++g_failures;
}

using Map = std::unordered_map<std::string_view, std::wstring>;

// UE4SS's statics as the dump shows them: the lock, then the map.
struct FakeCache
{
    SRWLOCK lock = SRWLOCK_INIT;
    Map     map;
};
static_assert(sizeof(FakeCache) == kNcEnd, "an SRWLOCK and an unordered_map are 0x48 bytes on MSVC x64");

static uintptr_t base_of(FakeCache& c) { return reinterpret_cast<uintptr_t>(&c.lock); }

// ---- names in pages that can be freed, like a closed Lua state's strings ----

struct Names
{
    char* base  = nullptr;
    int   count = 0;
    int   len   = 0;
};

static Names make_names(int count, int salt, int len = 32)
{
    Names n;
    n.count = count;
    n.len   = len;
    n.base  = static_cast<char*>(VirtualAlloc(nullptr, static_cast<size_t>(count) * len,
                                              MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE));
    for (int i = 0; i < count; ++i)
    {
        char tmp[64];
        std::snprintf(tmp, sizeof(tmp), "RT_member_%05d_%05d_xxxxxxxxxxxxxxxxxxxx", salt, i);
        std::memcpy(n.base + static_cast<size_t>(i) * len, tmp, len);
    }
    return n;
}

static std::string_view name_at(const Names& n, int i)
{
    return { n.base + static_cast<size_t>(i) * n.len, static_cast<size_t>(n.len) };
}

static void free_names(Names& n) { VirtualFree(n.base, 0, MEM_RELEASE); }

struct Insert
{
    Map*         map;
    const Names* names;
    int          from, to;
};

static void do_insert(void* arg)
{
    auto* a = static_cast<Insert*>(arg);
    for (int i = a->from; i < a->to; ++i) a->map->emplace(name_at(*a->names, i), L"wide");
}

// Whether fn faulted reading memory. A frame of its own: nothing in it may need unwinding.
static bool faults(void (*fn)(void*), void* arg)
{
    __try
    {
        fn(arg);
        return false;
    }
    __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER
                                                               : EXCEPTION_CONTINUE_SEARCH)
    {
        return true;
    }
}

static bool insert_faults(FakeCache& c, const Names& n, int from, int to)
{
    Insert a{ &c.map, &n, from, to };
    return faults(&do_insert, &a);
}

static bool all_found(FakeCache& c, const Names& n)
{
    for (int i = 0; i < n.count; ++i)
        if (c.map.find(name_at(n, i)) == c.map.end()) return false;
    return true;
}

// ---- UE4SS's code, byte for byte as at UE4SS+0x2285d1 and +0x2286a0 ----

static const uint8_t kLockBytes[] = {
    0x4c, 0x8d, 0x25, 0, 0, 0, 0,  0x4c, 0x89, 0x65, 0xd7,  0xc6, 0x45, 0xdf, 0x01,
    0x49, 0x8b, 0xcc,  0xe8, 0xb8, 0xdf, 0x71, 0x00,  0x90,  0x0f, 0x10, 0x06,
    0x0f, 0x29, 0x45, 0xe7,  0x48, 0xbb, 0x25, 0x23, 0x22, 0x84, 0xe4, 0x9c, 0xf2, 0xcb,
};
static const uint8_t kSizeBytes[] = {
    0x48, 0xb8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03,  0x48, 0x39, 0x05, 0, 0, 0, 0,
};
static const size_t kSizeAt   = 0x2286a0 - 0x2285d1;
static const size_t kCodeSize = 0x200;

static void put_disp(uint8_t* insn, size_t at, size_t len, uintptr_t target)
{
    const auto d = static_cast<int32_t>(static_cast<intptr_t>(target)
                                        - static_cast<intptr_t>(reinterpret_cast<uintptr_t>(insn) + len));
    std::memcpy(insn + at, &d, sizeof(d));
}

// The two instructions, at `at`, naming `lock` and `sizeField`.
static void make_code(uint8_t* at, uintptr_t lock, uintptr_t sizeField)
{
    std::memset(at, 0xCC, kCodeSize);
    std::memcpy(at, kLockBytes, sizeof(kLockBytes));
    put_disp(at, 3, 7, lock);
    std::memcpy(at + kSizeAt, kSizeBytes, sizeof(kSizeBytes));
    put_disp(at + kSizeAt, 13, sizeof(kSizeBytes), sizeField);
}

static uint8_t   g_code[2 * kCodeSize];
static FakeCache g_target;      // static, so the fake code can reach it with a 32-bit displacement
static FakeCache g_layout;

int main()
{
    std::printf("-- MSVC lays the map out as the repair assumes --\n");
    Names layoutNames = make_names(100, 0);
    {
        Insert a{ &g_layout.map, &layoutNames, 0, 100 };
        do_insert(&a);
    }
    const uintptr_t lb = base_of(g_layout);
    check("the count is at +0x18", *reinterpret_cast<size_t*>(lb + kNcSize) == g_layout.map.size());
    check("the bucket count is at +0x40",
          *reinterpret_cast<size_t*>(lb + kNcBuckets) == g_layout.map.bucket_count());
    check("the mask is at +0x38",
          *reinterpret_cast<size_t*>(lb + kNcMask) == g_layout.map.bucket_count() - 1);
    NcShape shape;
    check("it holds together as read: 100 names around the ring",
          nc_shape(lb, shape) == 1 && shape.size == 100 && shape.buckets == g_layout.map.bucket_count());

    std::printf("\n-- the signature --\n");
    const uintptr_t tb = base_of(g_target);
    const uintptr_t lo = tb, hi = tb + sizeof(FakeCache);
    uintptr_t found = 0;
    make_code(g_code, tb, tb + kNcSize);
    check("finds the cache the code names", find_name_cache(g_code, kCodeSize, lo, hi, &found) == 1 && found == tb);
    make_code(g_code, tb, tb + kNcSize + 8);
    check("not when the size check names another field", find_name_cache(g_code, kCodeSize, lo, hi, &found) == 0);
    make_code(g_code, tb, tb + kNcSize);
    g_code[33] ^= 0x01;                                       // a byte of FNV-1a's offset basis
    check("not when a fixed byte differs", find_name_cache(g_code, kCodeSize, lo, hi, &found) == 0);
    make_code(g_code, tb, tb + kNcSize);
    check("not when the map would run past the data section",
          find_name_cache(g_code, kCodeSize, lo, hi - 8, &found) == 0);
    make_code(g_code + kCodeSize, tb, tb + kNcSize);
    check("two places naming it count as two (the DLL then leaves it alone)",
          find_name_cache(g_code, sizeof(g_code), lo, hi, &found) == 2);

    std::printf("\n-- the crash in the dump, reproduced --\n");
    // Never deleted: an insert dies inside it.
    auto* doomed = new FakeCache;
    Names closed = make_names(512, 1);
    insert_faults(*doomed, closed, 0, 512);
    check("512 names fill 512 buckets", doomed->map.size() == 512 && doomed->map.bucket_count() == 512);
    free_names(closed);                                       // the Lua state that owned them closed
    Names after = make_names(1, 2, 20);                       // another length: no compare on the way in
    check("the 513th name grows the table, re-hashes a freed key and faults",
          insert_faults(*doomed, after, 0, 1));

    std::printf("\n-- the repair --\n");
    auto* repaired = new FakeCache;                           // leaked, like the nodes it drops
    Names gone = make_names(512, 3);
    insert_faults(*repaired, gone, 0, 512);
    const std::wstring* handedOut = &repaired->map.find(name_at(gone, 7))->second;
    free_names(gone);
    check("drops every name", nc_purge(base_of(*repaired)) == 512);
    check("the map is empty", repaired->map.empty() && repaired->map.begin() == repaired->map.end());
    check("a string handed out before is still there (nodes are leaked, not freed)", *handedOut == L"wide");
    Names next = make_names(2000, 4);
    check("2000 new names grow it to 2048 buckets without touching a freed key",
          !insert_faults(*repaired, next, 0, 2000) && repaired->map.bucket_count() >= 2048);
    check("and every one of them is found", repaired->map.size() == 2000 && all_found(*repaired, next));

    std::printf("\n-- refusals --\n");
    alignas(16) static unsigned char unused[kNcEnd] = {};
    check("never used (no sentinel yet): nothing to do, nothing written",
          nc_purge(reinterpret_cast<uintptr_t>(unused)) == 0 && unused[kNcSize] == 0);
    auto* bent = new FakeCache;
    Names bentNames = make_names(50, 5);
    insert_faults(*bent, bentNames, 0, 50);
    const uintptr_t bb = base_of(*bent);
    auto* sentinel = *reinterpret_cast<uintptr_t**>(bb + kNcHead);
    const uintptr_t prev = sentinel[1];
    sentinel[1] = reinterpret_cast<uintptr_t>(sentinel);
    check("a list that does not come back to its sentinel: left alone",
          nc_purge(bb) == -2 && bent->map.size() == 50);
    sentinel[1] = prev;
    auto* mask = reinterpret_cast<size_t*>(bb + kNcMask);
    *mask += 1;
    check("a mask that is not the bucket count less one: left alone",
          nc_purge(bb) == -2 && bent->map.size() == 50);
    *mask -= 1;
    check("put right, it is emptied", nc_purge(bb) == 50 && bent->map.empty());

    std::printf("\n-- the installed UE4SS.dll --\n");
    wchar_t path[MAX_PATH] = {};
    const wchar_t* dll = L"D:\\SteamLibrary\\steamapps\\common\\RetroRewind\\RetroRewind\\Binaries\\Win64\\ue4ss\\UE4SS.dll";
    if (GetEnvironmentVariableW(L"RT_UE4SS_DLL", path, MAX_PATH)) dll = path;
    HMODULE image = LoadLibraryExW(dll, nullptr, LOAD_LIBRARY_AS_IMAGE_RESOURCE);
    if (!image)
    {
        std::printf("  SKIP  not found (set RT_UE4SS_DLL to its path)\n");
    }
    else
    {
        const uintptr_t mb = reinterpret_cast<uintptr_t>(image) & ~uintptr_t(3);
        Range text, data;
        int count = -1;
        uintptr_t lock = 0;
        if (module_section(mb, ".text", text) && module_section(mb, ".data", data))
            count = find_name_cache(reinterpret_cast<const uint8_t*>(text.lo), text.hi - text.lo,
                                    data.lo, data.hi, &lock);
        const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(
            mb + reinterpret_cast<const IMAGE_DOS_HEADER*>(mb)->e_lfanew);
        const DWORD stamp = nt->FileHeader.TimeDateStamp;
        std::printf("  (build %08lX: %d place(s), lock at +0x%llX)\n", static_cast<unsigned long>(stamp), count,
                    static_cast<unsigned long long>(count > 0 ? lock - mb : 0));
        if (count == 0)
            std::printf("  WARN  the repair finds nothing on this UE4SS build - it will stay off\n");
        else
            check("exactly one place names the cache", count == 1);
        if (stamp == 0x69C69775)
            check("on the dump's build, at the address read off the dump (+0xF41118)",
                  count == 1 && lock - mb == 0xF41118);
        FreeLibrary(image);
    }

    std::printf("\n-- crash report folders (rt_crashes_since) --\n");
    FILETIME epoch;
    epoch.dwLowDateTime  = static_cast<DWORD>(116444736000000000ULL & 0xFFFFFFFFu);
    epoch.dwHighDateTime = static_cast<DWORD>(116444736000000000ULL >> 32);
    check("a FILETIME at 1970-01-01 is Unix second 0", unix_seconds(epoch) == 0);
    wchar_t tmp[MAX_PATH], dir[MAX_PATH], sub[MAX_PATH];
    GetTempPathW(MAX_PATH, tmp);
    swprintf_s(dir, MAX_PATH, L"%sRT_crashes_%lu", tmp, GetCurrentProcessId());
    CreateDirectoryW(dir, nullptr);
    int64_t newest = -1;
    check("an empty folder: no crash", count_crash_folders(dir, 0, &newest) == 0 && newest == 0);
    const int64_t now = static_cast<int64_t>(time(nullptr));
    swprintf_s(sub, MAX_PATH, L"%s\\UECC-Windows-TEST_0000", dir);
    CreateDirectoryW(sub, nullptr);
    check("a report made now counts as one since a minute ago",
          count_crash_folders(dir, now - 60, &newest) == 1 && newest >= now - 5 && newest <= now + 5);
    check("and not as one since an hour from now", count_crash_folders(dir, now + 3600, &newest) == 0);
    check("a report whose process cannot be read counts for any process",
          count_crash_folders(dir, now - 60, &newest, 4242) == 1);
    wchar_t xml[MAX_PATH];
    swprintf_s(xml, MAX_PATH, L"%s\\UECC-Windows-TEST_0000\\CrashContext.runtime-xml", dir);
    {
        HANDLE f = CreateFileW(xml, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
        const char body[] = "<?xml version=\"1.0\"?>\r\n<FGenericCrashContext>\r\n<ProcessId>37636</ProcessId>\r\n";
        DWORD put = 0;
        WriteFile(f, body, static_cast<DWORD>(sizeof(body) - 1), &put, nullptr);
        CloseHandle(f);
    }
    check("the dump's own report (pid 37636) is about pid 37636", count_crash_folders(dir, now - 60, &newest, 37636) == 1);
    check("and not about the other copy's pid", count_crash_folders(dir, now - 60, &newest, 4242) == 0);
    DeleteFileW(xml);
    swprintf_s(sub, MAX_PATH, L"%s\\not-a-folder.txt", dir);
    CloseHandle(CreateFileW(sub, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr));
    check("files are not reports", count_crash_folders(dir, now - 60, &newest) == 1);
    DeleteFileW(sub);
    swprintf_s(sub, MAX_PATH, L"%s\\UECC-Windows-TEST_0000", dir);
    RemoveDirectoryW(sub);
    RemoveDirectoryW(dir);
    check("a folder that does not exist: no crash", count_crash_folders(dir, 0, &newest) == 0);

    std::printf("\n-- is that copy still running (rt_pid_alive) --\n");
    check("this process is a running copy of itself", pid_alive(GetCurrentProcessId()) == 1);
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    wchar_t cmd[] = L"cmd.exe /c exit 0";
    if (CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi))
    {
        WaitForSingleObject(pi.hProcess, 10000);
        check("a process that has exited is not", pid_alive(pi.dwProcessId) == 0);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    check("a running process of another program is not", pid_alive(GetCurrentProcessId() == 4 ? 8 : 4) != 1);
    check("nonsense ids are not", pid_alive(0) == 0 && pid_alive(-5) == 0);

    std::printf("\n%s\n", g_failures ? "SOME CHECKS FAILED" : "All name-cache checks passed.");
    return g_failures ? 1 : 0;
}
