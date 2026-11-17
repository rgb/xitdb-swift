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

        /// The hashers' second names stand where a bare `SHA256` or
        /// `Insecure.SHA1` does not compile in this file, since nothing
        /// there tells this module's from CryptoKit's: a value that is the
        /// type, a type annotation, a type alias.
        @Test func theSecondNamesStandWhereABareNameDoesNotCompile() throws {
            let hasher = SHA256KeyHashing.self
            let annotated: SHA1KeyHashing.Type = SHA1KeyHashing.self
            typealias Hasher = SHA256KeyHashing
            #expect(hasher == XitDBHashing.SHA256.self)
            #expect(annotated == XitDBHashing.Insecure.SHA1.self)
            #expect(Hasher.size == 32)

            let database = try Database(creating: MemoryStorage(), hashing: hasher)
            #expect(database.header.hashSize == 32)
            let old = try Database(creating: MemoryStorage(), hashing: annotated)
            #expect(old.header.hashSize == 20)
            // And each is this module's hash, which is CryptoKit's digest.
            #expect(Hasher.keyHash(of: "alice") == Array(CryptoKit.SHA256.hash(data: Array("alice".utf8))))
            #expect(
                SHA1KeyHashing.keyHash(of: "alice") == Array(CryptoKit.Insecure.SHA1.hash(data: Array("alice".utf8))))
        }
    }
#endif
