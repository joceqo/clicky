//
//  ParsingTests.swift
//  leanring-buddyTests
//
//  Unit tests for the pure parsing functions in CompanionManager and UserProfile.
//  These functions have no side-effects and no UI dependencies, so they're safe
//  to run in the test host without touching TCC-gated APIs.
//

import Testing
@testable import leanring_buddy

// MARK: - NOTE tag parsing

struct NoteTagParsingTests {

    @Test func noNoteTagsReturnsTextUnchanged() {
        let input = "here is a response with no note tags at all. [POINT:none]"
        let result = CompanionManager.parseAndStripNoteTags(from: input)

        #expect(result.notes.isEmpty)
        #expect(result.textWithNotesStripped == input)
    }

    @Test func singleNoteTagIsExtractedAndStripped() {
        let input = """
        got it, saving that for you.

        [NOTE:Swift Closures]
        A closure is a self-contained block of code that can capture variables from its surrounding scope.
        [/NOTE]
        """

        let result = CompanionManager.parseAndStripNoteTags(from: input)

        #expect(result.notes.count == 1)
        #expect(result.notes[0].title == "Swift Closures")
        #expect(result.notes[0].content.contains("self-contained block"))
        #expect(!result.textWithNotesStripped.contains("[NOTE:"))
        #expect(!result.textWithNotesStripped.contains("[/NOTE]"))
        #expect(result.textWithNotesStripped.contains("saving that for you"))
    }

    @Test func multipleNoteTagsAreAllExtracted() {
        let input = """
        saved both notes for you.
        [NOTE:Topic A]
        Content A
        [/NOTE]
        [NOTE:Topic B]
        Content B
        [/NOTE]
        """

        let result = CompanionManager.parseAndStripNoteTags(from: input)

        #expect(result.notes.count == 2)
        #expect(result.notes[0].title == "Topic A")
        #expect(result.notes[1].title == "Topic B")
        #expect(!result.textWithNotesStripped.contains("[NOTE:"))
    }

    @Test func noteTagTitleAndContentAreTrimmed() {
        let input = "[NOTE:  My Note Title  ]\n  Content here  \n[/NOTE]"
        let result = CompanionManager.parseAndStripNoteTags(from: input)

        #expect(result.notes[0].title == "My Note Title")
        #expect(result.notes[0].content == "Content here")
    }

    @Test func noteTagAfterPointTagIsStripped() {
        let input = """
        check that button up top. [POINT:100,200:button]

        [NOTE:UI Tips]
        The button opens the inspector panel.
        [/NOTE]
        """

        let result = CompanionManager.parseAndStripNoteTags(from: input)

        #expect(result.notes.count == 1)
        // The POINT tag should survive since it's not a NOTE tag
        #expect(result.textWithNotesStripped.contains("[POINT:100,200:button]"))
    }

    @Test func strippedTextIsTrimmedOfSurroundingWhitespace() {
        let input = "spoken text.\n\n[NOTE:title]\ncontent\n[/NOTE]\n\n"
        let result = CompanionManager.parseAndStripNoteTags(from: input)
        #expect(result.textWithNotesStripped == "spoken text.")
    }
}

// MARK: - POINT tag parsing

struct PointTagParsingTests {

    @Test func noneTagReturnsNilCoordinate() {
        let input = "html is the structure of the web. [POINT:none]"
        let result = CompanionManager.parsePointingCoordinates(from: input)

        #expect(result.coordinate == nil)
        #expect(result.spokenText == "html is the structure of the web.")
    }

    @Test func coordinateTagIsExtractedAndStripped() {
        let input = "click the save button up there. [POINT:450,22:save button]"
        let result = CompanionManager.parsePointingCoordinates(from: input)

        #expect(result.coordinate?.x == 450)
        #expect(result.coordinate?.y == 22)
        #expect(result.elementLabel == "save button")
        #expect(result.spokenText == "click the save button up there.")
        #expect(result.screenNumber == nil)
    }

    @Test func screenNumberIsParsedForSecondaryMonitor() {
        let input = "that window is on your other screen. [POINT:800,400:terminal:screen2]"
        let result = CompanionManager.parsePointingCoordinates(from: input)

        #expect(result.coordinate?.x == 800)
        #expect(result.coordinate?.y == 400)
        #expect(result.screenNumber == 2)
        #expect(result.elementLabel == "terminal")
    }

    @Test func missingTagReturnsNilCoordinate() {
        let input = "a general answer with no pointer tag"
        let result = CompanionManager.parsePointingCoordinates(from: input)

        #expect(result.coordinate == nil)
        // Spoken text should be the full input when there's no tag to strip
        #expect(result.spokenText == input)
    }

    @Test func spokenTextIsCleanedOfTrailingWhitespace() {
        let input = "look at the toolbar.   [POINT:200,30:toolbar]"
        let result = CompanionManager.parsePointingCoordinates(from: input)
        #expect(result.spokenText == "look at the toolbar.")
    }
}

// MARK: - UserProfile system prompt injection

struct UserProfileTests {

    @Test func emptyProfileHasNoContent() {
        let profile = UserProfile(nickname: "", goals: "", additionalContext: "")
        #expect(!profile.hasAnyContent)
    }

    @Test func profileWithOnlyNicknameHasContent() {
        let profile = UserProfile(nickname: "joce", goals: "", additionalContext: "")
        #expect(profile.hasAnyContent)
    }

    @Test func profileWithWhitespaceOnlyHasNoContent() {
        let profile = UserProfile(nickname: "   ", goals: "\n\t", additionalContext: "  ")
        #expect(!profile.hasAnyContent)
    }

    @Test func systemPromptSectionIncludesAllFilledFields() {
        let profile = UserProfile(
            nickname: "joce",
            goals: "get better at coding",
            additionalContext: "learning DaVinci Resolve"
        )
        let section = profile.buildSystemPromptSection()

        #expect(section.contains("name: joce"))
        #expect(section.contains("goals: get better at coding"))
        #expect(section.contains("additional context: learning DaVinci Resolve"))
    }

    @Test func systemPromptSectionOmitsEmptyFields() {
        let profile = UserProfile(nickname: "joce", goals: "", additionalContext: "")
        let section = profile.buildSystemPromptSection()

        #expect(section.contains("name: joce"))
        #expect(!section.contains("goals:"))
        #expect(!section.contains("additional context:"))
    }

    @Test func emptyProfileProducesEmptySection() {
        let profile = UserProfile()
        let section = profile.buildSystemPromptSection()
        #expect(section.isEmpty)
    }

    @Test func systemPromptSectionStartsWithUserProfileHeader() {
        let profile = UserProfile(nickname: "joce", goals: "", additionalContext: "")
        let section = profile.buildSystemPromptSection()
        #expect(section.hasPrefix("user profile:"))
    }
}
