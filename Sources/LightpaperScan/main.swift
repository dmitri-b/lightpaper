import CoreGraphics
import Foundation
import ImageIO

enum SourceKind: String, Codable, CaseIterable {
    case original
    case preview
}

enum MediaFormat: String, Codable {
    case jpeg
    case png
    case heif
    case tiff
    case unknown
}

struct Options {
    var libraryPath: String?
    var sourceFilter: Set<SourceKind> = Set(SourceKind.allCases)
    var sampleLimit = 20
    var json = false
}

struct ScanRoot {
    let libraryURL: URL
    let accountURL: URL
}

struct MediaItem: Codable {
    let path: String
    let source: SourceKind
    let format: MediaFormat
    let bytes: UInt64
    let modifiedAt: String?
    let width: Int?
    let height: Int?
}

struct ScanSummary: Codable {
    let libraryPath: String
    let scannedAt: String
    let scannedDirectories: [String]
    let totalMediaFiles: Int
    let sourceCounts: [String: Int]
    let formatCounts: [String: Int]
    let samples: [MediaItem]
    let warnings: [String]
}

enum ScanError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case noLibraryFound
    case unreadableLibrary(String)

    var description: String {
        switch self {
        case .invalidArgument(let message):
            return message
        case .noLibraryFound:
            return "No Lightroom .lrlibrary package found. Pass --library /path/to/Lightroom\\ Library.lrlibrary."
        case .unreadableLibrary(let path):
            return "Cannot read Lightroom library at \(path)."
        }
    }
}

func isoString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

func printUsage() {
    let usage = """
    Usage:
      lightpaper-scan [--library PATH] [--source all|previews|originals] [--limit N] [--json]

    Examples:
      swift run lightpaper-scan
      swift run lightpaper-scan -- --source previews --limit 10
      swift run lightpaper-scan -- --library "$HOME/Pictures/Lightroom Library.lrlibrary" --json

    This command reads Lightroom desktop local files only. It does not modify Adobe data.
    """
    print(usage)
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--":
            break
        case "--help", "-h":
            printUsage()
            exit(0)
        case "--library":
            index += 1
            guard index < arguments.count else {
                throw ScanError.invalidArgument("--library requires a path")
            }
            options.libraryPath = NSString(string: arguments[index]).expandingTildeInPath
        case "--source":
            index += 1
            guard index < arguments.count else {
                throw ScanError.invalidArgument("--source requires all, previews, or originals")
            }
            switch arguments[index] {
            case "all":
                options.sourceFilter = Set(SourceKind.allCases)
            case "previews":
                options.sourceFilter = [.preview]
            case "originals":
                options.sourceFilter = [.original]
            default:
                throw ScanError.invalidArgument("--source must be all, previews, or originals")
            }
        case "--limit":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value >= 0 else {
                throw ScanError.invalidArgument("--limit requires a non-negative integer")
            }
            options.sampleLimit = value
        case "--json":
            options.json = true
        default:
            throw ScanError.invalidArgument("Unknown argument: \(argument)")
        }
        index += 1
    }

    return options
}

func defaultLibraryCandidates() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
    var candidates: [URL] = [
        pictures.appendingPathComponent("Lightroom Library.lrlibrary", isDirectory: true)
    ]

    if let contents = try? FileManager.default.contentsOfDirectory(
        at: pictures,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) {
        for url in contents where url.pathExtension == "lrlibrary" && !candidates.contains(url) {
            candidates.append(url)
        }
    }

    return candidates
}

func findLibrary(path: String?) throws -> URL {
    let fileManager = FileManager.default

    if let path {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScanError.unreadableLibrary(url.path)
        }
        return url
    }

    for url in defaultLibraryCandidates() {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
    }

    throw ScanError.noLibraryFound
}

func findScanRoots(in libraryURL: URL) throws -> [ScanRoot] {
    let fileManager = FileManager.default
    guard let children = try? fileManager.contentsOfDirectory(
        at: libraryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw ScanError.unreadableLibrary(libraryURL.path)
    }

    let roots = children.compactMap { child -> ScanRoot? in
        let managedCatalog = child.appendingPathComponent("Managed Catalog.mcat")
        let previews = child.appendingPathComponent("previews", isDirectory: true)
        let originals = child.appendingPathComponent("originals", isDirectory: true)
        if fileManager.fileExists(atPath: managedCatalog.path)
            || fileManager.fileExists(atPath: previews.path)
            || fileManager.fileExists(atPath: originals.path) {
            return ScanRoot(libraryURL: libraryURL, accountURL: child)
        }
        return nil
    }

    return roots
}

func mediaFormat(for url: URL) -> MediaFormat {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
        return .unknown
    }
    defer {
        try? handle.close()
    }

    let data = (try? handle.read(upToCount: 16)) ?? Data()
    let bytes = [UInt8](data)

    if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
        return .jpeg
    }
    if bytes.count >= 8,
       bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
       bytes[4] == 0x0D, bytes[5] == 0x0A, bytes[6] == 0x1A, bytes[7] == 0x0A {
        return .png
    }
    if bytes.count >= 4,
       ((bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00)
        || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)) {
        return .tiff
    }
    if bytes.count >= 12 {
        let marker = String(bytes: bytes[4..<8], encoding: .ascii)
        let brand = String(bytes: bytes[8..<12], encoding: .ascii)
        let heifBrands = ["heic", "heix", "hevc", "hevx", "mif1", "msf1"]
        if marker == "ftyp", let brand, heifBrands.contains(brand) {
            return .heif
        }
    }

    return .unknown
}

