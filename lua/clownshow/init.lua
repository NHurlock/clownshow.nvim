local ts_utils = require("nvim-treesitter.ts_utils")
local utils = require("clownshow.utils")

---@alias ClownshowIdentifierType "test"|"describe"|"root"

---@alias ClownshowIdentifierStatus "pending"|"loading"|"passed"|"failed"

---@class ClownshowIdentifier
---@field line number
---@field col number
---@field endline? number
---@field type? ClownshowIdentifierType
---@field only? boolean
---@field status? ClownshowIdentifierStatus
---@field mark? number
---@field has_only? boolean
---@field parent? number
---@field above? ClownshowIdentifier

---@class ClownshowState
---@field init? boolean
---@field job? number
---@field autocmd number[]
---@field diagnostics Diagnostic[]
---@field identifiers ClownshowIdentifier[]

---@class ClownshowJestAssertion
---@field status ClownshowIdentifierStatus
---@field location { line: number }
---@field failureMessages string[]

---@class ClownshowJestResult
---@field message string
---@field assertionResults ClownshowJestAssertion[]

local M = {}

local _config = require("clownshow.defaults")
local _source = "clownshow"
local _ns = vim.api.nvim_create_namespace(_source)
local _group = vim.api.nvim_create_augroup(_source, { clear = true })
---@type table<string, Query>
local _queries = {}
---@type table<number, ClownshowState>
local _active = {}
---@type string|nil
local _jest_query
local _jest_args = { "--watch", "--silent", "--forceExit", "--json", "--testLocationInResults", "--no-colors",
  "--coverage=false" }

local function set_jest_query()
  local jest_queries = {}
  local jest_query_files = vim.api.nvim_get_runtime_file("queries/clownshow/*.scm", true)
  for _, jest_query_file in ipairs(jest_query_files) do
    jest_queries[vim.fn.fnamemodify(jest_query_file, ":t:r")] = utils.get_file(jest_query_file)
  end
  _jest_query = jest_queries["jest"]
      :gsub("TEST_EXPRESSION", jest_queries["test_expression"])
      :gsub("OUTER_TEST", jest_queries["outer_test"])
      :gsub("INNER_TEST", jest_queries["inner_test"])
end

---@param bufnr number
---@return ClownshowState|nil
local function get_state(bufnr)
  return _active[bufnr]
end

---@param bufnr number
---@param state ClownshowState
---@return ClownshowState|nil
local function set_state(bufnr, state)
  _active[bufnr] = state
  return get_state(bufnr)
end

-- generate query for given filetype if one does not already exist
-- only need to do this once
---@param filetype string
---@return Query
local function get_filetype_query(filetype)
  if not _queries[filetype] then
    _queries[filetype] = vim.treesitter.query.parse(filetype, _jest_query)
  end
  return _queries[filetype]
end

