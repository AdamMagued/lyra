import Foundation
import ApplicationServices

public enum AccessibilityHelper {
    /// Returns true if the process is currently trusted with macOS Accessibility permissions.
    public static var isAccessibilityTrusted: Bool {
        return AXIsProcessTrusted()
    }
    
    /// Requests accessibility permission prompt from macOS system if not already granted.
    public static func requestAccessibilityPrompt() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
