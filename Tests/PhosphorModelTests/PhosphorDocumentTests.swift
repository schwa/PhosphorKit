import Foundation
import Testing
@testable import PhosphorModel

@Suite struct PhosphorDocumentTests {
    @Test func roundTripsThroughJSON() throws {
        let config = PhosphorConfiguration(output: "image")
        let doc = PhosphorDocument(configuration: config, source: "kernel void image() {}")
        let data = try doc.jsonData()
        let decoded = try PhosphorDocument(jsonData: data)
        #expect(decoded == doc)
        #expect(decoded.version == PhosphorDocument.currentVersion)
    }

    @Test func defaultsToCurrentVersion() {
        let doc = PhosphorDocument(configuration: PhosphorConfiguration(output: "image"), source: "")
        #expect(doc.version == 1)
    }

    @Test func jsonHasExpectedTopLevelKeys() throws {
        let doc = PhosphorDocument(configuration: PhosphorConfiguration(output: "image"), source: "x")
        let object = try JSONSerialization.jsonObject(with: doc.jsonData()) as? [String: Any]
        let keys = Set(object?.keys.map { String($0) } ?? [])
        #expect(keys == ["version", "configuration", "source"])
    }
}
