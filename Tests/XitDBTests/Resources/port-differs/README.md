# Reads the Swift port corrects

The user decided that the port corrects these from the start (findings 8, 9, 21 and 26 in `director/zig-findings.md`).
So they aren't in `tests/valid/` or the fixtures, and `run` refuses to run a script that uses them unless it's given
`--allow-port-differences`.

Each has two scripts, which differ only in what they expect. `<name>.zig.json` says what the Zig original does, and
`<name>.port.json` says what the port does, which for all but `iterator-past-slice` is also what the branch with the fixes
does so far. On the Zig original the
first passes and the second fails, and `check.sh` holds it to that, so it notices if the original changes.
`second-zig.sh` reports which of the two each Zig checkout does.

| Scripts | Finding | Zig | Port |
|---|---|---|---|
| `none-into-buffer` | 8 | a slot set to nothing, read into a buffer that isn't empty, raises `EndOfStream` | it's empty |
| `stream-none` | 21 | streaming a slot set to nothing raises `UnexpectedTag` | it's an empty stream |
| `stream-short-no-position` | 9 | streaming a short value from a cursor with no position raises `ExpectedSlotPosition` | it gives the value |
| `stream-short-overwritten` | 9 | streaming a short value after its slot was overwritten gives the old length of the new bytes | it gives the cursor's value |
| `iterator-past-slice` | 26 | an iterator on a sliced array list with an unwritten element gives an element past the end | it stops at the end, and agrees with `array_list_get` |
