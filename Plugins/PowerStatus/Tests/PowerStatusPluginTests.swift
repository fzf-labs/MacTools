import XCTest
@testable import PowerStatusPlugin

final class PowerStatusPluginTests: XCTestCase {

    func testSnapshotEmptyDefaults() {
        let snapshot = PowerStatusSnapshot.empty

        XCTAssertEqual(snapshot.batteryPercent, 0)
        XCTAssertFalse(snapshot.isOnAC)
        XCTAssertFalse(snapshot.isCharging)
        XCTAssertFalse(snapshot.isDataAvailable)
        XCTAssertNil(snapshot.systemPowerW)
        XCTAssertEqual(snapshot.flowState, .idle)
    }

    func testPowerSourceLabelKeyMatchesFlowState() {
        XCTAssertEqual(makeSnapshot(flowState: .onAC).powerSourceLocalizationKey, "flow.source.ac")
        XCTAssertEqual(
            makeSnapshot(flowState: .charging(rateW: 10)).powerSourceLocalizationKey,
            "flow.source.charging"
        )
        XCTAssertEqual(
            makeSnapshot(flowState: .discharging(rateW: 15)).powerSourceLocalizationKey,
            "flow.source.battery"
        )
        XCTAssertEqual(
            makeSnapshot(flowState: .supplementalDischarge(rateW: 5)).powerSourceLocalizationKey,
            "flow.source.supplemental"
        )
        XCTAssertEqual(makeSnapshot(flowState: .idle).powerSourceLocalizationKey, "flow.source.idle")
    }

    func testChargingSnapshotComputedProperties() throws {
        let snapshot = makeSnapshot(
            systemPowerW: 25.0,
            acInputW: 35.0,
            isOnAC: true,
            isCharging: true,
            flowState: .charging(rateW: 10)
        )

        XCTAssertTrue(snapshot.effectiveIsOnAC)
        XCTAssertEqual(try XCTUnwrap(snapshot.effectiveACOutputW), 35.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.batteryChargeRateW, 10.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(snapshot.headerPowerW), 35.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.batteryDischargeRateW, 0, accuracy: 0.01)
    }

    func testDischargeSnapshotComputedProperties() throws {
        let snapshot = makeSnapshot(
            systemPowerW: 20.0,
            acInputW: 0,
            isOnAC: false,
            isCharging: false,
            avgTimeToEmptyMinutes: 120,
            flowState: .discharging(rateW: 20.0)
        )

        XCTAssertFalse(snapshot.effectiveIsOnAC)
        XCTAssertEqual(snapshot.batteryDischargeRateW, 20.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(snapshot.headerPowerW), 20.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.estimatedTimeRemainingMinutes, 120)
        XCTAssertEqual(snapshot.estimatedTimeRemainingText, "2h 0m")
    }

    func testSupplementalDischargeFlowState() throws {
        let snapshot = makeSnapshot(
            systemPowerW: 80.0,
            acInputW: 60.0,
            isOnAC: true,
            isCharging: false,
            flowState: .supplementalDischarge(rateW: 20.0)
        )

        XCTAssertTrue(snapshot.effectiveIsOnAC)
        XCTAssertEqual(snapshot.batteryDischargeRateW, 20.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(snapshot.headerPowerW), 80.0, accuracy: 0.01)
    }

    func testMissingTelemetryReportsChargingInsteadOfDischarge() {
        // IOKit signs Amperage positive while the pack takes charge, so a
        // charging current must not fall through as supplemental discharge
        // when PowerTelemetryData is absent or empty.
        let metrics = PowerStatusSampler.computePowerMetrics(
            telemetry: nil,
            isOnAC: true,
            isCharging: true,
            amperage: 1000,
            voltage: 10000
        )

        guard case .charging(let rateW) = metrics.flowState else {
            return XCTFail("expected charging, got \(metrics.flowState)")
        }
        XCTAssertEqual(rateW, 10.0, accuracy: 0.01)

        let emptyTelemetry = PowerStatusSampler.computePowerMetrics(
            telemetry: [:],
            isOnAC: true,
            isCharging: true,
            amperage: 1000,
            voltage: 10000
        )
        guard case .charging(let emptyRateW) = emptyTelemetry.flowState else {
            return XCTFail("expected charging for empty telemetry, got \(emptyTelemetry.flowState)")
        }
        XCTAssertEqual(emptyRateW, 10.0, accuracy: 0.01)
    }

    func testMissingTelemetryKeepsNegativeAmperageAsSupplementalDischarge() {
        // The opposite current direction has to stay distinguishable: a
        // negative reading on AC means the pack is feeding the machine.
        let metrics = PowerStatusSampler.computePowerMetrics(
            telemetry: nil,
            isOnAC: true,
            isCharging: false,
            amperage: -1000,
            voltage: 10000
        )

        guard case .supplementalDischarge(let rateW) = metrics.flowState else {
            return XCTFail("expected supplementalDischarge, got \(metrics.flowState)")
        }
        XCTAssertEqual(rateW, 10.0, accuracy: 0.01)
    }

