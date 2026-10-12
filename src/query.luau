--!strict
--!native

local sql = require('@jessql')

local Query = {}
Query.__index = Query

local function componentFromColumn(world, column)
  local name = column.name
  if name == 'entity' then return nil end
  local component = world._componentByName[name]
  if not component then error(`ecs: unknown component {name}`, 3) end
  return component
end

local function collectPredicate(world, expr, all, none)
  if not expr then return end

  if expr.tag == 'binary' and expr.op == 'AND' then
    collectPredicate(world, expr.left, all, none)
    collectPredicate(world, expr.right, all, none)
    return
  end

  if expr.tag ~= 'binary' or expr.op ~= '=' then
    error('ecs: hot query WHERE supports only Component = TRUE/FALSE joined by AND', 3)
  end

  local column, literal = expr.left, expr.right
  if column.tag ~= 'column' or literal.tag ~= 'literal' or type(literal.value) ~= 'boolean' then
    error('ecs: hot query predicates must be Component = TRUE/FALSE', 3)
  end

  local component = componentFromColumn(world, column)
  if not component then error('ecs: entity cannot be used as a presence predicate', 3) end
  if literal.value then all[component.id] = true else none[component.id] = true end
end

local function matches(archetype, all, none)
  for componentId in pairs(all) do
    if not archetype.has[componentId] then return false end
  end

  for componentId in pairs(none) do
    if archetype.has[componentId] then return false end
  end
  return true
end

function Query:_consider(archetype)
  if matches(archetype, self._all, self._none) then
    table.insert(self._archetypes, archetype)
  end
end

function Query:chunks()
  local archetypes = self._archetypes
  local archetypeIndex, chunkIndex = 1, 0

  return function()
    while archetypeIndex <= #archetypes do
      local chunks = archetypes[archetypeIndex].chunks
      chunkIndex += 1
      if chunkIndex <= #chunks then
        local chunk = chunks[chunkIndex]
        if chunk.count > 0 then return chunk end
      else
        archetypeIndex += 1
        chunkIndex = 0
      end
    end
    return nil
  end
end

function Query:count()
  local count = 0
  for _, archetype in self._archetypes do
    count += archetype.count
  end
  return count
end

function Query:explain()
  local required, excluded, archetypes = {}, {}, {}
  for componentId in pairs(self._all) do table.insert(required, self._world._components[componentId].name) end
  for componentId in pairs(self._none) do table.insert(excluded, self._world._components[componentId].name) end
  for _, archetype in self._archetypes do table.insert(archetypes, archetype.id) end
  table.sort(required)
  table.sort(excluded)
  return {
    sql = self.sql,
    required = required,
    excluded = excluded,
    archetypes = archetypes,
    selected = self.selected,
  }
end

local function compile(world, text, parsed)
  local ast = parsed or sql.parse(text)
  if ast.tag ~= 'select' or ast.from.name ~= 'entities' or #ast.joins ~= 0 then
    error('ecs: hot queries must SELECT FROM entities without joins', 3)
  end

  if #ast.groupBy ~= 0 or #ast.orderBy ~= 0 or ast.limit ~= nil or ast.offset ~= 0 then
    error('ecs: GROUP/ORDER/LIMIT/OFFSET belong to world:sql(), not hot ECS queries', 3)
  end

  local all, none, selected = {}, {}, {}
  for _, item in ast.select do
    local expr = item.expr
    if expr.tag ~= 'column' then error('ecs: hot query SELECT accepts only entity/component columns', 3) end

    if expr.name ~= 'entity' then
      local component = componentFromColumn(world, expr)
      all[component.id] = true
      table.insert(selected, component)
    end
  end
  collectPredicate(world, ast.where, all, none)

  local self = setmetatable({
    _world = world,
    _all = all,
    _none = none,
    _archetypes = {},
    selected = selected,
    sql = text,
  }, Query)

  for _, archetype in world._archetypes do self:_consider(archetype) end
  return self
end

return {
  compile = compile,
}
