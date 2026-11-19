# Exchange Connectivity and Market Data Capture

An exchange connectivity stack in C++17 and Python, built against a simulated
ITCH-style multicast feed and an OUCH-style order-entry protocol. It has three
parts:

1. **Market data.** A UDP multicast feed handler that rebuilds full-depth,
   order-by-order (L3) books for 128 instruments, with A/B line arbitration
   and TCP gap recovery when both lines drop the same packets.
2. **Capture, replay and query.** TCAP, a columnar tick-capture format with
   recorded timestamps, so any session replays **bit for bit** (book and wire
   SHA-256 digests match), plus typed queries, a 14-invariant session
   validator, and date/symbol-partitioned Parquet publication checked with
   DuckDB. An independent Python reader, written from the format spec,
   cross-validates the C++ side.
3. **Order entry and routing.** A sequenced order-entry session with resend
   on reconnect, inline pre-trade risk checks (position, notional, message
   rate), and a fee-aware smart order router that splits parent orders
   across five venues by net-of-fee cost.

Every result below is checked against an independent oracle or reference
implementation, and every number comes from raw output committed in
[`docs/`](docs/). How each part works, what broke while building it, and the
full measurement commands are in [DESIGN.md](DESIGN.md); the capture format
is specified in [docs/FORMAT.md](docs/FORMAT.md).

## Honest framing

- **The protocols are inspired by real ones, not conformant to them.** The
  feed is ITCH-style over MoldUDP64-style framing and order entry is
  OUCH-style over a SoupBinTCP-like session, each with its own field layout
  (`include/wire_protocol.hpp`, `include/ouch_session.hpp`).
- **The order flow is synthetic** (`include/market_simulator.hpp`):
  self-consistent, so every Cancel or Execute refers to an order actually
  resting, but not captured exchange data.
- **One host.** The multicast path is real (`IP_ADD_MEMBERSHIP`, a 239.x.x.x
  group, datagrams through the kernel), but cross-host routing was not
  exercised. POSIX only; built and tested on Linux.
- **Timings are from one machine** (Ryzen 7 7800X3D, WSL2 Ubuntu 22.04, g++
  11.4, `-O2`) and move with load. Counts and digests are deterministic and
  reproduce exactly; the results table marks which is which.

## Architecture

```
Market data
  include/wire_protocol.hpp      ITCH-style messages + MoldUDP64-style datagram framing
  include/multicast_posix.hpp    POSIX UDP multicast sender/receiver
  include/feed_decoder.hpp       datagram -> messages -> book, with gap detection
  include/order_book_l3.hpp      full-depth order-by-order book, one instrument
  include/book_universe.hpp      all instruments + O(1) order_id -> location index
  include/line_arbitrator.hpp    A/B line arbitration, first copy wins
  include/gap_recovery.hpp       TCP retransmit path for double-line drops
  include/market_simulator.hpp   deterministic, self-consistent synthetic order flow

Capture, replay and query
  include/column_codec.hpp       RAW / DELTA / DOD / FOR / RLE column encodings
  include/tick_capture.hpp       TCAP columnar writer + selective reader
  include/canonical.hpp          deterministic book serialization for digests
  include/session_validator.hpp  14 named invariants over a record stream
  src/tcap_query.cpp             typed predicate queries over two columns
  python/tickcap/                independent TCAP reader and L3 book, from the spec
  python/publish_parquet.py      date/symbol-partitioned Parquet warehouse
  python/validate_publication.py DuckDB cross-check of the published warehouse

Order entry and routing
  include/tcp_io.hpp             TCP session I/O
  include/ouch_session.hpp       sequenced order entry, logged, resend on reconnect
  include/pre_trade_risk.hpp     inline position / notional / message-rate checks
  include/venue_router.hpp       best-price routing across simulated venues
  include/fee_schedule.hpp       per-venue maker-taker fees and rebates
  include/smart_order_router.hpp net-of-fee parent-order splitting across 5 venues
  python/validate_routing.py     independent Python oracle for the best-price router
  python/validate_sor.py         independent Python oracle for the smart order router
```

