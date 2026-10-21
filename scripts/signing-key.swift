// Imports, checks and deletes the private key of the certificate that builds can be signed with
// (make signing-identity), for scripts/make-signing-identity.sh and scripts/build-app.sh. macOS ties
// Teams Pulse's Full Disk Access to that certificate, so any app that may use the key without asking
// could sign itself as Teams Pulse and get the access. That's why the key trusts no app, not even
// codesign, which asks for your login password each time it signs, and why it can't be exported.
//
//   swift scripts/signing-key.swift import <keychain> <name> [--trust <app>]
//       Imports a PKCS #12 identity: its password on the first line of standard input, then the
//       file in base64. --trust lets that app use the key without asking, for a keychain of its own
//       (CI) only.
//   swift scripts/signing-key.swift check <name> [keychain]
//       Fails with status 3 if any app may use the key of the certificate named <name> without
//       asking, and names them; with status 4 if there's no such certificate; with another status if
//       it can't tell. It reads only the key's access list, with user interaction off, so macOS never
//       asks anything.
//   swift scripts/signing-key.swift delete <name> <keychain>
//       Deletes each certificate named exactly <name> from the keychain, with its private key, one item
//       at a time, and checks that they're gone. Nothing else is touched.
import Foundation
import Security

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("signing-key: \(message)\n".utf8))
    exit(status)
}

func openKeychain(_ path: String) -> SecKeychain {
    var keychain: SecKeychain?
    guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { fail("can't open \(path)") }
    return keychain
}

func importIdentity(into path: String, name: String, trusting apps: [String]) -> Never {
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let lines = input.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    guard lines.count == 2, !lines[0].isEmpty,
          let data = Data(base64Encoded: String(lines[1]), options: .ignoreUnknownCharacters), !data.isEmpty
    else { fail("expected a password line, then a base64 PKCS #12, on standard input") }
    let passphrase = String(lines[0]) as CFString

    let trusted = apps.map { app -> SecTrustedApplication in
        var trustedApp: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(app, &trustedApp) == errSecSuccess, let trustedApp else {
            fail("can't trust \(app)")
        }
        return trustedApp
    }
    // An empty list trusts no app at all. Without an access object, the key would trust the app that
    // imports it.
    var access: SecAccess?
    guard SecAccessCreate(name as CFString, trusted as CFArray, &access) == errSecSuccess, let access else {
        fail("can't create the key's access list")
    }

    // Without kSecAttrIsExtractable, the key can't leave the keychain, even with the password.
    let keyAttributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged<AnyObject>.passUnretained(passphrase)
    parameters.accessRef = Unmanaged.passUnretained(access)
    parameters.keyAttributes = Unmanaged.passUnretained(keyAttributes)
    var format = SecExternalFormat.formatPKCS12
    var type = SecExternalItemType.itemTypeAggregate
    let keychain = openKeychain(path)
    let status = withExtendedLifetime((passphrase, access, keyAttributes)) {
        SecItemImport(data as CFData, nil, &format, &type, [], &parameters, keychain, nil)
    }
    guard status == errSecSuccess else { fail("the import failed (\(status))") }
    exit(0)
}

func checkKey(named name: String, in path: String?) -> Never {
    // Anything that would need a prompt fails instead.
    SecKeychainSetUserInteractionAllowed(false)
    var query: [String: Any] = [
        kSecClass as String: kSecClassIdentity,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true,
    ]
    if let path {
        query[kSecMatchSearchList as String] = [openKeychain(path)]
    }
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    let identities = status == errSecSuccess ? (result as? [SecIdentity] ?? []) : []

    var found = false
    var openTo: Set<String> = []
    for identity in identities {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              SecCertificateCopySubjectSummary(certificate) as String? == name
        else { continue }
        found = true
        var key: SecKey?
        var access: SecAccess?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
              SecKeychainItemCopyAccess(unsafeBitCast(key, to: SecKeychainItem.self), &access) == errSecSuccess,
              let access
        else { fail("can't read who may use the key of \"\(name)\"", status: 2) }
        let entries = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationSign) as? [SecACL] ?? []
        for entry in entries {
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(entry, &apps, &description, &prompt) == errSecSuccess else {
                fail("can't read who may use the key of \"\(name)\"", status: 2)
            }
            // No list at all means any app.
            guard let apps = apps as? [SecTrustedApplication] else {
                openTo.insert("any app")
                continue
            }
            for app in apps {
                var data: CFData?
                SecTrustedApplicationCopyData(app, &data)
                let path = data.map { String(decoding: $0 as Data, as: UTF8.self) }?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                openTo.insert(path ?? "an app")
            }
        }
    }
    guard found else { fail("there's no certificate named \"\(name)\"", status: 4) }
    guard openTo.isEmpty else {
        fail("these may use the key of \"\(name)\" without asking: \(openTo.sorted().joined(separator: ", "))", status: 3)
    }
    exit(0)
}

