import XCTest
import ZippCore
@testable import Zipp

final class ArchiveTypesTests: XCTestCase {
    func testBaseName() {
        XCTAssertEqual(ArchiveTypes.baseName(of: URL(fileURLWithPath: "/x/Projekt.tar.gz")), "Projekt")
        XCTAssertEqual(ArchiveTypes.baseName(of: URL(fileURLWithPath: "/x/Setup.part1.rar")), "Setup")
        XCTAssertEqual(ArchiveTypes.baseName(of: URL(fileURLWithPath: "/x/Fotos 2026.zip")), "Fotos 2026")
        XCTAssertEqual(ArchiveTypes.baseName(of: URL(fileURLWithPath: "/x/notiz.txt")), "notiz.txt")
        XCTAssertEqual(ArchiveTypes.baseName(of: URL(fileURLWithPath: "/x/Film.part03.rar")), "Film")
        XCTAssertEqual(ArchiveTypes.baseName(of: URL(fileURLWithPath: "/x/Fotos.7z.002")), "Fotos")
        XCTAssertEqual(ArchiveTypes.logicalName(of: URL(fileURLWithPath: "/x/Fotos.7z.002")), "Fotos.7z")
    }

    func testLikelyArchive() {
        XCTAssertTrue(ArchiveTypes.isLikelyArchive(URL(fileURLWithPath: "/a.ZIP")))
        XCTAssertTrue(ArchiveTypes.isLikelyArchive(URL(fileURLWithPath: "/a.tar.zst")))
        XCTAssertTrue(ArchiveTypes.isLikelyArchive(URL(fileURLWithPath: "/a.7z.001")))
        XCTAssertTrue(ArchiveTypes.isLikelyArchive(URL(fileURLWithPath: "/a.r00")))
        XCTAssertFalse(ArchiveTypes.isLikelyArchive(URL(fileURLWithPath: "/a.pdf")))
    }

    func testUniqueArchiveURLRespectsVolumes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("Fotos.7z.001"))
        XCTAssertEqual(FileNaming.uniqueArchiveURL(folder: dir, name: "Fotos", ext: "7z", split: false).lastPathComponent, "Fotos.7z")
        XCTAssertEqual(FileNaming.uniqueArchiveURL(folder: dir, name: "Fotos", ext: "7z", split: true).lastPathComponent, "Fotos 2.7z")
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("1.2.10", than: "1.2.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0-beta", than: "1.0.0"))
    }

    func testUniqueURL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.tar.gz")
        XCTAssertEqual(FileNaming.uniqueURL(file), file)
        try Data().write(to: file)
        XCTAssertEqual(FileNaming.uniqueURL(file).lastPathComponent, "a 2.tar.gz")
    }
}

final class ArchiveNodeTests: XCTestCase {
    private func entry(_ path: String, dir: Bool = false, size: UInt64 = 10, packed: UInt64? = 5) -> ArchiveEntry {
        ArchiveEntry(path: path, isDir: dir, isSymlink: false, size: size, packedSize: packed, crc32: nil,
                     modified: 1_700_000_000, encrypted: false, method: nil, unixMode: nil)
    }

    func testTreeWithImplicitFolders() {
        let root = ArchiveNode.buildTree(from: [
            entry("b.txt"),
            entry("docs/a.txt"),
            entry("docs/sub/c.txt", size: 30, packed: 10),
            entry("empty", dir: true, size: 0, packed: nil),
        ], rootName: "test.zip")

        XCTAssertEqual(root.children.map(\.name), ["docs", "empty", "b.txt"], "Ordner zuerst, dann Dateien")
        XCTAssertEqual(root.fileCount, 3)
        XCTAssertEqual(root.totalSize, 50)
        XCTAssertEqual(root.totalPacked, 20)
        let docs = root.find(path: "docs")
        XCTAssertEqual(docs?.isDirectory, true)
        XCTAssertEqual(docs?.totalSize, 40)
        XCTAssertEqual(root.find(path: "docs/sub/c.txt")?.parentPath, "docs/sub")
        XCTAssertEqual(docs?.savingsPercent, 63)
        XCTAssertEqual(root.descendants(matching: "c.t", limit: 10).map(\.path), ["docs/sub/c.txt"])
    }
}

