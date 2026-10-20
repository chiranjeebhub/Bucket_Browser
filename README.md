# Bucket Browser

A native macOS app for browsing Amazon S3 and Cloudflare R2 buckets the way you browse files in Finder. Written in SwiftUI with a small, dependency-free S3 client.

![List view with Get Info](docs/screenshots/list-view.png)

| Icon view | Column view |
| --- | --- |
| ![Icon view](docs/screenshots/icon-view.png) | ![Column view](docs/screenshots/column-view.png) |

## Features

- **Sidebar of accounts and buckets.** Add as many AWS, R2 or other S3-compatible accounts as you like; each shows its buckets like Finder's Locations.
- **Icon, list and column views** (⌘1, ⌘2, ⌘3), with sortable columns, folders kept on top and search within the current folder.
- **Finder navigation:** back and forward (⌘[ and ⌘]), Enclosing Folder (⌘↑), Open (⌘↓ or double-click), and a clickable path bar with an item count.
- **Quick Look:** press Space or ⌘Y to preview any file. Previews are cached by ETag.
- **Drag and drop:** drop files or whole folders from Finder onto the window, a folder, a column or a path-bar segment to upload. Drag items out to Finder to download them.
- **File operations:** New Folder (⇧⌘N), Rename, Delete (⌘⌫), Upload (⇧⌘U) and Download (⌥⌘D), all from context menus too. Renaming and deleting work on folders recursively.
- **Get Info** (⌘I): size, dates, storage class, content type, ETag and user metadata.
- **Shareable links:** copy a presigned URL that expires in an hour, a day or seven days, or copy the `s3://` URI.
- **Transfers popover** with progress, cancel and Show in Finder. Large files upload in parallel multipart chunks.
- **Credentials live in the Keychain.** Account settings (names, regions, endpoints) go in user defaults; access keys never do.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (Swift 5.10+) to build

## Build and run

```sh
# Run straight from the package
swift run BucketBrowser

# Or build a double-clickable app in build/Bucket Browser.app
scripts/build-app.sh            # release build for this Mac
UNIVERSAL=1 scripts/build-app.sh  # Apple silicon + Intel
open "build/Bucket Browser.app"
```

You can also open `Package.swift` in Xcode and run the `BucketBrowser` scheme.

Every CI run on GitHub builds a universal app and attaches it to the run as `BucketBrowser-app`. The app is ad-hoc signed, so the first time you open a downloaded copy, Control-click it and choose **Open**.

## Adding an account

Choose **Add Account** at the bottom of the sidebar, or open **Settings › Accounts**.

| Service | What you need |
| --- | --- |
| Amazon S3 | An IAM access key and a default region. Each bucket's region is detected automatically. |
| Cloudflare R2 | Your Cloudflare account ID and an R2 API token's S3 access key ID and secret (R2 › Manage API Tokens). Pick the EU or FedRAMP jurisdiction if your buckets use one. |
| S3-compatible | The endpoint URL (for example `http://localhost:9000` for MinIO), the region and whether to use path-style URLs. |

If your key can read buckets but not list them (common with bucket-scoped R2 tokens), type the bucket names under **Buckets › Always Show** and they appear in the sidebar anyway. **Test Connection** checks the keys before you save.

## How it works

- `Sources/S3Kit` is a small async S3 client: AWS Signature Version 4 signing (headers and presigned URLs), ListBuckets, ListObjectsV2 with delimiters, HEAD, GET to file, PUT and multipart upload, CopyObject, and batched DeleteObjects. It uses only Foundation and CryptoKit.
- `Sources/BucketBrowser` is the SwiftUI app. Each window has its own `BrowserModel`; accounts and transfers are shared between windows.
- S3 has no real folders or renames. Folders are key prefixes ending in `/`, New Folder writes an empty `name/` marker object, and Rename copies each object to its new key and then deletes the original. Renaming a large folder therefore takes as long as copying it, and single objects over 5 GB can't be renamed.

## Demo mode and screenshots

Launch with `BUCKET_BROWSER_DEMO=1` to browse made-up R2 and AWS buckets without any credentials:

```sh
BUCKET_BROWSER_DEMO=1 swift run BucketBrowser
```

`scripts/take-screenshots.sh` uses demo mode to capture the images above. The **Screenshots** workflow runs it on a macOS runner and commits the results to `docs/screenshots`.

## Tests

```sh
swift test
```

The S3Kit tests check the signer against the AWS SigV4 test vectors and cover URL building for each provider, XML parsing and path helpers.
