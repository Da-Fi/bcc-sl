# bcc-sl-db

Database operations for Bcc SL.

A Bcc node has a database that is used to store:

  * The blocks that make up the blockchain and a block index to make queries on
    the blocks easier and more efficient.
  * UTXOs (unspent transaction outputs).
  * LRC (leaders and richmen computation) data required for Proof-of-Stake.
  * Other miscellaneous data.

A bcc node stores its data in a [RocksDB] database. Since [RocksDB] is
written in C++, it is accessed from Haskell via the [rocksdb-haskell-ng] library.

In addition, this library provides a pure database interface built on top
of `Data.Map` that mirrors the RocksDB data base so that one can be tested
against the other.


[RocksDB]: http://rocksdb.org/
[rocksdb-haskell-ng]: https://github.com/The-Blockchain-Company/rocksdb-haskell-ng
