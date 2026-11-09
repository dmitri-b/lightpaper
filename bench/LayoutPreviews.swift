// Renders full-resolution mock screens of candidate mosaic layouts using real
// Lightroom previews, so layouts can be compared by eye before one is built
// into the saver. Usage: layout-previews <input.json> <outDir> <widthPx> <heightPx> <scale>
// input.json: {"<label>": ["/path/to/preview", ...], ...}

import AppKit
import CoreImage
import ImageIO
import Vision
struct Photo {
    let image: CGImage
    var w: CGFloat { CGFloat(image.width) }
    var h: CGFloat { CGFloat(image.height) }
    var aspect: CGFloat { w / h }
}

/// Same greedy look-alike filter as the saver's `deduplicateByLook` (feature print distance 0.7).
func deduplicate(_ photos: [Photo]) -> [Photo] {
    var kept: [(Photo, VNFeaturePrintObservation)] = []
    for p in photos {
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: p.image).perform([request])
        guard let print = request.results?.first else { continue }
        let isDuplicate = kept.contains { other in
            var d: Float = 0
            return (try? print.computeDistance(&d, to: other.1)) != nil && d < 0.7
        }
        if !isDuplicate { kept.append((p, print)) }
    }
    return kept.map(\.0)
}

func loadPhoto(_ path: String) -> Photo? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let pw = props[kCGImagePropertyPixelWidth] as? Int,
          let ph = props[kCGImagePropertyPixelHeight] as? Int,
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: max(pw, ph)
          ] as CFDictionary) else { return nil }
    return Photo(image: img)
}

