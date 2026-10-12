local ecs = require('@dream/ecs')
local test = require('@jess/test')
local expect = test.expect
local suite = test.new()

local function fixture()
  local world = ecs.new({ chunkCapacity = 4 })
  local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
  local velocity = world:component('Velocity', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
  local health = world:component('Health', { value = { type = 'f32', default = 100 } })
  local frozen = world:tag('Frozen')
  return world, position, velocity, health, frozen
end

suite.describe('packed entities and components', function()
  suite.it('spawns, reads, writes and invalidates generation handles', function()
    local world, position = fixture()
    local entity = world:spawn({ [position] = { axisX = 1, axisY = 2, axisZ = 3 } })
    expect(world:valid(entity)).toBe(true)
    expect(world:get(entity, position.axisY)).toBe(2)
    expect(world:set(entity, position.axisY, 9)).toBe(true)
    expect(world:get(entity, position.axisY)).toBe(9)
    expect(world:destroy(entity)).toBe(true)
    expect(world:valid(entity)).toBe(false)
  end)

  suite.it('migrates between archetypes without losing shared data', function()
    local world, position, velocity, health = fixture()
    local entity = world:spawn({ [position] = { axisX = 7 } })
    expect(world:add(entity, velocity, { axisX = 2 })).toBe(true)
    expect(world:add(entity, health)).toBe(true)
    expect(world:get(entity, position.axisX)).toBe(7)
    expect(world:get(entity, velocity.axisX)).toBe(2)
    expect(world:get(entity, health.value)).toBe(100)
    expect(world:remove(entity, position)).toBe(true)
    expect(world:has(entity, position)).toBe(false)
    expect(world:get(entity, velocity.axisX)).toBe(2)
  end)

  suite.it('keeps entity component generations instead of retargeting reused slots', function()
    local world = ecs.new()
    local link = world:component('Link', { target = 'entity' })
    local owner = world:spawn({ [link] = {} })
    local target = world:spawn()
    expect(world:set(owner, link.target, target)).toBe(true)
    expect(world:get(owner, link.target)).toBe(target)
    world:destroy(target)
    local replacement = world:spawn()
    local stale = world:get(owner, link.target)
    expect(stale).toBe(target)
    expect(world:valid(stale)).toBe(false)
    expect(stale == replacement).toBe(false)
  end)

  suite.it('round-trips every field kind through spawn, set and get', function()
    local world = ecs.new({ chunkCapacity = 4 })
    local sample = world:component('Sample', {
      byte = 'u8', short = 'u16', word = 'u32', signed = 'i32', single = 'f32', double = 'f64',
      flag = 'bool', other = 'entity',
    })
    local target = world:spawn()
    local entity = world:spawn({
      [sample] = {
        byte = 200, short = 60000, word = 4000000000, signed = -7, single = 0.5, double = 0.1,
        flag = true, other = target,
      },
    })
    expect(world:get(entity, sample.byte)).toBe(200)
    expect(world:get(entity, sample.short)).toBe(60000)
    expect(world:get(entity, sample.word)).toBe(4000000000)
    expect(world:get(entity, sample.signed)).toBe(-7)
    expect(world:get(entity, sample.single)).toBe(0.5)
    expect(world:get(entity, sample.double)).toBe(0.1)
    expect(world:get(entity, sample.flag)).toBe(true)
    expect(world:get(entity, sample.other)).toBe(target)

    expect(world:set(entity, sample.byte, 257)).toBe(true)
    expect(world:set(entity, sample.short, 65537)).toBe(true)
    expect(world:set(entity, sample.word, 7)).toBe(true)
    expect(world:set(entity, sample.signed, -2147483648)).toBe(true)
    expect(world:set(entity, sample.single, 16777217)).toBe(true)
    expect(world:set(entity, sample.double, -1e300)).toBe(true)
    expect(world:set(entity, sample.flag, false)).toBe(true)
    expect(world:set(entity, sample.other, entity)).toBe(true)
    expect(world:get(entity, sample.byte)).toBe(1)
    expect(world:get(entity, sample.short)).toBe(1)
    expect(world:get(entity, sample.word)).toBe(7)
    expect(world:get(entity, sample.signed)).toBe(-2147483648)
    expect(world:get(entity, sample.single)).toBe(16777216)
    expect(world:get(entity, sample.double)).toBe(-1e300)
    expect(world:get(entity, sample.flag)).toBe(false)
    expect(world:get(entity, sample.other)).toBe(entity)

    local empty = world:spawn({ [sample] = {} })
    expect(world:get(empty, sample.word)).toBe(0)
    expect(world:get(empty, sample.flag)).toBe(false)
    expect(world:get(empty, sample.other)).toBe(nil)
    expect(world:set(target, sample.byte, 1)).toBe(false)
    expect(world:get(target, sample.byte)).toBe(nil)
  end)

  suite.it('spawns batches across chunks with defaults, and reuses freed slots and rows', function()
    local world, position, _, health = fixture()
    local armor = world:component('Armor', { rating = { type = 'u8', default = 3 }, plate = 'u16' })
    expect(world:spawnBatch(0, { position }).count).toBe(0)
    expect(world:spawnBatch(10, { armor, position, health }).count).toBe(10)
    expect(world.count).toBe(10)
    expect(world:stats().chunks).toBe(3)

    local movers = world:query('SELECT Position, Health, Armor FROM entities')
    local rows, chunkCounts = 0, {}
    for chunk in movers:chunks() do
      chunkCounts[#chunkCounts + 1] = chunk.count
      for row = 0, chunk.count - 1 do
        rows += 1
        local entity = chunk:entity(row)
        expect(entity).toBe(world:_token(rows))
        expect(entity).toBe(4294967296 + rows)
        expect(buffer.readu32(chunk:entities(), row * 4)).toBe(rows)
        expect(world:get(entity, health.value)).toBe(100)
        expect(world:get(entity, armor.rating)).toBe(3)
        expect(world:get(entity, armor.plate)).toBe(0)
        expect(world:get(entity, position.axisX)).toBe(0)
        local located, locatedRow = world:locate(entity)
        expect(located).toBe(chunk)
        expect(locatedRow).toBe(row)
        world:set(entity, position.axisX, rows)
        world:set(entity, health.value, rows)
        world:set(entity, armor.plate, rows)
      end
    end
    expect(rows).toBe(10)
    expect(chunkCounts[1]).toBe(4)
    expect(chunkCounts[2]).toBe(4)
    expect(chunkCounts[3]).toBe(2)

    -- The tenth entity's row and slot are both reused: the row must hold defaults again, and the
    -- slot's handle carries the next generation.
    expect(world:destroy(world:_token(10))).toBe(true)
    expect(world:destroy(world:_token(9))).toBe(true)
    world:spawnBatch(4, { position, health, armor })
    expect(world.count).toBe(12)
    expect(movers:count()).toBe(12)
    expect(world:valid(4294967296 + 9)).toBe(false)

    local expected = { 2 * 4294967296 + 9, 2 * 4294967296 + 10, 4294967296 + 11, 4294967296 + 12 }
    for spawned, entity in expected do
      expect(world:valid(entity)).toBe(true)
      local chunk, row = world:locate(entity)
      expect(row).toBe(spawned - 1)
      expect(chunk:entity(row)).toBe(entity)
      expect(world:get(entity, position.axisX)).toBe(0)
      expect(world:get(entity, health.value)).toBe(100)
      expect(world:get(entity, armor.rating)).toBe(3)
      expect(world:get(entity, armor.plate)).toBe(0)
    end
    expect(world:get(world:_token(8), position.axisX)).toBe(8)
    expect(world:stats().chunks).toBe(3)
  end)

  suite.it('writes a default the same bytes whether rows come one at a time or in bulk', function()
    -- Past 2^63 an integer write wraps where a fill would saturate, and a numeric string is
    -- converted by a write alone: every path has to agree with the single spawn.
    local defaults = { 1e30, -1e30, math.huge, -math.huge, 9223372036854775808, 0 / 0, 300.75, -1, 0, '7' }

    for _, kind in { 'u8', 'u16', 'u32', 'i32', 'f32', 'f64', 'entity' } do
      for _, default in defaults do
        if kind == 'entity' and type(default) == 'string' then continue end

        local world = ecs.new({ chunkCapacity = 4 })
        local sample = world:component('Sample', { cell = { type = kind, default = default } })
        local marker = world:tag('Marker')
        local cell = sample.cell

        -- The cell's bytes in hex: a NaN compares unequal to itself, and raw bytes break a report.
        local function stored(index: number): string
          local chunk, row = world:locate(world:_token(index))
          local column, offset = chunk:buffer(cell), row * cell.width
          return table.concat([for byte in range(0, cell.width - 1) => string.format('%02x', buffer.readu8(column, offset + byte))])
        end

        world:spawn({ [sample] = {} })
        local expected = stored(1)

        -- Fresh rows across two chunks, then the rows and slots two destroyed entities leave.
        world:spawnBatch(6, { sample })
        for index = 2, 7 do
          expect(stored(index)).toBe(expected)
          world:set(world:_token(index), cell, 1)
        end

        world:destroy(world:_token(7))
        world:destroy(world:_token(6))
        world:spawnBatch(3, { sample })
        for index = 6, 8 do expect(stored(index)).toBe(expected) end

        -- A bulk add onto fresh rows by default, then onto used rows by value.
        world:spawnBatch(5, { marker })
        expect(world:addQuery('SELECT Marker FROM entities WHERE Sample = FALSE', sample)).toBe(5)
        for index = 9, 13 do
          expect(stored(index)).toBe(expected)
          world:set(world:_token(index), cell, 1)
        end

        expect(world:removeQuery('SELECT Marker FROM entities', sample)).toBe(5)
        expect(world:addQuery('SELECT Marker FROM entities WHERE Sample = FALSE', sample, { cell = default })).toBe(5)
        for index = 9, 13 do expect(stored(index)).toBe(expected) end
      end
    end
  end)

  suite.it('stops a batch at its first row when a default or the count is refused', function()
    local world, position = fixture()
    local broken = world:component('Broken', { cell = { type = 'u8', default = 'heavy' } })
    expect(function() world:spawnBatch(6, { position, broken }) end).toThrow 'writeu8'
    expect(function() world:spawnBatch('several', { position }) end).toThrow "'for' limit"
    expect(world.count).toBe(0)
    expect(world:query('SELECT Position FROM entities'):count()).toBe(0)

    -- The refused row had taken a slot, and only that one.
    expect(world:spawn({ [position] = {} })).toBe(4294967296 + 2)
    expect(world:spawnBatch(5, { position }).count).toBe(6)
    expect(world.count).toBe(6)
  end)

  suite.it('reads a batch\'s component list as it comes, holes skipped', function()
    local world, position, _, _, frozen = fixture()
    world:spawnBatch(3, { position, nil, frozen })
    expect(world:query('SELECT Position, Frozen FROM entities'):count()).toBe(3)
    expect(function() world:spawnBatch(3) end).toThrow 'iterate over a nil value'
    expect(world.count).toBe(3)
  end)
end)

suite.describe('compiled JessQL hot queries', function()
  suite.it('matches archetypes and notices archetypes created later', function()
    local world, position, velocity, _, frozen = fixture()
    world:spawn({ [position] = {}, [velocity] = {} })
    world:spawn({ [position] = {}, [velocity] = {}, [frozen] = true })
    local movers = world:query('SELECT entity, Position, Velocity FROM entities WHERE Frozen = FALSE')
    expect(movers:count()).toBe(1)
    world:spawn({ [position] = {}, [velocity] = {} })
    expect(movers:count()).toBe(2)
    expect(world:query(movers.sql)).toBe(movers)
  end)

  suite.it('exposes raw field buffers as the hot-loop surface', function()
    local world, position, velocity = fixture()
    local entity = world:spawn({ [position] = { axisX = 1 }, [velocity] = { axisX = 2 } })
    local movers = world:query('SELECT Position, Velocity FROM entities')
    for chunk in movers:chunks() do
      local positionX = chunk:buffer(position.axisX)
      local velocityX = chunk:buffer(velocity.axisX)
      buffer.writef32(positionX, 0, buffer.readf32(positionX, 0) + buffer.readf32(velocityX, 0))
    end
    expect(world:get(entity, position.axisX)).toBe(3)
  end)

  suite.it('locates one entity row for zero-allocation external SoA drains', function()
    local world, position, velocity = fixture()
    local entity = world:spawn({ [position] = { axisX = 1 }, [velocity] = { axisX = 2 } })
    local chunk, row = world:locate(entity)
    expect(chunk ~= nil).toBe(true)
    expect(row).toBe(0)
    buffer.writef32(chunk:buffer(position.axisX), row * 4, 11)
    buffer.writef32(chunk:buffer(velocity.axisX), row * 4, -3)
    expect(world:get(entity, position.axisX)).toBe(11)
    expect(world:get(entity, velocity.axisX)).toBe(-3)

    -- Structural migration may move rows; a fresh locate must still resolve the current storage.
    local health = world:component('Armor', { value = 'f32' })
    expect(world:add(entity, health, { value = 7 })).toBe(true)
    local movedChunk, movedRow = world:locate(entity)
    expect(movedChunk ~= nil).toBe(true)
    expect(world:get(entity, position.axisX)).toBe(11)
    buffer.writef32(movedChunk:buffer(position.axisX), movedRow * 4, 13)
    expect(world:get(entity, position.axisX)).toBe(13)
    expect(world:locate(123456789)).toBe(nil)
  end)

  suite.it('exposes cold relational inspection through normal JessQL providers', function()
    local world, position, velocity = fixture()
    world:spawnBatch(10, { position, velocity })
    local first = world:_token(1)
    world:set(first, position.axisX, 7)
    world:set(first, velocity.axisX, 3)
    local database = world:sql()
    local result = database:query(
      'SELECT COUNT(*) AS total FROM entities WHERE Position = TRUE AND Velocity = TRUE'
    )
    expect(result.rows[1].total).toBe(10)
    expect(database:query('SELECT COUNT(*) AS total FROM components').rows[1].total).toBe(4)
    expect(database:query('SELECT COUNT(*) AS total FROM fields').rows[1].total).toBe(7)
    expect(database:query('SELECT axisX FROM Position WHERE entity = ?', { first }).rows[1].axisX).toBe(7)

    local joined = database:query([[
      SELECT p.entity, p.axisX AS positionX, v.axisX AS velocityX
      FROM Position p INNER JOIN Velocity v ON p.entity = v.entity
      WHERE p.entity = ?
    ]], { first })
    expect(#joined.rows).toBe(1)
    expect(joined.rows[1].positionX).toBe(7)
    expect(joined.rows[1].velocityX).toBe(3)
  end)
end)

suite.describe('relations and structural mutation', function()
  suite.it('packs bidirectional relations and clears edges when an entity dies', function()
    local world = ecs.new()
    local parentRelation = world:relation('Parent')
    local firstEntity = world:spawn()
    local secondEntity = world:spawn()
    local thirdEntity = world:spawn()
    expect(world:relate(parentRelation, firstEntity, secondEntity)).toBe(true)
    expect(world:relate(parentRelation, firstEntity, thirdEntity)).toBe(true)
    expect(world._relationStores[parentRelation.id]:has(1, 2)).toBe(true)
    expect(world:sql():query("SELECT COUNT(*) AS total FROM relations WHERE relation = 'Parent'").rows[1].total).toBe(2)
    world:destroy(secondEntity)
    expect(world._relationStores[parentRelation.id]:has(1, 2)).toBe(false)
    expect(world._relationStores[parentRelation.id]:has(1, 3)).toBe(true)
  end)

  suite.it('batches structural changes through a command buffer', function()
    local world, position, velocity = fixture()
    local entity = world:spawn({ [position] = {} })
    local commands = world:commands()
    commands:add(entity, velocity, { axisX = 3 })
    expect(world:has(entity, velocity)).toBe(false)
    commands:flush()
    expect(world:get(entity, velocity.axisX)).toBe(3)
  end)

  suite.it('bulk-migrates whole compiled-query archetypes', function()
    local world, position, velocity, health, frozen = fixture()
    world:spawnBatch(10, { position, velocity })
    local movers = world:query('SELECT Position, Velocity FROM entities WHERE Frozen = FALSE')
    expect(world:addQuery(movers, frozen)).toBe(10)
    expect(movers:count()).toBe(0)

    local frozenMovers = world:query('SELECT Position, Velocity, Frozen FROM entities')
    expect(world:addQuery(frozenMovers, health, { value = 75 })).toBe(10)
    local withHealth = world:query('SELECT Position, Velocity, Frozen, Health FROM entities')
    expect(withHealth:count()).toBe(10)
    for chunk in withHealth:chunks() do
      expect(buffer.readf32(chunk:buffer(health.value), 0)).toBe(75)
    end

    expect(world:removeQuery(withHealth, frozen)).toBe(10)
    expect(world:query('SELECT Position, Velocity, Health FROM entities WHERE Frozen = FALSE'):count()).toBe(10)
  end)

  suite.it('queues whole-query structural migrations without per-op tables', function()
    local world, position, velocity, _, frozen = fixture()
    world:spawnBatch(12, { position, velocity })
    local movers = world:query('SELECT Position, Velocity FROM entities WHERE Frozen = FALSE')
    local commands = world:commands()
    commands:addQuery(movers, frozen)
    expect(commands:count()).toBe(1)
    expect(movers:count()).toBe(12)
    expect(commands:flush()).toBe(1)
    expect(movers:count()).toBe(0)
  end)

  suite.it('bulk-migrates runs that split across chunks, keeping rows, handles and defaults', function()
    local world, position, velocity, health = fixture()
    world:spawnBatch(2, { position, velocity, health })
    world:spawnBatch(11, { position, velocity })
    for index = 1, 13 do world:set(world:_token(index), position.axisX, index) end

    local bare = world:query('SELECT Position, Velocity FROM entities WHERE Health = FALSE')
    local healthy = world:query('SELECT Position, Velocity, Health FROM entities')
    expect(world:addQuery(bare, health, { value = 75 })).toBe(11)
    expect(bare:count()).toBe(0)
    expect(healthy:count()).toBe(13)

    for index = 1, 13 do
      local entity = world:_token(index)
      local chunk, row = world:locate(entity)
      expect(chunk:entity(row)).toBe(entity)
      expect(world:get(entity, position.axisX)).toBe(index)
      expect(world:get(entity, health.value)).toBe(if index <= 2 then 100 else 75)
      world:set(entity, health.value, index)
    end

    -- Moving out and back lands on rows both archetypes have used before: the component comes
    -- back as its default there, not as what those rows last held. Only an archetype's last chunk
    -- is refilled, so the emptied ones before it stay behind.
    expect(world:removeQuery(healthy, health)).toBe(13)
    expect(world:addQuery(bare, health)).toBe(13)
    expect(world:stats().chunks).toBe(13)

    for index = 1, 13 do
      local entity = world:_token(index)
      local chunk, row = world:locate(entity)
      expect(chunk:entity(row)).toBe(entity)
      expect(world:get(entity, position.axisX)).toBe(index)
      expect(world:get(entity, health.value)).toBe(100)
    end
  end)

  suite.it('reads bulk-added values a row at a time when they come through a metatable', function()
    local world, position, _, health = fixture()
    world:spawnBatch(6, { position })

    local reads = 0
    local counted = setmetatable({}, {
      __index = function()
        reads += 1
        return reads
      end,
    })
    expect(world:addQuery('SELECT Position FROM entities', health, counted)).toBe(6)
    for index = 1, 6 do expect(world:get(world:_token(index), health.value)).toBe(index) end

    -- Values that cannot be read fail the add before any entity has moved.
    local bare = world:query('SELECT Position FROM entities WHERE Health = FALSE')
    world:spawnBatch(2, { position })
    expect(function() world:addQuery(bare, health, true) end).toThrow 'index boolean'
    expect(bare:count()).toBe(2)
  end)

  suite.it('keeps relation edges exact through removal, re-adding and index growth', function()
    local world = ecs.new()
    local link = world:relation('Link')
    world:spawnBatch(2001, {})
    local hub = world:_token(2001)
    for index = 1, 2000 do expect(world:relate(link, world:_token(index), hub)).toBe(true) end
    expect(world:relate(link, world:_token(7), hub)).toBe(false)
    for index = 1, 2000, 2 do expect(world:unrelate(link, world:_token(index), hub)).toBe(true) end
    expect(world:unrelate(link, world:_token(1), hub)).toBe(false)
    for index = 1, 2000, 4 do expect(world:relate(link, world:_token(index), hub)).toBe(true) end

    local store = world._relationStores[link.id]
    expect(store.count).toBe(1500)
    for index = 1, 2000 do
      expect(store:has(index, 2001)).toBe(index % 2 == 0 or index % 4 == 1)
      expect(store:has(2001, index)).toBe(false)
    end

    -- An endpoint's edges come back newest first.
    local sources = {}
    for source in world:sources(link, hub) do sources[#sources + 1] = source end
    expect(#sources).toBe(1500)
    expect(sources[1]).toBe(world:_token(1997))
    expect(sources[500]).toBe(world:_token(1))
    expect(sources[501]).toBe(world:_token(2000))
    expect(sources[1500]).toBe(world:_token(2))
    expect(world:targets(link, world:_token(1997))()).toBe(hub)
    expect(world:targets(link, world:_token(1999))()).toBe(nil)
  end)
end)

suite.describe('packed transient events', function()
  suite.it('stores event rows in typed column buffers and exposes them to JessQL', function()
    local world = ecs.new({ chunkCapacity = 4 })
    local first = world:spawn()
    local second = world:spawn()
    local hit = world:event('Hit', { source = 'entity', target = 'entity', damage = 'f32', critical = 'bool' }, { blockCapacity = 2 })
    hit:emit({ source = first, target = second, damage = 12.5, critical = true })
    hit:emit({ source = second, target = first, damage = 2.5 })

    expect(hit.count).toBe(2)
    local chunk = hit:chunks()()
    expect(chunk.count).toBe(2)
    expect(buffer.readf32(chunk:buffer(hit.damage), 0)).toBe(12.5)

    local database = world:sql()
    local rows = database:query('SELECT source, target, damage, critical FROM Hit ORDER BY damage DESC').rows
    expect(#rows).toBe(2)
    expect(rows[1].source).toBe(first)
    expect(rows[1].critical).toBe(true)
    expect(database:query('SELECT rows FROM events WHERE name = \'Hit\'').rows[1].rows).toBe(2)

    world:clearEvents()
    expect(hit.count).toBe(0)
  end)

  suite.it('emits every event field kind across blocks, defaults included', function()
    local world = ecs.new()
    local owner = world:spawn()
    local sample = world:event('Sample', {
      tiny = 'u8', small = 'u16', wide = 'u32', delta = 'i32', ratio = { type = 'f32', default = 1.5 },
      exact = 'f64', flag = 'bool', other = 'entity',
    }, { blockCapacity = 2 })
    local first = { tiny = 200, small = 60000, wide = 4000000000, delta = -7, ratio = 0.5, exact = 0.1, flag = true, other = owner }
    expect(sample:emit(first)).toBe(0)
    expect(sample:emit()).toBe(1)
    expect(sample:emit({ tiny = 257, small = 65537, ratio = 16777217, flag = false })).toBe(0)
    expect(sample.count).toBe(3)
    expect(sample:bytes()).toBe(2 * 2 * 30)

    local rows = world:sql():query('SELECT tiny, small, wide, delta, ratio, exact, flag, other FROM Sample').rows
    expect(#rows).toBe(3)
    expect(rows[1].tiny).toBe(200)
    expect(rows[1].small).toBe(60000)
    expect(rows[1].wide).toBe(4000000000)
    expect(rows[1].delta).toBe(-7)
    expect(rows[1].ratio).toBe(0.5)
    expect(rows[1].exact).toBe(0.1)
    expect(rows[1].flag).toBe(true)
    expect(rows[1].other).toBe(owner)
    expect(rows[2].tiny).toBe(0)
    expect(rows[2].wide).toBe(0)
    expect(rows[2].ratio).toBe(1.5)
    expect(rows[2].exact).toBe(0)
    expect(rows[2].other).toBe(nil)
    expect(rows[3].tiny).toBe(1)
    expect(rows[3].small).toBe(1)
    expect(rows[3].ratio).toBe(16777216)
    expect(rows[3].flag).toBe(false)
  end)
end)

suite.describe('indexed relational SQL', function()
  suite.it('pushes direct relation target lookups into adjacency indexes', function()
    local world, position = fixture()
    local parentRelation = world:relation('Parent')
    local parent = world:spawn()
    local child = world:spawn({ [position] = { axisX = 7 } })
    world:relate(parentRelation, child, parent)

    local database = world:sql()
    local direct = database:query(
      "SELECT source FROM relations WHERE relation = 'Parent' AND target = ?",
      { parent }
    )
    expect(#direct.rows).toBe(1)
    expect(direct.rows[1].source).toBe(child)

    local joined = database:query([[
      SELECT e.entity
      FROM relations r
      INNER JOIN entities e ON r.source = e.entity
      WHERE r.relation = 'Parent' AND r.target = ? AND e.Position = TRUE
    ]], { parent })
    expect(#joined.rows).toBe(1)
    expect(joined.rows[1].entity).toBe(child)
  end)

  suite.it('lowers a constrained JessQL relation join into a packed adjacency iterator', function()
    local world, position, _, _, frozen = fixture()
    local parentRelation = world:relation('Parent')
    local parent = world:spawn()
    local first = world:spawn({ [position] = { axisX = 3 } })
    local second = world:spawn({ [position] = { axisX = 9 }, [frozen] = true })
    world:relate(parentRelation, first, parent)
    world:relate(parentRelation, second, parent)

    local children = world:query([[
      SELECT e.entity, Position
      FROM relations r INNER JOIN entities e ON r.source = e.entity
      WHERE r.relation = 'Parent' AND r.target = ? AND e.Frozen = FALSE
    ]])
    expect(children:explain().kind).toBe('relation-index')
    expect(children:count({ parent })).toBe(1)
    local iterator = children:rows({ parent })
    local entity, chunk, row = iterator()
    expect(entity).toBe(first)
    expect(buffer.readf32(chunk:buffer(position.axisX), row * 4)).toBe(3)
    expect(iterator()).toBe(nil)
  end)

  suite.it('tests relation rows against where each entity is now, not where it was', function()
    local world, position, _, _, frozen = fixture()
    local parentRelation = world:relation('Parent')
    local parent = world:spawn()
    local child = world:spawn({ [position] = { axisX = 3 } })
    world:relate(parentRelation, child, parent)

    local children = world:query([[
      SELECT e.entity, Position
      FROM relations r INNER JOIN entities e ON r.source = e.entity
      WHERE r.relation = 'Parent' AND r.target = ? AND e.Frozen = FALSE
    ]])
    expect(children:count({ parent })).toBe(1)
    world:add(child, frozen)
    expect(children:count({ parent })).toBe(0)
    world:remove(child, frozen)
    expect(children:count({ parent })).toBe(1)
    world:remove(child, position)
    expect(children:count({ parent })).toBe(0)

    local armor = world:component('Armor', { rating = 'u8' })
    world:add(child, position, { axisX = 5 })
    world:add(child, armor)
    local entity, chunk, row = children:rows({ parent })()
    expect(entity).toBe(child)
    expect(buffer.readf32(chunk:buffer(position.axisX), row * 4)).toBe(5)
    expect(children:count({ world:spawn() })).toBe(0)
    expect(children:count({ 123456789 })).toBe(0)
  end)

  suite.it('compacts dead relation history without changing live edges', function()
    local world = ecs.new()
    local link = world:relation('Link')
    world:spawnBatch(3001, {})
    for index = 1, 3000 do world:relate(link, world:_token(index), world:_token(index + 1)) end
    for index = 1, 2500 do world:unrelate(link, world:_token(index), world:_token(index + 1)) end

    local before = world._relationStores[link.id]:bytes()
    world:compactRelations()
    local store = world._relationStores[link.id]
    local after = store:bytes()
    expect(after < before).toBe(true)
    expect(store.count).toBe(500)
    expect(store:has(2501, 2502)).toBe(true)
  end)
end)

suite.describe('systems and resources', function()
  suite.it('runs systems over cached chunk plans and defers structural commands', function()
    local world, position, velocity = fixture()
    local entity = world:spawn({ [position] = {}, [velocity] = { axisX = 4 } })
    world:system({
      name = 'movement',
      query = 'SELECT Position, Velocity FROM entities',
      writes = { position },
      update = function(chunk, deltaTime)
        local positionX = chunk:buffer(position.axisX)
        local velocityX = chunk:buffer(velocity.axisX)
        for row = 0, chunk.count - 1 do
          local offset = row * 4
          buffer.writef32(
            positionX,
            offset,
            buffer.readf32(positionX, offset) + buffer.readf32(velocityX, offset) * deltaTime
          )
        end
      end,
    })
    world:step(0.5)
    expect(world:get(entity, position.axisX)).toBe(2)
  end)

  suite.it('derives safe future parallel waves from declared read/write sets', function()
    local world, position, velocity, health = fixture()
    world:system({ name = 'move', query = 'SELECT Position, Velocity FROM entities', writes = { position }, update = function() end })
    world:system({ name = 'observe', query = 'SELECT Position FROM entities', update = function() end })
    world:system({ name = 'heal', query = 'SELECT Health FROM entities', writes = { health }, update = function() end })
    local waves = world:schedule()
    expect(#waves).toBe(2)
    expect(#waves[1]).toBe(2)
    expect(waves[1][1].name).toBe('move')
    expect(waves[1][2].name).toBe('heal')
    expect(waves[2][1].name).toBe('observe')
  end)

  suite.it('schedules independent SoA fields separately when access is explicit', function()
    local world, position = fixture()
    local query = world:query('SELECT Position FROM entities')
    world:system({
      name = 'writeX', query = query, reads = {}, writes = { position.axisX }, update = function() end,
    })

    world:system({
      name = 'writeY', query = query, reads = {}, writes = { position.axisY }, update = function() end,
    })

    world:system({
      name = 'readX', query = query, reads = { position.axisX }, update = function() end,
    })
    local waves = world:schedule()
    expect(#waves).toBe(2)
    expect(#waves[1]).toBe(2)
    expect(waves[1][1].name).toBe('writeX')
    expect(waves[1][2].name).toBe('writeY')
    expect(waves[2][1].name).toBe('readX')
  end)

  suite.it('matches the pairwise conflict scheduler while scaling by access edges', function()
    local world = ecs.new()
    local fields = {}
    for fieldIndex = 1, 12 do
      local component = world:component('Sched' .. fieldIndex, { value = 'f32' })
      fields[fieldIndex] = component.value
    end

    for systemNumber = 1, 128 do
      local reads = { fields[((systemNumber * 5) % 12) + 1] }
      local writes = { fields[((systemNumber * 7) % 12) + 1] }
      local after = {}
      if systemNumber > 17 and systemNumber % 17 == 0 then after[1] = 'sched' .. (systemNumber - 17) end
      world:system({ name = 'sched' .. systemNumber, reads = reads, writes = writes, after = after, update = function() end })
    end

    local referenceWaves, waveBySystem = {}, {}
    local systems = world._systems
    local function conflicts(left, right)
      for access in pairs(left._writes) do
        if right._writes[access] or right._reads[access] then return true end
      end

      for access in pairs(left._reads) do
        if right._writes[access] then return true end
      end
      return false
    end

    for systemIndex, system in systems do
      local waveIndex = 1
      for previousIndex = 1, systemIndex - 1 do
        local previous = systems[previousIndex]
        if conflicts(previous, system) then waveIndex = math.max(waveIndex, waveBySystem[previous.id] + 1) end
      end

      for _, dependency in system.after do
        local previous = world._systemByName[dependency]
        waveIndex = math.max(waveIndex, waveBySystem[previous.id] + 1)
      end
      referenceWaves[waveIndex] = referenceWaves[waveIndex] or {}
      referenceWaves[waveIndex][#referenceWaves[waveIndex] + 1] = system
      waveBySystem[system.id] = waveIndex
    end

    local actual = world:schedule()
    expect(#actual).toBe(#referenceWaves)
    for waveIndex, wave in actual do
      expect(#wave).toBe(#referenceWaves[waveIndex])
      for systemIndex, system in wave do expect(system).toBe(referenceWaves[waveIndex][systemIndex]) end
    end
  end)

  suite.it('executes cached dependency waves explicitly without changing default step semantics', function()
    local world, position, velocity = fixture()
    local entity = world:spawn({ [position] = { axisX = 1 }, [velocity] = { axisX = 2 } })
    local order = {}

    world:system({
      name = 'writeVelocity', query = 'SELECT Velocity FROM entities', reads = {}, writes = { velocity.axisX },
      update = function(chunk)
        order[#order + 1] = 'writeVelocity'
        buffer.writef32(chunk:buffer(velocity.axisX), 0, 4)
      end,
    })

    world:system({
      name = 'unrelatedPositionY', query = 'SELECT Position FROM entities', reads = {}, writes = { position.axisY },
      update = function() order[#order + 1] = 'unrelatedPositionY' end,
    })

    world:system({
      name = 'consumeVelocity', query = 'SELECT Position, Velocity FROM entities', reads = { velocity.axisX },
      writes = { position.axisX },
      update = function(chunk)
        order[#order + 1] = 'consumeVelocity'
        buffer.writef32(chunk:buffer(position.axisX), 0, buffer.readf32(chunk:buffer(velocity.axisX), 0))
      end,
    })

    world:stepScheduled(0)
    expect(world:get(entity, position.axisX)).toBe(4)
    expect(order[1]).toBe('writeVelocity')
    expect(order[2]).toBe('unrelatedPositionY')
    expect(order[3]).toBe('consumeVelocity')
  end)

  suite.it('exposes scheduler waves and access counts through cold SQL metadata', function()
    local world, position = fixture()
    world:system({
      name = 'writeX', query = 'SELECT Position FROM entities', reads = {}, writes = { position.axisX },
      update = function() end,
    })

    world:system({
      name = 'readX', query = 'SELECT Position FROM entities', reads = { position.axisX }, update = function() end,
    })
    local rows = world:sql():query([[SELECT name, wave, reads, writes FROM systems ORDER BY id]]).rows
    expect(#rows).toBe(2)
    expect(rows[1].wave).toBe(1)
    expect(rows[1].writes).toBe(1)
    expect(rows[2].wave).toBe(2)
    expect(rows[2].reads).toBe(1)
  end)

  suite.it('keeps singleton resources outside the entity model', function()
    local world = ecs.new()
    local gravity = world:resource('Gravity', -9.81)
    expect(world:getResource(gravity)).toBe(-9.81)
    world:setResource(gravity, -3.7)
    expect(world:getResource(gravity)).toBe(-3.7)
  end)

  suite.it('tracks resource, relation and event hazards in cached schedule waves', function()
    local world = ecs.new()
    local position = world:component('Position', { axisX = 'f32' })
    local parent = world:relation('Parent')
    local hit = world:event('Hit', { entity = 'entity' })
    local time = world:resource('Time', 0)
    local query = world:query('SELECT Position FROM entities')

    world:system({
      name = 'produce', query = query, writesRelations = { parent }, writesEvents = { hit },
      writesResources = { time }, update = function() end,
    })

    world:system({
      name = 'unrelated', query = query, update = function() end,
    })

    world:system({
      name = 'consume', query = query, readsRelations = { parent }, readsEvents = { hit },
      readsResources = { time }, update = function() end,
    })

    world:system({
      name = 'explicit', query = query, after = { 'consume' }, update = function() end,
    })

    local waves = world:schedule()
    expect(#waves).toBe(3)
    expect(#waves[1]).toBe(2)
    expect(waves[2][1].name).toBe('consume')
    expect(waves[3][1].name).toBe('explicit')
    expect(world:schedule()).toBe(waves)
  end)

  suite.it('runs resource/event-only systems without manufacturing singleton entities', function()
    local world = ecs.new()
    local tick = world:event('Tick', { value = 'u32' })
    local counter = world:resource('Counter', 0)
    world:system({
      name = 'produceTick', writesEvents = { tick },
      update = function() tick:emit({ value = 7 }) end,
    })

    world:system({
      name = 'consumeTick', readsEvents = { tick }, writesResources = { counter },
      update = function()
        local total = 0
        for chunk in tick:chunks() do
          local values = chunk:buffer(tick.value)
          for row = 0, chunk.count - 1 do total += buffer.readu32(values, row * 4) end
        end
        world:setResource(counter, total)
      end,
    })
    world:step(0)
    expect(world:getResource(counter)).toBe(7)
  end)
end)

return suite
