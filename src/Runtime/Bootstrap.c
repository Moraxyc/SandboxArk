#include <dispatch/dispatch.h>

extern void SandboxArkBootstrap(void);

static void SandboxArkBootstrapOnMain(void *context) {
    (void)context;
    SandboxArkBootstrap();
}

__attribute__((constructor)) static void SandboxArkConstructor(void) {
    dispatch_async_f(dispatch_get_main_queue(), NULL, SandboxArkBootstrapOnMain);
}
