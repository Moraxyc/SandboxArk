/// Strict SandboxArk/1 reader: validates the manifest, hash index, path rules and
/// member correspondence, then maps to the normalized model. It never applies restore
/// operations, so a new format version adds a reader instead of spreading version
/// checks through the restore path.
enum SKBackupFormatReaderV1 {
}