/// The certificates named exactly `name` in the keychain (security's -c matches part of a name).
func certificates(named name: String, in keychain: SecKeychain, path: String) -> [SecCertificate] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassCertificate,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true,
        kSecMatchSearchList as String: [keychain],
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { fail("can't search \(path) (\(status))") }
    return (result as? [SecCertificate] ?? []).filter { SecCertificateCopySubjectSummary($0) as String? == name }
}

/// The private keys in the keychain with this application label, the SHA-1 of the public key.
func privateKeyCount(label: Data, in keychain: SecKeychain, path: String) -> Int {
    let query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrApplicationLabel as String: label,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true,
        kSecMatchSearchList as String: [keychain],
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return 0 }
    guard status == errSecSuccess else { fail("can't search \(path) (\(status))") }
    return (result as? [AnyObject])?.count ?? 0
}

func deleteIdentities(named name: String, in path: String) -> Never {
    // Never asks: whatever would need a prompt fails instead.
    SecKeychainSetUserInteractionAllowed(false)
    let keychain = openKeychain(path)
    let found = certificates(named: name, in: keychain, path: path)
    guard !found.isEmpty else {
        print("There's no \"\(name)\" certificate in \(path).")
        exit(0)
    }
    var labels: [Data] = []
    for certificate in found {
        var identity: SecIdentity?
        var key: SecKey?
        if SecIdentityCreateWithCertificate(keychain, certificate, &identity) == errSecSuccess, let identity,
           SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key {
            guard let label = (SecKeyCopyAttributes(key) as? [String: Any])?[kSecAttrApplicationLabel as String] as? Data
            else { fail("can't identify the private key of \"\(name)\"") }
            labels.append(label)
            // Item by item, so that nothing but this key and its certificate can match.
            let status = SecKeychainItemDelete(unsafeBitCast(key, to: SecKeychainItem.self))
            guard status == errSecSuccess else { fail("can't delete the private key of \"\(name)\" (\(status))") }
        }
        let status = SecKeychainItemDelete(unsafeBitCast(certificate, to: SecKeychainItem.self))
        guard status == errSecSuccess else { fail("can't delete the \"\(name)\" certificate (\(status))") }
    }
    guard certificates(named: name, in: keychain, path: path).isEmpty else {
        fail("a \"\(name)\" certificate is still in \(path)")
    }
    for label in labels where privateKeyCount(label: label, in: keychain, path: path) > 0 {
        fail("the private key of \"\(name)\" is still in \(path)")
    }
    print("Deleted \(found.count) \"\(name)\" certificate(s) and \(labels.count) private key(s) from \(path).")
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "import" where arguments.count == 3:
    importIdentity(into: arguments[1], name: arguments[2], trusting: [])
case "import" where arguments.count == 5 && arguments[3] == "--trust":
    importIdentity(into: arguments[1], name: arguments[2], trusting: [arguments[4]])
case "check" where arguments.count == 2 || arguments.count == 3:
    checkKey(named: arguments[1], in: arguments.count == 3 ? arguments[2] : nil)
case "delete" where arguments.count == 3:
    deleteIdentities(named: arguments[1], in: arguments[2])
default:
    fail("usage: signing-key.swift import <keychain> <name> [--trust <app>] | check <name> [keychain] | delete <name> <keychain>",
         status: 64)
}
