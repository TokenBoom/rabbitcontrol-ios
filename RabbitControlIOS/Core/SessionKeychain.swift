import Foundation
import Security

struct SessionKeychain {
    var service = "com.rabbitcontrol.ios.login"
    private var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "session"]
    }

    func load() throws -> Data? {
        var query = key
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return item as? Data
    }

    func store(_ data: Data) throws {
        let values = [kSecValueData as String: data,
                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        let status = SecItemUpdate(key as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(key.merging(values) { _, v in v } as CFDictionary, nil))
        } else { try check(status) }
    }

    func remove() throws {
        let status = SecItemDelete(key as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
