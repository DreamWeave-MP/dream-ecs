local ecs = require('@dream/ecs')
local count = tonumber(arg[1]) or 200000
local world = ecs.new({ chunkCapacity = tonumber(arg[2]) or 8192 })
local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local velocity = world:component('Velocity', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local health = world:component('Health', { current = { type = 'f32', default = 100 }, maximum = { type = 'f32', default = 100 } })
world:spawnBatch(count, { position, velocity })
local query = world:query('SELECT Position, Velocity FROM entities')
local before = os.clock()
local moved = world:addQuery(query, health, { current = 75, maximum = 125 })
local elapsed = os.clock() - before
print(`count={count} moved={moved} seconds={elapsed} ops_s={count/elapsed}`)
