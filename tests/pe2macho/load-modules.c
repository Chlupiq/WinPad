/* Loads Wine modules wrapped by tools/pe2macho with dlopen and checks what
 * dyld made of them: the PE headers sit at _PREFIX_image, every base-relocated
 * pointer holds image + its target RVA, and executable sections are mapped
 * read+execute (not writable).
 *
 * Then it adopts each image the way Wine's loader will (pe_adopt.h): ImageBase
 * holds the image's address, SizeOfImage is mapped, and every export found
 * through the PE export directory, as Wine's GetProcAddress finds it, is the
 * address dyld gives the export's symbol.
 *
 * Usage: load-modules LIST
 *   LIST has one module per line: "DYLIB PREFIX RELOCS", where RELOCS is the
 *   output of pe2macho.py --relocs ("RVA TARGET_RVA" lines, hex).
 */
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "pe_adopt.h"

#define IMAGE_SCN_MEM_EXECUTE 0x20000000u

static int check_protection(const char *dylib, const uint8_t *image) {
    uint32_t pe = *(const uint32_t *)(image + 0x3c);
    if (memcmp(image, "MZ", 2) || memcmp(image + pe, "PE\0\0", 4)) {
        fprintf(stderr, "%s: no PE headers at the image symbol\n", dylib);
        return 1;
    }
    uint16_t nsections = *(const uint16_t *)(image + pe + 6);
    uint16_t optsize = *(const uint16_t *)(image + pe + 20);
    const uint8_t *table = image + pe + 24 + optsize;
    int errors = 0;
    for (unsigned i = 0; i < nsections; i++) {
        const uint8_t *s = table + 40 * i;
        uint32_t rva = *(const uint32_t *)(s + 12), flags = *(const uint32_t *)(s + 36);
        mach_vm_address_t addr = (mach_vm_address_t)(image + rva);
        mach_vm_size_t size;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object;
        if (mach_vm_region(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                           (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS ||
            addr > (mach_vm_address_t)(image + rva)) {
            fprintf(stderr, "%s: section %.8s is not mapped\n", dylib, (const char *)s);
            errors++;
            continue;
        }
        vm_prot_t want = (flags & IMAGE_SCN_MEM_EXECUTE) ? (VM_PROT_READ | VM_PROT_EXECUTE)
                                                         : (VM_PROT_READ | VM_PROT_WRITE);
        if (info.protection != want) {
            fprintf(stderr, "%s: section %.8s has protection %d, expected %d\n", dylib,
                    (const char *)s, info.protection, want);
            errors++;
        }
    }
    return errors;
}

static int mapped(const uint8_t *addr) {
    mach_vm_address_t a = (mach_vm_address_t)addr;
    mach_vm_size_t size;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object;
    return mach_vm_region(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                          &count, &object) == KERN_SUCCESS && a <= (mach_vm_address_t)addr;
}

/* Adopts the image and resolves its exports through the PE export directory.
 * Returns the number of errors; counts the exports in *exports. */
static int check_adopt(const char *dylib, void *h, const char *prefix, unsigned long *exports) {
    /* pe2macho derives the prefix from the DLL name; so does pe_adopt_prefix */
    char name[256], want[300];
    const char *slash = strrchr(dylib, '/');
    snprintf(name, sizeof(name), "%s", slash ? slash + 1 : dylib);
    char *ext = strstr(name, ".dylib");
    if (ext) *ext = 0;
    pe_adopt_prefix(name, want, sizeof(want));
    if (strcmp(want, prefix)) {
        fprintf(stderr, "%s: pe_adopt_prefix gives %s, pe2macho %s\n", dylib, want, prefix);
        return 1;
    }
    PeAdopted m;
    char err[300];
    if (pe_adopt(h, prefix, &m, err, sizeof(err))) {
        fprintf(stderr, "%s: %s\n", dylib, err);
        return 1;
    }
    if (!mapped(m.base + m.size - 1)) {
        fprintf(stderr, "%s: SizeOfImage %#zx reaches past the dylib\n", dylib, m.size);
        return 1;
    }
    const uint8_t *opt = m.base + m.nt_offset + 24;
    uint32_t dir = *(const uint32_t *)(opt + 112), dir_size = *(const uint32_t *)(opt + 116);
    if (!dir_size) return 0;
    const uint32_t *ed = (const uint32_t *)(m.base + dir);
    uint32_t nnames = ed[6];
    const uint32_t *funcs = (const uint32_t *)(m.base + ed[7]), *names = (const uint32_t *)(m.base + ed[8]);
    const uint16_t *ordinals = (const uint16_t *)(m.base + ed[9]);
    int errors = 0;
    for (uint32_t i = 0; i < nnames; i++) {
        uint32_t rva = funcs[ordinals[i]];
        if (rva >= dir && rva < dir + dir_size) continue; /* forwarder */
        char sym[512];
        snprintf(sym, sizeof(sym), "%s_export_%s", prefix, (const char *)(m.base + names[i]));
        void *addr = dlsym(h, sym);
        if (addr != m.base + rva) {
            if (errors < 5)
                fprintf(stderr, "%s: export %s is at image + %#x, symbol %s at %p\n", dylib,
                        (const char *)(m.base + names[i]), rva, sym, addr);
            errors++;
        }
        (*exports)++;
    }
    return errors;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s LIST\n", argv[0]);
        return 2;
    }
    FILE *list = fopen(argv[1], "r");
    if (!list) {
        perror(argv[1]);
        return 2;
    }
    char dylib[1024], prefix[256], relocs[1024];
    unsigned modules = 0, failed = 0;
    unsigned long pointers = 0, exports = 0;
    while (fscanf(list, "%1023s %255s %1023s", dylib, prefix, relocs) == 3) {
        modules++;
        void *h = dlopen(dylib, RTLD_NOW | RTLD_LOCAL);
        if (!h) {
            fprintf(stderr, "%s\n", dlerror());
            failed++;
            continue;
        }
        char sym[300];
        snprintf(sym, sizeof(sym), "%s_image", prefix);
        const uint8_t *image = dlsym(h, sym);
        if (!image) {
            fprintf(stderr, "%s: no symbol %s\n", dylib, sym);
            failed++;
            continue;
        }
        int errors = check_protection(dylib, image);
        FILE *rf = fopen(relocs, "r");
        unsigned long rva, target;
        while (rf && fscanf(rf, "%lx %lx", &rva, &target) == 2) {
            uint64_t value;
            memcpy(&value, image + rva, 8);
            if (value != (uint64_t)(uintptr_t)(image + target)) {
                if (errors < 5)
                    fprintf(stderr, "%s: pointer at RVA %#lx is image + %#llx, expected + %#lx\n", dylib,
                            rva, (unsigned long long)(value - (uint64_t)(uintptr_t)image), target);
                errors++;
            }
            pointers++;
        }
        if (!rf) {
            perror(relocs);
            errors++;
        } else {
            fclose(rf);
        }
        errors += check_adopt(dylib, h, prefix, &exports);
        if (errors)
            failed++;
    }
    fclose(list);
    printf("%u Wine modules loaded as dylibs, %lu pointers rebased by dyld, %u failed\n", modules,
           pointers, failed);
    printf("%lu exports found through the adopted PE images\n", exports);
    return failed || !modules;
}
