/// Host side of the restore write barrier: block business writes inside the selected scope,
/// drain in-flight writers and SQLite handles, then reload caches and reopen handles before
/// the lease is released. Controlled restore is 0.2.0 scope.
enum SKTestHostQuiescenceAdapter {
}
