//
//  NotchReadAlongView.swift
//  leanring-buddy
//
//  Live "read-along" rendering of the buddy's spoken response — the full
//  response text split into phrases, with the currently-spoken phrase
//  highlighted at full brightness while already-spoken phrases dim back and
//  upcoming phrases stay dimmer. Auto-scrolls to keep the active phrase centred.
//
//  This is the SHARED core used by two surfaces:
//    • the floating cursor bubble on non-notch Macs
//      (`PhraseHighlightResponseBubbleView` in OverlayWindow.swift wraps it), and
//    • the Dynamic-Island notch on notched Macs (NotchResponseReadAlongView in
//      NotchWindowManager, which feeds it the live CompanionManager state).
//
//  Keeping the highlight/auto-scroll logic in one place means the two surfaces
//  can never drift apart.
//

import SwiftUI

/// Reports the intrinsic height of the read-along content so a host can cap the
/// visible area (and let the inner ScrollView take over past that cap).
struct ReadAlongContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The phrase-highlighted, auto-scrolling response text. Pure presentation: it
/// takes the phrases + active index and renders them; hosts decide the width,
/// the height cap, and the surrounding chrome.
struct ReadAlongView: View {
    let phrases: [String]
    let activePhraseIndex: Int?

    /// Visible width of the text column.
    var width: CGFloat = 304
    /// Maximum visible height before the content scrolls internally.
    var maxHeight: CGFloat = 340
    /// Base font size for phrases.
    var fontSize: CGFloat = 12

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(phrases.enumerated()), id: \.offset) { index, phrase in
                        Text(phrase)
                            .font(.system(size: fontSize, weight: index == activePhraseIndex ? .semibold : .regular))
                            .foregroundColor(DS.Colors.textPrimary.opacity(phraseTextOpacity(forIndex: index)))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ReadAlongContentHeightKey.self, value: geo.size.height)
                    }
                )
            }
            // Visible box = content height capped at maxHeight, so it grows with
            // the text but never overflows; the ScrollView scrolls past that.
            .frame(width: width, height: min(contentHeight, maxHeight))
            .onPreferenceChange(ReadAlongContentHeightKey.self) { contentHeight = $0 }
            .onChange(of: activePhraseIndex) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func phraseTextOpacity(forIndex index: Int) -> Double {
        guard let activeIndex = activePhraseIndex else { return 1.0 }
        if index == activeIndex { return 1.0 }
        if index < activeIndex { return 0.45 }  // already spoken
        return 0.30                              // not yet spoken
    }
}

/// Notch-flavoured wrapper around `ReadAlongView`: observes the live
/// CompanionManager and renders the read-along styled for the expanded notch
/// (wider column, panel chrome, a tiny "speaking" header). Used as the expanded
/// notch content while the buddy is responding (see NotchWindowManager's router).
struct NotchResponseReadAlongView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            header

            ReadAlongView(
                phrases: companionManager.currentResponsePhrases,
                activePhraseIndex: companionManager.currentlySpeakingPhraseIndex,
                width: 396,
                maxHeight: 300,
                fontSize: 13
            )
        }
        .padding(DS.Spacing.md)
        .frame(width: 420)
        .background(DS.Colors.background)
        .clickyPanelBackground(cornerRadius: DS.CornerRadius.extraLarge)
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            NotchBuddyGlyph(width: 12, height: 10)
            Text("Speaking…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer(minLength: 0)
        }
    }
}
