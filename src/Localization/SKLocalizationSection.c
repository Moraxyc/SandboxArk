#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <stdint.h>

const void *SandboxArkLocalizationSection(unsigned long *size) {
    Dl_info image = {0};
    if (dladdr((const void *)&SandboxArkLocalizationSection, &image) == 0 || image.dli_fbase == NULL) {
        return NULL;
    }

    return getsectiondata(
        (const struct mach_header_64 *)image.dli_fbase,
        "__DATA",
        "__sk_i18n",
        size
    );
}
