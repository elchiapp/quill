import Foundation
import Metal

struct DeviceProfile: Sendable, Equatable {
    static let gibibyte: UInt64 = 1_073_741_824

    let chipName: String
    let totalMemoryBytes: UInt64
    let processorCount: Int

    static var current: DeviceProfile {
        DeviceProfile(
            chipName: MTLCreateSystemDefaultDevice()?.name ?? "Apple silicon Mac",
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.processorCount
        )
    }

    var modelMemoryBudgetBytes: UInt64 {
        totalMemoryBytes / 2
    }

    var memoryLabel: String {
        "\(Int((totalMemoryBytes + Self.gibibyte / 2) / Self.gibibyte)) GB"
    }

    var summary: String {
        "\(chipName) · \(processorCount) CPU cores · \(memoryLabel) unified memory"
    }
}

struct BuiltInModel: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let name: String
    let parameterLabel: String
    let downloadBytes: UInt64
    let nativeContextTokens: Int
    let kvBytesPerToken: UInt64
    let minimumDeviceMemoryBytes: UInt64
    let detail: String

    var displayName: String {
        "\(name) · MLX 4-bit"
    }

    var downloadLabel: String {
        Self.bytesLabel(downloadBytes)
    }

    func estimatedModelMemoryBytes(contextTokens: Int) -> UInt64 {
        // Quantized weights still need temporary buffers and non-quantized
        // tensors while loaded. The 35% reserve is deliberately conservative.
        let residentWeights = downloadBytes + downloadBytes * 35 / 100
        return residentWeights + UInt64(max(0, contextTokens)) * kvBytesPerToken
    }

    func maximumContextTokens(within budgetBytes: UInt64) -> Int {
        let residentWeights = downloadBytes + downloadBytes * 35 / 100
        guard budgetBytes > residentWeights, kvBytesPerToken > 0 else { return 0 }
        let availableForContext = budgetBytes - residentWeights
        let calculated = min(
            UInt64(nativeContextTokens),
            availableForContext / kvBytesPerToken
        )
        let quantum = 4_096
        let rounded = Int(calculated) / quantum * quantum
        if rounded >= nativeContextTokens - quantum {
            return nativeContextTokens
        }
        return rounded
    }

    static func bytesLabel(_ bytes: UInt64) -> String {
        String(
            format: "%.1f GB",
            Double(bytes) / Double(DeviceProfile.gibibyte)
        )
    }
}

struct BuiltInModelPlan: Sendable, Equatable {
    let model: BuiltInModel
    let contextTokens: Int
    let memoryBudgetBytes: UInt64

    var estimatedModelMemoryBytes: UInt64 {
        model.estimatedModelMemoryBytes(contextTokens: contextTokens)
    }

    var contextLabel: String {
        contextTokens >= 1_000
            ? "\(contextTokens / 1_000)K tokens"
            : "\(contextTokens) tokens"
    }

    var memoryLabel: String {
        BuiltInModel.bytesLabel(estimatedModelMemoryBytes)
    }

    var budgetLabel: String {
        BuiltInModel.bytesLabel(memoryBudgetBytes)
    }

    var fitsMemoryBudget: Bool {
        contextTokens >= 16_384
            && estimatedModelMemoryBytes <= memoryBudgetBytes
    }
}

enum AIModelCatalog {
    private static let gb = DeviceProfile.gibibyte

    static let models: [BuiltInModel] = [
        BuiltInModel(
            id: "mlx-community/Qwen3.5-2B-4bit",
            name: "Qwen3.5 2B",
            parameterLabel: "2B",
            downloadBytes: 1_749_081_927,
            nativeContextTokens: 262_144,
            kvBytesPerToken: 7_373,
            minimumDeviceMemoryBytes: 8 * gb,
            detail: "Small, capable, and the conservative default."
        ),
        BuiltInModel(
            id: "mlx-community/Qwen3.5-4B-4bit",
            name: "Qwen3.5 4B",
            parameterLabel: "4B",
            downloadBytes: 3_061_130_647,
            nativeContextTokens: 262_144,
            kvBytesPerToken: 19_661,
            minimumDeviceMemoryBytes: 24 * gb,
            detail: "A quality step up for Macs with more memory."
        ),
        BuiltInModel(
            id: "mlx-community/Qwen3.5-9B-4bit",
            name: "Qwen3.5 9B",
            parameterLabel: "9B",
            downloadBytes: 5_977_073_303,
            nativeContextTokens: 262_144,
            kvBytesPerToken: 19_661,
            minimumDeviceMemoryBytes: 32 * gb,
            detail: "Stronger synthesis and reasoning on high-memory Macs."
        ),
        BuiltInModel(
            id: "mlx-community/Qwen3.6-27B-4bit",
            name: "Qwen3.6 27B",
            parameterLabel: "27B",
            downloadBytes: 16_081_490_064,
            nativeContextTokens: 262_144,
            kvBytesPerToken: 39_322,
            minimumDeviceMemoryBytes: 64 * gb,
            detail: "A large dense model for maximum answer quality."
        ),
        BuiltInModel(
            id: "mlx-community/Qwen3.6-35B-A3B-4bit",
            name: "Qwen3.6 35B-A3B",
            parameterLabel: "35B · 3B active",
            downloadBytes: 20_429_169_263,
            nativeContextTokens: 262_144,
            kvBytesPerToken: 12_288,
            minimumDeviceMemoryBytes: 64 * gb,
            detail: "Current high-end MoE model with strong quality and fast decoding."
        ),
    ]

    static let defaultModel = models[0]

    static func model(id: String?) -> BuiltInModel {
        models.first { $0.id == id } ?? defaultModel
    }

    static func plan(for model: BuiltInModel, device: DeviceProfile) -> BuiltInModelPlan {
        let context = model.maximumContextTokens(
            within: device.modelMemoryBudgetBytes
        )
        return BuiltInModelPlan(
            model: model,
            contextTokens: context,
            memoryBudgetBytes: device.modelMemoryBudgetBytes
        )
    }

    static func recommendation(for device: DeviceProfile) -> BuiltInModelPlan {
        let minimumUsefulContext = 131_072
        for model in models.reversed()
        where device.totalMemoryBytes >= model.minimumDeviceMemoryBytes {
            let candidate = plan(for: model, device: device)
            if candidate.fitsMemoryBudget
                && candidate.contextTokens >= minimumUsefulContext
            {
                return candidate
            }
        }
        return plan(for: defaultModel, device: device)
    }
}