---@type fun(bufnr: number): table<number, ClownshowIdentifier>
local get_identifiers = ts_utils.memoize_by_buf_tick(function(bufnr)
  local filetype = utils.get_filetype(bufnr)
  local parser = vim.treesitter.get_parser(bufnr, filetype, {})
  local root = parser:parse()[1]:root()
  local query = get_filetype_query(filetype)
  ---@type table<number, ClownshowIdentifier>
  local identifier_info = {}
  local root_has_only = false
  ---@type number|nil
  local curr_parent
  ---@type ClownshowIdentifier|nil
  local holding
  ---@type table<ClownshowIdentifierType, ClownshowIdentifier>
  local each = {}

  -- "test" would be any test
  -- "describe" would be any inner/nested describe block
  -- "root" would be any outer/non-nested describe block
  ---@param name string
  ---@return ClownshowIdentifierType
  local function get_type(name)
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
  ---@param name string
  ---@return ClownshowIdentifierStatus
  local function get_status(name)
    if string.match(name, "skip") then
      return "pending"
    else
      return "loading"
    end
  end

  -- a test marked as "only" in jest will force skip all other non-only tests
  -- each time one is found, identify parents that contain an "only" using "has_only"
  local function set_only()
    root_has_only = true
    local parent = curr_parent
    while parent and not identifier_info[parent].has_only do
      identifier_info[parent].has_only = true
      parent = identifier_info[parent].parent
    end
  end

  ---@param props ClownshowIdentifier
  local function add_identifier(props)
    if props.type ~= "root" and each["root"] then
      -- when "root" is an "each" (tables) in jest, we need to wait for the root's arguments before applying parent logic to children
      -- otherwise, the parent's line number reference may be invalid
      -- set holding for processing later
      holding = props
    elseif not identifier_info[props.line] then
      if curr_parent and (identifier_info[curr_parent].status == "pending" or (not props.only and root_has_only)) then
        props.status = "pending"
      end

      if props.only then
        set_only()
      end

      props.has_only = false
      props.parent = curr_parent
      identifier_info[props.line] = props
    elseif curr_parent and not identifier_info[props.line].parent then
      identifier_info[props.line].parent = curr_parent
    end

    if props.type == "root" and not curr_parent then
      curr_parent = props.line
    end
  end

  ---@param props ClownshowIdentifier
  ---@param curr_each ClownshowIdentifier|nil
  local function add_each(props, curr_each)
    if identifier_info[props.line] then
      identifier_info[props.line].endline = props.endline
    end
    if not curr_each then return nil end
    each[curr_each.type] = nil

    -- "props" will be of type "args" which will not contain accurate type, only, and status info
    -- "args" will have the correct line and col info, set "above" to the "each"
    add_identifier(utils.merge_tables(props, {
      type = curr_each.type,
      endline = curr_each.endline,
      only = curr_each.only,
      status = curr_each.status,
      above = curr_each
    }))
  end

  ---@param props ClownshowIdentifier
  local function set_each(props)
    each[props.type] = props
  end

  -- each match will go in the order of:
  --    root? (describe)
  --      child (inner describe/test)
  --      inner_args
  --    args?
  --
  -- if "root" exists, it will always be the parent of "child"
  -- "inner_args" will always exist, only used when "child" is an "each" (tables)
  -- "args" will only exist if "root" exists, only used when "root" is an "each"
  for _, match, _ in query:iter_matches(root, bufnr, 0, -1) do
    curr_parent = nil
    holding = nil
    each = {}

    for id, node in pairs(match) do
      local name = query.captures[id]
      local range = { node:range() }
      ---@type ClownshowIdentifier
      local props = {
        type = get_type(name),
        line = range[1],
        col = range[2],
        endline = range[3],
        status = get_status(name),
        only = string.match(name, "only") ~= nil
      }

      if string.match(name, "each") then
        set_each(props)
      elseif not string.match(name, "args") then
        add_identifier(props)
      elseif name == "inner_args" then
        add_each(props, each["test"] or each["describe"])
      elseif name == "args" then
        add_each(props, each["root"])
      end
    end

    -- "holding" will only be set when "root" is an "each" and a child was found
    if holding then
      add_identifier(holding)
    end
  end

  -- reprocess all identifiers to account for any "only" states that were missed due to node order
  for _, identifier in pairs(identifier_info) do
    local parent = identifier_info[identifier.parent]
    local parent_not_only = not parent or (parent and not parent.only)
    if root_has_only and parent_not_only and not identifier.has_only and not identifier.only and identifier.status ~= "pending" then
      identifier.status = "pending"
    end
  end

  return identifier_info
end)

