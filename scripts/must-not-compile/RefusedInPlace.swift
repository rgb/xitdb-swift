// What must not compile, fifth file: a change in place of the view a file
// storage reads through.
//
// A file storage holds the view its reads go through in a property whose
// run-time check of exclusive access is off, which is what makes a read
// through a mapped storage cost what a read through its snapshot costs. The
// check is sound to leave out because nothing can be written against that
// property but a load of the whole view and a store of a whole new one:
// `FileMapView` has no member that can be changed. This file holds that by
// the compiler. `scripts/must-not-compile.sh` type-checks it against the
// built library, as a file of the library itself would be checked (the
// type is the library's own, so the import is a testable one): each marked
// line must be refused, with the compiler's words that follow its mark, and
// nothing else may be refused.
//
// If a line here ever compiles, the view has become changeable in place,
// and the comment beside `FileStorage`'s two unchecked properties is no
// longer true.

@testable import XitDB

func refusedInPlace(view: inout FileMapView, segment: MappedSegment) {
    view.segments.append(segment)  // must not compile: 'segments' is a 'let' constant
    view.segments[0] = segment  // must not compile: 'segments' is a 'let' constant
    view.segments.removeAll()  // must not compile: 'segments' is a 'let' constant
    view.segmentSize = 4096  // must not compile: 'segmentSize' is a 'let' constant
}

// What takes their place: a new view, which the storage stores whole.

func acceptedWhole(view: inout FileMapView, segment: MappedSegment) {
    view = view.with(segment, at: 0)
    view = FileMapView(segmentSize: view.segmentSize)
}
