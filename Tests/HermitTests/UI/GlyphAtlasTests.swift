import Testing
import Metal
@testable import SwiftTerm

@Suite("Glyph atlas memory backport")
struct GlyphAtlasTests {
    @Test("Growth preserves old glyph bytes, alpha masks and bitmap orientation", arguments: [false, true])
    func growPreservesGlyphs(grayscale: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 256, maxSize: 512, format: grayscale ? .grayscale : .bgra))
        let region = try #require(atlas.ensureRegion(width: 2, height: 2))
        let pixels: [UInt8] = [1,2,3,10, 4,5,6,20, 7,8,9,30, 10,11,12,40]
        atlas.write(region: region, pixels: pixels, width: 2, height: 2)
        let expected: [UInt8] = grayscale ? [30,40,10,20] : Array(pixels[8..<16])+Array(pixels[0..<8])
        #expect(read(atlas.texture, region: region, bytesPerPixel: grayscale ? 1 : 4) == expected)
        _ = try #require(atlas.ensureRegion(width: 256, height: 256))
        #expect(atlas.size == 512 && !atlas.didReset)
        #expect(read(atlas.texture, region: region, bytesPerPixel: grayscale ? 1 : 4) == expected)
    }
    @Test("Reset keeps unused texels transparent for the local linear sampler")
    func reuseAfterReset() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 256, maxSize: 256, format: .bgra))
        let full = try #require(atlas.ensureRegion(width: 256, height: 256))
        atlas.write(region: full, pixels: Array(repeating: 99, count: 256*256*4), width: 256, height: 256)
        let next = try #require(atlas.ensureRegion(width: 2, height: 2))
        #expect(atlas.didReset)
        atlas.write(region: next, pixels: Array(repeating: 7, count: 16), width: 2, height: 2)
        #expect(read(atlas.texture, region: next, bytesPerPixel: 4) == Array(repeating: 7, count: 16))
        #expect(read(atlas.texture, region: AtlasRegion(x: 200, y: 200, width: 2, height: 2), bytesPerPixel: 4) == Array(repeating: 0, count: 16))
    }
    private func read(_ texture: MTLTexture, region: AtlasRegion, bytesPerPixel: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: region.width*region.height*bytesPerPixel)
        data.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: region.width*bytesPerPixel,
                             from: MTLRegionMake2D(region.x, region.y, region.width, region.height), mipmapLevel: 0)
        }
        return data
    }
}
