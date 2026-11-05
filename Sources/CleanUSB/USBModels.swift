import Foundation

/// 표시 대상이 되는 외장 로컬 볼륨. `id`는 볼륨 UUID(없으면 장치 식별자)로 세션 내에서 안정적으로 유지된다.
struct ExternalVolume: Identifiable, Hashable {
    let id: String
    let name: String
    let mountPoint: URL
    let deviceIdentifier: String
    let deviceNode: String
    let volumeUUID: String?
    let filesystemName: String
    let busProtocol: String
    let totalSize: Int64
    let freeSpace: Int64
    /// 마운트 지점의 `st_dev`. 스캔·삭제 시 파일시스템 경계와 볼륨 교체 여부를 판별하는 기준이다.
    let deviceID: dev_t

    var usedSize: Int64 { max(0, totalSize - freeSpace) }
    var usedFraction: Double {
        guard totalSize > 0 else { return 0 }
        return min(1, max(0, Double(usedSize) / Double(totalSize)))
    }
    var mountPath: String { mountPoint.path }
}

/// 정리 대상 종류. v0.1.0에서는 이 세 가지 이름 외에는 어떤 파일도 삭제하지 않는다.
enum CleanupKind: String, Codable, CaseIterable, Hashable {
    case dsStore
    case thumbsDb
    case appleDouble

    var label: String {
        switch self {
        case .dsStore: return ".DS_Store"
        case .thumbsDb: return "Thumbs.db"
        case .appleDouble: return "._ 부속 파일"
        }
    }

    var description: String {
        switch self {
        case .dsStore: return "macOS Finder가 폴더 보기 설정을 저장하는 파일"
        case .thumbsDb: return "Windows 탐색기가 만드는 미리보기 캐시"
        case .appleDouble: return "macOS가 다른 파일시스템에 리소스 포크·태그를 보관하는 부속 파일"
        }
    }

    /// 파일 이름이 이 종류에 정확히 해당하는지 판별한다.
    static func classify(name: String, includeAppleDouble: Bool) -> CleanupKind? {
        if name == ".DS_Store" { return .dsStore }
        if name == "Thumbs.db" || name == "thumbs.db" { return .thumbsDb }
        if includeAppleDouble, name.hasPrefix("._"), name.utf8.count > 2 { return .appleDouble }
        return nil
    }
}

/// 스캔에서 발견된 삭제 후보. 경로 구성 요소와 장치·inode·크기·수정 시각을 함께 보관해 삭제 시 같은 파일인지 재확인한다.
struct USBCleanupCandidate: Identifiable, Hashable {
    let id: String
    let components: [String]
    let kind: CleanupKind
    let size: Int64
    let device: dev_t
    let inode: ino_t
    /// 확인 시점의 `st_mtimespec`. 삭제 직전 값이 다르면 내용이 바뀐 것으로 보고 건너뛴다.
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    var name: String { components.last ?? "" }
    var relativePath: String { components.joined(separator: "/") }
    var parentPath: String { components.dropLast().joined(separator: "/") }

    init(components: [String], kind: CleanupKind, stat sb: stat) {
        self.components = components
        self.kind = kind
        self.size = Int64(sb.st_size)
        self.device = sb.st_dev
        self.inode = sb.st_ino
        self.modifiedSeconds = sb.st_mtimespec.tv_sec
        self.modifiedNanoseconds = sb.st_mtimespec.tv_nsec
        self.id = "\(sb.st_dev):\(sb.st_ino):\(components.joined(separator: "/"))"
    }

    /// 삭제 직전 다시 읽은 stat 이 확인 시점과 같은 파일·같은 내용인지 판별한다.
    func matches(_ sb: stat) -> Bool {
        sb.st_dev == device && sb.st_ino == inode && Int64(sb.st_size) == size
            && sb.st_mtimespec.tv_sec == modifiedSeconds && sb.st_mtimespec.tv_nsec == modifiedNanoseconds
    }
}

