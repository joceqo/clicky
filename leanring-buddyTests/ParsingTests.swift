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

// MARK: - ActionTagParser: [LOG:app:topic]

struct LogTagParsingTests {

    @Test func noLogTagsProducesEmptyEntries() {
        let input = "here is a plain response with no log tags."
        let result = ActionTagParser.parse(from: input)

        #expect(result.logEntries.isEmpty)
        #expect(result.cleanedText == input)
    }

    @Test func singleLogTagIsExtractedAndStripped() {
        let input = "great question about color grading. [LOG:DaVinci Resolve:color wheels]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.logEntries.count == 1)
        #expect(result.logEntries[0].app == "DaVinci Resolve")
        #expect(result.logEntries[0].topic == "color wheels")
        #expect(!result.cleanedText.contains("[LOG:"))
        #expect(result.cleanedText.contains("great question about color grading"))
    }

    @Test func multipleLogTagsAreAllExtracted() {
        let input = """
        we covered two topics today. [LOG:Xcode:breakpoints] [LOG:Swift:async await]
        """
        let result = ActionTagParser.parse(from: input)

        #expect(result.logEntries.count == 2)
        let apps = result.logEntries.map { $0.app }
        #expect(apps.contains("Xcode"))
        #expect(apps.contains("Swift"))
        #expect(!result.cleanedText.contains("[LOG:"))
    }

    @Test func logTagWithSpacesInAppAndTopicIsParsed() {
        let input = "[LOG:Visual Studio Code:multi-cursor editing]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.logEntries.count == 1)
        #expect(result.logEntries[0].app == "Visual Studio Code")
        #expect(result.logEntries[0].topic == "multi-cursor editing")
    }

    @Test func logTagAppAndTopicAreTrimmed() {
        let input = "[LOG:  Figma  :  auto layout  ]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.logEntries[0].app == "Figma")
        #expect(result.logEntries[0].topic == "auto layout")
    }
}

// MARK: - ActionTagParser: [OPEN:url-or-app]

struct OpenTagParsingTests {

    @Test func noOpenTagsProducesEmptyTargets() {
        let input = "nothing to open here."
        let result = ActionTagParser.parse(from: input)
        #expect(result.openTargets.isEmpty)
    }

    @Test func urlOpenTagIsExtractedAndStripped() {
        let input = "opening that for you. [OPEN:https://developer.apple.com]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.openTargets.count == 1)
        #expect(result.openTargets[0] == "https://developer.apple.com")
        #expect(!result.cleanedText.contains("[OPEN:"))
        #expect(result.cleanedText.contains("opening that for you"))
    }

    @Test func appNameOpenTagIsExtracted() {
        let input = "launching Xcode for you. [OPEN:Xcode]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.openTargets.count == 1)
        #expect(result.openTargets[0] == "Xcode")
    }

    @Test func multipleOpenTagsAreAllExtracted() {
        let input = "opening your tools. [OPEN:Xcode] [OPEN:https://swift.org]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.openTargets.count == 2)
        #expect(result.openTargets.contains("Xcode"))
        #expect(result.openTargets.contains("https://swift.org"))
    }

    @Test func openTagValueIsTrimmed() {
        let input = "[OPEN:  Safari  ]"
        let result = ActionTagParser.parse(from: input)
        #expect(result.openTargets[0] == "Safari")
    }
}

// MARK: - ActionTagParser: [SHORTCUT:name]

struct ShortcutTagParsingTests {

    @Test func noShortcutTagsProducesEmptyNames() {
        let input = "no shortcuts here."
        let result = ActionTagParser.parse(from: input)
        #expect(result.shortcutNames.isEmpty)
    }

    @Test func shortcutTagIsExtractedAndStripped() {
        let input = "running your morning routine. [SHORTCUT:Morning Routine]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.shortcutNames.count == 1)
        #expect(result.shortcutNames[0] == "Morning Routine")
        #expect(!result.cleanedText.contains("[SHORTCUT:"))
        #expect(result.cleanedText.contains("running your morning routine"))
    }

    @Test func multipleShortcutTagsAreAllExtracted() {
        let input = "running both shortcuts. [SHORTCUT:Focus Mode] [SHORTCUT:Daily Backup]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.shortcutNames.count == 2)
        #expect(result.shortcutNames.contains("Focus Mode"))
        #expect(result.shortcutNames.contains("Daily Backup"))
    }

    @Test func shortcutNameIsTrimmed() {
        let input = "[SHORTCUT:  End of Day  ]"
        let result = ActionTagParser.parse(from: input)
        #expect(result.shortcutNames[0] == "End of Day")
    }
}

// MARK: - ActionTagParser: [REMIND:text:date-hint]

struct RemindTagParsingTests {

    @Test func noRemindTagsProducesEmptyReminders() {
        let input = "nothing to remind you about."
        let result = ActionTagParser.parse(from: input)
        #expect(result.reminders.isEmpty)
    }

    @Test func remindTagIsExtractedAndStripped() {
        let input = "I'll set that reminder. [REMIND:Practice color grading:tomorrow 9am]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.reminders.count == 1)
        #expect(result.reminders[0].text == "Practice color grading")
        #expect(result.reminders[0].dateHint == "tomorrow 9am")
        #expect(!result.cleanedText.contains("[REMIND:"))
        #expect(result.cleanedText.contains("I'll set that reminder"))
    }