/// Prüft, dass der Rust-Kern korrekt eingebunden ist (Brücke, Fehler, Fortschritt).
final class CoreBridgeTests: XCTestCase {
    func testCreateListExtractRoundtrip() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zipp-test-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Ordner")
        try fm.createDirectory(at: source.appendingPathComponent("innen"), withIntermediateDirectories: true)
        try "Hallo".write(to: source.appendingPathComponent("innen/datei.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }

        let archive = dir.appendingPathComponent("test.7z")
        let relay = ProgressRelay()
        let summary = try createArchive(
            sources: [source.path], destination: archive.path,
            options: CreateOptions(format: .sevenZip, level: 6, password: "geheim",
                                   encryptFileNames: true, excludeMacMetadata: true, volumeSize: nil),
            progress: relay
        )
        XCTAssertEqual(summary.files, 1)
        XCTAssertEqual(try detectFormat(path: archive.path), .sevenZip)

        XCTAssertThrowsError(try listArchive(path: archive.path, password: nil)) { error in
            XCTAssertEqual(error as? ZippError, .PasswordRequired)
        }
        let listing = try listArchive(path: archive.path, password: "geheim")
        XCTAssertTrue(listing.headerEncrypted)
        XCTAssertEqual(listing.singleRootFolder, "Ordner")

        let out = dir.appendingPathComponent("out")
        _ = try extractArchive(
            path: archive.path, destination: out.path,
            options: ExtractOptions(password: "geheim", selection: [], stripPrefix: nil,
                                    overwrite: .keepBoth, applyQuarantine: true),
            progress: relay
        )
        let text = try String(contentsOf: out.appendingPathComponent("Ordner/innen/datei.txt"), encoding: .utf8)
        XCTAssertEqual(text, "Hallo")
    }

    func testEditSplitAndPasswordCheck() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zipp-edit-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Daten")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 300_000)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: source.appendingPathComponent("zufall.bin"))
        try "A".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }
        let relay = ProgressRelay()

        // Aufgeteiltes, verschlüsseltes 7z
        let archive = dir.appendingPathComponent("teile.7z")
        let summary = try createArchive(
            sources: [source.path], destination: archive.path,
            options: CreateOptions(format: .sevenZip, level: 0, password: "pw", encryptFileNames: false,
                                   excludeMacMetadata: true, volumeSize: minVolumeSize()),
            progress: relay
        )
        XCTAssertGreaterThan(summary.outputs.count, 1)
        let last = summary.outputs.last!
        XCTAssertEqual(firstVolume(path: last), summary.outputs[0])
        XCTAssertEqual(archiveVolumes(path: last).count, summary.outputs.count)
        let listing = try listArchive(path: last, password: nil)
        XCTAssertEqual(listing.volumeCount, UInt32(summary.outputs.count))
        XCTAssertFalse(listing.supportsEditing, "Mehrteilige Archive sind nur lesbar")
        XCTAssertTrue(try checkPassword(path: last, password: "pw"))
        XCTAssertFalse(try checkPassword(path: last, password: "falsch"))

