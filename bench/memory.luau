local ecs = require('@dream/ecs')
local count = tonumber(arg[1]) or 1000000
local world = ecs.new({ chunkCapacity = tonumber(arg[2]) or 8192 })
local position = world:component('Position', { axisX='f32', axisY='f32', axisZ='f32' })
local velocity = world:component('Velocity', { axisX='f32', axisY='f32', axisZ='f32' })
world:spawnBatch(count, { position, velocity })
local stats=world:stats()
for key,value in pairs(stats) do print(key,value) end
