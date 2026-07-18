import GoiCore
import SwiftUI

/// Compact facets shared by the local library and the community catalog.
/// The caller owns the complete item array; changing a facet never performs a
/// network request.
struct DictionaryFilterBar: View {
    @Binding var filter: DictionaryFilter
    let metadata: [DictionaryMetadata]
    let resultCount: Int
    let totalCount: Int

    private var languageOptions: [DictionaryMetadata.Language] {
        DictionaryMetadata.Language.allCases.filter { language in
            metadata.contains { $0.languages.contains(language) }
        }
    }

    private var functionOptions: [DictionaryMetadata.Function] {
        DictionaryMetadata.Function.allCases.filter { function in
            metadata.contains { $0.function == function }
        }
    }

    private var vendorOptions: [String] {
        Array(Set(metadata.map(\.vendor))).sorted { left, right in
            if left == "其他" { return false }
            if right == "其他" { return true }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("按词典名称搜索", text: $filter.query)
                    .textFieldStyle(.plain)
                Text(filter.isActive ? "\(resultCount) / \(totalCount) 本" : "\(totalCount) 本")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                if filter.isActive {
                    Button("清除") { filter.clear() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))

            if !languageOptions.isEmpty {
                facetScroller(label: "语种") {
                    facetButton("全部", selected: filter.language == nil) { filter.language = nil }
                    ForEach(languageOptions, id: \.self) { language in
                        facetButton(language.label, selected: filter.language == language) {
                            filter.language = filter.language == language ? nil : language
                        }
                    }
                }
            }

            if !functionOptions.isEmpty {
                facetScroller(label: "功能") {
                    facetButton("全部", selected: filter.function == nil) { filter.function = nil }
                    ForEach(functionOptions, id: \.self) { function in
                        facetButton(function.label, selected: filter.function == function) {
                            filter.function = filter.function == function ? nil : function
                        }
                    }
                }
            }

            if !vendorOptions.isEmpty {
                HStack(spacing: 8) {
                    Text("出版方")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 42, alignment: .leading)
                    if vendorOptions.count <= 7 {
                        facetButton("全部", selected: filter.vendor == nil) { filter.vendor = nil }
                        ForEach(vendorOptions, id: \.self) { vendor in
                            facetButton(vendor, selected: filter.vendor == vendor) {
                                filter.vendor = filter.vendor == vendor ? nil : vendor
                            }
                        }
                    } else {
                        Menu(filter.vendor ?? "全部出版方") {
                            Button("全部出版方") { filter.vendor = nil }
                            Divider()
                            ForEach(vendorOptions, id: \.self) { vendor in
                                Button {
                                    filter.vendor = vendor
                                } label: {
                                    if filter.vendor == vendor {
                                        Label(vendor, systemImage: "checkmark")
                                    } else {
                                        Text(vendor)
                                    }
                                }
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func facetScroller<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5, content: content)
            }
        }
    }

    private func facetButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .accentColor : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

struct DictionaryMetadataLine: View {
    let metadata: DictionaryMetadata

    var body: some View {
        HStack(spacing: 5) {
            Text(metadata.languageLabel)
            Text("·")
            Text(metadata.function.label)
            if metadata.vendor != "其他" {
                Text("·")
                Text(metadata.vendor)
            }
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .lineLimit(1)
    }
}
