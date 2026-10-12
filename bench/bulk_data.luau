local data = require('@dream/data')
local ecs = require('@dream/ecs')
local count = tonumber(arg[1]) or 200000
local world = ecs.new({ chunkCapacity = tonumber(arg[2]) or 8192 })
local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local velocity = world:component('Velocity', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local health = world:component('Health', { current = { type = 'f32', default = 100 }, maximum = { type = 'f32', default = 100 } })
world:spawnBatch(count, { position, velocity })
local query = world:query('SELECT Position, Velocity FROM entities')
local withHealth = world:query('SELECT Position, Velocity, Health FROM entities')

-- The sum of Health.current over every entity that has it.
local function healthTotal()
  local total = 0
  for chunk in withHealth:chunks() do total += data.sum(chunk:buffer(health.current), 'f32', 0, chunk.count) end
  return total
end

local before = os.clock()
local moved = world:addQuery(query, health, { current = 75, maximum = 125 })
local elapsed = os.clock() - before
print(`count={count} moved={moved} seconds={elapsed} ops_s={count/elapsed} health={healthTotal()}`)

before = os.clock()
local removed = world:removeQuery(withHealth, health)
local removeSeconds = os.clock() - before

-- Added again without values: the defaults, written over rows that held the first pass's data.
before = os.clock()
local restored = world:addQuery(query, health)
local defaultSeconds = os.clock() - before
print(`remove_s={removeSeconds} remove_ops_s={count/removeSeconds} removed={removed}`)
print(`default_s={defaultSeconds} default_ops_s={count/defaultSeconds} restored={restored} health={healthTotal()}`)
