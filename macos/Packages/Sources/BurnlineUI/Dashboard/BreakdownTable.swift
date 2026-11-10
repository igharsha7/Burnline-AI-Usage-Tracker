//
//  BreakdownTable.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import SwiftUI

/// The breakdown table, in whichever shape its columns describe: ranked
/// models, or time buckets with providers as columns. The day ledger is the
/// same table over ten days. Every numeric column sorts. A ranked row opens
/// in place to show its token mix and rates; a bucket narrows the
/// dashboard to it. A long ranking shows its top rows until asked for all;
/// a page that is only this table shows it a screenful at a time instead,
/// so a long history never builds every row at once.
struct BreakdownTable: View {
    let columns: [BreakdownColumn]
    let lines: [BreakdownLine]
    var ranked = false
    var search = ""
    let drill: (BreakdownLine.Drill) -> Void
    /// Whether a row's drill-down is already applied, and how to lift it,
    /// so an opened row offers the way back as well as the way in.
    var applied: (BreakdownLine.Drill) -> Bool = { _ in false }
    var undo: (BreakdownLine.Drill) -> Void = { _ in }
    /// Rows a page holds, where the table is paged rather than cut short.
    var pageSize: Int?
    /// Told where the rows begin in the page, so a paged table's page can
    /// be sized to the room below them.
    var rowsTop: ((CGFloat) -> Void)?

    @State private var sort: (column: String, ascending: Bool)?
    @State private var opened: String?
    @State private var showingAll = false
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let numberWidth: CGFloat = 92
    /// Rows a ranking shows before "Show all".
    static let leading = 8

    /// A paged table shows its current page. Otherwise a ranking is cut
    /// short, only when nothing is being searched for.
    private func cut(_ lines: [BreakdownLine]) -> ArraySlice<BreakdownLine> {
        if let pageSize {
            let start = current(lines.count) * pageSize
            return lines[start..<min(start + pageSize, lines.count)]
        }
        return ranked && search.isEmpty && !showingAll ? lines.prefix(Self.leading) : lines[...]
    }

    private func pages(_ count: Int) -> Int {
        guard let pageSize, pageSize > 0 else { return 1 }
        return max(1, (count + pageSize - 1) / pageSize)
    }

    /// The page on screen, kept inside the pages there are as rows come and go.
    private func current(_ count: Int) -> Int { min(page, pages(count) - 1) }

    private var shown: [BreakdownLine] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? lines : lines.filter { $0.name.localizedCaseInsensitiveContains(query) }
        guard let sort else { return matching.sorted { $0.order < $1.order } }
        return matching.sorted { a, b in
            if sort.column == "name" {
                let order = a.name.localizedStandardCompare(b.name)
                return sort.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            let x = a.values[sort.column] ?? 0, y = b.values[sort.column] ?? 0
            return x == y ? a.order < b.order : sort.ascending ? x < y : x > y
        }
    }

