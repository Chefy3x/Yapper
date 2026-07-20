import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "app.yapper.Yapper", category: "app")
    static let hotkey = Logger(subsystem: "app.yapper.Yapper", category: "hotkey")
    static let ax = Logger(subsystem: "app.yapper.Yapper", category: "ax")
    static let tts = Logger(subsystem: "app.yapper.Yapper", category: "tts")
}
