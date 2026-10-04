--!native

local World = require('@dream/ecs/world')

return table.freeze {
  new = World.new,
}
