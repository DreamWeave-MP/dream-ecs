# Dream ECS on l3i 2.0: before and after

What moving the package onto l3i 2.0 (the dialect and the `@dream/data` plane) changed, measured.
`ECS-BENCHMARKS.md` is the older 0.2.1 report from another machine; nothing here is comparable
with it, and nothing there has been rerun.

- Machine: Intel Core i7-10870H @ 2.20GHz, 16 threads, 15 GB, Linux 7.2.8. Shared with four other
  agents' test runs at the time, so wall time is noisy.
- Date: 2026-10-12.
- Binary: `jess 0.1.0`, the verified release build on l3i 2.0.1 (`target/l3i2/jess`), with
  `org.dreamweave.jessql` 0.1.6.
- Base: commit `19fcd35` (the package as it was, plus the pinning tests and the bench additions).
  Head: commit `66068da`. Both sides ran the head's bench files.

Each bench file was run with its default arguments against the base export and against the
package, base then head, five rounds, all eighteen files inside one hold of the shared bench lock:

```sh
flock ~/.cache/agents-bench.lock systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 \
  jess run --package <base export | jpk/dream-ecs> --package-path jpk <package>/bench/<file>.luau
```

The numbers are the median of the five values each file printed. Most files time one pass of
their workload, so a row under about 3 ms is one short sample a round and mostly noise.

## What moved

| File | Workload | Base | Head | Base / head |
|---|---|---:|---:|---:|
| `spawn` | `spawnBatch`, 1,000,000 × Position + Velocity | 194.3 ms | 16.5 ms | 11.8x |
| `spawn` | `spawnBatch`, 1,000,000 × Position + Health (two non-zero defaults) | 341.9 ms | 15.8 ms | 21.7x |
| `spawn` | `spawnBatch`, 250,000 into freed slots and used rows | 84.4 ms | 5.72 ms | 14.8x |
| `structural` | `spawnBatch`, 200,000, 4,096-row chunks | 39.96 ms | 3.53 ms | 11.3x |
| `movement_fair` | `spawnBatch`, 1,048,576, 4,096-row chunks | 209.9 ms | 17.8 ms | 11.8x |
| `bulk_structural` | `addQuery` of a tag, 200,000 | 18.36 ms | 3.23 ms | 5.7x |
| `bulk_structural` | `removeQuery` of a tag, 200,000 | 14.82 ms | 3.32 ms | 4.5x |
| `bulk_data` | `addQuery` of Health with values, 200,000 | 37.33 ms | 3.94 ms | 9.5x |
| `bulk_data` | `removeQuery` of Health, 200,000 | 14.45 ms | 3.36 ms | 4.3x |
| `bulk_data` | `addQuery` of Health, defaults over used rows, 200,000 | 42.20 ms | 3.72 ms | 11.4x |
| `relation` | `relate`, 200,000 edges | 252.5 ms | 148.7 ms | 1.70x |
| `relation_hot` | hot relation query, 200 rows a query | 42.06 µs | 27.23 µs | 1.55x |
| `structural` | `add` of a tag, 50,000 | 48.81 ms | 39.56 ms | 1.23x |
| `structural` | `remove` of a tag, 50,000 | 47.57 ms | 39.65 ms | 1.20x |
| `structural` | `add` of Health with values, 50,000 | 58.04 ms | 47.10 ms | 1.23x |
| `structural` | `remove` of Health, 50,000 | 50.00 ms | 41.36 ms | 1.21x |
| `bulk_structural` | `add` of a tag one entity at a time, 200,000 | 189.9 ms | 163.5 ms | 1.16x |
| `structural` | random `get` + `set`, 800,000 pairs | 251.4 ms | 227.9 ms | 1.10x |
| `component_scan` | `COUNT(*), AVG(axisX)` over 1,000,000 Position rows | 233.8 ms | 216.8 ms | 1.08x |

## What did not

