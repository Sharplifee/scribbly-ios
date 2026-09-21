import SwiftUI

/// The filter + sort row every list carries (Library · Collections · Groups).
struct FilterSortRow: View {
    let filters: [String]
    @Binding var filter: String
    let sorts: [String]
    @Binding var sort: String

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filters, id: \.self) { f in
                        Button { filter = f } label: {
                            Text(f).font(.system(size: 12, weight: .semibold))
                                .foregroundColor(filter == f ? .white : P.textSec)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(filter == f ? P.accent.opacity(0.18) : P.surface).clipShape(Capsule())
                                .overlay(Capsule().stroke(filter == f ? P.accent.opacity(0.4) : P.border))
                        }
                    }
                }
                .padding(.leading, 16)
            }
            Menu {
                ForEach(sorts, id: \.self) { s in Button(s) { sort = s } }
            } label: {
                Text("⇅ \(sort)").font(.system(size: 12, weight: .semibold)).foregroundColor(P.accent).lineLimit(1).fixedSize()
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(P.surface).clipShape(Capsule()).overlay(Capsule().stroke(P.border))
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 6)
    }
}

/// Section header for grouped search results: "Chase Hughes  › full channel · 4".
struct GroupHeader: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            Spacer()
            Text(detail).font(.system(size: 12)).foregroundColor(P.textDim)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
    }
}

/// Left rule that nests results under their header.
struct Nested<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(P.accent.opacity(0.35)).frame(width: 2).padding(.vertical, 4)
            VStack(spacing: 0) { content }
        }
        .padding(.leading, 20)
    }
}

/// Plain search field used at the top of every list.
struct ListSearch: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(P.textDim)
            TextField(placeholder, text: $text)
                .foregroundColor(.white).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(P.textDim) }
            }
        }
        .padding(12).background(P.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(P.border))
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
    }
}
