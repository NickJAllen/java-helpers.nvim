local M = {}

local utils = require("java-helpers.utils")
local log = utils.log
local java_ls_names = { "jdtls", "java_language_server" }

local loaded_stack_trace = nil
local current_loaded_stack_trace_index = 0

---@class JavaStackTraceElement
---@field class_name string
---@field file_name string?
---@field line_number integer

local begin_regex = "%s*at "
local module_regex = "[%w%._]+"
local class_name_regex = "[%w%.%$_]+"
local method_name_regex = "<?[%w_]+>?"
local line_number_regex = "%d+"
local file_name_regexes = { "[%w%.%-]+%.%w+", "Unknown Source", "Native Method" }

---@param with_module boolean
---@param file_name_regex string
---@param with_line_number boolean
local function create_regex(with_module, file_name_regex, with_line_number)
	local r = begin_regex

	if with_module then
		r = r .. module_regex .. "/"
	end

	r = r .. "(" .. class_name_regex .. ")%." .. method_name_regex .. "%((" .. file_name_regex .. ")"

	if with_line_number then
		r = r .. ":(" .. line_number_regex .. ")"
	end

	r = r .. "%).*"

	return r
end

---@param line string
---@return string? class_name
---@return string? file_path
---@return integer? line_number
local function parse_class_name_file_and_line_number(line)
	for _, file_name_regex in ipairs(file_name_regexes) do
		local regex = create_regex(false, file_name_regex, true)

		local class_name, file_name, line_number_string = line:match(regex)

		if class_name then
			return class_name, file_name, line_number_string
		end

		regex = create_regex(true, file_name_regex, true)

		class_name, file_name, line_number_string = line:match(regex)

		if class_name then
			return class_name, file_name, line_number_string
		end
	end

	return nil
end

---@param line string
---@return string? class_name
---@return string? file_path
local function parse_class_name_and_file(line)
	for _, file_name_regex in ipairs(file_name_regexes) do
		local regex = create_regex(false, file_name_regex, false)

		local class_name, file_name = line:match(regex)

		if class_name then
			return class_name, file_name
		end

		regex = create_regex(true, file_name_regex, false)

		class_name, file_name = line:match(regex)

		if class_name then
			return class_name, file_name
		end
	end

	return nil
end

---@param line string The line to be parsed
---@return JavaStackTraceElement | nil result The parsed java stack trace element or nil if could not be parsed
function M.parse_java_stack_trace_line(line)
	local class_name, file_name, line_number_string = parse_class_name_file_and_line_number(line)

	if not class_name then
		-- Could be a stack trace line that has a module in it so try that as well
		class_name, file_name = parse_class_name_and_file(line)

		if not class_name then
			return nil
		end
	end

	-- String off nested class part from class name
	class_name = class_name:match("([^%$]+)")

	local line_number = tonumber(line_number_string)

	if not line_number then
		line_number = 1
	end

	return {
		class_name = class_name,
		file_name = file_name,
		line_number = line_number,
	}
end

---@param e1 JavaStackTraceElement
---@param e2 JavaStackTraceElement?
---@return boolean True if the same
local function is_same_stack_track_element(e1, e2)
	if not e2 then
		return false
	end

	return e1.class_name == e2.class_name and e1.file_name == e2.file_name and e1.line_number == e2.line_number
end

--- Parses all contiguous stack trace lines around the cursor
--- @return JavaStackTraceElement[]|nil
--- @return integer The 1 based index where the current line was found in the stack trace
local function parse_java_stack_around_cursor()
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] -- 1-indexed
	local total_lines = vim.api.nvim_buf_line_count(bufnr)

	local current_line_text = vim.api.nvim_buf_get_lines(bufnr, cursor_line - 1, cursor_line, false)[1]
	local current_element = M.parse_java_stack_trace_line(current_line_text)

	if not current_element then
		log.error("No Java stack trace could be parsed at the cursor position for line " .. current_line_text)
		return nil, 0
	end

	local stack_elements = {}

	local prev_element = nil

	-- Look Upwards
	local up = cursor_line - 1
	while up >= 1 do
		local line = vim.api.nvim_buf_get_lines(bufnr, up - 1, up, false)[1]
		local element = M.parse_java_stack_trace_line(line)

		if element then
			if not is_same_stack_track_element(element, prev_element) then
				table.insert(stack_elements, 1, element)
				prev_element = element
			end

			up = up - 1
		else
			break
		end
	end

	local current_line_index = #stack_elements + 1

	table.insert(stack_elements, current_element)

	prev_element = current_element

	-- Look Downwards
	local down = cursor_line + 1
	while down <= total_lines do
		local line = vim.api.nvim_buf_get_lines(bufnr, down - 1, down, false)[1]
		local element = M.parse_java_stack_trace_line(line)

		if element then
			if not is_same_stack_track_element(element, prev_element) then
				table.insert(stack_elements, element)
				prev_element = element
			end

			down = down + 1
		else
			break
		end
	end

	return stack_elements, current_line_index
end

