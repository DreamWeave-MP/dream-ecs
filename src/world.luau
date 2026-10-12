--!strict
--!native

local sql = require('@jessql')
local Query = require('@dream/ecs/query')
local RelationQuery = require('@dream/ecs/relation-query')
local RelationStore = require('@dream/ecs/relation')
local EventStore = require('@dream/ecs/event')
local CommandBuffer = require('@dream/ecs/command')

local World = {}
World.__index = World

local EntityPageSize = 65536
local EntityStride = 8
local DefaultChunkCapacity = 8192
local TokenScale = 4294967296

local FieldTypes = {
  u8 = { width = 1, read = buffer.readu8, write = buffer.writeu8 },
  u16 = { width = 2, read = buffer.readu16, write = buffer.writeu16 },
  u32 = { width = 4, read = buffer.readu32, write = buffer.writeu32 },
  i32 = { width = 4, read = buffer.readi32, write = buffer.writei32 },
  f32 = { width = 4, read = buffer.readf32, write = buffer.writef32 },
  f64 = { width = 8, read = buffer.readf64, write = buffer.writef64 },
  bool = { width = 1, read = buffer.readu8, write = buffer.writeu8 },
  entity = { width = 8 },
}

local Chunk = {}
Chunk.__index = Chunk

function Chunk:buffer(field)
  local value = self.columns[field.id]
  if not value then error(`ecs: field {field.component.name}.{field.name} is not in this chunk`, 2) end
  return value
end

function Chunk:entities()
  return self.entityIds
end

function Chunk:entity(row)
  local index = buffer.readu32(self.entityIds, row * 4)
  return self.world:_token(index)
end

local function pageFor(world, index, create)
  local pageIndex = math.floor((index - 1) / EntityPageSize) + 1
  local page = world._entityPages[pageIndex]
  if not page and create then
    page = buffer.create(EntityPageSize * EntityStride)
    world._entityPages[pageIndex] = page
  end
  local offset = ((index - 1) % EntityPageSize) * EntityStride
  return page, offset
end

function World:_generation(index)
  local page, offset = pageFor(self, index, false)
  if not page then return 0 end
  return buffer.readu16(page, offset)
end

function World:_locationIndex(index)
  local page, offset = pageFor(self, index, false)
  if not page then return nil end
  local archetypeId = buffer.readu16(page, offset + 2)
  if archetypeId == 0 then return nil end
  return buffer.readu16(page, offset), archetypeId, buffer.readu16(page, offset + 4), buffer.readu16(page, offset + 6)
end

function World:_token(index)
  return self:_generation(index) * TokenScale + index
end

local function decodeToken(token)
  local generation = math.floor(token / TokenScale)
  return token - generation * TokenScale, generation
end

function World:_location(token)
  local index, generation = decodeToken(token)
  local page, offset = pageFor(self, index, false)
  if not page then return nil end
  local archetypeId = buffer.readu16(page, offset + 2)
  if archetypeId == 0 or buffer.readu16(page, offset) ~= generation then return nil end
  return index, archetypeId, buffer.readu16(page, offset + 4), buffer.readu16(page, offset + 6)
end

function World:_setLocation(index, generation, archetypeId, chunkIndex, row)
  if archetypeId > 65535 or chunkIndex > 65535 or row > 65535 then
    error('ecs: packed entity locator overflow', 2)
  end
  local page, offset = pageFor(self, index, true)
  buffer.writeu16(page, offset, generation)
  buffer.writeu16(page, offset + 2, archetypeId)
  buffer.writeu16(page, offset + 4, chunkIndex)
  buffer.writeu16(page, offset + 6, row)
end

function World:_kill(index)
  local page, offset = pageFor(self, index, false)
  local generation = buffer.readu16(page, offset) + 1
  if generation > 65535 then generation = 1 end
  buffer.writeu16(page, offset, generation)
  buffer.writeu16(page, offset + 2, 0)
end

local function archetypeKey(ids)
  return table.concat(ids, ':')
end

local function collectComponentIds(initial)
  local ids = {}
  for component, value in pairs(initial or {}) do
    if type(component) == 'table' and component.id then
      if value ~= false and value ~= nil then table.insert(ids, component.id) end
    end
  end
  table.sort(ids)
  return ids
end

local function newChunk(world, archetype, capacity)
  local columns = {}
  for _, componentId in archetype.componentIds do
    local component = world._components[componentId]
    for _, field in component.fields do
      columns[field.id] = buffer.create(capacity * field.width)
    end
  end

  return setmetatable({
    world = world,
    archetype = archetype,
    count = 0,
    capacity = capacity,
    entityIds = buffer.create(capacity * 4),
    columns = columns,
    highWater = 0,
  }, Chunk)
end

function World:_archetype(ids)
  local key = archetypeKey(ids)
  local existing = self._archetypeByKey[key]
  if existing then return existing end

  local has = {}
  for _, componentId in ids do has[componentId] = true end

  local archetype = {
    id = #self._archetypes + 1,
    key = key,
    has = has,
    componentIds = table.clone(ids),
    chunks = {},
    count = 0,
    addTransitions = {},
    removeTransitions = {},
  }
  self._archetypes[archetype.id] = archetype
  self._archetypeByKey[key] = archetype
  for _, query in self._queries do query:_consider(archetype) end
  return archetype
end

