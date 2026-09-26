import XCTest
@testable import TabBuddy

final class CurriculumModelSchemaTests: XCTestCase {
    func testMinimalStageDecodesWithDefaults() throws {
        let json = """
        {"id":"guitar.s0","instrument":"guitar","order":0,"title":"Setup","summary":"s",
         "lessons":[{"id":"guitar.s0.l1","title":"T","summary":"s","minutes":5,
           "steps":[{"type":"explain","title":"Hi","body":"Text","diagram":{"kind":"fretboard"}},
                    {"type":"demo","title":"Listen","caption":"c","playback":{"notes":[["E2"]]}},
                    {"type":"practice","exercise":{"kind":"playNote","prompt":"Play E","notes":["E2"]}},
                    {"type":"quiz","generator":{"kind":"noteOnFretboard"}},
                    {"type":"song","title":"Ode","notes":[["E4"]],"rhythm":"q","bpm":80}]}]}
        """
        let stage = try JSONDecoder().decode(Stage.self, from: Data(json.utf8))
        XCTAssertTrue(stage.branches.isEmpty)
        guard case .practice(let p) = stage.lessons[0].steps[2] else { return XCTFail() }
        XCTAssertEqual(p.exercise.passAccuracy, 0.8)
        guard case .demo(let d) = stage.lessons[0].steps[1] else { return XCTFail() }
        XCTAssertEqual(d.playback.bpm, 80)
        guard case .quiz(let q) = stage.lessons[0].steps[3] else { return XCTFail() }
        XCTAssertEqual(q.count, 5)
        let round = try JSONDecoder().decode(Stage.self, from: JSONEncoder().encode(stage))
        XCTAssertEqual(round, stage)
    }
}