/// Drawing surface in top-left-origin pixel coordinates.
final class Canvas {
    let ctx: CGContext
    let W: CGFloat, H: CGFloat, s: CGFloat
    init(width: Int, height: Int, scale: CGFloat) {
        W = CGFloat(width); H = CGFloat(height); s = scale
        ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
    }
    func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
    func fill(_ gray: CGFloat) {
        ctx.setFillColor(CGColor(gray: gray, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    }
    func rect(_ r: CGRect, gray: CGFloat, shadow: CGFloat = 0) {
        ctx.saveGState()
        if shadow > 0 { ctx.setShadow(offset: CGSize(width: 0, height: -shadow * 0.4), blur: shadow, color: CGColor(gray: 0, alpha: 0.7)) }
        ctx.setFillColor(CGColor(gray: gray, alpha: 1)); ctx.fill(flip(r))
        ctx.restoreGState()
    }
    /// Aspect-fill `p` into `r` (crops overflow).
    func fillPhoto(_ p: Photo, _ r: CGRect) {
        let k = max(r.width / p.w, r.height / p.h)
        let d = CGRect(x: r.midX - p.w * k / 2, y: r.midY - p.h * k / 2, width: p.w * k, height: p.h * k)
        ctx.saveGState(); ctx.clip(to: flip(r)); ctx.draw(p.image, in: flip(d)); ctx.restoreGState()
    }
    func save(_ url: URL) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// Greedy justified rows in `width` with gutter `g`, each row's natural height
/// as close as possible to `target`. Returns (photo indices, natural height).
func justifiedRows(_ photos: ArraySlice<Photo>, width: CGFloat, target: CGFloat, g: CGFloat, maxRows: Int) -> [([Photo], CGFloat)] {
    var rows: [([Photo], CGFloat)] = []
    var i = photos.startIndex
    while i < photos.endIndex, rows.count < maxRows {
        var row: [Photo] = []; var asp: CGFloat = 0; var best: CGFloat = .greatestFiniteMagnitude
        while i < photos.endIndex {
            let p = photos[i]
            let h = (width - g * CGFloat(row.count)) / (asp + p.aspect)
            if !row.isEmpty, abs(h - target) > abs(best - target) { break }
            row.append(p); asp += p.aspect; best = h; i += 1
        }
        rows.append((row, best))
    }
    return rows
}

/// Lays rows into `area` with every row exactly `rowH` tall (aspect-fill absorbs the difference).
func drawRows(_ c: Canvas, _ rows: [([Photo], CGFloat)], in area: CGRect, g: CGFloat) {
    let rowH = (area.height - g * CGFloat(rows.count - 1)) / CGFloat(rows.count)
    var y = area.minY
    for (row, _) in rows {
        let asp = row.reduce(0) { $0 + $1.aspect }
        let usable = area.width - g * CGFloat(row.count - 1)
        var x = area.minX
        for (j, p) in row.enumerated() {
            let w = j == row.count - 1 ? area.maxX - x : (usable * p.aspect / asp).rounded()
            c.fillPhoto(p, CGRect(x: x, y: y, width: w, height: rowH))
            x += w + g
        }
        y += rowH + g
    }
}

// MARK: Layouts

/// Port of the saver's current composeRows/sinkSmallRowsLast/fill logic.
func layoutCurrent(_ c: Canvas, _ photos: [Photo]) {
    c.fill(0)
    let W = c.W / c.s, vh = c.H / c.s
    let targets = [min(max(vh * 0.66, 460), 1300), min(max(vh * 0.50, 360), 1040),
                   min(max(vh * 0.60, 420), 1180), min(max(vh * 0.46, 320), 940)]
    var rows: [([Photo], CGFloat)] = []; var total: CGFloat = 0; var i = 0
    while i < photos.count {
        var row: [Photo] = []; var asp: CGFloat = 0; var minH = CGFloat.greatestFiniteMagnitude; var settled = false
        let t = targets[rows.count % targets.count]
        while i < photos.count {
            let p = photos[i]; row.append(p); asp += p.aspect; minH = min(minH, p.h / c.s); i += 1
            if W / asp <= min(t, minH * 2.4) { settled = true; break }
        }
        if !settled { break }
        let h = min(W / asp, minH * 2.4); rows.append((row, h)); total += h
        if total >= vh { break }
    }
    func score(_ p: Photo) -> CGFloat { p.w * p.h * p.h }
    let scores = rows.flatMap { $0.0.map(score) }.sorted()
    let cut = scores[scores.count / 2] * 0.85
    rows = rows.filter { !$0.0.contains { score($0) < cut } } + rows.filter { $0.0.contains { score($0) < cut } }
    let fill = min(1, vh / total)
    var y: CGFloat = 0
    for (row, h) in rows {
        let asp = row.reduce(0) { $0 + $1.aspect }; var x: CGFloat = 0
        for (j, p) in row.enumerated() {
            let w = j == row.count - 1 ? W - x : W * p.aspect / asp
            c.fillPhoto(p, CGRect(x: x * c.s, y: y * c.s, width: w * c.s, height: h * fill * c.s))
            x += w
        }
        y += h * fill
    }
}

/// A: justified rows, thin gutters, equal row heights, always full.
func layoutA(_ c: Canvas, _ photos: [Photo]) {
    c.fill(0)
    let g = gutterPt * c.s, k = c.W > c.H ? 3 : 4
    let area = CGRect(x: g, y: g, width: c.W - 2 * g, height: c.H - 2 * g)
    let target = (area.height - g * CGFloat(k - 1)) / CGFloat(k)
    drawRows(c, justifiedRows(photos[...], width: area.width, target: target, g: g, maxRows: k), in: area, g: g)
}

/// B: one hero (largest landscape near the front) + justified grid beside it.
func layoutB(_ c: Canvas, _ photos: [Photo]) {
    c.fill(0)
    let g = gutterPt * c.s
    let heroIndex = photos.prefix(12).indices.max { a, b in
        let sa = (photos[a].aspect > 1.1 ? 1e9 : 0) + photos[a].w * photos[a].h
        let sb = (photos[b].aspect > 1.1 ? 1e9 : 0) + photos[b].w * photos[b].h
        return sa < sb
    }!
    var rest = photos; let hero = rest.remove(at: heroIndex)
    let heroRect = CGRect(x: g, y: g, width: ((c.W - 3 * g) * 0.6).rounded(), height: c.H - 2 * g)
    c.fillPhoto(hero, heroRect)
    let side = CGRect(x: heroRect.maxX + g, y: g, width: c.W - heroRect.maxX - 2 * g, height: c.H - 2 * g)
    let k = 3, target = (side.height - g * CGFloat(k - 1)) / CGFloat(k)
    drawRows(c, justifiedRows(rest[...], width: side.width, target: target, g: g, maxRows: k), in: side, g: g)
}

/// C: one centred row of 3-5 uncropped photos, cinematic bands.
func layoutC(_ c: Canvas, _ photos: [Photo]) {
    c.fill(0)
    let g = 16 * c.s, m = 64 * c.s
    var best: (n: Int, h: CGFloat) = (3, 0); var bestErr = CGFloat.greatestFiniteMagnitude
    for n in 3...5 {
        let asp = photos.prefix(n).reduce(0) { $0 + $1.aspect }
        let h = min((c.W - 2 * m - g * CGFloat(n - 1)) / asp, c.H * 0.72)
        let err = abs(h - c.H * 0.62)
        if err < bestErr { bestErr = err; best = (n, h) }
    }
    let row = Array(photos.prefix(best.n))
    let widths = row.map { ($0.aspect * best.h).rounded() }
    var x = (c.W - widths.reduce(0, +) - g * CGFloat(row.count - 1)) / 2
    let y = ((c.H - best.h) / 2).rounded()
    for (p, w) in zip(row, widths) {
        c.fillPhoto(p, CGRect(x: x, y: y, width: w, height: best.h)); x += w + g
    }
}

/// D: masonry — equal-width columns, each photo to the shortest column, columns
/// trimmed to the screen height by aspect-fill.
func layoutD(_ c: Canvas, _ photos: [Photo]) {
    c.fill(0)
    let g = gutterPt * c.s, n = c.W > c.H ? 4 : 3
    let colW = ((c.W - g * CGFloat(n + 1)) / CGFloat(n)).rounded(.down)
    var cols = Array(repeating: [Photo](), count: n)
    var heights = Array(repeating: CGFloat(0), count: n)
    let avail = c.H - 2 * g
    for p in photos {
        guard let j = heights.indices.filter({ heights[$0] < avail }).min(by: { heights[$0] < heights[$1] }) else { break }
        heights[j] += (cols[j].isEmpty ? 0 : g) + colW / p.aspect
        cols[j].append(p)
    }
    for j in 0..<n {
        // Drop the overflowing last tile if that lands closer to the screen height.
        if cols[j].count > 1 {
            let without = heights[j] - g - colW / cols[j].last!.aspect
            if abs(without - avail) < abs(heights[j] - avail) { cols[j].removeLast(); heights[j] = without }
        }
        let natural = cols[j].map { colW / $0.aspect }
        let f = (avail - g * CGFloat(cols[j].count - 1)) / natural.reduce(0, +)
        var y = g; let x = g + CGFloat(j) * (colW + g)
        for (k, p) in cols[j].enumerated() {
            let h = k == cols[j].count - 1 ? c.H - g - y : (natural[k] * f).rounded()
            c.fillPhoto(p, CGRect(x: x, y: y, width: colW, height: h)); y += h + g
        }
    }
}

/// E: gallery wall — five matted, uncropped prints on charcoal.
func layoutE(_ c: Canvas, _ photos: [Photo]) {
    c.fill(0.11)
    let mat = 14 * c.s, gap = 48 * c.s, side = 96 * c.s, vgap = 56 * c.s
    let rowsSpec = [Array(photos.prefix(3)), Array(photos.dropFirst(3).prefix(2))]
    var rowH = (c.H - 2 * 80 * c.s - vgap) / 2 - 2 * mat
    for row in rowsSpec {
        let width = row.reduce(0) { $0 + $1.aspect * rowH + 2 * mat } + gap * CGFloat(row.count - 1)
        if width > c.W - 2 * side { rowH *= (c.W - 2 * side - gap * CGFloat(row.count - 1) - 2 * mat * CGFloat(row.count)) / (width - gap * CGFloat(row.count - 1) - 2 * mat * CGFloat(row.count)) }
    }
    let blockH = 2 * (rowH + 2 * mat) + vgap
    var y = (c.H - blockH) / 2
    for row in rowsSpec {
        let widths = row.map { ($0.aspect * rowH).rounded() }
        var x = (c.W - widths.reduce(0) { $0 + $1 + 2 * mat } - gap * CGFloat(row.count - 1)) / 2
        for (p, w) in zip(row, widths) {
            let frame = CGRect(x: x, y: y, width: w + 2 * mat, height: rowH + 2 * mat)
            c.rect(frame, gray: 0.96, shadow: 28 * c.s)
            c.fillPhoto(p, frame.insetBy(dx: mat, dy: mat))
            x += frame.width + gap
        }
        y += rowH + 2 * mat + vgap
    }
}

/// Gutter between tiles, in points.
nonisolated(unsafe) var gutterPt: CGFloat = 6

/// F: one photo near native size over a blurred, darkened copy of itself.
func layoutF(_ c: Canvas, _ photos: [Photo]) {
    let p = photos[0]
    // Blur at source resolution, then enlarge: a soft, colour-faithful wash.
    let k = max(c.W / p.w, c.H / p.h)
    let blurred = CIImage(cgImage: p.image).clampedToExtent()
        .applyingGaussianBlur(sigma: 18)
        .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.3])
        .transformed(by: CGAffineTransform(scaleX: k, y: k))
    let ox = (p.w * k - c.W) / 2, oy = (p.h * k - c.H) / 2
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctxCI = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
    if let bg = ctxCI.createCGImage(blurred, from: CGRect(x: ox, y: oy, width: c.W, height: c.H), format: .RGBA8, colorSpace: srgb) {
        c.ctx.draw(bg, in: CGRect(x: 0, y: 0, width: c.W, height: c.H))
    }
    let fit = min(c.W * 0.86 / p.w, c.H * 0.84 / p.h, 2.2)
    let r = CGRect(x: ((c.W - p.w * fit) / 2).rounded(), y: ((c.H - p.h * fit) / 2).rounded(), width: (p.w * fit).rounded(), height: (p.h * fit).rounded())
    c.rect(r, gray: 0, shadow: 40 * c.s)
    c.fillPhoto(p, r)
}

let args = CommandLine.arguments
let input = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
let width = Int(args[3])!, height = Int(args[4])!, scale = CGFloat(Double(args[5])!)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
func flush(_ layout: @escaping (Canvas, [Photo]) -> Void) -> (Canvas, [Photo]) -> Void {
    { c, p in gutterPt = 0; layout(c, p); gutterPt = 6 }
}
let layouts: [(String, (Canvas, [Photo]) -> Void)] = [
    ("0-current", layoutCurrent), ("A-justified", layoutA), ("B-hero", layoutB), ("C-strip", layoutC),
    ("D-masonry", layoutD), ("E-gallery", layoutE), ("F-single", layoutF),
    ("A-justified-nogap", flush(layoutA)), ("B-hero-nogap", flush(layoutB)), ("D-masonry-nogap", flush(layoutD))
]
for (label, paths) in input.sorted(by: { $0.key < $1.key }) {
    let photos = deduplicate(paths.compactMap(loadPhoto))
    for (name, layout) in layouts {
        let c = Canvas(width: width, height: height, scale: scale)
        layout(c, photos)
        c.save(outDir.appendingPathComponent("\(label)-\(name).png"))
    }
    print("rendered \(label): \(photos.count) photos")
}
