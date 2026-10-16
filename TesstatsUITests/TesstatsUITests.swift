import XCTest

@MainActor
final class TesstatsUITests: XCTestCase {
    func testMonthlyChargingCostFiltersAndLayout() {
        XCUIDevice.shared.orientation = .portrait
        let app = localizedDemoApp(language: "es")
        app.launch()
        tapTab(["Cargas", "Charging"], app: app)
        let filters = app.buttons["charging-cost-filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 10))
        if !filters.isHittable { app.swipeUp() }
        XCTAssertTrue(filters.isHittable)
        capture("charging-monthly-cost-portrait", in: app)
        filters.tap()
        let locationButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "charging-cost-location-", "charging-cost-location-search"))
        XCTAssertGreaterThan(locationButtons.count, 1)
        let first = locationButtons.element(boundBy: 0)
        let firstID = first.identifier
        first.tap()
        locationButtons.element(boundBy: 1).tap()
        XCTAssertEqual(first.value as? String, "Seleccionado")
        let search = app.textFields.firstMatch
        search.tap()
        search.typeText("unlikely-location-xyz")
        XCTAssertTrue(app.staticTexts["No hay puntos de carga"].exists || locationButtons.count == 0)
        app.buttons["charging-cost-apply"].tap()
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.tap()
        XCTAssertEqual(app.buttons[firstID].value as? String, "Seleccionado")
        app.segmentedControls["charging-cost-period"].buttons["Años"].tap()
        capture("charging-monthly-cost-filters", in: app)
        app.segmentedControls["charging-cost-period"].buttons["Días"].tap()
        XCTAssertEqual(app.datePickers.count, 2)
        app.buttons["charging-cost-all-locations"].tap()
        app.buttons["charging-cost-apply"].tap()
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["charging-cost-total"].exists)
        capture("charging-monthly-cost-filtered", in: app)
    }

    func testDriverQuickAppearanceAndExpandedZoom() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_DEMO_SCENARIO"] = "driving"
        app.launchEnvironment["TESSTATS_START_SCREEN"] = "driver"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launchEnvironment["TESSTATS_DRIVER_APPEARANCE"] = "dark"
        app.launchEnvironment["TESSTATS_DRIVER_HIDDEN_MODULES"] = ""
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let toggle = app.buttons["driver-appearance-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 8))
            XCTAssertTrue(toggle.isHittable)
            XCTAssertLessThan(toggle.frame.midX, app.buttons["driver-display-settings"].frame.midX)
            toggle.tap()
            XCTAssertFalse(app.descendants(matching: .any)["driver-speed-dial"].exists)
            XCTAssertTrue(app.staticTexts["driver-speed-value"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["driver-gear-badge"].exists)
            for _ in 0..<6 { app.buttons["driver-map-zoom-in"].tap() }
            let vehicle = app.descendants(matching: .any)["driver-map-vehicle"]
            XCTAssertTrue(app.windows.firstMatch.frame.contains(vehicle.frame))
            capture("driver-560-day-\(orientation.rawValue)", in: app)
            for _ in 0..<6 { app.buttons["driver-map-zoom-out"].tap() }
            XCTAssertTrue(app.windows.firstMatch.frame.contains(vehicle.frame))
            toggle.tap()
            XCTAssertTrue(app.descendants(matching: .any)["driver-speed-dial"].exists)
            XCTAssertTrue(app.buttons["driver-close"].isHittable)
            app.buttons["driver-display-settings"].tap()
            XCTAssertTrue(app.buttons["driver-bluetooth-done"].waitForExistence(timeout: 4))
            app.buttons["driver-bluetooth-done"].tap()
        }
        app.buttons["driver-close"].tap()
        XCTAssertFalse(app.buttons["driver-close"].exists)
    }

    func testDriverElementsCanAllBeHiddenWithoutLosingExitOrSettings() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_DEMO_SCENARIO"] = "driving"
        app.launchEnvironment["TESSTATS_START_SCREEN"] = "driver"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launchEnvironment["TESSTATS_DRIVER_HIDDEN_MODULES"] = ""
        app.launch()
        XCTAssertTrue(app.buttons["driver-display-settings"].waitForExistence(timeout: 8))
        app.buttons["driver-display-settings"].tap()
        let speedToggle = app.switches["driver-toggle-speed"]
        if !speedToggle.isHittable { app.swipeUp() }
        XCTAssertTrue(speedToggle.isHittable)
        speedToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["driver-bluetooth-done"].tap()
        XCTAssertFalse(app.staticTexts["driver-speed-value"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["driver-gear-badge"].exists)
        app.terminate()

        app.launchEnvironment["TESSTATS_DRIVER_HIDDEN_MODULES"] =
            "speed,battery,power,motion,averageConsumption,lastTripConsumption,tripCost,route,map,environment,alerts,gear,speedActivity,range,outsideTemperature,odometer,tripDistance,logo,clock,connection,mapZoom"
        app.launch()
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.buttons["driver-close"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["driver-display-settings"].isHittable)
            for identifier in ["driver-speed-value", "driver-speed-dial", "driver-gear-badge",
                               "driver-battery", "driver-range-counter", "driver-temperature",
                               "driver-odometer", "driver-trip-distance", "driver-average-consumption",
                               "driver-current-trip-consumption", "driver-current-trip-cost",
                               "driver-route-summary", "driver-dynamics-summary", "driver-power", "driver-motion", "driver-map-vehicle",
                               "driver-map-zoom-in", "driver-connection-indicator"] {
                XCTAssertFalse(app.descendants(matching: .any)[identifier].exists, identifier)
            }
        }
        app.buttons["driver-close"].tap()
        XCTAssertFalse(app.buttons["driver-close"].exists)
    }

    func testSpanishEnglishAndUnsupportedSystemLanguagePolicy() {
        XCUIDevice.shared.orientation = .portrait

        let spanish = localizedDemoApp(language: "es")
        spanish.launch()
        XCTAssertTrue(spanish.buttons["Resumen"].waitForExistence(timeout: 8))
        XCTAssertTrue(spanish.buttons["Cargas"].exists)
        XCTAssertFalse(spanish.buttons["Summary"].exists)
        spanish.terminate()

        let english = localizedDemoApp(language: "en")
        english.launch()
        XCTAssertTrue(english.buttons["Summary"].waitForExistence(timeout: 8))
        XCTAssertTrue(english.buttons["Charging"].exists)
        XCTAssertFalse(english.buttons["Resumen"].exists)
        english.terminate()

        let unsupported = localizedDemoApp(language: "")
        unsupported.launchArguments += ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        unsupported.launch()
        XCTAssertTrue(unsupported.buttons["Summary"].waitForExistence(timeout: 8))
        XCTAssertTrue(unsupported.buttons["Charging"].exists)
        XCTAssertFalse(unsupported.buttons["Résumé"].exists)
    }

    func testDriverDisplayOpensInBothOrientationsAndRemainsReadOnly() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_DEMO_SCENARIO"] = "driving"
        app.launchEnvironment["TESSTATS_LANGUAGE"] = "en"
        app.launchEnvironment["TESSTATS_START_SCREEN"] = "driver"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launchEnvironment["TESSTATS_SCREENSHOT_MODE"] = "1"
        app.launch()

        let close = app.buttons["driver-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        let bluetoothSettings = app.buttons["driver-display-settings"]
        XCTAssertTrue(bluetoothSettings.exists)
        XCTAssertLessThan(bluetoothSettings.frame.midX, close.frame.midX,
                          "Read-only Bluetooth settings must sit immediately left of close")
        XCTAssertGreaterThanOrEqual(close.frame.width, 44, "The close control needs a reliable touch target")
        XCTAssertGreaterThanOrEqual(close.frame.height, 44, "The close control needs a reliable touch target")
        XCTAssertFalse(app.buttons["Unlock"].exists)
        XCTAssertFalse(app.buttons["Start climate"].exists)
        let portraitDial = app.descendants(matching: .any)["driver-speed-dial"]
        let portraitVehicle = app.descendants(matching: .any)["driver-map-vehicle"]
        let portraitZoomIn = app.buttons["driver-map-zoom-in"]
        let portraitZoomOut = app.buttons["driver-map-zoom-out"]
        XCTAssertTrue(portraitDial.exists)
        XCTAssertTrue(portraitVehicle.exists, "Portrait mode must keep the vehicle arrow visible on the map")
        XCTAssertGreaterThan(portraitVehicle.frame.midY, portraitDial.frame.maxY,
                             "The portrait vehicle arrow must remain in the visible map area below the raised dial")
        XCTAssertTrue(portraitZoomIn.isHittable, "Portrait zoom-in must be visible and tappable")
        XCTAssertTrue(portraitZoomOut.isHittable, "Portrait zoom-out must be visible and tappable")
        let portraitWindow = app.windows.firstMatch.frame
        XCTAssertGreaterThan(portraitZoomIn.frame.maxX, portraitWindow.maxX - 12,
                             "Portrait zoom controls should sit against the lower-right corner")
        portraitZoomIn.tap()
        XCTAssertTrue(portraitVehicle.exists)
        XCTAssertTrue(portraitWindow.contains(portraitVehicle.frame),
                      "Zooming must retain the vehicle as the visible map reference")
        XCTAssertGreaterThan(portraitZoomIn.frame.midX, app.windows.firstMatch.frame.midX)
        XCTAssertGreaterThan(portraitZoomOut.frame.midY, app.windows.firstMatch.frame.midY)
        bluetoothSettings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["driver-telemetry-mode-sheet"].waitForExistence(timeout: 3),
                      "Portrait settings must remain tappable above the map")
        app.buttons["driver-bluetooth-done"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["driver-close"].waitForExistence(timeout: 4))
        let landscapeSpeed = app.staticTexts["driver-speed-value"]
        XCTAssertTrue(landscapeSpeed.exists)
        XCTAssertLessThanOrEqual(abs(landscapeSpeed.frame.midX - app.windows.firstMatch.frame.midX), 1,
                                 "Landscape speed must stay centered while the map fades in beside it")
        XCTAssertTrue(app.descendants(matching: .any)["driver-route-summary"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["driver-map-vehicle"].exists,
                      "The vehicle arrow must remain clearly exposed on the right-side map")
        let rangeCounter = app.descendants(matching: .any)["driver-range-counter"]
        XCTAssertTrue(rangeCounter.exists, "Remaining and full estimated range should sit beside battery charge")
        XCTAssertTrue(rangeCounter.label.contains("/"), "Range counter should read as remaining / full")
        let odometer = app.descendants(matching: .any)["driver-odometer"]
        let currentTrip = app.descendants(matching: .any)["driver-trip-distance"]
        let averageConsumption = app.descendants(matching: .any)["driver-average-consumption"]
        let currentTripConsumption = app.descendants(matching: .any)["driver-current-trip-consumption"]
        XCTAssertTrue(odometer.exists)
        XCTAssertTrue(currentTrip.exists)
        XCTAssertTrue(averageConsumption.waitForExistence(timeout: 5))
        XCTAssertTrue(currentTripConsumption.waitForExistence(timeout: 5))
        let currentTripCost = app.descendants(matching: .any)["driver-current-trip-cost"]
        XCTAssertTrue(currentTripCost.waitForExistence(timeout: 5),
                      "Driver Display should expose the live trip cost from charged-energy history")
        let temperatures = app.descendants(matching: .any)["driver-temperature"]
        XCTAssertTrue(temperatures.label.contains("Inside"))
        XCTAssertTrue(temperatures.label.contains("Outside"))
        XCTAssertTrue(averageConsumption.label.contains("Wh/"),
                      "The vehicle average should use the configured consumption unit")
        XCTAssertTrue(currentTripConsumption.label.contains("Wh/"),
                      "The live current-trip average should use the configured consumption unit")
        let zoomIn = app.buttons["driver-map-zoom-in"]
        let zoomOut = app.buttons["driver-map-zoom-out"]
        XCTAssertTrue(zoomIn.isHittable, "Landscape zoom-in must be visible and tappable")
        XCTAssertTrue(zoomOut.isHittable, "Landscape zoom-out must be visible and tappable")
        XCTAssertLessThanOrEqual(zoomIn.frame.maxX, app.windows.firstMatch.frame.maxX)
        XCTAssertLessThanOrEqual(zoomOut.frame.maxY, app.windows.firstMatch.frame.maxY)
        XCTAssertGreaterThan(zoomIn.frame.midX, app.windows.firstMatch.frame.midX)
        XCTAssertGreaterThan(zoomOut.frame.midY, app.windows.firstMatch.frame.midY)
        zoomIn.tap()
        let vehicleAfterZoomIn = app.descendants(matching: .any)["driver-map-vehicle"]
        XCTAssertTrue(app.windows.firstMatch.frame.contains(vehicleAfterZoomIn.frame),
                      "Landscape zoom-in must preserve the vehicle reference")
        zoomOut.tap()
        XCTAssertTrue(app.windows.firstMatch.frame.contains(vehicleAfterZoomIn.frame),
                      "Landscape zoom-out must preserve the vehicle reference")
        XCTAssertLessThan(odometer.frame.midX, app.windows.firstMatch.frame.midX,
                          "Odometer should remain in the lower-left driving cluster")
        XCTAssertLessThan(currentTrip.frame.midX, app.windows.firstMatch.frame.midX,
                          "Current trip should remain beside the odometer")
        XCTAssertTrue(app.descendants(matching: .any)["driver-motion"].exists,
                      "The enabled motion module should remain available in landscape")
        for hiddenLabel in ["TeslaMate", "iPhone GPS", "Route overview · no turn guidance",
                            "Supplemental display", "No active route"] {
            XCTAssertFalse(app.staticTexts[hiddenLabel].exists,
                           "Driver mode should not expose implementation language: \(hiddenLabel)")
        }
        let speedBeforeCapture = landscapeSpeed.label
        let nextSpeedSample = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", speedBeforeCapture),
            object: landscapeSpeed
        )
        _ = XCTWaiter.wait(for: [nextSpeedSample], timeout: 1.5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        capture("iphone-driver-immersive-landscape", in: app)
        app.buttons["driver-display-settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["driver-telemetry-mode-sheet"].waitForExistence(timeout: 5),
                      "Driver settings must expose Auto, Bluetooth and iPhone telemetry modes")
        app.buttons["driver-bluetooth-done"].tap()
        XCTAssertTrue(app.buttons["driver-close"].waitForExistence(timeout: 5))
        app.buttons["driver-close"].tap()
        XCTAssertTrue(app.buttons["driver-display-card-open"].waitForExistence(timeout: 5))
    }

    func testDriverSpeedIsCenteredAndTransmissionFollowsDialInBothOrientations() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_DEMO_SCENARIO"] = "parked"
        app.launchEnvironment["TESSTATS_START_SCREEN"] = "driver"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launchEnvironment["TESSTATS_SCREENSHOT_MODE"] = "1"
        app.launch()

        func assertCircularTransmission(file: StaticString = #filePath, line: UInt = #line) {
            let speed = app.staticTexts["driver-speed-value"]
            XCTAssertTrue(speed.waitForExistence(timeout: 8), file: file, line: line)
            XCTAssertEqual(speed.label, "0", file: file, line: line)
            XCTAssertLessThanOrEqual(abs(speed.frame.midX - app.windows.firstMatch.frame.midX), 1,
                                     "The speed reading must remain geometrically centered",
                                     file: file, line: line)

            let dial = app.descendants(matching: .any)["driver-speed-dial"]
            XCTAssertTrue(dial.exists, file: file, line: line)
            let gears = ["p", "r", "n", "d"].map {
                app.staticTexts["driver-gear-\($0)"]
            }
            for gear in gears {
                XCTAssertTrue(gear.exists, file: file, line: line)
                XCTAssertGreaterThanOrEqual(gear.frame.minX, dial.frame.minX - 1, file: file, line: line)
                XCTAssertLessThanOrEqual(gear.frame.maxX, dial.frame.maxX + 1,
                                         "No selected gear badge may cross the outer dial",
                                         file: file, line: line)
                XCTAssertGreaterThanOrEqual(gear.frame.minY, dial.frame.minY - 1, file: file, line: line)
                XCTAssertLessThanOrEqual(gear.frame.maxY, dial.frame.maxY + 1,
                                         "No selected gear badge may cross the outer dial",
                                         file: file, line: line)
            }
            for pair in zip(gears, gears.dropFirst()) {
                XCTAssertLessThan(pair.0.frame.midY, pair.1.frame.midY,
                                  "Transmission positions must read from P to D, top to bottom",
                                  file: file, line: line)
            }
            XCTAssertGreaterThan(gears[0].frame.midX, speed.frame.midX,
                                 "The transmission positions must follow the dial's right-hand arc",
                                 file: file, line: line)
            let radii = gears.map { hypot($0.frame.midX - dial.frame.midX, $0.frame.midY - dial.frame.midY) }
            XCTAssertLessThan((radii.max() ?? 0) - (radii.min() ?? 0), 3,
                              "Every transmission position must sit on the same circular path",
                              file: file, line: line)
            XCTAssertLessThan(gears[3].frame.midY, dial.frame.midY + dial.frame.height * 0.23,
                              "D must remain high enough on the dial to clear the activity bar",
                              file: file, line: line)
        }

        assertCircularTransmission()
        capture("iphone-driver-centered-zero-prnd", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["driver-close"].waitForExistence(timeout: 5))
        assertCircularTransmission()
    }

    func testSummaryToolbarUsesRequestedLeftToRightOrder() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        let identifiers = ["open-driver-display", "arrange-section-summary", "update-data",
                           "open-notifications", "Settings"]
        let buttons = identifiers.map { app.buttons[$0] }
        for button in buttons {
            XCTAssertTrue(button.waitForExistence(timeout: 6), "Missing toolbar control: \(button)")
        }
        for pair in zip(buttons, buttons.dropFirst()) {
            XCTAssertLessThan(pair.0.frame.midX, pair.1.frame.midX,
                              "Summary toolbar controls must keep their requested left-to-right order")
        }
    }

    func testSummaryLastTripCardKeepsSymmetricScreenMargins() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_LANGUAGE"] = "en"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        let card = app.descendants(matching: .any)["dashboard-last-trip-card"]
        for _ in 0..<5 where !card.exists {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5), "The Summary screen should expose the Last trip card")

        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(card.frame.minX, window.minX,
                                    "The Last trip card must not overflow past the left edge")
        XCTAssertLessThanOrEqual(card.frame.maxX, window.maxX,
                                 "The Last trip card must not be clipped at the right edge")
        XCTAssertEqual(card.frame.minX - window.minX, window.maxX - card.frame.maxX, accuracy: 1,
                       "The Last trip card should keep the same screen margin on both sides")
        XCTAssertTrue(card.label.contains("Home"))
        XCTAssertTrue(card.label.contains("Work"), "The complete destination must remain visible")
    }

    func testChargingSummaryShowsAcDcDonut() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_LANGUAGE"] = "en"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["Charging"].waitForExistence(timeout: 8))
        app.buttons["Charging"].tap()
        let chart = app.descendants(matching: .any)["charging-ac-dc-chart"]
        for _ in 0..<5 where !chart.exists || !app.windows.firstMatch.frame.intersects(chart.frame) {
            app.swipeUp()
        }
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertTrue(chart.label.contains("AC"))
        XCTAssertTrue(chart.label.contains("DC"))
        XCTAssertTrue(app.windows.firstMatch.frame.intersects(chart.frame))
    }

    func testNotificationSettingsExposeADeviceTest() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_LANGUAGE"] = "es"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        let alerts = app.buttons["Avisos"]
        XCTAssertTrue(alerts.waitForExistence(timeout: 5))
        alerts.tap()
        XCTAssertTrue(app.buttons["Enviar notificación de prueba"].waitForExistence(timeout: 5))
    }

    func testNotificationInboxHasAdjacentClearAndCloseControls() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        let open = app.buttons["open-notifications"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        open.tap()

        let clear = app.buttons["clear-notifications"]
        let close = app.buttons["close-notifications"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertTrue(close.exists)
        XCTAssertGreaterThan(close.frame.midX, clear.frame.midX,
                             "Close must sit immediately to the right of the trash control")
        close.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Close must dismiss the notification window")
    }

    func testSecurityCardAlwaysShowsEveryStatusIndicator() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_LANGUAGE"] = "es"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        let identifiers = [
            "security-lock", "security-sentry", "security-occupied", "security-frunk",
            "security-trunk", "security-windows", "security-driver-front", "security-passenger-front",
            "security-driver-rear", "security-passenger-rear"
        ]
        let first = app.descendants(matching: .any)[identifiers[0]]
        for _ in 0..<8 where !first.isHittable {
            app.swipeUp()
        }

        var frames: [CGRect] = []
        for identifier in identifiers {
            let indicator = app.descendants(matching: .any)[identifier]
            for _ in 0..<4 where !indicator.exists { app.swipeUp() }
            XCTAssertTrue(
                indicator.exists,
                "Security must always expose \(identifier), including when inactive"
            )
            if indicator.exists { frames.append(indicator.frame) }
        }

        let widths = frames.map(\.width)
        let heights = frames.map(\.height)
        XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 1,
                                 "Every security tile must have the same width")
        XCTAssertLessThanOrEqual((heights.max() ?? 0) - (heights.min() ?? 0), 1,
                                 "Every security tile must have the same height")
        XCTAssertGreaterThanOrEqual(heights.min() ?? 0, 78,
                                    "Security icons and labels need comfortable vertical margins")
        XCTAssertLessThanOrEqual(widths.max() ?? .infinity, 116,
                                 "Security tiles must stay compact instead of stretching to fill the card")
        capture("iphone-security-status-grid", in: app)
    }

    func testChargingMapOpensAsAnInteractiveExpandedMap() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        tapTab(["Charging", "Cargas"], app: app)
        let expand = app.buttons["expand-map-charging"]
        XCTAssertTrue(expand.waitForExistence(timeout: 8))
        expand.tap()
        XCTAssertTrue(app.buttons["close-expanded-map"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["expand-map-charging"].isHittable,
                       "The expanded surface must replace the small map preview")
        app.buttons["close-expanded-map"].tap()
        XCTAssertTrue(app.buttons["expand-map-charging"].waitForExistence(timeout: 4))
    }

    func testDriverDisplayFallsBackToPhoneTelemetryAndKeepsHeaderVisible() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_DEMO_SCENARIO"] = "driving"
        app.launchEnvironment["TESSTATS_START_SCREEN"] = "driver"
        app.launchEnvironment["TESSTATS_FORCE_PHONE_FALLBACK"] = "1"
        app.launchEnvironment["TESSTATS_PHONE_TELEMETRY_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_DRIVER_APPEARANCE"] = "light"
        app.launchEnvironment["TESSTATS_LANGUAGE"] = "en"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["driver-close"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["driver-connection-indicator"].exists)
        XCTAssertTrue(app.staticTexts["22°C"].exists)
        // The immersive layout intentionally promotes only the tire requiring attention.
        XCTAssertTrue(elementWithLabel(parts: ["RR", "2.1 bar"], in: app).exists)
        XCTAssertTrue(app.staticTexts["28,450 km"].exists)
        XCTAssertTrue(app.staticTexts["12.4 km"].exists)
        XCTAssertEqual(app.staticTexts["driver-speed-value"].label, "74",
                       "The default +2 km/h adjustment applies to the 72 km/h GPS fixture")
        capture("driver-phone-fallback-light-portrait", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["22°C"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["12.4 km"].exists)
        XCTAssertEqual(app.staticTexts["driver-speed-value"].label, "74")
        capture("driver-phone-fallback-light-landscape", in: app)
    }

    func testDemoModeVisualSurfacesAreReachableAndReadOnly() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        XCTAssertTrue(waitForAnyText(["Sample data", "Datos de muestra", "Estos son datos de muestra"], app: app, timeout: 8))
        XCTAssertTrue(anyTextExists(["Efficiency 30d", "Efic. 30d", "Last 48h", "Últimas 48h"], app: app))
        XCTAssertFalse(app.buttons["Unlock"].exists)
        XCTAssertFalse(app.buttons["Start climate"].exists)

        tapTab(["Trips", "Viajes"], app: app)
        XCTAssertTrue(waitForAnyText(["Trips", "Viajes"], app: app, timeout: 4))
        XCTAssertTrue(anyTextExists(["Energy", "Energía", "Efficiency", "Eficiencia"], app: app))

        tapTab(["Charging", "Cargas"], app: app)
        XCTAssertTrue(waitForAnyText(["Charging", "Cargas"], app: app, timeout: 4))
        XCTAssertTrue(anyTextExists(["Costs & places", "Costes y ubicaciones", "Totals", "Totales"], app: app))

        tapTab(["Battery", "Batería"], app: app)
        XCTAssertTrue(waitForAnyText(["Battery", "Batería"], app: app, timeout: 4))
        XCTAssertTrue(anyTextExists(["Degradation", "Degradación", "Efficiency & totals", "Eficiencia y totales"], app: app))

        tapTab(["Stats", "Estadísticas"], app: app)
        XCTAssertTrue(waitForAnyText(["Stats", "Estadísticas"], app: app, timeout: 4))

        tapTab(["Trips", "Viajes"], app: app)
        let parking = app.buttons["Parking"]
        XCTAssertTrue(parking.waitForExistence(timeout: 4), "Parking must be integrated into Trips")
        parking.tap()
        XCTAssertTrue(waitForAnyText(["Parking"], app: app, timeout: 4))
    }

    func testChargingLayoutAllowsHidingAndMovingEveryBlock() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        tapTab(["Charging", "Cargas"], app: app)
        let arrange = app.buttons["arrange-section-charging"]
        XCTAssertTrue(arrange.waitForExistence(timeout: 5))
        arrange.tap()

        let listVisibility = app.buttons["layout-visibility-list"]
        XCTAssertTrue(listVisibility.waitForExistence(timeout: 3), "The main list must have a hide control")
        listVisibility.tap()
        XCTAssertTrue(app.buttons["layout-visibility-list"].waitForExistence(timeout: 2),
                      "A hidden main list must remain available to show again")
        app.buttons["layout-visibility-list"].tap()

        let moveMapUp = app.buttons["layout-up-map"]
        XCTAssertTrue(moveMapUp.waitForExistence(timeout: 2))
        let originalY = moveMapUp.frame.minY
        moveMapUp.tap()
        let movedMapUp = app.buttons["layout-up-map"]
        let didMove = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in movedMapUp.frame.minY < originalY },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [didMove], timeout: 3), .completed,
                       "Moving a block up must update its visible position")

        let reset = app.buttons["layout-reset"]
        if reset.exists { reset.tap() }
        app.buttons["layout-done"].tap()
    }

    func testTripsAndParkingShareOneFocusedTab() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        tapTab(["Trips", "Viajes"], app: app)
        XCTAssertTrue(app.descendants(matching: .any)["trips-area-picker"].waitForExistence(timeout: 5))
        let parking = app.buttons["Parking"]
        XCTAssertTrue(parking.exists)
        parking.tap()
        XCTAssertTrue(waitForAnyText(["Parking"], app: app, timeout: 4))
        XCTAssertFalse(app.buttons["more-row-supercharger"].exists,
                       "The removed More hub must not leave duplicate destinations behind")
    }

    /// Produces deterministic, demo-only reference images for release/design review.
    func testCaptureTeslaStyleGallery() {
        XCUIDevice.shared.orientation = .portrait
        let device = XCUIScreen.main.screenshot().image.size.width > 700 ? "ipad" : "iphone"

        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_DEMO_SCENARIO"] = "driving"
        app.launchEnvironment["TESSTATS_LANGUAGE"] = "es"
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        app.launch()

        XCTAssertTrue(waitForAnyText(["Datos de muestra", "Estos son datos de muestra"], app: app, timeout: 8))
        capture("\(device)-01-resumen", in: app)

        tapTab(["Estadísticas", "Stats"], app: app)
        XCTAssertTrue(waitForAnyText(["Estadísticas", "Stats"], app: app, timeout: 5))
        capture("\(device)-02-estadisticas", in: app)

        app.buttons["Settings"].tap()
        let preferences = app.buttons["settings-section-preferences"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 4))
        preferences.tap()
        let driverSettings = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Pantalla del conductor", "Equilibrado")
        ).firstMatch
        XCTAssertTrue(driverSettings.waitForExistence(timeout: 4))
        driverSettings.tap()
        XCTAssertTrue(waitForAnyText(["Preajuste", "Preset", "Minimalista", "Minimal"], app: app, timeout: 4))
        capture("\(device)-03-personalizacion", in: app)

        app.terminate()
        let driverApp = XCUIApplication()
        driverApp.launchEnvironment["TESSTATS_DEMO"] = "1"
        driverApp.launchEnvironment["TESSTATS_DEMO_SCENARIO"] = "driving"
        driverApp.launchEnvironment["TESSTATS_LANGUAGE"] = "es"
        driverApp.launchEnvironment["TESSTATS_DRIVER_APPEARANCE"] = "dark"
        driverApp.launchEnvironment["TESSTATS_START_SCREEN"] = "driver"
        driverApp.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        driverApp.launchEnvironment["TESSTATS_SCREENSHOT_MODE"] = "1"
        driverApp.launch()
        XCTAssertTrue(driverApp.buttons["driver-close"].waitForExistence(timeout: 8))
        capture("\(device)-04-conductor-vertical", in: driverApp)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(driverApp.buttons["driver-close"].waitForExistence(timeout: 5))
        capture("\(device)-05-conductor-horizontal", in: driverApp)
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        XCTAssertEqual(app.state, .runningForeground)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func localizedDemoApp(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TESSTATS_DEMO"] = "1"
        app.launchEnvironment["TESSTATS_LANGUAGE"] = language
        app.launchEnvironment["TESSTATS_SKIP_TUTORIAL"] = "1"
        return app
    }

    private func elementWithLabel(parts: [String], in app: XCUIApplication) -> XCUIElement {
        let clauses = parts.map { _ in "label CONTAINS %@" }.joined(separator: " AND ")
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: clauses, argumentArray: parts))
            .firstMatch
    }

    private func tapTab(_ labels: [String], app: XCUIApplication) {
        // Native TabView exposes its system tab buttons by localized label. Prefer that path;
        // keep the identifiers below for compatibility with older custom-navigation builds.
        for label in labels {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 1) {
                button.tap()
                return
            }
        }

        let identifiers: [String: String] = [
            "Summary": "primary-tab-summary", "Viajes": "primary-tab-trips",
            "Trips": "primary-tab-trips", "Charging": "primary-tab-charging",
            "Cargas": "primary-tab-charging", "Battery": "primary-tab-battery",
            "Batería": "primary-tab-battery", "Stats": "primary-tab-stats",
            "Estadísticas": "primary-tab-stats"
        ]
        for label in labels {
            if let identifier = identifiers[label] {
                let button = app.buttons[identifier]
                if button.waitForExistence(timeout: 1) {
                    button.tap()
                    return
                }
            }
        }

        XCTFail("Could not find tab with labels: \(labels.joined(separator: ", "))")
    }

    private func waitForAnyText(_ labels: [String], app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label IN %@", labels)
        return app.staticTexts.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }

    private func anyTextExists(_ labels: [String], app: XCUIApplication) -> Bool {
        let predicate = NSPredicate(format: "label IN %@", labels)
        return app.staticTexts.matching(predicate).firstMatch.exists
    }
}