    func testMissingTelemetryHonorsChargerFlagWithoutCurrent() {
        // No usable current; the charger flag alone has to keep the panel from
        // reporting idle while the pack is actually charging.
        let metrics = PowerStatusSampler.computePowerMetrics(
            telemetry: nil,
            isOnAC: true,
            isCharging: true,
            amperage: nil,
            voltage: nil
        )

        guard case .charging(let rateW) = metrics.flowState else {
            return XCTFail("expected charging from the charger flag, got \(metrics.flowState)")
        }
        XCTAssertEqual(rateW, 0, accuracy: 0.01)
    }

    func testOnACWithoutBatteryCurrentResolvesToOnACNotIdle() {
        // A full pack or paused charging leaves zero battery current while the
        // adapter still carries the load. That must stay `.onAC`; `.idle` is
        // only valid off power, and the diagram would otherwise draw the pack
        // as the source.
        let flow = PowerStatusSampler.resolveBatteryFlow(
            isOnAC: true,
            isChargingFlag: false,
            acInputW: 20,
            systemLoadW: 20,
            amperagePowerW: nil,
            batteryPowerFromTelemetry: 0
        )

        XCTAssertEqual(flow, .onAC)
    }

    func testMissingTelemetryChargingLeavesACInputAndSystemLoadUnavailable() {
        // The pack's charge rate is the only measured quantity. Total AC input
        // and the system draw are not established by it, so both must read as
        // unavailable rather than as a false 0 W that the header and diagram
        // would then present as a real AC output.
        let metrics = PowerStatusSampler.computePowerMetrics(
            telemetry: nil,
            isOnAC: true,
            isCharging: true,
            amperage: 1000,
            voltage: 10000
        )
        guard case .charging(let rateW) = metrics.flowState else {
            return XCTFail("expected charging, got \(metrics.flowState)")
        }
        XCTAssertEqual(rateW, 10.0, accuracy: 0.01)
        XCTAssertNil(metrics.systemPowerW)
        XCTAssertNil(metrics.acInputW)

        let snapshot = makeSnapshot(
            systemPowerW: metrics.systemPowerW,
            acInputW: metrics.acInputW,
            isOnAC: true,
            isCharging: true,
            flowState: metrics.flowState
        )
        // The charge rate is still reported on its own.
        XCTAssertEqual(snapshot.batteryChargeRateW, 10.0, accuracy: 0.01)
        XCTAssertNil(snapshot.headerPowerW)
        XCTAssertNil(snapshot.effectiveACOutputW)

        // Empty telemetry must take the same path as missing telemetry.
        let emptyTelemetry = PowerStatusSampler.computePowerMetrics(
            telemetry: [:],
            isOnAC: true,
            isCharging: true,
            amperage: 1000,
            voltage: 10000
        )
        XCTAssertNil(emptyTelemetry.systemPowerW)
        XCTAssertNil(emptyTelemetry.acInputW)
    }

    func testMissingTelemetryDischargingStillDerivesSystemLoadFromPackRate() {
        // Off power the pack is the only source, so its rate does establish the
        // system draw; there is no adapter input to report either way.
        let metrics = PowerStatusSampler.computePowerMetrics(
            telemetry: nil,
            isOnAC: false,
            isCharging: false,
            amperage: -1000,
            voltage: 10000
        )

        guard case .discharging = metrics.flowState else {
            return XCTFail("expected discharging, got \(metrics.flowState)")
        }
        XCTAssertEqual(metrics.systemPowerW ?? -1, 10.0, accuracy: 0.01)
        XCTAssertEqual(metrics.acInputW, 0)
    }

    func testMeasuredZeroStaysDistinctFromUnavailable() {
        // Telemetry reporting a real 0 W system load has to stay a measured
        // zero; only a reading that could not be established becomes nil.
        let metrics = PowerStatusSampler.computePowerMetrics(
            telemetry: [
                "SystemLoad": 0,
                "SystemPowerIn": 20_000,
                "BatteryPower": 20_000,
            ],
            isOnAC: true,
            isCharging: true,
            amperage: 2_000,
            voltage: 10_000
        )

        XCTAssertEqual(metrics.systemPowerW, 0)
        XCTAssertEqual(metrics.acInputW, 20.0)
    }

