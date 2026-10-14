local ecs = require('@dream/ecs')

local entityCount = tonumber(arg[1]) or 1000000
local world = ecs.new({ chunkCapacity = 8192 })
local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local velocity = world:component('Velocity', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local frozen = world:tag('Frozen')
world:spawnBatch(entityCount, { position, velocity })

local function seconds(action)
  local before = os.clock()
  local result = action()
  return os.clock() - before, result
end

local compileSeconds, query = seconds(function()
  return world:query('SELECT entity, Position, Velocity FROM entities WHERE Frozen = FALSE')
end)

local cachedSeconds = seconds(function()
  for _ = 1, 100000 do
    world:query('SELECT entity, Position, Velocity FROM entities WHERE Frozen = FALSE')
  end
end)

local db = world:sql()
local sqlSeconds, result = seconds(function()
  return db:query('SELECT COUNT(*) AS n FROM entities WHERE Position = TRUE AND Velocity = TRUE AND Frozen = FALSE')
end)

print(`entities={entityCount}`)
print(`compile_us={compileSeconds * 1e6} archetypes={#query._archetypes}`)
print(`cached_100k_s={cachedSeconds} cached_ns={(cachedSeconds / 100000) * 1e9}`)
print(`sql_count_s={sqlSeconds} n={result.rows[1].n}`)
