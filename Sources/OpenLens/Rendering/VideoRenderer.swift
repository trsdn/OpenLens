import CoreVideo
import Foundation
import Metal
import QuartzCore
import simd

/// Layout must match `RenderUniforms` in Shaders.metal.
struct RenderUniforms {
    var cropRect: SIMD4<Float>
    var overlayRect: SIMD4<Float>
    var overlayOpacity: Float
    var mirror: Float
    var lumaOffset: Float
    var lumaScale: Float
    var exposureGain: Float
    var blackLevel: Float
    var levelsGain: Float
    var midtoneExponent: Float
    var contrastAmount: Float
    var saturationGain: Float
    var temperatureShift: Float
    var tintShift: Float
    var shadowShift: Float
    var highlightShift: Float
}

/// The whole image pipeline: one Metal pass that crops, scales and composites.
///
/// Nothing here ever maps a pixel buffer to the CPU. Camera buffers arrive
/// IOSurface-backed, are wrapped as Metal textures through a texture cache, and
/// the result is written straight into another IOSurface that gets handed to the
/// system extension.
final class VideoRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let biplanarPipeline: MTLRenderPipelineState
    private let bgraPipeline: MTLRenderPipelineState

    /// One pipeline per source layout; the NV12 output needs both planes.
    private struct Planar {
        let biplanar: MTLRenderPipelineState
        let bgra: MTLRenderPipelineState

        func pipeline(isBiplanarSource: Bool) -> MTLRenderPipelineState {
            isBiplanarSource ? biplanar : bgra
        }
    }

    private let lumaPipelines: Planar
    private let chromaPipelines: Planar
    private let textureCache: CVMetalTextureCache
    private let blankOverlay: MTLTexture

    private var outputPool: CVPixelBufferPool?
    private var outputPoolSize = CGSize.zero

    /// Keeps the CVMetalTexture wrappers alive until the GPU is done with them.
    private var inFlightTextures: [CVMetalTexture] = []

    enum RendererError: Error {
        case noDevice
        case libraryUnavailable
        case pipelineCreationFailed
        case textureCacheCreationFailed
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noDevice }
        self.commandQueue = queue

        // Resolving the library from the bundle that owns this class rather than
        // the main bundle lets the render pass run inside a unit-test bundle too.
        let library: MTLLibrary
        if let bundled = try? device.makeDefaultLibrary(bundle: Bundle(for: VideoRenderer.self)) {
            library = bundled
        } else if let main = device.makeDefaultLibrary() {
            library = main
        } else {
            throw RendererError.libraryUnavailable
        }

        func makePipeline(fragment: String, format: MTLPixelFormat = .bgra8Unorm) throws
            -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "openlens_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
                throw RendererError.pipelineCreationFailed
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        biplanarPipeline = try makePipeline(fragment: "openlens_fragment_biplanar")
        bgraPipeline = try makePipeline(fragment: "openlens_fragment_bgra")
        lumaPipelines = Planar(
            biplanar: try makePipeline(
                fragment: "openlens_fragment_luma_biplanar",
                format: .r8Unorm
            ),
            bgra: try makePipeline(fragment: "openlens_fragment_luma_bgra", format: .r8Unorm)
        )
        chromaPipelines = Planar(
            biplanar: try makePipeline(
                fragment: "openlens_fragment_chroma_biplanar",
                format: .rg8Unorm
            ),
            bgra: try makePipeline(fragment: "openlens_fragment_chroma_bgra", format: .rg8Unorm)
        )

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                == kCVReturnSuccess,
              let cache
        else { throw RendererError.textureCacheCreationFailed }
        textureCache = cache

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let blank = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.pipelineCreationFailed
        }
        var clear: UInt32 = 0
        blank.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &clear,
            bytesPerRow: 4
        )
        blankOverlay = blank
    }

    // MARK: - Public API

    struct Frame {
        var pixelBuffer: CVPixelBuffer
        var crop: CGRect
        var mirror: Bool
        var overlay: OverlayTexture?
        var adjustments: ImageAdjustments = .neutral
    }

    /// Renders into a pooled NV12 buffer destined for the virtual camera.
    func renderToOutputBuffer(_ frame: Frame) -> CVPixelBuffer? {
        let size = CGSize(width: OpenLensOutput.width, height: OpenLensOutput.height)
        guard let pool = pool(for: size) else { return nil }

        var output: CVPixelBuffer?
        // Fail the allocation rather than growing the pool without bound. If the
        // extension ever stops draining, dropping this frame is the right answer;
        // queueing more of them only adds latency and memory.
        let auxAttributes: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: 6]
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                auxAttributes as CFDictionary,
                &output
              ) == kCVReturnSuccess,
              let output,
              let luma = makeTexture(from: output, plane: 0, format: .r8Unorm),
              let chroma = makeTexture(from: output, plane: 1, format: .rg8Unorm)
        else { return nil }

        let isBiplanar = Self.isBiplanar(frame.pixelBuffer)
        // Both planes go into one command buffer: the source textures, uniforms
        // and GPU submission are shared, so the second plane costs little beyond
        // its own (quarter-size) fragment work.
        let passes = [
            Pass(pipeline: lumaPipelines.pipeline(isBiplanarSource: isBiplanar), texture: luma),
            Pass(pipeline: chromaPipelines.pipeline(isBiplanarSource: isBiplanar), texture: chroma)
        ]
        guard encode(frame, passes: passes, present: nil) else { return nil }

        // Only the matrix is signalled. A consumer needs it to decode the two
        // planes, and getting it wrong is visible. Primaries and transfer
        // function are display characteristics that every conferencing app
        // assumes to be 709/sRGB anyway — and tagging them made CoreMedia
        // synthesise an ICC profile, which it then rebuilt into a gamma LUT on
        // every single frame.
        CVBufferSetAttachment(
            output, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate
        )
        return output
    }

    /// A fully black frame in the virtual camera's output format.
    ///
    /// This is what a pause sends. A frozen still of the room reads as live
    /// video to whoever is watching, which is the one thing someone who steps
    /// away does not want; black is unambiguous.
    ///
    /// Static and self-allocating on purpose: it is called from the main thread
    /// while the capture queue is inside `renderToOutputBuffer`, so it must not
    /// touch the renderer's pool or texture cache. One buffer per pause is not
    /// worth a shared pool anyway.
    static func makeBlackOutputBuffer() -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            OpenLensOutput.width,
            OpenLensOutput.height,
            OpenLensOutput.pixelFormat,
            attributes as CFDictionary,
            &output
        ) == kCVReturnSuccess, let output else { return nil }

        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }

        // Video-range NV12 black is luma 16 and neutral chroma 128. Zeroing both
        // planes instead — the obvious shortcut — produces a green frame.
        let fills: [(plane: Int, value: Int32)] = [(0, 16), (1, 128)]
        for fill in fills {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(output, fill.plane)
            else { return nil }
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(output, fill.plane)
                * CVPixelBufferGetHeightOfPlane(output, fill.plane)
            memset(base, fill.value, bytes)
        }

        CVBufferSetAttachment(
            output, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate
        )
        return output
    }

    /// Blocks until everything submitted so far has finished on the GPU.
    ///
    /// Command buffers on a single queue complete in order, so an empty one
    /// submitted last is a barrier. This exists for tests, which have to read an
    /// output surface back and would otherwise race the GPU; the live path never
    /// waits, which is the whole point of handing the buffer straight on.
    func waitUntilIdle() {
        let barrier = commandQueue.makeCommandBuffer()
        barrier?.commit()
        barrier?.waitUntilCompleted()
    }

    /// Renders straight into a `CAMetalLayer` drawable for the preview.
    ///
    /// `completion` fires once the frame has been presented, which is what lets
    /// the caller keep exactly one preview render in flight instead of blocking
    /// on `nextDrawable()`.
    func renderToDrawable(
        _ frame: Frame,
        drawable: CAMetalDrawable,
        completion: @escaping @Sendable () -> Void
    ) {
        let pipeline = Self.isBiplanar(frame.pixelBuffer) ? biplanarPipeline : bgraPipeline
        let pass = Pass(pipeline: pipeline, texture: drawable.texture)
        if !encode(frame, passes: [pass], present: drawable, completion: completion) {
            completion()
        }
    }

    // MARK: - Encoding

    private struct Pass {
        let pipeline: MTLRenderPipelineState
        let texture: MTLTexture
    }

    private static func isBiplanar(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    private func encode(
        _ frame: Frame,
        passes: [Pass],
        present drawable: CAMetalDrawable?,
        completion: (@Sendable () -> Void)? = nil
    ) -> Bool {
        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let isBiplanar = Self.isBiplanar(frame.pixelBuffer)

        var sourceTextures: [MTLTexture] = []
        if isBiplanar {
            guard let luma = makeTexture(from: frame.pixelBuffer, plane: 0, format: .r8Unorm),
                  let chroma = makeTexture(from: frame.pixelBuffer, plane: 1, format: .rg8Unorm)
            else { return false }
            sourceTextures = [luma, chroma]
        } else {
            guard let bgra = makeTexture(from: frame.pixelBuffer, plane: 0, format: .bgra8Unorm)
            else { return false }
            sourceTextures = [bgra]
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        // Video range needs the 16...235 luma window expanded; full range does not.
        let isFullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var uniforms = RenderUniforms(
            cropRect: SIMD4<Float>(
                Float(frame.crop.origin.x),
                Float(frame.crop.origin.y),
                Float(frame.crop.width),
                Float(frame.crop.height)
            ),
            overlayRect: frame.overlay.map {
                SIMD4<Float>(
                    Float($0.rect.origin.x),
                    Float($0.rect.origin.y),
                    Float($0.rect.width),
                    Float($0.rect.height)
                )
            } ?? SIMD4<Float>(0, 0, 0, 0),
            overlayOpacity: Float(frame.overlay?.opacity ?? 0),
            mirror: frame.mirror ? 1 : 0,
            lumaOffset: isFullRange ? 0.0 : 16.0 / 255.0,
            lumaScale: isFullRange ? 1.0 : 255.0 / 219.0,
            exposureGain: Float(frame.adjustments.exposureGain),
            blackLevel: Float(frame.adjustments.blackLevel),
            levelsGain: Float(frame.adjustments.levelsGain),
            midtoneExponent: Float(frame.adjustments.midtoneExponent),
            contrastAmount: Float(frame.adjustments.contrastAmount),
            saturationGain: Float(frame.adjustments.saturationGain),
            temperatureShift: Float(frame.adjustments.temperatureShift),
            tintShift: Float(frame.adjustments.tintShift),
            shadowShift: Float(frame.adjustments.shadowShift),
            highlightShift: Float(frame.adjustments.highlightShift)
        )

        for pass in passes {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = pass.texture
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return false }

            encoder.setRenderPipelineState(pass.pipeline)
            for (index, texture) in sourceTextures.enumerated() {
                encoder.setFragmentTexture(texture, index: index)
            }
            encoder.setFragmentTexture(frame.overlay?.texture ?? blankOverlay, index: 2)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
            encoder.setFragmentBytes(
                &uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        if let drawable { commandBuffer.present(drawable) }

        let retained = inFlightTextures
        commandBuffer.addCompletedHandler { _ in
            _ = retained
            completion?()
        }
        inFlightTextures.removeAll(keepingCapacity: true)

        commandBuffer.commit()
        // The cache holds a reference to every texture it hands out; without a
        // periodic flush the IOSurfaces behind them are never released back to
        // the capture device's pool.
        flushTextureCache()
        return true
    }

    // MARK: - Buffers and textures

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let effectiveWidth = planeCount == 0 ? CVPixelBufferGetWidth(pixelBuffer) : width
        let effectiveHeight = planeCount == 0 ? CVPixelBufferGetHeight(pixelBuffer) : height

        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            format,
            effectiveWidth,
            effectiveHeight,
            plane,
            &textureRef
        )
        guard status == kCVReturnSuccess, let textureRef,
              let texture = CVMetalTextureGetTexture(textureRef)
        else { return nil }
        inFlightTextures.append(textureRef)
        return texture
    }

    private func pool(for size: CGSize) -> CVPixelBufferPool? {
        if let outputPool, outputPoolSize == size { return outputPool }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: OpenLensOutput.pixelFormat,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        // A shallow pool is deliberate: it bounds latency and memory, and the
        // extension is always a frame or two behind at most.
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]

        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess else { return nil }

        outputPool = pool
        outputPoolSize = size
        return pool
    }

    func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
