import XCTest
@testable import WhoopProtocol

/// The WHOOP 5/MG **R16 raw ECG record** decoder (`Whoop5EcgRawRecord`), pinned against real captured
/// hardware frames and against the fixed geometry in `docs/PROTOCOL_ECG.md`.
///
/// UNVALIDATED INSTRUMENTATION. Nothing here asserts volts, a sample rate, electrode acceptance or any
/// clinical reading — these tests pin the DECODE, which is a fact about bytes.
///
/// ## Why these three fixtures and not the two already in `Whoop5HistoricalV16Tests`
///
/// Those two are a full record and an empty one, and NEITHER CAN FAIL on the defect this file exists to
/// prevent: every waveform word in the full fixture carries tag byte `0x83`, so the superseded
/// tag-class guard happened to keep all 500 of them. A suite that only ever sees uniform flags cannot
/// see a guard that discards samples BY their flags — which is exactly how 42.8 percent of the captured
/// corpus came to be dropped under a green suite.
///
/// So each fixture below was chosen for what the OLD guard did to it, and the oracle records that
/// figure beside the corrected one:
///
/// | fixture | declared | superseded guard stored | this decoder stores |
/// |---|---:|---:|---:|
/// | `pureContactOffHex` | 500 | 0 | 500 |
/// | `contactTransitionHex` | 500 | 436 | 500 |
/// | `partialRecordHex` | 245 | 65 | 245 |
///
/// All three are real, CRC-valid 1,584-byte v16 records from WHOOP 5/MG hardware (fw 50.39.1.0), and
/// like the existing fixtures they are anonymous — a type-47 history frame carries no device name,
/// serial or token.
///
/// ## The expected values are an ORACLE, not hand-read
///
/// Per `AGENTS.md`: `Whoop5EcgRawRecord.swift` was compiled standalone (`swiftc -O
/// Whoop5EcgRawRecord.swift main.swift -o gen`) against these three frames and its stdout pinned
/// verbatim below. Sample arrays are pinned by FNV-1a over their decimal rendering — a stable,
/// platform-neutral digest, never `hashValue`, which Swift randomises per process.
final class Whoop5EcgR16RecordTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    /// FNV-1a over the samples' decimal rendering — the twin of the oracle generator's digest.
    private func digest(_ samples: [Int]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for u in samples.map(String.init).joined(separator: ",").unicodeScalars {
            h ^= UInt64(u.value)
            h = h &* 0x0000_0100_0000_01B3
        }
        return String(h, radix: 16)
    }

    /// Reproduces the SUPERSEDED tag-class guard exactly, so the tests below can assert the SIZE of the
    /// defect rather than only the corrected output. If this ever stops differing from the real decoder
    /// on these fixtures, the fixtures have stopped covering the bug.
    private func supersededKeptCount(_ frame: [UInt8]) -> Int {
        let declared = Int(frame[32]) | (Int(frame[33]) << 8)
        var kept = 0
        for i in 0..<min(declared, 500) {
            let tag = frame[34 + i * 3]
            if tag & 0x80 != 0, tag & 0x7C == 0 { kept += 1 }
        }
        return kept
    }

    // A full record captured with the electrode circuit OPEN: 500 declared samples, every one carrying
    // flag7 = 0. The superseded guard stored ZERO of them, and the record survived at all only because
    // the archive skip is sample-bound. record_index 29868864, unix 1789990223.
    private let pureContactOffHex =
        "aa0128060100cde02f100340c3c7014f15b16af5280108010264004900280000f401415fa84143714132394124c1412c254141f14166a34185054191cb418074415f47413f3e412d024122d2412d3a4144134167c44185324193014181e5416078413e85412b4441233e412cd74141ba41683b4187e641936a4182e5416028413e77412b324120604128b041426c41695e41872641951a41844b4161e9413d58412873411d914127d041408b416b7d418bf241965e418443416168413b1d4124e8411cae41283441401341692c4189e34198f3418574415ed5413a044122ef4118f041256e413fe5416a14418dca419b6d418778416039413c3e412815411c4441255e41404c416b94418cb4419985418551416281413d2341246d4116fa412176413eaa416c44418f81419e5f418810415f1941387e41230f4114be412164413f41416a8c418da3419c984188fe4161c64139624120af4116074120f7413c94416b044191cb41a059418b1a41619c41352b411d5a411342412034413d68416bea418ffa41a18b418be6415e44413458411c74411027411d25413d6b416d6941921c419f654189f94160974136b4412041411114411d7a4139bf416ad44190fd41a25b418d4a416084413418411ccd410f53411b104139604169b54192ce41a36e418b8c415e0d413657411cc7410e8c411cb1413db5416dc841937c41a3cd418aec415d17413360411aea411112411c0f41399b416bd041941041a591418cff416157413513411a7c410cea411c0f413ade416b7e41948b41a4ac418d1d415ef741347f4119c5410cc5411b2c413aca016d1d018dbf017c9d016820014a9a011a4e00e06e00ab3d0092ec00995a00cc7e0110ea01505d01605701481a0115f400de6c00aa0e009547009e2f00cff501165e0157b301686b014dd6011f6700e88c00b1c0009d3700a8cb00e03201261b01653101728401582101270900ed2e00b84d009fdd00a79100dde50127320167f00176bc015bcb01296a00f0e500b798009efb00a6f700d8ec01236d016524016fc5014fa0011a4800e14f00a837008e8d00982c00cf3401176d015954016859014a5d0118f600df8200aaf3009562009d5300d43601210401626301733c0158cf01218f00eb2c00b503009e3400a55700dab90126f7016adc017aba015c8201253d00ec5e00b520009af600a3e700d991011ff4015e99016def01524e011dc200e2b500ac9e0096cf00a02900da1b0127fa0168bb017644015dd301260b00e60b00aacd009440009e9200d83401229f0163500174000154b0011de900e45600ae3500968300a3ae00debd0128380167cb0177620159dd01251500e95500b5bc009b7d00a2ec00dc890125be0166b60178fa015bd10122ff00e7df00b02c009630009fca00dc5f01264301676701759c01554e0119ff00e01500ade70093c2009ee800dbfe0124e80166ec01784f015d0c0126fd00ee4f00bb6800a31800acd400e5d0012f220170db0180780164c6012c0a00eeba00b632009e5300a98500e377012a5a016a2c017b87015c6401214400e3ec00adf00096c800a09600dd1e01292c016a72017b88015f6f01280f00eb4300b83c009eee00a8ad00e507012f58016dff017e2d01631b012bd200f42700bf1b00a66400b2c300ed570135ea0174ed01843c01631c012c3400fc3a00c61600aae100b6ec00f31a013a45017281017eac016237012be700f34100c4d800ad7500b72700eed901351501723f017fec0164f8012e6b00f64200c3f000ad1e00b6cc00ef330136ea01754b0180160160aa012bd400f7d200c69400af4600bdd100f67a013bfb01761b0183a701680e01338600fa4f00cd6900b8ff00c2cb00f8b001400a017a150183b30169dc01382101000800cbc300b89b00c5ad00fbce013fda017ba60186380168300132e700fc4500cbfd00b82100c37600fb2e0141a2017b0501851001682f0135a600fd6900ce3e00bb8900c76700ff0a013fc801760901831a0168bb0136860101ce00d3d100c00200cae80100220142170178ba0181500164ce01337600fdd600ceb000bc3e00c93e00fe8b013efe01777501819301626601327700fe1300d20d00c13d00cd6400feb1013e300171bc0176d40a98019701960195018f018801850184018401850100002401230123012301220120011f011e011e011e01000000f6b77e12"

    // The record ONE SECOND EARLIER, catching the contact loss in flight: flag7 runs 1 for nine contact
    // groups and drops to 0 for the tenth. The lead-off I channel corroborates it independently, rising
    // from 63 to 406 across the same boundary. record_index 29868863, unix 1789990222.
    private let contactTransitionHex =
        "aa0128060100cde02f10033fc3c7014e15b16af5280108010264004900280000f40183d7a983da9783dee883e04383de6983dedd83e1d783dcbd83d7fd83d86f83dc0783d9b483d76f83dcb383e37783df6783dbfc83db0683d97483d80e83d89083d9c083df7883ddf783e1c383e49883e05883dc9083e09083daff83da3183ddd483de9b83de8983e01e83db6e83d8c383d93083ded783e1fa83e29e83e0d183e30d83e22183de6483e24083e6c083e81583e23f83d94b83d7f783da1f83de0c83e1df83dedf83db6e83de5883df8b83dec883e26a83e29b83e3b183e71683e29b83e0bb83e2ec83df0c83d96c83da4f83dd7d83df1f83defe83e07783df5483df1b83e0e783e33c83e2b383e3f683e6cf83e46483e32e83e79d83e5bd83ddfd83e32883e5d483e65d83e5d983e3e183e2bd83dfc583e34a83e68c83e7cc83e5e783e18c83e3be83e60283e7e183ecd483ed4983e57183e4b883e52a83e31883e46283e17983e30783e7a683e96383e70883e24e83e3d183e3d683e41583e53583e30e83e5d683e9f283e66683e5c983eba183e8bd83e53283e3f483e83183e66b83e19a83e46183e8fd83e93b83ea5283ec0183ea8383e64683e92c83e91183e89483edc383f1c683f03883efa883ec5183ea9083e82183e78c83e68683ea3f83f32383f44e83f26a83edfc83ed8c83ee5083f36f83fce58004ff800ac3800a9e800c448010158010438007e183fce883f3ea83ef1d83eab283ea8983f22483f4fe83ed7083e21f83d9b983d45c83d51083d80d83d93a83dd3183e25683e5ec83e9ed83eb5d83ee9083edef83ea4f83eb2c83ed9683f20583f17983f0d883ef0983f31283f59083f37583f03483f0c783f2fa83f50d83f51183f73c83f60d83f3bf83f31a83f61c83f86d83f87083f86283f82883f6c183f93a83f79c83f95c83fbf783fa8583f83e83f90a83fa1483fb7683f81683f63583fb8583fc0d83fa0d83fbb783fce583fd5383fe1183fefc83fe3e83ff6683fff383fe4b83fd9483ff758002b680032383fd3683ff0083fe2d83feb480014583feff83ff9780001680017e80026680041c8002ba80029f8002698004578004678004f680055a80057e800527800774800a07800985800948800a508007f280067280055c8007a680077d800973800c72800d8c800c49800acf800af08009788008a1800b76800aea800b4d8009f78007638007198008548006748007728007198005e580043b8008c78008de80083d8007a68004768004878005198001ff8001218004f580087a8006a78004308004dd8006248004418003cc8001b58004f28007198006cc8001778001288005d580080a800a208007fa8005708004838009d5800afd800788800525800726800b30800b3f800da5800d06800d6980106f80121e8011bb8013388017d8801de9801f9780213c802543802759802b8a80287b80292d802acb802b3c802d2680312b8033af803133803192803ba680438d80482080501680546480539c8055b4805ad7805eee80652e8066c58070f7807f66808c5a8097d980a47e80c16580ef248110298131988149488168f8818dff81ae8581d02681eb9281effe81f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f000c1f000c1f000c1f000c1f000c1f000c1f000c1f000c1f000c1f000c1ecc6c1d288c1bca0c1b002c194ebc174014157404143fd413bc54140be414fe6416aa8417ed74188d4417eb341655341494b413b3241345241396e41491941659d417ec6418a1e417cd94161e94147b2413526412b754132ea414a1241677d417f0e4189aa417c6e41608f414699413464412cb84134d64144e9416470417eab41895c417c874163cc41466041334e412a1841312d41431a416567418367419014417f7a0a3f003f003f003f003f003f003f004100780196010000edffedffedffedffedffeeffeefff0ff17012301000000dc96cd76"

    // A PARTIAL record — 245 declared samples, not the 500-slot capacity. Its value is the fixed-offset
    // rule: 34 + 3 * 245 is 769, nowhere near the lead-off count byte at 1534, so a decoder that
    // computes its way to the diagnostics from the declared count reads waveform bytes as lead state
    // here. record_index 29868823, unix 1789990182.
    private let partialRecordHex =
        "aa0128060100cde02f100317c3c7012615b16af528010a000100000000ffff00f500806bc381aaba81f00181f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f00081f000c1efaac18f1ac07c90c01fa6c00cabc0062cc003c7c0039ac0039ec00345c0031bc002f0c00296c002e1c0038bc00237c001f1c002ddc0038ec0031ac00327c00363c002c0c00316c002fbc00379c002a2c00291c00352c00377c0033fc00330c00310c0031ac00262c00238c00353c002e4c002f5c00353c00391c0036ec00240c0028cc002f9c00398c002c9c00324c002e2c0039fc002cdc0030ac00453c00300c001b3c00172c001e2c00311c003edc0030cc002e1c0037ec003a4c00356c0032ec00369c00250c00239c00205c002cec002c8c00319c00367c002acc00275c0032dc002f4c002e3c0035ec00353c003cdc0030bc0025fc0029dc002cbc002ebc002f5c00281c0020fc0030fc0038ec002f2c0027ac002e1c0028dc00322c002ddc002bdc00412c0037dc002bdc002b6c00316c002cac00266c0024ec002f6c00363c002bbc002c4c0033fc00335c002f5c00256c00284c00364c002efc0034bc002f0c002b5c002f9c002afc00339c00354c002c2c00352c0040ac0041cc003afc00369c002eac003acc00395c00294c00208c00216c0012dc001e7c00293c002e3c002d4c0017dc000dbc00117c0014fc0016fc002f0c00455c0035bc00357c003dfc003ebc003afc003f0c0042ac002e2c001ebc001dec002b1c00414c003e7c00391c00302c00279c0026fc002e9c00320c002e2c002c6c00306c003aac00391c0030dc00342c00267c0025f40032d4002c340028a4002b60000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a3f003f003f003f003f003f003f003f003f003f000000eeffeeffeeffedffedffedffedffedffedffedff000000f384771a"

    // MARK: - The defect: samples are carried, never filtered by their flags

    /// The headline regression guard. A record whose every sample carries `flag7 = 0` stored NOTHING
    /// under the tag-class guard; it must now store all 500.
    func testAContactOffRecordStoresEverySampleRatherThanNone() {
        let frame = bytes(pureContactOffHex)
        guard let r = Whoop5EcgRawRecord.decode(frame) else { return XCTFail("fixture must decode") }
        XCTAssertEqual(supersededKeptCount(frame), 0,
                       "fixture must still exercise the defect: the old guard kept none of these")
        XCTAssertEqual(r.status.declaredSampleCount, 500)
        XCTAssertEqual(r.samples.count, 500, "every DECLARED sample is carried, whatever its flags say")
        XCTAssertEqual(r.contactFlags, Array(repeating: false, count: 10),
                       "contact was open for the whole record — which is a FACT ABOUT CONTACT, not a reason to drop the waveform")
        XCTAssertTrue(r.anomalies.isEmpty, "an open circuit is not a malformed record")
    }

    func testAContactTransitionRecordKeepsTheSamplesTheOldGuardDropped() {
        let frame = bytes(contactTransitionHex)
        guard let r = Whoop5EcgRawRecord.decode(frame) else { return XCTFail("fixture must decode") }
        XCTAssertEqual(supersededKeptCount(frame), 436)
        XCTAssertEqual(r.samples.count, 500, "the 64 dropped samples are real waveform, not noise")
        // Nine groups in contact, the tenth not — the grouping rule's own resolution, no finer.
        XCTAssertEqual(r.contactFlags.map { $0 ? 1 : 0 }, [1, 1, 1, 1, 1, 1, 1, 1, 1, 0])
    }

    func testAPartialRecordStoresItsDeclaredCountNotItsCapacity() {
        let frame = bytes(partialRecordHex)
        guard let r = Whoop5EcgRawRecord.decode(frame) else { return XCTFail("fixture must decode") }
        XCTAssertEqual(supersededKeptCount(frame), 65)
        XCTAssertEqual(r.status.declaredSampleCount, 245)
        XCTAssertEqual(r.samples.count, 245, "read the declared count, never the 500-slot capacity")
    }

    // MARK: - Oracle: pinned verbatim from the standalone run (see the class doc)

    func testDecodeMatchesTheOracleForEveryFixture() {
        // [zero]
        guard let zero = Whoop5EcgRawRecord.decode(bytes(pureContactOffHex)) else { return XCTFail("zero") }
        XCTAssertEqual(zero.recordIndex, 29_868_864)
        XCTAssertEqual(zero.unix, 1_789_990_223)
        XCTAssertEqual(zero.samples.count, 500)
        XCTAssertEqual(Array(zero.samples.prefix(5)), [90024, 82801, 78393, 74945, 76837])
        XCTAssertEqual(Array(zero.samples.suffix(5)), [52580, 65201, 81456, 94652, 95956])
        XCTAssertEqual(zero.samples.min(), 36493)
        XCTAssertEqual(zero.samples.max(), 107_921)
        XCTAssertEqual(digest(zero.samples), "a0401a687fa22f60")
        XCTAssertEqual(zero.sampleFlags.filter { $0 }.count, 186)
        XCTAssertEqual(zero.leadOffCount, 10)
        XCTAssertEqual(zero.leadOffI, [408, 407, 406, 405, 399, 392, 389, 388, 388, 389])
        XCTAssertEqual(zero.leadOffQ, [292, 291, 291, 291, 290, 288, 287, 286, 286, 286])
        XCTAssertEqual(zero.anomalies, [])

        // [mix]
        guard let mix = Whoop5EcgRawRecord.decode(bytes(contactTransitionHex)) else { return XCTFail("mix") }
        XCTAssertEqual(mix.recordIndex, 29_868_863)
        XCTAssertEqual(mix.unix, 1_789_990_222)
        XCTAssertEqual(Array(mix.samples.prefix(5)), [-10327, -9577, -8472, -8125, -8599])
        XCTAssertEqual(Array(mix.samples.suffix(5)), [82714, 91495, 99175, 102_420, 98170])
        XCTAssertEqual(mix.samples.min(), -11172)
        XCTAssertEqual(mix.samples.max(), 126_976)
        XCTAssertEqual(digest(mix.samples), "d20262b2ad4fc9e6")
        XCTAssertEqual(mix.sampleFlags.filter { $0 }.count, 64)
        // The independent corroboration: the I/Q diagnostics move across the SAME boundary flag7 does.
        XCTAssertEqual(mix.leadOffI, [63, 63, 63, 63, 63, 63, 63, 65, 376, 406])
        XCTAssertEqual(mix.leadOffQ, [-19, -19, -19, -19, -19, -18, -18, -16, 279, 291])
        XCTAssertEqual(mix.anomalies, [])

        // [part]
        guard let part = Whoop5EcgRawRecord.decode(bytes(partialRecordHex)) else { return XCTFail("part") }
        XCTAssertEqual(part.recordIndex, 29_868_823)
        XCTAssertEqual(part.unix, 1_789_990_182)
        XCTAssertEqual(Array(part.samples.prefix(5)), [27587, 109_242, 126_977, 126_976, 126_976])
        XCTAssertEqual(Array(part.samples.suffix(5)), [607, 813, 707, 650, 694])
        XCTAssertEqual(part.samples.min(), 219)
        XCTAssertEqual(part.samples.max(), 126_977)
        XCTAssertEqual(digest(part.samples), "38efcd86a49ba07c")
        XCTAssertEqual(part.sampleFlags.filter { $0 }.count, 180)
        XCTAssertEqual(part.leadOffCount, 10)
        XCTAssertEqual(part.leadOffI, [63, 63, 63, 63, 63, 63, 63, 63, 63, 63])
        XCTAssertEqual(part.leadOffQ, [-18, -18, -18, -19, -19, -19, -19, -19, -19, -19])
        XCTAssertEqual(part.contactFlags, Array(repeating: true, count: 10))
        XCTAssertEqual(part.anomalies, [])
    }

    // MARK: - The packed 13-byte status, NOT the generic 17-byte header

    /// `EcgStatusHeader` — the older unpacked Labrador model — must never be used for an R16 record.
    /// `docs/PROTOCOL_ECG.md` rules it out for these revisions, and this test shows the damage in
    /// numbers: it puts the sample count 4 bytes late, where a full record's waveform has already begun.
    func testTheGenericSeventeenByteHeaderWouldMisreadThisRecord() {
        let frame = bytes(pureContactOffHex)
        guard let packed = Whoop5EcgRawRecord.Status.decode(frame) else { return XCTFail("status") }
        XCTAssertEqual(packed.declaredSampleCount, 500)
        // The 17-byte model reads the count from payload[15..16], i.e. frame @36..37 — inside the
        // waveform region. The point is not the specific wrong number but that it is not 500.
        let wrong = UInt16(frame[36]) | (UInt16(frame[37]) << 8)
        XCTAssertNotEqual(wrong, packed.declaredSampleCount,
                          "if these ever agree the fixture has stopped demonstrating the layout conflict")
        // And it reads @25 — a progress value that ramps 0, 3, 6 … 100 across a session — as a BOOLEAN.
        XCTAssertEqual(packed.progress, 100, "this record completed its session")
    }

    func testStatusFieldsThatAreDocumentedZeroOnR16AreZero() {
        for hex in [pureContactOffHex, contactTransitionHex, partialRecordHex] {
            guard let s = Whoop5EcgRawRecord.Status.decode(bytes(hex)) else { return XCTFail("status") }
            XCTAssertEqual(s.hrRelatedR17, 0, "@28 is an R17 field and a zero placeholder on R16")
            XCTAssertEqual(s.reservedZero, 0, "@31 is a placeholder, NOT a measured stress value")
            XCTAssertEqual(s.packedBooleans, 0)
        }
    }

    // MARK: - The contact grouping rule (docs/PROTOCOL_ECG.md, 500 raw / 10 slower)

    /// The doc gives this grouping explicitly, and getting it wrong is silent: ten equal groups of 50
    /// misplaces every contact boundary by one sample and still produces a plausible-looking array.
    func testFiveHundredOverTenIsFiftyOneThenEightFiftiesThenFortyNine() {
        XCTAssertEqual(Whoop5EcgRawRecord.contactGroupSizes(sampleCount: 500, contactCount: 10),
                       [51, 50, 50, 50, 50, 50, 50, 50, 50, 49])
        XCTAssertNotEqual(Whoop5EcgRawRecord.contactGroupSizes(sampleCount: 500, contactCount: 10),
                          Array(repeating: 50, count: 10),
                          "ten equal groups is the documented WRONG answer")
    }

    func testGroupSizesAlwaysPartitionTheSamplesExactly() {
        for (n, c) in [(500, 10), (500, 11), (245, 10), (100, 10), (7, 3)] {
            let sizes = Whoop5EcgRawRecord.contactGroupSizes(sampleCount: n, contactCount: c)
            XCTAssertEqual(sizes.reduce(0, +), n, "\(n)/\(c) must cover every sample exactly once")
        }
        // Oracle-pinned shapes for the counts the corpus actually carries.
        XCTAssertEqual(Whoop5EcgRawRecord.contactGroupSizes(sampleCount: 500, contactCount: 11),
                       [46, 45, 45, 45, 45, 45, 45, 45, 45, 45, 49])
        XCTAssertEqual(Whoop5EcgRawRecord.contactGroupSizes(sampleCount: 245, contactCount: 10),
                       [25, 24, 24, 24, 24, 24, 24, 24, 24, 28])
    }

    func testDegenerateCountsProduceNoGroupsRatherThanACrash() {
        XCTAssertEqual(Whoop5EcgRawRecord.contactGroupSizes(sampleCount: 0, contactCount: 10), [])
        XCTAssertEqual(Whoop5EcgRawRecord.contactGroupSizes(sampleCount: 500, contactCount: 0), [])
        XCTAssertEqual(Whoop5EcgRawRecord.contactGroupSizes(sampleCount: 5, contactCount: 10), [],
                       "fewer samples than contact entries has no divisor, so it has no grouping")
    }

    // MARK: - Bounds are quarantined, never truncated

    func testAWaveformCountOverCapacityIsQuarantinedRatherThanTruncated() {
        var frame = bytes(pureContactOffHex)
        frame[32] = 0xF4; frame[33] = 0x01  // 500 -> fine
        XCTAssertEqual(Whoop5EcgRawRecord.decode(frame)?.samples.count, 500)
        frame[32] = 0xF5; frame[33] = 0x01  // 501 — one past capacity
        guard let over = Whoop5EcgRawRecord.decode(frame) else { return XCTFail("decode") }
        XCTAssertTrue(over.samples.isEmpty,
                      "the doc forbids silently truncating an over-capacity count: 500 plausible samples out of a record that contradicted its own header is the worst available answer")
        XCTAssertEqual(over.anomalies, [.waveformCountOverCapacity(declared: 501)])
        // The lead-off diagnostics are an INDEPENDENT region and survive the waveform's quarantine —
        // they are exactly what a reader wants when the waveform is the part that went wrong.
        XCTAssertEqual(over.leadOffCount, 10)
        XCTAssertEqual(over.leadOffI.count, 10)
    }

    func testALeadOffCountOverCapacityIsQuarantinedAndLeavesTheWaveformAlone() {
        var frame = bytes(pureContactOffHex)
        frame[Whoop5EcgRawRecord.leadOffCountOffset] = 12  // capacity is 11
        guard let r = Whoop5EcgRawRecord.decode(frame) else { return XCTFail("decode") }
        XCTAssertEqual(r.samples.count, 500, "a bad diagnostic count says nothing about the waveform")
        XCTAssertTrue(r.leadOffI.isEmpty)
        XCTAssertEqual(r.anomalies, [.leadOffCountOverCapacity(declared: 12)])
        XCTAssertEqual(r.contactFlags, [], "with no usable slower count there is no grid to collapse onto")
    }

    func testReservedBitsAreCountedNotFoldedIntoASampleOrDiscarded() {
        var frame = bytes(pureContactOffHex)
        // Set bit 2 on the first two waveform words — a bit that is clear in all 62,000 corpus samples.
        frame[34] |= 0x04
        frame[37] |= 0x04
        guard let r = Whoop5EcgRawRecord.decode(frame) else { return XCTFail("decode") }
        XCTAssertEqual(r.anomalies, [.reservedBitsSet(words: 2)])
        XCTAssertEqual(r.samples.count, 500, "the samples are still read — the bits are reported, not obeyed")
        // The reserved bits must not leak into the sample's magnitude.
        XCTAssertEqual(r.samples[0], 90024, "bits 2-5 are not part of the 18-bit value")
    }

    func testAFrameOfTheWrongLengthReadsNoFixedRegionAtAll() {
        let short = Array(bytes(pureContactOffHex).prefix(600))
        guard let r = Whoop5EcgRawRecord.decode(short) else { return XCTFail("decode") }
        XCTAssertEqual(r.anomalies, [.unexpectedFrameLength(600)])
        XCTAssertTrue(r.samples.isEmpty, "the fixed offsets are only fixed in a 1584-byte frame")
        XCTAssertEqual(r.leadOffCount, 0)
        // The header the frame IS long enough to carry still decodes — a short frame is not a total loss.
        XCTAssertEqual(r.recordIndex, 29_868_864)
        XCTAssertEqual(r.status.declaredSampleCount, 500)
    }

    func testAFrameTooShortForTheStatusBlockDecodesToNil() {
        XCTAssertNil(Whoop5EcgRawRecord.decode(Array(bytes(pureContactOffHex).prefix(20))))
    }

    // MARK: - Sample coding

    func testSlotDecodingSplitsTheEighteenBitValueFromItsTwoFlags() {
        // Flags set, value 0 — the flags must contribute nothing to the magnitude.
        XCTAssertEqual(Whoop5EcgRawRecord.decodeSlot(0xC0, 0x00, 0x00).sample, 0)
        XCTAssertTrue(Whoop5EcgRawRecord.decodeSlot(0xC0, 0x00, 0x00).flag6)
        XCTAssertTrue(Whoop5EcgRawRecord.decodeSlot(0xC0, 0x00, 0x00).flag7)
        XCTAssertFalse(Whoop5EcgRawRecord.decodeSlot(0x00, 0x00, 0x00).flag6)
        // The two's-complement boundary the doc names: 131071 is the largest positive, 131072 wraps.
        XCTAssertEqual(Whoop5EcgRawRecord.decodeSlot(0x01, 0xFF, 0xFF).sample, 131_071)
        XCTAssertEqual(Whoop5EcgRawRecord.decodeSlot(0x02, 0x00, 0x00).sample, -131_072)
        XCTAssertEqual(Whoop5EcgRawRecord.decodeSlot(0x03, 0xFF, 0xFF).sample, -1)
        // Flags must not shift that boundary.
        XCTAssertEqual(Whoop5EcgRawRecord.decodeSlot(0xC3, 0xFF, 0xFF).sample, -1)
        XCTAssertEqual(Whoop5EcgRawRecord.decodeSlot(0x83, 0xFF, 0xFF).sample, -1)
    }

    func testReservedBitsAreReportedSeparatelyFromTheFlags() {
        let slot = Whoop5EcgRawRecord.decodeSlot(0x3C, 0x00, 0x01)
        XCTAssertEqual(slot.reservedBits, 0x0F)
        XCTAssertFalse(slot.flag6)
        XCTAssertFalse(slot.flag7)
        XCTAssertEqual(slot.sample, 1)
    }

    // MARK: - The interpreter publishes the same facts

    func testTheInterpreterPublishesEverySampleAndDropsTheOldTagTally() {
        let p = parseFrame(bytes(pureContactOffHex), family: .whoop5)
        XCTAssertEqual(p.parsed["hist_version"]?.intValue, 16)
        XCTAssertEqual(p.crcOK, true, "fixture must be CRC-valid")
        XCTAssertEqual(p.parsed["ecg_candidate"]?.intArrayValue?.count, 500,
                       "the field map must carry what the decoder carries")
        XCTAssertEqual(p.parsed["ecg_candidate_count"]?.intValue, 500)
        XCTAssertNil(p.parsed["ecg_candidate_unexpected_tag_count"],
                     "the superseded tally counted ordinary flag-bearing samples as anomalies")
        XCTAssertEqual(p.parsed["ecg_progress"]?.intValue, 100)
        XCTAssertEqual(p.parsed["ecg_lead_off_count"]?.intValue, 10)
        XCTAssertEqual(p.parsed["ecg_contact_flags"]?.intArrayValue, Array(repeating: 0, count: 10))
        XCTAssertEqual(p.parsed["ecg_sample_flags"]?.intArrayValue?.count, 500)
    }
}
