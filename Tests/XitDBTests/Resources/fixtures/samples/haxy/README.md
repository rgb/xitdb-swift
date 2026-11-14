# Databases written by haxy

Four databases that haxy and xit wrote through the original at `89da8e7`, in version 2 with a hash size of 20 and the
hash ID `sha1`. Everything in them is throwaway test data. They're samples of real use, not byte-identity fixtures: no
script made them, and nothing is to write them again byte for byte. What's to agree is how they read.

`fixtures.sh` copies them to `fixtures/samples/haxy/`, with `<name>.txt` beside each, which is what `dump` built against
the commit the fixtures follow prints for it: a listing that doesn't depend on where things are in the file. A port
that reads one and prints it the same way should get the same text. `SHA256SUMS` has their SHA-256, which
`fixtures.sh --check` holds them to.

| Database | Bytes | Root | What's in it |
|---|---|---|---|
| `admin.db` | 13118 | a history of 6 moments | hash maps, sorted maps and sets, counted hash maps, hash sets, array lists, byte records and integers |
| `project-repo.db` | 22928 | a history of 4 moments | the same kinds |
| `user-repo.db` | 15852 | a history of 5 moments | the same kinds |
| `users-index.db` | 1535 | a hash map | a hash map, a sorted set and an integer |
