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
