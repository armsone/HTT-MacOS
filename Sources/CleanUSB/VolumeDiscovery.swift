import Foundation
import AppKit

/// 연결된 볼륨 중 외장·로컬·물리·쓰기 가능한 것만 골라낸다.
/// 1단계: URL 리소스 값으로 네트워크·내장·읽기 전용 볼륨을 걸러 diskutil 호출을 최소화한다.
/// 2단계: `diskutil info -plist`와 `statfs`로 볼륨과 그 뒤의 물리 디스크(APFS는 물리 저장소)를 확인한다.
///        확인되지 않으면 제외하고, 사용자에게 보여 줄 수 있도록 이름과 사유를 남긴다.
enum VolumeDiscovery {
    /// 1단계는 통과했지만 2단계에서 제외된 볼륨.
    struct ExcludedVolume: Identifiable, Hashable {
        let name: String
        let reason: String
        var id: String { name }
    }

    struct DiscoveryResult {
        var volumes: [ExternalVolume] = []
        var excluded: [ExcludedVolume] = []
    }

    static func discover() -> DiscoveryResult {
        let keys: [URLResourceKey] = [
            .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsReadOnlyKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey, .volumeNameKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return DiscoveryResult()
        }
        var result = DiscoveryResult()
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.volumeIsLocal == true else { continue }
            guard values.volumeIsInternal == false else { continue }
            guard values.volumeIsReadOnly == false else { continue }
            guard values.volumeIsRootFileSystem == false else { continue }
            guard values.volumeIsBrowsable == true else { continue }
            guard values.volumeIsRemovable == true || values.volumeIsEjectable == true else { continue }
            let path = url.path
            guard path.hasPrefix("/Volumes/") else { continue }
            let displayName = values.volumeName ?? (path as NSString).lastPathComponent
            switch validateDetailed(mountPath: path, displayName: displayName) {
            case .success(let volume):
                result.volumes.append(volume)
            case .failure(let reason):
                result.excluded.append(ExcludedVolume(name: displayName, reason: reason.label))
            }
        }
        result.volumes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result.excluded.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    enum Rejection: Error {
        case diskutilFailed
        case excluded(DiskUtilInfo.Exclusion)
        case statfsFailed
        case notLocalOrReadOnly

        var label: String {
            switch self {
            case .diskutilFailed: return "diskutil 정보를 읽을 수 없음"
            case .excluded(let ex): return ex.label
            case .statfsFailed: return "마운트 정보를 읽을 수 없음"
            case .notLocalOrReadOnly: return "로컬 볼륨이 아니거나 읽기 전용"
            }
        }
    }

    /// 마운트 지점 하나를 diskutil과 statfs로 재검증해 `ExternalVolume`을 만든다. 조건 미충족 시 `nil`.
    static func validate(mountPath: String, displayName: String?) -> ExternalVolume? {
        try? validateDetailed(mountPath: mountPath, displayName: displayName).get()
    }

    static func validateDetailed(mountPath: String, displayName: String?) -> Result<ExternalVolume, Rejection> {
        guard let info = try? DiskUtilInfo.query(mountPath) else { return .failure(.diskutilFailed) }
        if let ex = info.volumeLevelExclusion(expectedMountPoint: mountPath) { return .failure(.excluded(ex)) }
        if let ex = info.backingDiskExclusion(query: DiskUtilInfo.query) { return .failure(.excluded(ex)) }
        guard let fs = statfsInfo(mountPath), fs.mountOnName == mountPath else { return .failure(.statfsFailed) }
        guard fs.isLocal, !fs.isReadOnly else { return .failure(.notLocalOrReadOnly) }
        guard let deviceIdentifier = info.deviceIdentifier, let deviceNode = info.deviceNode else {
            return .failure(.excluded(.missingIdentifiers))
        }
        let name = info.volumeName.flatMap { $0.isEmpty ? nil : $0 } ?? displayName ?? (mountPath as NSString).lastPathComponent
        let id = info.volumeUUID.map { "uuid:\($0)" } ?? "dev:\(deviceIdentifier)"
        return .success(ExternalVolume(
            id: id,
            name: name,
            mountPoint: URL(fileURLWithPath: mountPath, isDirectory: true),
            deviceIdentifier: deviceIdentifier,
            deviceNode: deviceNode,
            volumeUUID: info.volumeUUID,
            filesystemName: info.filesystemName ?? fs.typeName,
            busProtocol: info.busProtocol ?? "",
            totalSize: info.totalSize ?? fs.totalBytes,
            freeSpace: info.freeSpace ?? fs.freeBytes,
            deviceID: fs.deviceID
        ))
    }

    struct StatFSInfo {
        let mountOnName: String
        let typeName: String
        let isLocal: Bool
        let isReadOnly: Bool
        let totalBytes: Int64
        let freeBytes: Int64
        let deviceID: dev_t
    }

    static func statfsInfo(_ path: String) -> StatFSInfo? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        var sb = stat()
        guard lstat(path, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let mountOn = withUnsafePointer(to: &st.f_mntonname) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let typeName = withUnsafePointer(to: &st.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let flags = UInt32(st.f_flags)
        return StatFSInfo(
            mountOnName: mountOn,
            typeName: typeName,
            isLocal: flags & UInt32(MNT_LOCAL) != 0,
            isReadOnly: flags & UInt32(MNT_RDONLY) != 0,
            totalBytes: Int64(st.f_blocks) * Int64(st.f_bsize),
            freeBytes: Int64(st.f_bavail) * Int64(st.f_bsize),
            deviceID: sb.st_dev
        )
    }
}
