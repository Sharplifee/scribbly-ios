import AVFoundation
import Accelerate
import CoreML
import Foundation
import os

/// Produces a fixed-length vector per speaker turn so the same voice matches
/// itself across recordings.
///
/// Model: an ECAPA-TDNN or WeSpeaker checkpoint converted to CoreML, taking
/// 16 kHz mono float audio and emitting a 192-dim embedding. The conversion
/// is a build-time step, not runtime — drop `SpeakerEmbedding.mlmodelc` into
/// the bundle.
///
/// If the model is absent this degrades to unavailable rather than crashing,
/// and the pipeline keeps working with unlabeled speakers.
public actor SpeakerEmbedder {

    public static let dimension = 192
    /// Minimum audio needed for a stable embedding. Shorter turns are skipped.
    public static let minimumTurnDuration: TimeInterval = 1.5

    private let log = Logger(subsystem: "com.sharp.ambientcapture", category: "embed")
    private var model: MLModel?
    private var triedLoading = false

    public init() {}

    public var isAvailable: Bool {
        get async {
            await loadIfNeeded()
            return model != nil
        }
    }

    private func loadIfNeeded() async {
        guard !triedLoading else { return }
        triedLoading = true
        guard let url = Bundle.main.url(forResource: "SpeakerEmbedding", withExtension: "mlmodelc") else {
            log.notice("SpeakerEmbedding.mlmodelc not in bundle — identity disabled")
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: url, configuration: config)
            log.info("speaker embedding model loaded")
        } catch {
            log.error("model load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Embed one contiguous span of audio.
    public func embed(samples: [Float]) async throws -> [Float] {
        await loadIfNeeded()
        guard let model else { throw IdentityError.modelUnavailable }
        guard Double(samples.count) / 16_000.0 >= Self.minimumTurnDuration else {
            throw IdentityError.turnTooShort
        }

        let array = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: samples.count)
        samples.withUnsafeBufferPointer { src in
            ptr.update(from: src.baseAddress!, count: samples.count)
        }

        let input = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: array)])
        let output = try model.prediction(from: input)

        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw IdentityError.malformedOutput
        }

        var result = [Float](repeating: 0, count: vector.count)
        let vPtr = vector.dataPointer.bindMemory(to: Float.self, capacity: vector.count)
        for i in 0..<vector.count { result[i] = vPtr[i] }
        return Self.l2Normalize(result)
    }

    /// Extract the float samples for a time span of a file, at 16 kHz mono.
    public nonisolated static func samples(
        from url: URL,
        start: TimeInterval,
        end: TimeInterval
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceRate = file.processingFormat.sampleRate

        let startFrame = AVAudioFramePosition(start * sourceRate)
        let frameCount = AVAudioFrameCount(max(0, (end - start) * sourceRate))
        guard frameCount > 0 else { return [] }

        file.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: buffer, frameCount: frameCount)

        guard let channel = buffer.floatChannelData?[0] else { return [] }
        var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
        for i in 0..<Int(buffer.frameLength) { mono[i] = channel[i] }

        guard sourceRate != 16_000 else { return mono }
        return resample(mono, from: sourceRate, to: 16_000)
    }

    /// Linear resample. Adequate for embedding input; not for playback.
    private nonisolated static func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        let ratio = to / from
        let outCount = Int(Double(input.count) * ratio)
        guard outCount > 1 else { return input }
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) / ratio
            let lo = Int(pos)
            let hi = min(lo + 1, input.count - 1)
            let frac = Float(pos - Double(lo))
            out[i] = input[lo] * (1 - frac) + input[hi] * frac
        }
        return out
    }

    static func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var divisor = norm
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// Cosine similarity of two L2-normalized vectors is their dot product.
    public nonisolated static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }
}

public enum IdentityError: Error, LocalizedError {
    case modelUnavailable
    case turnTooShort
    case malformedOutput

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "speaker embedding model not available"
        case .turnTooShort: return "audio span too short for a stable embedding"
        case .malformedOutput: return "embedding model returned unexpected output"
        }
    }
}
