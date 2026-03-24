#include "../kawpowminer/libprogpow/ProgPow.h"
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "Usage: dump_kernel <height>\n"); return 1; }
    int height = atoi(argv[1]);
    uint64_t prog_seed = height / 3;
    printf("// Height: %d, ProgSeed: %llu\n", height, (unsigned long long)prog_seed);
    printf("%s", ProgPow::getKern(prog_seed, ProgPow::KERNEL_CL).c_str());
    return 0;
}
