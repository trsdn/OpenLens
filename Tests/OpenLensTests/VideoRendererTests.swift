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
        // The hot path commits without waiting, so the test has to impose the
        // barrier itself. Polling for "not blank any more" is not enough: the
        // pool recycles surfaces, so a stale buffer looks finished immediately
        // and the assertions quietly read the previous frame instead.
        renderer.waitUntilIdle()
        return output
    }

    /// Reads back an NV12 pixel and decodes it to RGB.
    ///
    /// The output plane layout is the product of the shader's colour conversion,
    /// so decoding it here with the inverse BT.601 video-range transform is what
    /// proves the conversion is correct rather than merely plausible: a wrong
    /// matrix, range or plane order turns a saturated primary into mud and every
    /// dominance assertion below fails.
    private func sample(
        _ buffer: CVPixelBuffer,
        atX xFraction: CGFloat,
        y yFraction: CGFloat
    ) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let x = Int(CGFloat(CVPixelBufferGetWidth(buffer) - 1) * xFraction)
        let y = Int(CGFloat(CVPixelBufferGetHeight(buffer) - 1) * yFraction)

        let lumaBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = lumaBase.advanced(by: y * lumaStride + x)
            .assumingMemoryBound(to: UInt8.self)[0]

        let chromaBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chroma = chromaBase.advanced(by: (y / 2) * chromaStride + (x / 2) * 2)
            .assumingMemoryBound(to: UInt8.self)

        let luminance = (Double(luma) - 16) / 219
        let cb = (Double(chroma[0]) - 128) / 255
        let cr = (Double(chroma[1]) - 128) / 255

        func byte(_ value: Double) -> UInt8 {
            UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded()))
        }
        return (
            r: byte(luminance + 1.402 * cr),
            g: byte(luminance - 0.344136 * cb - 0.714136 * cr),
            b: byte(luminance + 1.772 * cb)
        )
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

    func testOutputIsNV12SoTheSinkMovesAThirdOfTheBytes() throws {
        let output = try render(
            VideoRenderer.Frame(
                pixelBuffer: try makeSourceBuffer(),
                crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                mirror: false,
                overlay: nil
            )
        )
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(output),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(CVPixelBufferGetPlaneCount(output), 2)
        // The chroma plane is subsampled 2x2; without that the format would cost
        // as much as BGRA and the whole change would be pointless.
        XCTAssertEqual(
            CVPixelBufferGetHeightOfPlane(output, 1),
            CVPixelBufferGetHeightOfPlane(output, 0) / 2
        )
    }

    func testPreviewNeverRendersMorePixelsThanAreTransmitted() {
        // A Retina-backed window would ask for far more than the output; a
        // sharper preview than the transmitted frame both wastes bandwidth and
        // hides the softness that a strong zoom introduces.
        let capped = PreviewRenderTarget.drawableSize(
            for: CGSize(width: 1244, height: 700),
            scale: 2
        )
        XCTAssertEqual(capped.width, CGFloat(OpenLensOutput.width))
        XCTAssertEqual(capped.height, CGFloat(OpenLensOutput.height))

        // A small window stays at its natural size — no upscaling either.
        let small = PreviewRenderTarget.drawableSize(
            for: CGSize(width: 400, height: 225),
            scale: 2
        )
        XCTAssertEqual(small.width, 800)
        XCTAssertEqual(small.height, 450)
    }

    // MARK: - Colour correction

    /// The camera's own format, which the BGRA fixture above does not exercise:
    /// every real source negotiates 4:2:0 biplanar, so the shaders that grade
    /// luma and chroma separately are the ones that actually ship.
    ///
    /// Red on the left, blue on the right, encoded with the same BT.601
    /// video-range constants the shader inverts.
    private func makeBiplanarSourceBuffer() throws -> CVPixelBuffer {
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
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes as CFDictionary,
                &buffer
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(buffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        // Y = 0.299R + 0.587G + 0.114B, scaled into the 16...235 window.
        func videoLuma(_ full: Double) -> UInt8 { UInt8((full * 219 + 16).rounded()) }
        let redLuma = videoLuma(0.299)
        let blueLuma = videoLuma(0.114)

        let lumaBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for y in 0..<height {
            let row = lumaBase.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x] = x < width / 2 ? redLuma : blueLuma
            }
        }

        func chroma(r: Double, g: Double, b: Double) -> (UInt8, UInt8) {
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            let cb = (b - y) / 1.772 + 0.5
            let cr = (r - y) / 1.402 + 0.5
            return (UInt8((cb * 255).rounded()), UInt8((cr * 255).rounded()))
        }
        let red = chroma(r: 1, g: 0, b: 0)
        let blue = chroma(r: 0, g: 0, b: 1)

        let chromaBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for y in 0..<(height / 2) {
            let row = chromaBase.advanced(by: y * chromaStride)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<(width / 2) {
                let value = x < width / 4 ? red : blue
                row[x * 2] = value.0
                row[x * 2 + 1] = value.1
            }
        }
        return pixelBuffer
    }

    /// A 1280x720 neutral grey ramp, dark on the left and light on the right.
    ///
    /// The red/blue fixture above cannot exercise the tonal controls: both of
    /// its halves are dark and saturated, so "did the shadows move" and "did
    /// the highlights survive" have nowhere to be measured. It also cannot show
    /// that the shadow and highlight tints stay in their own half of the scale,
    /// because a tint is only visible against grey.
    private func makeGreyRampSourceBuffer() throws -> CVPixelBuffer {
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
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes as CFDictionary,
                &buffer
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(buffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let lumaBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for y in 0..<height {
            let row = lumaBase.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let fraction = Double(x) / Double(width - 1)
                row[x] = UInt8((fraction * 219 + 16).rounded())
            }
        }

        // 128/128 is the chroma origin, so every pixel is a true neutral and
        // any colour in the output came from the grade rather than the source.
        let chromaBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for y in 0..<(height / 2) {
            let row = chromaBase.advanced(by: y * chromaStride)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<(width / 2) {
                row[x * 2] = 128
                row[x * 2 + 1] = 128
            }
        }
        return pixelBuffer
    }

    private func fullFrame(
        _ pixelBuffer: CVPixelBuffer,
        _ adjustments: ImageAdjustments
    ) -> VideoRenderer.Frame {
        VideoRenderer.Frame(
            pixelBuffer: pixelBuffer,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1),
            mirror: false,
            overlay: nil,
            adjustments: adjustments
        )
    }

    /// The most important property of the whole feature: with every slider
    /// centred the extra arithmetic must be a bit-exact no-op, otherwise simply
    /// shipping colour correction would change how everyone already looks.
    func testNeutralAdjustmentsLeaveTheBiplanarPictureUntouched() throws {
        let graded = try render(fullFrame(try makeBiplanarSourceBuffer(), .neutral))
        assertDominant(\.x, try sample(graded, atX: 0.1, y: 0.5))
        assertDominant(\.z, try sample(graded, atX: 0.9, y: 0.5))
    }

    func testExposureBrightensAndDarkensTheBiplanarPath() throws {
        let neutral = try luma(of: try render(fullFrame(try makeBiplanarSourceBuffer(), .neutral)))
        let brighter = try luma(
            of: try render(fullFrame(try makeBiplanarSourceBuffer(),
                                     ImageAdjustments(exposure: 1)))
        )
        let darker = try luma(
            of: try render(fullFrame(try makeBiplanarSourceBuffer(),
                                     ImageAdjustments(exposure: -1)))
        )
        XCTAssertGreaterThan(brighter, neutral + 10)
        XCTAssertLessThan(darker, neutral - 10)
    }

    func testFullyDesaturatingRemovesColour() throws {
        let output = try render(
            fullFrame(try makeBiplanarSourceBuffer(), ImageAdjustments(saturation: -1))
        )
        // The red half must come back as a neutral grey of the same brightness.
        let pixel = try sample(output, atX: 0.1, y: 0.5)
        let spread = Int(max(pixel.r, max(pixel.g, pixel.b)))
            - Int(min(pixel.r, min(pixel.g, pixel.b)))
        XCTAssertLessThan(spread, 12, "expected a grey pixel, got \(pixel)")
    }

    func testWhiteBalanceShiftsTowardsRedAndBlue() throws {
        let warm = try sample(
            try render(fullFrame(try makeBiplanarSourceBuffer(),
                                 ImageAdjustments(saturation: -1, temperature: 1))),
            atX: 0.1, y: 0.5
        )
        let cool = try sample(
            try render(fullFrame(try makeBiplanarSourceBuffer(),
                                 ImageAdjustments(saturation: -1, temperature: -1))),
            atX: 0.1, y: 0.5
        )
        // Starting from grey, warm must land on the red side and cool on the blue.
        XCTAssertGreaterThan(Int(warm.r), Int(warm.b))
        XCTAssertGreaterThan(Int(cool.b), Int(cool.r))
    }

    func testTintShiftsBetweenGreenAndMagenta() throws {
        // Against the light end of the neutral ramp, where there is enough
        // signal for a white balance to act on.
        let magenta = try sample(
            try render(fullFrame(try makeGreyRampSourceBuffer(), ImageAdjustments(tint: 1))),
            atX: 0.9, y: 0.5
        )
        let green = try sample(
            try render(fullFrame(try makeGreyRampSourceBuffer(), ImageAdjustments(tint: -1))),
            atX: 0.9, y: 0.5
        )
        XCTAssertGreaterThan(Int(magenta.r), Int(magenta.g))
        XCTAssertGreaterThan(Int(magenta.b), Int(magenta.g))
        XCTAssertGreaterThan(Int(green.g), Int(green.r))
        XCTAssertGreaterThan(Int(green.g), Int(green.b))
    }

    func testTintIsADifferentAxisFromWhiteBalance() throws {
        // If tint moved green the way temperature does — barely, and only as a
        // side effect of trading red against blue — it would be a duplicate
        // control. The point of a second axis is that it reaches a cast the
        // first one cannot.
        func greenDeviation(_ adjustments: ImageAdjustments) throws -> Int {
            let pixel = try sample(
                try render(fullFrame(try makeGreyRampSourceBuffer(), adjustments)),
                atX: 0.9, y: 0.5
            )
            return Int(pixel.g) - (Int(pixel.r) + Int(pixel.b)) / 2
        }
        let byTint = try greenDeviation(ImageAdjustments(tint: -1))
        let byTemperature = try greenDeviation(ImageAdjustments(temperature: 1))
        XCTAssertGreaterThan(byTint, abs(byTemperature) * 3)
    }

    /// The reason the global white balance controls scale with luma.
    ///
    /// A flat chroma offset is proportionally enormous on a near-black pixel: it
    /// drains the blue out of a black shirt and swings a dark neutral
    /// background green long before the correction reaches a lit face. Scaling
    /// by luma reproduces what a real white balance does — a per-channel gain in
    /// linear light, which leaves black alone because black carries no light to
    /// re-balance.
    func testGlobalWhiteBalanceLeavesBlackAloneButStillCorrectsHighlights() throws {
        for adjustments in [ImageAdjustments(temperature: 1),
                            ImageAdjustments(tint: -1),
                            ImageAdjustments(temperature: 1, tint: -1)] {
            let output = try render(fullFrame(try makeGreyRampSourceBuffer(), adjustments))
            func spread(atX x: CGFloat) throws -> Int {
                let pixel = try sample(output, atX: x, y: 0.5)
                let values = [Int(pixel.r), Int(pixel.g), Int(pixel.b)]
                return values.max()! - values.min()!
            }
            // The darkest column of the ramp is very nearly black.
            XCTAssertLessThan(
                try spread(atX: 0.01), 8,
                "a white balance must not tint black — \(adjustments)"
            )
            // The light end is what the control is actually for. Measured short
            // of the very top, where the ramp is already close enough to white
            // that the warmed channel clips and hides half the shift.
            XCTAssertGreaterThan(
                try spread(atX: 0.75), 25,
                "a white balance must still reach the highlights — \(adjustments)"
            )
        }
    }

    func testSplitToneControlsStillReachTheShadows() throws {
        // The counterpart to the test above: the shadow tint deliberately stays
        // a flat offset, because tinting the darkest part of the picture is the
        // entire point of a split tone. Scaling it by luma would cancel it
        // against its own weighting curve and silently disable the control.
        let output = try render(
            fullFrame(try makeGreyRampSourceBuffer(), ImageAdjustments(shadowWarmth: 1))
        )
        let dark = try sample(output, atX: 0.05, y: 0.5)
        XCTAssertGreaterThan(Int(dark.r), Int(dark.b) + 20)
    }

    func testAdjustmentsAlsoApplyToBGRASources() throws {        let neutral = try luma(of: try render(fullFrame(try makeSourceBuffer(), .neutral)))
        let brighter = try luma(
            of: try render(fullFrame(try makeSourceBuffer(), ImageAdjustments(exposure: 1)))
        )
        XCTAssertGreaterThan(brighter, neutral + 10)
    }

    // MARK: - Levels, contrast curve and split tinting

    func testBlackPointDeepensTheShadowsAndLeavesTheHighlightsAlone() throws {
        let neutral = try render(fullFrame(try makeGreyRampSourceBuffer(), .neutral))
        let graded = try render(
            fullFrame(try makeGreyRampSourceBuffer(), ImageAdjustments(blackPoint: 0.5))
        )
        // The dark end is what the control is for.
        XCTAssertLessThan(
            try luma(of: graded, atX: 0.15), try luma(of: neutral, atX: 0.15) - 10
        )
        // White is an anchor of the mapping, so the bright end must barely move.
        XCTAssertEqual(
            try luma(of: graded, atX: 0.98),
            try luma(of: neutral, atX: 0.98),
            accuracy: 3
        )
    }

    func testContrastDoesNotClipTheHighlightsTheWayAStraightSlopeWould() throws {
        let neutral = try render(fullFrame(try makeGreyRampSourceBuffer(), .neutral))
        let graded = try render(
            fullFrame(try makeGreyRampSourceBuffer(), ImageAdjustments(contrast: 1))
        )
        // Midtones steepen, which is the point of the control.
        XCTAssertGreaterThan(
            try luma(of: graded, atX: 0.75), try luma(of: neutral, atX: 0.75) + 5
        )
        XCTAssertLessThan(try luma(of: graded, atX: 0.25), try luma(of: neutral, atX: 0.25) - 5)
        // A linear (y - 0.5) * 1.5 would drive everything above ~0.83 to white
        // and flatten the brightest skin into a single flat patch. The curve
        // has to leave the top of the ramp separable instead.
        XCTAssertGreaterThan(try luma(of: graded, atX: 1.0), try luma(of: graded, atX: 0.9) + 2)
    }

    func testShadowAndHighlightTintsStayInTheirOwnHalfOfTheScale() throws {
        let warmShadows = try render(
            fullFrame(try makeGreyRampSourceBuffer(), ImageAdjustments(shadowWarmth: 1))
        )
        let dark = try sample(warmShadows, atX: 0.08, y: 0.5)
        let light = try sample(warmShadows, atX: 0.95, y: 0.5)
        // The dark end picks up the warmth...
        XCTAssertGreaterThan(Int(dark.r), Int(dark.b) + 8)
        // ...and the light end must not, or this would just be white balance
        // under another name and the split would buy nothing.
        XCTAssertEqual(Int(light.r), Int(light.b), accuracy: 6)

        let coolHighlights = try render(
            fullFrame(try makeGreyRampSourceBuffer(), ImageAdjustments(highlightWarmth: -1))
        )
        let brightPixel = try sample(coolHighlights, atX: 0.95, y: 0.5)
        let darkPixel = try sample(coolHighlights, atX: 0.08, y: 0.5)
        XCTAssertGreaterThan(Int(brightPixel.b), Int(brightPixel.r) + 8)
        XCTAssertEqual(Int(darkPixel.r), Int(darkPixel.b), accuracy: 6)
    }

    /// Reads the raw luma byte, which is what exposure and contrast move.
    private func luma(of buffer: CVPixelBuffer, atX xFraction: CGFloat = 0.1) throws -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let x = Int(CGFloat(CVPixelBufferGetWidth(buffer) - 1) * xFraction)
        let y = CVPixelBufferGetHeight(buffer) / 2
        return Int(base.advanced(by: y * stride + x).assumingMemoryBound(to: UInt8.self)[0])
    }
}
