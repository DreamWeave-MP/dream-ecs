local ecs=require('@dream/ecs')
local edgeCount=tonumber(arg[1]) or 200000
local parentCount=tonumber(arg[2]) or 1000
local repeats=tonumber(arg[3]) or 1000
local world=ecs.new(); local position=world:component('Position',{axisX='f32'}); world:spawnBatch(edgeCount+parentCount,{position})
local parent=world:relation('Parent')
for child=1,edgeCount do local target=edgeCount+((child-1)%parentCount)+1; world:relate(parent,world:_token(child),world:_token(target)) end
local target=world:_token(edgeCount+math.floor(parentCount/2))
local Text=[[SELECT e.entity, Position FROM relations r INNER JOIN entities e ON r.source = e.entity WHERE r.relation = 'Parent' AND r.target = ?]]
local hot=world:query(Text); local cold=world:sql():prepare(Text)
local sum=0; local before=os.clock()
for _=1,repeats do for entity,chunk,row in hot:rows({target}) do sum += row; if entity<0 or chunk.count<0 then error('no') end end end
local hotTime=os.clock()-before
before=os.clock(); local rows=0
for _=1,repeats do rows += #cold.run({target}).rows end
local coldTime=os.clock()-before
print(`edges={edgeCount} degree={edgeCount/parentCount} repeats={repeats}`)
print(`hot_s={hotTime} hot_us_query={hotTime/repeats*1e6}`)
print(`cold_s={coldTime} cold_us_query={coldTime/repeats*1e6}`)
print(`ratio={hotTime/coldTime} rows={rows} checksum={sum}`)
