import XCTest

/// Guards the camera extension's `Info.plist` against build-setting variables
/// that only expand when the build signs with a team.
///
/// A sandboxed system extension is refused by `sysextd` unless its mach service
/// name is prefixed with one of its app groups. The obvious spelling,
/// `$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`, expands to nothing in
/// front of the bundle id when there is no team — which is exactly the case in
/// the notarization broker, because it builds the source unsigned and signs
/// afterwards. The resulting release installs, launches, passes every signature
/// and notarization check, and then loses the extension seconds later with
/// nothing in the UI but "extension category returned error".
final class CameraExtensionInfoPlistTests: XCTestCase {
    private func extensionInfoPlist() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Sources/OpenLensCamera/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testTheMachServiceNameCarriesTheTeamPrefixWithoutABuildSetting() throws {
        let info = try extensionInfoPlist()
        let cmio = try XCTUnwrap(info["CMIOExtension"] as? [String: Any])
        let name = try XCTUnwrap(cmio["CMIOExtensionMachServiceName"] as? String)

        XCTAssertFalse(
            name.contains("$(TeamIdentifierPrefix)"),
            """
            The mach service name must not depend on $(TeamIdentifierPrefix): \
            it is empty in an unsigned build and the extension is then rejected.
            """
        )
        XCTAssertTrue(
            name.hasPrefix("\(OpenLensID.teamID)."),
            "Expected the team prefix, got \(name)"
        )

        let resolved = name.replacingOccurrences(
            of: "$(PRODUCT_BUNDLE_IDENTIFIER)",
            with: OpenLensID.extensionBundleID
        )
        XCTAssertEqual(resolved, OpenLensID.cmioMachServiceName)
        XCTAssertTrue(
            resolved.hasPrefix(OpenLensID.appGroup),
            "sysextd requires the mach service name to sit inside an app group"
        )
    }
}
