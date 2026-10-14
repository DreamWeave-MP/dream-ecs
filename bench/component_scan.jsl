local ecs = require('@dream/ecs')
local count = tonumber(arg[1]) or 1000000
local world = ecs.new({ chunkCapacity = 8192 })
local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
world:spawnBatch(count, { position })
for chunk in world:query('SELECT Position FROM entities'):chunks() do
  local axisX = chunk:buffer(position.axisX)
  for row = 0, chunk.count - 1 do buffer.writef32(axisX, row * 4, row % 100) end
end
local database = world:sql()
local statement = database:prepare('SELECT COUNT(*) AS total, AVG(axisX) AS average FROM Position')
local before = os.clock()
local result = statement.run()
local elapsed = os.clock() - before
print(`count={count} seconds={elapsed} rows_s={count/elapsed} total={result.rows[1].total} avg={result.rows[1].average}`)
