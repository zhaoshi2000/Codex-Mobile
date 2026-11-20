import XCTest

final class SelectionUITests: XCTestCase {
    @MainActor
    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    func testPartialCopySurvivesUpdatesAndPreservesMarkdown() {
        let app = launch()
        app.buttons["Check selection and rendering"].tap()
        let result = app.staticTexts["result"]
        let passed = NSPredicate(format: "label BEGINSWITH 'PASS'")
        expectation(for: passed, evaluatedWith: result)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.keyboards.count, 0)
    }

    @MainActor
    func testLongPressShowsSystemSelectionWithoutKeyboard() {
        let app = launch()
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.04)).press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["Selection active"].waitForExistence(timeout: 4), app.debugDescription)
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertEqual(app.keyboards.count, 0)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Native partial text selection"
        image.lifetime = .keepAlways
        add(image)
        copy.tap()
    }

    @MainActor
    func testFileLinkUsesTheChatDownloadHandler() {
        let app = launch()
        let link = app.links["下载报告"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
        link.tap()
        XCTAssertTrue(app.staticTexts["File routed"].waitForExistence(timeout: 3), app.debugDescription)
    }
}