        // Konvertieren nach ZIP, dann umbenennen und Ordner anlegen
        let zip = dir.appendingPathComponent("ganz.zip")
        _ = try convertArchive(
            path: summary.outputs[0], password: "pw", destination: zip.path,
            options: CreateOptions(format: .zip, level: 6, password: nil, encryptFileNames: false,
                                   excludeMacMetadata: false, volumeSize: nil),
            progress: relay
        )
        let renamed = try renameInArchive(path: zip.path, entry: "Daten/a.txt", newName: "b.txt", password: nil, progress: relay)
        XCTAssertEqual(renamed, "Daten/b.txt")
        let folder = try createFolderInArchive(path: zip.path, innerDir: "Daten", name: "Neu", password: nil, progress: relay)
        XCTAssertEqual(folder, "Daten/Neu")
        let paths = try listArchive(path: zip.path, password: nil).entries.map(\.path)
        XCTAssertTrue(paths.contains("Daten/b.txt"))
        XCTAssertTrue(paths.contains("Daten/Neu"))
        XCTAssertFalse(paths.contains("Daten/a.txt"))
        XCTAssertTrue(try listArchive(path: zip.path, password: nil).supportsEditing)
    }

    func testCancellation() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zipp-cancel-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("gross.bin")
        try Data(count: 8_000_000).write(to: file)

        let relay = ProgressRelay()
        relay.cancel()
        XCTAssertThrowsError(try createArchive(
            sources: [file.path], destination: dir.appendingPathComponent("x.zip").path,
            options: CreateOptions(format: .zip, level: 6, password: nil, encryptFileNames: false,
                                   excludeMacMetadata: true, volumeSize: nil),
            progress: relay
        )) { error in
            XCTAssertEqual(error as? ZippError, .Cancelled)
        }
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("x.zip").path))
    }
}

