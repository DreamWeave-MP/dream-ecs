# Dream ECS

`org.dreamweave.ecs` is a packed archetype/chunk ECS for Jess. JessQL is the declarative query
frontend and cold inspection engine; hot ECS queries are parsed through JessQL once and lowered into
cached archetype/relation plans. No SQL row evaluator runs inside the frame loop.

## Physical model

- entities are 48-bit numeric handles (`u32 slot + u16 generation`);
- entity locations are packed **8-byte** records (`u16 generation/archetype/chunk/row`);
- component data is structure-of-arrays buffers, one typed buffer per field per chunk;
- hot component entity references stay aligned at 8 bytes; packed transient event entity fields use 6 bytes;
- tags occupy no per-entity component storage;
- structural changes migrate dense rows with swap-remove;
- archetypes cache add/remove transitions so repeated structural churn skips signature reconstruction;
- whole-query structural changes migrate chunk ranges with `buffer.copy`;
- hot queries persist as matching-archetype or relation-index plans and automatically see later archetypes;
- relations use packed edge rows, packed adjacency heads and integer edge indexes;
- events are transient packed SoA relations with both convenient emit and zero-table `reserve()` paths;
- resources live outside the entity namespace;
- systems declare **field-level** component access plus resource/relation/event access so deterministic dependency waves can be derived;
- `world:sql()` exposes live entity, component, relation, event and scheduler metadata through JessQL.

The default chunk capacity is 8192 rows. It can be changed per world.

## Hot component query

```luau
local ecs = require('@dream/ecs')
local world = ecs.new()
local position = world:component('Position', { x = 'f32', y = 'f32', z = 'f32' })
local velocity = world:component('Velocity', { x = 'f32', y = 'f32', z = 'f32' })
local frozen = world:tag('Frozen')

local movers = world:query([[SELECT Position, Velocity
  FROM entities WHERE Frozen = FALSE]])

for chunk in movers:chunks() do
  local positionX = chunk:buffer(position.x)
  local velocityX = chunk:buffer(velocity.x)

  for row = 0, chunk.count - 1 do
    local offset = row * 4
    buffer.writef32(
      positionX,
      offset,
      buffer.readf32(positionX, offset) + buffer.readf32(velocityX, offset) * deltaTime
    )
  end
end
```

Selecting a component implies presence. `WHERE Component = TRUE/FALSE` adds required/excluded tags
or components. The hot compiler intentionally rejects arbitrary joins, aggregation and ordering;
use `world:sql()` for arbitrary cold/tooling queries.

## Hot indexed relation query

Relations are first-class rather than fake components. A constrained relation join is lowered into
an adjacency-list lookup plus archetype tests rather than a generic SQL join:

```luau
local target = world:relation('Target')

local attackers = world:query([[
  SELECT e.entity, Position
  FROM entities AS e
  JOIN relations AS r ON r.source = e.entity
  WHERE r.relation = 'Target'
    AND r.target = ?
    AND Dead = FALSE
]])

for entity, chunk, row in attackers:rows({ player }) do
  -- direct packed component access through chunk/row
end
```

## Systems and scheduling

```luau
world:system({
  name = 'movement',
  query = 'SELECT Position, Velocity FROM entities',
  reads = { velocity.x, velocity.y, velocity.z },
  writes = { position.x, position.y, position.z },
  update = function(chunk, deltaTime, commands, world)
    -- direct buffer work
  end,
})
```

If `reads` is omitted, selected query components are conservatively considered read. Passing a
component means every field; passing a field gives the scheduler field-level precision. Systems can
also declare `readsResources` / `writesResources`, `readsRelations` / `writesRelations`, and
`readsEvents` / `writesEvents`. `after = { 'systemName' }` adds an explicit dependency.

`world:schedule()` produces deterministic conflict-free waves and caches them until another system
is registered. `world:stepScheduled()` executes those waves sequentially today; the wave boundary is
the future worker-scheduling contract, not a claim of current parallel execution. Ordinary
`world:step()` remains registration-order sequential execution.

## Structural changes

`spawn`, `destroy`, `add` and `remove` are immediate. `world:commands()` batches them for a stable
iteration/synchronization boundary. `spawnBatch(count, components)` is the bulk zero/default path.

When the same change applies to a compiled set, use the archetype-wide path:

```luau
local aliveEnemies = world:query([[SELECT Enemy FROM entities WHERE Dead = FALSE]])
world:addQuery(aliveEnemies, Frozen)
world:removeQuery(aliveEnemies, Frozen)
```

Those operations migrate whole chunk ranges and copy common SoA columns in bulk instead of routing
every entity through the individual migration path.

## Packed transient events

Friendly/low-volume production can use `emit`:

```luau
local hit = world:event('Hit', { source = 'entity', target = 'entity', damage = 'f32' })
hit:emit({ source = attacker, target = victim, damage = 12 })
```

High-volume producers should reserve raw packed ranges and write directly:

```luau
for chunk, startRow, count in hit:reserve(contactCount) do
  local damage = chunk:buffer(hit.damage)
  -- fill [startRow, startRow + count) directly
end
```

`world:clearEvents()` resets event counts without rebuilding schemas. Event relations are also
visible to cold JessQL queries.

## Resources

Resources are typed-by-convention singleton world state without manufacturing singleton entities:

```luau
local gravity = world:resource('Gravity', -9.81)
world:setResource(gravity, -3.7)
print(world:getResource(gravity))
```

## Cold SQL inspection

`world:sql()` returns a JessQL database with live providers for:

- `entities(entity, Component...)` presence metadata;
- one relation per component, e.g. `Position(entity, x, y, z)`;
- `relations(relation, source, target)`;
- one relation per event schema;
- `archetypes`, `components`, `fields`, `resources`, `events`, and `systems` metadata.

Component providers have an indexed `entity` lookup, so targeted tooling joins do not scan the ECS:

```sql
SELECT p.x, p.y, p.z, v.x, v.y, v.z
FROM Position p
JOIN Velocity v ON v.entity = p.entity
WHERE p.entity = ?;
```

The SQL surface is deliberately the cold/tooling path. Frame systems should keep using compiled
hot plans and direct chunk buffers.

See `ECS-BENCHMARKS.md` and `bench/` for the 0.2 performance pass.
