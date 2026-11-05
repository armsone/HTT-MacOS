import Foundation
import AppKit

/// 일반 추출만 수행한다. 강제 추출·마운트 해제 옵션은 제공하지 않는다.
enum Ejector {
    enum EjectError: Error, LocalizedError {
        case volumeChanged(String)
        case system(Error)

        var errorDescription: String? {
            switch self {
            case .volumeChanged(let reason): return reason
            case .system(let error):
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteVolumeReadOnlyError {
                    return "볼륨을 추출할 수 없습니다: 읽기 전용 볼륨입니다."
                }
                return "추출 실패: \(ns.localizedDescription)"
            }
        }
    }

    /// 추출 전 볼륨이 아직 같은 장치인지 다시 확인한 뒤 NSWorkspace로 추출한다. 백그라운드에서 호출할 것.
    static func eject(_ volume: ExternalVolume) throws {
        guard let fresh = VolumeDiscovery.validate(mountPath: volume.mountPath, displayName: volume.name),
              fresh.id == volume.id, fresh.deviceIdentifier == volume.deviceIdentifier else {
            throw EjectError.volumeChanged("'\(volume.name)' 볼륨이 이미 연결 해제되었거나 다른 볼륨으로 바뀌어 추출하지 않았습니다.")
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.mountPoint)
        } catch {
            throw EjectError.system(error)
        }
    }
}