## Results

| Part | Result | Kind | Raw output |
|---|---|---|---|
| Market data | **815,678 msgs/sec** live receive path on one thread (recv, decode, L3 book, capture, SHA-256) | timing | DESIGN.md, Throughput |
| Market data | **6.87M msgs/sec** best of 5 (median 6.21M) decode-and-apply replay on one pinned core | timing | [`replay_bench_output.txt`](docs/replay_bench_output.txt) |
| Market data | **5,000 of 5,000** seeded double-line drops recovered over TCP (308,648 messages), book digest identical to the oracle | deterministic | [`live_capture_ab_output.txt`](docs/live_capture_ab_output.txt) |
| Capture | Session replayed **bit for bit**: 43,529 datagrams, 57.5 MiB, book and wire SHA-256 match, including a lossy session's 415 gaps | deterministic | DESIGN.md, Bit-for-bit reproducibility |
| Capture | **4.71x** smaller than a packed row file; a one-column scan touches **33.63x** fewer bytes | deterministic | DESIGN.md, The capture format |
| Query | Typed query **about 318x** faster than tshark-plus-grep on the same capture (overstated by tshark startup at 46.7 MiB) | timing | [`benchmark_output.txt`](docs/benchmark_output.txt) |
| Validation | **280 of 280** seeded defects caught with the failing check named; **0 of 40** clean sessions flagged | deterministic | [`validator_defect_output.txt`](docs/validator_defect_output.txt) |
| Publication | 900,000 records published to 48 Parquet partitions; DuckDB agrees with an independent recomputation on all 48 | deterministic | [`validate_publication_output.txt`](docs/validate_publication_output.txt) |
| Order entry | **p99 8.2us** send-side tick-to-order on loopback; **20 of 20** sequence numbers recovered exactly once across a reconnect | timing, deterministic | [`ouch_session_test_output.txt`](docs/ouch_session_test_output.txt) |
| Risk | **500 of 500** seeded limit breaches rejected, **4,500 of 4,500** valid orders accepted | deterministic | [`pre_trade_risk_output.txt`](docs/pre_trade_risk_output.txt) |
| Routing | **8,000 of 8,000** routing decisions match an independent Python oracle, for both routers | deterministic | [`routing_validation_output.txt`](docs/routing_validation_output.txt), [`sor_validation_output.txt`](docs/sor_validation_output.txt) |
| Routing | Fee-aware router paid **83.24% less** in venue fees than a best-price router on the same 8,000 orders ($1,006.04 vs $6,002.68) | deterministic | [`sor_fee_output.txt`](docs/sor_fee_output.txt) |
| Correctness | **600 checks**, 0 failures, from SHA-256 FIPS vectors up through codecs, wire format, books and gap detection | deterministic | `correctness_test` |

## Building and running

Requires CMake 3.15+, a C++17 compiler and Linux. CI (GitHub Actions) builds
and runs every test, the deterministic checks above, and the Python
cross-validation on each push; `scripts/reproduce.sh` regenerates the
committed outputs into `repro_out/` for comparison with `docs/`.

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
ctest --test-dir build --output-on-failure     # correctness, order entry, routing, validator