    var body: some View {
        // Filtered and sorted once per redraw, not once per read.
        let shown = shown
        let visible = cut(shown)
        VStack(spacing: 0) {
            header
            // As wide as a row's highlight, so the two share their edges.
            Divider().overlay(Palette.separator.opacity(0.5)).padding(.horizontal, -Row.inset)
            LazyVStack(spacing: 2) {
                // Rows are told apart by space and their hover, not by rules,
                // as the reference has them.
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, line in
                    Row(line: line, rank: ranked ? visible.startIndex + index + 1 : nil, columns: columns, index: index,
                        opened: opened == line.id, open: { toggle(line.id) }, drill: follow,
                        applied: applied, undo: { target in close(); undo(target) })
                }
            }
            .padding(.top, 6)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(ListPage.space)).minY } action: { rowsTop?($0) }
            // A new page replaces the old one whole: the old leaves at once
            // and the new fades up, so two pages never show through each other.
            .id(pageSize == nil ? 0 : current(shown.count))
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .identity))
            if pageSize != nil {
                if pages(shown.count) > 1 { pager(shown.count, visible: visible) }
            } else if visible.count < shown.count || (showingAll && shown.count > Self.leading && search.isEmpty) {
                Button {
                    withAnimation(Motion.standard(reduced: reduceMotion)) { showingAll.toggle() }
                } label: {
                    Label(showingAll ? "Show top \(Self.leading)" : "Show all \(shown.count)",
                          systemImage: showingAll ? "chevron.up" : "chevron.down")
                        .font(.callout).foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10).contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
            if shown.isEmpty {
                Text(search.isEmpty ? "Nothing in this range." : "No rows match “\(search)”.")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }        // A new search starts from its first page.
        .onChange(of: search) { page = 0 }
    }

    /// Where the page is in the whole, and the way to the next and previous.
    private func pager(_ count: Int, visible: ArraySlice<BreakdownLine>) -> some View {
        let current = current(count), last = pages(count) - 1
        return HStack(spacing: 10) {
            Text("\(visible.startIndex + 1)–\(visible.endIndex) of \(count)")
                .monospacedDigit().foregroundStyle(Palette.textSecondary)
            Spacer()
            Button { turn(to: current - 1) } label: {
                Image(systemName: "chevron.left").frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .disabled(current == 0)
            .help("Previous page")
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            Text("Page \(current + 1) of \(last + 1)").monospacedDigit()
            Button { turn(to: current + 1) } label: {
                Image(systemName: "chevron.right").frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .disabled(current == last)
            .help("Next page")
            .keyboardShortcut(.rightArrow, modifiers: [.command])
        }
        .buttonStyle(.pressable)
        .font(.callout)
        .padding(.top, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pages")
    }

    private func turn(to page: Int) {
        opened = nil
        withAnimation(Motion.standard(reduced: reduceMotion)) { self.page = page }
    }

    /// A row followed or lifted closes, since the table under it changes.
    private func follow(_ target: BreakdownLine.Drill) {
        close()
        drill(target)
    }

    private func close() {
        withAnimation(Motion.standard(reduced: reduceMotion)) { opened = nil }
    }

    private func toggle(_ id: String) {
        withAnimation(Motion.standard(reduced: reduceMotion)) { opened = opened == id ? nil : id }
    }

    private var header: some View {
        HStack(spacing: 0) {
            if ranked {
                Text("#").frame(width: Row.rankWidth, alignment: .leading)
            }
            ForEach(columns) { column in
                Button {
                    toggleSort(column.id)
                } label: {
                    HStack(spacing: 3) {
                        if column.id != "name" { indicator(column.id) }
                        Text(column.title).lineLimit(1)
                        if column.id == "name" { indicator(column.id) }
                    }
                    .frame(maxWidth: column.id == "name" ? .infinity : Self.numberWidth,
                           alignment: column.id == "name" ? .leading : .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sort by \(column.title.lowercased())")
                .accessibilityLabel(column.title)
                .accessibilityValue(sortValue(column.id))
                .accessibilityHint("Sorts the table")
                .accessibilityAddTraits(sort?.column == column.id ? [.isHeader, .isSelected] : .isHeader)
            }
            // The rows' chevron column, so the titles end where the figures do.
            Color.clear.frame(width: Row.chevronWidth)
        }
        .font(.callout)
        .foregroundStyle(Palette.textSecondary)
        .padding(.vertical, 10)
    }

    private func sortValue(_ column: String) -> String {
        guard let sort, sort.column == column else { return "" }
        return sort.ascending ? "Sorted ascending" : "Sorted descending"
    }

    @ViewBuilder private func indicator(_ column: String) -> some View {
        if let sort, sort.column == column {
            Image(systemName: sort.ascending ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
                .id(sort.ascending)
                .transition(Motion.icon)
        }
    }

    /// Numbers sort largest first on the first click, names A to Z; a third
    /// click returns to the table's own order.
    private func toggleSort(_ column: String) {
        page = 0
        withAnimation(Motion.standard(reduced: reduceMotion)) {
            if let current = sort, current.column == column {
                sort = current.ascending == (column == "name") ? (column, !current.ascending) : nil
            } else {
                sort = (column, column == "name")
            }
        }
    }
}

private struct Row: View {
    let line: BreakdownLine
    let rank: Int?
    let columns: [BreakdownColumn]
    /// Its place on screen, which staggers its underline growing in.
    let index: Int
    let opened: Bool
    let open: () -> Void
    let drill: (BreakdownLine.Drill) -> Void
    let applied: (BreakdownLine.Drill) -> Bool
    let undo: (BreakdownLine.Drill) -> Void

    @State private var hovering = false
    @State private var appeared = false

    /// How far the highlight reaches past the row's content on each side,
    /// so the chevron and the rank sit inside it with room, not on its edge.
    /// The header's rule reaches as far.
    static let inset: CGFloat = 14
    static let chevronWidth: CGFloat = 18
    static let rankWidth: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A ranked row with figures of its own opens; any other row drills.
    private var opens: Bool { line.detail != nil }

    /// The row as one sentence: its name, then each figure with its column.
    private var spoken: String {
        let name = [rank.map { "\($0)." }, line.name].compactMap { $0 }.joined(separator: " ")
        guard line.tracked else { return "\(name), not tracked" }
        let figures = columns.dropFirst().compactMap { column -> String? in
            guard let text = line.texts[column.id], !text.isEmpty else { return nil }
            return "\(column.title) \(text == "—" ? "none" : text)"
        }
        return ([name] + figures).joined(separator: ", ")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(spacing: 0) {
            summary
            if opened, let detail = line.detail {
                // From the name to the chevron: it starts where the name
                // does and ends where the figures do.
                RowDetail(line: line, detail: detail, drill: drill, applied: applied, undo: undo)
                    .padding(.leading, rank == nil ? 0 : Self.rankWidth)
                    .padding(.bottom, 16)
            }
        }
        // Hovered, a tint; opened, the same tint held, with a rim, so the
        // row and its figures read as one piece.
        .background {
            shape.fill(Palette.control.opacity(opened ? 0.5 : hovering ? 0.4 : 0))
                .overlay { shape.strokeBorder(Palette.separator.opacity(opened ? 0.7 : 0), lineWidth: 0.5) }
        }
        // Clipped before the negative padding: clipping after it would cut
        // the highlight back to the content's edges, onto the rank and chevron.
        .clipShape(shape)
        .padding(.horizontal, -Self.inset)
        .onAppear {
            guard !appeared else { return }
            withAnimation(Motion.reveal(index, reduced: reduceMotion)) { appeared = true }
        }
    }

    private var cells: some View {
        HStack(spacing: 0) {
            if let rank {
                Text("\(rank)").monospacedDigit().foregroundStyle(Palette.textSecondary)
                    .frame(width: Self.rankWidth, alignment: .leading)
            }
            name.frame(maxWidth: .infinity, alignment: .leading)
            if line.tracked {
                ForEach(columns.dropFirst()) { column in
                    Text(line.texts[column.id] ?? "")
                        .monospacedDigit()
                        .fontWeight(column.id == "metric" ? .medium : .regular)
                        .foregroundStyle(column.id == "share" || column.id == "other" ? Palette.textSecondary : Palette.textPrimary)
                        .lineLimit(1)
                        .frame(width: BreakdownTable.numberWidth, alignment: .trailing)
                }
            } else {
                // Before tracking began there is no figure, not a zero.
                Text("Not tracked").italic().foregroundStyle(Palette.textSecondary)
            }
            Image(systemName: opens ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
                .rotationEffect(.degrees(opened ? 180 : 0))
                .frame(width: Self.chevronWidth, alignment: .trailing)
                .opacity(opened || (hovering && (opens || line.drill != nil)) ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, Self.inset)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Motion.standard(reduced: reduceMotion)) { hovering = inside }
        }
    }

    @ViewBuilder private var summary: some View {
        let openHelp: String = opened ? "Close" : "Show what makes up " + line.name
        if opens {
            Button(action: open) { cells }
                .buttonStyle(.plain)
                .help(openHelp)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityValue(opened ? Text("Open") : Text(""))
                .accessibilityHint("Shows its token mix and rates")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open() }
        } else if let target = line.drill {
            Button { drill(target) } label: { cells }
                .buttonStyle(.plain)
                .help(Self.help(target, name: line.name))
                // Replacing the element drops the button's own press, so
                // it is given back as the default action.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityHint(Self.help(target, name: line.name))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { drill(target) }
        } else {
            cells
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    /// The row's share as a short rule under its name in the provider's
    /// colour, growing in as the row arrives. Scaled to the whole rather
    /// than the largest row, so it stays a quiet mark, as in the reference;
    /// a row with no share, such as a day, is scaled to the largest row.
    private var underline: some View {
        let fraction = min(1, line.share ?? line.magnitude)
        let shown = line.tracked && fraction > 0 && appeared
        return GeometryReader { geometry in
            Capsule()
                .fill((line.provider.map(Palette.accent) ?? Palette.textSecondary)
                    .opacity(line.provider == nil ? 0.5 : 0.9))
                .frame(width: shown ? max(Self.shareLeast, min(geometry.size.width, Self.shareSpan) * fraction) : 0)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    /// The width a whole share would take, and the stub the least gets.
    static let shareSpan: CGFloat = 420
    static let shareLeast: CGFloat = 8

    @ViewBuilder private var name: some View {
        VStack(alignment: .leading, spacing: 6) {
            if line.ranked {
                HStack(spacing: 8) {
                    if let provider = line.provider {
                        ProviderLogo(provider: provider, size: 14)
                    }
                    // Long names keep both ends, where versions differ.
                    Text(line.name).lineLimit(1).truncationMode(.middle)
                    if line.share == nil {
                        Text("Not a model").font(.caption2).foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Palette.control.opacity(0.7), in: Capsule())
                    }
                }
            } else {
                Text(line.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(line.tracked ? Palette.textPrimary : Palette.textSecondary)
            }
            underline
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 16)
    }

    static func help(_ drill: BreakdownLine.Drill, name: String) -> String {
        switch drill {
        case .model(_, let name): "Show only \(name)"
        case .project, .session: "Open \(name)"
        case .window: "Show \(name)"
        }
    }
}

/// An opened row: its tokens by kind, what share of its input the cache
/// served, what a million of its tokens cost, when it was last used, and
/// the way into it.
private struct RowDetail: View {
    let line: BreakdownLine
    let detail: BreakdownLine.Detail
    let drill: (BreakdownLine.Drill) -> Void
    let applied: (BreakdownLine.Drill) -> Bool
    let undo: (BreakdownLine.Drill) -> Void

    /// How many of its three parts have arrived; they come in turn.
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tokens: TokenCounts { detail.totals.tokens }

    /// Of everything read as input, the share that came from the cache.
    private var hitRate: Double? {
        let read = tokens.input + tokens.cachedInput + tokens.cacheWrite
        return read > 0 ? Double(tokens.cachedInput) / Double(read) : nil
    }

    /// The cost of a million processed tokens, in whole nanodollars.
    private var perMillion: Nanodollars? {
        guard tokens.processed > 0, detail.totals.cost.raw > 0 else { return nil }
        var exact = Decimal(detail.totals.cost.raw) * 1_000_000 / Decimal(tokens.processed)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &exact, 0, .plain)
        return Nanodollars(raw: NSDecimalNumber(decimal: rounded).int64Value)
    }

    var body: some View {
        let counts = TokenKind.allCases.map { $0.count(tokens) }
        VStack(alignment: .leading, spacing: 14) {
            if shown > 0 { mix(counts) }
            if shown > 1 { legend(counts) }
            if shown > 2 { stats }
        }
        .padding(.horizontal, Row.inset)
        .padding(.top, 2)
        .onAppear {
            if reduceMotion { shown = 3 } else { withAnimation(Motion.standard) { shown = 3 } }
        }
    }

    private func mix(_ counts: [Int64]) -> some View {
        GeometryReader { geometry in
            let widths = TokenKind.widths(counts, in: geometry.size.width, gap: 2, least: 3)
            HStack(spacing: 2) {
                ForEach(Array(TokenKind.allCases.enumerated()), id: \.element) { index, kind in
                    if widths[index] > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(kind.color)
                            .frame(width: widths[index])
                            .help("\(kind.name): \(Format.figure(counts[index]))")
                    }
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
        .transition(Motion.unfold(0))
    }

    private func legend(_ counts: [Int64]) -> some View {
        HStack(alignment: .top, spacing: 22) {
            ForEach(Array(TokenKind.allCases.enumerated()), id: \.element) { index, kind in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle().fill(kind.color).frame(width: 6, height: 6)
                        Text(kind.name).foregroundStyle(Palette.textSecondary)
                    }
                    Text(Format.figure(counts[index])).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .transition(Motion.unfold(1))
    }

    private var stats: some View {
        HStack(spacing: 8) {
            if let hitRate { Stat(title: "Cache hit rate", value: Format.share(hitRate)) }
            if let perMillion { Stat(title: "Per million tokens", value: Format.cost(perMillion)) }
            if let lastUsed = detail.lastUsed { Stat(title: "Last used", value: lastUsed) }
            Spacer(minLength: 8)
            if let target = line.drill {
                if applied(target) {
                    DetailAction(title: Self.lift(target), symbol: "arrow.uturn.backward", leading: true) { undo(target) }
                } else {
                    DetailAction(title: Self.action(target), symbol: "arrow.right") { drill(target) }
                        .help(Row.help(target, name: line.name))
                }
            }
        }
        .transition(Motion.unfold(2))
    }
}

extension RowDetail {
    /// Short, since the row above already names what it opens.
    static func action(_ drill: BreakdownLine.Drill) -> String {
        switch drill {
        case .model: "Only this model"
        case .project: "Open project"
        case .session: "Open session"
        case .window: "Show this period"
        }
    }

    static func lift(_ drill: BreakdownLine.Drill) -> String {
        switch drill {
        case .model: "Show all models"
        case .project, .session, .window: "Back"
        }
    }
}

/// An opened row's way in or back: a chip of the stats' height and shape,
/// told apart by its arrow, which leans the way it goes on hover.
private struct DetailAction: View {
    let title: String
    let symbol: String
    var leading = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                if leading { arrow }
                Text(title)
                if !leading { arrow }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: Stat.height)
            .background(hovering ? Palette.control : Palette.surface, in: shape)
            .overlay { shape.strokeBorder(Palette.separator.opacity(hovering ? 1 : 0.7), lineWidth: 0.5) }
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .onHover { inside in
            withAnimation(Motion.standard(reduced: reduceMotion)) { hovering = inside }
        }
    }

    private var arrow: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.textSecondary)
            .offset(x: hovering && !reduceMotion ? (leading ? -2 : 2) : 0)
            .accessibilityHidden(true)
    }
}

private struct Stat: View {
    let title: String
    let value: String

    /// Two lines and their padding, which the action beside them matches.
    static let height: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Palette.textSecondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: Self.height)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
