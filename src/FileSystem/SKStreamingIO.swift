/// Bounded-buffer file reads for hashing and archiving.
///
/// Files are never loaded whole into memory, and the buffer budget is fixed rather
/// than derived from file size, so peak memory stays flat for multi-gigabyte inputs.
enum SKStreamingIO {
}
