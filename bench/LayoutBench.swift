// Benchmark harness for the screen saver mosaic. Compiled as ONE module together
// with Sources/LightpaperScreenSaver/LightpaperScreenSaver.swift (concatenated by
// autoresearch.sh) so it can reach the file-private types.
//
// For every (fixture screen × display) it presents a gallery through the real
// `LightpaperScreenSaverView.presentGallery` path in an offscreen window with a
// pinned backing scale, reads back the tile container layers as displayed, and
// scores the composition. Contract with the saver: `LightpaperTiledView.tileLayers[i]`
// is the clipping container showing `items[i]`.

import AppKit
import ScreenSaver

private final class FixedScaleWindow: NSWindow {
    var fixedScale: CGFloat = 2
    override var backingScaleFactor: CGFloat { fixedScale }
}

private struct BenchDisplay {
    let name: String
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
}

private let benchDisplays: [BenchDisplay] = [
    BenchDisplay(name: "mbp14", width: 1512, height: 982, scale: 2),
    BenchDisplay(name: "mbp16", width: 1728, height: 1117, scale: 2),
    BenchDisplay(name: "studio5k", width: 2560, height: 1440, scale: 2),
    BenchDisplay(name: "4k-looks1080", width: 1920, height: 1080, scale: 2),
    BenchDisplay(name: "1080p", width: 1920, height: 1080, scale: 1),
    BenchDisplay(name: "portrait", width: 1080, height: 1920, scale: 2)
]

private struct BenchFixture: Decodable {
    struct Screen: Decodable {
        let month: String
        let items: [[Int]]
    }
    let screens: [Screen]
}

extension LightpaperTiledView {
    fileprivate var benchTiles: [(layer: CALayer, item: TileItem)] {
        Array(zip(tileLayers, items)).map { ($0.0, $0.1) }
    }
}

extension LightpaperScreenSaverView {
    fileprivate func benchPresent(_ items: [TileItem]) -> LightpaperTiledView? {
        presentGallery(items: items, animated: false)
        layoutSubtreeIfNeeded()
        return currentGallery?.documentView as? LightpaperTiledView
    }
}

private struct ScreenScore {
    var coverage: Double = 0
    var crop: Double = 0
    var sharp: Double = 0
    var upscale: Double = 0
    var count: Double = 0
    var countTerm: Double = 0
    var evenness: Double = 0
    var harmony: Double = 0
    var overlap: Double = 0
    var beauty: Double = 0
}

/// Target look (chosen by the user from full-res renders): justified rows, NO gaps,
/// full-bleed — no black anywhere — with rows of roughly equal height, ~10 photos,
/// minimal cropping and as little enlargement as possible.
private func score(tiles: [(rect: CGRect, item: TileItem)], viewport: CGSize, scale: CGFloat) -> ScreenScore {
    var s = ScreenScore()
    let viewportRect = CGRect(origin: .zero, size: viewport)
    let visible = tiles.compactMap { tile -> (rect: CGRect, item: TileItem)? in
        let r = tile.rect.intersection(viewportRect)
        return r.isNull || r.width < 1 || r.height < 1 ? nil : (r, tile.item)
    }
    guard !visible.isEmpty else {
        return s
    }

    // Coverage / overlap on a 2pt grid. Tiles are dilated by 0.5pt only to absorb
    // rounding; any real gap or empty band counts as black.
    let cell: CGFloat = 2
    let cols = Int(ceil(viewport.width / cell))
    let rows = Int(ceil(viewport.height / cell))
    var covered = [UInt8](repeating: 0, count: cols * rows)
    var hits = [UInt8](repeating: 0, count: cols * rows)
    for tile in visible {
        let d = tile.rect.insetBy(dx: -0.5, dy: -0.5)
        let x0 = max(0, Int(floor(d.minX / cell))), x1 = min(cols, Int(ceil(d.maxX / cell)))
        let y0 = max(0, Int(floor(d.minY / cell))), y1 = min(rows, Int(ceil(d.maxY / cell)))
        if x0 < x1, y0 < y1 {
            for y in y0..<y1 { for x in x0..<x1 { covered[y * cols + x] = 1 } }
        }
        let r = tile.rect
        let a0 = max(0, Int((r.minX / cell).rounded())), a1 = min(cols, Int((r.maxX / cell).rounded()))
        let b0 = max(0, Int((r.minY / cell).rounded())), b1 = min(rows, Int((r.maxY / cell).rounded()))
        if a0 < a1, b0 < b1 {
            for y in b0..<b1 { for x in a0..<a1 { hits[y * cols + x] &+= 1 } }
        }
    }
    s.coverage = Double(covered.reduce(0) { $0 + Int($1) }) / Double(cols * rows)
    s.overlap = Double(hits.reduce(0) { $0 + ($1 > 1 ? 1 : 0) }) / Double(cols * rows)

    var areaSum = 0.0, cropSum = 0.0, sharpSum = 0.0, upSum = 0.0
    var areas: [Double] = []
    var rowHeights: [Int: CGFloat] = [:]
    for tile in visible {
        let r = tile.rect
        let area = Double(r.width * r.height)
        let tileAspect = Double(r.width / r.height)
        let imageAspect = Double(tile.item.pixelWidth) / Double(tile.item.pixelHeight)
        let visibleFraction = min(tileAspect / imageAspect, imageAspect / tileAspect)
        let up = max(
            Double(r.width * scale) / Double(tile.item.pixelWidth),
            Double(r.height * scale) / Double(tile.item.pixelHeight)
        )
        areaSum += area
        cropSum += area * visibleFraction
        sharpSum += area * pow(max(1, up), -0.35)
        upSum += area * up
        areas.append(area)
        let rowKey = Int((r.minY / 4).rounded())
        rowHeights[rowKey] = max(rowHeights[rowKey] ?? 0, r.height)
    }
    s.crop = cropSum / areaSum
    s.sharp = sharpSum / areaSum
    s.upscale = upSum / areaSum
    s.count = Double(visible.count)
    let l = log(s.count / 10)
    s.countTerm = exp(-(l * l) / (2 * 0.6 * 0.6))
    let heights = rowHeights.values
    s.evenness = Double((heights.min() ?? 0) / max(heights.max() ?? 1, 1))
    let sorted = areas.sorted()
    let median = sorted[sorted.count / 2]
    s.harmony = 0.5 + 0.5 * min(1, (sorted[0] / median) / 0.4)
    s.beauty = pow(s.coverage, 4) * s.crop * s.sharp * s.countTerm * pow(s.evenness, 0.5)
        * s.harmony * max(0, 1 - 4 * s.overlap)
    return s
}

