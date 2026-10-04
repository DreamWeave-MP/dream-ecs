local ecs = require('@dream/ecs')
local count = tonumber(arg[1]) or 200000
local iterations = tonumber(arg[2]) or 1000000
local world = ecs.new({ chunkCapacity = 8192 })
local link = world:component('Link', { target = 'entity' })
world:spawnBatch(count, { link })
local target = world:_token(count)
local before = os.clock()
local checksum = 0
for iteration = 1, iterations do
  local index = ((iteration * 8191) % count) + 1
  local entity = world:_token(index)
  world:set(entity, link.target, target)
  checksum += world:get(entity, link.target) or 0
end
local elapsed = os.clock() - before
print(`width={link.target.width} iterations={iterations} seconds={elapsed} pairs_s={iterations/elapsed} checksum={checksum}`)
print(`bytes={world:stats().chunkBytes}`)
