import XCTest
@testable import TabBuddy

final class TutorContractsTests: XCTestCase {
    func testPassageTiming() {
        let passage = ExpectedPassage(events: [ExpectedEvent(id: 0, pitches: [40], beat: 2, durationBeats: 1,
                                                             measureIndex: 0, positionInMeasure: 0.5)],
                                      beatsPerMeasure: 4, bpm: 120, instrument: .guitar)
        XCTAssertEqual(passage.time(ofBeat: 2), 1, accuracy: 1e-9)
        XCTAssertEqual(passage.measureRange, 0...0)
    }
}
