#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Metal

struct AtlasRegion {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct GlyphBitmap {
    let width: Int
    let height: Int
    let bearing: CGPoint
    let pixels: [UInt8]
    let isColor: Bool
}

enum GlyphAtlasFormat {
    case grayscale
    case bgra

    var bytesPerPixel: Int {
        switch self {
        case .grayscale:
            return 1
        case .bgra:
            return 4
        }
    }

    var pixelFormat: MTLPixelFormat {
        switch self {
        case .grayscale:
            return .r8Unorm
        case .bgra:
            return .bgra8Unorm
        }
    }
}

final class GlyphAtlas {
    private let device: MTLDevice
    private let format: GlyphAtlasFormat
    private let bytesPerPixel: Int
    private let maxSize: Int
    private(set) var size: Int
    private(set) var texture: MTLTexture
    private var nextX = 0
    private var nextY = 0
    private var rowHeight = 0
    private(set) var didReset = false

    init?(device: MTLDevice, size: Int = 1024, maxSize: Int = 2048, format: GlyphAtlasFormat = .bgra) {
        self.device = device
        self.format = format
        self.bytesPerPixel = format.bytesPerPixel
        let clampedMin = max(size, 256)
        self.maxSize = max(maxSize, clampedMin)
        self.size = clampedMin
        guard let texture = GlyphAtlas.makeTexture(device: device, size: self.size, format: format) else {
            return nil
        }
        self.texture = texture
    }

    func ensureRegion(width: Int, height: Int) -> AtlasRegion? {
        didReset = false
        if width <= 0 || height <= 0 {
            return nil
        }
        if let region = reserve(width: width, height: height) {
            return region
        }
        if width > maxSize || height > maxSize {
            return nil
        }
        var newSize = size
        while newSize < maxSize && (newSize < max(width, height) || !canFit(width: width, height: height, size: newSize)) {
            newSize *= 2
        }
        if newSize > maxSize {
            newSize = maxSize
        }
        if newSize > size {
            grow(to: newSize)
            return reserve(width: width, height: height)
        }
        reset()
        didReset = true
        return reserve(width: width, height: height)
    }

    func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int) {
        guard width == region.width, height == region.height, width > 0, height > 0,
              region.x >= 0, region.y >= 0, width <= size, height <= size,
              region.x <= size - width, region.y <= size - height,
              pixels.count >= width * height * 4 else { return }
        // Keep only a glyph-sized upload buffer. A full CPU shadow doubled
        // the atlas memory for every terminal, even while nothing changed.
        let stride = width * bytesPerPixel
        let upload = [UInt8](unsafeUninitializedCapacity: stride * height) { buffer, initialized in
            pixels.withUnsafeBufferPointer { source in
                for row in 0..<height {
                    let sourceRow = source.baseAddress! + (height - 1 - row) * width * 4
                    let destination = buffer.baseAddress! + row * stride
                    switch format {
                    case .bgra: destination.update(from: sourceRow, count: stride)
                    case .grayscale:
                        for col in 0..<width { destination[col] = sourceRow[col * 4 + 3] }
                    }
                }
            }
            initialized = stride * height
        }
        upload.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(region.x, region.y, width, height),
                            mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: stride)
        }
    }

    private func reserve(width: Int, height: Int) -> AtlasRegion? {
        guard width <= size, height <= size else {
            return nil
        }
        if nextX + width > size {
            nextX = 0
            nextY += rowHeight
            rowHeight = 0
        }
        guard nextY + height <= size else {
            return nil
        }
        let region = AtlasRegion(x: nextX, y: nextY, width: width, height: height)
        nextX += width
        rowHeight = max(rowHeight, height)
        return region
    }

    private func canFit(width: Int, height: Int, size: Int) -> Bool {
        if width > size || height > size {
            return false
        }
        if nextY + height <= size {
            return true
        }
        return false
    }

    private func grow(to newSize: Int) {
        guard newSize > size else {
            return
        }
        guard let newTexture = GlyphAtlas.makeTexture(device: device, size: newSize, format: format) else {
            return
        }
        // Existing cache entries retain their coordinates after growth. The
        // readback buffer exists only for this copy, as in upstream PR #816.
        let oldRegion = MTLRegionMake2D(0, 0, size, size)
        let stride = size * bytesPerPixel
        let oldTexture = texture
        let pixels = [UInt8](unsafeUninitializedCapacity: stride * size) { buffer, initialized in
            oldTexture.getBytes(buffer.baseAddress!, bytesPerRow: stride, from: oldRegion, mipmapLevel: 0)
            initialized = stride * size
        }
        pixels.withUnsafeBytes { raw in
            newTexture.replace(region: oldRegion, mipmapLevel: 0,
                               withBytes: raw.baseAddress!, bytesPerRow: stride)
        }
        size = newSize
        texture = newTexture
    }

    private func reset() {
        // This fork uses linear sampling without upstream's padded glyphs.
        // Keep unused texels transparent so old neighbors cannot bleed into
        // a new glyph. The scratch block is transient, never atlas-sized.
        Self.clear(texture: texture, bytesPerPixel: bytesPerPixel)
        nextX = 0
        nextY = 0
        rowHeight = 0
    }

    private static func makeTexture(device: MTLDevice, size: Int, format: GlyphAtlasFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format.pixelFormat,
                                                                   width: size,
                                                                   height: size,
                                                                   mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        clear(texture: texture, bytesPerPixel: format.bytesPerPixel)
        return texture
    }

    private static func clear(texture: MTLTexture, bytesPerPixel: Int) {
        let rows = min(64, texture.height), stride = texture.width * bytesPerPixel
        let zeros = [UInt8](repeating: 0, count: stride * rows)
        zeros.withUnsafeBytes { bytes in
            for y in Swift.stride(from: 0, to: texture.height, by: rows) {
                texture.replace(region: MTLRegionMake2D(0, y, texture.width, min(rows, texture.height-y)),
                                mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: stride)
            }
        }
    }
}
#endif
