local ecs = require('@dream/ecs')

local entityCount = tonumber(arg[1]) or 200000
local repeats = tonumber(arg[2]) or 10000
local world = ecs.new({ chunkCapacity = 8192 })
local position = world:component('Position', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
local velocity = world:component('Velocity', { axisX = 'f32', axisY = 'f32', axisZ = 'f32' })
world:spawnBatch(entityCount, { position, velocity })
local target = world:_token(math.floor(entityCount / 2))
world:set(target, position.axisX, 7)
world:set(target, velocity.axisX, 3)

local database = world:sql()
local direct = database:prepare('SELECT axisX FROM Position WHERE entity = ?')
local joined = database:prepare([[
  SELECT p.axisX AS positionX, v.axisX AS velocityX
  FROM Position p INNER JOIN Velocity v ON p.entity = v.entity
  WHERE p.entity = ?
]])

local function bench(statement)
  local checksum = 0
  local before = os.clock()
  for _ = 1, repeats do
    local rows = statement.run({ target }).rows
    checksum += #rows
  end
  return os.clock() - before, checksum
end

local directSeconds, directRows = bench(direct)
local joinSeconds, joinRows = bench(joined)
print(`entities={entityCount} repeats={repeats}`)
print(`direct_us={(directSeconds/repeats)*1e6} rows={directRows}`)
print(`join_us={(joinSeconds/repeats)*1e6} rows={joinRows}`)
