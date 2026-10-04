--!native

local RelationStore = {}
RelationStore.__index = RelationStore

local EdgeBlockSize = 1024
local EdgeStride = 16
local HeadPageSize = 4096
local EmptySlot = 0
local Tombstone = 4294967295

local function hashPair(source, target)
  local value = bit32.bxor(source, bit32.lrotate(target, 16))
  value = bit32.bxor(value, bit32.rshift(value, 16))
  value = bit32.bxor(value, bit32.lshift(value, 7))
  value = bit32.bxor(value, bit32.rshift(value, 11))
  return bit32.band(value, 0x7fffffff)
end

local function edgeLocation(edgeId)
  local zero = edgeId - 1
  return math.floor(zero / EdgeBlockSize) + 1, (zero % EdgeBlockSize) * EdgeStride
end

local function headLocation(entityIndex)
  local zero = entityIndex - 1
  return math.floor(zero / HeadPageSize) + 1, (zero % HeadPageSize) * 4
end

local function head(pageTable, entityIndex)
  local pageIndex, offset = headLocation(entityIndex)
  local page = pageTable[pageIndex]
  if not page then return 0 end
  return buffer.readu32(page, offset)
end

local function setHead(pageTable, entityIndex, edgeId)
  local pageIndex, offset = headLocation(entityIndex)
  local page = pageTable[pageIndex]
  if not page then
    page = buffer.create(HeadPageSize * 4)
    pageTable[pageIndex] = page
  end
  buffer.writeu32(page, offset, edgeId)
end

local function edgeBlock(store, edgeId)
  local blockIndex, offset = edgeLocation(edgeId)
  return store._blocks[blockIndex], offset
end

local function edgePair(store, edgeId)
  local block, offset = edgeBlock(store, edgeId)
  return buffer.readu32(block, offset), buffer.readu32(block, offset + 4)
end

local function edgeActive(store, edgeId)
  local block, offset = edgeBlock(store, edgeId)
  return buffer.readu32(block, offset) ~= 0
end

local function findSlot(store, source, target)
  local capacity = store._hashCapacity
  local mask = capacity - 1
  local slot = bit32.band(hashPair(source, target), mask)
  local firstTombstone = nil

  for _ = 1, capacity do
    local offset = slot * 4
    local edgeId = buffer.readu32(store._hash, offset)
    if edgeId == EmptySlot then return false, firstTombstone or slot end

    if edgeId == Tombstone then
      if firstTombstone == nil then firstTombstone = slot end
    else
      local foundSource, foundTarget = edgePair(store, edgeId)
      if foundSource == source and foundTarget == target and edgeActive(store, edgeId) then
        return true, slot, edgeId
      end
    end
    slot = bit32.band(slot + 1, mask)
  end

  return false, firstTombstone
end

local function insertHash(store, edgeId, source, target)
  local _, slot = findSlot(store, source, target)
  if slot == nil then error('ecs: relation hash is full') end
  if buffer.readu32(store._hash, slot * 4) == Tombstone then store._tombstones -= 1 end
  buffer.writeu32(store._hash, slot * 4, edgeId)
  store._hashUsed += 1
end

local function rehash(store, capacity)
  local old = store._hash
  store._hash = buffer.create(capacity * 4)
  store._hashCapacity = capacity
  store._hashUsed = 0
  store._tombstones = 0

  if not old then return end

  for edgeId = 1, store._nextEdge - 1 do
    if edgeActive(store, edgeId) then
      local source, target = edgePair(store, edgeId)
      insertHash(store, edgeId, source, target)
    end
  end
end

local function ensureHash(store)
  local occupied = store._hashUsed + store._tombstones + 1
  if occupied * 10 < store._hashCapacity * 7 then return end
  local capacity = if store._hashUsed * 10 >= store._hashCapacity * 5 then store._hashCapacity * 2 else store._hashCapacity
  rehash(store, capacity)
end

