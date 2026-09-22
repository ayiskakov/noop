import XCTest
@testable import WhoopProtocol

/// Registry row → `DeviceFamily` resolution (#171, #1086).
///
/// NOOP supports one strap family, so the question a registry row has to answer is no longer "which
/// generation?" but "is this row a WHOOP at all?" — and that still matters, because an install
/// upgraded from an older build can hold rows for devices NOOP no longer drives (a ring, a watch, a
/// generic strap). Answering yes for one of those is the #171 mistake wearing #1086's clothes: a
/// family question settled by a fall-through rather than by evidence.
///
/// The registry also holds several historical spellings for the same hardware — the Add-Device
/// wizard's bare "5.0 MG", the full picker label "WHOOP 5.0 / MG", and the legacy seeded "my-whoop"
/// row's bare "WHOOP". `confirmedRegistryFamily` is the one place allowed to read them, and it
/// distinguishes a POSITIVELY identified 5/MG from a row that merely fails to contradict one.
final class RegistryModelFamilyTests: XCTestCase {

    // MARK: - confirmedRegistryFamily — positive evidence only

    func testEveryStored5MGSpellingIsPositivelyIdentified() {
        for model in ["5.0", "5.0 MG", "WHOOP 5.0", "WHOOP 5.0 / MG", "MG", "whoop5",
                      "5.0 mg", "whoop 5.0 / mg"] {
            XCTAssertEqual(DeviceFamily.confirmedRegistryFamily(model: model, brand: "WHOOP"), .whoop5,
                           "\(model) must positively identify a 5/MG")
        }
    }

    /// The legacy "WHOOP" label predates the wizard and was written identically for every generation,
    /// so it identifies NOTHING. Nil is the honest answer; callers that need a concrete family coalesce
    /// it themselves, and callers asking an identity question must not.
    func testLegacyAndBlankLabelsIdentifyNothing() {
        for model in ["WHOOP", "", "4.0", "WHOOP 4.0", "Ring Gen3", "garmin-hrm"] {
            XCTAssertNil(DeviceFamily.confirmedRegistryFamily(model: model, brand: "WHOOP"),
                         "\(model) carries no 5/MG evidence")
        }
        XCTAssertNil(DeviceFamily.confirmedRegistryFamily(model: nil, brand: nil))
    }

    /// A positively non-WHOOP brand is never a WHOOP, whatever its model string says.
    func testNonWhoopBrandIsNeverConfirmed() {
        for brand in ["Oura", "Apple", "Garmin", "Polar"] {
            XCTAssertNil(DeviceFamily.confirmedRegistryFamily(model: "5.0 MG", brand: brand))
        }
    }

    // MARK: - forRegistryDevice — nil means "not a WHOOP", not "unknown generation"

    func testNonWhoopBrandResolvesToNil() {
        for model in ["5.0 MG", "WHOOP 5.0 / MG", "Watch", nil] {
            XCTAssertNil(DeviceFamily.forRegistryDevice(model: model, brand: "Oura"),
                         "an Oura row must never resolve to a WHOOP family")
        }
        XCTAssertNil(DeviceFamily.forRegistryDevice(model: nil, brand: "Garmin"))
        XCTAssertNil(DeviceFamily.forRegistryDevice(model: "Watch", brand: "Apple"))
    }

    /// A WHOOP brand — or no brand at all, which carries no non-WHOOP signal — resolves to the one
    /// supported family regardless of model spelling.
    func testWhoopOrUnbrandedRowsResolveToWhoop5() {
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: "5.0 MG", brand: "WHOOP"), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: "WHOOP 5.0 / MG", brand: "whoop"), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: "WHOOP", brand: nil), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: nil, brand: ""), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: nil, brand: nil), .whoop5)
    }

    // MARK: - isWhoop5Registry — the identity question, which must never coalesce

    /// The shape this helper exists to make unwriteable: `forRegistryDevice(…) ?? .whoop5 == .whoop5`
    /// answers YES for a leftover non-WHOOP row, because the coalesce throws away the brand evidence.
    func testIdentityQuestionSaysNoForANonWhoopRow() {
        for model in ["5.0 MG", "WHOOP 5.0 / MG", "Ring Gen3", nil] {
            XCTAssertFalse(DeviceFamily.isWhoop5Registry(model: model, brand: "Oura"),
                           "an Oura row is not a 5/MG, whatever its model string says")
        }
        XCTAssertFalse(DeviceFamily.isWhoop5Registry(model: "Watch", brand: "Apple"))
        XCTAssertFalse(DeviceFamily.isWhoop5Registry(model: nil, brand: "Garmin"))
    }

    func testIdentityQuestionSaysYesForAWhoopOrUnbrandedRow() {
        XCTAssertTrue(DeviceFamily.isWhoop5Registry(model: "5.0 MG", brand: "WHOOP"))
        XCTAssertTrue(DeviceFamily.isWhoop5Registry(model: "WHOOP 5.0 / MG", brand: "WHOOP"))
        XCTAssertTrue(DeviceFamily.isWhoop5Registry(model: "WHOOP", brand: nil))
        XCTAssertTrue(DeviceFamily.isWhoop5Registry(model: nil, brand: ""))
    }

    // MARK: - the family axis itself

    /// One supported family. Pinned so adding a case is a deliberate act that reddens this suite
    /// rather than quietly widening every `switch family` in the package.
    func testOnlyOneFamilyIsSupported() {
        XCTAssertEqual(DeviceFamily.allCases, [.whoop5])
    }

    /// A WHOOP 4.0 strap is still RECOGNISED on the air — it just isn't connectable. Reporting it as
    /// detected-but-unsupported is the honest outcome; silently ignoring the advertisement would leave
    /// a 4.0 owner with an app that scans forever and says nothing.
    func testWhoop4IsRecognisedButNotConnectable() {
        let whoop4 = WhoopGattServiceFamily.whoop4
        XCTAssertNil(whoop4.connectableDeviceFamily)
        XCTAssertFalse(whoop4.isConnectable)
        XCTAssertTrue(WhoopGattServiceFamily.unsupportedFamilies.contains(whoop4))
        XCTAssertEqual(WhoopGattServiceFamily.forServiceUUIDString("61080001-8d6d-82b8-614a-1c8cb0f8dcc6"),
                       whoop4)
        XCTAssertTrue(whoop4.diagnosticUnsupportedMessage.contains("WHOOP 4.0"))
    }

    func testOnlyTheFd4bServiceIsConnectable() {
        XCTAssertEqual(WhoopGattServiceFamily.allCases.filter(\.isConnectable), [.maverickGooseFD4B])
        XCTAssertEqual(WhoopGattServiceFamily.maverickGooseFD4B.connectableDeviceFamily, .whoop5)
    }
}