function World:_chunkForSpawn(archetype)
  local chunk = archetype.chunks[#archetype.chunks]
  if chunk and chunk.count < chunk.capacity then return chunk, #archetype.chunks end
  chunk = newChunk(self, archetype, self.chunkCapacity)
  table.insert(archetype.chunks, chunk)
  return chunk, #archetype.chunks
end

function World:_allocateEntity()
  local index
  if #self._free > 0 then
    index = self._free[#self._free]
    self._free[#self._free] = nil
  else
    self._nextEntity += 1
    index = self._nextEntity
  end
  local generation = self:_generation(index)
  if generation == 0 then generation = 1 end
  return index, generation
end

local function writeInitial(world, chunk, row, component, values, fresh)
  if component.tag then return end
  values = values or {}
  for _, field in component.fields do
    local value = values[field.name]
    if value == nil then
      value = field.default or 0
      if fresh and value == 0 then continue end
    end
    local offset = row * field.width
    if field.kind == 'bool' then value = if value then 1 else 0 end

    if field.kind == 'entity' then
      local entityIndex, generation
      if value == 0 then
        entityIndex, generation = 0, 0
      else
        entityIndex, generation = decodeToken(value)
      end
      buffer.writeu32(chunk.columns[field.id], offset, entityIndex)
      buffer.writeu32(chunk.columns[field.id], offset + 4, generation)
    else
      field.write(chunk.columns[field.id], offset, value)
    end
  end
end

function World:spawnBatch(count, components)
  local ids = {}
  for _, component in components do table.insert(ids, component.id) end
  table.sort(ids)
  local archetype = self:_archetype(ids)

  for _ = 1, count do
    local chunk, chunkIndex = self:_chunkForSpawn(archetype)
    local row = chunk.count
    local index, generation = self:_allocateEntity()
    buffer.writeu32(chunk.entityIds, row * 4, index)

    local fresh = row >= chunk.highWater
    for _, componentId in ids do
      local component = self._components[componentId]
      if not fresh or component.needsFreshInit then writeInitial(self, chunk, row, component, nil, fresh) end
    end

    chunk.count += 1
    if chunk.count > chunk.highWater then chunk.highWater = chunk.count end
    archetype.count += 1
    self.count += 1
    self:_setLocation(index, generation, archetype.id, chunkIndex, row)
  end

  return archetype
end

function World:spawn(initial)
  initial = initial or {}
  local ids = collectComponentIds(initial)
  local archetype = self:_archetype(ids)
  local chunk, chunkIndex = self:_chunkForSpawn(archetype)
  local row = chunk.count
  local index, generation = self:_allocateEntity()

  buffer.writeu32(chunk.entityIds, row * 4, index)
  for _, componentId in ids do
    local component = self._components[componentId]
    writeInitial(self, chunk, row, component, initial[component], row >= chunk.highWater)
  end

  chunk.count += 1
  if chunk.count > chunk.highWater then chunk.highWater = chunk.count end
  archetype.count += 1
  self.count += 1
  self:_setLocation(index, generation, archetype.id, chunkIndex, row)
  return generation * TokenScale + index
end

local function copyRow(world, sourceChunk, sourceRow, targetChunk, targetRow, targetArchetype, added, addedValue)
  local index = buffer.readu32(sourceChunk.entityIds, sourceRow * 4)
  buffer.writeu32(targetChunk.entityIds, targetRow * 4, index)

  for _, componentId in targetArchetype.componentIds do
    local component = world._components[componentId]
    if componentId == added then
      writeInitial(world, targetChunk, targetRow, component, addedValue, targetRow >= targetChunk.highWater)
    elseif sourceChunk.archetype.has[componentId] then
      for _, field in component.fields do
        buffer.copy(targetChunk.columns[field.id], targetRow * field.width, sourceChunk.columns[field.id], sourceRow * field.width, field.width)
      end
    end
  end
end

local function addedTransition(world, source, component)
  local target = source.addTransitions[component.id]
  if target then return target end

  local ids = {}
  local inserted = false
  for _, componentId in source.componentIds do
    if not inserted and component.id < componentId then
      ids[#ids + 1] = component.id
      inserted = true
    end
    ids[#ids + 1] = componentId
  end

  if not inserted then ids[#ids + 1] = component.id end
  target = world:_archetype(ids)
  source.addTransitions[component.id] = target
  target.removeTransitions[component.id] = source
  return target
end

local function removedTransition(world, source, component)
  local target = source.removeTransitions[component.id]
  if target then return target end

  local ids = {}
  for _, componentId in source.componentIds do
    if componentId ~= component.id then ids[#ids + 1] = componentId end
  end
  target = world:_archetype(ids)
  source.removeTransitions[component.id] = target
  target.addTransitions[component.id] = source
  return target
end

function World:_removeRow(archetype, chunkIndex, row)
  local chunk = archetype.chunks[chunkIndex]
  local last = chunk.count - 1
  if row ~= last then
    local movedIndex = buffer.readu32(chunk.entityIds, last * 4)
    buffer.writeu32(chunk.entityIds, row * 4, movedIndex)
    for _, componentId in archetype.componentIds do
      local component = self._components[componentId]
      for _, field in component.fields do
        buffer.copy(chunk.columns[field.id], row * field.width, chunk.columns[field.id], last * field.width, field.width)
      end
    end
    local movedPage, movedOffset = pageFor(self, movedIndex, false)
    buffer.writeu16(movedPage, movedOffset + 6, row)
  end
  chunk.count -= 1
  archetype.count -= 1
end

function World:destroy(token)
  local index, archetypeId, chunkIndex, row = self:_location(token)
  if not index then return false end
  local archetype = self._archetypes[archetypeId]
  self:_removeRow(archetype, chunkIndex, row)
  for _, store in self._relationStores do store:removeEntity(index) end
  self:_kill(index)
  table.insert(self._free, index)
  self.count -= 1
  return true
end

function World:valid(token)
  return self:_location(token) ~= nil
end

function World:has(token, component)
  local _, archetypeId = self:_location(token)
  if not archetypeId then return false end
  return self._archetypes[archetypeId].has[component.id] == true
end

-- Resolve an entity token to its current packed storage row. The returned chunk/row is
-- intentionally ephemeral: structural changes may move the entity, so callers must not cache the
-- row across spawn/destroy/add/remove/command-buffer synchronization boundaries. This is the hot
-- escape hatch for bulk producers that already know the field layout and want one token lookup
-- followed by direct SoA buffer writes.
function World:locate(token)
  local _, archetypeId, chunkIndex, row = self:_location(token)
  if not archetypeId then return nil end
  return self._archetypes[archetypeId].chunks[chunkIndex], row
end

function World:get(token, field)
  local _, archetypeId, chunkIndex, row = self:_location(token)
  if not archetypeId then return nil end
  local archetype = self._archetypes[archetypeId]
  if not archetype.has[field.component.id] then return nil end
  local chunk = archetype.chunks[chunkIndex]
  local column = chunk.columns[field.id]
  local offset = row * field.width
  if field.kind == 'entity' then
    local entityIndex = buffer.readu32(column, offset)
    if entityIndex == 0 then return nil end
    local generation = buffer.readu32(column, offset + 4)
    return generation * TokenScale + entityIndex
  end
  local value = field.read(column, offset)
  if field.kind == 'bool' then return value ~= 0 end
  return value
end

function World:set(token, field, value)
  local _, archetypeId, chunkIndex, row = self:_location(token)
  if not archetypeId then return false end
  local archetype = self._archetypes[archetypeId]
  if not archetype.has[field.component.id] then return false end
  local column = archetype.chunks[chunkIndex].columns[field.id]
  local offset = row * field.width
  if field.kind == 'bool' then value = if value then 1 else 0 end

  if field.kind == 'entity' then
    local entityIndex, generation = decodeToken(value)
    buffer.writeu32(column, offset, entityIndex)
    buffer.writeu32(column, offset + 4, generation)
  else
    field.write(column, offset, value)
  end
  return true
end

function World:_migrateTo(token, targetArchetype, added, addedValue)
  local index, archetypeId, chunkIndex, row = self:_location(token)
  if not index then return false end
  local sourceArchetype = self._archetypes[archetypeId]
  local sourceChunk = sourceArchetype.chunks[chunkIndex]
  if sourceArchetype == targetArchetype then return true end

  local targetChunk, targetChunkIndex = self:_chunkForSpawn(targetArchetype)
  local targetRow = targetChunk.count
  copyRow(self, sourceChunk, row, targetChunk, targetRow, targetArchetype, added, addedValue)
  targetChunk.count += 1
  if targetChunk.count > targetChunk.highWater then targetChunk.highWater = targetChunk.count end
  targetArchetype.count += 1
  local generation = self:_generation(index)
  self:_setLocation(index, generation, targetArchetype.id, targetChunkIndex, targetRow)
  self:_removeRow(sourceArchetype, chunkIndex, row)
  return true
end

function World:_migrateArchetype(sourceArchetype, targetArchetype, added, addedValue)
  if sourceArchetype == targetArchetype or sourceArchetype.count == 0 then return 0 end
  local moved = sourceArchetype.count

  for _, sourceChunk in sourceArchetype.chunks do
    local sourceCount = sourceChunk.count
    local sourceRow = 0
    while sourceRow < sourceCount do
      local targetChunk, targetChunkIndex = self:_chunkForSpawn(targetArchetype)
      local targetRow = targetChunk.count
      local available = targetChunk.capacity - targetRow
      local take = math.min(sourceCount - sourceRow, available)

      buffer.copy(targetChunk.entityIds, targetRow * 4, sourceChunk.entityIds, sourceRow * 4, take * 4)
      for _, componentId in targetArchetype.componentIds do
        local component = self._components[componentId]
        if componentId == added then
          for rowOffset = 0, take - 1 do
            writeInitial(self, targetChunk, targetRow + rowOffset, component, addedValue, targetRow + rowOffset >= targetChunk.highWater)
          end
        elseif sourceArchetype.has[componentId] then
          for _, field in component.fields do
            buffer.copy(
              targetChunk.columns[field.id],
              targetRow * field.width,
              sourceChunk.columns[field.id],
              sourceRow * field.width,
              take * field.width
            )
          end
        end
      end

      for rowOffset = 0, take - 1 do
        local index = buffer.readu32(sourceChunk.entityIds, (sourceRow + rowOffset) * 4)
        self:_setLocation(index, self:_generation(index), targetArchetype.id, targetChunkIndex, targetRow + rowOffset)
      end

      targetChunk.count += take
      if targetChunk.count > targetChunk.highWater then targetChunk.highWater = targetChunk.count end
      targetArchetype.count += take
      sourceRow += take
    end
    sourceChunk.count = 0
  end

  sourceArchetype.count = 0
  return moved
end

function World:add(token, component, value)
  local _, archetypeId = self:_location(token)
  if not archetypeId then return false end
  local source = self._archetypes[archetypeId]
  if source.has[component.id] then return true end
  local target = addedTransition(self, source, component)
  return self:_migrateTo(token, target, component.id, value)
end

function World:remove(token, component)
  local _, archetypeId = self:_location(token)
  if not archetypeId then return false end
  local source = self._archetypes[archetypeId]
  if not source.has[component.id] then return true end
  local target = removedTransition(self, source, component)
  return self:_migrateTo(token, target, nil, nil)
end

function World:addQuery(query, component, value)
  if type(query) == 'string' then query = self:query(query) end
  local sources = table.clone(query._archetypes)
  local moved = 0
  for _, source in sources do
    if not source.has[component.id] then
      moved += self:_migrateArchetype(source, addedTransition(self, source, component), component.id, value)
    end
  end
  return moved
end

function World:removeQuery(query, component)
  if type(query) == 'string' then query = self:query(query) end
  local sources = table.clone(query._archetypes)
  local moved = 0
  for _, source in sources do
    if source.has[component.id] then
      moved += self:_migrateArchetype(source, removedTransition(self, source, component), nil, nil)
    end
  end
  return moved
end

function World:component(name, schema)
  if self._componentByName[name] then error(`ecs: duplicate component {name}`, 2) end
  if self._eventByName[name] then error(`ecs: component {name} collides with an event relation`, 2) end

  if not string.match(name, '^[A-Za-z_][A-Za-z0-9_]*$') then
    error('ecs: component names must be SQL-safe identifiers', 2)
  end

  if name == 'entities' or name == 'relations' or name == 'archetypes' or name == 'components' or name == 'fields'
      or name == 'events' or name == 'resources' or name == 'systems' then
    error(`ecs: component name {name} collides with a built-in SQL relation`, 2)
  end
  local id = #self._components + 1
  local component = { id = id, name = name, fields = {}, tag = false, needsFreshInit = false }
  self._components[id] = component
  self._componentByName[name] = component

  local names = {}
  for fieldName in pairs(schema or {}) do table.insert(names, fieldName) end
  table.sort(names)
  for _, fieldName in names do
    if fieldName == 'entity' or not string.match(fieldName, '^[A-Za-z_][A-Za-z0-9_]*$') then
      error(`ecs: component field {fieldName} must be a SQL-safe identifier other than entity`, 2)
    end
    local declaration = schema[fieldName]
    local kind, default
    if type(declaration) == 'string' then kind = declaration else kind, default = declaration.type, declaration.default end
    local fieldType = FieldTypes[kind]
    if not fieldType then error(`ecs: unsupported field type {tostring(kind)}`, 2) end

    local field = {
      id = self._nextField,
      name = fieldName,
      kind = kind,
      width = fieldType.width,
      read = fieldType.read,
      write = fieldType.write,
      default = default,
      component = component,
    }
    self._nextField += 1
    if default ~= nil and default ~= 0 and default ~= false then component.needsFreshInit = true end
    component.fields[#component.fields + 1] = field
    component[fieldName] = field
  end
  return component
end

function World:tag(name)
  local component = self:component(name, {})
  component.tag = true
  return component
end

function World:relation(name)
  if self._relationByName[name] then error(`ecs: duplicate relation {name}`, 2) end
  local definition = { id = #self._relations + 1, name = name }
  self._relations[definition.id] = definition
  self._relationByName[name] = definition
  self._relationStores[definition.id] = RelationStore.new(definition)
  return definition
end

function World:event(name, schema, options)
  if self._eventByName[name] then error(`ecs: duplicate event {name}`, 2) end
  if self._componentByName[name] then error(`ecs: event {name} collides with a component relation`, 2) end

  if not string.match(name, '^[A-Za-z_][A-Za-z0-9_]*$') then
    error('ecs: event names must be SQL-safe identifiers', 2)
  end

  if name == 'entities' or name == 'relations' or name == 'archetypes' or name == 'components' or name == 'fields'
      or name == 'events' or name == 'resources' or name == 'systems' then
    error(`ecs: event name {name} collides with a built-in SQL relation`, 2)
  end
  local definition = { id = #self._eventDefs + 1, name = name }
  local store = EventStore.new(definition, schema, options)
  definition.store = store
  self._eventDefs[definition.id] = definition
  self._events[definition.id] = store
  self._eventByName[name] = store
  return store
end


function World:relate(relation, source, target)
  local sourceIndex = self:_location(source)
  local targetIndex = self:_location(target)
  if not sourceIndex or not targetIndex then return false end
  return self._relationStores[relation.id]:add(sourceIndex, targetIndex)
end

function World:unrelate(relation, source, target)
  local sourceIndex = self:_location(source)
  local targetIndex = self:_location(target)
  if not sourceIndex or not targetIndex then return false end
  return self._relationStores[relation.id]:remove(sourceIndex, targetIndex)
end

function World:targets(relation, source)
  local sourceIndex = self:_location(source)
  if not sourceIndex then return function() return nil end end
  local iter = self._relationStores[relation.id]:targets(sourceIndex)
  return function()
    local index = iter()
    while index do
      local token = self:_token(index)
      if self:valid(token) then return token end
      index = iter()
    end
    return nil
  end
end

function World:sources(relation, target)
  local targetIndex = self:_location(target)
  if not targetIndex then return function() return nil end end
  local iter = self._relationStores[relation.id]:sources(targetIndex)
  return function()
    local index = iter()
    while index do
      local token = self:_token(index)
      if self:valid(token) then return token end
      index = iter()
    end
    return nil
  end
end

function World:compactRelations()
  for relationId, store in self._relationStores do
    self._relationStores[relationId] = store:compact()
  end
end


local AccessStride = 16777216
local ComponentAccessBase = AccessStride
local ResourceAccessBase = AccessStride * 2
local RelationAccessBase = AccessStride * 3
local EventAccessBase = AccessStride * 4

local function componentSet(components)
  local out = {}
  for _, definition in components or {} do
    local component = definition.component or definition
    out[component.id] = true
  end
  return out
end

local function componentAccessSet(definitions, out)
  out = out or {}
  for _, definition in definitions or {} do
    if definition.component then
      out[definition.id] = true
    elseif definition.tag or #definition.fields == 0 then
      out[ComponentAccessBase + definition.id] = true
    else
      for _, field in definition.fields do out[field.id] = true end
    end
  end
  return out
end

local function accessSet(definitions, base, out)
  out = out or {}
  for _, definition in definitions or {} do out[base + definition.id] = true end
  return out
end

function World:system(definition)
  if definition.name and self._systemByName[definition.name] then
    error(`ecs: duplicate system {definition.name}`, 2)
  end

  if type(definition.update) ~= 'function' then error('ecs: system update must be a function', 2) end

  local query = if type(definition.query) == 'string' then self:query(definition.query) else definition.query
  local defaultReads = if query then query.selected else {}
  local reads = componentSet(definition.reads or defaultReads)
  local writes = componentSet(definition.writes)
  local readAccess = componentAccessSet(definition.reads or defaultReads)
  local writeAccess = componentAccessSet(definition.writes)
  accessSet(definition.readsResources, ResourceAccessBase, readAccess)
  accessSet(definition.writesResources, ResourceAccessBase, writeAccess)
  accessSet(definition.readsRelations, RelationAccessBase, readAccess)
  accessSet(definition.writesRelations, RelationAccessBase, writeAccess)
  accessSet(definition.readsEvents, EventAccessBase, readAccess)
  accessSet(definition.writesEvents, EventAccessBase, writeAccess)
  local system = {
    id = #self._systems + 1,
    name = definition.name or `system{#self._systems + 1}`,
    query = query,
    reads = reads,
    writes = writes,
    _reads = readAccess,
    _writes = writeAccess,
    after = definition.after or {},
    update = definition.update,
  }
  self._systems[#self._systems + 1] = system
  self._systemByName[system.name] = system
  self._scheduleCache = nil
  return system
end

function World:schedule()
  if self._scheduleCache then return self._scheduleCache end

  local waves, waveBySystem = {}, {}
  local lastWriteWave, lastAccessWave = {}, {}
  for _, system in self._systems do
    local waveIndex = 1

    for access in pairs(system._reads) do
      if not system._writes[access] then
        local previousWave = lastWriteWave[access]
        if previousWave then waveIndex = math.max(waveIndex, previousWave + 1) end
      end
    end

    for access in pairs(system._writes) do
      local previousWave = lastAccessWave[access]
      if previousWave then waveIndex = math.max(waveIndex, previousWave + 1) end
    end

    for _, dependency in system.after do
      local previous = if type(dependency) == 'string' then self._systemByName[dependency] else dependency
      if not previous or previous.id >= system.id then
        error(`ecs: system {system.name} after-dependency must reference an earlier system`, 2)
      end
      waveIndex = math.max(waveIndex, waveBySystem[previous.id] + 1)
    end

    local wave = waves[waveIndex]
    if not wave then wave = {}; waves[waveIndex] = wave end
    wave[#wave + 1] = system
    waveBySystem[system.id] = waveIndex
    system.wave = waveIndex

    for access in pairs(system._reads) do
      local previousWave = lastAccessWave[access]
      if not previousWave or waveIndex > previousWave then lastAccessWave[access] = waveIndex end
    end

    for access in pairs(system._writes) do
      lastWriteWave[access] = waveIndex
      lastAccessWave[access] = waveIndex
    end
  end

  self._scheduleCache = waves
  return waves
end

local function runSystem(world, system, deltaTime, commands)
  local query = system.query
  if query then
    for _, archetype in query._archetypes do
      for _, chunk in archetype.chunks do
        if chunk.count > 0 then system.update(chunk, deltaTime, commands, world) end
      end
    end
  else
    system.update(nil, deltaTime, commands, world)
  end
end

function World:step(deltaTime)
  local commands = self._stepCommands
  for _, system in self._systems do runSystem(self, system, deltaTime, commands) end
  commands:flush()
end

function World:stepScheduled(deltaTime)
  local commands = self._stepCommands
  for _, wave in self:schedule() do
    for _, system in wave do runSystem(self, system, deltaTime, commands) end
  end
  commands:flush()
end

function World:clearEvents()
  for _, event in self._events do event:clear() end
end

function World:resource(name, initialValue)
  local existing = self._resourceByName[name]
  if existing then return existing end
  local resource = { id = #self._resources + 1, name = name }
  self._resources[resource.id] = initialValue
  self._resourceDefs[resource.id] = resource
  self._resourceByName[name] = resource
  return resource
end

function World:getResource(resource)
  return self._resources[resource.id]
end

function World:setResource(resource, value)
  self._resources[resource.id] = value
end

function World:query(text)
  local cached = self._queryCache[text]
  if cached then return cached end
  local ast = sql.parse(text)
  local query = if #ast.joins == 0 then Query.compile(self, text, ast) else RelationQuery.compile(self, text, ast)
  self._queryCache[text] = query
  table.insert(self._queries, query)
  return query
end

local function makeEntityProvider(world)
  local columns = { 'entity' }
  for _, component in world._components do table.insert(columns, component.name) end

  local function projectEntity(index, archetype, request)
    local out = {}
    local wanted = request.columns or columns
    for _, column in wanted do
      if column == 'entity' then
        out.entity = world:_token(index)
      else
        local component = world._componentByName[column]
        if component then out[column] = archetype.has[component.id] == true end
      end
    end
    return out
  end

  local provider = {
    columns = columns,
    indexes = { entity = true },
  }

  function provider.lookup(column, value, request)
    if column ~= 'entity' or type(value) ~= 'number' then return {} end
    local index, archetypeId = world:_location(value)
    if not index then return {} end
    return { projectEntity(index, world._archetypes[archetypeId], request) }
  end

  function provider.iterate(request)
    local required, excluded, handled = {}, {}, true
    local entityToken = nil
    for _, constraint in request.constraints or {} do
      if constraint.column == 'entity' and constraint.op == '=' and type(constraint.value) == 'number' then
        entityToken = constraint.value
      else
        local component = world._componentByName[constraint.column]
        if constraint.op ~= '=' or not component or type(constraint.value) ~= 'boolean' then
          handled = false
          break
        end

        if constraint.value then required[component.id] = true else excluded[component.id] = true end
      end
    end

    if entityToken ~= nil and handled then
      local yielded = false
      local index, archetypeId = world:_location(entityToken)
      local archetype = if archetypeId then world._archetypes[archetypeId] else nil
      if archetype then
        for componentId in pairs(required) do
          if not archetype.has[componentId] then archetype = nil; break end
        end
      end

      if archetype then
        for componentId in pairs(excluded) do
          if archetype.has[componentId] then archetype = nil; break end
        end
      end

      return {
        _jessqlIter = 'v1', volatileRows = false, handledConstraints = true,
        handledWhere = request.whereComplete == true, ordered = false,
        next = function()
          if yielded or not archetype then return nil end
          yielded = true
          return projectEntity(index, archetype, request)
        end,
      }
    end

    local archetypes = {}
    for _, archetype in world._archetypes do
      local matches = true
      if handled then
        for componentId in pairs(required) do
          if not archetype.has[componentId] then matches = false; break end
        end

        if matches then
          for componentId in pairs(excluded) do
            if archetype.has[componentId] then matches = false; break end
          end
        end
      end

      if matches then archetypes[#archetypes + 1] = archetype end
    end

    local archetypeIndex, chunkIndex, row = 1, 1, -1
    local out = {}
    return {
      _jessqlIter = 'v1',
      volatileRows = request.allowVolatileRows == true,
      handledConstraints = handled,
      handledWhere = handled and request.whereComplete == true,
      ordered = false,
      next = function()
        while archetypeIndex <= #archetypes do
          local archetype = archetypes[archetypeIndex]
          local chunk = archetype.chunks[chunkIndex]
          if chunk then
            row += 1
            if row < chunk.count then
              table.clear(out)
              local entityIndex = buffer.readu32(chunk.entityIds, row * 4)
              out.entity = world:_token(entityIndex)
              for _, column in request.columns or columns do
                if column ~= 'entity' then
                  local component = world._componentByName[column]
                  out[column] = component ~= nil and archetype.has[component.id] == true
                end
              end
              return out
            end
            chunkIndex += 1
            row = -1
          else
            archetypeIndex += 1
            chunkIndex = 1
            row = -1
          end
        end
        return nil
      end,
    }
  end

  provider.scan = function(_request) error('ecs: entity provider streams') end
  return provider
end

local function readFieldValue(world, chunk, row, field)
  local column = chunk.columns[field.id]
  local offset = row * field.width
  if field.kind == 'entity' then
    local index = buffer.readu32(column, offset)
    if index == 0 then return nil end
    local generation = buffer.readu32(column, offset + 4)
    return generation * TokenScale + index
  end
  local value = field.read(column, offset)
  return if field.kind == 'bool' then value ~= 0 else value
end

local function makeComponentProvider(world, component)
  local columns = { 'entity' }
  for _, field in component.fields do columns[#columns + 1] = field.name end

  local function project(index, chunk, row, request, out)
    out = out or {}
    table.clear(out)
    for _, columnName in request.columns or columns do
      if columnName == 'entity' then
        out.entity = world:_token(index)
      else
        local field = component[columnName]
        if field then out[columnName] = readFieldValue(world, chunk, row, field) end
      end
    end
    return out
  end

  local provider = { columns = columns, indexes = { entity = true } }

  function provider.lookup(column, value, request)
    if column ~= 'entity' or type(value) ~= 'number' then return {} end
    local index, archetypeId, chunkIndex, row = world:_location(value)
    if not index then return {} end
    local archetype = world._archetypes[archetypeId]
    if not archetype.has[component.id] then return {} end
    return { project(index, archetype.chunks[chunkIndex], row, request, nil) }
  end

  function provider.iterate(request)
    local entityToken = nil
    local handled = true
    for _, constraint in request.constraints or {} do
      if constraint.column == 'entity' and constraint.op == '=' and type(constraint.value) == 'number' then
        entityToken = constraint.value
      else
        handled = false
      end
    end

    if entityToken ~= nil and handled then
      local rows = provider.lookup('entity', entityToken, request)
      local yielded = false
      return {
        _jessqlIter = 'v1', volatileRows = false, handledConstraints = true,
        handledWhere = request.whereComplete == true, ordered = false,
        next = function()
          if yielded then return nil end
          yielded = true
          return rows[1]
        end,
      }
    end

    local archetypes = {}
    for _, archetype in world._archetypes do
      if archetype.has[component.id] then archetypes[#archetypes + 1] = archetype end
    end
    local archetypeIndex, chunkIndex, row = 1, 1, -1
    local reusable = {}
    local volatileRows = request.allowVolatileRows == true

    return {
      _jessqlIter = 'v1', volatileRows = volatileRows, handledConstraints = false,
      handledWhere = false, ordered = false,
      next = function()
        while archetypeIndex <= #archetypes do
          local archetype = archetypes[archetypeIndex]
          local chunk = archetype.chunks[chunkIndex]
          if chunk then
            row += 1
            if row < chunk.count then
              local index = buffer.readu32(chunk.entityIds, row * 4)
              return project(index, chunk, row, request, if volatileRows then reusable else nil)
            end
            chunkIndex += 1
            row = -1
          else
            archetypeIndex += 1
            chunkIndex = 1
            row = -1
          end
        end
        return nil
      end,
    }
  end

  provider.scan = function(_request) error('ecs: component provider streams') end
  return provider
end

local function makeRelationProvider(world)
  local function selectedStores(request)
    local relationName = nil
    for _, constraint in request.constraints or {} do
      if constraint.column == 'relation' and constraint.op == '=' and type(constraint.value) == 'string' then
        relationName = constraint.value
        break
      end
    end

    if relationName then
      local definition = world._relationByName[relationName]
      return if definition then { world._relationStores[definition.id] } else {}
    end
    local stores = {}
    for _, store in world._relationStores do stores[#stores + 1] = store end
    return stores
  end

  local provider = {
    columns = { 'relation', 'source', 'target' },
    indexes = { source = true, target = true },
  }

  function provider.lookup(column, value, request)
    if (column ~= 'source' and column ~= 'target') or type(value) ~= 'number' then return {} end
    local entityIndex = world:_location(value)
    if not entityIndex then return {} end
    local rows = {}
    local limit = request.limitHint

    for _, store in selectedStores(request) do
      if column == 'source' then
        for targetIndex in store:targets(entityIndex) do
          rows[#rows + 1] = {
            relation = store.definition.name,
            source = value,
            target = world:_token(targetIndex),
          }

          if limit ~= nil and #rows >= limit then return rows end
        end
      else
        for sourceIndex in store:sources(entityIndex) do
          rows[#rows + 1] = {
            relation = store.definition.name,
            source = world:_token(sourceIndex),
            target = value,
          }

          if limit ~= nil and #rows >= limit then return rows end
        end
      end
    end
    return rows
  end

  function provider.iterate(request)
    local stores = selectedStores(request)
    local handled = true
    local sourceToken, targetToken = nil, nil
    for _, constraint in request.constraints or {} do
      if constraint.op ~= '=' then
        handled = false
      elseif constraint.column == 'relation' and type(constraint.value) == 'string' then
        -- selectedStores already consumed it.
      elseif constraint.column == 'source' and type(constraint.value) == 'number' then
        sourceToken = constraint.value
      elseif constraint.column == 'target' and type(constraint.value) == 'number' then
        targetToken = constraint.value
      else
        handled = false
      end
    end

    local sourceIndex = if sourceToken ~= nil then world:_location(sourceToken) else nil
    local targetIndex = if targetToken ~= nil then world:_location(targetToken) else nil
    local impossible = (sourceToken ~= nil and sourceIndex == nil) or (targetToken ~= nil and targetIndex == nil)

    local storeIndex = 0
    local iterator = nil
    local function nextStore()
      storeIndex += 1
      local store = stores[storeIndex]
      if not store then iterator = nil; return end

      if sourceIndex and targetIndex then
        local yielded = false
        iterator = function()
          if yielded then return nil end
          yielded = true
          if store:has(sourceIndex, targetIndex) then return sourceIndex, targetIndex end
          return nil
        end
      elseif sourceIndex then
        local targets = store:targets(sourceIndex)
        iterator = function()
          local target = targets()
          if target then return sourceIndex, target end
          return nil
        end
      elseif targetIndex then
        local sources = store:sources(targetIndex)
        iterator = function()
          local source = sources()
          if source then return source, targetIndex end
          return nil
        end
      else
        iterator = store:iterate()
      end
    end

    if not impossible then nextStore() end
    local out = {}
    return {
      _jessqlIter = 'v1',
      volatileRows = request.allowVolatileRows == true,
      handledConstraints = handled,
      handledWhere = handled and request.whereComplete == true,
      ordered = false,
      next = function()
        while iterator do
          local sourceIndexValue, targetIndexValue = iterator()
          if sourceIndexValue then
            table.clear(out)
            out.relation = stores[storeIndex].definition.name
            out.source = world:_token(sourceIndexValue)
            out.target = world:_token(targetIndexValue)
            return out
          end
          nextStore()
        end
        return nil
      end,
    }
  end

  provider.scan = function(_request) error('ecs: relation provider streams') end
  return provider
end

function World:sql()
  local db = sql.new()
  db:register('entities', makeEntityProvider(self))
  db:register('relations', makeRelationProvider(self))
  for _, component in self._components do db:register(component.name, makeComponentProvider(self, component)) end
  for _, store in self._events do db:register(store.name, store:provider(self)) end

  local archetypeRows = {}
  for _, archetype in self._archetypes do
    archetypeRows[#archetypeRows + 1] = {
      id = archetype.id,
      entities = archetype.count,
      chunks = #archetype.chunks,
      signature = archetype.key,
    }
  end
  db:table('archetypes', archetypeRows, { 'id', 'entities', 'chunks', 'signature' })

  local componentRows, fieldRows = {}, {}
  for _, component in self._components do
    componentRows[#componentRows + 1] = {
      id = component.id, name = component.name, tag = component.tag, fields = #component.fields,
    }

    for _, field in component.fields do
      fieldRows[#fieldRows + 1] = {
        id = field.id, component = component.name, name = field.name, kind = field.kind, width = field.width,
      }
    end
  end
  db:table('components', componentRows, { 'id', 'name', 'tag', 'fields' })
  db:table('fields', fieldRows, { 'id', 'component', 'name', 'kind', 'width' })

  local eventRows = {}
  for _, event in self._events do
    eventRows[#eventRows + 1] = {
      id = event.id,
      name = event.name,
      rows = event.count,
      fields = #event.fields,
      bytes = event:bytes(),
    }
  end
  db:table('events', eventRows, { 'id', 'name', 'rows', 'fields', 'bytes' })

  local resourceRows = {}
  for _, resource in self._resourceDefs do
    resourceRows[#resourceRows + 1] = { id = resource.id, name = resource.name }
  end
  db:table('resources', resourceRows, { 'id', 'name' })

  local systemRows = {}
  if #self._systems > 0 then self:schedule() end

  for _, system in self._systems do
    local readCount, writeCount = 0, 0
    for _ in pairs(system._reads) do readCount += 1 end
    for _ in pairs(system._writes) do writeCount += 1 end

    systemRows[#systemRows + 1] = {
      id = system.id,
      name = system.name,
      query = if system.query then system.query.sql else nil,
      wave = system.wave,
      reads = readCount,
      writes = writeCount,
    }
  end
  db:table('systems', systemRows, { 'id', 'name', 'query', 'wave', 'reads', 'writes' })
  return db
end

function World:stats()
  local entityPages = 0
  for _ in pairs(self._entityPages) do entityPages += 1 end
  local entityBytes = entityPages * EntityPageSize * EntityStride

  local chunkBytes, chunkCount = 0, 0
  for _, archetype in self._archetypes do
    for _, chunk in archetype.chunks do
      chunkCount += 1
      chunkBytes += buffer.len(chunk.entityIds)
      for _, column in pairs(chunk.columns) do chunkBytes += buffer.len(column) end
    end
  end

  local relationBytes = 0
  for _, store in self._relationStores do relationBytes += store:bytes() end
  local eventBytes = 0
  for _, store in self._events do eventBytes += store:bytes() end

  return {
    entities = self.count,
    archetypes = #self._archetypes,
    chunks = chunkCount,
    entityBytes = entityBytes,
    chunkBytes = chunkBytes,
    relationBytes = relationBytes,
    eventBytes = eventBytes,
    packedBytes = entityBytes + chunkBytes + relationBytes + eventBytes,
  }
end

function World:commands()
  return CommandBuffer.new(self)
end

local function new(options)
  options = options or {}
  local chunkCapacity = options.chunkCapacity or DefaultChunkCapacity
  if chunkCapacity < 1 or chunkCapacity > 65535 then error('ecs: chunkCapacity must be 1..65535', 2) end

  local self = setmetatable({
    chunkCapacity = chunkCapacity,
    count = 0,
    _components = {},
    _componentByName = {},
    _nextField = 1,
    _archetypes = {},
    _archetypeByKey = {},
    _queries = {},
    _queryCache = {},
    _entityPages = {},
    _free = {},
    _nextEntity = 0,
    _relations = {},
    _relationByName = {},
    _relationStores = {},
    _eventDefs = {},
    _events = {},
    _eventByName = {},
    _systems = {},
    _systemByName = {},
    _scheduleCache = nil,
    _resources = {},
    _resourceDefs = {},
    _resourceByName = {},
  }, World)
  self:_archetype({})
  self._stepCommands = self:commands()
  return self
end

return {
  new = new,
}
