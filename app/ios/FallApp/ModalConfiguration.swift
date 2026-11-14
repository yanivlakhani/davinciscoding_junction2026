import Foundation
import Security
import ModalTransport

struct ModalSetup {
    let settings: ModalServerSettings?
    let message: String
}

enum ModalSettings {
    static func configured() -> ModalSetup {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "ModalEndpointURL") as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            return ModalSetup(settings: nil, message: "Server URL not configured")
        }
        do {
            try provisionDebugCredential()
            guard let key = credential() else { return ModalSetup(settings: nil, message: "Server API key not provisioned") }
            return ModalSetup(settings: ModalServerSettings(baseURL: url, apiKey: key), message: "Connecting to server")
        } catch {
            return ModalSetup(settings: nil, message: "Cannot provision server key; unlock phone and retry")
        }
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "FallApp") + ".modal",
         kSecAttrAccount as String: "api-key"]
    }

    private static func credential() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    private static func provisionDebugCredential() throws {
        #if DEBUG
        // Passed once via devicectl's child environment. Never stored in source,
        // Info.plist, the executable, or a launch argument.
        guard let key = ProcessInfo.processInfo.environment["FALLAPP_MODAL_API_KEY"] else { return }
        guard !key.isEmpty, !key.contains("\r"), !key.contains("\n"), let data = key.data(using: .utf8) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
        #endif
    }
}