struct ScanOptions: Equatable {
    var includeAppleDouble: Bool = false
    var maxResults: Int = 5000
    var maxDepth: Int = 64
}

struct ScanProgress: Equatable {
    var directoriesVisited: Int = 0
    var found: Int = 0
    var currentDirectory: String = ""
}

/// 스캔 결과. `isComplete`가 아니면 볼륨 전체를 봤다고 말할 수 없으므로 자동 추출을 하지 않는다.
struct ScanResult: Equatable {
    let volumeID: String
    let rootDevice: dev_t
    let rootInode: ino_t
    let candidates: [USBCleanupCandidate]
    let directoriesVisited: Int
    /// 의도적으로 들어가지 않은 패키지·시스템 폴더 수. 완전성에는 영향을 주지 않는다.
    let excludedDirectories: Int
    /// 접근 거부(EACCES/EPERM)로 읽지 못한 폴더 수.
    let accessDeniedCount: Int
    /// 최대 깊이 제한에 걸려 들어가지 않은 폴더 수.
    let depthLimitedCount: Int
    /// fd 부족(EMFILE/ENFILE)·읽기 오류 등 그 밖의 이유로 건너뛴 폴더·항목 수.
    let errorCount: Int
    let truncated: Bool
    let cancelled: Bool
    let options: ScanOptions
    let finishedAt: Date

    var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.size } }

    /// 취소·잘림·접근 거부·깊이 제한·오류가 하나도 없을 때만 참. 모든 자동 추출 판단은 이 값을 쓴다.
    var isComplete: Bool {
        !truncated && !cancelled && accessDeniedCount == 0 && depthLimitedCount == 0 && errorCount == 0
    }

    /// 불완전한 이유를 사용자에게 보여 줄 문장 목록. 완전하면 비어 있다.
    var incompleteReasons: [String] {
        var notes: [String] = []
        if cancelled { notes.append("취소되어 일부만 확인했습니다") }
        if truncated { notes.append("상한 \(options.maxResults)개에 도달해 확인을 멈췄습니다") }
        if accessDeniedCount > 0 { notes.append("접근이 거부된 폴더 \(accessDeniedCount)개를 읽지 못했습니다") }
        if depthLimitedCount > 0 { notes.append("깊이 \(options.maxDepth)단계를 넘는 폴더 \(depthLimitedCount)개는 확인하지 않았습니다") }
        if errorCount > 0 { notes.append("읽기 오류나 자원 부족으로 \(errorCount)개 항목을 건너뛰었습니다") }
        return notes
    }

    func bytes(of kind: CleanupKind) -> Int64 {
        candidates.reduce(0) { $0 + ($1.kind == kind ? $1.size : 0) }
    }

    func count(of kind: CleanupKind) -> Int {
        candidates.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }
}

struct FileFailure: Identifiable, Hashable {
    let id = UUID()
    let relativePath: String
    let message: String
}

struct CleanupReport: Equatable {
    let deletedCount: Int
    let deletedBytes: Int64
    let failures: [FileFailure]
    let cancelled: Bool
    let abortedReason: String?

    var isCompleteSuccess: Bool { failures.isEmpty && !cancelled && abortedReason == nil }
}

/// 최근 작업 요약. 파일 경로는 저장하지 않고 개수·용량·결과만 보관한다.
struct OperationSummary: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case scan
        case cleanup
        case eject
    }
    enum Outcome: String, Codable {
        case success
        case partial
        case failed
        case cancelled
    }

    var id: UUID = UUID()
    var date: Date
    var kind: Kind
    var outcome: Outcome
    var volumeName: String
    var count: Int
    var bytes: Int64
    var detail: String

    var kindLabel: String {
        switch kind {
        case .scan: return "확인"
        case .cleanup: return "정리"
        case .eject: return "추출"
        }
    }

    var outcomeLabel: String {
        switch outcome {
        case .success: return "완료"
        case .partial: return "일부 실패"
        case .failed: return "실패"
        case .cancelled: return "취소됨"
        }
    }
}

enum ByteFormat {
    static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}
