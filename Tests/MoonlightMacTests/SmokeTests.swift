import Testing
import Copus

@Test func testBasicArithmetic() {
    #expect(1 + 1 == 2)
}

@Test func testCopusDecoderLifecycle() {
    var err: Int32 = 0
    var mapping: [UInt8] = [0, 1]
    let decoder = opus_multistream_decoder_create(
        48000,
        2,
        1,
        1,
        &mapping,
        &err
    )
    #expect(decoder != nil)
    #expect(err == OPUS_OK)
    if let dec = decoder {
        opus_multistream_decoder_destroy(dec)
    }
}

