#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "EmbeddedData.h"
#include <stdbool.h>
#include <string.h>

static BunEmbeddedStatus readPayload(const uint8_t* header, size_t available,
    const uint8_t** outData, size_t* outLength)
{
    if (available < sizeof(uint64_t)) return BUN_EMBEDDED_INVALID;
    uint64_t length = 0;
    for (unsigned i = 0; i < 8; i++) length |= (uint64_t)header[i] << (8 * i);
    if (!length) return BUN_EMBEDDED_ABSENT;
    if (length > available - sizeof(uint64_t)) return BUN_EMBEDDED_INVALID;
    *outData = header + sizeof(uint64_t);
    *outLength = (size_t)length;
    return BUN_EMBEDDED_READY;
}

#if defined(__APPLE__) || defined(__linux__) || defined(__FreeBSD__)
/* The executable writer reserves a page-aligned section for this locator.
   Mach-O stores a payload length here; ELF stores its link-time address. */
typedef struct {
    uint64_t locator;
    uint8_t data[];
} __attribute__((aligned(16 * 1024))) BunEmbeddedMarker;

#if defined(__APPLE__)
volatile BunEmbeddedMarker BUN_COMPILED __attribute__((section("__BUN,__bun"), used)) = { 0 };
#else
volatile BunEmbeddedMarker BUN_COMPILED __attribute__((section(".bun"), used)) = { 0 };
#endif
#endif

#if defined(__linux__) || defined(__FreeBSD__)
#include <link.h>
typedef __typeof__(((struct dl_phdr_info*)0)->dlpi_phdr) ProgramHeaders;

typedef struct {
    uint64_t locator;
    const uint8_t* data;
    size_t length;
    BunEmbeddedStatus status;
} ElfSearch;

static bool segmentRange(const struct dl_phdr_info* image, ProgramHeaders segment,
    uintptr_t* outStart, size_t* outSize, bool fileBacked)
{
    const uint64_t size = fileBacked ? segment->p_filesz : segment->p_memsz;
    if (segment->p_type != PT_LOAD || !(segment->p_flags & PF_R)
        || segment->p_vaddr > UINTPTR_MAX - image->dlpi_addr)
        return false;
    const uintptr_t start = image->dlpi_addr + segment->p_vaddr;
    if (size > UINTPTR_MAX - start) return false;
    *outStart = start;
    *outSize = (size_t)size;
    return true;
}

static int findElfPayload(struct dl_phdr_info* image, size_t infoSize, void* context)
{
    (void)infoSize;
    ElfSearch* search = context;
    const uintptr_t marker = (uintptr_t)&BUN_COMPILED;
    bool containsMarker = false;
    for (size_t i = 0; i < image->dlpi_phnum; i++) {
        uintptr_t start;
        size_t size;
        if (segmentRange(image, &image->dlpi_phdr[i], &start, &size, false)
            && size >= sizeof(uint64_t) && marker >= start && marker - start <= size - sizeof(uint64_t)) {
            containsMarker = true;
            break;
        }
    }
    if (!containsMarker) return 0;
    if (search->locator > UINTPTR_MAX - image->dlpi_addr) return 1;
    const uintptr_t target = image->dlpi_addr + search->locator;
    for (size_t i = 0; i < image->dlpi_phnum; i++) {
        uintptr_t start;
        size_t size;
        if (!segmentRange(image, &image->dlpi_phdr[i], &start, &size, true)
            || target < start || target - start >= size)
            continue;
        search->status = readPayload((const uint8_t*)target, size - (target - start), &search->data, &search->length);
        if (search->status == BUN_EMBEDDED_ABSENT) search->status = BUN_EMBEDDED_INVALID;
        return 1;
    }
    return 1;
}

#elif defined(__APPLE__)
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
extern const struct mach_header_64 _mh_execute_header;

#elif defined(_WIN32)
#include <windows.h>
#include <winnt.h>

static bool readableImageRange(const uint8_t* image, size_t offset, size_t length)
{
    const uintptr_t base = (uintptr_t)image;
    if (offset > UINTPTR_MAX - base || length > UINTPTR_MAX - (base + offset)) return false;
    uintptr_t cursor = base + offset;
    const uintptr_t end = cursor + length;
    while (cursor < end) {
        MEMORY_BASIC_INFORMATION region;
        if (!VirtualQuery((const void*)cursor, &region, sizeof(region))
            || region.AllocationBase != image || region.State != MEM_COMMIT
            || (region.Protect & (PAGE_GUARD | PAGE_NOACCESS)))
            return false;
        switch (region.Protect & 0xff) {
        case PAGE_READONLY:
        case PAGE_READWRITE:
        case PAGE_WRITECOPY:
        case PAGE_EXECUTE_READ:
        case PAGE_EXECUTE_READWRITE:
        case PAGE_EXECUTE_WRITECOPY:
            break;
        default:
            return false;
        }
        const uintptr_t regionBase = (uintptr_t)region.BaseAddress;
        if (region.RegionSize > UINTPTR_MAX - regionBase) return false;
        const uintptr_t next = regionBase + region.RegionSize;
        if (next <= cursor) return false;
        cursor = next;
    }
    return true;
}

