import Cocoa
import Foundation
import ApplicationServices
import AVFoundation

struct VoiceStatus {
    let status: String
    let label: String
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

struct OllamaModel {
    let name: String
    let capabilities: [String]
    let needsTest: Bool
    let loaded: Bool
    let size: Int64?
    let family: String
    let families: [String]
    let parameterSize: String
    let quantization: String
}

struct ModelTask {
    let status: String
    let scope: String
    let label: String
    let detail: String
    let progress: Double?
    let updatedAt: String
}

struct OllamaScan {
    let available: Bool
    let status: String
    let error: String
    let baseURL: String
    let configuredCorrectionModel: String
    let configuredCorrectionModelInstalled: Bool
    let configuredCorrectionModelLoaded: Bool
    let transcriptionModels: [OllamaModel]
    let correctionModels: [OllamaModel]
}

struct PanelMaintenance {
    let pythonPath: String
    let launchAgentStatus: String
    let ollamaStatus: String
    let ollamaStatusCode: String
    let ollamaBaseURL: String
}
