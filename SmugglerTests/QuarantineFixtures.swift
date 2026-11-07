//
//  QuarantineFixtures.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 05.09.26.
//

import Foundation

nonisolated private let quarantineName = "com.apple.quarantine"

nonisolated func setQuarantine(on url: URL) throws {
    try setXattr(quarantineName, "0001;00000000;Test;", on: url)
}

// Read independently of the service, so a wrong attribute name in the service
// fails the removal tests instead of agreeing with itself.
nonisolated func hasQuarantine(_ url: URL) -> Bool {
    xattrNames(of: url).contains(quarantineName)
}

nonisolated func setXattr(_ name: String, _ value: String, on url: URL) throws {
    let code: Int32 = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return EINVAL }
        let result = value.withCString { setxattr(path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
        return result == 0 ? 0 : errno
    }
    guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
}

nonisolated func xattrValue(_ name: String, of url: URL) -> String? {
    url.withUnsafeFileSystemRepresentation { path -> String? in
        guard let path else { return nil }
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        guard read >= 0 else { return nil }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }
}

nonisolated func xattrNames(of url: URL) -> Set<String> {
    url.withUnsafeFileSystemRepresentation { path -> Set<String> in
        guard let path else { return [] }
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard read > 0 else { return [] }
        let names = buffer.prefix(read).split(separator: 0).map { name in
            String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return Set(names)
    }
}
