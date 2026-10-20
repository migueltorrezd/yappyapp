import Foundation
import Testing

// Release metadata that lives outside Swift (provenance, cask, packaging
// script) must agree. These read the repository files next to this test.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func projectFile(_ path: String) throws -> String {
    try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
}

private func provenanceApp() throws -> [String: Any] {
    let data = try Data(contentsOf: projectRoot.appendingPathComponent("docs/RELEASE_PROVENANCE.json"))
    let object = try JSONSerialization.jsonObject(with: data)
    let json = try #require(object as? [String: Any])
    return try #require(json["app"] as? [String: Any])
}

@Test
func releaseVersionIsBumpedPastPublishedBuild() throws {
    let app = try provenanceApp()
    let shortVersion = try #require(app["short_version"] as? String)
    #expect(shortVersion.split(separator: ".").count == 3)
    let bundleVersionText = try #require(app["bundle_version"] as? String)
    let bundleVersion = try #require(Int(bundleVersionText))
    // 0.3.1 shipped as build 4; Sparkle only offers a higher build.
    #expect(bundleVersion >= 5)
}

@Test
func caskMatchesProvenanceAndRequiresAppleSilicon() throws {
    let app = try provenanceApp()
    let shortVersion = try #require(app["short_version"] as? String)
    let cask = try projectFile("packaging/homebrew/yappyapp.rb")
    #expect(cask.contains("version \"\(shortVersion)\""))
    #expect(cask.contains("depends_on arch: :arm64"))
    #expect(cask.contains("zap script:"))
    #expect(cask.contains("trash:  ["))
    #expect(cask.contains("tccutil"))
    #expect(!cask.contains("xattr"))
    #expect(cask.contains("https://github.com/migueltorrezd/yappyapp-releases/"))
}

@Test
func packagedFeedUsesCurrentOwner() throws {
    let script = try projectFile("scripts/package_app.sh")
    #expect(script.contains(
        "<string>https://raw.githubusercontent.com/migueltorrezd/yappyapp-releases/main/appcast.xml</string>"
    ))
    #expect(!script.contains("matd97"))
}
