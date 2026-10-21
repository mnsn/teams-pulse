// Puts standard input on the clipboard for scripts/make-release-keys.sh, marked as concealed and
// transient (nspasteboard.org) so that clipboard managers leave it out of their history. With --clear,
// it empties the clipboard instead.
//   … | swift scripts/copy-secret.swift
//   swift scripts/copy-secret.swift --clear
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("copy-secret: \(message)\n".utf8))
    exit(1)
}

let pasteboard = NSPasteboard.general
if CommandLine.arguments.dropFirst().first == "--clear" {
    pasteboard.clearContents()
    exit(0)
}
let secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard !secret.isEmpty else { fail("nothing to copy") }

let item = NSPasteboardItem()
item.setString(secret, forType: .string)
for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
    item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
}
pasteboard.clearContents()
guard pasteboard.writeObjects([item]) else { fail("couldn't write to the clipboard") }
