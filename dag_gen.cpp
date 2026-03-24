// Standalone DAG generator using Ravencoin's ethash library
// Compile: g++ -O3 -std=c++17 -I../ravencoin/src/crypto/ethash/include dag_gen.cpp ../ravencoin/src/crypto/ethash/lib/ethash/ethash.cpp ../ravencoin/src/crypto/ethash/lib/ethash/primes.c ../ravencoin/src/crypto/ethash/lib/ethash/managed.cpp ../ravencoin/src/crypto/ethash/lib/keccak/keccak.c ../ravencoin/src/crypto/ethash/lib/keccak/keccakf800.c ../ravencoin/src/crypto/ethash/lib/keccak/keccakf1600.c -o dag_gen

#include <ethash/ethash.hpp>
#include <ethash/progpow.hpp>
#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: dag_gen <epoch> <output_file>\n");
        fprintf(stderr, "  Also writes light cache to <output_file>.cache\n");
        return 1;
    }

    int epoch = atoi(argv[1]);
    const char* outfile = argv[2];

    printf("Generating DAG for epoch %d...\n", epoch);

    auto& context = ethash::get_global_epoch_context_full(epoch);
    int num_items = context.full_dataset_num_items;
    size_t dag_size = (size_t)num_items * sizeof(ethash::hash2048);

    printf("DAG items: %d\n", num_items);
    printf("DAG size: %.2f GB\n", dag_size / 1024.0 / 1024.0 / 1024.0);
    printf("Light cache items: %d\n", context.light_cache_num_items);

    // Write light cache
    char cachefile[256];
    snprintf(cachefile, sizeof(cachefile), "%s.cache", outfile);
    FILE* fc = fopen(cachefile, "wb");
    if (!fc) { perror("fopen cache"); return 1; }
    int lc_items = context.light_cache_num_items;
    fwrite(&lc_items, sizeof(int), 1, fc);
    fwrite(context.light_cache, sizeof(ethash::hash512), lc_items, fc);
    fclose(fc);
    printf("Light cache written to %s (%d items)\n", cachefile, lc_items);

    // Write full DAG
    printf("Writing full DAG to %s...\n", outfile);
    FILE* f = fopen(outfile, "wb");
    if (!f) { perror("fopen"); return 1; }

    fwrite(&num_items, sizeof(int), 1, f);

    for (int i = 0; i < num_items; i++) {
        auto item = ethash::calculate_dataset_item_2048(context, i);
        fwrite(&item, sizeof(ethash::hash2048), 1, f);
        if (i % 100000 == 0)
            printf("\r  %d / %d (%.1f%%)", i, num_items, 100.0 * i / num_items);
    }
    printf("\r  %d / %d (100.0%%)\n", num_items, num_items);

    fclose(f);
    printf("Done! DAG written to %s\n", outfile);
    return 0;
}
