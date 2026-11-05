import Foundation
import UniformTypeIdentifiers

/// 볼륨을 파일 디스크립터 기반으로 순회해 정리 후보를 찾는다.
/// - 심볼릭 링크는 따라가지 않는다(`O_NOFOLLOW`, `AT_SYMLINK_NOFOLLOW`).
/// - 마운트 지점의 장치 번호와 다른 디렉터리는 들어가지 않는다(파일시스템 경계 유지).
/// - 패키지(.app 등)와 시스템 보조 디렉터리는 의도적으로 건너뛴다(`excludedDirectories`).
/// - 깊이 우선으로 내려가며 열린 디렉터리 스트림은 깊이마다 하나뿐이다. 따라서 동시에 열린 fd 수는
///   `maxDepth + 1`을 넘지 않고, 형제 폴더 수와 무관하다.
/// - 접근 거부·깊이 제한·읽기 오류·fd 부족은 각각 따로 세어 결과를 '불완전'으로 표시한다.
/// - 결과 개수 상한에 도달하면 `truncated`로 표시하고 중단한다.
final class MetadataScanner {
    enum ScanError: Error, LocalizedError {
        case cannotOpenRoot(Int32)
        case rootDeviceMismatch
        case rootNotDirectory

        var errorDescription: String? {
            switch self {
            case .cannotOpenRoot(let code):
                if code == EACCES || code == EPERM {
                    return "볼륨 최상위 폴더를 열 수 없습니다(접근 거부). Finder에서 볼륨을 열 수 있는지 확인해 주세요."
                }
                return "볼륨 최상위 폴더를 열 수 없습니다: \(String(cString: strerror(code)))"
            case .rootDeviceMismatch:
                return "볼륨이 교체되었거나 연결 해제되어 확인을 중단했습니다."
            case .rootNotDirectory:
                return "마운트 지점이 폴더가 아닙니다."
            }
        }
    }

