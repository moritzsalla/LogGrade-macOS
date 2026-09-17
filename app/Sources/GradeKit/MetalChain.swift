import Foundation
import Metal

/// `LiveChain` on the GPU: the same stages, in the same order, with the same quantisation.
///
/// WHY. On the Intel Mac the CPU chain is 47 ms of a 1080x1920 frame, which caps the native export
/// at grade.sh's speed. Every stage here is per pixel or a separable blur, the shape a GPU is for.
///
/// A TRANSCRIPTION, held to `LiveChain` by `MetalChainTests` pixel for pixel, not to a tolerance
/// chosen after the fact. What it must reproduce, and each was a CPU decision first:
///   - tetrahedral cube sampling (`Cube3D.sample`), corner by corner, not the GPU's trilinear filter;
///   - the colour stages truncated to 8 bits, as `LiveChain.store` truncates them;
///   - the tone curve read from the same 256-entry table, merged by `LiveGrade.merge`, truncated.
public final class MetalChain {
    public enum Failure: Error, CustomStringConvertible {
        case noDevice
        case shader(String)
        case texture
        case command(String)

        public var description: String {
            switch self {
            case .noDevice: return "no Metal device"
            case .shader(let s): return "the chain's shaders did not compile: \(s)"
            case .texture: return "a texture could not be made"
            case .command(let s): return "the GPU chain failed: \(s)"
            }
        }
    }

