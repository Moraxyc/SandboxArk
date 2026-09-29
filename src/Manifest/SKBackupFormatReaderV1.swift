/// Checks format identity before SandboxArk/1-specific fields are interpreted.
enum SKBackupFormatReaderV1 {
    /// The format-identity boundary. `format` and `formatVersion` are decided before any
    /// other manifest field is interpreted, so an archive written by a newer major version
    /// is reported as unsupported with an action the user can take, instead of as damage.
    ///
    static func checkIdentity(_ value: SKJSONValue) throws {
        let root = try SKJSONObjectReader(value, label: "manifest")
        guard try root.string("format", maxBytes: 64) == SKManifest.format else {
            throw SKManifestDocument.malformed("unknown format")
        }
        guard try root.integer("formatVersion") == Int64(SKManifest.formatVersion) else {
            throw SKError(code: .manifestUnsupportedVersion,
                          stage: "backupFormat",
                          userAction: "Update SandboxArk, or use a backup written by formatVersion "
                              + "\(SKManifest.formatVersion).",
                          reason: "the archive is not a supported format version")
        }
    }
}
