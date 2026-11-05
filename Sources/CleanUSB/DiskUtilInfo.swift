import Foundation

/// `diskutil info -plist`의 결과를 필요한 항목만 읽어 들인 구조체.
/// 값이 없거나 형식이 다르면 `nil`로 남기고, 판별 단계에서 "알 수 없음 → 제외"로 처리한다.
///
/// 이 Mac(macOS 26)에서 확인한 사실:
/// - `VirtualOrPhysical`은 전체 디스크(disk0, disk3 …)에만 있고 파티션·볼륨(disk0s2, disk3s5 …)에는 없다.
/// - APFS 볼륨의 plist에는 `APFSPhysicalStores`(`[{APFSPhysicalStore: "disk0s2"}]`)와
///   `APFSContainerReference`가 있고, 그 컨테이너 디스크는 `VirtualOrPhysical == "Virtual"`이다.
/// - 디스크 이미지 위의 APFS 볼륨은 볼륨·물리 저장소 모두 `BusProtocol == "Disk Image"`다.
struct DiskUtilInfo {
    let raw: [String: Any]

    var mountPoint: String? { raw["MountPoint"] as? String }
    var volumeName: String? { raw["VolumeName"] as? String }
    var volumeUUID: String? { raw["VolumeUUID"] as? String }
    var deviceIdentifier: String? { raw["DeviceIdentifier"] as? String }
    var deviceNode: String? { raw["DeviceNode"] as? String }
    var busProtocol: String? { raw["BusProtocol"] as? String }
    var filesystemName: String? { raw["FilesystemName"] as? String ?? raw["FilesystemUserVisibleName"] as? String }
    var filesystemType: String? { raw["FilesystemType"] as? String }
    var virtualOrPhysical: String? { raw["VirtualOrPhysical"] as? String }
    var parentWholeDisk: String? { raw["ParentWholeDisk"] as? String }
    var apfsContainerReference: String? { raw["APFSContainerReference"] as? String }
    /// APFS 볼륨이 실제로 놓인 물리 저장소 파티션 식별자 목록.
    var apfsPhysicalStores: [String]? {
        guard let list = raw["APFSPhysicalStores"] as? [[String: Any]] else { return nil }
        let ids = list.compactMap { $0["APFSPhysicalStore"] as? String }
        return ids.count == list.count ? ids : nil
    }
    var internalDevice: Bool? { raw["Internal"] as? Bool }
    var removableMedia: Bool? { raw["RemovableMedia"] as? Bool }
    var removableMediaOrExternalDevice: Bool? { raw["RemovableMediaOrExternalDevice"] as? Bool }
    var ejectable: Bool? { raw["Ejectable"] as? Bool }
    var writableVolume: Bool? { raw["WritableVolume"] as? Bool }
    var writableMedia: Bool? { raw["WritableMedia"] as? Bool }
    var osInternalMedia: Bool? { raw["OSInternalMedia"] as? Bool }
    var totalSize: Int64? { (raw["TotalSize"] as? NSNumber)?.int64Value ?? (raw["Size"] as? NSNumber)?.int64Value }
    var freeSpace: Int64? {
        (raw["APFSContainerFree"] as? NSNumber)?.int64Value
            ?? (raw["FreeSpace"] as? NSNumber)?.int64Value
    }

    enum Failure: Error, LocalizedError {
        case launchFailed(String)
        case nonZeroExit(Int32, String)
        case invalidPlist

        var errorDescription: String? {
            switch self {
            case .launchFailed(let msg): return "diskutil을 실행할 수 없습니다: \(msg)"
            case .nonZeroExit(let code, let msg): return "diskutil 종료 코드 \(code): \(msg)"
            case .invalidPlist: return "diskutil 결과를 해석할 수 없습니다."
            }
        }
    }