    /// 어떤 깊이에서도 들어가지 않는 디렉터리 이름.
    static let skippedDirectoryNames: Set<String> = [
        ".Trashes", ".Trash", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
        ".DocumentRevisions-V100", ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware",
        "System Volume Information", "$RECYCLE.BIN", ".HFS+ Private Directory Data\r",
        "lost+found", ".vol", ".timemachine", "Backups.backupdb", ".MobileBackups",
    ]

    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "pkg", "mpkg",
        "photoslibrary", "photolibrary", "aplibrary", "imovielibrary", "fcpbundle", "band", "logicx",
        "xcodeproj", "xcworkspace", "playground", "rtfd", "key", "pages", "numbers", "scptd",
        "prefpane", "qlgenerator", "mdimporter", "saver", "wdgt", "sparsebundle", "tvlibrary",
    ]

    private let cancelFlag: CancellationFlag
    private let options: ScanOptions
    private let progress: (ScanProgress) -> Void
    private var lastProgressReport = Date.distantPast

    init(options: ScanOptions, cancelFlag: CancellationFlag, progress: @escaping (ScanProgress) -> Void) {
        self.options = options
        self.cancelFlag = cancelFlag
        self.progress = progress
    }

    /// 현재 열려 있는 한 깊이의 디렉터리. `dir`를 닫으면 `fd`도 함께 닫힌다.
    private struct Frame {
        let dir: UnsafeMutablePointer<DIR>
        let fd: Int32
        let components: [String]
    }

    func scan(volume: ExternalVolume) throws -> ScanResult {
        let rootFD = open(volume.mountPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ScanError.cannotOpenRoot(errno) }
        var rootStat = stat()
        guard fstat(rootFD, &rootStat) == 0 else {
            let code = errno
            close(rootFD)
            throw ScanError.cannotOpenRoot(code)
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            close(rootFD)
            throw ScanError.rootNotDirectory
        }
        guard rootStat.st_dev == volume.deviceID else {
            close(rootFD)
            throw ScanError.rootDeviceMismatch
        }
        guard let rootDir = fdopendir(rootFD) else {
            let code = errno
            close(rootFD)
            throw ScanError.cannotOpenRoot(code)
        }
        let rootDevice = rootStat.st_dev
        let rootInode = rootStat.st_ino

        var candidates: [USBCleanupCandidate] = []
        var directoriesVisited = 1
        var excluded = 0
        var accessDenied = 0
        var depthLimited = 0
        var errors = 0
        var truncated = false
        var cancelled = false

        var stack: [Frame] = [Frame(dir: rootDir, fd: rootFD, components: [])]
        defer { for frame in stack { closedir(frame.dir) } }

        reportProgress(ScanProgress(directoriesVisited: directoriesVisited, found: 0, currentDirectory: ""))

        while let frame = stack.last {
            if cancelFlag.isCancelled { cancelled = true; break }

            errno = 0
            guard let entry = readdir(frame.dir) else {
                if errno != 0 { errors += 1 }
                closedir(frame.dir)
                stack.removeLast()
                continue
            }
            let name = MetadataScanner.entryName(entry)
            if name == "." || name == ".." || name.isEmpty || name.contains("/") { continue }

            var resolvedType = Int32(entry.pointee.d_type)
            var sb = stat()
            var haveStat = false
            if resolvedType == DT_UNKNOWN || resolvedType == DT_REG {
                // 정확한 파일 종류·크기·inode·수정 시각 확인을 위해 링크를 따라가지 않고 stat 한다.
                if fstatat(frame.fd, name, &sb, AT_SYMLINK_NOFOLLOW) == 0 {
                    haveStat = true
                    switch sb.st_mode & S_IFMT {
                    case S_IFDIR: resolvedType = DT_DIR
                    case S_IFREG: resolvedType = DT_REG
                    case S_IFLNK: resolvedType = DT_LNK
                    default: resolvedType = DT_UNKNOWN
                    }
                } else {
                    if errno == EACCES || errno == EPERM { accessDenied += 1 } else { errors += 1 }
                    continue
                }
            }

            if resolvedType == DT_DIR {
                if MetadataScanner.shouldSkipDirectory(named: name) { excluded += 1; continue }
                if frame.components.count + 1 > options.maxDepth { depthLimited += 1; continue }
                let childFD = openat(frame.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if childFD < 0 {
                    switch errno {
                    case EACCES, EPERM: accessDenied += 1
                    default: errors += 1
                    }
                    continue
                }
                var childStat = stat()
                guard fstat(childFD, &childStat) == 0, (childStat.st_mode & S_IFMT) == S_IFDIR else {
                    close(childFD)
                    errors += 1
                    continue
                }
                // 다른 파일시스템(하위 마운트)은 의도적으로 들어가지 않는다.
                guard childStat.st_dev == rootDevice else {
                    close(childFD)
                    excluded += 1
                    continue
                }
                guard let childDir = fdopendir(childFD) else {
                    let code = errno
                    close(childFD)
                    if code == EACCES || code == EPERM { accessDenied += 1 } else { errors += 1 }
                    continue
                }
                let components = frame.components + [name]
                stack.append(Frame(dir: childDir, fd: childFD, components: components))
                directoriesVisited += 1
                reportProgress(ScanProgress(
                    directoriesVisited: directoriesVisited,
                    found: candidates.count,
                    currentDirectory: components.joined(separator: "/")
                ))
            } else if resolvedType == DT_REG {
                guard let kind = CleanupKind.classify(name: name, includeAppleDouble: options.includeAppleDouble) else { continue }
                if !haveStat {
                    guard fstatat(frame.fd, name, &sb, AT_SYMLINK_NOFOLLOW) == 0 else {
                        if errno == EACCES || errno == EPERM { accessDenied += 1 } else { errors += 1 }
                        continue
                    }
                }
                guard (sb.st_mode & S_IFMT) == S_IFREG, sb.st_dev == rootDevice else { continue }
                candidates.append(USBCleanupCandidate(components: frame.components + [name], kind: kind, stat: sb))
                if candidates.count >= options.maxResults {
                    truncated = true
                    break
                }
            }
        }

        candidates.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        reportProgress(ScanProgress(directoriesVisited: directoriesVisited, found: candidates.count, currentDirectory: ""), force: true)
        return ScanResult(
            volumeID: volume.id,
            rootDevice: rootDevice,
            rootInode: rootInode,
            candidates: candidates,
            directoriesVisited: directoriesVisited,
            excludedDirectories: excluded,
            accessDeniedCount: accessDenied,
            depthLimitedCount: depthLimited,
            errorCount: errors,
            truncated: truncated,
            cancelled: cancelled,
            options: options,
            finishedAt: Date()
        )
    }

    private func reportProgress(_ p: ScanProgress, force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(lastProgressReport) > 0.12 {
            lastProgressReport = now
            progress(p)
        }
    }

    static func shouldSkipDirectory(named name: String) -> Bool {
        if skippedDirectoryNames.contains(name) { return true }
        if name.hasPrefix(".Trash") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return false }
        if packageExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .package) || type.conforms(to: .bundle) {
            return true
        }
        return false
    }

    static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
                let len = Int(entry.pointee.d_namlen)
                let buffer = UnsafeBufferPointer(start: cstr, count: len)
                return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
    }
}

/// 스캔·정리 취소를 백그라운드 스레드와 공유하기 위한 단순 플래그.
final class CancellationFlag {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}