---@param bufnr number
local function reset_marks(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
end

---@param bufnr number
local function reset_diagnostics(bufnr)
  vim.diagnostic.reset(_ns, bufnr)
  local state = get_state(bufnr)
  if not state then return nil end
  state.diagnostics = {}
end

---@param bufnr number
local function reset_commands(bufnr)
  local state = get_state(bufnr)
  if not state then return nil end
  if state.job then vim.fn.jobstop(state.job) end
  for _, autocmd in ipairs(state.autocmd) do
    vim.api.nvim_del_autocmd(autocmd)
  end
  vim.api.nvim_buf_del_user_command(bufnr, "JestWatchStop")
end

---@param bufnr number
local function reset_jest(bufnr)
  if not _active[bufnr] then return nil end
  reset_marks(bufnr)
  reset_diagnostics(bufnr)
  reset_commands(bufnr)
  _active[bufnr] = nil
end

---@param bufnr number
---@return { test_file_name: string, project_root: string, command: string }|nil
local function get_job_info(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)

  local project_root = _config.project_root({ bufnr = bufnr, path = path })
  if not project_root or project_root == "" then return nil end

  local jest_cmd = _config.jest_command({ bufnr = bufnr, path = path, root = project_root })
  if not jest_cmd or jest_cmd == "" then return nil end

  return {
    test_file_name = vim.fn.fnamemodify(path, ":t"),
    project_root = project_root,
    command = jest_cmd .. " " .. table.concat(_jest_args, " ") .. " " .. path
  }
end

---@param bufnr number
local function attach_to_buffer(bufnr)
  if get_state(bufnr) then return nil end
  local state = set_state(bufnr, { diagnostics = {}, identifiers = {}, autocmd = {} })
  local job_info = get_job_info(bufnr)
  if not state or not job_info then return nil end

  local function create_autocmd(event, callback)
    table.insert(state.autocmd,
      vim.api.nvim_create_autocmd(event, {
        group = _group,
        buffer = bufnr,
        callback = callback
      })
    )
  end

  ---@param line string
  ---@return number[]|nil
  local function get_stack_location(line)
    if line and line:match(job_info.test_file_name) then
      for match in string.gmatch(line, "at .*" .. job_info.test_file_name .. ":([0-9]+:[0-9]+)") do
        local match_split = vim.split(match, ":")
        return { tonumber(match_split[1]) - 1, tonumber(match_split[2]) - 1 }
      end
    end
  end

  ---@param identifier ClownshowIdentifier
  ---@param message string
  local function create_diagnostic(identifier, message)
    local message_lines = vim.split(message, "\n")
    ---@type string[]
    local err_message = {}
    ---@type number|nil
    local err_line
    ---@type number|nil
    local err_col

    -- find a stack trace line matching the test file and identifier scope
    -- set the error location to the specific reference, trim remaining trace
    -- remaining trace will be jest-internal
    for _, message_line in ipairs(message_lines) do
      local stack_location = get_stack_location(message_line)
      ---@type number|nil
      local match_line
      if stack_location then
        match_line = stack_location[1]

        if match_line >= identifier.line and match_line <= identifier.endline then
          err_line = match_line
          err_col = stack_location[2]
        end
      end
      if err_line and err_line ~= match_line then break end
      table.insert(err_message, message_line)
    end
    if err_line then
      -- last line was the error, pop off the last line and extra whitepace
      table.remove(err_message)
      while vim.trim(err_message[#err_message]) == "" do
        table.remove(err_message)
      end
    end

    table.insert(state.diagnostics, {
      bufnr = bufnr,
      lnum = err_line or identifier.line,
      col = err_col or 0,
      message = table.concat(err_message, "\n"),
      severity = vim.diagnostic.severity.ERROR,
      source = _source,
      user_data = {}
    })
  end

  ---@param identifier ClownshowIdentifier
  local function create_mark(identifier)
    local line = identifier.line
    local col = identifier.col
    ---@type ClownshowStatusOptions
    local mark_options = _config[identifier.status] or _config["skipped"]
    local mark_text = ""

    if _config.show_icon then
      mark_text = mark_text .. mark_options.icon
    end
    if _config.show_icon and _config.show_text then
      mark_text = mark_text .. " "
    end
    if _config.show_text then
      mark_text = mark_text .. mark_options.text
    end

    -- "above" will be placed "inline" on line 0 otherwise it would be hidden
    if _config.mode == "above" and line ~= 0 then
      -- in an "each" (tables) the line/col is not guaranteed to be the highest point for the test
      -- use "above" instead
      if identifier.above then
        line = identifier.above.line
        col = identifier.above.col
      end

      identifier.mark = vim.api.nvim_buf_set_extmark(bufnr, _ns, line, col, {
        id = identifier.mark,
        priority = 100,
        virt_lines = { { { string.rep(" ", col) .. mark_text, mark_options.hl_group } } },
        virt_lines_above = true
      })
    else
      identifier.mark = vim.api.nvim_buf_set_extmark(bufnr, _ns, line, col, {
        id = identifier.mark,
        priority = 100,
        virt_text = { { mark_text, mark_options.hl_group } }
      })
    end
  end

  ---@param line number
  ---@return ClownshowIdentifier|nil
  local function get_identifier(line)
    return state.identifiers[line]
  end

  ---@param identifier ClownshowIdentifier
  ---@return ClownshowIdentifier|nil
  local function get_parent(identifier)
    return get_identifier(identifier.parent)
  end

  ---@param assertion ClownshowJestAssertion
  ---@return ClownshowIdentifier|nil
  local function get_result_identifier(assertion)
    local valid_location, location = pcall(function() return assertion.location.line - 1 end)
    if valid_location then
      local identifier = get_identifier(location)
      if identifier then
        return identifier
      end
    end

    -- in the event that no identifier can be found
    -- attempt to find one through the stack trace
    if assertion.failureMessages then
      local message_lines = vim.split(assertion.failureMessages[1], "\n", { trimempty = true })
      for _, message_line in ipairs(message_lines) do
        local stack_location = get_stack_location(message_line)
        if stack_location then
          local identifier = get_identifier(stack_location[1])
          if identifier then
            return identifier
          end
        end
      end
    end
  end

  ---@param identifier ClownshowIdentifier
  local function passed_mark(identifier)
    identifier.status = "passed"
    create_mark(identifier)

    local parent = get_parent(identifier)
    if parent and parent.status ~= "failed" and parent.status ~= "passed" then
      passed_mark(parent)
    end
  end

  ---@param identifier ClownshowIdentifier
  local function failed_mark(identifier)
    identifier.status = "failed"
    create_mark(identifier)

    local parent = get_parent(identifier)
    if parent and parent.status ~= "failed" then
      failed_mark(parent)
    end
  end

  ---@param identifier ClownshowIdentifier
  local function loading_mark(identifier)
    identifier.status = "loading"
    create_mark(identifier)
  end

  ---@param identifier ClownshowIdentifier
  local function skipped_mark(identifier)
    identifier.status = "pending"
    create_mark(identifier)
  end

  local function init_marks()
    state.init = true
    reset_marks(bufnr)
    reset_diagnostics(bufnr)
    state.identifiers = get_identifiers(bufnr)

    -- set initial "loading" states for all identifiers that are not known to be skipped
    for _, identifier in pairs(state.identifiers) do
      if identifier.status ~= "pending" then
        loading_mark(identifier)
      else
        skipped_mark(identifier)
      end
    end
  end

  ---@param results ClownshowJestResult[]
  local function handle_results(results)
    ---@type string|nil
    local message
    for _, result in ipairs(results) do
      message = result.message
      for _, assertion in ipairs(result.assertionResults) do
        local identifier = get_result_identifier(assertion)
        if identifier then
          message = nil
          if assertion.status == "failed" then
            failed_mark(identifier)
            create_diagnostic(identifier, assertion.failureMessages[1])
          elseif assertion.status == "passed" then
            passed_mark(identifier)
          elseif assertion.status == "pending" then
            skipped_mark(identifier)
          end
        end
      end
    end

    -- if a message still exists, there was a file-level error
    -- caused the test suite to not run
    if message and message ~= "" then
      create_diagnostic({ line = 0, col = 0, endline = 0 }, message)
    end

    -- any identifiers that do not have a processed status get set to skipped
    -- this will happen when all children within a describe have been skipped
    -- or if an "each" (tables) does not have a value
    for _, identifier in pairs(state.identifiers) do
      if identifier.status == "loading" then
        skipped_mark(identifier)
      end
    end

    vim.diagnostic.set(_ns, bufnr, state.diagnostics, {})
  end

  local function run_tests()
    local curr_data = ""
    state.job = vim.fn.jobstart(job_info.command, {
      cwd = job_info.project_root,
      stdout_buffered = false,
      ---@param _ any
      ---@param data string[]|nil
      on_stdout = function(_, data)
        if not state or not data then return nil end

        -- process only the jest result output
        ---@class ClownshowJestOutput
        ---@field testResults ClownshowJestResult[]
        local results = nil
        for _, line in ipairs(data) do
          if (curr_data ~= "" or (vim.startswith(line, '{') and string.match(line, "numTotalTests") ~= nil)) then
            curr_data = curr_data .. line
            local status_ok, res = pcall(vim.json.decode, curr_data)
            if status_ok then
              results = res
              break
            end
          end
        end

        -- concat stdout data until we can process the data as json
        if not results then return nil end
        curr_data = ""

        -- if init has not yet been run, force a run before handling results
        -- this will happen when the non-test buffer triggers jest watch to rerun a test
        if not state.init then init_marks() end
        state.init = nil

        ---@type ClownshowJestResult[]
        local test_results = {}
        if results and results.testResults then
          test_results = results.testResults
        end
        handle_results(test_results)
      end,
      on_exit = function()
        reset_jest(bufnr)
      end
    })
  end

  create_autocmd("BufWritePre", init_marks)
  create_autocmd("BufDelete", function()
    reset_jest(bufnr)
  end)
  vim.api.nvim_buf_create_user_command(bufnr, "JestWatchStop", function()
    reset_jest(bufnr)
  end, {})

  init_marks()
  run_tests()
end

local function validate_status_options(status)
  vim.validate({
    is_table = { status, "table" },
    icon = { status.icon, "string" },
    text = { status.text, "string" },
    hl_group = { status.hl_group, "string" },
  })
  return true
end

---@param opts table
local function validate_options(opts)
  vim.validate({
    mode = { opts.mode, function(mode) return mode == "inline" or mode == "above" end, "'above' or 'inline'" },
    jest_command = { opts.jest_command, { "function" } },
    project_root = { opts.project_root, { "function" } },
    show_icon = { opts.show_icon, "boolean" },
    show_text = { opts.show_text, "boolean" },
    passed = { opts.passed, validate_status_options },
    failed = { opts.failed, validate_status_options },
    skipped = { opts.skipped, validate_status_options },
    loading = { opts.loading, validate_status_options }
  })
  return opts
end

---@param opts ClownshowOptions
M.set_options = function(opts)
  if opts then
    _config = validate_options(utils.merge_tables(_config, opts))
  end
end

---@param opts ClownshowOptions
M.setup = function(opts)
  M.set_options(opts)

  vim.api.nvim_create_user_command("JestWatch", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local filetype = utils.get_filetype(bufnr)

    if filetype ~= "typescript" and filetype ~= "javascript" then return nil end
    if not _jest_query then set_jest_query() end

    attach_to_buffer(bufnr)
  end, {})
end

return M
