/* Loads Wine modules wrapped by tools/pe2macho with dlopen and checks what
 * dyld made of them: the PE headers sit at _PREFIX_image, every base-relocated
 * pointer holds image + its target RVA, and executable sections are mapped
 * read+execute (not writable).
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
    unsigned long pointers = 0;
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
        if (errors)
            failed++;
    }
    fclose(list);
    printf("%u Wine modules loaded as dylibs, %lu pointers rebased by dyld, %u failed\n", modules,
           pointers, failed);
    return failed || !modules;
}
