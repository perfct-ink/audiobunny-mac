import XCTest
@testable import AudioBunny

final class PresetInstallerTests: XCTestCase {
    private var dir: URL!
    private var home: URL!

    private let serum = PresetPluginCandidate(name: "Serum", manufacturer: "Xfer Records")
    private let serum2 = PresetPluginCandidate(name: "Serum 2", manufacturer: "Xfer Records")
    private let diva = PresetPluginCandidate(name: "Diva", manufacturer: "u-he")
    private let vital = PresetPluginCandidate(name: "Vital", manufacturer: "Vital Audio")
    private let proQ = PresetPluginCandidate(name: "Pro-Q 3", manufacturer: "FabFilter",
                                             auSubtypes: ["FQ3p"], auComponents: ["aufx|FQ3p|FbFl"],
                                             vst3ClassIDs: ["72C4DB717A4D459AB97E51745D84B39D"])

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioBunnyPresetInstallerTests-\(UUID().uuidString)")
        home = dir.appendingPathComponent("home")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    @discardableResult
    private func write(_ relative: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent("drop/\(relative)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func fxp(id: String) -> Data {
        var data = Data("CcnK".utf8)
        data.append(contentsOf: [0, 0, 0, 100])
        data.append(Data("FPCh".utf8))
        data.append(contentsOf: [0, 0, 0, 1])
        data.append(Data(id.utf8))
        data.append(Data(count: 40))
        return data
    }

    private func code(_ s: String) -> Int {
        s.utf8.reduce(0) { $0 << 8 | Int($1) }
    }

    // MARK: Detection

    func testFxpMatchesAUSubtype() throws {
        let url = try write("Bright.fxp", fxp(id: "FQ3p"))
        XCTAssertEqual(detectPresetPlugin(at: url, plugins: [serum, proQ]), proQ)
    }

    func testFxpMatchesKnownSerumID() throws {
        let url = try write("Bass.fxp", fxp(id: "XfsX"))
        XCTAssertEqual(detectPresetPlugin(at: url, plugins: [serum2, proQ, serum]), serum)
    }

    func testAUPresetMatchesComponentCodes() throws {
        let plist: [String: Any] = ["type": code("aufx"), "subtype": code("FQ3p"),
                                    "manufacturer": code("FbFl"), "name": "Vocal"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let url = try write("Vocal.aupreset", data)
        XCTAssertEqual(auPresetCodes(url), AUCodeKey(type: "aufx", subtype: "FQ3p", manufacturer: "FbFl"))
        XCTAssertEqual(detectPresetPlugin(at: url, plugins: [serum, proQ]), proQ)
    }

    func testVSTPresetMatchesClassID() throws {
        var data = Data("VST3".utf8)
        data.append(contentsOf: [1, 0, 0, 0])
        data.append(Data("72c4db717a4d459ab97e51745d84b39d".utf8))
        data.append(Data(count: 16))
        let url = try write("Air.vstpreset", data)
        XCTAssertEqual(detectPresetPlugin(at: url, plugins: [serum, proQ]), proQ)
    }

    func testVSTPresetFallsBackToMetadataPluginName() throws {
        var data = Data("VST3".utf8)
        data.append(contentsOf: [1, 0, 0, 0])
        data.append(Data(String(repeating: "0", count: 32).utf8))
        data.append(Data(count: 16))
        data.append(Data(#"<MetaInfo><Attribute id="PlugInName" value="Diva" type="string" flags="writeProtected"></Attribute></MetaInfo>"#.utf8))
        let url = try write("Pad.vstpreset", data)
        XCTAssertEqual(vstPresetHeader(url)?.pluginName, "Diva")
        XCTAssertEqual(detectPresetPlugin(at: url, plugins: [serum, diva]), diva)
    }

    func testH2PUsesProductLine() throws {
        let url = try write("Lead.h2p", Data("/*@Meta\nAuthor:\n'someone'\n*/\n\n#AM=Diva\n#Vers=1\n".utf8))
        XCTAssertEqual(detectPresetPlugin(at: url, plugins: [serum, diva]), diva)
    }

    func testFormatOwnedByOnePlugin() throws {
        let url = try write("Pluck.vital", Data("{}".utf8))
        XCTAssertEqual(detectPresetPlugin(at: url, plugins: [serum, vital]), vital)
        let serum2URL = try write("Growl.SerumPreset", Data("x".utf8))
        XCTAssertEqual(detectPresetPlugin(at: serum2URL, plugins: [serum, serum2]), serum2)
    }

    func testFallsBackToFolderNamePreferringLongestName() throws {
        let url = try write("Untitled.fxp", Data("not a real header".utf8))
        XCTAssertEqual(detectPresetPlugin(at: url, contextNames: ["Basses", "Serum 2 Presets"],
                                          plugins: [serum, serum2]), serum2)
        XCTAssertNil(detectPresetPlugin(at: url, contextNames: ["Basses"], plugins: [serum, serum2]))
    }

    func testCandidatesFoldFormatsAndPreferAUManufacturer() {
        let candidates = presetCandidates(from: [
            (name: "Pro-Q 3", manufacturer: "FabFilter Software Instruments, Copyright 2020", type: .vst2,
             fileURL: URL(fileURLWithPath: "/nonexistent/Pro-Q 3.vst"), auCodes: nil),
            (name: "Pro-Q 3", manufacturer: "FabFilter", type: .audioUnit,
             fileURL: URL(fileURLWithPath: "/nonexistent/Pro-Q 3.component"),
             auCodes: AUCodeKey(type: "aufx", subtype: "FQ3p", manufacturer: "FbFl")),
        ])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].manufacturer, "FabFilter")
        XCTAssertEqual(candidates[0].auSubtypes, ["FQ3p"])
        XCTAssertEqual(candidates[0].auComponents, ["aufx|FQ3p|FbFl"])
    }

    // MARK: Destinations

    func testInstallFolders() {
        XCTAssertEqual(presetInstallFolder(for: serum, fileExtension: "fxp", home: home).path,
                       home.appendingPathComponent("Documents/Xfer/Serum Presets/Presets/User").path)
        XCTAssertEqual(presetInstallFolder(for: diva, fileExtension: "h2p", home: home).path,
                       home.appendingPathComponent("Library/Audio/Presets/u-he/Diva").path)
        XCTAssertEqual(presetInstallFolder(for: proQ, fileExtension: "aupreset", home: home).path,
                       home.appendingPathComponent("Library/Audio/Presets/FabFilter/Pro-Q 3").path)
    }

    func testUnsafeNamesStayInsideTheirFolder() throws {
        let evil = PresetPluginCandidate(name: "..", manufacturer: "../../..")
        let source = try write("x.aupreset", Data("x".utf8))
        let dest = try presetDestination(for: PresetInstallItem(source: source, relativeFolder: [".."], plugin: evil),
                                         home: home)
        XCTAssertTrue(dest.standardizedFileURL.path.hasPrefix(home.appendingPathComponent("Library/Audio/Presets").path + "/"))
    }

    // MARK: Installing

    func testInstallCreatesFoldersAndNeverOverwrites() throws {
        let source = try write("Bass.fxp", fxp(id: "XfsX"))
        let item = PresetInstallItem(source: source, relativeFolder: ["My Pack"], plugin: serum)
        let expected = home.appendingPathComponent("Documents/Xfer/Serum Presets/Presets/User/My Pack/Bass.fxp")

        guard case .installed(let first) = try installPresetFile(item, home: home) else { return XCTFail("not installed") }
        XCTAssertEqual(first.path, expected.path)
        guard case .alreadyInstalled(let again) = try installPresetFile(item, home: home) else { return XCTFail("copied twice") }
        XCTAssertEqual(again.path, expected.path)

        try fxp(id: "XfsY").write(to: source)
        guard case .installed(let numbered) = try installPresetFile(item, home: home) else { return XCTFail("not installed") }
        XCTAssertEqual(numbered.lastPathComponent, "Bass 2.fxp")
        XCTAssertEqual(numbered.deletingLastPathComponent().path, expected.deletingLastPathComponent().path)
        XCTAssertEqual(try Data(contentsOf: expected), fxp(id: "XfsX"))
    }

    func testInstallWithoutPluginThrows() throws {
        let source = try write("Mystery.fxp", Data("x".utf8))
        XCTAssertThrowsError(try installPresetFile(PresetInstallItem(source: source, relativeFolder: [], plugin: nil),
                                                   home: home))
    }

    // MARK: Collecting drops

    func testCollectsFolderPresetsAndPluginBundles() throws {
        try write("Pack/Basses/Wobble.fxp", fxp(id: "XfsX"))
        try write("Pack/readme.txt", Data("hi".utf8))
        try write("Pack/Extras/Thing.vst3/Contents/Info.plist", Data())
        let loose = try write("Lead.h2p", Data("#AM=Diva\n".utf8))

        let dropped = collectDroppedFiles([dir.appendingPathComponent("drop/Pack"), loose], plugins: [serum, diva])

        XCTAssertEqual(dropped.pluginBundles.map(\.lastPathComponent), ["Thing.vst3"])
        XCTAssertEqual(dropped.ignored.map(\.lastPathComponent), ["readme.txt"])
        let byName = Dictionary(uniqueKeysWithValues: dropped.presets.map { ($0.source.lastPathComponent, $0) })
        XCTAssertEqual(byName["Wobble.fxp"]?.relativeFolder, ["Pack", "Basses"])
        XCTAssertEqual(byName["Wobble.fxp"]?.plugin, serum)
        XCTAssertEqual(byName["Lead.h2p"]?.relativeFolder, [])
        XCTAssertEqual(byName["Lead.h2p"]?.plugin, diva)
    }
}