private func drawPreview(tiles: [(rect: CGRect, item: TileItem)], viewport: CGSize, scale: CGFloat, to url: URL) {
    let w = Int(viewport.width / 4), h = Int(viewport.height / 4)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for tile in tiles {
        let r = tile.rect
        let up = max(Double(r.width * scale) / Double(tile.item.pixelWidth),
                     Double(r.height * scale) / Double(tile.item.pixelHeight))
        let t = CGFloat(min(1, max(0, (up - 1) / 2)))
        ctx.setFillColor(CGColor(red: 0.3 + 0.6 * t, green: 0.7 - 0.4 * t, blue: 0.5, alpha: 1))
        let q = CGRect(x: r.minX / 4, y: r.minY / 4, width: r.width / 4, height: r.height / 4)
        ctx.fill(q.insetBy(dx: 0.5, dy: 0.5))
    }
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

@main
enum LayoutBench {
    static func main() throws {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        let fixtureURL = URL(fileURLWithPath: args.count > 1 ? args[1] : "bench/fixture.json")
        let previewDir: URL? = args.count > 2 ? URL(fileURLWithPath: args[2], isDirectory: true) : nil
        let fixture = try JSONDecoder().decode(BenchFixture.self, from: Data(contentsOf: fixtureURL))

        var all: [ScreenScore] = []
        var layoutSeconds = 0.0
        for display in benchDisplays {
            for (screenIndex, screen) in fixture.screens.enumerated() {
                let items = screen.items.enumerated().map { index, wh in
                    TileItem(url: URL(fileURLWithPath: "/nonexistent/lightpaper-bench/\(index).jpg"),
                             pixelWidth: wh[0], pixelHeight: wh[1])
                }
                let frame = NSRect(x: 0, y: 0, width: display.width, height: display.height)
                let window = FixedScaleWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
                window.fixedScale = display.scale
                guard let saver = LightpaperScreenSaverView(frame: frame, isPreview: false) else {
                    fatalError("saver init failed")
                }
                window.contentView = saver
                let start = Date()
                guard let tiled = saver.benchPresent(items) else {
                    fatalError("no tiled gallery")
                }
                layoutSeconds += Date().timeIntervalSince(start)
                guard let rootLayer = saver.layer else { fatalError("no saver layer") }
                let flipped = !rootLayer.isGeometryFlipped
                let tiles = tiled.benchTiles.map { tile -> (rect: CGRect, item: TileItem) in
                    var r = tile.layer.convert(tile.layer.bounds, to: rootLayer)
                    if flipped {
                        r.origin.y = display.height - r.maxY
                    }
                    return (r, tile.item)
                }
                let s = score(tiles: tiles, viewport: frame.size, scale: display.scale)
                all.append(s)
                if let previewDir {
                    try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
                    drawPreview(tiles: tiles, viewport: frame.size, scale: display.scale,
                                to: previewDir.appendingPathComponent("\(display.name)-\(screenIndex)-\(screen.month).png"))
                }
                window.contentView = nil
            }
        }

        func mean(_ key: KeyPath<ScreenScore, Double>) -> Double {
            all.map { $0[keyPath: key] }.reduce(0, +) / Double(all.count)
        }
        // Geometric mean, floored so one degenerate screen cannot zero the run.
        let logSum = all.map { log(max($0.beauty, 0.01)) }.reduce(0, +)
        let beauty = 100 * exp(logSum / Double(all.count))
        let worst = 100 * (all.map(\.beauty).min() ?? 0)
        print(String(format: "METRIC beauty=%.4f", beauty))
        print(String(format: "METRIC worst_screen=%.4f", worst))
        print(String(format: "METRIC coverage=%.4f", mean(\.coverage)))
        print(String(format: "METRIC crop_visible=%.4f", mean(\.crop)))
        print(String(format: "METRIC sharpness=%.4f", mean(\.sharp)))
        print(String(format: "METRIC upscale=%.4f", mean(\.upscale)))
        print(String(format: "METRIC tiles=%.3f", mean(\.count)))
        print(String(format: "METRIC count_term=%.4f", mean(\.countTerm)))
        print(String(format: "METRIC harmony=%.4f", mean(\.harmony)))
        print(String(format: "METRIC evenness=%.4f", mean(\.evenness)))
        print(String(format: "METRIC overlap=%.5f", mean(\.overlap)))
        print(String(format: "METRIC layout_ms=%.2f", 1000 * layoutSeconds / Double(all.count)))
    }
}
