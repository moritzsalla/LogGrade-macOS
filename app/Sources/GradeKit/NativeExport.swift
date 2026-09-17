import AVFoundation
import Accelerate
import CoreImage
import Foundation
import Metal

/// A clip's deliverables rendered in this process: AVFoundation decode, the live chain
/// (`ChainBuilder`), the delivery finish (`DeliveryFinish`) and VideoToolbox H.264.
///
/// WHY. grade.sh spends most of an export in ffmpeg's software pipeline and x264 on the CPU. On the
/// GPU (`MetalFrame`), a 5 s 1080x1920 reels export of IMG_0607 took 12.6 s against grade.sh's
/// 18.8 s on the Intel MacBook Pro; the CPU path here took 20.2 s, no faster than the engine, and
/// is kept only as the fallback when the GPU cannot take a frame.
///
/// THE COST IS FILE SIZE. VideoToolbox H.264 needs about 24 Mbit/s at 1080x1920 to deliver the grain
/// the engine's x264 CRF 18 delivers at about 11, measured through `ExportParityTests` (on the GPU
/// path 27 read 1.28 of the engine's grain; on the CPU path 24 read 0.79 and 30 read 1.22: the
/// scaler's detail moves it), so a file is about twice the engine's.
///
/// WHAT HOLDS IT. `ExportParityTests` renders the same clip both ways and bounds every stage against
/// the engine's file. Anything it does not do yet — `unsupported` says what — stays on grade.sh.
public enum NativeExport {
    public enum Failure: Error, CustomStringConvertible {
        case unsupported(String)
        case noVideoTrack
        case reader(String)
        case writer(String)
        case naming(String)
        case frame
        case cancelled

        public var description: String {
            switch self {
            case .unsupported(let why): return "not a native export: \(why)"
            case .noVideoTrack: return "the clip has no video track"
            case .reader(let s): return "decoding failed: \(s)"
            case .writer(let s): return "encoding failed: \(s)"
            case .naming(let s): return "no file name for \(s)"
            case .frame: return "a frame could not be graded"
            case .cancelled: return "cancelled"
            }
        }
    }

    /// Why this request cannot be exported natively yet, or nil when it can.
    public static func unsupported(
        look: Look, delivery: Project.Delivery, clip: Project.ClipSettings
    ) -> String? {
        if delivery.codec != .h264 { return "\(delivery.codec.label) is encoded by the engine" }
        if clip.stabilise { return "stabilisation is the engine's" }
        if look.finish.denoise > 0 { return "the log denoise is the engine's" }
        if look.finish.gauge != "none" { return "the \(look.finish.gauge) gauge is the engine's" }
        if delivery.fps != nil { return "a frame rate change is the engine's" }
        return nil
    }

    public static func export(
        source: URL, look: Look, delivery: Project.Delivery, clip: Project.ClipSettings,
        proofSeconds: Double?, outputDirectory: URL, engine: EngineLocation,
        progress: ((Int) -> Void)? = nil, isCancelled: (() -> Bool)? = nil
    ) throws -> [URL] {
        if let why = unsupported(look: look, delivery: delivery, clip: clip) {
            throw Failure.unsupported(why)
        }
        let asset = AVAsset(url: source)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let transform = track.preferredTransform
        let oriented = CGRect(origin: .zero, size: track.naturalSize).applying(transform)
        guard let turns = quarterTurns(transform) else {
            throw Failure.unsupported("a mirrored or skewed clip is the engine's")
        }
        let sourceSize = FrameSize(
            width: Int(abs(oriented.width)), height: Int(abs(oriented.height)))

        // The metering the engine does at 1 s, added by the builder as the engine adds it.
        let metered =
            clip.adjust.match
            ? try ExposureMeter(engine: engine).measure(
                source, referenceStops: look.matchReferenceStops) : nil

        let plan = try Plan(source: sourceSize, delivery: delivery, clip: clip)
        let stem = source.deletingPathExtension().lastPathComponent
        let builder = ChainBuilder(engine: engine)
        let built = try builder.build(
            look, metered: metered, frameLongEdge: max(plan.frameWidth, plan.frameHeight),
            sourceLongEdge: max(sourceSize.width, sourceSize.height))
        let finish = DeliveryFinish(look: look)
        // Grain in the negative, on the shared frame, as grade.sh's grain_prefix adds it.
        let grain = LiveGrain(
            strength: look.grainStrength, frameWidth: plan.frameWidth,
            frameHeight: plan.frameHeight)
        let range =
            proofSeconds.map {
                CMTimeRange(start: .zero, duration: CMTime(seconds: $0, preferredTimescale: 600))
            } ?? CMTimeRange(start: .zero, duration: asset.duration)

        // THE GPU WHEN IT CAN: every deliverable a crop of the shared frame at its own size, which
        // is what the plan gives unless a shape rounds away from it. Otherwise the CPU path.
        let gpu: MetalFrame? =
            plan.targets.allSatisfy { $0.crop.width == $0.width && $0.crop.height == $0.height }
            ? try? Self.metalFrame() : nil
        lastRenderedOnGPU = gpu != nil
        defer { release(gpu) }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let video = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: gpu != nil
                ? [
                    // The decoder's own planes, handed to the GPU as they are.
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ]
                : [
                    // RGB from the decoder: its YCbCr matrix and range expansion only, with no
                    // transfer function, as ffmpeg's `format=gbrp16le` gives. vImage scales it in
                    // 34 ms a 4K frame where Core Image took 94. BIG-ENDIAN ARGB, because the
                    // little-endian RGBA format was accepted and came back black: measured, every
                    // sample zero.
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64ARGB
                ])
        video.alwaysCopiesSampleData = true
        reader.add(video)