static BunEmbeddedStatus pePayload(const uint8_t** outData, size_t* outLength)
{
    const uint8_t* base = (const uint8_t*)GetModuleHandleW(NULL);
    if (!base || !readableImageRange(base, 0, sizeof(IMAGE_DOS_HEADER))) return BUN_EMBEDDED_INVALID;
    const IMAGE_DOS_HEADER* dos = (const IMAGE_DOS_HEADER*)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0
        || (size_t)dos->e_lfanew < sizeof(IMAGE_DOS_HEADER))
        return BUN_EMBEDDED_INVALID;
    const size_t ntOffset = (size_t)dos->e_lfanew;
    if (!readableImageRange(base, ntOffset, sizeof(IMAGE_NT_HEADERS))) return BUN_EMBEDDED_INVALID;
    const IMAGE_NT_HEADERS* nt = (const IMAGE_NT_HEADERS*)(base + ntOffset);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC
        || nt->FileHeader.SizeOfOptionalHeader < sizeof(IMAGE_OPTIONAL_HEADER64))
        return BUN_EMBEDDED_INVALID;
    const size_t imageSize = nt->OptionalHeader.SizeOfImage;
    const size_t headersSize = nt->OptionalHeader.SizeOfHeaders;
    if (headersSize > imageSize || ntOffset > headersSize || sizeof(*nt) > headersSize - ntOffset)
        return BUN_EMBEDDED_INVALID;
    const size_t sectionOffset = ntOffset + offsetof(IMAGE_NT_HEADERS, OptionalHeader) + nt->FileHeader.SizeOfOptionalHeader;
    const size_t count = nt->FileHeader.NumberOfSections;
    if (sectionOffset > headersSize || count > (headersSize - sectionOffset) / sizeof(IMAGE_SECTION_HEADER)
        || !readableImageRange(base, sectionOffset, count * sizeof(IMAGE_SECTION_HEADER)))
        return BUN_EMBEDDED_INVALID;
    const IMAGE_SECTION_HEADER* sections = (const IMAGE_SECTION_HEADER*)(base + sectionOffset);
    static const char name[IMAGE_SIZEOF_SHORT_NAME] = ".bun";
    const IMAGE_SECTION_HEADER* found = NULL;
    for (size_t i = 0; i < count; i++) {
        if (memcmp(sections[i].Name, name, sizeof(name)) != 0) continue;
        if (found) return BUN_EMBEDDED_INVALID;
        found = &sections[i];
    }
    if (!found) return BUN_EMBEDDED_ABSENT;
    const size_t offset = found->VirtualAddress;
    size_t available = found->SizeOfRawData;
    if (found->Misc.VirtualSize && found->Misc.VirtualSize < available) available = found->Misc.VirtualSize;
    if (offset > imageSize || available > imageSize - offset || !readableImageRange(base, offset, available))
        return BUN_EMBEDDED_INVALID;
    const BunEmbeddedStatus status = readPayload(base + offset, available, outData, outLength);
    return status == BUN_EMBEDDED_ABSENT ? BUN_EMBEDDED_INVALID : status;
}
#endif

BunEmbeddedStatus bun_embedded_data(const uint8_t** outData, size_t* outLength)
{
    *outData = NULL;
    *outLength = 0;
#if defined(__linux__) || defined(__FreeBSD__)
    const uint64_t locator = BUN_COMPILED.locator;
    if (!locator) return BUN_EMBEDDED_ABSENT;
    ElfSearch search = { .locator = locator, .status = BUN_EMBEDDED_INVALID };
    dl_iterate_phdr(findElfPayload, &search);
    if (search.status == BUN_EMBEDDED_READY) {
        *outData = search.data;
        *outLength = search.length;
    }
    return search.status;
#elif defined(__APPLE__)
    if (!BUN_COMPILED.locator) return BUN_EMBEDDED_ABSENT;
    unsigned long size = 0;
    const uint8_t* section = getsectiondata(&_mh_execute_header, "__BUN", "__bun", &size);
    if (section != (const uint8_t*)&BUN_COMPILED) return BUN_EMBEDDED_INVALID;
    unsigned long segmentSize = 0;
    const uint8_t* segment = getsegmentdata(&_mh_execute_header, "__BUN", &segmentSize);
    const uintptr_t start = (uintptr_t)segment;
    const uintptr_t address = (uintptr_t)section;
    if (!segment || segmentSize > UINTPTR_MAX - start || address < start
        || address - start > segmentSize || size > segmentSize - (address - start))
        return BUN_EMBEDDED_INVALID;
    return readPayload(section, size, outData, outLength);
#elif defined(_WIN32)
    return pePayload(outData, outLength);
#else
    return BUN_EMBEDDED_ABSENT;
#endif
}