| File | Workload | Base | Head | Base / head |
|---|---|---:|---:|---:|
| `movement_fair` | compiled movement loop, per entity per frame | 7.43 ns | 7.34 ns | no change |
| `movement_fair` | the same loop over raw chunked buffers | 7.39 ns | 7.27 ns | no change |
| `movement` | compiled movement loop, 1,024-row chunks | 7.46 ns | 7.28 ns | no change |
| `system` | movement through `world:step`, per entity per frame | 6.42 ns | 6.60 ns | no change |
| `spawn` | `destroy`, 250,000 | 61.04 ms | 59.20 ms | no change |
| `events` | `emit`, 500,000 | 248.4 ms | 246.9 ms | no change |
| `events_reserve` | `reserve` and direct writes, 500,000 | 10.21 ms | 10.65 ms | no change |
| `entity_field` | `set` + `get` of an entity field, 1,000,000 pairs | 272.0 ms | 267.4 ms | no change |
| `relation` | `has`, 200,000 lookups | 33.25 ms | 34.72 ms | no change |
| `relation_hot` | the same join through cold JessQL | 210.1 µs | 211.5 µs | no change |
| `relation_sql` | direct / joined relation SQL | 115.1 / 220.0 µs | 118.2 / 220.2 µs | no change |
| `relation_sql_direct` | direct relation SQL | 119.2 µs | 120.8 µs | no change |
| `component_sql` | indexed lookup / join | 2.24 / 3.53 µs | 2.29 / 3.58 µs | no change |
| `query` | `COUNT(*)` over 1,000,000 entities | 317.9 ms | 324.9 ms | no change |
| `query` | compile / cached lookup | 32.4 µs / 29.9 ns | 31.6 µs / 28.1 ns | no change |
| `scheduler` | register / schedule 4,000 systems | 7.95 / 1.16 ms | 7.61 / 1.24 ms | no change |

The last two rows differ by six percent in places. No code on those paths changed, and each is a
single sample of one to three milliseconds: that is the noise floor of this run, not a result.

## Why

The large numbers are the two bulk paths, and most of each is batching, not the data plane.
`spawnBatch` used to make four method calls and one `writeInitial` per entity. It now works a
chunk run at a time: entity ids in one loop, each default as one `data.fill` of its column, and
the locator slots of new entities as one strided fill (`u32@8`, the generation and archetype half
of every 8-byte slot) plus a ramp of rows. The fills are the data plane's share: a batch with two
non-zero defaults now costs what a batch with none does, where it cost 1.8 times as much.
`addQuery` and `removeQuery` already copied columns in runs; what they did per entity was
initialize the added component and repoint the locator through two method calls, and both are now
one pass a run. Measured alone on this machine, `data.fill` of an f32 column runs at 0.26 ns an
element against 3.1 ns for the `buffer.writef32` loop.

Two things the data plane was tried for and lost: repointing locator slots with three
`data.scatter` calls over a flat locator (10.0 ns an entity against 8.9 ns for the plain loop, and
it needs the pages gone), and writing the entity-id ramp through a buffer sink (3.6 ns against
2.7 ns). Both stayed loops.

The rest is ordinary. `relate` probed the edge hash twice and compared pairs while rehashing; it
now probes once and rehashes by first empty slot. A hot relation query walked two sets with
`pairs` for every row; an archetype's components never change, so the answer is kept by archetype
id. Single-entity migration called `buffer.copy` for every field of the row, twice; the cells are
now moved with reads and writes native code compiles in place. `get` and `set` name the buffer
function for the field's kind instead of calling the one stored on the field; the component scan
reads its rows the same way, which is the likely source of its eight percent, a number close
enough to the noise that it should not be leaned on.

The dialect conversions in cold code (the SQL metadata rows, provider lists, `Query:count`, event
columns) measure as nothing, which is what a comprehension is supposed to cost.

One number that is not an A/B: `events.luau` now sums the same event column twice, with the
row loop it always had and with a typed-slice reduction, `sum[for impulse in
column[1:count, 'f32'] => impulse]`, which l3i lowers to one data-plane call a chunk. Over 500,000
rows in 4,096-row blocks the loop took 1.54 ms and the reduction about 0.6 ms. That is what the data
plane buys a system that reduces a column; the package's own frame-loop surface is still raw
buffers, and a read-modify-write loop like movement has no bulk form to move to.
