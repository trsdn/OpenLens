import CoreVideo
import Metal
import XCTest

/// Exercises the real Metal pass end to end: a synthetic camera frame goes in,
/// the output buffer is read back and its pixels are asserted.
///
/// The crop is the product's headline feature and it lives entirely in the
/// shader, so a geometry unit test alone would not catch a flipped axis or a
/// mis-sized uniform struct.
final class VideoRendererTests: XCTestCase {
    private var renderer: VideoRenderer!

    override func setUpWithError() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "No Metal device")
        renderer = try VideoRenderer()
    }

    // MARK: - Fixtures

    /// A 1280x720 BGRA frame: red on the left half, blue on the right half.
    private func makeSourceBuffer() throws -> CVPixelBuffer {
        let width = 1280
        let height = 720
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &buffer
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(buffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let pixel = row.advanced(by: x * 4)
                let isLeft = x < width / 2
                pixel[0] = isLeft ? 0 : 255   // B
                pixel[1] = 0                  // G
                pixel[2] = isLeft ? 255 : 0   // R
                pixel[3] = 255
            }
        }
        return pixelBuffer
    }

    private func makeOverlay(rect: CGRect) throws -> OverlayTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        // Opaque green, premultiplied (which for a fully opaque pixel is a no-op).
        var pixels = [UInt8](repeating: 0, count: 2 * 2 * 4)
        for index in 0..<4 {
            pixels[index * 4 + 1] = 255
            pixels[index * 4 + 3] = 255
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: 8
        )
        return OverlayTexture(
            texture: texture,
            rect: rect,
            opacity: 1,
            pixelSize: CGSize(width: 2, height: 2)
        )
    }

    // MARK: - Helpers

    /// Renders and reads back, sampling at a fraction of the output size.
    private func render(_ frame: VideoRenderer.Frame) throws -> CVPixelBuffer {
        let output = try XCTUnwrap(renderer.renderToOutputBuffer(frame))
        // The command buffer is committed but not waited on in the hot path, so
        // the test has to give the GPU a moment before reading the surface.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !isBlank(output) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return output
    }

    private func isBlank(_ buffer: CVPixelBuffer) -> Bool {
        guard let pixel = try? sample(buffer, atX: 0.5, y: 0.5) else { return true }
        return pixel.r == 0 && pixel.g == 0 && pixel.b == 0
    }

    private func sample(
        _ buffer: CVPixelBuffer,
        atX xFraction: CGFloat,
        y yFraction: CGFloat
    ) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let x = Int(CGFloat(CVPixelBufferGetWidth(buffer) - 1) * xFraction)
        let y = Int(CGFloat(CVPixelBufferGetHeight(buffer) - 1) * yFraction)
        let pixel = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        return (r: pixel[2], g: pixel[1], b: pixel[0])
    }

    private func assertDominant(
        _ channel: WritableKeyPath<SIMD3<Int>, Int>,
        _ pixel: (r: UInt8, g: UInt8, b: UInt8),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var values = SIMD3<Int>(Int(pixel.r), Int(pixel.g), Int(pixel.b))
        let dominant = values[keyPath: channel]
        values[keyPath: channel] = -1
        XCTAssertGreaterThan(dominant, 180, "expected a saturated channel", file: file, line: line)
        XCTAssertLessThan(values.max(), 80, "expected the other channels dark", file: file, line: line)
    }

    // MARK: - Tests

    func testCropSelectsTheLeftHalfOfTheSource() throws {
        let output = try render(
            VideoRenderer.Frame(
                pixelBuffer: try makeSourceBuffer(),
                crop: CGRect(x: 0, y: 0, width: 0.5, height: 1),
                mirror: false,
                overlay: nil
            )
        )
        // The whole output must now be the red half, edge to edge.
        for x in [0.02, 0.5, 0.98] {
            assertDominant(\.x, try sample(output, atX: x, y: 0.5))
        }
    }

    func testCropSelectsTheRightHalfOfTheSource() throws {
        let output = try render(
            VideoRenderer.Frame(
                pixelBuffer: try makeSourceBuffer(),
                crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                mirror: false,
                overlay: nil
            )
        )
        for x in [0.02, 0.5, 0.98] {
            assertDominant(\.z, try sample(output, atX: x, y: 0.5))
        }
    }

    func testMirrorFlipsTheImageHorizontally() throws {
        let output = try render(
            VideoRenderer.Frame(
                pixelBuffer: try makeSourceBuffer(),
                crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                mirror: true,
                overlay: nil
            )
        )
        // Red lives on the left of the source, so mirroring puts it on the right.
        assertDominant(\.z, try sample(output, atX: 0.1, y: 0.5))
        assertDominant(\.x, try sample(output, atX: 0.9, y: 0.5))
    }

    func testOverlayIsCompositedOverTheLeftHalfOfTheOutput() throws {
        let output = try render(
            VideoRenderer.Frame(
                pixelBuffer: try makeSourceBuffer(),
                crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                mirror: false,
                overlay: try makeOverlay(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
            )
        )
        assertDominant(\.y, try sample(output, atX: 0.25, y: 0.5))
        // Outside the overlay rect the cropped source must be untouched.
        assertDominant(\.z, try sample(output, atX: 0.75, y: 0.5))
    }

    func testOverlayOpacityBlendsWithTheSource() throws {
        var overlay = try makeOverlay(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        overlay.opacity = 0.5
        let output = try render(
            VideoRenderer.Frame(
                pixelBuffer: try makeSourceBuffer(),
                crop: CGRect(x: 0, y: 0, width: 0.5, height: 1),
                mirror: false,
                overlay: overlay
            )
        )
        let pixel = try sample(output, atX: 0.5, y: 0.5)
        XCTAssertGreaterThan(Int(pixel.g), 60, "half-opacity green should be visible")
        XCTAssertGreaterThan(Int(pixel.r), 60, "the red source should still show through")
    }
}
