import Foundation
import XCTest

final class ControlProtocolTests: XCTestCase {

    // MARK: - Framing

    /// A socket read is not a message. This is the case that breaks a naive
    /// implementation: the request arrives in three pieces and none of them is
    /// valid JSON on its own.
    func testALineSplitAcrossReadsIsReassembled() {
        var framer = LineFramer()
        XCTAssertEqual(framer.append(Data(#"{"comm"#.utf8)).count, 0)
        XCTAssertEqual(framer.append(Data(#"and":"state.get"#.utf8)).count, 0)

        let lines = framer.append(Data("\"}\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), #"{"command":"state.get"}"#)
    }

    func testSeveralLinesInOneReadAllComeOut() {
        var framer = LineFramer()
        let lines = framer.append(Data("{\"command\":\"a\"}\n{\"command\":\"b\"}\n".utf8))
        XCTAssertEqual(lines.count, 2)
    }

    /// A trailing partial line must be held back rather than handed over as if
    /// it were complete, which would turn one request into a parse error plus a
    /// truncated second one.
    func testATrailingPartialLineIsHeldBack() {
        var framer = LineFramer()
        let lines = framer.append(Data("{\"command\":\"a\"}\n{\"comm".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(framer.append(Data("and\":\"b\"}\n".utf8)).count, 1)
    }

    func testBlankLinesAreIgnoredRatherThanReportedAsErrors() {
        var framer = LineFramer()
        XCTAssertEqual(framer.append(Data("\n\n".utf8)).count, 0)
    }

    /// A multi-byte character split across two reads must survive, because the
    /// framer works on bytes: cutting a scene name in half mid-character and
    /// decoding each piece as UTF-8 would corrupt it.
    func testAMultiByteCharacterSplitAcrossReadsSurvives() {
        var framer = LineFramer()
        let payload = Data(#"{"command":"scene.rename","params":{"name":"Bürö"}}"#.utf8)
        let cut = payload.count / 2

        XCTAssertEqual(framer.append(payload.prefix(cut)).count, 0)
        let lines = framer.append(payload.suffix(from: cut) + Data("\n".utf8))

        XCTAssertEqual(lines.count, 1)
        let request = try? ControlCodec.decode(lines[0])
        XCTAssertEqual(request?.param("name")?.stringValue, "Bürö")
    }

    /// Without a ceiling, a client that opens the socket and never sends a
    /// newline grows this buffer until the app is killed.
    func testAnEndlessLineIsReportedAsOverflowing() {
        var framer = LineFramer()
        XCTAssertFalse(framer.isOverflowing)
        _ = framer.append(Data(repeating: 0x20, count: LineFramer.maximumLineLength + 1))
        XCTAssertTrue(framer.isOverflowing)
    }

    // MARK: - Requests

    func testARequestWithoutParametersDecodes() throws {
        let request = try ControlCodec.decode(Data(#"{"command":"state.get"}"#.utf8))
        XCTAssertEqual(request.command, "state.get")
        XCTAssertNil(request.param("anything"))
    }

    /// Shells and `jq` pipelines stringify everything, so a client that is
    /// otherwise correct will send `"2"` and `"true"`. Rejecting those would
    /// make the socket unusable from the one place it is most likely called.
    func testStringifiedNumbersAndBooleansAreAccepted() throws {
        let request = try ControlCodec.decode(
            Data(#"{"command":"zoom.set","params":{"value":"2.5","paused":"true"}}"#.utf8)
        )
        XCTAssertEqual(request.param("value")?.doubleValue, 2.5)
        XCTAssertEqual(request.param("paused")?.boolValue, true)
    }

    func testAWrongTypeReadsAsMissingRatherThanCrashing() throws {
        let request = try ControlCodec.decode(
            Data(#"{"command":"zoom.set","params":{"value":"wide"}}"#.utf8)
        )
        XCTAssertNil(request.param("value")?.doubleValue)
    }

    /// An explicit null and an absent key have to read the same, otherwise
    /// every command would need two checks for "was this given?".
    func testAnExplicitNullReadsAsAbsent() throws {
        let request = try ControlCodec.decode(
            Data(#"{"command":"scene.select","params":{"index":null}}"#.utf8)
        )
        XCTAssertNil(request.param("index"))
    }

    func testAnIdIsEchoedBackUnchanged() throws {
        let request = try ControlCodec.decode(
            Data(#"{"id":"abc","command":"state.get"}"#.utf8)
        )
        let encoded = try ControlCodec.encode(.success(id: request.id))
        XCTAssertTrue(String(data: encoded, encoding: .utf8)!.contains(#""id":"abc""#))
    }

    // MARK: - Responses

    /// Every response is exactly one line, because the framing on the client
    /// side is the same as the framing here: a pretty-printed response would
    /// read as several malformed messages.
    func testAResponseIsASingleNewlineTerminatedLine() throws {
        let encoded = try ControlCodec.encode(
            .success(id: ControlValue(1), .object(["zoom": ControlValue(2.0)]))
        )
        let text = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
    }

    func testAFailureCarriesAMessageAndNoResult() throws {
        let encoded = try ControlCodec.encode(.failure(id: nil, "No scene named `x`"))
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: encoded)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error, "No scene named `x`")
        XCTAssertNil(decoded.result)
    }

    func testNestedValuesSurviveARoundTrip() throws {
        let value = ControlValue.object([
            "scenes": .array([.object(["name": ControlValue("Wide"), "zoom": ControlValue(1.0)])]),
            "error": .null,
        ])
        let encoded = try ControlCodec.encode(.success(id: nil, value))
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: encoded)
        XCTAssertEqual(decoded.result, value)
    }

    /// Slashes appear in camera unique IDs, and escaping them turns a value a
    /// client sent into one it cannot match against.
    func testSlashesAreNotEscaped() throws {
        let encoded = try ControlCodec.encode(
            .success(id: nil, .object(["id": ControlValue("0x1/cam")]))
        )
        XCTAssertTrue(String(data: encoded, encoding: .utf8)!.contains("0x1/cam"))
    }

    // MARK: - Events

    /// A subscriber reads responses and events off the same stream, so it has
    /// to be able to tell them apart without guessing: a response always
    /// carries `ok`, an event never does.
    func testAnEventIsDistinguishableFromAResponse() throws {
        let event = try ControlCodec.encode(ControlEvent(state: .object([:])))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: event) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "state")
        XCTAssertNil(object["ok"])

        let response = try ControlCodec.encode(.success(id: nil))
        let responseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )
        XCTAssertEqual(responseObject["ok"] as? Bool, true)
        XCTAssertNil(responseObject["event"])
    }

    func testAnEventIsASingleLine() throws {
        let encoded = try ControlCodec.encode(
            ControlEvent(state: .object(["name": ControlValue("Desk\nLamp")]))
        )
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    /// The broadcaster suppresses a push whose bytes match the previous one, so
    /// that a change nothing can see does not wake every connected deck. That
    /// only works because encoding is reproducible — which it is because the
    /// encoder sorts keys.
    func testTheSameStateEncodesToTheSameBytes() throws {
        let state = ControlValue.object([
            "zoom": ControlValue(1.5),
            "paused": ControlValue(false),
            "scene": .object(["name": ControlValue("Wide"), "index": ControlValue(1)]),
        ])
        XCTAssertEqual(
            try ControlCodec.encode(ControlEvent(state: state)),
            try ControlCodec.encode(ControlEvent(state: state))
        )
    }

    /// The two commands the server answers itself rather than passing to the
    /// model, spelled once so a rename cannot silently orphan a client.
    func testTheSubscriptionCommandsAreNamedAsDocumented() {
        XCTAssertEqual(ControlSubscriptionCommand.subscribe, "events.subscribe")
        XCTAssertEqual(ControlSubscriptionCommand.unsubscribe, "events.unsubscribe")
    }

    // MARK: - Socket path

    /// `sun_path` is 104 bytes on Darwin and `bind` fails rather than
    /// truncating. The app group container lives under the user's home
    /// directory, so a long enough user name breaks an otherwise ordinary
    /// install — worth refusing deliberately instead of failing obscurely.
    func testAnOverlongSocketPathIsRejected() {
        let container = URL(fileURLWithPath: "/Users/" + String(repeating: "a", count: 120))
        let url = ControlSocket.url(inContainer: container)
        XCTAssertFalse(ControlSocket.isUsable(path: url.path))
    }

    func testARealisticSocketPathIsAccepted() {
        let container = URL(
            fileURLWithPath: "/Users/someone/Library/Group Containers/G69Z5BNY97.com.trsdn.openlens"
        )
        let url = ControlSocket.url(inContainer: container)
        XCTAssertTrue(ControlSocket.isUsable(path: url.path))
        XCTAssertEqual(url.lastPathComponent, "control.sock")
    }
}
