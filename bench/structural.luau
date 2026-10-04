local ecs = require('@dream/ecs')

local entityCount = tonumber(arg[1]) or 200000
local mutateCount = tonumber(arg[2]) or 50000
local chunkCapacity = tonumber(arg[3]) or 4096

local function seconds(action)
  local before = os.clock()
  action()
  return os.clock() - before
end

local world = ecs.new({ chunkCapacity = chunkCapacity })
local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local velocity = world:component('Velocity', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local health = world:component('Health', { current = { type = 'f32', default = 100 }, maximum = { type = 'f32', default = 100 } })
local frozen = world:tag('Frozen')

local spawnSeconds = seconds(function()
  world:spawnBatch(entityCount, { position, velocity })
end)

local addTagSeconds = seconds(function()
  for index = 1, mutateCount do world:add(world:_token(index), frozen) end
end)

local removeTagSeconds = seconds(function()
  for index = 1, mutateCount do world:remove(world:_token(index), frozen) end
end)

local addDataSeconds = seconds(function()
  for index = 1, mutateCount do world:add(world:_token(index), health, { current = 75, maximum = 100 }) end
end)

local removeDataSeconds = seconds(function()
  for index = 1, mutateCount do world:remove(world:_token(index), health) end
end)

local randomSeconds = seconds(function()
  local value = 0
  for iteration = 1, entityCount * 4 do
    local index = ((iteration * 8191) % entityCount) + 1
    local entity = world:_token(index)
    value += world:get(entity, position.axisX) or 0
    world:set(entity, position.axisX, iteration % 100)
  end

  if value < 0 then print(value) end
end)

print(`entities={entityCount} mutate={mutateCount} chunk={chunkCapacity}`)
print(`spawn_s={spawnSeconds} spawn_per_s={entityCount / spawnSeconds}`)
print(`add_tag_s={addTagSeconds} ops_s={mutateCount / addTagSeconds}`)
print(`remove_tag_s={removeTagSeconds} ops_s={mutateCount / removeTagSeconds}`)
print(`add_data_s={addDataSeconds} ops_s={mutateCount / addDataSeconds}`)
print(`remove_data_s={removeDataSeconds} ops_s={mutateCount / removeDataSeconds}`)
print(`random_getset_s={randomSeconds} pairs_s={(entityCount * 4) / randomSeconds}`)
