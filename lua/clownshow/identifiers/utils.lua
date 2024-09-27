local utils = require("clownshow.utils")

local M = {}

---@type table<string, vim.treesitter.Query>
local _queries = {}
---@type fun(): string
local function _jest_query()
  ---@type string
  local cached
  if not cached then
    local _, query = pcall(function()
      local jest_queries = {}
      local jest_query_files = vim.api.nvim_get_runtime_file("queries/clownshow/*.scm", true)
      for _, jest_query_file in ipairs(jest_query_files) do
        jest_queries[vim.fn.fnamemodify(jest_query_file, ":t:r")] = utils.get_file(jest_query_file)
      end
      return jest_queries["jest"]
          :gsub("TEST_EXPRESSION", jest_queries["test_expression"])
          :gsub("OUTER_TEST", jest_queries["outer_test"])
          :gsub("INNER_TEST", jest_queries["inner_test"])
    end)
    cached = query
  end
  return cached
end

-- "test" would be any test
-- "describe" would be any inner/nested describe block
-- "root" would be any outer/non-nested describe block
---@param name string node name
---@return ClownshowIdentifierType type identifier type
function M.get_type(name)
  if string.match(name, "^test") then
    return "test"
  elseif string.match(name, "^idescribe") then
    return "describe"
  else
    return "root"
  end
end

-- initial "loading" state always set unless test is skipped
-- skipped tests in jest are marked as "pending"
---@param name string node name
---@return ClownshowIdentifierStatus status initial identifier status
function M.get_initial_status(name)
  if string.match(name, "skip") then
    return "pending"
  else
    return "loading"
  end
end

-- generate query for given filetype if one does not already exist
-- only need to do this once
---@param filetype string file type
---@return vim.treesitter.Query query treesitter query for the filetype
function M.get_filetype_query(filetype)
  if not _queries[filetype] then
    _queries[filetype] = vim.treesitter.query.parse(filetype, _jest_query())
  end
  return _queries[filetype]
end

return M
