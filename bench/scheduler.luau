local ecs = require('@dream/ecs')

local systemCount = tonumber(arg[1]) or 4000
local world = ecs.new()
local fields = {}
for fieldIndex = 1, 64 do
  local component = world:component('Schedule' .. fieldIndex, { value = 'f32' })
  fields[fieldIndex] = component.value
end

local registrationStart = os.clock()
for systemIndex = 1, systemCount do
  local readField = fields[((systemIndex * 13) % 64) + 1]
  local writeField = fields[((systemIndex * 29) % 64) + 1]
  world:system({
    name = 'system' .. systemIndex,
    reads = { readField },
    writes = { writeField },
    update = function() end,
  })
end
local registrationSeconds = os.clock() - registrationStart

local scheduleStart = os.clock()
local waves = world:schedule()
local scheduleSeconds = os.clock() - scheduleStart
local scheduledSystems = 0
for _, wave in waves do scheduledSystems += #wave end

print(`systems={systemCount} waves={#waves} scheduled={scheduledSystems}`)
print(`registration_s={registrationSeconds} schedule_s={scheduleSeconds} schedule_us_system={scheduleSeconds/systemCount*1e6}`)
