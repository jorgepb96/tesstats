import SwiftUI

/// Drag-to-reorder / show-hide editor shared by every section.
///
/// Reachable from the section it edits (toolbar ▦ button) rather than buried in Settings, so
/// rearranging a screen happens where the user is already looking at it.
struct SectionLayoutEditor<Block: SectionBlock>: View {
    let section: SectionID
    let blockType: Block.Type
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SectionLayoutState()

    private var layout: SectionLayoutState { draft }
    private var ordered: [Block] { SectionLayout.resolved(Block.self, layout: layout) }
    private var hidden: Set<String> { Set(layout.hidden) }
    private var shownBlocks: [Block] { ordered.filter { !hidden.contains($0.rawValue) } }
    private var hiddenBlocks: [Block] { ordered.filter { hidden.contains($0.rawValue) } }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background.ignoresSafeArea()
                List {
                    Section {
                        if shownBlocks.isEmpty {
                            Text(L("Every block is hidden. Add one back below."))
                                .font(.subheadline).foregroundStyle(Brand.textSecondary)
                        }
                        ForEach(shownBlocks) { block in
                            row(block, isHidden: false)
                        }
                        .onMove(perform: move)
                    } header: {
                        Text(L("Shown"))
                    } footer: {
                        Text(L("Drag the handle to reorder. Blocks still only appear when they have data."))
                    }

                    if !hiddenBlocks.isEmpty {
                        Section(L("Hidden")) {
                            ForEach(hiddenBlocks) { block in
                                row(block, isHidden: true)
                            }
                        }
                    }
                }
                .alwaysReorderable()
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(L("Arrange \(section.title)"))
            .toolbarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Reset")) { apply(SectionLayoutState()) }
                        .disabled(layout.isDefault)
                        .accessibilityIdentifier("layout-reset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("layout-done")
                }
            }
        }
        .tint(Brand.action)
        .onAppear { draft = env.settings.config.layout(for: section) }
    }

    private func row(_ block: Block, isHidden: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: block.icon)
                .foregroundStyle(isHidden ? Brand.textTertiary : Brand.crimson)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title)
                    .foregroundStyle(isHidden ? Brand.textSecondary : Brand.textPrimary)
                Text(block.blurb)
                    .font(.caption).foregroundStyle(Brand.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if !isHidden, let index = shownBlocks.firstIndex(of: block) {
                VStack(spacing: 0) {
                    Button { move(block, by: -1) } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 28, height: 22)
                    }
                    .disabled(index == shownBlocks.startIndex)
                    .accessibilityLabel(L("Move up"))
                    .accessibilityIdentifier("layout-up-\(block.rawValue)")
                    Button { move(block, by: 1) } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 28, height: 22)
                    }
                    .disabled(index == shownBlocks.index(before: shownBlocks.endIndex))
                    .accessibilityLabel(L("Move down"))
                    .accessibilityIdentifier("layout-down-\(block.rawValue)")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Brand.textTertiary)
            }
            Button {
                toggle(block)
            } label: {
                Image(systemName: isHidden ? "plus.circle.fill" : "eye.slash")
                    .font(.body)
                    .foregroundStyle(isHidden ? Brand.driving : Brand.textTertiary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isHidden ? L("Show") : L("Hide"))
            .accessibilityIdentifier("layout-visibility-\(block.rawValue)")
        }
    }

    private func move(from: IndexSet, to: Int) {
        // `shownBlocks` is a filtered view of the full order, so the move is applied to the
        // visible list and the hidden blocks are appended back afterwards.
        var shown = shownBlocks
        shown.move(fromOffsets: from, toOffset: to)
        apply(SectionLayoutState(order: (shown + hiddenBlocks).map(\.rawValue),
                                 hidden: layout.hidden))
    }

    private func toggle(_ block: Block) {
        var hiddenList = layout.hidden
        if let idx = hiddenList.firstIndex(of: block.rawValue) {
            hiddenList.remove(at: idx)
        } else {
            hiddenList.append(block.rawValue)
        }
        let order = layout.order.isEmpty ? ordered.map(\.rawValue) : layout.order
        apply(SectionLayoutState(order: order, hidden: hiddenList))
    }

    private func move(_ block: Block, by offset: Int) {
        var shown = shownBlocks
        guard let source = shown.firstIndex(of: block) else { return }
        let destination = source + offset
        guard shown.indices.contains(destination) else { return }
        shown.swapAt(source, destination)
        apply(SectionLayoutState(order: (shown + hiddenBlocks).map(\.rawValue),
                                 hidden: layout.hidden))
    }

    private func apply(_ new: SectionLayoutState) {
        draft = new
        env.settings.config.setLayout(new, for: section)
        env.settings.save()
    }
}

private extension View {
    /// Show the drag handles permanently so reordering needs no Edit button. macOS has no
    /// `editMode`; its lists reorder from `.onMove` directly.
    @ViewBuilder
    func alwaysReorderable() -> some View {
        #if os(iOS)
        self.environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }
}

/// Toolbar button that opens the arrange sheet for a section.
struct ArrangeSectionButton<Block: SectionBlock>: View {
    let section: SectionID
    let blockType: Block.Type
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "square.grid.2x2")
        }
        .tint(Brand.action)
        .accessibilityLabel(L("Arrange section"))
        .accessibilityIdentifier("arrange-section-\(section.rawValue)")
        .sheet(isPresented: $presented) {
            SectionLayoutEditor(section: section, blockType: blockType)
        }
    }
}
