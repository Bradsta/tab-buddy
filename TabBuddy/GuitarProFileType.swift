import Foundation
import UniformTypeIdentifiers

/// Shared by the app and share extension; Guitar Pro 3–8 use these extensions.
enum GuitarProFileType {
    static let extensions = ["gp3", "gp4", "gp5", "gpx", "gp"]
    static func contains(_ filename: String) -> Bool {
        extensions.contains((filename as NSString).pathExtension.lowercased())
    }
    static func supports(extension ext: String) -> Bool {
        ["pdf", "txt"].contains(ext.lowercased()) || extensions.contains(ext.lowercased())
    }
    static var contentTypes: [UTType] {
        extensions.map { UTType(importedAs: "com.gamicarts.tabbuddy.guitar-pro.\($0)", conformingTo: .data) }
    }
}