/// Das Archivfenster bemerkt, wenn die Datei außerhalb von ZIPP gelöscht, verschoben oder geändert wird.
@MainActor
final class ArchiveWatchTests: XCTestCase {
    private var dir: URL!
    private var archive: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        dir = fm.temporaryDirectory.appendingPathComponent("zipp-watch-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        archive = dir.appendingPathComponent("test.zip")
        try makeZip(at: archive, files: ["a.txt"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeZip(at url: URL, files: [String]) throws {
        let source = dir.appendingPathComponent("quelle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        for name in files {
            try "Inhalt".write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        _ = try createArchive(
            sources: files.map { source.appendingPathComponent($0).path }, destination: url.path,
            options: CreateOptions(format: .zip, level: 6, password: nil, encryptFileNames: false,
                                   excludeMacMetadata: true, volumeSize: nil),
            progress: ProgressRelay()
        )
    }

    private func openSession() async throws -> ArchiveSession {
        let session = ArchiveSession(url: archive, ui: WindowState())
        session.watchFile()
        await session.load()
        XCTAssertEqual(session.phase, .ready)
        addTeardownBlock { @MainActor in session.cleanup() }
        return session
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func testFollowsRename() async throws {
        let session = try await openSession()
        let renamed = dir.appendingPathComponent("umbenannt.zip")
        try FileManager.default.moveItem(at: archive, to: renamed)
        let followed = await waitUntil { session.url.standardizedFileURL == renamed.standardizedFileURL }
        XCTAssertTrue(followed)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.displayName, "umbenannt.zip")
    }

    func testDeletedShowsMissing() async throws {
        let session = try await openSession()
        try FileManager.default.removeItem(at: archive)
        let missing = await waitUntil { session.phase == .missing(trashed: false) }
        XCTAssertTrue(missing)
    }

    func testTrashAndPutBack() async throws {
        let session = try await openSession()
        var trashed: NSURL?
        try FileManager.default.trashItem(at: archive, resultingItemURL: &trashed)
        let inTrash = try XCTUnwrap(trashed as URL?)
        defer { try? FileManager.default.removeItem(at: inTrash) }
        let missing = await waitUntil { session.phase == .missing(trashed: true) }
        XCTAssertTrue(missing)

        // Zurücklegen: Das Fenster zeigt das Archiv wieder an
        try FileManager.default.moveItem(at: inTrash, to: archive)
        let back = await waitUntil { session.phase == .ready }
        XCTAssertTrue(back)
        XCTAssertEqual(session.url.standardizedFileURL, archive.standardizedFileURL)
    }

    func testReloadsWhenReplacedFromOutside() async throws {
        let session = try await openSession()
        XCTAssertEqual(session.listing?.entries.count, 1)
        // Wie ein anderes Programm, das sicher speichert: neue Datei daneben, dann ersetzen
        let replacement = dir.appendingPathComponent("neu.zip")
        try makeZip(at: replacement, files: ["a.txt", "b.txt", "c.txt"])
        _ = try FileManager.default.replaceItemAt(archive, withItemAt: replacement)
        let reloaded = await waitUntil { session.listing?.entries.count == 3 }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(session.phase, .ready)
    }

    func testOwnEditIsNotAnExternalChange() async throws {
        let session = try await openSession()
        let extra = dir.appendingPathComponent("extra.txt")
        try "Neu".write(to: extra, atomically: true, encoding: .utf8)
        await session.add([extra], into: nil)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.listing?.entries.count, 2)
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(session.phase, .ready)

        // Danach wird weiter beobachtet (die neu geschriebene Datei)
        try FileManager.default.removeItem(at: archive)
        let missing = await waitUntil { session.phase == .missing(trashed: false) }
        XCTAssertTrue(missing)
    }
}

/// Fortschrittsfenster beim Herausziehen in den Finder.
@MainActor
final class DragProgressTests: XCTestCase {
    func testCombinedProgressWindowAndCancel() async throws {
        let batch = DragBatch(ui: WindowState(), window: nil)
        let first = batch.register(name: "a.mov", size: 1_000)
        let second = batch.register(name: "b.mov", size: 3_000)

        batch.itemStarted()
        batch.itemStarted()
        // Erst nach kurzer Verzögerung erscheint das Fenster
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(batch.isShowingWindow)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(batch.isShowingWindow)
        XCTAssertEqual(batch.job?.title, "Entpacke 2 Objekte …")

        // Ein gemeinsamer Balken über beide Einträge
        batch.update(first, done: 500, total: 1_000, current: "a.mov")
        batch.update(second, done: 1_500, total: 3_000, current: "b.mov")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(batch.job?.total, 4_000)
        XCTAssertEqual(batch.job?.done, 2_000)

        // Abbrechen im Fenster erreicht die laufenden Einträge
        batch.job?.cancel()
        XCTAssertTrue(batch.isCancelled)
        batch.itemFinished(first, error: nil)
        batch.itemFinished(second, error: nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(batch.isShowingWindow)
        XCTAssertTrue(batch.isCancelled, "wartende Einträge müssen weiterhin abbrechen")
    }

    func testQuickExtractionShowsNoWindow() async throws {
        let batch = DragBatch(ui: WindowState(), window: nil)
        let only = batch.register(name: "klein.txt", size: 10)
        batch.itemStarted()
        batch.itemFinished(only, error: nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(batch.isShowingWindow)
    }

    /// Der echte Schreibweg eines File Promise: entpackt genau den gezogenen Eintrag ans Ziel.
    func testPromiseWritesEntry() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zipp-drag-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("quelle/Ordner")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "Hallo".write(to: source.appendingPathComponent("datei.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("test.zip")
        _ = try createArchive(
            sources: [source.path], destination: archive.path,
            options: CreateOptions(format: .zip, level: 6, password: nil, encryptFileNames: false,
                                   excludeMacMetadata: true, volumeSize: nil),
            progress: ProgressRelay()
        )

        let session = ArchiveSession(url: archive, ui: WindowState())
        await session.load()
        let node = try XCTUnwrap(session.root?.find(path: "Ordner/datei.txt"))
        let delegate = FilePromiseDelegate(session: session)
        let provider = delegate.makeProvider(for: node, window: nil)
        delegate.sealBatch()

        let target = dir.appendingPathComponent("ziel")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        // AppKit ruft das ebenfalls auf einem Hintergrund-Thread auf
        nonisolated(unsafe) let promise = provider
        let error: (any Error)? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                delegate.filePromiseProvider(promise, writePromiseTo: target.appendingPathComponent("datei.txt")) {
                    continuation.resume(returning: $0)
                }
            }
        }
        XCTAssertNil(error)
        let text = try String(contentsOf: target.appendingPathComponent("datei.txt"), encoding: .utf8)
        XCTAssertEqual(text, "Hallo")
    }
}
