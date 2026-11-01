import Combine
import Foundation

// 성공한 수동 변환('')의 원문 → 결과 쌍을 이 Mac의 UserDefaults에만 저장한다. 로그·분석·클라우드 동기화는 쓰지 않는다.
// 키는 대소문자·철자를 그대로 비교하며, 값에는 공백이 들어갈 수 있다(예: 인명 표기).
@MainActor
public final class PersonalDictionaryStore: ObservableObject {
    public static let shared = PersonalDictionaryStore()

    private static let defaultsKey = "InputMate.personalDictionary"
    private static let originsKey = "InputMate.personalDictionaryOrigins.v1"
    private static let seedKey = "InputMate.personalDictionarySeed.v1"

    public enum EntryOrigin: String, Codable, Sendable {
        case manual
        case automatic
        case unknown
    }

    @Published public private(set) var entries: [String: String]
    @Published public private(set) var origins: [String: EntryOrigin]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 없거나 손상된 데이터는 빈 사전으로 시작하며 저장된 값을 지우지 않는다. 문자열 쌍만 읽는다.
        var loaded: [String: String] = [:]
        if let stored = defaults.dictionary(forKey: Self.defaultsKey) {
            for (key, value) in stored {
                if let text = value as? String, Self.isValid(source: key, replacement: text) {
                    loaded[key] = text
                }
            }
        }

        // 출처 메타데이터 읽기: 기존 항목에 실제로 존재하는 키만 유지하며, 없는 항목은 unknown으로 취급한다.
        var loadedOrigins: [String: EntryOrigin] = [:]
        if let storedOrigins = defaults.dictionary(forKey: Self.originsKey) {
            for (key, rawVal) in storedOrigins {
                guard loaded[key] != nil else { continue }
                if let rawStr = rawVal as? String, let origin = EntryOrigin(rawValue: rawStr) {
                    loadedOrigins[key] = origin
                }
            }
        }

        // 마이그레이션 실패 시에는 seed나 기본 항목으로 기존 사전을 덮어쓰거나 seed 마커를 쓰지 않는다.
        if !InputMateMigration.migrationFailed, !defaults.bool(forKey: Self.seedKey) {
            if loaded["한병기"] == nil || loaded["한병기"] == "Han Byeonggi" {
                loaded["한병기"] = "Han byoungki"
                loadedOrigins["한병기"] = .unknown
                defaults.set(loaded, forKey: Self.defaultsKey)
                var rawOrigins: [String: String] = [:]
                for (k, v) in loadedOrigins { rawOrigins[k] = v.rawValue }
                defaults.set(rawOrigins, forKey: Self.originsKey)
            }
            defaults.set(true, forKey: Self.seedKey)
        }
        entries = loaded
        origins = loadedOrigins
    }

    public func origin(for source: String) -> EntryOrigin {
        guard entries[source] != nil else { return .unknown }
        return origins[source] ?? .unknown
    }

    public func replacement(for source: String) -> String? {
        entries[source]
    }

    // 새 쌍만 추가한다. 이미 있는 항목(학습·사용자 수정)은 덮어쓰지 않으며, 실제로 추가했을 때만 true.
    // 성공한 자동 학습 시 origin은 .automatic으로 기록된다.
    @discardableResult
    public func remember(source: String, replacement: String) -> Bool {
        guard canEdit else { return false }
        let value = Self.cleaned(replacement)
        guard Self.isValid(source: source, replacement: value), entries[source] == nil else { return false }
        entries[source] = value
        origins[source] = .automatic
        persist()
        return true
    }

    // 사용자가 직접 지정·수정한 값. 기존 항목은 덮어쓴다. origin은 .manual로 승격된다.
    public func set(source: String, replacement: String) {
        guard canEdit else { return }
        let value = Self.cleaned(replacement)
        guard Self.isValid(source: source, replacement: value) else { return }
        guard entries[source] != value || origins[source] != .manual else { return }
        entries[source] = value
        origins[source] = .manual
        persist()
    }

    public enum SaveResult {
        case saved, unchanged, invalid, duplicate, unavailable
    }

    // 사용자가 사전 화면에서 직접 추가·수정한다. original이 nil이면 새 항목, 아니면 그 항목을 수정(원래 단어 변경 포함)한다.
    // 검사를 모두 통과한 뒤에만 한 번에 바꾸므로 잘못된 입력·중복이면 기존 항목은 그대로다. 다른 항목은 덮어쓰지 않는다.
    // 저장 시에는 무조건 수동 지정(.manual)으로 승격/기록되며, 원래 키가 바뀌면 이전 메타데이터는 정리된다.
    public func save(original: String?, source: String, replacement: String) -> SaveResult {
        let key = Self.cleaned(source)
        let value = Self.cleaned(replacement)
        guard Self.isValid(source: key, replacement: value), Self.isSingleWord(key) else { return .invalid }
        guard !InputMateMigration.migrationFailed else { return .unavailable }
        if key != original, entries[key] != nil { return .duplicate }
        var updatedEntries = entries
        var updatedOrigins = origins
        if let original, original != key {
            updatedEntries[original] = nil
            updatedOrigins[original] = nil
        }
        updatedEntries[key] = value
        updatedOrigins[key] = .manual
        guard updatedEntries != entries || updatedOrigins != origins else { return .unchanged }
        entries = updatedEntries
        origins = updatedOrigins
        persist()
        return .saved
    }

    // 자동 학습되었거나 기존(미확인) 단어를 사용자가 명시적으로 '직접 지정한 단어'로 승격한다.
    @discardableResult
    public func markAsManual(source: String) -> Bool {
        guard canEdit, entries[source] != nil, origins[source] != .manual else { return false }
        origins[source] = .manual
        persist()
        return true
    }

    // 이전 데이터 확인에 실패한 동안에는 저장되지 않으므로 화면에서 추가·수정·삭제를 막는 데 쓴다.
    public var canEdit: Bool { !InputMateMigration.migrationFailed }

    public func remove(source: String) {
        guard canEdit else { return }
        guard entries[source] != nil else { return }
        entries[source] = nil
        origins[source] = nil
        persist()
    }

    // 현재 값이 replacement와 같을 때만 지운다. 되돌리기로 방금 학습한 항목만 취소하는 용도다.
    // 사용자가 직접 지정·고정한 항목(.manual)은 stale undo로 지워지지 않도록 보호한다.
    public func removeIfMatching(source: String, replacement: String) {
        guard entries[source] == replacement else { return }
        guard origin(for: source) != .manual else { return }
        remove(source: source)
    }

    private func persist() {
        guard !InputMateMigration.migrationFailed else { return }
        defaults.set(entries, forKey: Self.defaultsKey)
        var rawOrigins: [String: String] = [:]
        for (k, v) in origins where entries[k] != nil {
            rawOrigins[k] = v.rawValue
        }
        defaults.set(rawOrigins, forKey: Self.originsKey)
    }

    private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 변환은 커서 바로 앞의 한 단어(공백 없음, 32 UTF-16 단위 이하)에만 적용되므로 그 밖의 원래 단어는 받지 않는다.
    private static func isSingleWord(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil && text.utf16.count <= 32
    }

    private static func isValid(source: String, replacement: String) -> Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !replacement.isEmpty
    }
}
