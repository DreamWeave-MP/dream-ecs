--!strict
--!native

local EventStore = {}
EventStore.__index = EventStore

local DefaultBlockCapacity = 1024
local TokenScale = 4294967296

local FieldTypes = {
  u8 = { width = 1, read = buffer.readu8, write = buffer.writeu8 },
  u16 = { width = 2, read = buffer.readu16, write = buffer.writeu16 },
  u32 = { width = 4, read = buffer.readu32, write = buffer.writeu32 },
  i32 = { width = 4, read = buffer.readi32, write = buffer.writei32 },
  f32 = { width = 4, read = buffer.readf32, write = buffer.writef32 },
  f64 = { width = 8, read = buffer.readf64, write = buffer.writef64 },
  bool = { width = 1, read = buffer.readu8, write = buffer.writeu8 },
  entity = { width = 6 },
}

local EventChunk = {}
EventChunk.__index = EventChunk

function EventChunk:buffer(field)
  local value = self.columns[field.id]
  if not value then error(`ecs: event field {field.event.name}.{field.name} is not in this chunk`, 2) end
  return value
end

local function decodeToken(token)
  local generation = math.floor(token / TokenScale)
  return token - generation * TokenScale, generation
end

local function newChunk(store: { fields: { { width: number } }, blockCapacity: number })
  -- A field's id is its place in the list, so the columns are the list mapped.
  local columns = [for field in store.fields => buffer.create(store.blockCapacity * field.width)]
  return setmetatable({ count = 0, capacity = store.blockCapacity, columns = columns }, EventChunk)
end

local function chunkForEmit(store)
  local chunk = store._chunks[#store._chunks]
  if chunk and chunk.count < chunk.capacity then return chunk end
  chunk = newChunk(store)
  store._chunks[#store._chunks + 1] = chunk
  return chunk
end

local function writeField(field, column, row, value)
  if value == nil then value = field.default or 0 end
  local offset = row * field.width
  if field.kind == 'bool' then value = if value then 1 else 0 end

  if field.kind == 'entity' then
    local index, generation
    if value == 0 or value == nil then
      index, generation = 0, 0
    else
      index, generation = decodeToken(value)
    end
    buffer.writeu32(column, offset, index)
    buffer.writeu16(column, offset + 4, generation)
  else
    field.write(column, offset, value)
  end
end

function EventStore:emit(values)
  values = values or {}
  local chunk = chunkForEmit(self)
  local row = chunk.count
  for _, field in self.fields do writeField(field, chunk.columns[field.id], row, values[field.name]) end
  chunk.count += 1
  self.count += 1
  return row
end

function EventStore:reserve(count)
  if count < 0 or count % 1 ~= 0 then error('ecs: event reserve count must be a non-negative integer', 2) end
  local remaining = count
  self.count += count

  return function()
    if remaining == 0 then return nil end
    local chunk = chunkForEmit(self)
    local startRow = chunk.count
    local take = math.min(remaining, chunk.capacity - startRow)
    chunk.count += take
    remaining -= take
    return chunk, startRow, take
  end
end

function EventStore:clear()
  for _, chunk in self._chunks do chunk.count = 0 end
  self.count = 0
end

function EventStore:chunks()
  local chunks = self._chunks
  local index = 0
  return function()
    while true do
      index += 1
      local chunk = chunks[index]
      if not chunk then return nil end
      if chunk.count > 0 then return chunk end
    end
  end
end

function EventStore:bytes()
  local rowWidth = sum[for field in self.fields => field.width]
  return #self._chunks * self.blockCapacity * rowWidth
end

function EventStore:provider(world)
  local columns = [for field in self.fields => field.name]

  return {
    columns = columns,
    iterate = function(request)
      local selected = request.columns or columns
      local chunkIndex, row = 1, -1
      local out = {}
      return {
        _jessqlIter = 'v1',
        volatileRows = request.allowVolatileRows == true,
        handledConstraints = false,
        handledWhere = false,
        ordered = false,
        next = function()
          while chunkIndex <= #self._chunks do
            local chunk = self._chunks[chunkIndex]
            row += 1
            if row < chunk.count then
              table.clear(out)
              for _, name in selected do
                local field = self._fieldByName[name]
                if not field then continue end

                local column = chunk.columns[field.id]
                local offset = row * field.width
                if field.kind == 'entity' then
                  local index = buffer.readu32(column, offset)
                  if index ~= 0 then
                    local generation = buffer.readu16(column, offset + 4)
                    out[name] = generation * TokenScale + index
                  end
                else
                  local value = field.read(column, offset)
                  out[name] = if field.kind == 'bool' then value ~= 0 else value
                end
              end
              return out
            end
            chunkIndex += 1
            row = -1
          end
          return nil
        end,
      }
    end,
    scan = function(_request) error('ecs: event provider streams') end,
  }
end

local function new(definition, schema, options)
  options = options or {}
  local blockCapacity = options.blockCapacity or DefaultBlockCapacity
  if blockCapacity < 1 or blockCapacity > 65535 then error('ecs: event blockCapacity must be 1..65535', 3) end

  local self = setmetatable({
    id = definition.id,
    name = definition.name,
    fields = {},
    count = 0,
    blockCapacity = blockCapacity,
    _chunks = {},
    _fieldByName = {},
  }, EventStore)

  local names = {}
  for name in pairs(schema or {}) do names[#names + 1] = name end
  table.sort(names)
  for fieldIndex, name in names do
    if not string.match(name, '^[A-Za-z_][A-Za-z0-9_]*$') then
      error(`ecs: event field {name} must be a SQL-safe identifier`, 3)
    end
    local declaration = schema[name]
    local kind, default
    if type(declaration) == 'string' then kind = declaration else kind, default = declaration.type, declaration.default end
    local fieldType = FieldTypes[kind]
    if not fieldType then error(`ecs: unsupported event field type {tostring(kind)}`, 3) end

    local field = {
      id = fieldIndex,
      name = name,
      kind = kind,
      width = fieldType.width,
      read = fieldType.read,
      write = fieldType.write,
      default = default,
      event = self,
    }
    self.fields[#self.fields + 1] = field
    self._fieldByName[name] = field
    self[name] = field
  end
  return self
end

return {
  new = new,
}
