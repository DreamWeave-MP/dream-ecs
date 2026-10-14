local ecs = require('@dream/ecs')

local entityCount = tonumber(arg[1]) or 1048576
local frames = tonumber(arg[2]) or 30
local chunkCapacity = tonumber(arg[3]) or 4096
local dt = 1 / 60

local function seconds(action)
  local before = os.clock()
  action()
  return os.clock() - before
end

local rawChunks = {}
local remaining = entityCount
while remaining > 0 do
  local count = math.min(remaining, chunkCapacity)
  local bytes = chunkCapacity * 4
  local chunk = {
    count = count,
    px = buffer.create(bytes), py = buffer.create(bytes), pz = buffer.create(bytes),
    vx = buffer.create(bytes), vy = buffer.create(bytes), vz = buffer.create(bytes),
  }

  for row = 0, count - 1 do
    local offset = row * 4
    buffer.writef32(chunk.vx, offset, 1)
    buffer.writef32(chunk.vy, offset, 2)
    buffer.writef32(chunk.vz, offset, 3)
  end
  rawChunks[#rawChunks + 1] = chunk
  remaining -= count
end

local world = ecs.new({ chunkCapacity = chunkCapacity })
local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local velocity = world:component('Velocity', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local spawnSeconds = seconds(function()
  world:spawnBatch(entityCount, { position, velocity })
end)
local movers = world:query('SELECT Position, Velocity FROM entities')
for chunk in movers:chunks() do
  local velocityX = chunk:buffer(velocity.axisX)
  local velocityY = chunk:buffer(velocity.axisY)
  local velocityZ = chunk:buffer(velocity.axisZ)
  for row = 0, chunk.count - 1 do
    local offset = row * 4
    buffer.writef32(velocityX, offset, 1)
    buffer.writef32(velocityY, offset, 2)
    buffer.writef32(velocityZ, offset, 3)
  end
end

local rawSeconds = seconds(function()
  for _ = 1, frames do
    for _, chunk in rawChunks do
      local {px, py, pz, vx, vy, vz} = chunk
      for row = 0, chunk.count - 1 do
        local offset = row * 4
        buffer.writef32(px, offset, buffer.readf32(px, offset) + buffer.readf32(vx, offset) * dt)
        buffer.writef32(py, offset, buffer.readf32(py, offset) + buffer.readf32(vy, offset) * dt)
        buffer.writef32(pz, offset, buffer.readf32(pz, offset) + buffer.readf32(vz, offset) * dt)
      end
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
print(`chunks={#rawChunks} spawn_s={spawnSeconds}`)
print(`raw_chunked_s={rawSeconds} raw_ns_entity={(rawSeconds / updates) * 1e9}`)
print(`ecs_s={ecsSeconds} ecs_ns_entity={(ecsSeconds / updates) * 1e9}`)
print(`ratio={ecsSeconds / rawSeconds}`)