local function appendEdge(store, source, target)
  local edgeId = store._nextEdge
  store._nextEdge += 1
  local blockIndex, offset = edgeLocation(edgeId)
  local block = store._blocks[blockIndex]
  if not block then
    block = buffer.create(EdgeBlockSize * EdgeStride)
    store._blocks[blockIndex] = block
  end

  buffer.writeu32(block, offset, source)
  buffer.writeu32(block, offset + 4, target)
  buffer.writeu32(block, offset + 8, head(store._outHeads, source))
  buffer.writeu32(block, offset + 12, head(store._inHeads, target))
  setHead(store._outHeads, source, edgeId)
  setHead(store._inHeads, target, edgeId)
  return edgeId
end

function RelationStore.new(definition)
  local self = setmetatable({
    definition = definition,
    count = 0,
    _blocks = {},
    _nextEdge = 1,
    _outHeads = {},
    _inHeads = {},
    _hash = nil,
    _hashCapacity = 1024,
    _hashUsed = 0,
    _tombstones = 0,
    _dead = 0,
  }, RelationStore)
  rehash(self, self._hashCapacity)
  return self
end

function RelationStore:add(source, target)
  local found = findSlot(self, source, target)
  if found then return false end
  ensureHash(self)
  local edgeId = appendEdge(self, source, target)
  insertHash(self, edgeId, source, target)
  self.count += 1
  return true
end

function RelationStore:remove(source, target)
  local found, slot, edgeId = findSlot(self, source, target)
  if not found then return false end
  local block, offset = edgeBlock(self, edgeId)
  buffer.writeu32(block, offset, 0)
  buffer.writeu32(self._hash, slot * 4, Tombstone)
  self._hashUsed -= 1
  self._tombstones += 1
  self.count -= 1
  self._dead += 1
  return true
end

function RelationStore:has(source, target)
  local found = findSlot(self, source, target)
  return found
end

function RelationStore:targets(source)
  local edgeId = head(self._outHeads, source)
  return function()
    while edgeId ~= 0 do
      local current = edgeId
      local block, offset = edgeBlock(self, current)
      edgeId = buffer.readu32(block, offset + 8)
      if buffer.readu32(block, offset) ~= 0 then
        return buffer.readu32(block, offset + 4)
      end
    end
    return nil
  end
end

function RelationStore:sources(target)
  local edgeId = head(self._inHeads, target)
  return function()
    while edgeId ~= 0 do
      local current = edgeId
      local block, offset = edgeBlock(self, current)
      edgeId = buffer.readu32(block, offset + 12)
      if buffer.readu32(block, offset) ~= 0 then
        return buffer.readu32(block, offset)
      end
    end
    return nil
  end
end

function RelationStore:removeEntity(entityIndex)
  local edgeId = head(self._outHeads, entityIndex)
  while edgeId ~= 0 do
    local block, offset = edgeBlock(self, edgeId)
    local nextEdge = buffer.readu32(block, offset + 8)
    if buffer.readu32(block, offset) ~= 0 then
      self:remove(entityIndex, buffer.readu32(block, offset + 4))
    end
    edgeId = nextEdge
  end

  edgeId = head(self._inHeads, entityIndex)
  while edgeId ~= 0 do
    local block, offset = edgeBlock(self, edgeId)
    local nextEdge = buffer.readu32(block, offset + 12)
    local source = buffer.readu32(block, offset)
    if source ~= 0 then self:remove(source, entityIndex) end
    edgeId = nextEdge
  end
end

function RelationStore:compact()
  if self._dead == 0 then return self end
  local fresh = RelationStore.new(self.definition)
  for source, target in self:iterate() do fresh:add(source, target) end
  return fresh
end

function RelationStore:iterate()
  local edgeId = 0
  return function()
    while true do
      edgeId += 1
      if edgeId >= self._nextEdge then return nil end
      if edgeActive(self, edgeId) then return edgePair(self, edgeId) end
    end
  end
end

function RelationStore:bytes()
  local blocks = #self._blocks * EdgeBlockSize * EdgeStride
  local heads = (#self._outHeads + #self._inHeads) * HeadPageSize * 4
  return blocks + heads + self._hashCapacity * 4
end

return RelationStore
