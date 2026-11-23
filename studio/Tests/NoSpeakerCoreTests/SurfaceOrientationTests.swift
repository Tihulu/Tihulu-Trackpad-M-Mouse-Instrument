import XCTest
@testable import NoSpeakerCore

final class SurfaceOrientationTests: XCTestCase {
    func testHorizontalKeepsAxes() {
        let v = SurfaceOrientation.horizontal.transformed(x: 0.25, y: 0.75)
        XCTAssertEqual(v.0, 0.25)
        XCTAssertEqual(v.1, 0.75)
    }
    func testVerticalRotatesMagicMouseCoordinates() {
        let v = SurfaceOrientation.vertical.transformed(x: 0.25, y: 0.75)
        XCTAssertEqual(v.0, 0.75)
        XCTAssertEqual(v.1, 0.75)
    }
    func testInputsAreClampedAndNonFiniteValuesAreSafe() {
        let v = SurfaceOrientation.vertical.transformed(x: .infinity, y: -2)
        XCTAssertEqual(v.0, 0)
        XCTAssertEqual(v.1, 1)
    }
}
