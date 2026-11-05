import Foundation

/// 미리보기에서 선택한 후보를 실제로 삭제한다.
/// 경로 문자열로 삭제하지 않고, 마운트 지점을 새로 연 디렉터리 fd에서 구성 요소를 하나씩
/// `openat(O_NOFOLLOW|O_DIRECTORY)` 로 내려간 뒤 `fstatat` 로 장치·inode·크기·수정 시각·일반 파일 여부를
/// 확인하고 `unlinkat` 으로 지운다. 조건이 하나라도 어긋나면 해당 파일은 건너뛰고 오류로 기록한다.
/// 한계: `fstatat`와 `unlinkat` 사이는 원자적이지 않다. 허용 이름 제한, `O_NOFOLLOW` 조상 탐색, 장치 번호
/// 확인으로 위험을 크게 줄이지만, 같은 이름의 파일이 그 짧은 순간에 교체되는 경우까지 막지는 못한다.
struct SafeDeleter {
    enum Abort: Error, LocalizedError {
        case volumeChanged(String)

        var errorDescription: String? {
            switch self {
            case .volumeChanged(let reason): return reason
            }
        }
    }

    let volume: ExternalVolume
    let scan: ScanResult
    let includeAppleDouble: Bool
    let cancelFlag: CancellationFlag
    let progress: (Int, Int) -> Void

    /// 볼륨이 여전히 같은 외장 디스크로 마운트되어 있는지 diskutil·statfs로 재확인한다.
    static func revalidate(volume: ExternalVolume) throws {
        guard let fresh = VolumeDiscovery.validate(mountPath: volume.mountPath, displayName: volume.name) else {
            throw Abort.volumeChanged("'\(volume.name)' 볼륨을 다시 확인할 수 없습니다. 연결 해제되었거나 조건(외장·로컬·쓰기 가능)을 만족하지 않아 정리를 중단했습니다.")
        }
        guard fresh.id == volume.id,
              fresh.deviceIdentifier == volume.deviceIdentifier,
              fresh.volumeUUID == volume.volumeUUID,
              fresh.mountPath == volume.mountPath,
              fresh.deviceID == volume.deviceID else {
            throw Abort.volumeChanged("'\(volume.name)' 자리에 다른 볼륨이 마운트된 것으로 보여 정리를 중단했습니다. 다시 확인해 주세요.")
        }
    }

    func run(candidates: [USBCleanupCandidate]) -> CleanupReport {
        do {
            try SafeDeleter.revalidate(volume: volume)
        } catch {
            return CleanupReport(deletedCount: 0, deletedBytes: 0, failures: [], cancelled: false, abortedReason: error.localizedDescription)
        }

        let rootFD = open(volume.mountPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            return CleanupReport(deletedCount: 0, deletedBytes: 0, failures: [], cancelled: false,
                                 abortedReason: "볼륨 최상위 폴더를 열 수 없습니다: \(String(cString: strerror(errno)))")
        }
        defer { close(rootFD) }
        var rootStat = stat()
        guard fstat(rootFD, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR,
              rootStat.st_dev == scan.rootDevice,
              rootStat.st_ino == scan.rootInode,
              rootStat.st_dev == volume.deviceID else {
            return CleanupReport(deletedCount: 0, deletedBytes: 0, failures: [], cancelled: false,
                                 abortedReason: "볼륨 최상위 폴더가 확인 시점과 다릅니다. 볼륨이 교체되었을 수 있어 정리를 중단했습니다.")
        }

        var deleted = 0
        var deletedBytes: Int64 = 0
        var failures: [FileFailure] = []
        var cancelled = false

        for (index, candidate) in candidates.enumerated() {
            if cancelFlag.isCancelled { cancelled = true; break }
            progress(index, candidates.count)
            if let message = deleteOne(candidate, rootFD: rootFD) {
                failures.append(FileFailure(relativePath: candidate.relativePath, message: message))
            } else {
                deleted += 1
                deletedBytes += candidate.size
            }
        }
        progress(candidates.count, candidates.count)
        return CleanupReport(deletedCount: deleted, deletedBytes: deletedBytes, failures: failures, cancelled: cancelled, abortedReason: nil)
    }

    /// 성공하면 `nil`, 실패하면 사용자에게 보여줄 메시지를 돌려준다.
    private func deleteOne(_ candidate: USBCleanupCandidate, rootFD: Int32) -> String? {
        guard candidate.device == scan.rootDevice else { return "다른 볼륨의 파일이라 건너뛰었습니다." }
        guard let name = candidate.components.last, candidate.components.count >= 1 else { return "잘못된 경로입니다." }
        guard let expectedKind = CleanupKind.classify(name: name, includeAppleDouble: true), expectedKind == candidate.kind else {
            return "허용된 이름(.DS_Store, Thumbs.db, ._*)이 아니라 건너뛰었습니다."
        }
        if candidate.kind == .appleDouble && !includeAppleDouble {
            return "._ 부속 파일 옵션이 꺼져 있어 건너뛰었습니다."
        }
        for component in candidate.components {
            if component.isEmpty || component == "." || component == ".." || component.contains("/") {
                return "허용되지 않는 경로 구성 요소가 있어 건너뛰었습니다."
            }
        }

        // 조상 디렉터리를 하나씩 O_NOFOLLOW 로 연다. 각 단계에서 같은 장치인지 확인한다.
        var currentFD = dup(rootFD)
        guard currentFD >= 0 else { return "디렉터리 핸들을 복제할 수 없습니다." }
        defer { close(currentFD) }

        for component in candidate.components.dropLast() {
            let next = openat(currentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let code = errno
                switch code {
                case ELOOP: return "경로에 심볼릭 링크가 있어 건너뛰었습니다."
                case ENOENT: return "폴더가 더 이상 존재하지 않습니다."
                case ENOTDIR: return "경로 일부가 폴더가 아니라 건너뛰었습니다."
                case EACCES, EPERM: return "폴더 접근이 거부되었습니다."
                default: return "폴더를 열 수 없습니다: \(String(cString: strerror(code)))"
                }
            }
            var sb = stat()
            guard fstat(next, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFDIR, sb.st_dev == scan.rootDevice else {
                close(next)
                return "경로가 볼륨 밖으로 벗어나거나 폴더가 아니어서 건너뛰었습니다."
            }
            close(currentFD)
            currentFD = next
        }

        var sb = stat()
        guard fstatat(currentFD, name, &sb, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if code == ENOENT { return "파일이 이미 없습니다." }
            return "파일 상태를 확인할 수 없습니다: \(String(cString: strerror(code)))"
        }
        guard (sb.st_mode & S_IFMT) == S_IFREG else { return "일반 파일이 아니어서 건너뛰었습니다." }
        guard sb.st_dev == candidate.device, sb.st_ino == candidate.inode else {
            return "확인 시점과 다른 파일로 바뀌어 건너뛰었습니다. 다시 확인해 주세요."
        }
        guard candidate.matches(sb) else {
            return "확인 시점 이후 크기나 수정 시각이 바뀌어 건너뛰었습니다. 다시 확인해 주세요."
        }
        if sb.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 {
            return "잠긴 파일이라 삭제하지 않았습니다."
        }

        guard unlinkat(currentFD, name, 0) == 0 else {
            let code = errno
            switch code {
            case EACCES, EPERM: return "삭제 권한이 없습니다."
            case EROFS: return "볼륨이 읽기 전용입니다."
            case ENOENT: return "파일이 이미 없습니다."
            case EBUSY: return "파일이 사용 중입니다."
            default: return "삭제 실패: \(String(cString: strerror(code)))"
            }
        }
        return nil
    }
}
