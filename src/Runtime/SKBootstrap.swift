/// Main-queue entry point reached from the C constructor in `Bootstrap.c`. It stays
/// minimal — no UIKit objects, file access, archive initialization or networking; waiting
/// and registration belong to the runtime coordinators.
@_cdecl("SandboxArkBootstrap")
func SandboxArkBootstrap() {
    Task { @MainActor in
        SKSceneCoordinator.shared.start()
    }
}
