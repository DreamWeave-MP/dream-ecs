local ecs = require('@dream/ecs')
local count = tonumber(arg[1]) or 200000
local world = ecs.new()
world:spawnBatch(count + 1, {})
local parent = world:relation('Parent')
local before = os.clock()
for index = 1, count do
  world:relate(parent, world:_token(index), world:_token(index + 1))
end
local addSeconds = os.clock() - before
before = os.clock()
local hits = 0
local store = world._relationStores[parent.id]
for index = 1, count do
  if store:has(index, index + 1) then hits += 1 end
end
local lookupSeconds = os.clock() - before
print(`edges={count} add_s={addSeconds} add_per_s={count / addSeconds}`)
print(`lookup_s={lookupSeconds} lookup_per_s={count / lookupSeconds} hits={hits}`)
print(`packed_bytes={store:bytes()} bytes_edge={store:bytes() / count}`)
