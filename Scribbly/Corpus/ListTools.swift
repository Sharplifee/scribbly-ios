import SwiftUI

/// The filter chip row every list carries (Library · Collections · Groups).
/// Its sort menu lives on the search row above (ListSearch), so the chips
/// have the whole width to themselves.
struct FilterSortRow: View {
    let filters: [String]
    @Binding var filter: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filters, id: \.self) { f in
                    Button { filter = f } label: {
                        Text(f).font(.geist(size: 13, weight: filter == f ? .semibold : .regular))
                            .foregroundColor(filter == f ? .black : Color(hex: 0xD9DCDD))
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(filter == f ? P.ink : Color.clear).clipShape(Capsule())
                            .overlay(Capsule().stroke(filter == f ? Color.clear : Color(hex: 0x2E3236)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
    }
}

/// Compact sort dropdown ("A–Z ⌄") that sits at the trailing end of the search row.
struct SortMenu: View {
    let sorts: [String]
    @Binding var sort: String
    var height: CGFloat = 44

    var body: some View {
        Menu {
            ForEach(sorts, id: \.self) { s in
                Button { sort = s } label: {
                    if s == sort { Label(s, systemImage: "checkmark") } else { Text(s) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                Text(sort).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.geist(size: 13)).foregroundColor(Color(hex: 0xD9DCDD))
            .padding(.horizontal, 12).frame(height: height)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sinkyGlass(RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
        }
        .accessibilityLabel("Sort: \(sort)")
    }
}

/// Section header for grouped search results: "Chase Hughes  › full channel · 4".
struct GroupHeader: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.geist(size: 15, weight: .semibold)).tracking(-0.3).foregroundColor(P.ink)
            Spacer()
            Text(detail).monoLabel(9.5, color: P.textDim)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
    }
}

/// Left rule that nests results under their header.
struct Nested<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(LinearGradient(colors: [P.accent, P.tan, P.teal], startPoint: .top, endPoint: .bottom))
                .frame(width: 1.5).padding(.vertical, 4)
            VStack(spacing: 0) { content }
        }
        .padding(.leading, 20)
    }
}

/// Plain search field used at the top of every list, with the list's sort
/// menu (when it has one) trailing on the same row.
struct ListSearch: View {
    let placeholder: String
    @Binding var text: String
    var sorts: [String] = []
    var sort: Binding<String>? = nil

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(P.textDim)
                TextField(placeholder, text: $text)
                    .foregroundColor(P.ink).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(P.textDim) }
                }
            }
            .font(.geist(size: 15))
            .padding(.horizontal, 12).frame(height: 44)
            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(P.edge))
            if let sort, !sorts.isEmpty {
                SortMenu(sorts: sorts, sort: sort)
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
    }
}
