--!strict
--!native

local sql = require('@jessql')

local RelationQuery = {}
RelationQuery.__index = RelationQuery

local function columnMatches(expr, alias, name)
  return expr and expr.tag == 'column' and expr.name == name
    and (expr.qualifier == nil or expr.qualifier == alias)
end

local function equalitySides(expr)
  if not expr or expr.tag ~= 'binary' or expr.op ~= '=' then return nil end
  return expr.left, expr.right
end

local function flattenAnd(expr, out)
  if expr and expr.tag == 'binary' and expr.op == 'AND' then
    flattenAnd(expr.left, out)
    flattenAnd(expr.right, out)
  elseif expr then
    out[#out + 1] = expr
  end
end

local function sourceAlias(source)
  return source.alias or source.name
end

local function classifySources(ast)
  if #ast.joins ~= 1 or ast.joins[1].kind ~= 'inner' then
    error('ecs: hot relation queries require exactly one INNER JOIN', 3)
  end

  local first = ast.from
  local second = ast.joins[1].source
  local entitySource, relationSource
  if first.name == 'entities' and second.name == 'relations' then
    entitySource, relationSource = first, second
  elseif first.name == 'relations' and second.name == 'entities' then
    entitySource, relationSource = second, first
  else
    error('ecs: hot relation queries must join entities and relations', 3)
  end
  return sourceAlias(entitySource), sourceAlias(relationSource)
end

local function classifyJoin(ast, entityAlias, relationAlias)
  local left, right = equalitySides(ast.joins[1].on)
  if not left then error('ecs: hot relation JOIN must be an equality', 3) end

  local relationColumn, entityColumn
  if left.tag == 'column' and left.qualifier == relationAlias then relationColumn, entityColumn = left, right
  elseif right.tag == 'column' and right.qualifier == relationAlias then relationColumn, entityColumn = right, left end

  if not relationColumn or not columnMatches(entityColumn, entityAlias, 'entity') then
    error('ecs: hot relation JOIN must connect relations.source/target to entities.entity', 3)
  end

  if relationColumn.name ~= 'source' and relationColumn.name ~= 'target' then
    error('ecs: hot relation JOIN endpoint must be source or target', 3)
  end
  return relationColumn.name
end

local function boolLiteral(expr)
  if expr and expr.tag == 'literal' and type(expr.value) == 'boolean' then return true, expr.value end
  return false, nil
end

local function boundValue(expr)
  if not expr then return nil end
  if expr.tag == 'param' then return { param = expr.index } end
  if expr.tag == 'literal' and type(expr.value) == 'number' then return { value = expr.value } end
  return nil
end

local function compile(world, text, parsed)
  local ast = parsed or sql.parse(text)
  if ast.tag ~= 'select' then error('ecs: hot relation query must be SELECT', 3) end

  if #ast.groupBy ~= 0 or #ast.orderBy ~= 0 or ast.limit ~= nil or ast.offset ~= 0 then
    error('ecs: GROUP/ORDER/LIMIT/OFFSET belong to world:sql(), not hot relation queries', 3)
  end

  local entityAlias, relationAlias = classifySources(ast)
  local joinedEndpoint = classifyJoin(ast, entityAlias, relationAlias)
  local boundEndpoint = if joinedEndpoint == 'source' then 'target' else 'source'
  local all, none, selected = {}, {}, {}
  local relationName, bound = nil, nil

  for _, item in ast.select do
    local expr = item.expr
    if columnMatches(expr, entityAlias, 'entity') then continue end

    if expr.tag ~= 'column' or (expr.qualifier ~= nil and expr.qualifier ~= entityAlias) then
      error('ecs: hot relation SELECT accepts only entity/component columns', 3)
    end
    local component = world._componentByName[expr.name]
    if not component then error(`ecs: unknown component {expr.name}`, 3) end
    all[component.id] = true
    selected[#selected + 1] = component
  end

  local predicates = {}
  flattenAnd(ast.where, predicates)
  for _, predicate in predicates do
    local left, right = equalitySides(predicate)
    if not left then error('ecs: hot relation WHERE supports equality predicates joined by AND', 3) end
    if left.tag ~= 'column' and right.tag == 'column' then left, right = right, left end
    if left.tag ~= 'column' then error('ecs: hot relation WHERE requires a column equality', 3) end

    if left.qualifier == relationAlias or (left.qualifier == nil and (left.name == 'relation' or left.name == boundEndpoint)) then
      if left.name == 'relation' and right.tag == 'literal' and type(right.value) == 'string' then
        relationName = right.value
      elseif left.name == boundEndpoint then
        bound = boundValue(right)
        if not bound then error('ecs: relation endpoint must be a numeric entity literal or ? parameter', 3) end
      else
        error(`ecs: unsupported relation predicate {left.name}`, 3)
      end
    elseif left.qualifier == entityAlias or left.qualifier == nil then
      local component = world._componentByName[left.name]
      local ok, value = boolLiteral(right)
      if not component or not ok then
        error('ecs: entity predicates in hot relation queries must be Component = TRUE/FALSE', 3)
      end

      if value then all[component.id] = true else none[component.id] = true end
    else
      error('ecs: unsupported qualified predicate in hot relation query', 3)
    end
  end

  if not relationName then error('ecs: hot relation query requires relations.relation = \'Name\'', 3) end
  if not bound then error(`ecs: hot relation query requires relations.{boundEndpoint} = ?`, 3) end
  local definition = world._relationByName[relationName]
  if not definition then error(`ecs: unknown relation {relationName}`, 3) end

  local self = setmetatable({
    _world = world,
    _relation = definition,
    _joinedEndpoint = joinedEndpoint,
    _boundEndpoint = boundEndpoint,
    _bound = bound,
    _all = all,
    _none = none,
    _matching = {},
    selected = selected,
    sql = text,
    kind = 'relation',
    params = ast.params,
  }, RelationQuery)
  return self
end

local function matches(archetype, all, none)
  for componentId in pairs(all) do if not archetype.has[componentId] then return false end end
  for componentId in pairs(none) do if archetype.has[componentId] then return false end end
  return true
end

function RelationQuery:_boundToken(params)
  if self._bound.param then
    params = params or {}
    local value = params[self._bound.param]
    if type(value) ~= 'number' then error(`ecs: hot relation query expects numeric parameter {self._bound.param}`, 3) end
    return value
  end
  return self._bound.value
end

function RelationQuery:rows(params)
  local world = self._world
  local boundToken = self:_boundToken(params)
  local boundIndex = world:_location(boundToken)
  if not boundIndex then return function() return nil end end
  local store = world._relationStores[self._relation.id]
  local iterator = if self._joinedEndpoint == 'source' then store:sources(boundIndex) else store:targets(boundIndex)
  local all, none = self._all, self._none
  -- An archetype's components never change, so whether it satisfies the query is decided once
  -- and remembered by its id.
  local matching: { [number]: boolean } = self._matching

  return function()
    while true do
      local index = iterator()
      if not index then return nil end
      local generation, archetypeId, chunkIndex, row = world:_locationIndex(index)
      if archetypeId then
        local archetype = world._archetypes[archetypeId]
        local matched = matching[archetypeId]
        if matched == nil then
          matched = matches(archetype, all, none)
          matching[archetypeId] = matched
        end

        if matched then return generation * 4294967296 + index, archetype.chunks[chunkIndex], row end
      end
    end
  end
end

function RelationQuery:count(params)
  local count = 0
  for _entity in self:rows(params) do count += 1 end
  return count
end

function RelationQuery:explain()
  local required, excluded = {}, {}
  for componentId in pairs(self._all) do required[#required + 1] = self._world._components[componentId].name end
  for componentId in pairs(self._none) do excluded[#excluded + 1] = self._world._components[componentId].name end
  table.sort(required)
  table.sort(excluded)
  return {
    kind = 'relation-index', sql = self.sql, relation = self._relation.name,
    joinedEndpoint = self._joinedEndpoint, boundEndpoint = self._boundEndpoint,
    required = required, excluded = excluded, parameter = self._bound.param,
  }
end

function RelationQuery:_consider(_archetype)
  -- Membership is driven by a relation posting list, not by a cached whole-archetype set.
end

return {
  compile = compile,
}