    func testUnpluggedWithSystemLoadResolvesToDischarging() {
        // Right after unplugging, BatteryPower and Amperage can still read zero
        // for one sample while the pack is already carrying the system.
        let flow = PowerStatusSampler.resolveBatteryFlow(
            isOnAC: false,
            isChargingFlag: false,
            acInputW: 0,
            systemLoadW: 14.3,
            amperagePowerW: nil,
            batteryPowerFromTelemetry: 0
        )

        guard case .discharging(let rateW) = flow else {
            return XCTFail("expected discharging, got \(flow)")
        }
        XCTAssertEqual(rateW, 14.3, accuracy: 0.01)
    }

    func testUnpluggedPrefersBatteryTelemetryForDischargeRate() {
        let flow = PowerStatusSampler.resolveBatteryFlow(
            isOnAC: false,
            isChargingFlag: false,
            acInputW: 0,
            systemLoadW: 14.3,
            amperagePowerW: nil,
            batteryPowerFromTelemetry: -14.3
        )

        guard case .discharging(let rateW) = flow else {
            return XCTFail("expected discharging, got \(flow)")
        }
        XCTAssertEqual(rateW, 14.3, accuracy: 0.01)
    }

    func testIdleOnlyWhenOffPowerAndDrawingNothing() {
        let flow = PowerStatusSampler.resolveBatteryFlow(
            isOnAC: false,
            isChargingFlag: false,
            acInputW: 0,
            systemLoadW: 0,
            amperagePowerW: nil,
            batteryPowerFromTelemetry: 0
        )

        XCTAssertEqual(flow, .idle)
    }

    func testBatteryHealthUsesDesignCapacityNotPercentage() {
        // Top-level MaxCapacity is a normalized 0-100 percentage on Apple
        // silicon; reading it as milliamps collapses health to a rounding error.
        let props: [String: Any] = [
            "MaxCapacity": 100,
            "BatteryData": [
                "DesignCapacity": 6075,
                "FullChargeCapacity": 5155,
                "RemainingCapacity": 4967,
            ] as [String: Any],
        ]

        let snapshot = PowerStatusSampler.readBatteryCapacitySnapshot(from: props)

        // 5155 / 6075 = 84.9%, which rounds up to 85% the way macOS reports it.
        XCTAssertEqual(snapshot.healthPercent, 85)
        XCTAssertEqual(snapshot.designCapacityMAH, 6075)
        XCTAssertEqual(snapshot.fullChargeCapacityMAH, 5155)
        XCTAssertNil(snapshot.rawMaxCapacityMAH)
    }

    func testBatteryHealthPrefersCompensatedCapacityFromPackNode() {
        // System Settings' "Maximum Capacity" is FccComp1 ÷ DesignCapacity, and
        // on Apple Silicon FccComp1 lives on AppleSmartBatteryPack, not on the
        // battery node that the raw milliamp readings come from.
        let props: [String: Any] = [
            "BatteryData": [
                "DesignCapacity": 6075,
                "FullChargeCapacity": 5179,
            ] as [String: Any],
        ]
        let packProps: [String: Any] = [
            "BatteryData": [
                "DesignCapacity": 6075,
                "FccComp1": 5401,
                "AppleRawMaxCapacity": 5179,
            ] as [String: Any],
        ]

        let snapshot = PowerStatusSampler.readBatteryCapacitySnapshot(
            from: props,
            packProps: packProps
        )

        XCTAssertEqual(snapshot.healthPercent, 89)
        XCTAssertEqual(snapshot.fullChargeCapacityMAH, 5401)
        XCTAssertEqual(snapshot.rawMaxCapacityMAH, 5179)
    }

    func testBatteryHealthRoundsUpInsteadOfTruncating() {
        // 5376 / 6075 = 88.49%: truncating gives 88% and rounding to nearest
        // also gives 88%, while System Settings reports 89%. Only rounding up
        // matches, and this is the live reading on the test machine.
        let props: [String: Any] = [
            "BatteryData": [
                "DesignCapacity": 6075,
                "FccComp1": 5376,
            ] as [String: Any],
        ]

        let snapshot = PowerStatusSampler.readBatteryCapacitySnapshot(from: props)

        XCTAssertEqual(snapshot.healthPercent, 89)
    }

    func testBatteryHealthReportsNinetyPercentFromRawMaxCapacity() {
        let props: [String: Any] = [
            "MaxCapacity": 100,
            "BatteryData": [
                "DesignCapacity": 5000,
                "AppleRawMaxCapacity": 4500,
            ] as [String: Any],
        ]

        let snapshot = PowerStatusSampler.readBatteryCapacitySnapshot(from: props)

        XCTAssertEqual(snapshot.healthPercent, 90)
        XCTAssertEqual(snapshot.rawMaxCapacityMAH, 4500)
    }

