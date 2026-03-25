# kawpow-metal

**The first KAWPOW GPU miner for Apple Silicon.** Mine Ravencoin (RVN) natively on Mac using Metal compute shaders.

## Performance

| Device | Hashrate |
|--------|----------|
| M1 Pro | 6.3 MH/s |
| M1 | ~2.9 MH/s |
| M2/M3 | TBD (should be faster) |

## Quick Start

```bash
git clone https://github.com/imperatormk/kawpow-metal.git
cd kawpow-metal
swift run kawpow-metal --pool rvnswap.xyz:3456 --worker YOUR_RVN_ADDRESS.rig01
```

That's it. No dependencies, no brew installs, no CUDA. Just Xcode command line tools.

## Requirements

- macOS 15+ (Sequoia)
- Apple Silicon (M1/M2/M3/M4)
- Xcode Command Line Tools (`xcode-select --install`)

## Usage

### Pool Mining (recommended)

```bash
swift run kawpow-metal --pool POOL_HOST:PORT --worker YOUR_ADDRESS.RIG_NAME
```

Example with our pool:
```bash
swift run kawpow-metal --pool rvnswap.xyz:3456 --worker RYourAddress.macbook
```

### Solo Mining

Requires a running `ravend` with `-miningaddress=YOUR_ADDRESS`:

```bash
swift run kawpow-metal
```

Connects to `127.0.0.1:18766` (testnet) by default.

## Features

- **Pure Metal compute shaders** — no OpenCL, no CUDA
- **6.3 MH/s on M1 Pro** — doubled from 3.2 via GPU optimizations
- **Epoch-agnostic** — auto-generates light cache for any epoch in ~3 seconds
- **Auto DAG generation** on GPU (~43 seconds)
- **Stratum protocol** — works with any KAWPOW pool
- **Double-buffered command buffers** — GPU never idles
- **SIMD group operations** — reduced threadgroup barriers
- **ProgPow kernel recompilation** — auto-adapts every 3 blocks

## How It Works

KAWPOW (ProgPow) is a GPU-friendly Proof of Work algorithm designed to be ASIC-resistant:

1. **Light cache** — generated from epoch seed via Keccak-512 (~55MB)
2. **DAG** — 3.5GB+ lookup table generated on GPU from light cache
3. **Mining** — each thread computes Keccak-f800, accesses random DAG entries, runs epoch-specific random programs
4. **Solution** — when hash meets target difficulty, submit to pool/node

The Metal implementation ports all of this to Apple's GPU compute framework:
- `KawpowShader.metal.template` — GPU kernel (Keccak-f800, DAG access, ProgPow loop)
- `main.swift` — host code (DAG generation, mining loop, stratum client)

## Pool

Join our pool: **[pool.rvnswap.xyz](https://pool.rvnswap.xyz)**

- 1% fee
- PPLNS payouts
- Auto-payout at 100 RVN
- Live hashrate dashboard

## Marketplace

Trade RVN assets: **[rvnswap.xyz](https://rvnswap.xyz)**

## Building

```bash
swift build           # debug build
swift build -c release  # optimized release build
```

## License

MIT
