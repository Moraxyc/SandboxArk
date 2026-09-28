/// Host side of the restore write barrier: block business writes inside the selected
/// scope, drain in-flight writers and SQLite handles, and after a commit reload caches
/// and reopen handles before the lease is released.
///
/// Controlled restore is 0.2.0 scope; until this adapter exists, restore stays disabled
/// because no host can prove its writers are stopped.
enum SKTestHostQuiescenceAdapter {
}
