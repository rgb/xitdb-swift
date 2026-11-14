// The hashing module's page: in a file that imports CryptoKit as well, a bare
// `SHA256` is whichever one the code around it can use. Only where CryptoKit
// exists; that it does not compile where nothing tells the two apart, as in a
// type annotation, a test cannot show.

#if canImport(CryptoKit)
    import CryptoKit
    import Testing
    import XitDB
    import XitDBHashing

    @Suite("The hashing module beside CryptoKit") struct HashingBesideCryptoKitExamples {
        @Test func aBareNameIsTheOneTheCodeCanUse() throws {
            // keyHash(of:) is this module's; hash(data:) is CryptoKit's.
            let byKey = SHA256.keyHash(of: "alice")
            let digest = Array(SHA256.hash(data: Array("alice".utf8)))
            #expect(byKey == XitDBHashing.SHA256.keyHash(of: "alice"))
            #expect(digest == Array(CryptoKit.SHA256.hash(data: Array("alice".utf8))))
            #expect(byKey == digest)

            // A hasher's place takes this module's.
            let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
            #expect(database.header.hashSize == 32)
        }
    }
#endif