    func testBatteryHealthFallsBackToNominalChargeCapacity() {
        // Some machines report neither AppleRawMaxCapacity nor
        // FullChargeCapacity; NominalChargeCapacity is still a real mAh value.
        let props: [String: Any] = [
            "BatteryData": [
                "DesignCapacity": 5000,
                "NominalChargeCapacity": 4000,
            ] as [String: Any],
        ]

        let snapshot = PowerStatusSampler.readBatteryCapacitySnapshot(from: props)

        XCTAssertEqual(snapshot.healthPercent, 80)
        XCTAssertEqual(snapshot.fullChargeCapacityMAH, 4000)
    }

    func testBatteryCapacityReadsTopLevelWhenBatteryDataAbsent() {
        let props: [String: Any] = [
            "MaxCapacity": 100,
            "DesignCapacity": 5000,
            "FullChargeCapacity": 4800,
            "Temperature": 3150,
        ]

        let snapshot = PowerStatusSampler.readBatteryCapacitySnapshot(from: props)

        XCTAssertEqual(snapshot.designCapacityMAH, 5000)
        XCTAssertEqual(snapshot.fullChargeCapacityMAH, 4800)
        XCTAssertEqual(snapshot.healthPercent, 96)
        XCTAssertEqual(snapshot.temperatureCentidegrees, 3150)
    }

    func testEstimatedTimeFormatting() {
        let snapshot1 = makeSnapshot(
            avgTimeToEmptyMinutes: 45,
            flowState: .discharging(rateW: 10)
        )
        XCTAssertEqual(snapshot1.estimatedTimeRemainingText, "45m")

        let snapshot2 = makeSnapshot(
            avgTimeToEmptyMinutes: 125,
            flowState: .discharging(rateW: 10)
        )
        XCTAssertEqual(snapshot2.estimatedTimeRemainingText, "2h 5m")

        let snapshot3 = makeSnapshot(
            avgTimeToEmptyMinutes: 0,
            flowState: .discharging(rateW: 10)
        )
        XCTAssertNil(snapshot3.estimatedTimeRemainingText)
    }

    func testEstimatedTimeLabelKeyMatchesFlowState() {
        // Charging always reports time to full.
        XCTAssertEqual(
            makeSnapshot(flowState: .charging(rateW: 5)).estimatedTimeLabelKey,
            "metric.timeToFull"
        )

        // A valid macOS average is reported as remaining time.
        XCTAssertEqual(
            makeSnapshot(avgTimeToEmptyMinutes: 120, flowState: .discharging(rateW: 12)).estimatedTimeLabelKey,
            "metric.timeEstimate.remaining"
        )

        // Without one, the estimate is computed locally and labelled as such.
        XCTAssertEqual(
            makeSnapshot(
                batteryVoltageMV: 12_000,
                remainingCapacityMAH: 3_000,
                flowState: .discharging(rateW: 12)
            ).estimatedTimeLabelKey,
            "metric.timeEstimate.computed"
        )

        // No time estimate applies on AC or while idle.
        XCTAssertNil(makeSnapshot(flowState: .onAC).estimatedTimeLabelKey)
        XCTAssertNil(makeSnapshot(flowState: .idle).estimatedTimeLabelKey)
    }

    func testComputedTimeToEmptyFallsBackWhenMacOSSilent() {
        // macOS reports no AvgTimeToEmpty; estimate from remaining energy.
        let snapshot = makeSnapshot(
            batteryPercent: 50,
            batteryVoltageMV: 12_000,
            fullChargeCapacityMAH: 4_000,
            avgTimeToEmptyMinutes: nil,
            remainingCapacityMAH: 2_000,
            flowState: .discharging(rateW: 20.0)
        )

        // 2000 mAh × 12 V = 24 Wh; 24 Wh / 20 W = 1.2 h = 72 min.
        XCTAssertEqual(snapshot.remainingEnergyWh ?? 0, 24.0, accuracy: 0.01)
        XCTAssertNotNil(snapshot.estimatedTimeRemainingMinutes)
        XCTAssertEqual(snapshot.estimatedTimeRemainingMinutes ?? 0, 72, accuracy: 1)
        XCTAssertEqual(snapshot.estimatedTimeRemainingText, "1h 12m")
        XCTAssertTrue(snapshot.estimatedTimeIsComputed)
        XCTAssertEqual(snapshot.estimatedTimeLabelKey, "metric.timeEstimate.computed")
    }

    func testEstimatedTimeUsesMacOSValueWhenAvailable() {
        let snapshot = makeSnapshot(
            batteryPercent: 50,
            batteryVoltageMV: 12_000,
            avgTimeToEmptyMinutes: 90,
            remainingCapacityMAH: 2_000,
            flowState: .discharging(rateW: 20.0)
        )

        XCTAssertEqual(snapshot.estimatedTimeRemainingMinutes, 90)
        XCTAssertFalse(snapshot.estimatedTimeIsComputed)
        XCTAssertEqual(snapshot.estimatedTimeLabelKey, "metric.timeEstimate.remaining")
    }