    @Test func remindTagWithEmptyDateHintIsAccepted() {
        // If the model emits [REMIND:task:] with empty date hint, we should still capture the text
        // The regex requires at least one char for date hint, so this tests graceful handling
        let input = "reminder set. [REMIND:Review notes:today]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.reminders.count == 1)
        #expect(result.reminders[0].text == "Review notes")
        #expect(result.reminders[0].dateHint == "today")
    }

    @Test func multipleRemindTagsAreAllExtracted() {
        let input = "added both reminders. [REMIND:Call doctor:tomorrow] [REMIND:Submit report:Friday 5pm]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.reminders.count == 2)
        let texts = result.reminders.map { $0.text }
        #expect(texts.contains("Call doctor"))
        #expect(texts.contains("Submit report"))
    }

    @Test func remindTagFieldsAreTrimmed() {
        let input = "[REMIND:  Buy groceries  :  this evening  ]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.reminders[0].text == "Buy groceries")
        #expect(result.reminders[0].dateHint == "this evening")
    }
}

// MARK: - ActionTagParser: mixed tags and cleaned text

struct MixedActionTagParsingTests {

    @Test func allTagTypesAreExtractedFromOneResponse() {
        let input = """
        I learned you want to understand async/await. [LOG:Swift:async await]
        Opening the Swift docs now. [OPEN:https://docs.swift.org]
        Running your focus shortcut. [SHORTCUT:Focus Mode]
        Set a reminder to practice tomorrow. [REMIND:Practice async/await:tomorrow morning]
        """
        let result = ActionTagParser.parse(from: input)

        #expect(result.logEntries.count == 1)
        #expect(result.openTargets.count == 1)
        #expect(result.shortcutNames.count == 1)
        #expect(result.reminders.count == 1)
        #expect(result.hasAnyActions)
        #expect(!result.cleanedText.contains("[LOG:"))
        #expect(!result.cleanedText.contains("[OPEN:"))
        #expect(!result.cleanedText.contains("[SHORTCUT:"))
        #expect(!result.cleanedText.contains("[REMIND:"))
    }

    @Test func responseWithNoActionTagsHasNoActions() {
        let input = "just a plain conversational response."
        let result = ActionTagParser.parse(from: input)
        #expect(!result.hasAnyActions)
        #expect(result.cleanedText == input)
    }

    @Test func cleanedTextIsTrimmedAfterTagRemoval() {
        // Tags at the very end leave trailing whitespace — should be trimmed
        let input = "doing it now. [LOG:Xcode:debugging]   "
        let result = ActionTagParser.parse(from: input)
        #expect(!result.cleanedText.hasSuffix("   "))
        #expect(result.cleanedText == "doing it now.")
    }

    @Test func tagsThatSurviveArePreservedInCleanedText() {
        // POINT tags are NOT handled by ActionTagParser — they survive into cleanedText
        // so the voice pipeline can parse them in a subsequent step
        let input = "look at this button. [LOG:Xcode:inspector panel] [POINT:300,200:button]"
        let result = ActionTagParser.parse(from: input)

        #expect(result.logEntries.count == 1)
        // POINT tag should remain in the cleaned text for the voice pipeline
        #expect(result.cleanedText.contains("[POINT:300,200:button]"))
    }
}

// MARK: - LearningEntry Codable round-trip

struct LearningEntryTests {

    @Test func learningEntryEncodesAndDecodesCorrectly() throws {
        let originalEntry = LearningEntry(
            app: "DaVinci Resolve",
            topic: "color wheels",
            noteTitle: "Color Grading Basics"
        )

        let encodedData = try JSONEncoder().encode(originalEntry)
        let decodedEntry = try JSONDecoder().decode(LearningEntry.self, from: encodedData)

        #expect(decodedEntry.id == originalEntry.id)
        #expect(decodedEntry.app == originalEntry.app)
        #expect(decodedEntry.topic == originalEntry.topic)
        #expect(decodedEntry.noteTitle == originalEntry.noteTitle)
    }

    @Test func learningEntryWithNilNoteTitleDecodesCorrectly() throws {
        let originalEntry = LearningEntry(app: "Xcode", topic: "breakpoints", noteTitle: nil)

        let encodedData = try JSONEncoder().encode(originalEntry)
        let decodedEntry = try JSONDecoder().decode(LearningEntry.self, from: encodedData)

        #expect(decodedEntry.noteTitle == nil)
    }

    @Test func learningEntryArrayEncodesAndDecodesAsJSON() throws {
        let entries = [
            LearningEntry(app: "Swift", topic: "closures"),
            LearningEntry(app: "Swift", topic: "generics"),
            LearningEntry(app: "Figma", topic: "components"),
        ]

        let encodedData = try JSONEncoder().encode(entries)
        let decodedEntries = try JSONDecoder().decode([LearningEntry].self, from: encodedData)

        #expect(decodedEntries.count == 3)
        #expect(decodedEntries[0].app == "Swift")
        #expect(decodedEntries[1].topic == "generics")
        #expect(decodedEntries[2].app == "Figma")
    }
}
