import Foundation

private final class AppResourceBundleToken: NSObject {}

enum AppResourceLocator {
    private static let packageResourceBundleName = "KCDeepL_KCDeepL.bundle"

    static func url(
        forResource name: String,
        withExtension fileExtension: String,
        subdirectory: String? = nil
    ) -> URL? {
        for bundle in candidateBundles {
            if let url = bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ) {
                return url
            }

            let resourceSubdirectory = ["Resources", subdirectory]
                .compactMap { $0 }
                .joined(separator: "/")
            if let url = bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: resourceSubdirectory
            ) {
                return url
            }
        }

        return nil
    }

    private static let candidateBundles: [Bundle] = {
        // Bundle.module traps when its build-time path no longer exists.
        // Use the app/code bundles instead: packaged resources live inside
        // the app, while SwiftPM test resources sit beside the .xctest bundle.
        let hostBundles = [Bundle.main, Bundle(for: AppResourceBundleToken.self)]
        var bundles: [Bundle] = []
        var seenPaths = Set<String>()
        for bundle in hostBundles {
            if seenPaths.insert(bundle.bundleURL.standardizedFileURL.path).inserted {
                bundles.append(bundle)
            }
        }

        for host in hostBundles {
            let roots = [
                host.resourceURL,
                host.bundleURL,
                host.bundleURL.deletingLastPathComponent()
            ].compactMap { $0 }
            for root in roots {
                let url = root.appendingPathComponent(
                    packageResourceBundleName,
                    isDirectory: true
                ).standardizedFileURL
                if seenPaths.insert(url.path).inserted, let bundle = Bundle(url: url) {
                    bundles.append(bundle)
                }
            }
        }

        return bundles
    }()
}