--- @param full_class_name string
--- @param expected_file_name string The expected file name we are looking for
--- @param file_found_callback fun(path:string|nil, error:string|nil)
local function find_java_source_file_for_class(full_class_name, expected_file_name, file_found_callback)
	local clients = vim.lsp.get_clients({ name = "jdtls" })

	if #clients == 0 then
		log.error("No jdtls client found for stack trace navigation")
		return
	end

	-- We use the first jdtls client found
	local client = clients[1]
	local params = { query = full_class_name }

	client.request("workspace/symbol", params, function(err, result, _)
		if err or not result or vim.tbl_isempty(result) then
			file_found_callback(nil, "Class not found: " .. full_class_name)
			return
		end

		-- Look for the exact match in the returned symbols
		for _, symbol in ipairs(result) do
			-- JDTLS returns the full class name in 'containerName' or 'name'
			-- depending on the specific symbol kind (Class = 5)
			if
				symbol.kind == 5
				and (symbol.name == full_class_name or symbol.containerName .. "." .. symbol.name == full_class_name)
			then
				local uri = symbol.location.uri or symbol.location.targetUri
				if uri then
					local file_path = vim.uri_to_fname(uri)

					file_found_callback(file_path)

					return
				end
			end
		end

		file_found_callback(nil, "Could not find file using workspace symbols for " .. full_class_name)
	end)
end

---@param element JavaStackTraceElement
local function go_to_java_stack_trace_element(element)
	log.trace("Go to " .. element.class_name .. " " .. element.file_name .. " " .. element.line_number)

	find_java_source_file_for_class(element.class_name, element.file_name, function(file_path, error)
		if file_path then
			utils.go_to_file_and_line_number(file_path, element.line_number)
		else
			log.error(error)
		end
	end)
end

---@param line string the line that contains the java stack trace text
function M.go_to_java_stack_trace_line(line)
	local element = M.parse_java_stack_trace_line(line)

	if not element then
		log.error("Could not parse Java stack trace line " .. line)
		return
	end

	go_to_java_stack_trace_element(element)
end

local function load_java_stack_trace()
	local stack_trace, current_index = parse_java_stack_around_cursor()

	if stack_trace then
		loaded_stack_trace = stack_trace
		current_loaded_stack_trace_index = current_index
		return
	end

	log.info("No Java stack trace found")
end

local function load_java_stace_trace_if_needed()
	if not loaded_stack_trace then
		load_java_stack_trace()
	end
end

function M.go_to_current_java_stack_trace_line()
	load_java_stack_trace()

	if not loaded_stack_trace then
		return
	end

	local element = loaded_stack_trace[current_loaded_stack_trace_index]

	go_to_java_stack_trace_element(element)
end

function M.go_down_java_stack_trace()
	load_java_stace_trace_if_needed()

	if not loaded_stack_trace then
		return
	end

	if current_loaded_stack_trace_index == 1 then
		log.info("At bottom of Java stack trace")
		return
	end

	current_loaded_stack_trace_index = current_loaded_stack_trace_index - 1

	local element = loaded_stack_trace[current_loaded_stack_trace_index]

	go_to_java_stack_trace_element(element)
end

function M.go_to_bottom_of_stack_trace()
	load_java_stace_trace_if_needed()

	if not loaded_stack_trace then
		return
	end

	local element = loaded_stack_trace[1]
	current_loaded_stack_trace_index = 1

	go_to_java_stack_trace_element(element)
end

function M.go_to_top_of_stack_trace()
	load_java_stace_trace_if_needed()

	if not loaded_stack_trace then
		return
	end

	local count = #loaded_stack_trace
	current_loaded_stack_trace_index = count
	local element = loaded_stack_trace[count]

	go_to_java_stack_trace_element(element)
end

function M.go_up_java_stack_trace()
	load_java_stace_trace_if_needed()

	if not loaded_stack_trace then
		return
	end

	local count = #loaded_stack_trace

	if current_loaded_stack_trace_index == count then
		log.info("At top of Java stack trace")
		return
	end

	current_loaded_stack_trace_index = current_loaded_stack_trace_index + 1

	local element = loaded_stack_trace[current_loaded_stack_trace_index]

	go_to_java_stack_trace_element(element)
end

function M.setup(_)
	vim.api.nvim_create_user_command("JavaHelpersGoToStackTraceLine", M.go_to_current_java_stack_trace_line, {
		desc = "Go to line in Java stack trace at cursor",
	})
	vim.api.nvim_create_user_command("JavaHelpersGoDownStackTrace", M.go_down_java_stack_trace, {
		desc = "Go down Java stack trace",
	})
	vim.api.nvim_create_user_command("JavaHelpersGoUpStackTrace", M.go_up_java_stack_trace, {
		desc = "Go up Java stack trace",
	})
	vim.api.nvim_create_user_command("JavaHelpersGoToBottomOfStackTrace", M.go_to_bottom_of_stack_trace, {
		desc = "Go to bottom of Java stack trace",
	})
	vim.api.nvim_create_user_command("JavaHelpersGoToTopOfStackTrace", M.go_to_top_of_stack_trace, {
		desc = "Go to top of Java stack trace",
	})
end

return M