func dimensions(for url: URL) -> (width: Int?, height: Int?) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return (nil, nil)
    }

    let width = properties[kCGImagePropertyPixelWidth] as? Int
    let height = properties[kCGImagePropertyPixelHeight] as? Int
    return (width, height)
}

func modifiedAtString(for values: URLResourceValues) -> String? {
    guard let date = values.contentModificationDate else {
        return nil
    }
    return isoString(from: date)
}

func scanDirectory(
    _ directory: URL,
    source: SourceKind,
    sampleLimit: Int,
    samples: inout [MediaItem],
    totalMediaFiles: inout Int,
    sourceCounts: inout [String: Int],
    formatCounts: inout [String: Int]
) {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return
    }

    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true else {
            continue
        }

        let format = mediaFormat(for: url)
        guard format != .unknown else {
            continue
        }

        totalMediaFiles += 1
        sourceCounts[source.rawValue, default: 0] += 1
        formatCounts[format.rawValue, default: 0] += 1

        if samples.count < sampleLimit {
            let size = UInt64(values.fileSize ?? 0)
            let imageSize = dimensions(for: url)
            samples.append(MediaItem(
                path: url.path,
                source: source,
                format: format,
                bytes: size,
                modifiedAt: modifiedAtString(for: values),
                width: imageSize.width,
                height: imageSize.height
            ))
        }
    }
}

func scan(options: Options) throws -> ScanSummary {
    let libraryURL = try findLibrary(path: options.libraryPath)
    let roots = try findScanRoots(in: libraryURL)

    var scannedDirectories: [String] = []
    var totalMediaFiles = 0
    var sourceCounts: [String: Int] = [:]
    var formatCounts: [String: Int] = [:]
    var samples: [MediaItem] = []
    var warnings: [String] = []

    if roots.isEmpty {
        warnings.append("No account folders with previews/originals were found in the Lightroom library.")
    }

    for root in roots {
        let originals = root.accountURL.appendingPathComponent("originals", isDirectory: true)
        let previews = root.accountURL.appendingPathComponent("previews", isDirectory: true)

        if options.sourceFilter.contains(.original), FileManager.default.fileExists(atPath: originals.path) {
            scannedDirectories.append(originals.path)
            scanDirectory(
                originals,
                source: .original,
                sampleLimit: options.sampleLimit,
                samples: &samples,
                totalMediaFiles: &totalMediaFiles,
                sourceCounts: &sourceCounts,
                formatCounts: &formatCounts
            )
        }

        if options.sourceFilter.contains(.preview), FileManager.default.fileExists(atPath: previews.path) {
            scannedDirectories.append(previews.path)
            scanDirectory(
                previews,
                source: .preview,
                sampleLimit: options.sampleLimit,
                samples: &samples,
                totalMediaFiles: &totalMediaFiles,
                sourceCounts: &sourceCounts,
                formatCounts: &formatCounts
            )
        }
    }

    if totalMediaFiles == 0 {
        warnings.append("No readable local media files were found. Lightroom may not have cached previews/originals locally.")
    }

    return ScanSummary(
        libraryPath: libraryURL.path,
        scannedAt: isoString(from: Date()),
        scannedDirectories: scannedDirectories,
        totalMediaFiles: totalMediaFiles,
        sourceCounts: sourceCounts,
        formatCounts: formatCounts,
        samples: samples,
        warnings: warnings
    )
}

func printHumanSummary(_ summary: ScanSummary) {
    print("Lightroom library: \(summary.libraryPath)")
    print("Scanned at: \(summary.scannedAt)")
    print("Media files found: \(summary.totalMediaFiles)")

    if !summary.sourceCounts.isEmpty {
        let counts = summary.sourceCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        print("Sources: \(counts)")
    }

    if !summary.formatCounts.isEmpty {
        let counts = summary.formatCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        print("Formats: \(counts)")
    }

    if !summary.scannedDirectories.isEmpty {
        print("Directories:")
        for directory in summary.scannedDirectories {
            print("  \(directory)")
        }
    }

    if !summary.samples.isEmpty {
        print("Samples:")
        for item in summary.samples {
            let dimensions: String
            if let width = item.width, let height = item.height {
                dimensions = "\(width)x\(height)"
            } else {
                dimensions = "unknown-size"
            }
            print("  [\(item.source.rawValue) \(item.format.rawValue) \(dimensions) \(item.bytes) bytes] \(item.path)")
        }
    }

    for warning in summary.warnings {
        print("Warning: \(warning)")
    }
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let summary = try scan(options: options)

    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        FileHandle.standardOutput.write(data)
        print("")
    } else {
        printHumanSummary(summary)
    }

    if summary.totalMediaFiles == 0 {
        exit(2)
    }
} catch let error as ScanError {
    FileHandle.standardError.write(Data("Error: \(error.description)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
