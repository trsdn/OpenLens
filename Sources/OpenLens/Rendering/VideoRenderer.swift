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

        func makePipeline(fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "openlens_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
                throw RendererError.pipelineCreationFailed
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        biplanarPipeline = try makePipeline(fragment: "openlens_fragment_biplanar")
        bgraPipeline = try makePipeline(fragment: "openlens_fragment_bgra")

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
    }

    /// Renders into a pooled output buffer destined for the virtual camera.
    func renderToOutputBuffer(_ frame: Frame) -> CVPixelBuffer? {
        let size = CGSize(width: OpenLensOutput.width, height: OpenLensOutput.height)
        guard let pool = pool(for: size) else { return nil }

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
                == kCVReturnSuccess,
              let output,
              let destination = makeTexture(from: output, plane: 0, format: .bgra8Unorm)
        else { return nil }

        guard encode(frame, into: destination, present: nil) else { return nil }
        return output
    }

    /// Renders straight into a `CAMetalLayer` drawable for the preview.
    func renderToDrawable(_ frame: Frame, drawable: CAMetalDrawable) {
        _ = encode(frame, into: drawable.texture, present: drawable)
    }

    // MARK: - Encoding

    private func encode(
        _ frame: Frame,
        into destination: MTLTexture,
        present drawable: CAMetalDrawable?
    ) -> Bool {
        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let isBiplanar = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

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

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return false }

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
            lumaScale: isFullRange ? 1.0 : 255.0 / 219.0
        )

        encoder.setRenderPipelineState(isBiplanar ? biplanarPipeline : bgraPipeline)
        for (index, texture) in sourceTextures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.setFragmentTexture(frame.overlay?.texture ?? blankOverlay, index: 2)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        if let drawable { commandBuffer.present(drawable) }

        let retained = inFlightTextures
        commandBuffer.addCompletedHandler { _ in _ = retained }
        inFlightTextures.removeAll(keepingCapacity: true)

        commandBuffer.commit()
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
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
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
