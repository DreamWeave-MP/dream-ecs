local ecs = require('@dream/ecs')

local entityCount = tonumber(arg[1]) or 262144
local frames = tonumber(arg[2]) or 30
local chunkCapacity = tonumber(arg[3]) or 1024
local dt = 1 / 60

local function seconds(action)
  local before = os.clock()
  action()
  return os.clock() - before
end

local rawPx = buffer.create(entityCount * 4)
local rawPy = buffer.create(entityCount * 4)
local rawPz = buffer.create(entityCount * 4)
local rawVx = buffer.create(entityCount * 4)
local rawVy = buffer.create(entityCount * 4)
local rawVz = buffer.create(entityCount * 4)
for row = 0, entityCount - 1 do
  local offset = row * 4
  buffer.writef32(rawVx, offset, 1)
  buffer.writef32(rawVy, offset, 2)
  buffer.writef32(rawVz, offset, 3)
end

local world = ecs.new({ chunkCapacity = chunkCapacity })
local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local velocity = world:component('Velocity', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local spawnSeconds = seconds(function()
  world:spawnBatch(entityCount, { position, velocity })
end)
local movers = world:query('SELECT Position, Velocity FROM entities')
for chunk in movers:chunks() do
  local vx = chunk:buffer(velocity.axisX)
  local vy = chunk:buffer(velocity.axisY)
  local vz = chunk:buffer(velocity.axisZ)
  for row = 0, chunk.count - 1 do
    local offset = row * 4
    buffer.writef32(vx, offset, 1)
    buffer.writef32(vy, offset, 2)
    buffer.writef32(vz, offset, 3)
  end
end

local rawSeconds = seconds(function()
  for _ = 1, frames do
    for row = 0, entityCount - 1 do
      local offset = row * 4
      buffer.writef32(rawPx, offset, buffer.readf32(rawPx, offset) + buffer.readf32(rawVx, offset) * dt)
      buffer.writef32(rawPy, offset, buffer.readf32(rawPy, offset) + buffer.readf32(rawVy, offset) * dt)
      buffer.writef32(rawPz, offset, buffer.readf32(rawPz, offset) + buffer.readf32(rawVz, offset) * dt)
    end
  end
end)

local ecsSeconds = seconds(function()
  for _ = 1, frames do
    for chunk in movers:chunks() do
      local px = chunk:buffer(position.axisX)
      local py = chunk:buffer(position.axisY)
      local pz = chunk:buffer(position.axisZ)
      local vx = chunk:buffer(velocity.axisX)
      local vy = chunk:buffer(velocity.axisY)
      local vz = chunk:buffer(velocity.axisZ)
      for row = 0, chunk.count - 1 do
        local offset = row * 4
        buffer.writef32(px, offset, buffer.readf32(px, offset) + buffer.readf32(vx, offset) * dt)
        buffer.writef32(py, offset, buffer.readf32(py, offset) + buffer.readf32(vy, offset) * dt)
        buffer.writef32(pz, offset, buffer.readf32(pz, offset) + buffer.readf32(vz, offset) * dt)
      end
    end
  end
end)

local updates = entityCount * frames
print(`entities={entityCount} frames={frames} chunk={chunkCapacity}`)
print(`spawn_s={spawnSeconds}`)
print(`raw_s={rawSeconds} raw_ns_entity={(rawSeconds / updates) * 1e9}`)
print(`ecs_s={ecsSeconds} ecs_ns_entity={(ecsSeconds / updates) * 1e9}`)
print(`ratio={ecsSeconds / rawSeconds}`)
print(`sample={world:get(world:_token(1), position.axisX)}`)
