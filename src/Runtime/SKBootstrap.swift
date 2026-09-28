/// Main-queue entry point reached from the C constructor in `Bootstrap.c`.
///
/// It stays minimal: no UIKit objects, no file access, no archive library
/// initialization, no networking. Waiting for UIKit, scene observation and trigger
/// registration belong to the runtime coordinators, because the constructor can run
/// before UIApplication or any scene exists.
@_cdecl("SandboxArkBootstrap")
func SandboxArkBootstrap() {
}
