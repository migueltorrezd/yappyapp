import AppKit
import Foundation

/// HELP > MADE BY MIGUEL TORREZ: the two places to reach the developer.
/// The one home for these URLs. They are only ever handed to the default
/// browser when the user clicks a link; the app itself never fetches them.
enum DeveloperLinks {
    static let youTube = URL(string: "https://www.youtube.com/@migueltorrezai")!
    static let linkedIn = URL(string: "https://www.linkedin.com/in/miguel-torrez")!

    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
