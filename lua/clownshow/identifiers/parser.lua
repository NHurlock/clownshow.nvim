local Object = require("clownshow.object")
local utils = require("clownshow.utils")
local identifier_utils = require("clownshow.identifiers.utils")

---@class ClownshowIdentifierParser
---@field _bufnr number
---@field _file_type string
---@field _parser vim.treesitter.LanguageTree
---@field _root_has_only boolean
---@field _curr_parent? number
---@field _holding? number
---@field _each table<ClownshowIdentifierType, ClownshowIdentifierProps>
---@field identifier_info table<number, ClownshowIdentifierProps>
---@overload fun(bufnr: number): ClownshowIdentifierParser
local Parser = Object("ClownshowIdentifierParser")

-- creates a parser for the buffer
---@param bufnr number buffer to create parser for
function Parser:init(bufnr)
  self._bufnr = bufnr
  self._file_type = utils.get_filetype(bufnr)
  self._parser = vim.treesitter.get_parser(bufnr, self._file_type, {})
end

-- a test marked as "only" in jest will force skip all other non-only tests
-- each time one is found, identify parents that contain an "only" using "has_only"
function Parser:_set_only()
  self._root_has_only = true
  local parent = self.identifier_info[self._curr_parent]
  while parent and not parent.has_only do
    parent.has_only = true
    parent = self.identifier_info[parent.parent]
  end
end

-- attempts to add a new identifier
---@param identifier ClownshowIdentifierProps properties used to create new identifier
function Parser:_add_identifier(identifier)
  local ref = self.identifier_info[identifier.line]
  if identifier.type ~= "root" and self._each["root"] then
    -- when "root" is an "each" (tables) in jest, we need to wait for the root's arguments before applying parent logic to children
    -- otherwise, the parent's line number reference may be invalid
    -- set holding for processing later
    self._holding = identifier.line
  elseif not ref then
    -- if the parent is skipped or the root contains an "only" and it doesn't include the current identifier
    -- mark the current identifier as skipped
    if self._curr_parent and (self.identifier_info[self._curr_parent].status == "pending" or (not identifier.only and self._root_has_only)) then
      identifier.status = "pending"
    end

    if identifier.only then
      self:_set_only()
    end

    -- apply parent-level information
    identifier.has_only = false
    identifier.parent = self._curr_parent
    self.identifier_info[identifier.line] = identifier
  elseif self._curr_parent and not ref.parent then
    ref.parent = self._curr_parent
  end

  -- root elements will contain children, set curr_parent for next identifiers to mark them as children to this identifier
  if identifier.type == "root" and not self._curr_parent then
    self._curr_parent = identifier.line
  end
end

-- handle identifier tables
---@param identifier ClownshowIdentifierProps properties to create new table identifier
---@param curr_each? ClownshowIdentifierProps the original "each" of the same table identifier (starting info)
function Parser:_add_each(identifier, curr_each)
  if self.identifier_info[identifier.line] then
    self.identifier_info[identifier.line].endline = identifier.endline
  end
  if not curr_each then return end

  -- reset "each" for next table identifier now that this one has completed
  self._each[curr_each.type] = nil

  -- "identifier" will not contain accurate type, only, and status info
  -- "curr_each" will have the correct line and col info, set "above" to the "each" location
  identifier.type = curr_each.type
  identifier.endline = curr_each.endline
  identifier.only = curr_each.only
  identifier.status = curr_each.status
  identifier.above = { line = curr_each.line, col = curr_each.col }
  self:_add_identifier(identifier)
end

-- identifier table found, need to wait for the "bottom" of the table, hold
---@param identifier ClownshowIdentifierProps properties to create new table identifier
function Parser:_set_each(identifier)
  self._each[identifier.type] = identifier
end

-- re-parse the buffer and re-create identifiers
function Parser:_refresh()
  self.identifier_info = {}
  self._root_has_only = false
  local root = self._parser:parse()[1]:root()
  local query = identifier_utils.get_filetype_query(self._file_type)

  -- each match will go in the order of:
  --    root? (describe)
  --      child (inner describe/test)
  --      inner_args
  --    args?
  --
  -- if "root" exists, it will always be the parent of "child"
  -- "inner_args" will always exist, only used when "child" is an "each" (tables)
  -- "args" will only exist if "root" exists, only used when "root" is an "each"
  for _, match, _ in query:iter_matches(root, self._bufnr, 0, -1) do
    self._curr_parent = nil
    self._holding = nil
    self._each = {}

    for id, nodes in pairs(match) do
      local name = query.captures[id]
      -- backwards compatibility
      if not vim.islist(nodes) then
        nodes = { nodes }
      end
      for _, node in ipairs(nodes) do
        local range = { node:range() }
        ---@type ClownshowIdentifierProps
        local identifier = {
          type = identifier_utils.get_type(name),
          line = range[1],
          col = range[2],
          endline = range[3],
          status = identifier_utils.get_initial_status(name),
          only = string.match(name, "only") ~= nil
        }

        if string.match(name, "each") then
          self:_set_each(identifier)
        elseif not string.match(name, "args") then
          self:_add_identifier(identifier)
        elseif name == "inner_args" then
          self:_add_each(identifier, self._each["test"] or self._each["describe"])
        elseif name == "args" then
          self:_add_each(identifier, self._each["root"])
        end
      end
    end

    -- "holding" will only be set when "root" is an "each" and a child was found
    if self._holding then
      self:_add_identifier(self.identifier_info[self._holding])
    end
  end

  -- reprocess all identifiers to account for any "only" states that were missed due to node order
  for _, identifier in pairs(self.identifier_info) do
    local parent = self.identifier_info[identifier.parent]
    local parent_not_only = not parent or (parent and not parent.only)
    if self._root_has_only and parent_not_only and not identifier.has_only and not identifier.only and identifier.status ~= "pending" then
      identifier.status = "pending"
    end
  end
end

-- refresh the state and get the parsed identifiers
---@return ClownshowIdentifierProps[] identifiers parsed identifiers
function Parser:get_identifiers()
  self:_refresh()
  return vim.tbl_values(self.identifier_info)
end

-- clear parser state
function Parser:reset()
  self._root_has_only = false
  self._curr_parent = nil
  self._holding = nil
  self._each = {}
  self.identifier_info = {}
end

return Parser