    func testNoTimeEstimateWhileOnAC() {
        let snapshot = makeSnapshot(
            isOnAC: true,
            batteryVoltageMV: 12_000,
            avgTimeToEmptyMinutes: nil,
            remainingCapacityMAH: 2_000,
            flowState: .onAC
        )

        XCTAssertNil(snapshot.estimatedTimeRemainingMinutes)
        XCTAssertFalse(snapshot.estimatedTimeIsComputed)
    }

    func testRemainingEnergyFallsBackToCapacityScaledByPercent() {
        let snapshot = makeSnapshot(
            batteryPercent: 40,
            batteryVoltageMV: 11_000,
            fullChargeCapacityMAH: 5_000,
            flowState: .discharging(rateW: 10.0)
        )

        // 5000 mAh × 40% × 11 V = 22 Wh
        XCTAssertEqual(snapshot.remainingEnergyWh ?? 0, 22.0, accuracy: 0.01)
    }

    func testSmoothedDischargePowersLocalEstimate() {
        let snapshot = makeSnapshot(
            batteryVoltageMV: 12_000,
            remainingCapacityMAH: 3_000,
            flowState: .discharging(rateW: 20.0)
        )
        var smoothed = snapshot
        smoothed.smoothedDischargePowerW = 15.0

        // 36 Wh / 15 W = 2.4 h = 144 min — the smoothed value drives the estimate.
        XCTAssertEqual(smoothed.estimatedTimeRemainingMinutes ?? 0, 144, accuracy: 1)
    }

    func testFlowDiagramRowCountMatchesFlowState() {
        XCTAssertEqual(
            PowerStatusLayout.flowDiagramRowCount(for: makeSnapshot(flowState: .onAC)),
            1
        )
        XCTAssertEqual(
            PowerStatusLayout.flowDiagramRowCount(for: makeSnapshot(flowState: .discharging(rateW: 15))),
            1
        )
        XCTAssertEqual(
            PowerStatusLayout.flowDiagramRowCount(
                for: makeSnapshot(isOnAC: true, isCharging: true, flowState: .charging(rateW: 12))
            ),
            2
        )
        XCTAssertEqual(
            PowerStatusLayout.flowDiagramRowCount(for: makeSnapshot(flowState: .supplementalDischarge(rateW: 8))),
            2
        )
        XCTAssertEqual(
            PowerStatusLayout.flowDiagramRowCount(for: makeSnapshot(isDataAvailable: false)),
            0
        )
    }

