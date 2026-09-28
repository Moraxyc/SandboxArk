/// A main database plus its `-wal`, `-shm` and `-journal` sidecars, treated as one
/// unit for hashing, packaging and restore decisions, because a database copied
/// without its WAL loses committed transactions.
enum SKSQLiteGroup {
}
