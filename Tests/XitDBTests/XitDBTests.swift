import Testing

@testable import XitDB

@Test func internalDeclarationsAreReachableFromTests() {
    #expect(moduleName == "XitDB")
}
