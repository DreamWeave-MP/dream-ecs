--!strict
--!native

local CommandBuffer = {}
CommandBuffer.__index = CommandBuffer

local BlockCapacity = 1024
local Stride = 16
local Add = 1
local Remove = 2
local Destroy = 3
local Spawn = 4
local AddQuery = 5
local RemoveQuery = 6

local function location(index)
  local zero = index - 1
  return math.floor(zero / BlockCapacity) + 1, (zero % BlockCapacity) * Stride
end

local function ensureBlock(self, blockIndex)
  local block = self._blocks[blockIndex]
  if not block then
    block = buffer.create(BlockCapacity * Stride)
    self._blocks[blockIndex] = block
  end
  return block
end

local function payload(self, value)
  if value == nil then return 0 end
  local index = #self._payloads + 1
  self._payloads[index] = value
  return index
end

local function append(self, kind, entity, componentId, value)
  self._count += 1
  local blockIndex, offset = location(self._count)
  local block = ensureBlock(self, blockIndex)
  buffer.writeu8(block, offset, kind)
  buffer.writeu16(block, offset + 2, componentId or 0)
  buffer.writeu32(block, offset + 4, payload(self, value))
  buffer.writef64(block, offset + 8, entity or 0)
end

function CommandBuffer:add(entity, component, value)
  append(self, Add, entity, component.id, value)
end

function CommandBuffer:remove(entity, component)
  append(self, Remove, entity, component.id, nil)
end

function CommandBuffer:destroy(entity)
  append(self, Destroy, entity, 0, nil)
end

function CommandBuffer:spawn(initial)
  append(self, Spawn, 0, 0, initial or {})
end

function CommandBuffer:addQuery(query, component, value)
  local queryIndex = payload(self, query)
  local valueIndex = payload(self, value)
  self._count += 1
  local blockIndex, offset = location(self._count)
  local block = ensureBlock(self, blockIndex)
  buffer.writeu8(block, offset, AddQuery)
  buffer.writeu16(block, offset + 2, component.id)
  buffer.writeu32(block, offset + 4, queryIndex)
  buffer.writef64(block, offset + 8, valueIndex)
end

function CommandBuffer:removeQuery(query, component)
  append(self, RemoveQuery, 0, component.id, query)
end

function CommandBuffer:clear()
  self._count = 0
  table.clear(self._payloads)
end

function CommandBuffer:count()
  return self._count
end

function CommandBuffer:bytes()
  return #self._blocks * BlockCapacity * Stride
end

function CommandBuffer:flush()
  local world = self._world
  local components = world._components
  local payloads = self._payloads
  for index = 1, self._count do
    local blockIndex, offset = location(index)
    local block = self._blocks[blockIndex]
    local kind = buffer.readu8(block, offset)
    local componentId = buffer.readu16(block, offset + 2)
    local payloadIndex = buffer.readu32(block, offset + 4)
    local entity = buffer.readf64(block, offset + 8)
    local value = if payloadIndex ~= 0 then payloads[payloadIndex] else nil

    if kind == Add then world:add(entity, components[componentId], value)
    elseif kind == Remove then world:remove(entity, components[componentId])
    elseif kind == Destroy then world:destroy(entity)
    elseif kind == Spawn then world:spawn(value)
    elseif kind == AddQuery then
      local queryValue = value
      local valueIndex = buffer.readf64(block, offset + 8)
      world:addQuery(queryValue, components[componentId], if valueIndex ~= 0 then payloads[valueIndex] else nil)
    else world:removeQuery(value, components[componentId]) end
  end
  local count = self._count
  self:clear()
  return count
end

local function new(world)
  return setmetatable({ _world = world, _blocks = {}, _payloads = {}, _count = 0 }, CommandBuffer)
end

return {
  new = new,
}
