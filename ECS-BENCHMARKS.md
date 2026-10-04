# Dream ECS 0.2.1 benchmark report

Environment: supplied `jess 0.1.0`, `jessql 0.1.6`, release/native Luau execution. Numbers are
engineering baselines from the supplied machine, not portable hardware claims. Unless noted, values
below are representative medians from repeated runs in `bench/final-0.2.0.txt`.

## North-star: compiled movement loop

1,048,576 entities, Position xyz + Velocity xyz as f32 SoA, 8192-row chunks. The fair raw baseline
uses hand-written buffers split into the **same chunk shape** as the ECS.

Across the recorded runs the ECS loop was roughly 0.94x-1.17x raw time; the median run was about
**1.11x** raw. Separate 80-frame system-wrapper probes landed around 0.94x-1.04x direct chunk-loop
time. The stable conclusion is that a compiled ECS query executes within roughly measurement noise
to low-double-digit-percent overhead of the equivalent direct buffer loop; JessQL does not execute
per entity.

The earlier result where ECS beat six monolithic raw buffers by ~25-30% was a cache-locality win from
chunking, not abstraction magic, and is intentionally not used as the overhead comparison.

## Resident layout

1,000,000 entities with Position xyz + Velocity xyz:

- packed entity locator/generation pages: **8,388,608 bytes**;
- chunk buffers including entity IDs: **28,213,248 bytes**;
- total packed ECS payload: **36,601,856 bytes**;
- observed process peak: about **56 MiB RSS**.

The 0.2 locator is 8 bytes/entity page slot (`u16 generation/archetype/chunk/row`), down from the
0.1 12-byte layout. Component `entity` fields remain aligned at 8 bytes because the tested 6-byte
form saved memory but cost roughly 15-20% on hot random get/set. Transient events retain the compact
6-byte entity representation because their normal access pattern is sequential.

## Bulk structural migration

200,000 entities; query-wide zero-byte tag migration:

- individual `add`: roughly **0.8M migrations/s**;
- bulk `addQuery`: roughly **7.0M migrations/s**;
- bulk `removeQuery`: roughly **9.0M migrations/s**;
- bulk add time is about **0.12x** the individual path (~8.5x faster).

This works by caching archetype transitions and copying common component columns in chunk ranges with
`buffer.copy`. Structural mutation over a set is therefore a first-class operation rather than a
loop over unrelated entity migrations.

## Packed events

500,000 reserved event rows:

- direct reserve/fill path: roughly **33M rows/s** median;
- packed event allocation in the recorded probe: **14,610,432 bytes**.

The table-taking `emit({ ... })` API remains for convenience; high-volume producers should use
`reserve()` and write event SoA buffers directly.

## Live component SQL

200,000-entity world, 10,000 repeated targeted queries:

- indexed direct component lookup: about **3.1 microseconds/query**;
- indexed `Position JOIN Velocity` lookup: about **4.3 microseconds/query**.

These are cold/tooling queries. They use live providers and entity indexes rather than materializing
component rows for the entire world.

## Relations

For a relation with 200,000 edges and degree 200, a specialized compiled relation query took roughly
**50 microseconds/query** versus roughly **259 microseconds/query** through the generic cold JessQL
path in the median recorded run: about **5x faster**. The hot plan walks the packed adjacency list and
applies component/archetype predicates directly.

## Scheduler

The scheduler operates over integer access IDs for fields, tags, resources, relations, and events. It
tracks the latest read/write wave per access rather than comparing every system against every prior
system. Tests compare its result against a pairwise reference scheduler.

Recorded setup costs:

| Systems | Waves | Schedule time | Time/system |
| ---: | ---: | ---: | ---: |
| 4,000 | 250 | ~1.3 ms median | ~0.33 us |
| 16,000 | 1,000 | ~7.0 ms median | ~0.44 us |

A fresh spot-check produced ~0.05 ms for 128 systems, ~0.16 ms for 512, ~0.84 ms for 2,000 and
~6.4 ms for 10,000. `world:schedule()` is cached; this is registration/setup work, not frame cost.

Field-level access matters physically: systems writing `Position.x` and `Position.y` may occupy the
same wave because those fields are distinct SoA buffers, while a reader of `Position.x` is scheduled
after its writer.

## What to optimize next

The hot component loop is already close enough to direct buffers that the next useful ECS pressure
points are:

1. relation insertion/removal churn and larger relation-query shapes;
2. command-buffer lowering that batches heterogeneous structural mutations;
3. real worker execution using the already-derived scheduler waves;
4. incremental/persistent query membership for value predicates if a concrete workload justifies it;
5. domain JPK integration (PHYSIK, navigation, scenegraph, networking) against this exact storage and
   scheduling contract.

The explicit non-goal is arbitrary SQL inside frame loops. JessQL is the parser/planner and the cold
relational observability surface; hot ECS plans lower into integer indexes and raw buffers.


## 0.2.1 external-drain pressure

MJ12 exposed a cost that the internal compiled-query benchmarks did not: an external subsystem
(Physik) may already have a dense SoA drain but only an entity token for locating the ECS row. Six
independent `World:set()` calls per body repeated token decode and locator lookup six times.

0.2.1 adds `World:locate(entity) -> chunk, row`, an allocation-free public escape hatch whose row is
valid only until the next structural mutation boundary. MJ12 resolves each body once and then writes
its Local/Velocity f32 columns directly. On the supplied sandbox this reduced the integrated 1000-body
step from roughly 2.83 ms median to roughly 1.92 ms before any Physik changes, and 5000 bodies from
roughly 13.15 ms to roughly 10.04 ms.

The API is deliberately generic: physics, animation, networking, importers, and other packed producers
can use it without teaching Dream ECS anything about those domains.
