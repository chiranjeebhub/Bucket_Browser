import AppKit
import Foundation
import S3Kit

/// Sample accounts and bucket contents for screenshots and trying the UI without credentials.
/// Enabled by launching with `BUCKET_BROWSER_DEMO=1`. Optional settings:
/// `BB_DEMO_VIEW` (icons, list, columns), `BB_DEMO_BUCKET`, `BB_DEMO_PREFIX`,
/// `BB_DEMO_SELECT` (item name), `BB_DEMO_INSPECTOR=1` and `BB_DEMO_APPEARANCE` (light, dark).
enum DemoMode {
    private static let environment = ProcessInfo.processInfo.environment

    static let isEnabled = environment["BUCKET_BROWSER_DEMO"] == "1"

    static var viewMode: ViewMode? { environment["BB_DEMO_VIEW"].flatMap(ViewMode.init(rawValue:)) }
    static var bucket: String { environment["BB_DEMO_BUCKET"] ?? "media-assets" }
    static var prefix: String { environment["BB_DEMO_PREFIX"] ?? "" }
    static var selectedName: String? { environment["BB_DEMO_SELECT"] }
    static var showsInspector: Bool { environment["BB_DEMO_INSPECTOR"] == "1" }
    /// Starts with no accounts, to show the welcome screen.
    static var startsEmpty: Bool { environment["BB_DEMO_EMPTY"] == "1" }

    static var appearance: NSAppearance? {
        switch environment["BB_DEMO_APPEARANCE"] {
        case "dark": return NSAppearance(named: .darkAqua)
        case "light": return NSAppearance(named: .aqua)
        default: return nil
        }
    }

    // MARK: - Accounts

    static let r2AccountID = UUID(uuidString: "6F1D7C2A-0000-4000-8000-000000000001")!
    static let awsAccountID = UUID(uuidString: "6F1D7C2A-0000-4000-8000-000000000002")!

    static let accounts: [Account] = [
        Account(id: r2AccountID, name: "Cloudflare R2", provider: .r2, r2AccountID: "demo"),
        Account(id: awsAccountID, name: "AWS Production", provider: .aws, region: "eu-west-1"),
    ]

    static let buckets: [UUID: [S3Bucket]] = [
        r2AccountID: ["media-assets", "website-backups"].map { S3Bucket(name: $0) },
        awsAccountID: ["analytics-exports", "app-uploads", "logs-archive"].map { S3Bucket(name: $0) },
    ]

    // MARK: - Objects

    private static let reference = Date(timeIntervalSince1970: 1_760_000_000) // Oct 2025

    private struct DemoObject {
        let key: String
        let size: Int64
        let daysAgo: Double
    }

    private static func o(_ key: String, _ size: Int64, _ daysAgo: Double) -> DemoObject {
        DemoObject(key: key, size: size, daysAgo: daysAgo)
    }

    /// Every object in the demo buckets with its size in bytes and age in days before the reference date.
    private static let objects: [String: [DemoObject]] = [
        "media-assets": [
            o("brand/logo.svg", 18_204, 120),
            o("brand/logo-dark.svg", 18_377, 120),
            o("brand/brand-guidelines.pdf", 4_812_330, 95),
            o("brand/fonts/Inter-Regular.woff2", 98_112, 300),
            o("brand/fonts/Inter-Bold.woff2", 101_640, 300),
            o("photos/2024/holiday-party.jpg", 3_420_118, 290),
            o("photos/2024/team-offsite.jpg", 5_118_004, 260),
            o("photos/2025/IMG_0412.HEIC", 2_903_551, 12),
            o("photos/2025/IMG_0413.HEIC", 3_117_908, 12),
            o("photos/2025/product-launch-hero.png", 8_412_093, 9),
            o("photos/2025/product-launch-social.png", 1_204_772, 9),
            o("photos/2025/storefront.jpg", 4_550_219, 6),
            o("photos/2025/warehouse-tour.jpg", 6_021_448, 3),
            o("photos/2025/press-kit.zip", 48_203_115, 2),
            o("photos/2025/raw/IMG_0412.dng", 24_112_908, 12),
            o("photos/cover.jpg", 912_004, 40),
            o("videos/launch-teaser.mp4", 184_220_771, 8),
            o("videos/how-it-works.mov", 642_118_330, 30),
            o("videos/captions/launch-teaser.srt", 4_221, 8),
            o("docs/press-release.docx", 48_330, 9),
            o("docs/pricing-2025.xlsx", 31_872, 21),
            o("docs/roadmap.key", 12_440_118, 18),
            o("docs/README.md", 2_204, 60),
            o("index.html", 14_882, 1),
            o("robots.txt", 68, 200),
            o("favicon.ico", 15_086, 400),
            o("site.webmanifest", 512, 400),
        ],
        "website-backups": [
            o("2025-10-01/site.tar.gz", 412_330_118, 10),
            o("2025-10-08/site.tar.gz", 418_004_220, 3),
            o("2025-10-08/database.sql.gz", 88_130_441, 3),
        ],
        "analytics-exports": [
            o("daily/2025-10-08.parquet", 22_118_440, 2),
            o("daily/2025-10-09.parquet", 23_007_118, 1),
            o("monthly/2025-09.csv", 118_220_004, 10),
        ],
        "app-uploads": [
            o("avatars/u_1042.png", 88_204, 4),
            o("avatars/u_1043.jpg", 102_337, 4),
            o("attachments/invoice-8812.pdf", 220_118, 6),
        ],
        "logs-archive": [
            o("2025/10/app-2025-10-09.log.gz", 9_220_118, 1),
            o("2025/10/app-2025-10-08.log.gz", 9_004_771, 2),
        ],
    ]

    /// The objects and sub-folders directly under `prefix`, as ListObjectsV2 with a `/` delimiter would return them.
    static func listing(bucket: String, prefix: String) -> S3Listing {
        var listing = S3Listing()
        var seenPrefixes = Set<String>()
        for object in objects[bucket] ?? [] where object.key.hasPrefix(prefix) {
            let (key, size, daysAgo) = (object.key, object.size, object.daysAgo)
            let rest = key.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                let folder = prefix + rest[...slash]
                if seenPrefixes.insert(folder).inserted { listing.prefixes.append(folder) }
            } else {
                listing.objects.append(S3Object(
                    key: key,
                    size: size,
                    lastModified: reference.addingTimeInterval(-daysAgo * 86_400 - Double(size % 36_000)),
                    etag: String(SigV4Signer.sha256Hex(Data(key.utf8)).prefix(32)),
                    storageClass: "STANDARD"
                ))
            }
        }
        return listing
    }

    static func metadata(for item: BrowserItem) -> S3ObjectMetadata {
        S3ObjectMetadata(
            contentType: item.contentType.preferredMIMEType ?? "application/octet-stream",
            contentLength: item.size,
            lastModified: item.lastModified,
            etag: item.etag,
            storageClass: item.storageClass,
            userMetadata: ["uploaded-by": "bucket-browser", "camera": item.fileExtension == "heic" ? "iPhone 16 Pro" : "—"]
        )
    }
}
