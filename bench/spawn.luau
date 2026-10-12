local data = require('@dream/data')
local ecs = require('@dream/ecs')

local entityCount = tonumber(arg[1]) or 1000000
local chunkCapacity = tonumber(arg[2]) or 8192
local reuseCount = math.floor(entityCount / 4)

local function seconds(action)
  local before = os.clock()
  action()
  return os.clock() - before
end

local world = ecs.new({ chunkCapacity = chunkCapacity })
local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local velocity = world:component('Velocity', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local health = world:component('Health', { current = { type = 'f32', default = 100 }, maximum = { type = 'f32', default = 125 } })

-- The sum of Health.current over every entity that has it, and how many there are.
local function healthTotal()
  local total, rows = 0, 0
  for chunk in world:query('SELECT Health FROM entities'):chunks() do
    total += data.sum(chunk:buffer(health.current), 'f32', 0, chunk.count)
    rows += chunk.count
  end
  return total, rows
end

local plainSeconds = seconds(function()
  world:spawnBatch(entityCount, { position, velocity })
end)

local defaultSeconds = seconds(function()
  world:spawnBatch(entityCount, { position, health })
end)
local defaultTotal, defaultRows = healthTotal()

-- The newest entities die newest first, so the batch after them takes their slots back from the
-- free list and starts on rows that have held data before.
local destroySeconds = seconds(function()
  for index = entityCount * 2, entityCount * 2 - reuseCount + 1, -1 do world:destroy(world:_token(index)) end
end)

local reuseSeconds = seconds(function()
  world:spawnBatch(reuseCount, { position, health })
end)
local reuseTotal, reuseRows = healthTotal()

print(`entities={entityCount} chunk={chunkCapacity} reuse={reuseCount}`)
print(`plain_s={plainSeconds} plain_per_s={entityCount / plainSeconds}`)
print(`default_s={defaultSeconds} default_per_s={entityCount / defaultSeconds} rows={defaultRows} health={defaultTotal}`)
print(`destroy_s={destroySeconds} destroy_per_s={reuseCount / destroySeconds}`)
print(`reuse_s={reuseSeconds} reuse_per_s={reuseCount / reuseSeconds} rows={reuseRows} health={reuseTotal}`)
print(`count={world.count} chunks={world:stats().chunks} last={world:valid(world:_token(entityCount * 2))}`)
