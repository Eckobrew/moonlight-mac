import Foundation
import CryptoKit
import CommonCrypto

public enum CryptoUtils {
    public static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        return data
    }

    public static func sha256(_ data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func dataFromHex(_ hex: String) -> Data? {
        var data = Data()
        let hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.count % 2 != 0 { return nil }

        var index = hexStr.startIndex
        while index < hexStr.endIndex {
            let nextIndex = hexStr.index(index, offsetBy: 2)
            let byteStr = String(hexStr[index..<nextIndex])
            guard let byte = UInt8(byteStr, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    public static func deriveKey(salt: Data, pin: String) -> Data {
        var combined = salt
        if let pinData = pin.data(using: .utf8) {
            combined.append(pinData)
        }
        let hash = sha256(combined)
        return hash.prefix(16) // 128-bit AES key
    }

    public static func aes128EcbEncrypt(data: Data, key: Data) -> Data? {
        return aesCrypt(operation: CCOperation(kCCEncrypt), mode: CCMode(kCCModeECB), data: data, key: key, iv: nil)
    }

    public static func aes128EcbDecrypt(data: Data, key: Data) -> Data? {
        return aesCrypt(operation: CCOperation(kCCDecrypt), mode: CCMode(kCCModeECB), data: data, key: key, iv: nil)
    }

    public static func aes128CbcEncrypt(data: Data, key: Data, iv: Data) -> Data? {
        return aesCrypt(operation: CCOperation(kCCEncrypt), mode: CCMode(kCCModeCBC), data: data, key: key, iv: iv)
    }

    public static func aes128CbcDecrypt(data: Data, key: Data, iv: Data) -> Data? {
        return aesCrypt(operation: CCOperation(kCCDecrypt), mode: CCMode(kCCModeCBC), data: data, key: key, iv: iv)
    }

    private static func aesCrypt(operation: CCOperation, mode: CCMode, data: Data, key: Data, iv: Data?) -> Data? {
        var outLength: size_t = 0
        let bufferLength = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferLength)

        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                buffer.withUnsafeMutableBytes { outBytes in
                    let ivPtr = iv != nil ? (iv! as NSData).bytes : nil
                    return CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        0, // no padding for fixed blocks
                        keyBytes.baseAddress,
                        kCCKeySizeAES128,
                        ivPtr,
                        dataBytes.baseAddress,
                        data.count,
                        outBytes.baseAddress,
                        bufferLength,
                        &outLength
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(outLength)
    }
}
