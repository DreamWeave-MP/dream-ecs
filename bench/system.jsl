local ecs = require('@dream/ecs')

local entityCount = tonumber(arg[1]) or 1048576
local frames = tonumber(arg[2]) or 80
local world = ecs.new({ chunkCapacity = tonumber(arg[3]) or 8192 })
local position = world:component('Position', { axisX = 'f32' })
local velocity = world:component('Velocity', { axisX = 'f32' })
world:spawnBatch(entityCount, { position, velocity })
local movers = world:query('SELECT Position, Velocity FROM entities')
for chunk in movers:chunks() do
  local velocityX = chunk:buffer(velocity.axisX)
  for row = 0, chunk.count - 1 do buffer.writef32(velocityX, row * 4, 1) end
end

local function update(chunk, deltaTime)
  local positionX = chunk:buffer(position.axisX)
  local velocityX = chunk:buffer(velocity.axisX)
  for row = 0, chunk.count - 1 do
    local offset = row * 4
    buffer.writef32(positionX, offset, buffer.readf32(positionX, offset) + buffer.readf32(velocityX, offset) * deltaTime)
  end
end

local before = os.clock()
for _ = 1, frames do
  for chunk in movers:chunks() do update(chunk, 1 / 60) end
end
local directSeconds = os.clock() - before

world:system({ name = 'movement', query = movers, writes = { position }, update = update })
before = os.clock()
for _ = 1, frames do world:step(1 / 60) end
local systemSeconds = os.clock() - before

local updates = entityCount * frames
print(`entities={entityCount} frames={frames}`)
print(`direct_ns_entity={directSeconds/updates*1e9}`)
print(`system_ns_entity={systemSeconds/updates*1e9}`)
print(`ratio={systemSeconds/directSeconds}`)
