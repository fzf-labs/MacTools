import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MacTools

final class RightClickFileOperationsTests: XCTestCase {
    private var root: URL!
    private var sources: URL!
    private var destination: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        destination = root.appendingPathComponent("Destination", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try fm.removeItem(at: root) } }
    private func file(_ name: String, in folder: URL? = nil, content: String = "original") throws -> URL {
        let url = (folder ?? sources).appendingPathComponent(name)
        try Data(content.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    func testCopyKeepsExistingFilesAndMovesCanBeUndone() throws {
        let source = try file("Notes.txt")
        let existing = try file("Notes.txt", in: destination, content: "existing")
        let operations = RightClickFileOperations()
        let copied = try XCTUnwrap(operations.transfer(source, into: destination, collision: .keepBoth, move: false))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: copied.current, encoding: .utf8), "original")
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        let moved = try XCTUnwrap(operations.transfer(source, into: destination, collision: .keepBoth, move: true))
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        let undone = operations.undo([moved])
        XCTAssertTrue(undone.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertFalse(fm.fileExists(atPath: moved.current.path))
    }

    func testFailedReplacementRestoresDestinationAndPreservesSource() throws {
        let source = try file("Notes.txt")
        let existing = try file("Notes.txt", in: destination, content: "existing")
        let trash = root.appendingPathComponent("TestTrash")
        var operations = RightClickFileOperations()
        operations.trashItem = { url in try self.fm.moveItem(at: url, to: trash); return trash }
        operations.copyItem = { _, target in
            try Data("partial".utf8).write(to: target)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        XCTAssertThrowsError(try operations.transfer(source, into: destination, collision: .replace, move: false))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: destination.path), ["Notes.txt"])
    }

    func testCrossVolumeMoveRetainsSourceWhenCopyFailsOrSourceChanges() throws {
        let source = try file("a.txt")
        var operations = RightClickFileOperations()
        operations.forceCopyForMove = true
        operations.copyItem = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try operations.transfer(source, into: destination, collision: .keepBoth, move: true))
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        operations.copyItem = { source, target in
            try self.fm.copyItem(at: source, to: target)
            try Data("externally changed".utf8).write(to: source)
        }
        XCTAssertThrowsError(try operations.transfer(source, into: destination, collision: .keepBoth, move: true))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "externally changed")
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testCancellationKeepsCompletedItemsAndDoesNotProcessRemainingItems() throws {
        let first = try file("a.txt")
        let second = try file("b.txt")
        let cancellation = RightClickCancellation()
        let result = RightClickFileOperations().perform(.init(action: .copyTo, sources: [first, second], destination: destination), cancellation: cancellation) { count, _ in
            if count == 1 { cancellation.cancel() }
        }
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: first.path))
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("b.txt").path))
    }

    func testParentChildSelectionAndSelfDestinationDoNotDuplicateOrLoseFiles() throws {
        let child = try file("a.txt")
        let operations = RightClickFileOperations()
        XCTAssertEqual(try operations.normalizedSources([child, sources, child]), [sources])
        XCTAssertThrowsError(try operations.transfer(sources, into: sources, collision: .keepBoth, move: true))
        XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), "original")
    }

    func testUndoRefusesExternallyModifiedDestination() throws {
        let source = try file("a.txt")
        let operations = RightClickFileOperations()
        let moved = try XCTUnwrap(operations.transfer(source, into: destination, collision: .keepBoth, move: true))
        try Data("changed outside MacTools".utf8).write(to: moved.current)
        let result = operations.undo([moved])
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: moved.current, encoding: .utf8), "changed outside MacTools")
    }

    func testRenamePreviewRejectsConflictsAndSuccessfulRenameCanBeUndone() throws {
        let first = try file("draft.txt")
        _ = try file("final.txt")
        let operations = RightClickFileOperations()
        var options = RightClickRenameOptions()
        options.find = "draft"; options.replacement = "final"
        XCTAssertThrowsError(try operations.renamePreview([first], options: options))
        XCTAssertTrue(fm.fileExists(atPath: first.path))
        options.replacement = "ready"
        var plan = RightClickFilePlan(action: .rename, sources: [first])
        plan.rename = options
        let result = operations.perform(plan)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.outputs.first?.lastPathComponent, "ready.txt")
        XCTAssertTrue(operations.undo(result.undo).failures.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: first.path))
    }

    func testDissolveKeepsFolderAndSkippedChildrenOnConflict() throws {
        let child = try file("a.txt")
        _ = try file("a.txt", in: root, content: "existing")
        let result = RightClickFileOperations().perform(.init(action: .dissolve, sources: [sources], collision: .skip))
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(fm.fileExists(atPath: child.path))
        XCTAssertTrue(fm.fileExists(atPath: sources.path))
    }

    func testTemplateCreatesRealContentAndRejectsTraversalName() throws {
        let template = try file("template.docx", content: "document payload")
        var plan = RightClickFilePlan(action: .newFile, sources: [], destination: destination,
            name: "Report", fileExtension: "docx", templateURL: template)
        let result = RightClickFileOperations().perform(plan)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.outputs.first)), Data("document payload".utf8))
        plan.name = "../escape"
        XCTAssertFalse(RightClickFileOperations().perform(plan).failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("escape.docx").path))
    }

    func testImageConversionKeepsOriginalAndRejectsMultipleFrames() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try file("image.png", content: "")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: png)
        let original = try Data(contentsOf: png)
        let result = RightClickFileOperations().perform(.init(action: .convertImage, sources: [png], imageFormat: "tiff"))
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: png), original)
        XCTAssertNotEqual(result.outputs.first, png)
        let animated = sources.appendingPathComponent("animated.gif")
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(animated as CFURL, UTType.gif.identifier as CFString, 2, nil))
        let image = try XCTUnwrap(bitmap.cgImage)
        CGImageDestinationAddImage(output, image, nil)
        CGImageDestinationAddImage(output, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        let rejected = RightClickFileOperations().perform(.init(action: .convertImage, sources: [animated]))
        XCTAssertFalse(rejected.failures.isEmpty)
        XCTAssertTrue(rejected.outputs.isEmpty)
    }
}

extension RightClickFileOperationsTests {
    func testFolderUndoRefusesChangesToDescendantFile() throws {
        let child = try file("a.txt")
        let operations = RightClickFileOperations()
        let moved = try XCTUnwrap(operations.transfer(sources, into: destination, collision: .keepBoth, move: true))
        let changed = moved.current.appendingPathComponent(child.lastPathComponent)
        try Data("externally changed".utf8).write(to: changed)
        let result = operations.undo([moved])
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: changed, encoding: .utf8), "externally changed")
    }
}
