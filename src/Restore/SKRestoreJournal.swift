/// Durable per-item journal. Intent, old and new fingerprints and the snapshot rollback
/// reference are persisted before a write, so an interrupted restore stays inspectable
/// and idempotent.
enum SKRestoreJournal {
}
