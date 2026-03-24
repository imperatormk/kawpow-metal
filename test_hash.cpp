#include "crypto/ethash/lib/ethash/ethash-internal.hpp"
#include "crypto/ethash/include/ethash/progpow.hpp"
extern "C" void ethash_keccakf800(uint32_t state[25]);
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "Usage: test_hash <height> <header_hex> <nonce_hex>\n");
        return 1;
    }
    int height = atoi(argv[1]);
    int epoch = height / 7500;
    const char* header_hex = argv[2];
    uint64_t nonce = strtoull(argv[3], nullptr, 16);

    auto* ctx = ethash_create_epoch_context(epoch);

    // Parse header hash
    ethash::hash256 header = {};
    for (int i = 0; i < 32; i++) {
        char buf[3] = {header_hex[i*2], header_hex[i*2+1], 0};
        ((uint8_t*)&header)[i] = (uint8_t)strtol(buf, nullptr, 16);
    }

    printf("Header: ");
    for (int i = 0; i < 8; i++) printf("%08x ", header.word32s[i]);
    printf("\nNonce: 0x%llx\n", (unsigned long long)nonce);
    printf("Height/Epoch: %d/%d\n", height, epoch);
    printf("ProgSeed: %llu\n", (unsigned long long)(height / 3));

    auto result = progpow::hash(*ctx, height, header, nonce);

    printf("Mix:    ");
    for (int i = 0; i < 8; i++) printf("%08x", result.mix_hash.word32s[i]);
    printf("\nDigest: ");
    for (int i = 0; i < 8; i++) printf("%08x", result.final_hash.word32s[i]);
    printf("\n");

    // Also compute just the initial keccak to verify
    uint32_t kstate[25] = {0};
    for (int i = 0; i < 8; i++) kstate[i] = header.word32s[i];
    kstate[8] = (uint32_t)(nonce & 0xFFFFFFFF);
    kstate[9] = (uint32_t)(nonce >> 32);
    uint32_t rvnc[15] = {0x72,0x41,0x56,0x45,0x4E,0x43,0x4F,0x49,0x4E,0x4B,0x41,0x57,0x50,0x4F,0x57};
    for (int i = 10; i < 25; i++) kstate[i] = rvnc[i-10];
    printf("Pre-keccak: ");
    for (int i = 0; i < 10; i++) printf("%08x ", kstate[i]);
    printf("\n");
    ethash_keccakf800(kstate);
    printf("State2:     ");
    for (int i = 0; i < 8; i++) printf("%08x ", kstate[i]);
    printf("\n");

    ethash_destroy_epoch_context(ctx);
    return 0;
}
