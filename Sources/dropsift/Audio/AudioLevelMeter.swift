import AVFoundation
import Foundation

enum AudioLevelMeter {
    /// Maps buffer RMS from a -52 dB noise floor to a compact 0...1 UI value.
    /// This is intentionally cheap enough to run on an audio callback.
    static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> Float {
        var sumOfSquares = 0.0
        var sampleCount = 0
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )

        for audioBuffer in audioBuffers {
            guard let data = audioBuffer.mData else { continue }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let sample = Double(samples[index])
                    sumOfSquares += sample * sample
                }
                sampleCount += count
            case .pcmFormatFloat64:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                let samples = data.assumingMemoryBound(to: Double.self)
                for index in 0..<count {
                    let sample = samples[index]
                    sumOfSquares += sample * sample
                }
                sampleCount += count
            case .pcmFormatInt16:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let sample = Double(samples[index]) / Double(Int16.max)
                    sumOfSquares += sample * sample
                }
                sampleCount += count
            case .pcmFormatInt32:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                let samples = data.assumingMemoryBound(to: Int32.self)
                for index in 0..<count {
                    let sample = Double(samples[index]) / Double(Int32.max)
                    sumOfSquares += sample * sample
                }
                sampleCount += count
            case .otherFormat:
                continue
            @unknown default:
                continue
            }
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumOfSquares / Double(sampleCount))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        let noiseFloor = -52.0
        guard decibels > noiseFloor else { return 0 }
        let linear = min(max((decibels - noiseFloor) / -noiseFloor, 0), 1)
        return Float(pow(linear, 0.72))
    }
}
