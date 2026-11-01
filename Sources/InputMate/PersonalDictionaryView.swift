import SwiftUI

// 개인 변환 사전: 직접 추가한 단어와 성공한 수동 변환('') 결과를 추가·수정·삭제하는 설정 항목. 목록은 이 Mac에만 저장된다.
@MainActor
struct PersonalDictionaryView: View {
    @ObservedObject var store: PersonalDictionaryStore
    @State private var selection: String?
    @State private var sourceDraft = ""
    @State private var replacementDraft = ""
    @State private var notice: (text: String, isError: Bool)?
    @State private var deleteTarget: String?

    init(store: PersonalDictionaryStore = .shared) {
        self.store = store
    }

    private var sortedSources: [String] {
        store.entries.keys.sorted()
    }

    // 목록에 실제로 있는 선택 항목만 수정·삭제 대상으로 본다.
    private var selectedSource: String? {
        selection.flatMap { store.entries[$0] != nil ? $0 : nil }
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { selection }, set: { select($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("개인 변환 사전")
                .font(.headline)
            Text("직접 추가한 단어와 '' 변환으로 자동 저장된 단어가 함께 보입니다. 입력 내용은 이 Mac 밖으로 보내지 않으며, 바로 앞의 한 단어가 '원래 단어'와 똑같을 때만(대소문자 구분) 저장된 표현을 먼저 적용합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.entries.isEmpty {
                Text("아직 저장된 단어가 없습니다. 아래에 첫 단어를 입력하고 '추가'를 누르세요.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(sortedSources, id: \.self, selection: selectionBinding) { source in
                    HStack {
                        Text(source)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Text(store.entries[source] ?? "")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 160)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(selectedSource == nil ? "새 단어 추가" : "선택한 단어 수정")
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text("원래 단어")
                    TextField("예: 한병기", text: $sourceDraft)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("바꿀 표현")
                    TextField("예: Han byoungki", text: $replacementDraft)
                        .textFieldStyle(.roundedBorder)
                }
                if let notice {
                    Text(notice.text)
                        .font(.caption)
                        .foregroundStyle(notice.isError ? Color.red : Color.secondary)
                }
                HStack {
                    Button("추가", action: add)
                    Button("수정 저장", action: update)
                        .disabled(selectedSource == nil)
                    Button("삭제…", role: .destructive) { requestDelete() }
                        .disabled(selectedSource == nil)
                    Button("새로 입력") { select(nil) }
                        .disabled(selection == nil && sourceDraft.isEmpty && replacementDraft.isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("이 단어를 삭제할까요?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("삭제", role: .destructive) { confirmDelete() }
            Button("취소", role: .cancel) { deleteTarget = nil }
        } message: {
            if let target = deleteTarget {
                Text("'\(target) → \(store.entries[target] ?? "")' 항목이 이 Mac의 사전에서 지워집니다.")
            }
        }
    }

    // 선택을 바꾸면 입력칸을 그 항목 값으로 채운다(nil이면 비운다). 첫 클릭과 추가·수정·삭제 직후 모두 이 경로를 쓴다.
    private func select(_ source: String?, notice: (text: String, isError: Bool)? = nil) {
        selection = source
        sourceDraft = source ?? ""
        replacementDraft = source.flatMap { store.entries[$0] } ?? ""
        self.notice = notice
    }

    private func add() {
        guard let problem = validationProblem() else {
            let key = trimmed(sourceDraft)
            switch store.save(original: nil, source: key, replacement: replacementDraft) {
            case .saved:
                select(key, notice: ("'\(key)' 단어를 추가했습니다.", false))
            case .duplicate:
                select(key, notice: ("'\(key)'은(는) 이미 사전에 있어 그대로 두었습니다. 바꾸려면 값을 고친 뒤 '수정 저장'을 누르세요.", true))
            case .unchanged:
                notice = ("변경된 내용이 없습니다.", false)
            case .unavailable:
                notice = (Self.unavailableText, true)
            case .invalid:
                notice = (validationProblem() ?? "입력 내용을 확인하세요.", true)
            }
            return
        }
        notice = (problem, true)
    }

    private func update() {
        guard let original = selectedSource else { return }
        if let problem = validationProblem() {
            notice = (problem, true)
            return
        }
        let key = trimmed(sourceDraft)
        switch store.save(original: original, source: key, replacement: replacementDraft) {
        case .saved:
            select(key, notice: ("'\(key)' 항목을 수정했습니다.", false))
        case .duplicate:
            notice = ("'\(key)'은(는) 이미 다른 항목으로 있어 저장하지 않았습니다. 원래 단어를 바꾸거나 그 항목을 선택해 수정하세요.", true)
        case .unchanged:
            notice = ("변경된 내용이 없습니다.", false)
        case .unavailable:
            notice = (Self.unavailableText, true)
        case .invalid:
            notice = ("입력 내용을 확인하세요.", true)
        }
    }

    private func requestDelete() {
        guard let source = selectedSource else { return }
        guard store.canEdit else {
            notice = (Self.unavailableText, true)
            return
        }
        deleteTarget = source
    }

    private func confirmDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        store.remove(source: target)
        select(nil, notice: ("'\(target)' 항목을 삭제했습니다.", false))
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 입력칸 검사. 문제가 없으면 nil, 있으면 입력칸 근처에 보여줄 쉬운 안내문을 돌려준다.
    private func validationProblem() -> String? {
        let key = trimmed(sourceDraft)
        if key.isEmpty { return "원래 단어를 입력하세요." }
        if trimmed(replacementDraft).isEmpty { return "바꿀 표현을 입력하세요." }
        if key.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || key.utf16.count > 32 {
            return "원래 단어는 띄어쓰기 없는 한 단어(32자 이하)로 입력하세요."
        }
        return nil
    }

    private static let unavailableText = "기존 사전 데이터를 확인하지 못해 지금은 저장할 수 없습니다. HTT를 다시 실행한 뒤 시도하세요."
}
