import Combine
import Foundation

// 성공한 수동 변환('')의 원문 → 결과 쌍을 이 Mac의 UserDefaults에만 저장한다. 로그·분석·클라우드 동기화는 쓰지 않는다.
// 키는 대소문자·철자를 그대로 비교하며, 값에는 공백이 들어갈 수 있다(예: 인명 표기).
@MainActor
public final class PersonalDictionaryStore: ObservableObject {
    public static let shared = PersonalDictionaryStore()

    private static let defaultsKey = "InputMate.personalDictionary"
    private static let seedKey = "InputMate.personalDictionarySeed.v1"

    @Published public private(set) var entries: [String: String]
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
        // 마이그레이션 실패 시에는 seed나 기본 항목으로 기존 사전을 덮어쓰거나 seed 마커를 쓰지 않는다.
        if !InputMateMigration.migrationFailed, !defaults.bool(forKey: Self.seedKey) {
            if loaded["한병기"] == nil || loaded["한병기"] == "Han Byeonggi" {
                loaded["한병기"] = "Han byoungki"
                defaults.set(loaded, forKey: Self.defaultsKey)
            }
            defaults.set(true, forKey: Self.seedKey)
        }
        entries = loaded
    }

    public func replacement(for source: String) -> String? {
        entries[source]
    }

    // 새 쌍만 추가한다. 이미 있는 항목(학습·사용자 수정)은 덮어쓰지 않으며, 실제로 추가했을 때만 true.
    @discardableResult
    public func remember(source: String, replacement: String) -> Bool {
        let value = Self.cleaned(replacement)
        guard Self.isValid(source: source, replacement: value), entries[source] == nil else { return false }
        entries[source] = value
        persist()
        return true
    }

    // 사용자가 직접 지정·수정한 값. 기존 항목은 덮어쓴다.
    public func set(source: String, replacement: String) {
        let value = Self.cleaned(replacement)
        guard Self.isValid(source: source, replacement: value), entries[source] != value else { return }
        entries[source] = value
        persist()
    }

    public enum SaveResult {
        case saved, unchanged, invalid, duplicate, unavailable
    }

    // 사용자가 사전 화면에서 직접 추가·수정한다. original이 nil이면 새 항목, 아니면 그 항목을 수정(원래 단어 변경 포함)한다.
    // 검사를 모두 통과한 뒤에만 한 번에 바꾸므로 잘못된 입력·중복이면 기존 항목은 그대로다. 다른 항목은 덮어쓰지 않는다.
    public func save(original: String?, source: String, replacement: String) -> SaveResult {
        let key = Self.cleaned(source)
        let value = Self.cleaned(replacement)
        guard Self.isValid(source: key, replacement: value), Self.isSingleWord(key) else { return .invalid }
        guard !InputMateMigration.migrationFailed else { return .unavailable }
        if key != original, entries[key] != nil { return .duplicate }
        var updated = entries
        if let original, original != key { updated[original] = nil }
        updated[key] = value
        guard updated != entries else { return .unchanged }
        entries = updated
        persist()
        return .saved
    }

    // 이전 데이터 확인에 실패한 동안에는 저장되지 않으므로 화면에서 추가·수정·삭제를 막는 데 쓴다.
    public var canEdit: Bool { !InputMateMigration.migrationFailed }

    public func remove(source: String) {
        guard entries[source] != nil else { return }
        entries[source] = nil
        persist()
    }

    // 현재 값이 replacement와 같을 때만 지운다. 되돌리기로 방금 학습한 항목만 취소하는 용도다.
    public func removeIfMatching(source: String, replacement: String) {
        guard entries[source] == replacement else { return }
        remove(source: source)
    }

    private func persist() {
        guard !InputMateMigration.migrationFailed else { return }
        defaults.set(entries, forKey: Self.defaultsKey)
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
