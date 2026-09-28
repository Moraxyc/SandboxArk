/// Host write barrier. Without a verified lease the restore UI stays disabled: a
/// generic injected host cannot prove that its writers, caches and open handles are
/// quiet.
enum SKHostQuiescenceGate {
}
