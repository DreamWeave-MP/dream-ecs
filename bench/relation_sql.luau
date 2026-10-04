local ecs = require('@dream/ecs')

local edgeCount = tonumber(arg[1]) or 200000
local parentCount = tonumber(arg[2]) or 1000
local repeats = tonumber(arg[3]) or 40

local world = ecs.new()
local position = world:component('Position', { axisX='f32' })
world:spawnBatch(edgeCount + parentCount, { position })
local parent = world:relation('Parent')
for child = 1, edgeCount do
  local target = edgeCount + ((child - 1) % parentCount) + 1
  world:relate(parent, world:_token(child), world:_token(target))
end
local target = world:_token(edgeCount + math.floor(parentCount / 2))
local db = world:sql()
local direct = db:prepare("SELECT source FROM relations WHERE relation = 'Parent' AND target = ?")
local joined = db:prepare([[SELECT e.entity
  FROM relations r INNER JOIN entities e ON r.source = e.entity
  WHERE r.relation = 'Parent' AND r.target = ? AND e.Position = TRUE]])

local function bench(stmt)
  local count = 0
  local before = os.clock()
  for _ = 1, repeats do
    local result = stmt.run({ target })
    count += #result.rows
  end
  return os.clock() - before, count
end

local directTime, directRows = bench(direct)
local joinTime, joinRows = bench(joined)
print(`edges={edgeCount} parents={parentCount} repeats={repeats}`)
print(`direct_s={directTime} direct_us_query={directTime/repeats*1e6} rows={directRows}`)
print(`join_s={joinTime} join_us_query={joinTime/repeats*1e6} rows={joinRows}`)
