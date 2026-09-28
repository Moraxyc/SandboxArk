/// SandboxArk/1 wire-format identity and container layout. `formatVersion` tracks the
/// archive contract, independent of the product version, so a format bump needs no release.
enum SKManifest {
    static let format = "SandboxArk"
    static let formatVersion = 1
    static let manifestPath = "manifest.json"
    static let hashIndexPath = "hashes.json"
    static let homeRoot = "data/home"
    static let appGroupsRoot = "app-groups"
}
