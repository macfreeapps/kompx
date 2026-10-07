import AppKit

enum TrashManager {
    private static let errorDomain = "komPX.TrashManager"
    private static let automationPermissionErrorCode = 3

    static func emptyTrash() throws {
        var scriptError: NSDictionary?
        guard let script = NSAppleScript(source: "tell application \"Finder\" to empty trash") else {
            throw NSError(
                domain: errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The Trash command could not be prepared."]
            )
        }

        _ = script.executeAndReturnError(&scriptError)
        if let scriptError {
            let message = scriptError[NSAppleScript.errorMessage] as? String
                ?? "Finder could not empty the Trash."
            let errorNumber = (scriptError[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            let permissionDenied = errorNumber == -1743
                || message.localizedCaseInsensitiveContains("not authorized to send Apple events")
            throw NSError(
                domain: errorDomain,
                code: permissionDenied ? automationPermissionErrorCode : 2,
                userInfo: [
                    NSLocalizedDescriptionKey: permissionDenied
                        ? "macOS has not allowed komPX to control Finder. Allow it in System Settings, then try again."
                        : message
                ]
            )
        }
    }

    static func isAutomationPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == errorDomain && nsError.code == automationPermissionErrorCode
    }

    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
