import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

/// One export frame on the GPU, decoded picture to encoder buffer, with no copy through the CPU
/// between: the camera's 10-bit 4:2:2 planes in, YCbCr to RGB and Lanczos to the shared frame, the
/// chain (`MetalChain`, turning the frame upright as it reads it), then for each deliverable the
/// crop, the 709 conversion and the sharpener, written into an 8-bit 4:2:0 buffer. Grain is the
/// chain's, in the negative.
///
/// THE FINISH IS `DeliveryFinish` TRANSCRIBED, integer for integer, and `MetalFrameTests` holds the
/// two to each other. The source stage is held by `ExportParityTests`, against
/// the engine's file.
public final class MetalFrame {
    public let chain: MetalChain
    private let pipelines: [String: MTLComputePipelineState]
    private let textures: CVMetalTextureCache
    private let lanczos: MPSImageLanczosScale

    public init(chain: MetalChain) throws {
        self.chain = chain
        let library: MTLLibrary
        do {
            library = try chain.device.makeLibrary(source: Self.source, options: nil)
        } catch {
            throw MetalChain.Failure.shader("\(error)")
        }
        var made: [String: MTLComputePipelineState] = [:]
        for name in [
            "ycbcr", "toY", "toCbCr", "binomialAcross", "binomialDown",
            "extremes", "sharpen", "writeY",
        ] {
            guard let f = library.makeFunction(name: name) else {
                throw MetalChain.Failure.shader("no \(name)")
            }
            made[name] = try chain.device.makeComputePipelineState(function: f)
        }
        pipelines = made
        lanczos = MPSImageLanczosScale(device: chain.device)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, chain.device, nil, &cache)
        guard let cache else { throw MetalChain.Failure.texture }
        textures = cache
    }

    /// Where a deliverable is cut from the shared frame, and how it is finished.
    public struct Target {
        public let crop: (x: Int, y: Int)
        public let finish: DeliveryFinish
        public let output: CVPixelBuffer
    }

    /// Renders `source` (a 10-bit 4:2:2 bi-planar buffer, as decoded) into every target's buffer.
    /// `frameWidth` x `frameHeight` is the upright shared frame; `turns` stands the source up.
    public func render(
        source: CVPixelBuffer, turns: Int, frameWidth: Int, frameHeight: Int, grade: LiveChain,
        grain: LiveGrain?, frame: Int, targets: [Target]
    ) throws {
        let sideways = turns % 2 == 1
        let sw = sideways ? frameHeight : frameWidth
        let sh = sideways ? frameWidth : frameHeight
        var held: [CVMetalTexture] = []
        let luma = try planeTexture(source, 0, .r16Unorm, &held)
        let chroma = try planeTexture(source, 1, .rg16Unorm, &held)
        guard let buffer = chain.queue.makeCommandBuffer() else {
            throw MetalChain.Failure.command("no buffer")
        }

        // YCbCr to RGB at the source's size, then Lanczos to the shared frame's. Apple's Lanczos:
        // a hand-written separable one reading the planes per tap was 34 ms of a frame.
        let rgb = try chain.scratch("sourceRGB", .rgba32Float, luma.width, luma.height)
        try run("ycbcr", buffer, luma.width, luma.height) { e in
            e.setTexture(luma, index: 0)
            e.setTexture(chroma, index: 1)
            e.setTexture(rgb, index: 2)
        }
        let scaled = try chain.scratch("sourceScaled", .rgba32Float, sw, sh)
        lanczos.encode(commandBuffer: buffer, sourceTexture: rgb, destinationTexture: scaled)
        let graded = try chain.scratch("graded", .rgba8Unorm, frameWidth, frameHeight)
        try chain.encode(
            source: scaled, into: graded, chain: grade, turns: turns, grain: grain, frame: frame,
            buffer: buffer)
        try encodeTargets(graded, targets, buffer, &held)
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw MetalChain.Failure.command("\(error)") }
        withExtendedLifetime(held) {}
    }

    /// The finish alone, from graded 8-bit RGBA: what `MetalFrameTests` holds to `DeliveryFinish`.
    func finish(rgba: [UInt8], width: Int, height: Int, targets: [Target]) throws {
        let graded = try chain.texture(.rgba8Unorm, width, height, usage: [.shaderRead])
        rgba.withUnsafeBytes {
            graded.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        var held: [CVMetalTexture] = []
        guard let buffer = chain.queue.makeCommandBuffer() else {
            throw MetalChain.Failure.command("no buffer")
        }
        try encodeTargets(graded, targets, buffer, &held)
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw MetalChain.Failure.command("\(error)") }
        withExtendedLifetime(held) {}
    }

    private func encodeTargets(
        _ graded: MTLTexture, _ targets: [Target], _ buffer: MTLCommandBuffer,
        _ held: inout [CVMetalTexture]
    ) throws {
        for (i, target) in targets.enumerated() {
            let w = CVPixelBufferGetWidth(target.output)
            let h = CVPixelBufferGetHeight(target.output)
            let outY = try planeTexture(target.output, 0, .r8Unorm, &held)
            let outC = try planeTexture(target.output, 1, .rg8Unorm, &held)
            var crop = SIMD2<Int32>(Int32(target.crop.x), Int32(target.crop.y))
            try run("toCbCr", buffer, w / 2, h / 2) { e in
                e.setTexture(graded, index: 0)
                e.setTexture(outC, index: 1)
                e.setBytes(&crop, length: 8, index: 0)
            }
            let y = try chain.scratch("y\(i)", .r32Float, w, h)
            try run("toY", buffer, w, h) { e in
                e.setTexture(graded, index: 0)
                e.setTexture(y, index: 1)
                e.setBytes(&crop, length: 8, index: 0)
            }
            let sharpened = try sharpen(y, target.finish, buffer, i)
            try writeY(sharpened, into: outY, buffer)
        }
    }

    // MARK: finish

    private func sharpen(
        _ y: MTLTexture, _ finish: DeliveryFinish, _ buffer: MTLCommandBuffer, _ i: Int
    ) throws -> MTLTexture {
        guard finish.sharpen > 0 else { return y }
        let w = y.width
        let h = y.height
        let geometry = finish.sharpenGeometry(width: w, height: h)
        let across = try chain.scratch("blurAcross\(i)", .r32Float, w, h)
        let passes = [
            try chain.scratch("blurB\(i)", .r32Float, w, h),
            try chain.scratch("blurC\(i)", .r32Float, w, h),
        ]
        var blur = y
        for pass in 0..<geometry.steps {
            let from = blur
            let to = passes[pass % 2]
            try run("binomialAcross", buffer, w, h) { e in
                e.setTexture(from, index: 0)
                e.setTexture(across, index: 1)
            }
            try run("binomialDown", buffer, w, h) { e in
                e.setTexture(across, index: 0)
                e.setTexture(to, index: 1)
            }
            blur = to
        }
        let extremes = try chain.scratch("extremes\(i)", .rg32Float, w, h)
        try run("extremes", buffer, w, h) { e in
            e.setTexture(y, index: 0)
            e.setTexture(extremes, index: 1)
        }
        let sharp = try chain.scratch("sharp\(i)", .r32Float, w, h)
        var params = SIMD3<Int32>(
            Int32(geometry.shift), Int32(geometry.amount), Int32(geometry.limit))
        let blurred = blur
        try run("sharpen", buffer, w, h) { e in
            e.setTexture(y, index: 0)
            e.setTexture(blurred, index: 1)
            e.setTexture(extremes, index: 2)
            e.setTexture(sharp, index: 3)
            e.setBytes(&params, length: MemoryLayout<SIMD3<Int32>>.stride, index: 0)
        }
        return sharp
    }

    private func writeY(_ y: MTLTexture, into out: MTLTexture, _ buffer: MTLCommandBuffer) throws {
        try run("writeY", buffer, y.width, y.height) { e in
            e.setTexture(y, index: 0)
            e.setTexture(out, index: 1)
        }
    }

    // MARK: plumbing

    private func planeTexture(
        _ buffer: CVPixelBuffer, _ plane: Int, _ format: MTLPixelFormat,
        _ held: inout [CVMetalTexture]
    ) throws -> MTLTexture {
        var made: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textures, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &made)
        guard let made, let texture = CVMetalTextureGetTexture(made) else {
            throw MetalChain.Failure.texture
        }
        held.append(made)
        return texture
    }

    private func run(
        _ name: String, _ buffer: MTLCommandBuffer, _ w: Int, _ h: Int,
        _ configure: (MTLComputeCommandEncoder) throws -> Void
    ) throws {
        guard let pipeline = pipelines[name], let e = buffer.makeComputeCommandEncoder() else {
            throw MetalChain.Failure.command("no encoder for \(name)")
        }
        e.setComputePipelineState(pipeline)
        try configure(e)
        let tw = min(16, pipeline.threadExecutionWidth)
        let th = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / tw))
        e.dispatchThreadgroups(
            MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        e.endEncoding()
    }

    // MARK: shaders

    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        // The camera's 10-bit video-range BT.2020 non-constant-luminance YCbCr to RGB, matrix
        // only, as ffmpeg's format=gbrp16le and the decoder's own RGB give it.
        static float3 rgbAt(texture2d<float, access::read> y, texture2d<float, access::read> c,
                            int x, int row) {
            float yv = y.read(uint2(x, row)).r * 65535.0 / 64.0;
            // 4:2:2 chroma is co-sited with the even luma samples.
            float cx = float(x) * 0.5;
            int c0 = int(cx);
            int c1 = min(c0 + 1, int(c.get_width()) - 1);
            float t = cx - float(c0);
            float2 cc = mix(c.read(uint2(c0, row)).rg, c.read(uint2(c1, row)).rg, t) * 65535.0 / 64.0;
            float Y = (yv - 64.0) / 876.0;
            float Cb = (cc.x - 512.0) / 896.0;
            float Cr = (cc.y - 512.0) / 896.0;
            float3 rgb = float3(Y + 1.4746 * Cr, Y - 0.16455 * Cb - 0.57135 * Cr, Y + 1.8814 * Cb);
            return clamp(rgb, 0.0, 1.0);
        }

        kernel void ycbcr(texture2d<float, access::read> y [[texture(0)]],
                          texture2d<float, access::read> c [[texture(1)]],
                          texture2d<float, access::write> dst [[texture(2)]],
                          uint2 id [[thread_position_in_grid]]) {
            if (id.x >= dst.get_width() || id.y >= dst.get_height()) return;
            dst.write(float4(rgbAt(y, c, id.x, id.y), 1), id);
        }

        // 709 video range, as vImage's ARGB8888 to 420Yp8_CbCr8 conversion gives it: luma per
        // pixel, chroma from each 2x2 block's mean.
        kernel void toY(texture2d<float, access::read> rgb [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant int2 &crop [[buffer(0)]],
                        uint2 id [[thread_position_in_grid]]) {
            if (id.x >= dst.get_width() || id.y >= dst.get_height()) return;
            float3 c = rgb.read(uint2(int2(id) + crop)).rgb * 255.0;
            float yl = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
            dst.write(floor(16.0 + yl * 219.0 / 255.0 + 0.5), id);
        }

        kernel void toCbCr(texture2d<float, access::read> rgb [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant int2 &crop [[buffer(0)]],
                           uint2 id [[thread_position_in_grid]]) {
            if (id.x >= dst.get_width() || id.y >= dst.get_height()) return;
            int2 at = int2(id) * 2 + crop;
            float3 c = (rgb.read(uint2(at)).rgb + rgb.read(uint2(at + int2(1, 0))).rgb
                      + rgb.read(uint2(at + int2(0, 1))).rgb + rgb.read(uint2(at + int2(1, 1))).rgb)
                      * 255.0 / 4.0;
            float yl = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
            float cb = 128.0 + (c.b - yl) / 1.8556 * 224.0 / 255.0;
            float cr = 128.0 + (c.r - yl) / 1.5748 * 224.0 / 255.0;
            dst.write(float4(floor(float2(cb, cr) + 0.5) / 255.0, 0, 1), id);
        }

        // DeliveryFinish.binomial: [1 2 1] each way, unnormalised, edges repeated.
        kernel void binomialAcross(texture2d<float, access::read> src [[texture(0)]],
                                   texture2d<float, access::write> dst [[texture(1)]],
                                   uint2 id [[thread_position_in_grid]]) {
            int w = src.get_width();
            if (int(id.x) >= w || id.y >= src.get_height()) return;
            float l = src.read(uint2(max(0, int(id.x) - 1), id.y)).r;
            float r = src.read(uint2(min(w - 1, int(id.x) + 1), id.y)).r;
            dst.write(l + 2.0 * src.read(id).r + r, id);
        }

        kernel void binomialDown(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 uint2 id [[thread_position_in_grid]]) {
            int h = src.get_height();
            if (id.x >= src.get_width() || int(id.y) >= h) return;
            float u = src.read(uint2(id.x, max(0, int(id.y) - 1))).r;
            float d = src.read(uint2(id.x, min(h - 1, int(id.y) + 1))).r;
            dst.write(u + 2.0 * src.read(id).r + d, id);
        }

        kernel void extremes(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             uint2 id [[thread_position_in_grid]]) {
            int w = src.get_width(), h = src.get_height();
            if (int(id.x) >= w || int(id.y) >= h) return;
            float lo = 255, hi = 0;
            for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                float v = src.read(uint2(clamp(int(id.x) + dx, 0, w - 1), clamp(int(id.y) + dy, 0, h - 1))).r;
                lo = min(lo, v); hi = max(hi, v);
            }
            dst.write(float4(lo, hi, 0, 0), id);
        }

        // DeliveryFinish.sharpened, in integers: params = (shift, amount/65536, limit).
        kernel void sharpen(texture2d<float, access::read> y [[texture(0)]],
                            texture2d<float, access::read> blur [[texture(1)]],
                            texture2d<float, access::read> ext [[texture(2)]],
                            texture2d<float, access::write> dst [[texture(3)]],
                            constant int3 &params [[buffer(0)]],
                            uint2 id [[thread_position_in_grid]]) {
            if (id.x >= y.get_width() || id.y >= y.get_height()) return;
            int v = int(y.read(id).r);
            int roundingHalf = 1 << (params.x - 1);
            int blurred = (int(blur.read(id).r) + roundingHalf) >> params.x;
            int sharp = v + (((v - blurred) * params.y + 32768) >> 16);
            float2 e = ext.read(id).rg;
            int clamped = min(int(e.y) + params.z, max(int(e.x) - params.z, sharp));
            dst.write(float(clamp(clamped, 0, 255)), id);
        }

        kernel void writeY(texture2d<float, access::read> y [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           uint2 id [[thread_position_in_grid]]) {
            if (id.x >= dst.get_width() || id.y >= dst.get_height()) return;
            dst.write(y.read(id).r / 255.0, id);
        }
        """
}
