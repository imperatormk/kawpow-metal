#include "crypto/ethash/lib/ethash/ethash-internal.hpp"
#include "crypto/ethash/include/ethash/progpow.hpp"
#include "crypto/ethash/lib/ethash/kiss99.hpp"
#include <cstdio>
#include <cstdlib>
extern "C" void ethash_keccakf800(uint32_t state[25]);

static uint32_t fnv1a_local(uint32_t h, uint32_t d) { return (h ^ d) * 0x01000193; }

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "Usage: test_fill_mix <header_hex> <nonce_hex>\n"); return 1; }

    uint8_t header_bytes[32];
    for (int i = 0; i < 32; i++) {
        char buf[3] = {argv[1][i*2], argv[1][i*2+1], 0};
        header_bytes[i] = (uint8_t)strtol(buf, nullptr, 16);
    }
    uint64_t nonce = strtoull(argv[2], nullptr, 16);

    uint32_t state[25] = {0};
    for (int i = 0; i < 8; i++)
        state[i] = header_bytes[i*4] | (header_bytes[i*4+1]<<8) | (header_bytes[i*4+2]<<16) | (header_bytes[i*4+3]<<24);
    state[8] = (uint32_t)(nonce & 0xFFFFFFFF);
    state[9] = (uint32_t)(nonce >> 32);
    uint32_t rvnc[15] = {0x72,0x41,0x56,0x45,0x4E,0x43,0x4F,0x49,0x4E,0x4B,0x41,0x57,0x50,0x4F,0x57};
    for (int i = 10; i < 25; i++) state[i] = rvnc[i-10];
    ethash_keccakf800(state);

    printf("State2: ");
    for (int i = 0; i < 8; i++) printf("%08x ", state[i]);
    printf("\n");

    // init_mix for lane 0
    uint32_t z = fnv1a_local(0x811c9dc5, state[0]);
    uint32_t w = fnv1a_local(z, state[1]);
    uint32_t jsr = fnv1a_local(w, 0); // lane 0
    uint32_t jcong = fnv1a_local(jsr, 0);
    kiss99 rng{z, w, jsr, jcong};

    printf("KISS99: z=%08x w=%08x jsr=%08x jcong=%08x\n", z, w, jsr, jcong);
    printf("Mix[0..7]: ");
    for (int i = 0; i < 32; i++) {
        uint32_t v = rng();
        if (i < 8) printf("%08x ", v);
    }
    printf("\n");
    return 0;
}
