import Foundation

enum AppResourceLocator {
    private static let packageResourceBundleName = "KCDeepL_KCDeepL.bundle"

    static func url(
        forResource name: String,
        withExtension fileExtension: String
    ) -> URL? {
        for bundle in candidateBundles {
            if let url = bundle.url(
                forResource: name,
                withExtension: fileExtension
            ) {
                return url
            }

            if let url = bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "Resources"
            ) {
                return url
            }
        }

        return nil
    }

    private static let candidateBundles: [Bundle] = {
        var bundles = [Bundle.main]
        var bundleURLs = [
            Bundle.main.bundleURL.appendingPathComponent(
                packageResourceBundleName,
                isDirectory: true
            ),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    packageResourceBundleName,
                    isDirectory: true
                )
        ]

        if let resourceURL = Bundle.main.resourceURL {
            bundleURLs.append(
                resourceURL.appendingPathComponent(
                    packageResourceBundleName,
                    isDirectory: true
                )
            )
        }

        if let executableURL = Bundle.main.executableURL {
            bundleURLs.append(
                executableURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        packageResourceBundleName,
                        isDirectory: true
                )
            )
        }

#if DEBUG
        let packageDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        for configuration in ["debug", "release"] {
            bundleURLs.append(
                packageDirectory
                    .appendingPathComponent(".build", isDirectory: true)
                    .appendingPathComponent(configuration, isDirectory: true)
                    .appendingPathComponent(
                        packageResourceBundleName,
                        isDirectory: true
                    )
            )
        }
#endif

        var seenPaths = Set([Bundle.main.bundleURL.standardizedFileURL.path])
        for bundleURL in bundleURLs {
            let standardizedURL = bundleURL.standardizedFileURL
            guard seenPaths.insert(standardizedURL.path).inserted,
                  let bundle = Bundle(url: standardizedURL)
            else {
                continue
            }

            bundles.append(bundle)
        }

        return bundles
    }()
}
