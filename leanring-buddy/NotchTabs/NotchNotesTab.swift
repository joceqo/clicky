//
//  NotchNotesTab.swift
//  leanring-buddy
//
//  The Notch "Notes" surface: a real local-notes feature backed by NotesStore
//  (JSON in Application Support, persisted across launches). Mirrors the
//  commercial Clicky "Notes"/WikiArticle list+detail shape.
//
//  Two states inside the notch panel:
//    • List   — notes as DSCard rows (title + relative updatedAt, newest first),
//               a "+ New note" action, and a clean empty state.
//    • Detail — a title field + multiline TextEditor that saves back to the
//               store as you type, with Back and Delete affordances.
//
//  Layout fits the ~420-wide notch panel (content area is the panel minus its
//  horizontal padding).
//

import SwiftUI

struct NotchNotesTab: View {
    /// Owned here so notes persist across launches and survive tab switches.
    @StateObject private var store = NotesStore()

    /// The note currently open for editing, if any. nil → show the list.
    @State private var editingNoteID: UUID?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        Group {
            if let editingNoteID, let note = store.notes.first(where: { $0.id == editingNoteID }) {
                NoteDetailView(
                    note: note,
                    store: store,
                    onBack: { self.editingNoteID = nil },
                    onDelete: {
                        store.delete(id: note.id)
                        self.editingNoteID = nil
                    }
                )
                // Re-create the editor when switching between notes so its local
                // draft state tracks the right note.
                .id(note.id)
            } else {
                listView
            }
        }
    }

    // MARK: - List

    private var listView: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text("Notes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button {
                    let note = store.create()
                    editingNoteID = note.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("New note")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New note")
            }

            if store.notes.isEmpty {
                DSCard {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("No notes yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Create a note to jot something down. It stays on this Mac.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.sm) {
                        ForEach(store.notes) { note in
                            noteRow(note)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        Button {
            editingNoteID = note.id
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "note.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(Self.relativeFormatter.localizedString(
                        for: note.updatedAt, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.vertical, DS.Spacing.sm)
            .padding(.horizontal, DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(note.displayTitle)
    }
}

// MARK: - Detail / Edit

/// Title field + multiline body editor for a single note. Keeps a local draft
/// and writes back to the store whenever the title or body changes so edits are
/// persisted as you type (no explicit save button needed).
private struct NoteDetailView: View {
    let note: Note
    @ObservedObject var store: NotesStore
    let onBack: () -> Void
    let onDelete: () -> Void

    @State private var title: String
    @State private var bodyText: String

    init(note: Note, store: NotesStore, onBack: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.note = note
        self.store = store
        self.onBack = onBack
        self.onDelete = onDelete
        _title = State(initialValue: note.title)
        _bodyText = State(initialValue: note.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Notes")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to notes")

                Spacer()

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.destructiveText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete note")
            }

            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.vertical, DS.Spacing.sm)
                .padding(.horizontal, DS.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
                .onChange(of: title) { _, _ in persist() }

            ZStack(alignment: .topLeading) {
                if bodyText.isEmpty {
                    Text("Write your note…")
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.top, DS.Spacing.sm + 1)
                        .padding(.leading, DS.Spacing.md + 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $bodyText)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, DS.Spacing.xs)
                    .padding(.horizontal, DS.Spacing.sm)
                    .frame(height: 200)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
                    .onChange(of: bodyText) { _, _ in persist() }
            }
        }
    }

    /// Writes the current draft back into the store under the note's id.
    private func persist() {
        var updated = note
        updated.title = title
        updated.body = bodyText
        store.update(updated)
    }
}