    public let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]
    /// Uploaded cubes, by the address of their samples' storage. The entry HOLDS that storage, so
    /// the address cannot be freed and handed to another cube while the texture is cached: keyed on
    /// the address alone, a Portra 800 export after a Neutral one rendered with Neutral's cube
    /// (`MetalChainTests.testAPresetSwitchUsesTheNewCube`).
    private var cubes: [CubeKey: (samples: [SIMD3<Float>], texture: MTLTexture)] = [:]
    /// The last `graded` call's time on the GPU itself, without upload or readback.
    public private(set) var lastGPUTime: CFTimeInterval = 0

    private struct CubeKey: Hashable {
        let address: Int
        let count: Int
    }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw Failure.noDevice }
        self.device = device
        self.queue = queue
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.source, options: nil)
        } catch {
            throw Failure.shader("\(error)")
        }
        var made: [String: MTLComputePipelineState] = [:]
        for name in [
            "correct", "highlight", "blurAcross", "blurDown", "glow", "convert", "grade",
            "grainNoise", "grainAcross", "grainDown", "grainAdd",
        ] {
            guard let function = library.makeFunction(name: name) else {
                throw Failure.shader("no \(name)")
            }
            made[name] = try device.makeComputePipelineState(function: function)
        }
        pipelines = made
    }

    // MARK: public entry

    /// The graded frame from 16-bit RGBA source pixels, as `LiveChain.converted` then
    /// `LiveChain.gradedPixels` give it: 8-bit RGBA, opaque.
    public func graded(
        rgba16: [UInt16], width: Int, height: Int, chain: LiveChain, grain: LiveGrain? = nil,
        frame: Int = 0
    ) throws -> [UInt8] {
        let source = try texture(.rgba16Unorm, width, height, usage: [.shaderRead])
        rgba16.withUnsafeBytes {
            source.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        let out = try texture(.rgba8Unorm, width, height, usage: [.shaderRead, .shaderWrite])
        guard let buffer = queue.makeCommandBuffer() else { throw Failure.command("no buffer") }
        try encode(
            source: source, into: out, chain: chain, grain: grain, frame: frame, buffer: buffer)
        // A managed texture on a discrete GPU is only copied back when asked; read without this and
        // the bytes are whatever the CPU side last held.
        if out.storageMode == .managed, let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: out)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw Failure.command("\(error)") }
        lastGPUTime = buffer.gpuEndTime - buffer.gpuStartTime
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            out.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    /// Encodes the whole chain from `source` (normalised log RGB) into `out` (8-bit RGBA), for a
    /// caller that keeps its frames on the GPU.
    ///
    /// `turns` quarter turns clockwise are applied as the correction reads the source, so a
    /// sideways source is `out` with its sides swapped and no pass is spent on turning it.
    ///
    /// `grain`, for an export only, is added to the log picture after halation and before the
    /// conversion, as `LiveChain.converted` adds it; `frame` numbers it.
    func encode(
        source: MTLTexture, into out: MTLTexture, chain: LiveChain, turns: Int = 0,
        grain: LiveGrain? = nil, frame: Int = 0, buffer: MTLCommandBuffer
    ) throws {
        let width = out.width
        let height = out.height
        let stages = chain.stages
        let log = try scratch("log", .rgba32Float, width, height)
        let identity = try cubeTexture(nil)
        try run("correct", buffer, width, height) { e in
            e.setTexture(source, index: 0)
            e.setTexture(log, index: 1)
            e.setTexture(try self.cubeTexture(stages.correction) ?? identity!, index: 2)
            var params = SIMD3<Int32>(
                stages.correction == nil ? 0 : 1, Int32(stages.correction?.size ?? 2),
                Int32(turns % 4))
            e.setBytes(&params, length: MemoryLayout<SIMD3<Int32>>.stride, index: 0)
        }

        var converting = log
        if let halation = stages.halation {
            converting = try halated(log, halation, buffer)
        }
        if let grain {
            converting = try grained(converting, grain, frame: frame, buffer)
        }

        let codes = try scratch("codes", .rgba32Float, width, height)
        try run("convert", buffer, width, height) { e in
            e.setTexture(converting, index: 0)
            e.setTexture(codes, index: 1)
            e.setTexture(try self.cubeTexture(stages.conversion), index: 2)
            e.setTexture(try self.cubeTexture(stages.hue) ?? identity!, index: 3)
            var sizes = SIMD2<Int32>(Int32(stages.conversion.size), Int32(stages.hue?.size ?? 2))
            var useHue: Int32 = stages.hue == nil ? 0 : 1
            e.setBytes(&sizes, length: 8, index: 0)
            e.setBytes(&useHue, length: 4, index: 1)
        }

        var table = [Float](repeating: 0, count: 256)
        for i in 0..<256 { table[i] = Float(chain.grade.curve.value(at: Double(i) / 255) * 255) }
        var trims = SIMD2<Float>(Float(chain.grade.saturation), Float(chain.grade.warmth))
        try run("grade", buffer, width, height) { e in
            e.setTexture(codes, index: 0)
            e.setTexture(out, index: 1)
            e.setBytes(&table, length: 256 * 4, index: 0)
            e.setBytes(&trims, length: 8, index: 1)
        }
    }

    // MARK: halation

    private func halated(_ log: MTLTexture, _ h: LiveHalation, _ buffer: MTLCommandBuffer) throws
        -> MTLTexture
    {
        let width = log.width
        let height = log.height
        let f = h.reduction
        let sw = max(1, width / f)
        let sh = max(1, height / f)
        let highlight = try scratch("highlight", .r32Float, sw, sh)
        var params = SIMD3<Float>(Float(h.threshold), 0, 0)
        try run("highlight", buffer, sw, sh) { e in
            e.setTexture(log, index: 0)
            e.setTexture(highlight, index: 1)
            e.setBytes(&params, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        }
        var blurred = highlight
        let sigma = h.sigma / Float(f)
        if sigma > 0.05 {
            let radius = Int((sigma * 3).rounded(.up))
            var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
            let total = kernel.reduce(0, +)
            kernel = kernel.map { $0 / total }
            var r = Int32(radius)
            let across = try scratch("across", .r32Float, sw, sh)
            try run("blurAcross", buffer, sw, sh) { e in
                e.setTexture(highlight, index: 0)
                e.setTexture(across, index: 1)
                e.setBytes(&kernel, length: kernel.count * 4, index: 0)
                e.setBytes(&r, length: 4, index: 1)
            }
            blurred = try scratch("blurred", .r32Float, sw, sh)
            try run("blurDown", buffer, sw, sh) { e in
                e.setTexture(across, index: 0)
                e.setTexture(blurred, index: 1)
                e.setBytes(&kernel, length: kernel.count * 4, index: 0)
                e.setBytes(&r, length: 4, index: 1)
            }
        }
        let lit = try scratch("lit", .rgba32Float, width, height)
        var gain = h.tint * h.strength
        try run("glow", buffer, width, height) { e in
            e.setTexture(log, index: 0)
            e.setTexture(highlight, index: 1)
            e.setTexture(blurred, index: 2)
            e.setTexture(lit, index: 3)
            e.setBytes(&gain, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        }
        return lit
    }

    // MARK: grain

    private func grained(
        _ log: MTLTexture, _ grain: LiveGrain, frame: Int, _ buffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let w = log.width
        let h = log.height
        let noise = try scratch("grainNoise", .rgba32Float, w, h)
        var frameNumber = UInt32(truncatingIfNeeded: frame)
        try run("grainNoise", buffer, w, h) { e in
            e.setTexture(noise, index: 0)
            e.setBytes(&frameNumber, length: 4, index: 0)
        }
        var (weights, sumOfSquares) = grain.kernel
        var radius = Int32(weights.count / 2)
        let across = try scratch("grainAcross", .rgba32Float, w, h)
        try run("grainAcross", buffer, w, h) { e in
            e.setTexture(noise, index: 0)
            e.setTexture(across, index: 1)
            e.setBytes(&weights, length: weights.count * 4, index: 0)
            e.setBytes(&radius, length: 4, index: 1)
        }
        let blurred = try scratch("grainBlurred", .rgba32Float, w, h)
        try run("grainDown", buffer, w, h) { e in
            e.setTexture(across, index: 0)
            e.setTexture(blurred, index: 1)
            e.setBytes(&weights, length: weights.count * 4, index: 0)
            e.setBytes(&radius, length: 4, index: 1)
        }
        let out = try scratch("grained", .rgba32Float, w, h)
        var amounts = SIMD2<Float>(
            LiveGrain.shared.squareRoot() * grain.sd / sumOfSquares,
            (1 - LiveGrain.shared).squareRoot() * grain.sd / sumOfSquares)
        try run("grainAdd", buffer, w, h) { e in
            e.setTexture(log, index: 0)
            e.setTexture(blurred, index: 1)
            e.setTexture(out, index: 2)
            e.setBytes(&amounts, length: 8, index: 0)
        }
        return out
    }

    // MARK: plumbing

    private var scratches: [String: MTLTexture] = [:]

    /// A working texture kept between frames: every frame of an export has the same sizes, and
    /// making seven textures a frame was a measurable share of the time.
    func scratch(_ name: String, _ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture
    {
        if let t = scratches[name], t.width == w, t.height == h, t.pixelFormat == format {
            return t
        }
        let t = try texture(format, w, h, usage: [.shaderRead, .shaderWrite], storage: .private)
        scratches[name] = t
        return t
    }

    func texture(
        _ format: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage,
        storage: MTLStorageMode = .managed
    ) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = usage
        d.storageMode = storage
        guard let t = device.makeTexture(descriptor: d) else { throw Failure.texture }
        return t
    }

    /// A cube as a 3D float texture, x = red, y = green, z = blue, as `Cube3D` indexes it. Kept by
    /// the storage it was read from, so a chain rebuilt around the same cube uploads nothing.
    private func cubeTexture(_ cube: Cube3D?) throws -> MTLTexture? {
        guard let cube else {
            return try cubeTexture(
                Cube3D(size: 2, samples: [SIMD3<Float>](repeating: .zero, count: 8)))
        }
        let key = cube.samples.withUnsafeBufferPointer {
            CubeKey(address: Int(bitPattern: $0.baseAddress), count: $0.count)
        }
        if let cached = cubes[key] { return cached.texture }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = cube.size
        d.height = cube.size
        d.depth = cube.size
        d.usage = [.shaderRead]
        d.storageMode = .managed
        guard let t = device.makeTexture(descriptor: d) else { throw Failure.texture }
        var rgba = [Float](repeating: 1, count: cube.samples.count * 4)
        for (i, s) in cube.samples.enumerated() {
            rgba[i * 4] = s.x
            rgba[i * 4 + 1] = s.y
            rgba[i * 4 + 2] = s.z
        }
        rgba.withUnsafeBytes {
            t.replace(
                region: MTLRegionMake3D(0, 0, 0, cube.size, cube.size, cube.size),
                mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                bytesPerRow: cube.size * 16, bytesPerImage: cube.size * cube.size * 16)
        }
        if cubes.count > 16 { cubes.removeAll() }
        cubes[key] = (cube.samples, t)
        return t
    }

    private func run(
        _ name: String, _ buffer: MTLCommandBuffer, _ w: Int, _ h: Int,
        _ configure: (MTLComputeCommandEncoder) throws -> Void
    ) throws {
        guard let pipeline = pipelines[name], let e = buffer.makeComputeCommandEncoder() else {
            throw Failure.command("no encoder for \(name)")
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

        // Apple Log, as CorrectionCube.decode and encode spell it.
        static float logDecode(float p) {
            const float r0 = -0.05641088, c = 47.28711236, beta = 0.00964052;
            const float gamma = 0.08550479, delta = 0.69336945;
            float pt = c * (0.01 - r0) * (0.01 - r0);
            if (p < 0) return r0;
            if (p < pt) return sqrt(p / c) + r0;
            return pow(2.0, (p - delta) / gamma) - beta;
        }
        static float logEncode(float r) {
            const float r0 = -0.05641088, c = 47.28711236, beta = 0.00964052;
            const float gamma = 0.08550479, delta = 0.69336945;
            if (r < r0) return 0;
            if (r < 0.01) return c * (r - r0) * (r - r0);
            return gamma * log2(r + beta) + delta;
        }

        // Cube3D.sample: the six tetrahedra, corner by corner.
        static float3 corner(texture3d<float, access::read> t, int r, int g, int b) {
            return t.read(uint3(r, g, b)).rgb;
        }
        static float3 tetra(texture3d<float, access::read> t, int size, float3 input) {
            float last = float(size - 1);
            float3 p = clamp(input, 0.0, 1.0) * last;
            int3 lo = min(int3(p), int3(size - 2));
            float3 f = p - float3(lo);
            float dr = f.x, dg = f.y, db = f.z;
            float3 c000 = corner(t, lo.x, lo.y, lo.z);
            float3 c111 = corner(t, lo.x + 1, lo.y + 1, lo.z + 1);
            float w0, w1, w2; float3 e0, e1;
            if (dr > dg) {
                if (dg > db) { w0 = dr; w1 = dg; w2 = db;
                    e0 = corner(t, lo.x + 1, lo.y, lo.z); e1 = corner(t, lo.x + 1, lo.y + 1, lo.z); }
                else if (dr > db) { w0 = dr; w1 = db; w2 = dg;
                    e0 = corner(t, lo.x + 1, lo.y, lo.z); e1 = corner(t, lo.x + 1, lo.y, lo.z + 1); }
                else { w0 = db; w1 = dr; w2 = dg;
                    e0 = corner(t, lo.x, lo.y, lo.z + 1); e1 = corner(t, lo.x + 1, lo.y, lo.z + 1); }
            } else {
                if (db > dg) { w0 = db; w1 = dg; w2 = dr;
                    e0 = corner(t, lo.x, lo.y, lo.z + 1); e1 = corner(t, lo.x, lo.y + 1, lo.z + 1); }
                else if (db > dr) { w0 = dg; w1 = db; w2 = dr;
                    e0 = corner(t, lo.x, lo.y + 1, lo.z); e1 = corner(t, lo.x, lo.y + 1, lo.z + 1); }
                else { w0 = dg; w1 = dr; w2 = db;
                    e0 = corner(t, lo.x, lo.y + 1, lo.z); e1 = corner(t, lo.x + 1, lo.y + 1, lo.z); }
            }
            float3 result = c000;
            result += (e0 - c000) * w0;
            result += (e1 - e0) * w1;
            result += (c111 - e1) * w2;
            return result;
        }

        kernel void correct(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            texture3d<float, access::read> cube [[texture(2)]],
                            constant int3 &params [[buffer(0)]],
                            uint2 id [[thread_position_in_grid]]) {
            uint w = dst.get_width(), h = dst.get_height();
            if (id.x >= w || id.y >= h) return;
            // The source pixel this upright one comes from, the source turned params.z quarter
            // turns clockwise to stand it up.
            uint2 at = id;
            if (params.z == 1) at = uint2(id.y, w - 1 - id.x);
            else if (params.z == 2) at = uint2(w - 1 - id.x, h - 1 - id.y);
            else if (params.z == 3) at = uint2(h - 1 - id.y, id.x);
            float3 c = src.read(at).rgb;
            if (params.x != 0) c = tetra(cube, params.y, c);
            dst.write(float4(c, 1), id);
        }

        // The reduced highlight: a block's mean in log, decoded, less the threshold, as luma.
        kernel void highlight(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant float3 &params [[buffer(0)]],
                              uint2 id [[thread_position_in_grid]]) {
            uint sw = dst.get_width(), sh = dst.get_height();
            if (id.x >= sw || id.y >= sh) return;
            uint w = src.get_width(), h = src.get_height();
            uint x0 = id.x * w / sw, x1 = max(x0 + 1, (id.x + 1) * w / sw);
            uint y0 = id.y * h / sh, y1 = max(y0 + 1, (id.y + 1) * h / sh);
            float3 mean = 0;
            for (uint y = y0; y < y1; y++) for (uint x = x0; x < x1; x++) mean += src.read(uint2(x, y)).rgb;
            mean /= float((x1 - x0) * (y1 - y0));
            float3 hi = float3(max(0.0, logDecode(mean.r) - params.x),
                               max(0.0, logDecode(mean.g) - params.x),
                               max(0.0, logDecode(mean.b) - params.x));
            dst.write(dot(hi, float3(0.2627, 0.6780, 0.0593)), id);
        }

        kernel void blurAcross(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant float *k [[buffer(0)]], constant int &radius [[buffer(1)]],
                               uint2 id [[thread_position_in_grid]]) {
            int w = src.get_width(), h = src.get_height();
            if (int(id.x) >= w || int(id.y) >= h) return;
            float sum = 0;
            for (int i = -radius; i <= radius; i++)
                sum += src.read(uint2(clamp(int(id.x) + i, 0, w - 1), id.y)).r * k[i + radius];
            dst.write(sum, id);
        }

        kernel void blurDown(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant float *k [[buffer(0)]], constant int &radius [[buffer(1)]],
                             uint2 id [[thread_position_in_grid]]) {
            int w = src.get_width(), h = src.get_height();
            if (int(id.x) >= w || int(id.y) >= h) return;
            float sum = 0;
            for (int i = -radius; i <= radius; i++)
                sum += src.read(uint2(id.x, clamp(int(id.y) + i, 0, h - 1))).r * k[i + radius];
            dst.write(sum, id);
        }

        static float edge(texture2d<float, access::read> blurred, texture2d<float, access::read> hi,
                          int x, int y) {
            return max(0.0, blurred.read(uint2(x, y)).r - hi.read(uint2(x, y)).r);
        }

        // Edge-only glow, bilinear up to the frame, added in linear light.
        kernel void glow(texture2d<float, access::read> log [[texture(0)]],
                         texture2d<float, access::read> hi [[texture(1)]],
                         texture2d<float, access::read> blurred [[texture(2)]],
                         texture2d<float, access::write> dst [[texture(3)]],
                         constant float3 &gain [[buffer(0)]],
                         uint2 id [[thread_position_in_grid]]) {
            uint w = log.get_width(), h = log.get_height();
            if (id.x >= w || id.y >= h) return;
            int sw = hi.get_width(), sh = hi.get_height();
            float fy = max(0.0, min(float(sh - 1), (float(id.y) + 0.5) * float(sh) / float(h) - 0.5));
            float fx = max(0.0, min(float(sw - 1), (float(id.x) + 0.5) * float(sw) / float(w) - 0.5));
            int y0 = int(fy), y1 = min(sh - 1, y0 + 1), x0 = int(fx), x1 = min(sw - 1, x0 + 1);
            float wy = fy - float(y0), wx = fx - float(x0);
            float top = edge(blurred, hi, x0, y0) * (1 - wx) + edge(blurred, hi, x1, y0) * wx;
            float bottom = edge(blurred, hi, x0, y1) * (1 - wx) + edge(blurred, hi, x1, y1) * wx;
            float amount = top * (1 - wy) + bottom * wy;
            float3 c = log.read(id).rgb;
            if (amount > 0) {
                for (int i = 0; i < 3; i++) c[i] = min(1.0, logEncode(logDecode(c[i]) + gain[i] * amount));
            }
            dst.write(float4(c, 1), id);
        }

        kernel void convert(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            texture3d<float, access::read> conversion [[texture(2)]],
                            texture3d<float, access::read> hue [[texture(3)]],
                            constant int2 &sizes [[buffer(0)]], constant int &useHue [[buffer(1)]],
                            uint2 id [[thread_position_in_grid]]) {
            if (id.x >= dst.get_width() || id.y >= dst.get_height()) return;
            float3 c = tetra(conversion, sizes.x, src.read(id).rgb);
            if (useHue != 0) c = tetra(hue, sizes.y, c);
            // LiveChain.store: truncated to 8 bits.
            dst.write(float4(floor(clamp(c * 255.0, 0.0, 255.0)), 1), id);
        }

        // LiveGrain.hash and LiveGrain.gaussian, the same arithmetic: channel 0 shared, 1-3 R G B.
        static uint grainHash(uint v) {
            uint s = v * 747796405u + 2891336453u;
            uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
            return (w >> 22u) ^ w;
        }
        static float grainGaussian(uint x, uint y, uint frame, uint channel) {
            uint base = grainHash((frame * 0x9E3779B9u) ^ (channel * 0x85EBCA6Bu));
            uint a = grainHash(grainHash(base ^ x) ^ y);
            uint b = grainHash(a ^ 0x68E31DA4u);
            float u1 = (float(a >> 8u) + 0.5) / 16777216.0;
            float u2 = float(b >> 8u) / 16777216.0;
            return sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI_F * u2);
        }

        kernel void grainNoise(texture2d<float, access::write> dst [[texture(0)]],
                               constant uint &frame [[buffer(0)]],
                               uint2 id [[thread_position_in_grid]]) {
            if (id.x >= dst.get_width() || id.y >= dst.get_height()) return;
            dst.write(float4(grainGaussian(id.x, id.y, frame, 0), grainGaussian(id.x, id.y, frame, 1),
                             grainGaussian(id.x, id.y, frame, 2), grainGaussian(id.x, id.y, frame, 3)), id);
        }

        kernel void grainAcross(texture2d<float, access::read> src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                constant float *k [[buffer(0)]], constant int &radius [[buffer(1)]],
                                uint2 id [[thread_position_in_grid]]) {
            int w = src.get_width();
            if (int(id.x) >= w || id.y >= src.get_height()) return;
            float4 sum = 0;
            for (int i = -radius; i <= radius; i++)
                sum += src.read(uint2(clamp(int(id.x) + i, 0, w - 1), id.y)) * k[i + radius];
            dst.write(sum, id);
        }

        kernel void grainDown(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant float *k [[buffer(0)]], constant int &radius [[buffer(1)]],
                              uint2 id [[thread_position_in_grid]]) {
            int h = src.get_height();
            if (id.x >= src.get_width() || int(id.y) >= h) return;
            float4 sum = 0;
            for (int i = -radius; i <= radius; i++)
                sum += src.read(uint2(id.x, clamp(int(id.y) + i, 0, h - 1))) * k[i + radius];
            dst.write(sum, id);
        }

        kernel void grainAdd(texture2d<float, access::read> log [[texture(0)]],
                             texture2d<float, access::read> noise [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant float2 &amounts [[buffer(0)]],
                             uint2 id [[thread_position_in_grid]]) {
            if (id.x >= dst.get_width() || id.y >= dst.get_height()) return;
            float4 n = noise.read(id);
            float3 c = log.read(id).rgb + amounts.x * n.x + amounts.y * float3(n.y, n.z, n.w);
            dst.write(float4(c, 1), id);
        }

        static float midtoneWeight(float level) {
            if (level <= 0.1059 || level >= 0.3922) return 0;
            if (level < 0.2314) return (level - 0.1059) / (0.2314 - 0.1059) * 0.6999;
            if (level <= 0.2510) return 0.6999;
            return (0.3922 - level) / (0.3922 - 0.2510) * 0.6999;
        }

        // LiveGrade.merge on the 8-bit codes, truncated as LiveChain.gradedPixels truncates.
        kernel void grade(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float *curve [[buffer(0)]], constant float2 &trims [[buffer(1)]],
                          uint2 id [[thread_position_in_grid]]) {
            if (id.x >= dst.get_width() || id.y >= dst.get_height()) return;
            const float kr = 0.2126, kg = 0.7152, kb = 0.0722, cbS = 1.8556, crS = 1.5748;
            float3 c = src.read(id).rgb;
            float y = kr * c.r + kg * c.g + kb * c.b;
            float cb = (c.b - y) / cbS, cr = (c.r - y) / crS;
            float lr = curve[int(c.r)], lg = curve[int(c.g)], lb = curve[int(c.b)];
            float ny = kr * lr + kg * lg + kb * lb;
            if (trims.x != 1) { cb *= trims.x; cr *= trims.x; }
            ny = clamp(ny, 0.0, 255.0); cb = clamp(cb, -128.0, 127.0); cr = clamp(cr, -128.0, 127.0);
            float r = ny + crS * cr;
            float g = ny - (kr * crS / kg) * cr - (kb * cbS / kg) * cb;
            float b = ny + cbS * cb;
            if (trims.y != 0) { float w = trims.y * 255.0 * midtoneWeight(ny / 255.0); r += w; b -= w; }
            float3 o = floor(clamp(float3(r, g, b), 0.0, 255.0));
            dst.write(float4(o / 255.0, 1), id);
        }
        """
}
