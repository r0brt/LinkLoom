# LinkLoom

LinkLoom builds a local-first catalog and text index over documents that already exist on a Mac or an available mounted source. The SwiftPM vertical slice scans supported files, extracts text locally, and persists only catalog and extraction data. Original files remain in place and are never renamed, moved, or intentionally modified.

## Prerequisites

- macOS 15 or newer
- Swift 6.2 or newer
- Full Xcode is optional for this SwiftPM slice; the Xcode Command Line Tools are sufficient when they provide the required macOS frameworks

## Build, test, and run

From the repository root:

```sh
swift build
swift test
swift run LinkLoomApp
```

The app stores its local SQLite database at:

```text
~/Library/Application Support/LinkLoom/linkloom.sqlite
```

## Supported source documents

The ingestion slice supports:

- PDFs with selectable text
- image-only PDFs through local Vision OCR
- JPEG/JPG images
- PNG images
- HEIC images when the host ImageIO installation supports HEIC decoding

Unsupported extensions are ignored. A corrupt, unreadable, or password-protected supported document remains represented in the local catalog with a failure status so it can be diagnosed or retried without changing the original.

The current catalog acceptance boundary is 10,000 documents in one selected source. This is a verified functional boundary, not a hard maximum or a performance SLA.

## Try LinkLoom safely

1. Create a temporary folder outside this repository.
2. Copy a few non-sensitive test documents into it.
3. Run `swift run LinkLoomApp`.
4. Select the temporary folder in the source picker.
5. Start a scan and inspect the local status shown for each document.

LinkLoom reads selected originals in place. It does not import them into a proprietary archive. Cataloging and text extraction run locally, and removing LinkLoom's rebuildable database does not remove source documents.

## Optional 10,000-document benchmark

The performance fixture is disabled during normal test runs. Enable it explicitly with:

```sh
LINKLOOM_PERF_TEST=1 swift test --filter catalogHandlesTenThousandDocumentsIdempotently
```

The benchmark creates its synthetic files in a temporary directory, scans them twice, verifies 10,000 catalog records after both passes, and requires zero fingerprint work on the second pass. No hard duration threshold is enforced until a stable baseline has been established across supported hardware.

## Troubleshooting

### Password-protected PDFs

Password-protected PDFs cannot be extracted without credentials and are reported with a failure status. LinkLoom does not attempt to remove or bypass document protection. Unlock a copy outside LinkLoom if you are authorized to do so, then rescan it.

### Unavailable mounts

If a network share, external disk, or cloud-backed mount becomes unavailable, LinkLoom preserves its existing catalog and derived data. Reconnect the source and allow the filesystem watcher to trigger a catch-up scan, or start a manual scan after the source is available again.

### OCR failures

OCR can fail for damaged images, unsupported encodings, extreme image dimensions, blank pages, or text that Vision cannot recognize reliably. Confirm that the original opens normally in Preview, then retry with a clearer or correctly oriented source file. The original is not rewritten during OCR.
