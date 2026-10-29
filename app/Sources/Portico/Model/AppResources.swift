import Foundation

/// Where the app's own resources (the markdown page's script and style)
/// are read from. An assembled `.app` carries SwiftPM's resource bundle in
/// `Contents/Resources`; Swift 6.4's `Bundle.module` finds it there, but a
/// Swift 6.3 (Xcode) build's looks at the `.app` root (where codesign
/// forbids files) and then at an absolute path in the checkout's `.build`
/// — and stops the app when neither is there. So the bundle beside the
/// main bundle's resources is tried first, and `Bundle.module` only after.
enum AppResources {
    static let bundleName = "Portico_Portico.bundle"

    /// The resource bundle inside `resourceDirectory`, when it is there.
    static func packagedBundle(in resourceDirectory: URL?) -> Bundle? {
        guard let resourceDirectory else { return nil }
        let candidate = resourceDirectory.appendingPathComponent(bundleName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return Bundle(url: candidate)
    }

    /// `Contents/Resources/Portico_Portico.bundle`, else SwiftPM's lookup.
    static var bundle: Bundle {
        packagedBundle(in: Bundle.main.resourceURL) ?? Bundle.module
    }

    /// A file in the bundle's `Resources` folder.
    static func url(forResource name: String, withExtension ext: String, bundle: Bundle = AppResources.bundle) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }
}
