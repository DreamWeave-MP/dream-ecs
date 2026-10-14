local ecs = require('@dream/ecs')
local edgeCount = tonumber(arg[1]) or 200000
local parentCount = tonumber(arg[2]) or 1000
local repeats = tonumber(arg[3]) or 100
local world=ecs.new(); world:spawnBatch(edgeCount+parentCount,{})
local parent=world:relation('Parent')
for child=1,edgeCount do local target=edgeCount+((child-1)%parentCount)+1; world:relate(parent,world:_token(child),world:_token(target)) end
local target=world:_token(edgeCount+math.floor(parentCount/2)); local stmt=world:sql():prepare("SELECT source FROM relations WHERE relation='Parent' AND target=?")
local before=os.clock(); local rows=0
for _=1,repeats do rows += #stmt.run({target}).rows end
local elapsed=os.clock()-before
print(`seconds={elapsed} us_query={elapsed/repeats*1e6} rows={rows}`)
