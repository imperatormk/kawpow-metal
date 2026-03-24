// Dumps the ethash light cache for a given epoch to a binary file
// Build: cd ~/projects/oss/ravencoin && g++ -O3 -std=c++17 -I src \
//   ../kawpow-metal/dump_light_cache.cpp \
//   src/crypto/ethash/lib/ethash/ethash.cpp \
//   src/crypto/ethash/lib/ethash/primes.c \
//   src/crypto/ethash/lib/ethash/managed.cpp \
//   src/crypto/ethash/lib/keccak/keccak.c \
//   src/crypto/ethash/lib/keccak/keccakf800.c \
//   src/crypto/ethash/lib/keccak/keccakf1600.c \
//   src/crypto/ethash/lib/ethash/progpow.cpp \
//   -o ../kawpow-metal/dump_light_cache

#include "crypto/ethash/lib/ethash/ethash-internal.hpp"
#include "crypto/ethash/include/ethash/progpow.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: dump_light_cache <epoch> <output_prefix>\n");
        fprintf(stderr, "  Writes: <prefix>.light (light cache)\n");
        return 1;
    }

    int epoch = atoi(argv[1]);
    const char* prefix = argv[2];

    printf("Computing light cache for epoch %d...\n", epoch);

    // Use internal API to create epoch context
    auto* ctx = ethash_create_epoch_context(epoch);
    if (!ctx) { fprintf(stderr, "Failed to create epoch context\n"); return 1; }

    printf("Light cache computed!\n");
    printf("  Light cache items: %d\n", ctx->light_cache_num_items);
    printf("  Light cache size: %.1f MB\n",
           (double)ctx->light_cache_num_items * 64 / 1024 / 1024);
    printf("  Full dataset items: %d\n", ctx->full_dataset_num_items);

    // Write light cache
    char fname[256];
    snprintf(fname, sizeof(fname), "%s.light", prefix);
    FILE* f = fopen(fname, "wb");
    if (!f) { perror("fopen"); return 1; }
    int32_t light_items = ctx->light_cache_num_items;
    int32_t dataset_items = ctx->full_dataset_num_items;
    fwrite(&light_items, 4, 1, f);
    fwrite(&dataset_items, 4, 1, f);
    fwrite(ctx->light_cache, 64, light_items, f);
    fclose(f);
    printf("Written to %s\n", fname);

    // Dump first few dataset items for GPU verification
    printf("\nReference DAG items:\n");
    for (int idx = 0; idx < 3; idx++) {
        auto item = ethash::calculate_dataset_item_2048(*ctx, idx);
        printf("  DAG[%d]: ", idx);
        for (int w = 0; w < 16; w++) printf("%08x ", item.word32s[w]);
        printf("\n");
    }
    // Also dump as hash512 (first item)
    auto item0 = ethash::calculate_dataset_item_2048(*ctx, 0);
    printf("  DAG[0] first word: 0x%08x\n", item0.word32s[0]);

    // Test progpow hash
    ethash::hash256 hh = {};
    hh.word32s[0] = 0xdeadbeef;
    auto result = progpow::hash(*ctx, epoch, hh, 0x1234567890abcdefULL);
    printf("  Hash: 0x%08x%08x...\n", result.final_hash.word32s[0], result.final_hash.word32s[1]);
    printf("  Mix:  0x%08x%08x...\n", result.mix_hash.word32s[0], result.mix_hash.word32s[1]);

    ethash_destroy_epoch_context(ctx);

    return 0;
}
