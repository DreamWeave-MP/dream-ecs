local ecs = require('@dream/ecs')

local eventCount = tonumber(arg[1]) or 500000
local world = ecs.new()
world:spawnBatch(2, {})
local first = world:_token(1)
local second = world:_token(2)
local collision = world:event('Collision', {
  first = 'entity', second = 'entity', impulse = 'f32', normalX = 'f32', normalY = 'f32', normalZ = 'f32', sensor = 'bool',
}, { blockCapacity = 4096 })

local before = os.clock()
for chunk, startRow, count in collision:reserve(eventCount) do
  local firstColumn = chunk:buffer(collision.first)
  local secondColumn = chunk:buffer(collision.second)
  local impulseColumn = chunk:buffer(collision.impulse)
  local normalXColumn = chunk:buffer(collision.normalX)
  local sensorColumn = chunk:buffer(collision.sensor)
  local firstIndex = first - 4294967296
  local secondIndex = second - 4294967296
  for row = startRow, startRow + count - 1 do
    local entityOffset = row * collision.first.width
    buffer.writeu32(firstColumn, entityOffset, firstIndex)
    buffer.writeu16(firstColumn, entityOffset + 4, 1)
    buffer.writeu32(secondColumn, entityOffset, secondIndex)
    buffer.writeu16(secondColumn, entityOffset + 4, 1)
    buffer.writef32(impulseColumn, row * 4, row % 100)
    buffer.writef32(normalXColumn, row * 4, 1)
    buffer.writeu8(sensorColumn, row, if row % 8 == 0 then 1 else 0)
  end
end
local seconds = os.clock() - before
print(`events={eventCount} reserve_write_s={seconds} rows_s={eventCount/seconds}`)
print(`packed_bytes={collision:bytes()} count={collision.count}`)