        let fps = Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 30)
        var outputs: [Output] = []
        for target in plan.targets {
            let name = try fileName(
                stem: stem, target: target.deliverable, delivery: delivery, engine: engine)
            outputs.append(
                try Output(
                    final: outputDirectory.appendingPathComponent(name), target: target,
                    delivery: delivery, fps: fps, asset: asset, range: range))
        }
        guard reader.startReading() else {
            throw Failure.reader(reader.error.map { "\($0)" } ?? "could not start")
        }
        for output in outputs { try output.start() }

        var index = 0
        var failure: Error?
        while failure == nil, let sample = video.copyNextSampleBuffer() {
            if isCancelled?() == true {
                failure = Failure.cancelled
                break
            }
            progress?(index)
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            do {
                if let gpu {
                    try gpu.render(
                        source: buffer, turns: turns, frameWidth: plan.frameWidth,
                        frameHeight: plan.frameHeight, grade: built.chain, grain: grain,
                        frame: index,
                        targets: try outputs.map { output in
                            MetalFrame.Target(
                                crop: (output.target.crop.x, output.target.crop.y),
                                finish: finish, output: try output.nextBuffer())
                        })
                    for output in outputs { try output.appendPending(at: time) }
                    index += 1
                    continue
                }
                let pixels = try uprightScaled(
                    buffer, turns: turns, width: plan.frameWidth, height: plan.frameHeight)
                guard
                    let converted = LiveChain.converted(
                        rgba16: pixels, width: plan.frameWidth, height: plan.frameHeight,
                        through: built.chain.stages, grain: grain, frame: index)
                else { throw Failure.frame }
                let rgba = LiveChain.gradedPixels(converted, with: built.chain.grade)
                for output in outputs {
                    try output.append(
                        rgba: rgba, width: plan.frameWidth, height: plan.frameHeight,
                        bytesPerRow: plan.frameWidth * 4, finish: finish, frame: index, at: time)
                }
            } catch {
                failure = error
            }
            index += 1
        }
        if failure == nil, reader.status == .failed {
            failure = Failure.reader(reader.error.map { "\($0)" } ?? "failed")
        }
        var written: [URL] = []
        for output in outputs {
            if let failure {
                output.cancel()
                _ = failure
            } else {
                written.append(try output.finish())
            }
        }
        if let failure { throw failure }
        return written
    }

    /// Whether the last export rendered on the GPU. A shader that fails to compile falls back to the
    /// CPU silently, which is right for a person exporting and wrong for a test measuring the GPU.
    public private(set) static var lastRenderedOnGPU = false

    /// The GPU the export renders on: the system's default, which on this MacBook Pro is the
    /// discrete Radeon (a 5 s 1080x1920 reels export in 12.6 s against 13.9 s on the integrated
    /// Intel, grade.sh 18.8 s). `LOGGRADE_GPU=integrated` picks the other, for measuring.
    ///
    /// KEPT FOR THE PROCESS, because compiling the shaders costs about a second an export. One
    /// export at a time holds it; a second concurrent one builds its own.
    static func metalFrame() throws -> MetalFrame {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedFrame, !cachedFrameBusy {
            cachedFrameBusy = true
            return cached
        }
        let integrated = ProcessInfo.processInfo.environment["LOGGRADE_GPU"] == "integrated"
        let device =
            integrated
            ? MTLCopyAllDevices().first { $0.isLowPower } : MTLCreateSystemDefaultDevice()
        let frame = try MetalFrame(chain: try MetalChain(device: device))
        if cachedFrame == nil {
            cachedFrame = frame
            cachedFrameBusy = true
        }
        return frame
    }

    static func release(_ frame: MetalFrame?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let frame, frame === cachedFrame { cachedFrameBusy = false }
    }

    private static let cacheLock = NSLock()
    private static var cachedFrame: MetalFrame?
    private static var cachedFrameBusy = false

    /// How many quarter turns clockwise the track's transform shows the picture at, or nil for a
    /// transform that is not a plain rotation.
    static func quarterTurns(_ t: CGAffineTransform) -> Int? {
        let a = t.a.rounded()
        let b = t.b.rounded()
        let c = t.c.rounded()
        let d = t.d.rounded()
        switch (a, b, c, d) {
        case (1, 0, 0, 1): return 0
        case (0, 1, -1, 0): return 1
        case (-1, 0, 0, -1): return 2
        case (0, -1, 1, 0): return 3
        default: return nil
        }
    }

    /// The decoded frame scaled to `width` x `height` once upright. Scaled BEFORE it is turned, so
    /// the rotation moves a 1080 frame rather than a 4K one; Lanczos either way (vImage's high
    /// quality resampling), as `zscale=f=lanczos` is.
    static func uprightScaled(_ buffer: CVPixelBuffer, turns: Int, width: Int, height: Int) throws
        -> [UInt16]
    {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        // Host order in place: the frame is the reader's own copy and is not read again.
        var planar = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(bh),
            width: vImagePixelCount(row / 2), rowBytes: row)
        guard
            vImageByteSwap_Planar16U(&planar, &planar, vImage_Flags(kvImageNoFlags))
                == kvImageNoError
        else { throw Failure.frame }
        var source = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(bh),
            width: vImagePixelCount(bw), rowBytes: row)
        let sideways = turns % 2 == 1
        let sw = sideways ? height : width
        let sh = sideways ? width : height
        var scaled = [UInt16](repeating: 0, count: sw * sh * 4)
        let scaleError = scaled.withUnsafeMutableBytes { d -> vImage_Error in
            var to = vImage_Buffer(
                data: d.baseAddress, height: vImagePixelCount(sh), width: vImagePixelCount(sw),
                rowBytes: sw * 8)
            return vImageScale_ARGB16U(
                &source, &to, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        guard scaleError == kvImageNoError else { throw Failure.frame }
        // ARGB to the RGBA the chain reads.
        let permuteError = scaled.withUnsafeMutableBytes { d -> vImage_Error in
            var buffer = vImage_Buffer(
                data: d.baseAddress, height: vImagePixelCount(sh), width: vImagePixelCount(sw),
                rowBytes: sw * 8)
            return vImagePermuteChannels_ARGB16U(
                &buffer, &buffer, [1, 2, 3, 0], vImage_Flags(kvImageNoFlags))
        }
        guard permuteError == kvImageNoError else { throw Failure.frame }
        guard turns != 0 else { return scaled }
        var upright = [UInt16](repeating: 0, count: width * height * 4)
        // vImage numbers its rotations counter-clockwise.
        let rotation = [
            kRotate0DegreesClockwise, kRotate90DegreesClockwise, kRotate180DegreesClockwise,
            kRotate270DegreesClockwise,
        ][turns]
        var back: [UInt16] = [0, 0, 0, 0]
        let rotateError = scaled.withUnsafeMutableBytes { s in
            upright.withUnsafeMutableBytes { d -> vImage_Error in
                var from = vImage_Buffer(
                    data: s.baseAddress, height: vImagePixelCount(sh), width: vImagePixelCount(sw),
                    rowBytes: sw * 8)
                var to = vImage_Buffer(
                    data: d.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 8)
                return vImageRotate90_ARGB16U(
                    &from, &to, UInt8(rotation), &back, vImage_Flags(kvImageNoFlags))
            }
        }
        guard rotateError == kvImageNoError else { throw Failure.frame }
        return upright
    }

    /// The engine's name for a deliverable's file, from `deliverable_spec` itself.
    static func fileName(
        stem: String, target: Deliverable, delivery: Project.Delivery, engine: EngineLocation
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c", #"source "$0/scripts/lib.sh" && deliverable_spec "$1""#, engine.root.path,
            target.spec,
        ]
        process.environment = EngineRun(engine: engine).childEnvironment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let fields = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard process.terminationStatus == 0, fields.count == 5 else {
            throw Failure.naming(target.spec)
        }
        return "\(stem)_\(fields[4]).\(delivery.container.rawValue)"
    }

    // MARK: geometry

    /// The shared frame and each deliverable's window on it, as grade.sh's one-pass render lays them
    /// out: `delivery_scale`, `scaled_even`, `scaled_crop`, `deliverable_height`.
    struct Plan {
        struct Target {
            let deliverable: Deliverable
            let width: Int
            let height: Int
            /// The window on the shared frame.
            let crop: (x: Int, y: Int, width: Int, height: Int)
        }

        let frameWidth: Int
        let frameHeight: Int
        let targets: [Target]

        init(source: FrameSize, delivery: Project.Delivery, clip: Project.ClipSettings) throws {
            let width = delivery.width
            var windows: [(Deliverable, Int, (Int, Int, Int, Int))] = []
            var scale = 0.0
            for deliverable in delivery.targets {
                let h = Self.even(width * deliverable.aspectHeight / deliverable.aspectWidth)
                let geometry = CropGeometry(source: source, deliverable: deliverable)
                var window = (0, 0, source.width, source.height)
                if geometry.crops {
                    let offset =
                        deliverable.cropOffset == .centre
                        ? geometry.centreOffset : (clip.cropOffset ?? geometry.centreOffset)
                    guard geometry.isValid(offset) else {
                        throw Failure.unsupported("crop offset \(offset) is outside the frame")
                    }
                    window =
                        geometry.axis == .y
                        ? (0, offset, geometry.windowWidth, geometry.windowHeight)
                        : (offset, 0, geometry.windowWidth, geometry.windowHeight)
                }
                windows.append((deliverable, h, window))
                scale = max(scale, Double(h) / Double(window.3))
            }
            // printf "%.6f", as delivery_scale prints it.
            scale = (scale * 1e6).rounded() / 1e6
            func scaledEven(_ n: Int) -> Int {
                let v = Int(Double(n) * scale + 0.5)
                return v - v % 2
            }
            let fw = scaledEven(source.width)
            let fh = scaledEven(source.height)
            frameWidth = fw
            frameHeight = fh
            targets = windows.map { deliverable, h, window in
                let crops = window.2 != source.width || window.3 != source.height
                var cw = crops ? scaledEven(window.2) : 0
                var ch = crops ? scaledEven(window.3) : 0
                var x = crops ? scaledEven(window.0) : 0
                var y = crops ? scaledEven(window.1) : 0
                if !crops {
                    (cw, ch) = (fw, fh)
                }
                cw = min(cw, fw)
                ch = min(ch, fh)
                if x + cw > fw { x = fw - cw }
                if y + ch > fh { y = fh - ch }
                return Target(
                    deliverable: deliverable, width: width, height: h, crop: (x, y, cw, ch))
            }
        }

        static func even(_ n: Int) -> Int { n - n % 2 }
    }

    // MARK: one deliverable's file

    final class Output {
        let final: URL
        let partial: URL
        let target: Plan.Target
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audio: Audio?
        let conversion: vImage_ARGBToYpCbCr

        init(
            final: URL, target: Plan.Target, delivery: Project.Delivery, fps: Double,
            asset: AVAsset, range: CMTimeRange
        ) throws {
            self.final = final
            self.target = target
            partial = final.deletingPathExtension().appendingPathExtension(
                "partial." + final.pathExtension)
            try? FileManager.default.removeItem(at: partial)
            writer = try AVAssetWriter(
                outputURL: partial, fileType: delivery.container == .mov ? .mov : .mp4)
            writer.shouldOptimizeForNetworkUse = true
            // CRF 18 at x264 medium measured about 16 Mbit/s at 1080x1920, 24 fps, grain on. The
            // hardware encoder is given that rate, scaled by pixels and frames, rather than a
            // quality number its Intel implementation does not take.
            let pixels = Double(target.width * target.height) / (1080 * 1920)
            let factor: Double = delivery.quality == .max ? 2 : delivery.quality == .high ? 1.5 : 1
            let bitrate = max(2_000_000, 24_000_000 * pixels * fps / 24 * factor)
            let colour: [String: Any] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
            videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: target.width,
                    AVVideoHeightKey: target.height,
                    AVVideoColorPropertiesKey: colour,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitrate,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                        AVVideoExpectedSourceFrameRateKey: fps,
                    ],
                ])
            videoInput.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferWidthKey as String: target.width,
                    kCVPixelBufferHeightKey as String: target.height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ])
            writer.add(videoInput)
            audio = delivery.audio ? try Audio(asset: asset, range: range, writer: writer) : nil

            var info = vImage_ARGBToYpCbCr()
            var pixelRange = vImage_YpCbCrPixelRange(
                Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235,
                YpMin: 16, CbCrMax: 240, CbCrMin: 16)
            guard
                vImageConvert_ARGBToYpCbCr_GenerateConversion(
                    kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &pixelRange, &info,
                    kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags))
                    == kvImageNoError
            else { throw Failure.writer("no 709 conversion") }
            conversion = info
        }

        func start() throws {
            guard writer.startWriting() else {
                throw Failure.writer(writer.error.map { "\($0)" } ?? "could not start")
            }
            writer.startSession(atSourceTime: .zero)
            try audio?.start()
        }

        private var pending: CVPixelBuffer?

        /// A buffer from the encoder's pool, tagged 709, once the encoder can take another frame.
        /// Kept as the pending frame for `appendPending`.
        func nextBuffer() throws -> CVPixelBuffer {
            while !videoInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw Failure.writer(writer.error.map { "\($0)" } ?? "failed")
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no buffer pool") }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw Failure.writer("no pixel buffer") }
            CVBufferSetAttachment(
                buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate)
            CVBufferSetAttachment(
                buffer, kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(
                buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate)
            pending = buffer
            return buffer
        }

        func appendPending(at time: CMTime) throws {
            guard let buffer = pending else { throw Failure.frame }
            pending = nil
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw Failure.writer(writer.error.map { "\($0)" } ?? "append failed")
            }
        }

        /// Crops and scales the graded RGBA frame to the deliverable, converts it to video-range
        /// 4:2:0 on the 709 matrix, finishes the luma and appends it.
        func append(
            rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int, finish: DeliveryFinish,
            frame: Int, at time: CMTime
        ) throws {
            let (cx, cy, cw, ch) = target.crop
            // ARGB for vImage, cropped.
            var cropped = [UInt8](repeating: 255, count: cw * ch * 4)
            for row in 0..<ch {
                let src = (cy + row) * bytesPerRow + cx * 4
                let dst = row * cw * 4
                for col in 0..<cw {
                    cropped[dst + col * 4 + 1] = rgba[src + col * 4]
                    cropped[dst + col * 4 + 2] = rgba[src + col * 4 + 1]
                    cropped[dst + col * 4 + 3] = rgba[src + col * 4 + 2]
                }
            }
            var argb = cropped
            if cw != target.width || ch != target.height {
                argb = [UInt8](repeating: 255, count: target.width * target.height * 4)
                let ok = cropped.withUnsafeMutableBytes { s in
                    argb.withUnsafeMutableBytes { d -> Bool in
                        var from = vImage_Buffer(
                            data: s.baseAddress, height: vImagePixelCount(ch),
                            width: vImagePixelCount(cw), rowBytes: cw * 4)
                        var to = vImage_Buffer(
                            data: d.baseAddress, height: vImagePixelCount(target.height),
                            width: vImagePixelCount(target.width), rowBytes: target.width * 4)
                        return vImageScale_ARGB8888(
                            &from, &to, nil, vImage_Flags(kvImageHighQualityResampling))
                            == kvImageNoError
                    }
                }
                guard ok else { throw Failure.frame }
            }

            while !videoInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw Failure.writer(writer.error.map { "\($0)" } ?? "failed")
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no buffer pool") }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw Failure.writer("no pixel buffer") }
            CVBufferSetAttachment(
                buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate)
            CVBufferSetAttachment(
                buffer, kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(
                buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate)

            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let w = target.width
            let h = target.height
            var luma = [UInt8](repeating: 0, count: w * h)
            let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
            else { throw Failure.frame }
            var info = conversion
            let converted = argb.withUnsafeMutableBytes { a -> vImage_Error in
                var src = vImage_Buffer(
                    data: a.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w),
                    rowBytes: w * 4)
                var yp = vImage_Buffer(
                    data: yBase, height: vImagePixelCount(h), width: vImagePixelCount(w),
                    rowBytes: yRow)
                var cbcr = vImage_Buffer(
                    data: cBase, height: vImagePixelCount(h / 2),
                    width: vImagePixelCount(w / 2), rowBytes: cRow)
                return vImageConvert_ARGB8888To420Yp8_CbCr8(
                    &src, &yp, &cbcr, &info, nil, vImage_Flags(kvImageNoFlags))
            }
            guard converted == kvImageNoError else { throw Failure.frame }

            let yPlane = yBase.assumingMemoryBound(to: UInt8.self)
            for row in 0..<h {
                for col in 0..<w { luma[row * w + col] = yPlane[row * yRow + col] }
            }
            finish.apply(to: &luma, width: w, height: h)
            for row in 0..<h {
                for col in 0..<w { yPlane[row * yRow + col] = luma[row * w + col] }
            }
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw Failure.writer(writer.error.map { "\($0)" } ?? "append failed")
            }
        }

        func finish() throws -> URL {
            videoInput.markAsFinished()
            try audio?.finish()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            guard writer.status == .completed else {
                throw Failure.writer(writer.error.map { "\($0)" } ?? "did not complete")
            }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
            return final
        }

        func cancel() {
            audio?.cancel()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partial)
        }
    }

    // MARK: audio

    /// The source's first audio track as AAC 192k, through the delivery high-pass at 60 Hz
    /// (`DELIVERY_AUDIO_HIGHPASS_HZ`): a second-order Butterworth, ffmpeg `highpass`'s default.
    final class Audio {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let queue = DispatchQueue(label: "gradekit.export.audio")
        let done = DispatchGroup()
        var error: Error?

        init?(asset: AVAsset, range: CMTimeRange, writer: AVAssetWriter) throws {
            guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
            let description = track.formatDescriptions.first.map { $0 as! CMAudioFormatDescription }
            let channels =
                description.flatMap {
                    CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
                }
                .map { Int($0.mChannelsPerFrame) } ?? 2
            reader = try AVAssetReader(asset: asset)
            reader.timeRange = range
            output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: channels,
                ])
            reader.add(output)
            input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 192_000,
                ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            self.channels = channels
        }

        let channels: Int

        func start() throws {
            guard reader.startReading() else {
                throw Failure.reader(reader.error.map { "\($0)" } ?? "audio")
            }
            var filters = [Biquad](
                repeating: Biquad.highPass(hz: 60, sampleRate: 48000), count: channels)
            done.enter()
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        done.leave()
                        return
                    }
                    if let block = CMSampleBufferGetDataBuffer(sample) {
                        var length = 0
                        var total = 0
                        var pointer: UnsafeMutablePointer<Int8>?
                        if CMBlockBufferGetDataPointer(
                            block, atOffset: 0, lengthAtOffsetOut: &length,
                            totalLengthOut: &total, dataPointerOut: &pointer)
                            == kCMBlockBufferNoErr,
                            length == total, let pointer
                        {
                            let count = total / MemoryLayout<Float32>.size
                            pointer.withMemoryRebound(to: Float32.self, capacity: count) { s in
                                for i in 0..<count {
                                    s[i] = Float32(filters[i % channels].process(Double(s[i])))
                                }
                            }
                        }
                    }
                    if !input.append(sample) {
                        done.leave()
                        return
                    }
                }
            }
        }

        func finish() throws {
            done.wait()
            if reader.status == .failed {
                throw Failure.reader(reader.error.map { "\($0)" } ?? "audio")
            }
        }

        func cancel() { reader.cancelReading() }
    }

    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        /// The RBJ cookbook high-pass at Q 0.707, which is ffmpeg `highpass`'s default width.
        static func highPass(hz: Double, sampleRate: Double) -> Biquad {
            let w0 = 2 * Double.pi * hz / sampleRate
            let alpha = sin(w0) / (2 * 0.707)
            let a0 = 1 + alpha
            var f = Biquad()
            f.b0 = (1 + cos(w0)) / 2 / a0
            f.b1 = -(1 + cos(w0)) / a0
            f.b2 = (1 + cos(w0)) / 2 / a0
            f.a1 = -2 * cos(w0) / a0
            f.a2 = (1 - alpha) / a0
            return f
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            return y
        }
    }
}
