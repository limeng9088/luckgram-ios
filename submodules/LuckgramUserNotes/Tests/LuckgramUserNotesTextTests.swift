import XCTest
@testable import LuckgramUserNotes

/// Spec 05 (private notes): text rules shared by the editor, chat bar and "All notes".
final class LuckgramUserNotesTextTests: XCTestCase {
    private let noahNote = "柏林设计周认识的。欠我 40 欧元"

    // 需求 2：纯文本，最多 2000 字，支持换行

    func testKeepsLineBreaksAndTrimsOuterWhitespace() {
        XCTAssertEqual(LuckgramUserNotesText.normalize("  第一行\n第二行\n\n "), "第一行\n第二行")
    }

    func testBlankNoteMeansNoNote() {
        XCTAssertEqual(LuckgramUserNotesText.normalize(nil), "")
        XCTAssertEqual(LuckgramUserNotesText.normalize(" \n\t "), "")
    }

    func testExactly2000CharactersAreKept() {
        let note = String(repeating: "字", count: 2000)
        XCTAssertEqual(LuckgramUserNotesText.normalize(note), note)
        XCTAssertTrue(LuckgramUserNotesText.isWithinLimit(note))
    }

    func testLongerNotesAreCutAndRefusedInEditor() {
        let long = String(repeating: "字", count: 2001)
        XCTAssertEqual(LuckgramUserNotesText.normalize(long).count, 2000)
        XCTAssertFalse(LuckgramUserNotesText.isWithinLimit(long))
    }

    func testEmojiCountAsOneCharacter() {
        let cut = LuckgramUserNotesText.normalize(String(repeating: "😀", count: 2001))
        XCTAssertEqual(cut.count, 2000)
        XCTAssertEqual(cut, String(repeating: "😀", count: 2000))
    }

    // 需求 3：聊天顶部细条显示备注第一行

    func testFirstLineSkipsEmptyLines() {
        XCTAssertEqual(LuckgramUserNotesText.firstLine("\n  \n柏林设计周认识的。\n欠我 40 欧元"), "柏林设计周认识的。")
    }

    func testFirstLineOfSingleLineNote() {
        XCTAssertEqual(LuckgramUserNotesText.firstLine(noahNote), noahNote)
        XCTAssertEqual(LuckgramUserNotesText.firstLine(nil), "")
    }

    // 需求 4 / 验收：「全部备注」搜索「欧元」能找到 Noah

    func testSearchFindsNoahByNoteText() {
        XCTAssertTrue(LuckgramUserNotesText.matches(query: "欧元", note: noahNote, name: "Noah"))
    }

    func testSearchFindsByNameCaseInsensitive() {
        XCTAssertTrue(LuckgramUserNotesText.matches(query: "noah", note: noahNote, name: "Noah"))
        XCTAssertTrue(LuckgramUserNotesText.matches(query: " NOAH ", note: "", name: "Noah Schmidt"))
    }

    func testSearchMisses() {
        XCTAssertFalse(LuckgramUserNotesText.matches(query: "美元", note: noahNote, name: "Noah"))
    }

    func testEmptyQueryListsEverything() {
        XCTAssertTrue(LuckgramUserNotesText.matches(query: "", note: noahNote, name: "Noah"))
    }

    func testSnippetShowsTheMatchingLine() {
        let note = "柏林设计周认识的\n欠我 40 欧元"
        XCTAssertEqual(LuckgramUserNotesText.snippet(note: note, query: "欧元"), "欠我 40 欧元")
        XCTAssertEqual(LuckgramUserNotesText.snippet(note: note, query: "Noah"), "柏林设计周认识的")
        XCTAssertEqual(LuckgramUserNotesText.snippet(note: note, query: ""), "柏林设计周认识的")
    }
}
