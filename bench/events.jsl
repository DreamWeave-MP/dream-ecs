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
for index = 1, eventCount do
  collision:emit({
    first = first, second = second, impulse = index % 100,
    normalX = 1, normalY = 0, normalZ = 0, sensor = index % 8 == 0,
  })
end
local emitSeconds = os.clock() - before

local checksum = 0
before = os.clock()
for chunk in collision:chunks() do
  local impulses = chunk:buffer(collision.impulse)
  for row = 0, chunk.count - 1 do checksum += buffer.readf32(impulses, row * 4) end
end
local iterateSeconds = os.clock() - before

-- The same total as one typed-slice reduction a chunk, which l3i runs in the data plane.
local reduced = 0
before = os.clock()
for chunk in collision:chunks() do
  reduced += sum[for impulse in chunk:buffer(collision.impulse)[1:chunk.count, 'f32'] => impulse]
end
local reduceSeconds = os.clock() - before
if reduced ~= checksum then error(`events bench: the reduction summed {reduced}, the row loop {checksum}`) end

local bytes = collision:bytes()
print(`events={eventCount} emit_s={emitSeconds} emit_s_rate={eventCount/emitSeconds}`)
print(`iterate_s={iterateSeconds} rows_s={eventCount/iterateSeconds} checksum={checksum}`)
print(`reduce_s={reduceSeconds} reduce_rows_s={eventCount/reduceSeconds} reduced={reduced}`)
print(`packed_bytes={bytes} bytes_event={bytes/eventCount}`)
