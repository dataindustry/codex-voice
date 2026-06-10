import Cocoa
import Foundation
import ApplicationServices
import AVFoundation

struct VoiceStatus {
    let status: String
    let labelKey: String
    let label: String
    let detailKey: String
    let detailArgs: [String: String]
    let detail: String
    let pid: Int?
    let updatedAt: String
    let isStale: Bool
}

struct InputDevice {
    let name: String
    let isDefault: Bool
    let channels: Int?
    let index: Int?
}

struct LocalModel {
    let id: String
    let name: String
    let role: String
    let modelType: String
    let installed: Bool
    let loaded: Bool
    let size: Int64?
    let parameterSize: String
    let architecture: String
    let vendor: String
    let quantization: String
}

struct ModelTask {
    let status: String
    let scope: String
    let modelID: String
    let phase: String
    let labelKey: String
    let labelArgs: [String: String]
    let label: String
    let detailKey: String
    let detailArgs: [String: String]
    let detail: String
    let progress: Double?
    let updatedAt: String
}

struct LocalModelScan {
    let available: Bool
    let status: String
    let error: String
    let socketPath: String
    let directASRModels: [LocalModel]
    let transcriptionModels: [LocalModel]
    let correctionModels: [LocalModel]
}

struct PanelMaintenance {
    let pythonPath: String
    let launchAgentStatus: String
    let modelServiceStatus: String
    let modelServiceStatusCode: String
    let modelServiceSocket: String
}
