import Foundation
import AppKit
import Combine

struct CleanupProgress: Equatable {
    var done: Int = 0
    var total: Int = 0
}

/// 볼륨별로 화면 상단에 보여 주는 최근 결과 메시지.
struct StatusMessage: Equatable {
    enum Level: Equatable { case info, success, warning, error }
    var level: Level
    var text: String
}

/// 사용자 확인이 필요한 작업. 확인 창을 띄운 시점의 선택 항목과 옵션을 그대로 보관하고,
/// 승인 시 다시 계산하지 않고 이 스냅샷만 실행한다.
struct PendingAction: Identifiable {
    enum Kind {
        case cleanup(thenEject: Bool)
    }
    let id = UUID()
    let volume: ExternalVolume
    let kind: Kind
    /// 확인 창에 표시한 순서 그대로의 후보 목록.
    let candidates: [USBCleanupCandidate]
    /// 스냅샷을 만든 확인 결과의 완료 시각. 승인 시 결과가 바뀌어 있으면 실행하지 않는다.
    let scanFinishedAt: Date
    let includeAppleDouble: Bool

    var count: Int { candidates.count }
    var bytes: Int64 { candidates.reduce(0) { $0 + $1.size } }
    var appleDoubleCount: Int { candidates.reduce(0) { $0 + ($1.kind == .appleDouble ? 1 : 0) } }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

extension ScanResult {
    /// 정리에 성공한 항목을 제외한 새 결과를 만든다. 나머지 필드는 그대로 유지한다.
    func removing(candidateIDs: Set<String>) -> ScanResult {
        ScanResult(
            volumeID: volumeID,
            rootDevice: rootDevice,
            rootInode: rootInode,
            candidates: candidates.filter { !candidateIDs.contains($0.id) },
            directoriesVisited: directoriesVisited,
            excludedDirectories: excludedDirectories,
            accessDeniedCount: accessDeniedCount,
            depthLimitedCount: depthLimitedCount,
            errorCount: errorCount,
            truncated: truncated,
            cancelled: cancelled,
            options: options,
            finishedAt: finishedAt
        )
    }
}

/// 앱 전체 상태. 모든 변경은 메인 스레드에서 이루어지고, 무거운 작업(diskutil·스캔·삭제·추출)은 백그라운드에서 실행한 뒤 결과만 돌려받는다.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case cleaning
        case ejecting
    }

    private static let appleDoubleKey = "includeAppleDouble"
    private static let recentKey = "recentOperations"
    private static let recentLimit = 20

    @Published private(set) var volumes: [ExternalVolume] = []
    /// 외장처럼 보였지만 조건을 확인하지 못해 표시하지 않은 볼륨. 이유와 함께 보여 준다.
    @Published private(set) var excludedVolumes: [VolumeDiscovery.ExcludedVolume] = []
    @Published var selectedVolumeID: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var busyVolumeID: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var scanResults: [String: ScanResult] = [:]
    @Published private(set) var selectedCandidateIDs: [String: Set<String>] = [:]
    @Published private(set) var failures: [String: [FileFailure]] = [:]
    @Published private(set) var messages: [String: StatusMessage] = [:]
    @Published private(set) var scanProgress = ScanProgress()
    @Published private(set) var cleanupProgress = CleanupProgress()
    @Published private(set) var recentOperations: [OperationSummary] = []
    @Published var pendingAction: PendingAction?
    @Published var alert: AlertInfo?
    @Published var includeAppleDouble: Bool {
        didSet {
            UserDefaults.standard.set(includeAppleDouble, forKey: AppState.appleDoubleKey)
            if includeAppleDouble != oldValue { invalidateScans(reason: "._ 부속 파일 옵션이 바뀌어 이전 확인 결과를 지웠습니다. '정리할 파일 확인'을 다시 실행해 주세요.") }
        }
    }

    private var cancelFlag: CancellationFlag?
    private var observers: [NSObjectProtocol] = []
    private var refreshQueued = false

    init() {
        includeAppleDouble = UserDefaults.standard.bool(forKey: AppState.appleDoubleKey)
        recentOperations = AppState.loadRecent()
        observeMounts()
        refreshVolumes()
    }

    deinit {
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    var isBusy: Bool { phase != .idle }

    var selectedVolume: ExternalVolume? {
        guard let id = selectedVolumeID else { return nil }
        return volumes.first { $0.id == id }
    }

    func scanResult(for volume: ExternalVolume) -> ScanResult? { scanResults[volume.id] }
    func message(for volume: ExternalVolume) -> StatusMessage? { messages[volume.id] }
    func failures(for volume: ExternalVolume) -> [FileFailure] { failures[volume.id] ?? [] }
    func selectedIDs(for volume: ExternalVolume) -> Set<String> { selectedCandidateIDs[volume.id] ?? [] }

    func selectedCandidates(for volume: ExternalVolume) -> [USBCleanupCandidate] {
        guard let scan = scanResults[volume.id] else { return [] }
        let ids = selectedIDs(for: volume)
        return scan.candidates.filter { ids.contains($0.id) }
    }

    func isBusy(volume: ExternalVolume) -> Bool { busyVolumeID == volume.id && phase != .idle }

    // MARK: - 볼륨 목록

    private func observeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            })
        }
    }

    /// 연결된 외장 볼륨 목록을 다시 읽는다. 진행 중이면 한 번 더 예약해 마지막 변경을 놓치지 않는다.
    func refreshVolumes() {
        if isRefreshing {
            refreshQueued = true
            return
        }
        isRefreshing = true
        Task.detached(priority: .userInitiated) {
            let found = VolumeDiscovery.discover()
            await MainActor.run { self.applyVolumes(found) }
        }
    }

    private func applyVolumes(_ result: VolumeDiscovery.DiscoveryResult) {
        let found = result.volumes
        volumes = found
        excludedVolumes = result.excluded
        lastRefresh = Date()
        let ids = Set(found.map(\.id))
        for key in scanResults.keys where !ids.contains(key) {
            scanResults[key] = nil
            selectedCandidateIDs[key] = nil
            failures[key] = nil
            messages[key] = nil
        }
        if let selected = selectedVolumeID, !ids.contains(selected) {
            selectedVolumeID = found.first?.id
        } else if selectedVolumeID == nil {
            selectedVolumeID = found.first?.id
        }
        isRefreshing = false
        if refreshQueued {
            refreshQueued = false
            refreshVolumes()
        }
    }

    // MARK: - 확인(스캔)

    func startScan(_ volume: ExternalVolume) {
        guard phase == .idle else { return }
        let flag = CancellationFlag()
        cancelFlag = flag
        phase = .scanning
        busyVolumeID = volume.id
        scanProgress = ScanProgress()
        messages[volume.id] = nil
        failures[volume.id] = nil
        let options = ScanOptions(includeAppleDouble: includeAppleDouble)
        Task.detached(priority: .userInitiated) {
            let scanner = MetadataScanner(options: options, cancelFlag: flag) { progress in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.busyVolumeID == volume.id, self.phase == .scanning else { return }
                    self.scanProgress = progress
                }
            }
            do {
                let result = try scanner.scan(volume: volume)
                await MainActor.run { self.finishScan(volume, result: result) }
            } catch {
                await MainActor.run { self.failScan(volume, error: error) }
            }
        }
    }

    private func finishScan(_ volume: ExternalVolume, result: ScanResult) {
        scanResults[volume.id] = result
        selectedCandidateIDs[volume.id] = Set(result.candidates.map(\.id))
        let notes = result.incompleteReasons
        let count = result.candidates.count
        let scope = result.isComplete ? "" : "확인한 범위에서는 "
        let base = count == 0
            ? "\(scope)정리할 파일이 없습니다. 폴더 \(result.directoriesVisited)개를 확인했습니다."
            : "\(scope)정리 후보 \(count)개(\(ByteFormat.string(result.totalBytes)))를 찾았습니다. 폴더 \(result.directoriesVisited)개를 확인했습니다."
        let level: StatusMessage.Level = result.isComplete ? (count == 0 ? .success : .info) : .warning
        let tail = result.isComplete ? "" : " " + notes.joined(separator: ". ") + ". 볼륨 전체를 확인하지 못했으므로 정리 후 자동 추출은 할 수 없습니다."
        messages[volume.id] = StatusMessage(level: level, text: base + tail)
        addSummary(OperationSummary(
            date: Date(), kind: .scan,
            outcome: result.cancelled ? .cancelled : (result.isComplete ? .success : .partial),
            volumeName: volume.name, count: count, bytes: result.totalBytes,
            detail: result.isComplete ? "폴더 \(result.directoriesVisited)개 확인" : notes.joined(separator: ", ")
        ))
        endOperation()
    }

    /// 확인 자체가 실패하면 이전 결과를 남겨 두지 않는다. 오래된 목록이 새 결과처럼 보이지 않게 하기 위해서다.
    private func failScan(_ volume: ExternalVolume, error: Error) {
        scanResults[volume.id] = nil
        selectedCandidateIDs[volume.id] = nil
        messages[volume.id] = StatusMessage(level: .error, text: error.localizedDescription + " 이전 확인 결과는 지웠습니다.")
        addSummary(OperationSummary(date: Date(), kind: .scan, outcome: .failed, volumeName: volume.name,
                                    count: 0, bytes: 0, detail: error.localizedDescription))
        endOperation()
        refreshVolumes()
    }

    /// 옵션이 바뀌면 모든 볼륨의 확인 결과를 지운다. 목록이 어떤 옵션으로 만들어졌는지 애매해지는 상황을 없앤다.
    private func invalidateScans(reason: String) {
        guard phase == .idle else { return }
        for id in scanResults.keys {
            scanResults[id] = nil
            selectedCandidateIDs[id] = nil
            failures[id] = nil
            messages[id] = StatusMessage(level: .info, text: reason)
        }
    }

    func cancelCurrentOperation() {
        cancelFlag?.cancel()
    }

    private func endOperation() {
        phase = .idle
        busyVolumeID = nil
        cancelFlag = nil
    }

    // MARK: - 후보 선택

    func setSelected(_ selected: Bool, candidateID: String, volume: ExternalVolume) {
        var set = selectedCandidateIDs[volume.id] ?? []
        if selected { set.insert(candidateID) } else { set.remove(candidateID) }
        selectedCandidateIDs[volume.id] = set
    }

    func clearScan(volume: ExternalVolume) {
        scanResults[volume.id] = nil
        selectedCandidateIDs[volume.id] = nil
        failures[volume.id] = nil
        messages[volume.id] = nil
    }

    // MARK: - 정리

    /// 확인 창을 띄운다. 이 시점의 선택 항목을 스냅샷으로 보관하고, 실제 삭제는 `performCleanup`에서만 일어난다.
    func requestCleanup(_ volume: ExternalVolume, thenEject: Bool) {
        guard phase == .idle, let scan = scanResults[volume.id] else { return }
        if thenEject && !scan.isComplete { return }
        let selected = selectedCandidates(for: volume)
        guard !selected.isEmpty else { return }
        pendingAction = PendingAction(
            volume: volume, kind: .cleanup(thenEject: thenEject),
            candidates: selected, scanFinishedAt: scan.finishedAt,
            includeAppleDouble: scan.options.includeAppleDouble
        )
    }

    func performPendingAction(_ action: PendingAction) {
        guard pendingAction?.id == action.id else { return }
        pendingAction = nil
        switch action.kind {
        case .cleanup(let thenEject):
            performCleanup(action, thenEject: thenEject)
        }
    }

    private func performCleanup(_ action: PendingAction, thenEject: Bool) {
        let volume = action.volume
        guard phase == .idle, let scan = scanResults[volume.id] else { return }
        // 확인 창을 띄운 뒤 결과가 바뀌었으면(다시 확인·옵션 변경) 스냅샷을 실행하지 않는다.
        guard scan.finishedAt == action.scanFinishedAt, scan.options.includeAppleDouble == action.includeAppleDouble else {
            messages[volume.id] = StatusMessage(level: .warning, text: "확인 창을 연 뒤 목록이 바뀌어 정리를 실행하지 않았습니다. 다시 선택해 주세요.")
            return
        }
        let known = Set(scan.candidates.map(\.id))
        let candidates = action.candidates
        guard !candidates.isEmpty, candidates.allSatisfy({ known.contains($0.id) }) else {
            messages[volume.id] = StatusMessage(level: .warning, text: "확인 창의 항목이 현재 목록과 달라 정리를 실행하지 않았습니다. 다시 선택해 주세요.")
            return
        }
        let flag = CancellationFlag()
        cancelFlag = flag
        phase = .cleaning
        busyVolumeID = volume.id
        cleanupProgress = CleanupProgress(done: 0, total: candidates.count)
        failures[volume.id] = nil
        let includeAppleDouble = action.includeAppleDouble
        Task.detached(priority: .userInitiated) {
            let deleter = SafeDeleter(volume: volume, scan: scan, includeAppleDouble: includeAppleDouble, cancelFlag: flag) { done, total in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.phase == .cleaning else { return }
                    self.cleanupProgress = CleanupProgress(done: done, total: total)
                }
            }
            let report = deleter.run(candidates: candidates)
            await MainActor.run { self.finishCleanup(volume, candidates: candidates, report: report, thenEject: thenEject) }
        }
    }

    private func finishCleanup(_ volume: ExternalVolume, candidates: [USBCleanupCandidate], report: CleanupReport, thenEject: Bool) {
        let failedPaths = Set(report.failures.map(\.relativePath))
        let attempted = candidates.prefix(report.deletedCount + report.failures.count)
        let deletedIDs = Set(attempted.filter { !failedPaths.contains($0.relativePath) }.map(\.id))
        if let scan = scanResults[volume.id] {
            scanResults[volume.id] = scan.removing(candidateIDs: deletedIDs)
        }
        var selected = selectedCandidateIDs[volume.id] ?? []
        selected.subtract(deletedIDs)
        selectedCandidateIDs[volume.id] = selected
        failures[volume.id] = report.failures

        let deletedText = "\(report.deletedCount)개 파일(\(ByteFormat.string(report.deletedBytes)))"
        let outcome: OperationSummary.Outcome
        let message: StatusMessage
        if let reason = report.abortedReason {
            outcome = .failed
            message = StatusMessage(level: .error, text: reason)
        } else if report.cancelled {
            outcome = .cancelled
            message = StatusMessage(level: .warning, text: "취소되어 \(deletedText)만 정리했습니다. 실패 \(report.failures.count)개.")
        } else if report.failures.isEmpty {
            outcome = .success
            message = StatusMessage(level: .success, text: "\(deletedText)을 정리했습니다.")
        } else {
            outcome = .partial
            message = StatusMessage(level: .warning, text: "\(deletedText)을 정리했고 \(report.failures.count)개는 실패했습니다. 실패 항목과 사유는 아래 목록에 있습니다.")
        }
        messages[volume.id] = message
        addSummary(OperationSummary(
            date: Date(), kind: .cleanup, outcome: outcome, volumeName: volume.name,
            count: report.deletedCount, bytes: report.deletedBytes,
            detail: report.abortedReason ?? (report.failures.isEmpty ? "실패 없음" : "실패 \(report.failures.count)개")
        ))
        endOperation()

        if thenEject {
            let scan = scanResults[volume.id]
            if report.isCompleteSuccess, let scan, scan.isComplete {
                performEject(volume, chained: true)
            } else {
                let current = messages[volume.id]?.text ?? ""
                let why = (scan?.isComplete ?? true) ? "정리가 완전히 끝나지 않아" : "확인이 볼륨 전체를 다루지 못해"
                messages[volume.id] = StatusMessage(level: .warning, text: current + " \(why) 추출하지 않았습니다. 내용을 확인한 뒤 '추출' 버튼으로 직접 추출해 주세요.")
            }
        }
    }

    // MARK: - 추출

    /// 일반 추출. 강제 추출은 하지 않으며 실패 시 시스템 오류를 그대로 보여 준다.
    func performEject(_ volume: ExternalVolume, chained: Bool = false, onFailure: (() -> Void)? = nil) {
        guard phase == .idle else { return }
        phase = .ejecting
        busyVolumeID = volume.id
        Task.detached(priority: .userInitiated) {
            do {
                try Ejector.eject(volume)
                await MainActor.run { self.finishEject(volume, error: nil, chained: chained, onFailure: onFailure) }
            } catch {
                await MainActor.run { self.finishEject(volume, error: error, chained: chained, onFailure: onFailure) }
            }
        }
    }

    private func finishEject(_ volume: ExternalVolume, error: Error?, chained: Bool, onFailure: (() -> Void)?) {
        endOperation()
        if let error {
            let text = error.localizedDescription
            messages[volume.id] = StatusMessage(level: .error, text: text)
            alert = AlertInfo(title: "'\(volume.name)' 추출 실패", message: text + "\n\n열려 있는 파일이나 창을 닫은 뒤 다시 시도해 주세요. 강제 추출은 지원하지 않습니다.")
            addSummary(OperationSummary(date: Date(), kind: .eject, outcome: .failed, volumeName: volume.name, count: 0, bytes: 0, detail: text))
            onFailure?()
        } else {
            addSummary(OperationSummary(date: Date(), kind: .eject, outcome: .success, volumeName: volume.name, count: 0, bytes: 0,
                                        detail: chained ? "정리 후 추출" : "추출"))
        }
        refreshVolumes()
    }

    // MARK: - 최근 작업

    private func addSummary(_ summary: OperationSummary) {
        recentOperations.insert(summary, at: 0)
        if recentOperations.count > AppState.recentLimit {
            recentOperations.removeLast(recentOperations.count - AppState.recentLimit)
        }
        if let data = try? JSONEncoder().encode(recentOperations) {
            UserDefaults.standard.set(data, forKey: AppState.recentKey)
        }
    }

    func clearRecent() {
        recentOperations = []
        UserDefaults.standard.removeObject(forKey: AppState.recentKey)
    }

    private static func loadRecent() -> [OperationSummary] {
        guard let data = UserDefaults.standard.data(forKey: recentKey),
              let list = try? JSONDecoder().decode([OperationSummary].self, from: data) else { return [] }
        return list
    }

    // MARK: - Finder

    func revealInFinder(_ candidate: USBCleanupCandidate, volume: ExternalVolume) {
        var url = volume.mountPoint
        for component in candidate.components { url.appendPathComponent(component) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
