import XCTest
@testable import LyraCore

/// The parser is the last line of defence between a misheard word and someone else's
/// document, so the cases that matter most are the ones that must *not* fire.
final class CommandParserTests: XCTestCase {

    private func parse(_ text: String) -> LyraCommand { CommandParser.parse(text) }

    // MARK: - Safety ordering

    func testStopWinsOverEverythingElse() {
        // The reason ordering exists: a user saying this has a cursor doing something
        // wrong right now.
        XCTAssertEqual(parse("stop click"), .stopTracking)
        XCTAssertEqual(parse("stop"), .stopTracking)
        XCTAssertEqual(parse("off"), .stopTracking)
        XCTAssertEqual(parse("pause"), .stopTracking)
    }

    func testStopBeatsStartInTheSamePhrase() {
        XCTAssertEqual(parse("start cursor stop"), .stopTracking)
    }

    // MARK: - Activation

    func testBasicActivation() {
        XCTAssertEqual(parse("click"), .activate)
        XCTAssertEqual(parse("pick"), .activate)
        XCTAssertEqual(parse("select this"), .activate)
        XCTAssertEqual(parse("click the button"), .activate)
        XCTAssertEqual(parse("double click"), .doubleClick)
        XCTAssertEqual(parse("right click"), .rightClick)
    }

    func testBareMentionOfSelectingIsNotAnActivation() {
        // "select" with no object is a statement about the world, not an instruction.
        XCTAssertEqual(parse("I would select a different approach"), .unrecognized("I would select a different approach"))
    }

    // MARK: - Correction and lens

    func testSelectionAdjustment() {
        XCTAssertEqual(parse("next"), .nextTarget)
        XCTAssertEqual(parse("the other one"), .nextTarget)
        XCTAssertEqual(parse("previous"), .previousTarget)
    }

    func testLensCommands() {
        XCTAssertEqual(parse("zoom in"), .zoomIn)
        XCTAssertEqual(parse("zoom"), .zoomIn)
        XCTAssertEqual(parse("zoom out"), .zoomOut)
        XCTAssertEqual(parse("show targets"), .showTargets)
        XCTAssertEqual(parse("hide targets"), .hideTargets)
    }

    // MARK: - Confirmation

    func testConfirmationRoundTrip() {
        XCTAssertEqual(parse("yes"), .confirm)
        XCTAssertEqual(parse("no"), .deny)
        XCTAssertEqual(parse("cancel"), .cancel)
    }

    func testOrdinarySpeechDoesNotConfirm() {
        // "no" is only accepted as an exact phrase; inside a sentence it is ordinary
        // speech and must not authorise a pending destructive action.
        XCTAssertEqual(parse("no thank you very much"), .unrecognized("no thank you very much"))
    }

    // MARK: - Start

    func testStartTracking() {
        XCTAssertEqual(parse("cursor"), .startTracking)
        XCTAssertEqual(parse("start tracking"), .startTracking)
    }

    func testEmptyInputIsUnrecognized() {
        XCTAssertEqual(parse("   "), .unrecognized("   "))
        XCTAssertEqual(parse("!!!"), .unrecognized("!!!"))
    }

    // MARK: - Normalisation

    func testNormalisationStripsPunctuationAndCase() {
        XCTAssertEqual(CommandParser.normalize("Click, please!"), "click please")
        XCTAssertEqual(CommandParser.normalize("  Zoom   IN  "), "zoom in")
    }
}
