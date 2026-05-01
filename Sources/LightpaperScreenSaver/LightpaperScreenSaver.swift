import AppKit
import ImageIO
import ScreenSaver

private enum SourceKind {
    case original
    case preview
}

private struct SourceDirectory {
    let source: SourceKind
    let directory: URL
}

private struct TileItem {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
}

private final class CachedCGImage {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private struct SkylineSegment {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat

    var maxX: CGFloat {
        x + width
    }
}

private let defaultImageLimit = 700
private let minimumTileLongEdge = 900

private final class LightpaperTiledView: NSView {
    private var items: [TileItem]
    private var tileFrames: [NSRect] = []
    private var laidOutWidth: CGFloat = 0
    private var laidOutViewportHeight: CGFloat = 0
    private var laidOutScale: CGFloat = 0
    private let imageCache = NSCache<NSURL, CachedCGImage>()

    init(items: [TileItem]) {
        self.items = items
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageCache.countLimit = 240
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    var pageCount: Int {
        updateTileLayout()
        let height = viewportHeight()
        return max(Int(ceil(frame.height / height)), 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        updateTileLayout()

        for (index, frame) in tileFrames.enumerated() where frame.intersects(dirtyRect) {
            guard let image = cachedImage(for: items[index])?.image,
                  let context = NSGraphicsContext.current?.cgContext else {
                continue
            }
            draw(image, in: frame, context: context)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateTileLayout()
    }

    private func draw(_ image: CGImage, in frame: NSRect, context: CGContext) {
        let imageSize = NSSize(width: image.width, height: image.height)
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawFrame = NSRect(
            x: (frame.width - drawSize.width) / 2,
            y: (frame.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        context.draw(image, in: drawFrame)
        context.restoreGState()
    }

    private func updateTileLayout() {
        let availableWidth = max(enclosingScrollView?.contentView.bounds.width ?? bounds.width, 1)
        let availableHeight = viewportHeight()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        guard tileFrames.isEmpty
                || abs(availableWidth - laidOutWidth) > 0.5
                || abs(availableHeight - laidOutViewportHeight) > 0.5
                || abs(scale - laidOutScale) > 0.01 else {
            return
        }

        laidOutWidth = availableWidth
        laidOutViewportHeight = availableHeight
        laidOutScale = scale
        tileFrames.removeAll(keepingCapacity: true)
        updateEditorialLayout(availableWidth: availableWidth, scale: scale)
    }

    private func updateEditorialLayout(availableWidth: CGFloat, scale: CGFloat) {
        let viewportHeight = viewportHeight()
        let targetHeights = [
            min(max(viewportHeight * 0.62, 380), 720),
            min(max(viewportHeight * 0.38, 260), 460),
            min(max(viewportHeight * 0.52, 330), 620),
            min(max(viewportHeight * 0.28, 190), 340),
            min(max(viewportHeight * 0.46, 300), 540)
        ]
        var y: CGFloat = 0
        var pageBottom = viewportHeight
        var cursor = 0
        var rowIndex = 0

        while cursor < items.count {
            let remaining = max(pageBottom - y, 1)
            var row: [(item: TileItem, nativeWidth: CGFloat, nativeHeight: CGFloat)] = []
            var rowAspect: CGFloat = 0
            let targetHeight = min(targetHeights[rowIndex % targetHeights.count], remaining)

            while cursor < items.count {
                let item = items[cursor]
                let size = nativeSize(for: item, scale: scale)
                row.append((item, size.width, size.height))
                rowAspect += size.width / size.height
                cursor += 1

                let projectedHeight = availableWidth / rowAspect
                if projectedHeight <= targetHeight {
                    break
                }
            }

            let exactHeight = availableWidth / rowAspect
            let shouldFillPage = pageBottom - y - exactHeight < targetHeights.last ?? 240
            let rowHeight = shouldFillPage ? remaining : min(exactHeight, remaining)
            appendRow(row, y: y, height: rowHeight, availableWidth: availableWidth)

            y += rowHeight
            if pageBottom - y < 1 {
                y = pageBottom
                pageBottom += viewportHeight
            }

            rowIndex += 1
        }

        frame = NSRect(x: 0, y: 0, width: availableWidth, height: pagedContentHeight(for: y))
    }

    private func appendRow(
        _ row: [(item: TileItem, nativeWidth: CGFloat, nativeHeight: CGFloat)],
        y: CGFloat,
        height: CGFloat,
        availableWidth: CGFloat
    ) {
        let rowAspect = row.reduce(CGFloat(0)) { result, entry in
            result + entry.nativeWidth / entry.nativeHeight
        }
        var x: CGFloat = 0

        for (index, entry) in row.enumerated() {
            let width = index == row.count - 1
                ? availableWidth - x
                : availableWidth * ((entry.nativeWidth / entry.nativeHeight) / rowAspect)
            tileFrames.append(NSRect(x: x, y: y, width: width, height: height))
            x += width
        }
    }

    private func viewportHeight() -> CGFloat {
        max(enclosingScrollView?.contentView.bounds.height ?? bounds.height, 1)
    }

    private func pagedContentHeight(for contentHeight: CGFloat) -> CGFloat {
        let pageHeight = viewportHeight()
        return max(ceil(max(contentHeight, 1) / pageHeight) * pageHeight, pageHeight)
    }

    private func nativeSize(for item: TileItem, scale: CGFloat) -> NSSize {
        NSSize(
            width: max(CGFloat(item.pixelWidth) / scale, 1),
            height: max(CGFloat(item.pixelHeight) / scale, 1)
        )
    }

    private func cachedImage(for item: TileItem) -> CachedCGImage? {
        let key = item.url as NSURL
        if let image = imageCache.object(forKey: key) {
            return image
        }

        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(item.pixelWidth, item.pixelHeight),
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else {
            return nil
        }

        let image = CachedCGImage(cgImage)
        imageCache.setObject(image, forKey: key)
        return image
    }
}

@objc(LightpaperScreenSaverView)
public final class LightpaperScreenSaverView: ScreenSaverView {
    private var scrollView: NSScrollView?
    private var tiledView: LightpaperTiledView?
    private var currentPage = 0

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    public override var hasConfigureSheet: Bool {
        false
    }

    public override var configureSheet: NSWindow? {
        nil
    }

    public override func startAnimation() {
        super.startAnimation()
        if tiledView == nil {
            installImages()
        }
    }

    public override func animateOneFrame() {
        advancePage()
    }

    public override func layout() {
        super.layout()
        scrollView?.frame = bounds
        tiledView?.layoutSubtreeIfNeeded()
        scrollToCurrentPage(animated: false)
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = isPreview ? 5 : 8
    }

    private func installImages() {
        guard let items = loadInitialItems(), !items.isEmpty else {
            return
        }

        let tiledView = LightpaperTiledView(items: items)
        let scrollView = NSScrollView(frame: bounds)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = tiledView

        addSubview(scrollView)
        self.scrollView = scrollView
        self.tiledView = tiledView
        scrollToCurrentPage(animated: false)
    }

    private func loadInitialItems() -> [TileItem]? {
        let sourceDirectories = collectSourceDirectories()
        guard !sourceDirectories.isEmpty else {
            return nil
        }

        let limit = isPreview ? min(defaultImageLimit, 160) : defaultImageLimit
        let urls = collectMediaURLs(from: sourceDirectories, limit: limit)
        return urls.compactMap(loadTileItem)
    }

    private func advancePage() {
        guard let tiledView else {
            return
        }

        let pageCount = tiledView.pageCount
        guard pageCount > 1 else {
            currentPage = 0
            scrollToCurrentPage(animated: false)
            return
        }

        currentPage = (currentPage + 1) % pageCount
        scrollToCurrentPage(animated: true)
    }

    private func scrollToCurrentPage(animated: Bool) {
        guard let scrollView else {
            return
        }

        tiledView?.layoutSubtreeIfNeeded()
        let pageHeight = max(scrollView.contentView.bounds.height, 1)
        let target = NSPoint(x: 0, y: CGFloat(currentPage) * pageHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(target)
            } completionHandler: {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

private func defaultLibraryCandidates() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
    var candidates = [
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

private func collectSourceDirectories() -> [SourceDirectory] {
    guard let libraryURL = defaultLibraryCandidates().first(where: { url in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }) else {
        return []
    }

    guard let children = try? FileManager.default.contentsOfDirectory(
        at: libraryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var sourceDirectories: [SourceDirectory] = []
    for child in children {
        let managedCatalog = child.appendingPathComponent("Managed Catalog.mcat")
        let previews = child.appendingPathComponent("previews", isDirectory: true)
        let originals = child.appendingPathComponent("originals", isDirectory: true)

        guard FileManager.default.fileExists(atPath: managedCatalog.path)
                || FileManager.default.fileExists(atPath: previews.path)
                || FileManager.default.fileExists(atPath: originals.path) else {
            continue
        }
        if FileManager.default.fileExists(atPath: previews.path) {
            sourceDirectories.append(SourceDirectory(source: .preview, directory: previews))
        }
    }

    return sourceDirectories
}

private func collectMediaURLs(from sourceDirectories: [SourceDirectory], limit: Int) -> [URL] {
    var urls: [URL] = []
    var seenURLs = Set<URL>()
    let leafDirectories = sourceDirectories
        .flatMap { candidateDirectories(for: $0.source, under: $0.directory) }
        .shuffled()

    for directory in leafDirectories {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            continue
        }

        for url in contents.shuffled() {
            guard urls.count < limit else {
                return urls
            }
            guard !seenURLs.contains(url) else {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  isLikelyImageURL(url) else {
                continue
            }
            seenURLs.insert(url)
            urls.append(url)
        }
    }

    return urls
}

private func candidateDirectories(for source: SourceKind, under root: URL) -> [URL] {
    switch source {
    case .preview:
        return [root] + childDirectories(under: root)
    case .original:
        let years = childDirectories(under: root)
        let dates = years.flatMap(childDirectories)
        return [root] + years + dates
    }
}

private func childDirectories(under root: URL) -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    return contents.filter { url in
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            return false
        }
        return values.isDirectory == true
    }
}

private func isLikelyImageURL(_ url: URL) -> Bool {
    let extensionName = url.pathExtension.lowercased()
    guard !extensionName.isEmpty else {
        return true
    }
    return ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"].contains(extensionName)
}

private func loadTileItem(url: URL) -> TileItem? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
        return nil
    }

    let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
    let swapsAxes = [5, 6, 7, 8].contains(orientation)
    let displayWidth = swapsAxes ? height : width
    let displayHeight = swapsAxes ? width : height
    guard max(displayWidth, displayHeight) >= minimumTileLongEdge else {
        return nil
    }
    return TileItem(
        url: url,
        pixelWidth: displayWidth,
        pixelHeight: displayHeight
    )
}
