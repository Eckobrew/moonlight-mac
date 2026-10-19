#include "Limelight-internal.h"
#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonCryptor.h>
#include <stdlib.h>
#include <string.h>

extern CCCryptorStatus CCCryptorGCM(CCOperation op, CCAlgorithm alg,
                                    const void *key, size_t keyLength,
                                    const void *iv, size_t ivLen,
                                    const void *aData, size_t aDataLen,
                                    const void *dataIn, size_t dataInLength,
                                    void *dataOut,
                                    void *tagOut, size_t *tagLength);

static int addPkcs7PaddingInPlace(unsigned char* plaintext, int plaintextLen) {
    int paddedLength = ROUND_TO_PKCS7_PADDED_LEN(plaintextLen);
    unsigned char paddingByte = (unsigned char)(16 - (plaintextLen % 16));
    memset(&plaintext[plaintextLen], paddingByte, paddedLength - plaintextLen);
    return paddedLength;
}

PPLT_CRYPTO_CONTEXT PltCreateCryptoContext(void) {
    PPLT_CRYPTO_CONTEXT ctx = (PPLT_CRYPTO_CONTEXT)malloc(sizeof(PLT_CRYPTO_CONTEXT));
    if (!ctx) return NULL;
    memset(ctx, 0, sizeof(*ctx));
    return ctx;
}

void PltDestroyCryptoContext(PPLT_CRYPTO_CONTEXT ctx) {
    if (!ctx) return;
    if (ctx->cryptor) {
        CCCryptorRelease((CCCryptorRef)ctx->cryptor);
        ctx->cryptor = NULL;
    }
    free(ctx);
}

void PltGenerateRandomData(unsigned char* data, int length) {
    arc4random_buf(data, length);
}

bool PltEncryptMessage(PPLT_CRYPTO_CONTEXT ctx, int algorithm, int flags,
                       unsigned char* key, int keyLength,
                       unsigned char* iv, int ivLength,
                       unsigned char* tag, int tagLength,
                       unsigned char* inputData, int inputDataLength,
                       unsigned char* outputData, int* outputDataLength) {
    if (algorithm == ALGORITHM_AES_GCM) {
        if (!tag || tagLength <= 0) return false;
        size_t actualTagLen = tagLength;
        CCCryptorStatus st = CCCryptorGCM(kCCEncrypt, kCCAlgorithmAES,
                                          key, keyLength, iv, ivLength,
                                          NULL, 0,
                                          inputData, inputDataLength,
                                          outputData, tag, &actualTagLen);
        if (st != kCCSuccess) return false;
        *outputDataLength = inputDataLength;
        return true;
    } else if (algorithm == ALGORITHM_AES_CBC) {
        int inLen = inputDataLength;
        if (flags & CIPHER_FLAG_PAD_TO_BLOCK_SIZE) {
            inLen = addPkcs7PaddingInPlace(inputData, inputDataLength);
        }
        CCCryptorRef cryptor = NULL;
        CCCryptorStatus st = CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES, 0,
                                             key, keyLength, iv, &cryptor);
        if (st != kCCSuccess) return false;
        size_t moved = 0;
        st = CCCryptorUpdate(cryptor, inputData, inLen, outputData, inLen, &moved);
        size_t finalMoved = 0;
        if (st == kCCSuccess && (flags & CIPHER_FLAG_FINISH)) {
            st = CCCryptorFinal(cryptor, outputData + moved, inLen - moved, &finalMoved);
        }
        CCCryptorRelease(cryptor);
        if (st != kCCSuccess) return false;
        *outputDataLength = (int)(moved + finalMoved);
        return true;
    }
    return false;
}

bool PltDecryptMessage(PPLT_CRYPTO_CONTEXT ctx, int algorithm, int flags,
                       unsigned char* key, int keyLength,
                       unsigned char* iv, int ivLength,
                       unsigned char* tag, int tagLength,
                       unsigned char* inputData, int inputDataLength,
                       unsigned char* outputData, int* outputDataLength) {
    if (algorithm == ALGORITHM_AES_GCM) {
        if (!tag || tagLength <= 0) return false;
        size_t actualTagLen = tagLength;
        CCCryptorStatus st = CCCryptorGCM(kCCDecrypt, kCCAlgorithmAES,
                                          key, keyLength, iv, ivLength,
                                          NULL, 0,
                                          inputData, inputDataLength,
                                          outputData, tag, &actualTagLen);
        if (st != kCCSuccess) return false;
        *outputDataLength = inputDataLength;
        return true;
    } else if (algorithm == ALGORITHM_AES_CBC) {
        CCOptions options = 0;
        if (flags & CIPHER_FLAG_FINISH) {
            options |= kCCOptionPKCS7Padding;
        }

        CCCryptorRef cryptor = NULL;
        bool shouldRelease = false;

        if (ctx != NULL && ctx->cryptor != NULL && (flags & CIPHER_FLAG_RESET_IV)) {
            cryptor = (CCCryptorRef)ctx->cryptor;
            CCCryptorStatus resetSt = CCCryptorReset(cryptor, iv);
            if (resetSt != kCCSuccess) {
                CCCryptorRelease(cryptor);
                ctx->cryptor = NULL;
                cryptor = NULL;
            }
        }

        if (cryptor == NULL) {
            CCCryptorStatus st = CCCryptorCreate(kCCDecrypt, kCCAlgorithmAES, options,
                                                 key, keyLength, iv, &cryptor);
            if (st != kCCSuccess) return false;

            if (ctx != NULL) {
                if (ctx->cryptor != NULL) {
                    CCCryptorRelease((CCCryptorRef)ctx->cryptor);
                }
                ctx->cryptor = cryptor;
                ctx->initialized = true;
            } else {
                shouldRelease = true;
            }
        }

        size_t moved = 0;
        size_t avail = ROUND_TO_PKCS7_PADDED_LEN(inputDataLength);
        CCCryptorStatus st = CCCryptorUpdate(cryptor, inputData, inputDataLength, outputData, avail, &moved);
        if (st != kCCSuccess) {
            if (shouldRelease) {
                CCCryptorRelease(cryptor);
            }
            return false;
        }

        size_t finalMoved = 0;
        if (flags & CIPHER_FLAG_FINISH) {
            st = CCCryptorFinal(cryptor, outputData + moved, avail - moved, &finalMoved);
            if (st != kCCSuccess) {
                // If PKCS7 padding fails, fall back to raw CBC
                if (shouldRelease) {
                    CCCryptorRelease(cryptor);
                } else if (ctx != NULL) {
                    CCCryptorRelease((CCCryptorRef)ctx->cryptor);
                    ctx->cryptor = NULL;
                }
                CCCryptorRef rawCryptor = NULL;
                if (CCCryptorCreate(kCCDecrypt, kCCAlgorithmAES, 0, key, keyLength, iv, &rawCryptor) == kCCSuccess) {
                    st = CCCryptorUpdate(rawCryptor, inputData, inputDataLength, outputData, avail, &moved);
                    CCCryptorRelease(rawCryptor);
                    if (st == kCCSuccess) {
                        *outputDataLength = (int)moved;
                        return true;
                    }
                }
                return false;
            }
        }

        if (shouldRelease) {
            CCCryptorRelease(cryptor);
        }

        *outputDataLength = (int)(moved + finalMoved);
        return true;
    }
    return false;
}