python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
scripts/reproduce.sh                           # regenerated outputs land in repro_out/
docker build -t exchange-connectivity . && docker run --rm exchange-connectivity
```

Live multicast needs a larger receive buffer first
(`sudo sysctl -w net.core.rmem_max=134217728`), and captures should go to a
native Linux path such as `/tmp`, not a Windows-mounted one. Per-part commands
are in DESIGN.md.

## Limitations

- Typed query: the benchmark capture is 46.7 MiB, and the measured 318x
  speedup over tshark-plus-grep is overstated by tshark's fixed
  per-invocation startup cost at that size (see DESIGN.md, Findings).
- Simplified ITCH-style protocol and MoldUDP64-style framing; not the real
  specs.
- Synthetic order flow, not captured exchange data.
- Single-host multicast; no cross-host routing exercised.
- The receive path is single-threaded by design (determinism over throughput).
  Parallel decode with deterministic capture is possible, capture pre-shard,
  reassemble by sequence number on replay, but was not built here.
- The simulator generates order *events* without matching semantics. Crossing is
  prevented by construction (finding 2) rather than by orders trading against
  each other, so there is no trade-price series to analyse.
- TCAP has no per-block checksums, no null/missing-value support, no schema
  evolution, and no nested types. A production format would want at least the
  first of those; the reproducibility checks here hash the whole file's
  reconstructed content instead.
- The codecs are integer-oriented. A column of genuinely high-entropy 64-bit
  values falls back to RAW, which is correct but means TCAP is not a general
  compressor, it exploits the specific structure of tick data.
- No kernel-bypass networking. At the rates a real feed handler runs, socket
  syscalls dominate and production systems reach for DPDK or similar; that is
  out of scope here and named rather than glossed over.
- The gateway's A/B line arbitration assumes a single logical
  consumer (both receive threads call into `LineArbitrator` under one mutex;
  see the threading note in `line_arbitrator.hpp`), not a lock-free or
  per-core design.
- Gap recovery's retransmit buffer retains the whole session in the demo
  binaries rather than a bounded, production-sized retention window;
  `RetransmitBuffer` supports eviction (`retention_floor()`) but the demos
  do not exercise it.
- The OUCH-style session is one session at a time with no authentication, no
  order rejection (every EnterOrder is accepted), and no
  Intermarket-Sweep-Order or self-help exceptions; it is the sequencing and
  resend mechanics, not a matching engine or a compliance-aware gateway.
- Tick-to-order latency measures the client-side cost of building an OUCH
  frame and handing it to the kernel's socket send buffer, not a full
  order-to-acknowledgment round trip and not any market-data decode time;
  see Findings for exactly what the three measurement attempts isolated.
- Multi-venue router: the 3 venues are 3 independent in-process
  `MarketSimulator`+`BookUniverse` instances, not 3 real feed handlers over
  the network; routing decisions never touch a real socket (the actual
  OUCH wire path is the unchanged, separately-measured gateway
  above). `PreTradeRiskChecker`'s position model is order-flow risk (every
  accepted order moves the position), not post-fill risk against actual
  executions, and it has no awareness of cancels or replaces reducing an
  earlier order's exposure.
- Session validator: `SessionValidator` is deliberately a second,
  from-scratch bookkeeper rather than a wrapper around `BookUniverse`, so
  its 14 checks can catch what `BookUniverse` is designed to tolerate
  (over-sized Execute/Cancel after a gap); it does not currently check
  level-aggregate consistency (sum of resting orders at a price equals the
  level's tracked total) as its own named assertion, only crossed-ness and
  the per-order checks above. The 280 seeded defects are each a single
  malformed record spliced into an otherwise clean session; no case
  combines two simultaneous defects.
- Parquet publication: a session has no calendar date of its own
  (`publish_parquet.py` is told the date explicitly, see DESIGN.md);
  "date partitioned" is demonstrated across 3 distinct dates built from 3
  separate sessions, not a single multi-day session split by wall-clock
  rollover. The published Parquet is a demo warehouse under `/tmp`, not a
  committed artifact (regenerate with the commands in DESIGN.md).
- Smart order router: depth is capped at the top 3 price levels
  per venue (`kSorDepth`), so an order can exhaust all visible depth and
  fill only partially; that happened on 1,851 of the 8,000 measured orders
  (fully filled: 6,149 / 8,000, `docs/sor_fee_output.txt`), and is reported
  as a genuine, not a hidden, shortfall. The 5 venues' displayed sizes are
  a random fragmentation of one shared consolidated book rather than 5
  independently-generated order books (see DESIGN.md for
  why); this makes price agreement across venues realistic but means the
  5 venues are not modeling 5 independently-arriving order flows at that
  price. The fee schedule is static for the whole measurement run, not a
  tiered or volume-based schedule, and the router does not model partial
  fills being cancel-and-replaced to chase a moving book intraday.
