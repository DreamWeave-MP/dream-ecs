local ecs = require('@dream/ecs')

local entityCount = tonumber(arg[1]) or 200000
local chunkCapacity = tonumber(arg[2]) or 8192

local function seconds(action)
  local before = os.clock()
  local result = action()
  return os.clock() - before, result
end

local function makeWorld()
  local world = ecs.new({ chunkCapacity = chunkCapacity })
  local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
  local velocity = world:component('Velocity', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
  local frozen = world:tag('Frozen')
  world:spawnBatch(entityCount, { position, velocity })
  return world, position, velocity, frozen
end

local individualWorld, _, _, individualFrozen = makeWorld()
local individualSeconds = seconds(function()
  for index = 1, entityCount do individualWorld:add(individualWorld:_token(index), individualFrozen) end
end)

local bulkWorld, bulkPosition, bulkVelocity, bulkFrozen = makeWorld()
local query = bulkWorld:query('SELECT Position, Velocity FROM entities WHERE Frozen = FALSE')
local bulkSeconds, moved = seconds(function()
  return bulkWorld:addQuery(query, bulkFrozen)
end)

local removeQuery = bulkWorld:query('SELECT Position, Velocity, Frozen FROM entities')
local removeSeconds, removed = seconds(function()
  return bulkWorld:removeQuery(removeQuery, bulkFrozen)
end)

print(`entities={entityCount} chunk={chunkCapacity}`)
print(`individual_add_s={individualSeconds} ops_s={entityCount / individualSeconds}`)
print(`bulk_add_s={bulkSeconds} ops_s={entityCount / bulkSeconds} moved={moved}`)
print(`bulk_remove_s={removeSeconds} ops_s={entityCount / removeSeconds} moved={removed}`)
print(`bulk_vs_individual={bulkSeconds / individualSeconds}`)
print(`final={bulkWorld:query('SELECT Position, Velocity FROM entities WHERE Frozen = FALSE'):count()}`)
