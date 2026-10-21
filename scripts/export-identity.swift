// Prints a signing identity (certificate and private key) from a keychain as base64 of a PKCS #12
// file protected by TEAMS_PULSE_EXPORT_PASSWORD, for the release environment's RELEASE_CERTIFICATE_P12
// secret. scripts/make-release-keys.sh pipes it straight to the clipboard, so the private key is
// never written to a file. macOS asks you to allow the export.
//   TEAMS_PULSE_EXPORT_PASSWORD=… swift scripts/export-identity.swift <certificate name> [keychain]
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("export-identity: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let name = arguments.first else { fail("usage: export-identity.swift <certificate name> [keychain]") }
guard let password = ProcessInfo.processInfo.environment["TEAMS_PULSE_EXPORT_PASSWORD"], !password.isEmpty else {
    fail("set TEAMS_PULSE_EXPORT_PASSWORD")
}

var query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnRef as String: true,
    kSecReturnAttributes as String: true,
]
if arguments.count > 1 {
    var keychain: SecKeychain?
    guard SecKeychainOpen(arguments[1], &keychain) == errSecSuccess, let keychain else { fail("can't open \(arguments[1])") }
    query[kSecMatchSearchList as String] = [keychain]
}
var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
guard status == errSecSuccess, let items = result as? [[String: Any]] else { fail("no identities found (\(status))") }
let identities = items.compactMap { item -> SecIdentity? in
    guard let ref = item[kSecValueRef as String] else { return nil }
    let identity = ref as! SecIdentity
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
          SecCertificateCopySubjectSummary(certificate) as String? == name
    else { return nil }
    return identity
}
guard identities.count == 1, let identity = identities.first else {
    fail("expected exactly one identity named \"\(name)\", found \(identities.count)")
}

let passphrase = password as CFString
var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
parameters.passphrase = Unmanaged<AnyObject>.passUnretained(passphrase)
var exported: CFData?
let exportStatus = withExtendedLifetime(passphrase) {
    SecItemExport(identity, .formatPKCS12, [], &parameters, &exported)
}
guard exportStatus == errSecSuccess, let exported else {
    fail("the export failed (\(exportStatus)); macOS may have asked for permission and been refused")
}
print((exported as Data).base64EncodedString())