    /// 주어진 마운트 지점(또는 장치 식별자)에 대해 diskutil을 동기 실행한다. 백그라운드에서 호출할 것.
    static func query(_ target: String) throws -> DiskUtilInfo {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", target]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.nonZeroExit(process.terminationStatus, msg)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: outData, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            throw Failure.invalidPlist
        }
        return DiskUtilInfo(raw: dict)
    }

    /// 볼륨을 표시하지 않는 이유. 사용자에게 그대로 보여 준다.
    enum Exclusion: Equatable {
        case mountPointMismatch
        case internalDevice
        case diskImageOrVirtualBus
        case notRemovable
        case notWritable
        case missingIdentifiers
        case apfsStoresUnknown
        case apfsStoreNotExternal(String)
        case wholeDiskUnknown
        case wholeDiskVirtual(String)

        var label: String {
            switch self {
            case .mountPointMismatch: return "마운트 지점을 확인할 수 없음"
            case .internalDevice: return "내장 디스크"
            case .diskImageOrVirtualBus: return "디스크 이미지·가상 장치"
            case .notRemovable: return "외장·이동식 장치가 아님"
            case .notWritable: return "쓰기 불가"
            case .missingIdentifiers: return "장치 식별자 없음"
            case .apfsStoresUnknown: return "APFS 물리 저장소를 확인할 수 없음"
            case .apfsStoreNotExternal(let id): return "APFS 물리 저장소(\(id))가 외장 물리 디스크가 아님"
            case .wholeDiskUnknown: return "상위 디스크를 확인할 수 없음"
            case .wholeDiskVirtual(let id): return "상위 디스크(\(id))가 가상 디스크"
            }
        }
    }

    /// 볼륨 자체의 plist만으로 판별할 수 있는 조건. 통과해도 `verifyBackingDisks`를 거쳐야 표시된다.
    func volumeLevelExclusion(expectedMountPoint: String) -> Exclusion? {
        guard let mp = mountPoint, !mp.isEmpty, mp == expectedMountPoint, mp.hasPrefix("/Volumes/") else { return .mountPointMismatch }
        guard internalDevice == false, osInternalMedia == false else { return .internalDevice }
        guard let proto = busProtocol, !proto.isEmpty, !DiskUtilInfo.isVirtualBus(proto) else { return .diskImageOrVirtualBus }
        guard removableMediaOrExternalDevice == true || removableMedia == true || ejectable == true else { return .notRemovable }
        guard writableVolume == true, writableMedia == true else { return .notWritable }
        guard deviceIdentifier != nil, deviceNode != nil else { return .missingIdentifiers }
        return nil
    }

    /// 볼륨 뒤에 있는 실제 디스크가 외장 물리 디스크인지 diskutil로 다시 확인한다.
    /// - APFS 볼륨: `APFSPhysicalStores`의 각 파티션과 그 `ParentWholeDisk`를 모두 확인한다. 목록이 없거나 비어 있으면 제외.
    /// - 그 밖의 볼륨: `ParentWholeDisk`를 확인한다.
    /// 전체 디스크는 `VirtualOrPhysical`이 "Virtual"이면 제외하고, 값이 없거나 "Unknown"이면 나머지 조건으로만 판단한다.
    func backingDiskExclusion(query: (String) throws -> DiskUtilInfo) -> Exclusion? {
        let isAPFS = filesystemType?.lowercased() == "apfs" || apfsPhysicalStores != nil || apfsContainerReference != nil
        if isAPFS {
            guard let stores = apfsPhysicalStores, !stores.isEmpty else { return .apfsStoresUnknown }
            for store in stores {
                guard let storeInfo = try? query(store) else { return .apfsStoreNotExternal(store) }
                guard storeInfo.isExternalPhysicalPiece else { return .apfsStoreNotExternal(store) }
                guard let whole = storeInfo.parentWholeDisk, let wholeInfo = try? query(whole) else { return .apfsStoreNotExternal(store) }
                if let ex = wholeInfo.wholeDiskExclusion(identifier: whole) { return ex }
            }
            return nil
        }
        guard let whole = parentWholeDisk, let wholeInfo = try? query(whole) else { return .wholeDiskUnknown }
        return wholeInfo.wholeDiskExclusion(identifier: whole)
    }

    /// 파티션(물리 저장소) 수준에서 외장·쓰기 가능·비가상 여부.
    private var isExternalPhysicalPiece: Bool {
        guard internalDevice == false, osInternalMedia == false else { return false }
        guard let proto = busProtocol, !proto.isEmpty, !DiskUtilInfo.isVirtualBus(proto) else { return false }
        guard removableMediaOrExternalDevice == true || removableMedia == true || ejectable == true else { return false }
        guard writableMedia == true else { return false }
        guard apfsPhysicalStores == nil else { return false } // 저장소 자체가 또 다른 APFS 볼륨이면(중첩) 지원하지 않는다.
        return true
    }

    private func wholeDiskExclusion(identifier: String) -> Exclusion? {
        if virtualOrPhysical == "Virtual" { return .wholeDiskVirtual(identifier) }
        guard internalDevice == false, osInternalMedia == false else { return .internalDevice }
        guard let proto = busProtocol, !proto.isEmpty, !DiskUtilInfo.isVirtualBus(proto) else { return .diskImageOrVirtualBus }
        guard removableMediaOrExternalDevice == true || removableMedia == true || ejectable == true else { return .notRemovable }
        return nil
    }

    private static func isVirtualBus(_ proto: String) -> Bool {
        proto == "Disk Image" || proto == "Virtual Interface"
    }
}