    func testContentHeightGrowsWithDiagramRows() {
        let oneRow = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 7,
            voltageCurrentTileCount: 4,
            isDataAvailable: true
        )
        let twoRows = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 2,
            capacityTileCount: 7,
            voltageCurrentTileCount: 4,
            isDataAvailable: true
        )

        let expectedDelta = PowerStatusLayout.flowRowHeight + PowerStatusLayout.flowRowSpacing
        XCTAssertEqual(twoRows - oneRow, expectedDelta, accuracy: 0.5)
        XCTAssertGreaterThan(oneRow, 0)
    }

    func testContentHeightGrowsWithCapacityTiles() {
        let fewTiles = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 1,
            voltageCurrentTileCount: 0,
            isDataAvailable: true
        )
        let manyTiles = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 8,
            voltageCurrentTileCount: 0,
            isDataAvailable: true
        )

        XCTAssertGreaterThan(manyTiles, fewTiles)
    }

    func testFullyChargedTileShownOnlyWhileStillOnPower() {
        let charged = makeSnapshot(batteryPercent: 100, isOnAC: true, fullyCharged: true, flowState: .onAC)
        XCTAssertTrue(charged.showFullyCharged)

        let charging = makeSnapshot(
            batteryPercent: 100,
            isOnAC: true,
            isCharging: true,
            fullyCharged: true,
            flowState: .charging(rateW: 2)
        )
        XCTAssertTrue(charging.showFullyCharged)

        // A full pack on battery power still wants the discharge estimate.
        let discharging = makeSnapshot(batteryPercent: 100, flowState: .discharging(rateW: 12))
        XCTAssertFalse(discharging.showFullyCharged)

        let partial = makeSnapshot(batteryPercent: 80, isOnAC: true, flowState: .charging(rateW: 15))
        XCTAssertFalse(partial.showFullyCharged)
    }

    func testTelemetryTileCountsMatchAvailableData() {
        let bare = makeSnapshot(flowState: .onAC)
        XCTAssertFalse(bare.hasVoltageCurrentDetail)
        XCTAssertEqual(PowerStatusLayout.capacityTileCount(for: bare), 0)
        XCTAssertEqual(PowerStatusLayout.voltageCurrentTileCount(for: bare), 0)

        let full = makeSnapshot(
            batteryVoltageMV: 12_000,
            batteryAmperageMA: -800,
            batteryTemperatureC: 31.5,
            cycleCount: 240,
            batteryHealthPercent: 84,
            remainingCapacityMAH: 3_000,
            flowState: .discharging(rateW: 12)
        )
        XCTAssertTrue(full.hasVoltageCurrentDetail)
        // Voltage and current only; no charging readings off power.
        XCTAssertEqual(PowerStatusLayout.voltageCurrentTileCount(for: full), 2)
        // Remaining capacity, health, cycles, temperature, and the discharge
        // time estimate, which resolves from 36 Wh of remaining energy.
        XCTAssertEqual(PowerStatusLayout.capacityTileCount(for: full), 5)
    }

    func testCapacityReadingsShareOneTileForHeight() {
        // Full-charge and design capacity render in a single merged tile, so
        // supplying both must not add a row to the panel height.
        let designOnly = makeSnapshot(designCapacityMAH: 6_075, flowState: .onAC)
        let merged = makeSnapshot(
            designCapacityMAH: 6_075,
            fullChargeCapacityMAH: 5_374,
            flowState: .onAC
        )

        XCTAssertEqual(
            PowerStatusLayout.capacityTileCount(for: merged),
            PowerStatusLayout.capacityTileCount(for: designOnly)
        )
        XCTAssertEqual(PowerStatusLayout.capacityTileCount(for: designOnly), 1)
    }

    // MARK: - App energy readings

    func testAppEnergyDeltaConvertsNanojoulesToWatts() {
        let previous: [Int32: UInt64] = [
            10: 1_000_000_000,
            20: 500_000_000,
            30: 2_000_000_000,
        ]
        let current: [Int32: UInt64] = [
            10: 3_000_000_000, // +2 J over 2 s = 1 W
            20: 400_000_000,   // counter went backwards (reused PID) = no reading
            30: 2_500_000_000, // +0.5 J over 2 s = 0.25 W
            40: 9_000_000_000, // no baseline yet
        ]

        let watts = PowerStatusAppEnergyMath.watts(previous: previous, current: current, elapsed: 2)

        XCTAssertEqual(watts[10] ?? -1, 1.0, accuracy: 0.001)
        XCTAssertNil(watts[20])
        XCTAssertEqual(watts[30] ?? -1, 0.25, accuracy: 0.001)
        XCTAssertNil(watts[40])
    }

    func testAppEnergyRankingKeepsFiveHeaviestAboveThreshold() {
        let apps = [
            PowerStatusAppEnergyReading(id: "a", name: "Alpha", watts: 0.05),
            PowerStatusAppEnergyReading(id: "b", name: "Bravo", watts: 1.20),
            PowerStatusAppEnergyReading(id: "c", name: "Charlie", watts: 0.30),
            PowerStatusAppEnergyReading(id: "d", name: "Delta", watts: 0.90),
            PowerStatusAppEnergyReading(id: "e", name: "Echo", watts: 0.60),
            PowerStatusAppEnergyReading(id: "f", name: "Foxtrot", watts: 0.40),
            PowerStatusAppEnergyReading(id: "g", name: "Golf", watts: 0.01),
        ]

        let ranked = PowerStatusAppEnergyMath.rankedReadings(apps)

        XCTAssertEqual(ranked.map(\.name), ["Bravo", "Delta", "Echo", "Foxtrot", "Charlie"])
        XCTAssertFalse(ranked.contains { $0.id == "g" })
    }

    func testAppEnergyWattsFormattingUsesExtraPrecisionBelowOneWatt() {
        XCTAssertEqual(PowerStatusValueText.energyWatts(1.24), "1.2 W")
        XCTAssertEqual(PowerStatusValueText.energyWatts(0.126), "0.13 W")
        XCTAssertEqual(PowerStatusValueText.energyWatts(nil), PowerStatusValueText.unavailable)
    }

    // MARK: - Component sensors

    func testSensorTemperatureKeysMapToComponents() {
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "Tp1A"), .cpu)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "Te05"), .cpu)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "TC0P"), .cpu)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "Tg0X"), .gpu)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "TG0D"), .gpu)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "TRD0"), .memory)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "TM0P"), .memory)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "TH0x"), .storage)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "TB0T"), .battery)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "TPD0"), .mainboard)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "Ts0P"), .mainboard)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "Ta0P"), .ambient)
        XCTAssertEqual(PowerStatusSensorMath.component(forTemperatureKey: "TW0P"), .wireless)
        XCTAssertNil(PowerStatusSensorMath.component(forTemperatureKey: "Tf04"))
        XCTAssertNil(PowerStatusSensorMath.component(forTemperatureKey: "PSTR"))
    }

    func testSensorTemperatureValidityRejectsUnpopulatedSiliconSensors() {
        // Some P-core keys report single-digit values before the die warms up.
        XCTAssertFalse(PowerStatusSensorMath.isValidTemperature(6.7, for: .cpu))
        XCTAssertTrue(PowerStatusSensorMath.isValidTemperature(46.2, for: .cpu))
        XCTAssertTrue(PowerStatusSensorMath.isValidTemperature(9.5, for: .ambient))
        XCTAssertFalse(PowerStatusSensorMath.isValidTemperature(0, for: .battery))
        XCTAssertFalse(PowerStatusSensorMath.isValidTemperature(130, for: .gpu))
    }

    func testNeuralEngineRowIsHiddenBeforeM3() {
        XCTAssertFalse(PowerStatusSensorMath.supportsNeuralEngineComponent(chipName: "Apple M1"))
        XCTAssertFalse(PowerStatusSensorMath.supportsNeuralEngineComponent(chipName: "Apple M2 Max"))
        XCTAssertFalse(PowerStatusSensorMath.supportsNeuralEngineComponent(chipName: "Intel(R) Core(TM) i7"))
        XCTAssertFalse(PowerStatusSensorMath.supportsNeuralEngineComponent(chipName: nil))
        XCTAssertTrue(PowerStatusSensorMath.supportsNeuralEngineComponent(chipName: "Apple M3"))
        XCTAssertTrue(PowerStatusSensorMath.supportsNeuralEngineComponent(chipName: "Apple M4 Pro"))
    }

    func testSensorPowerChannelsMapOnlyAggregateComponents() {
        XCTAssertEqual(PowerStatusSensorMath.component(forPowerChannel: "CPU Energy"), .cpu)
        XCTAssertEqual(PowerStatusSensorMath.component(forPowerChannel: "GPU Energy"), .gpu)
        XCTAssertEqual(PowerStatusSensorMath.component(forPowerChannel: "DRAM0"), .memory)
        XCTAssertEqual(PowerStatusSensorMath.component(forPowerChannel: "DRAM1"), .memory)
        XCTAssertEqual(PowerStatusSensorMath.component(forPowerChannel: "ANE0"), .neuralEngine)
        // Per-cluster and SRAM counters would double count the aggregate.
        XCTAssertNil(PowerStatusSensorMath.component(forPowerChannel: "PACC0_CPU"))
        XCTAssertNil(PowerStatusSensorMath.component(forPowerChannel: "GPU0"))
        XCTAssertNil(PowerStatusSensorMath.component(forPowerChannel: "GPU SRAM0"))
    }

    func testSensorEnergyUnitsConvertToJoules() {
        XCTAssertEqual(PowerStatusSensorMath.joules(from: 2, unit: "J") ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(PowerStatusSensorMath.joules(from: 2_000, unit: "mJ") ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(PowerStatusSensorMath.joules(from: 2_000_000, unit: "uJ") ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(
            PowerStatusSensorMath.joules(from: 2_000_000_000, unit: "nJ") ?? -1,
            2,
            accuracy: 0.001
        )
        XCTAssertNil(PowerStatusSensorMath.joules(from: 2, unit: "W"))
        XCTAssertNil(PowerStatusSensorMath.joules(from: -1, unit: "J"))
    }

    func testSensorPowerWattsUsesEnergyDeltasAndDropsInvalidCounters() {
        let previous: [PowerStatusSensorComponent: Double] = [
            .cpu: 10,
            .memory: 5,
        ]
        let current: [PowerStatusSensorComponent: Double] = [
            .cpu: 14,     // +4 J over 2 s = 2 W
            .memory: 4,   // counter went backwards = no reading
            .gpu: 8,      // no baseline yet
        ]

        let watts = PowerStatusSensorMath.watts(
            previous: previous,
            current: current,
            elapsed: 2
        )

        XCTAssertEqual(watts[.cpu] ?? -1, 2.0, accuracy: 0.001)
        XCTAssertNil(watts[.memory])
        XCTAssertNil(watts[.gpu])
    }

    func testSensorMemoryPowerTreatsZeroAsUnavailable() {
        XCTAssertEqual(
            PowerStatusSensorMath.memoryPowerWatts(energyModel: 1.2, smcFallback: 0.8) ?? -1,
            1.2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PowerStatusSensorMath.memoryPowerWatts(energyModel: 0, smcFallback: 0.8) ?? -1,
            0.8,
            accuracy: 0.001
        )
        XCTAssertNil(PowerStatusSensorMath.memoryPowerWatts(energyModel: 0, smcFallback: nil))
        XCTAssertNil(PowerStatusSensorMath.memoryPowerWatts(energyModel: nil, smcFallback: 0))
    }

    func testSensorLayoutHeightGrowsWithExpandedRows() {
        let collapsed = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 7,
            voltageCurrentTileCount: 4,
            sensorRowCount: 9,
            isSensorsExpanded: false,
            isDataAvailable: true
        )
        let expanded = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 7,
            voltageCurrentTileCount: 4,
            sensorRowCount: 9,
            isSensorsExpanded: true,
            isDataAvailable: true
        )

        XCTAssertGreaterThan(expanded, collapsed)
        XCTAssertEqual(
            expanded - collapsed,
            PowerStatusLayout.sectionHeaderContent
                + PowerStatusLayout.sensorTableHeaderHeight
                + PowerStatusLayout.sensorRowSpacing
                + 9 * PowerStatusLayout.sensorRowHeight
                + 8 * PowerStatusLayout.sensorRowSpacing,
            accuracy: 0.5
        )
    }

    func testEnergyAppsLayoutHeightGrowsOnlyWhenExpanded() {
        let collapsed = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 7,
            voltageCurrentTileCount: 4,
            energyAppCount: 5,
            isEnergyAppsExpanded: false,
            isDataAvailable: true
        )
        let collapsedWithoutRows = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 7,
            voltageCurrentTileCount: 4,
            energyAppCount: 0,
            isEnergyAppsExpanded: false,
            isDataAvailable: true
        )
        let expanded = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 7,
            voltageCurrentTileCount: 4,
            energyAppCount: 5,
            isEnergyAppsExpanded: true,
            isDataAvailable: true
        )
        let expandedWithoutRows = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 7,
            voltageCurrentTileCount: 4,
            energyAppCount: 0,
            isEnergyAppsExpanded: true,
            isDataAvailable: true
        )

        XCTAssertEqual(collapsed, collapsedWithoutRows, accuracy: 0.5)
        XCTAssertGreaterThan(expanded, collapsed)
        XCTAssertEqual(
            expanded - collapsed,
            PowerStatusLayout.sectionHeaderContent
                + 5 * PowerStatusLayout.appEnergyRowHeight
                + 4 * PowerStatusLayout.rowVertical,
            accuracy: 0.5
        )
        XCTAssertEqual(
            expandedWithoutRows - collapsed,
            PowerStatusLayout.sectionHeaderContent + PowerStatusLayout.appEnergyRowHeight,
            accuracy: 0.5
        )
    }

    // MARK: - Helpers

    private func makeSnapshot(
        systemPowerW: Double? = nil,
        acInputW: Double? = nil,
        acAdapterWattage: Int = 0,
        batteryPercent: Int = 0,
        isOnAC: Bool = false,
        isCharging: Bool = false,
        fullyCharged: Bool = false,
        batteryVoltageMV: Int? = nil,
        batteryAmperageMA: Int? = nil,
        batteryTemperatureC: Double? = nil,
        cycleCount: Int? = nil,
        batteryHealthPercent: Int? = nil,
        designCapacityMAH: Int? = nil,
        fullChargeCapacityMAH: Int? = nil,
        chargingVoltageMV: Int? = nil,
        chargingCurrentMA: Int? = nil,
        avgTimeToEmptyMinutes: Int? = nil,
        avgTimeToFullMinutes: Int? = nil,
        remainingCapacityMAH: Int? = nil,
        flowState: PowerFlowState = .idle,
        isDataAvailable: Bool = true
    ) -> PowerStatusSnapshot {
        PowerStatusSnapshot(
            timestamp: Date(),
            systemPowerW: systemPowerW,
            acInputW: acInputW,
            acAdapterWattage: acAdapterWattage,
            batteryPercent: batteryPercent,
            isOnAC: isOnAC,
            isCharging: isCharging,
            fullyCharged: fullyCharged,
            batteryVoltageMV: batteryVoltageMV,
            batteryAmperageMA: batteryAmperageMA,
            batteryTemperatureC: batteryTemperatureC,
            cycleCount: cycleCount,
            batteryHealthPercent: batteryHealthPercent,
            designCapacityMAH: designCapacityMAH,
            fullChargeCapacityMAH: fullChargeCapacityMAH,
            chargingVoltageMV: chargingVoltageMV,
            chargingCurrentMA: chargingCurrentMA,
            avgTimeToEmptyMinutes: avgTimeToEmptyMinutes,
            avgTimeToFullMinutes: avgTimeToFullMinutes,
            remainingCapacityMAH: remainingCapacityMAH,
            flowState: flowState,
            isDataAvailable: isDataAvailable,
            smoothedDischargePowerW: nil
        )
    }
}
