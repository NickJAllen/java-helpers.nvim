local M = {}

local utils = require("java-helpers.utils")
local log = utils.log
local java_ls_names = {
	jdtls = true,
	java_language_server = true,
}

local current_loaded_stack_trace = nil
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

---@param stack_trace JavaStackTraceElement[]
---@param element JavaStackTraceElement
---@return boolean
local function contains_stack_trace_element(stack_trace, element)
	for _, existing in ipairs(stack_trace) do
		if is_same_stack_track_element(existing, element) then
			return true
		end
	end

	return false
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

---@return boolean
local function is_java_client(client)
	return java_ls_names[client.name]
end

local function get_java_clients()
	return vim.tbl_filter(is_java_client, vim.lsp.get_clients())
end

--- @param full_class_name string Full class name that we want to resolve
--- @param expected_file_name string The expected file name we are looking for which can be used when multiple results are found to find the most likely
--- @return string? path The found path or nil
--- @return string? error The error message or nil
local function find_java_source_file_for_class(full_class_name, expected_file_name)
	local clients = get_java_clients()

	if #clients == 0 then
		return nil, "No Java clients found for resolving stack trace navigation"
	end

	local params = { query = full_class_name }
	local error = nil

	for _, client in ipairs(clients) do
		local err, result = utils.lsp_request_async(client, "workspace/symbol", params)

		if err or not result or vim.tbl_isempty(result) then
			error = "No workspace symbols were found by " .. client.name
		else
			for _, symbol in ipairs(result) do
				if
					symbol.kind == 5
					and (
						symbol.name == full_class_name or symbol.containerName .. "." .. symbol.name == full_class_name
					)
				then
					local uri = symbol.location.uri or symbol.location.targetUri

					if uri then
						local file_path = vim.uri_to_fname(uri)

						return file_path, nil
					else
						error = "Workspace symbol did not have a URI"
					end
				else
					error = "Workspace symbol matching class name " .. full_class_name .. " not found"
				end
			end
		end
	end

	return nil, "Could not find file using workspace symbols for " .. full_class_name .. ":" .. error
end

---@param element JavaStackTraceElement
local function go_to_java_stack_trace_element(element)
	log.trace("Go to " .. element.class_name .. " " .. element.file_name .. " " .. element.line_number)

	local file_path, error = find_java_source_file_for_class(element.class_name, element.file_name)

	if file_path then
		utils.go_to_file_and_line_number(file_path, element.line_number)
	else
		log.error(error)
	end
end

---@param element JavaStackTraceElement
local function go_to_java_stack_trace_element_in_bg(element)
	local co = coroutine.create(function()
		go_to_java_stack_trace_element(element)
	end)

	coroutine.resume(co)
end

local function load_java_stack_trace_around_cursor()
	local stack_trace, current_index = parse_java_stack_around_cursor()

	if stack_trace then
		current_loaded_stack_trace = stack_trace
		current_loaded_stack_trace_index = current_index
	end
end

---@param new_pos_callback function() : integer
local function navigate_current_stack_trace(new_pos_callback)
	if not current_loaded_stack_trace then
		load_java_stack_trace_around_cursor()
	end

	if not current_loaded_stack_trace then
		log.info("No Java stack trace found")
		return
	end

	assert(#current_loaded_stack_trace >= 1)
	assert(current_loaded_stack_trace_index >= 1)
	assert(current_loaded_stack_trace_index <= #current_loaded_stack_trace)

	local new_pos = new_pos_callback()

	assert(new_pos >= 1)
	assert(new_pos <= #current_loaded_stack_trace)

	local element = current_loaded_stack_trace[new_pos]

	assert(element ~= nil)

	current_loaded_stack_trace_index = new_pos

	go_to_java_stack_trace_element_in_bg(element)
end

function M.go_to_current_java_stack_trace_line()
	load_java_stack_trace_around_cursor()

	navigate_current_stack_trace(function()
		return current_loaded_stack_trace_index
	end)
end

function M.go_to_bottom_of_stack_trace()
	navigate_current_stack_trace(function()
		return 1
	end)
end

function M.go_to_top_of_stack_trace()
	navigate_current_stack_trace(function()
		return #current_loaded_stack_trace
	end)
end

function M.go_up_java_stack_trace()
	navigate_current_stack_trace(function()
		if current_loaded_stack_trace_index == #current_loaded_stack_trace then
			log.info("At top of stack trace")
			return #current_loaded_stack_trace
		else
			return current_loaded_stack_trace_index + 1
		end
	end)
end

function M.go_down_java_stack_trace()
	navigate_current_stack_trace(function()
		if current_loaded_stack_trace_index == 1 then
			log.info("At bottom of stack trace")
			return 1
		else
			return current_loaded_stack_trace_index - 1
		end
	end)
end

---@param element JavaStackTraceElement
---@return table? item
local function java_stack_trace_element_to_quickfix_item(element)
	local path, error = find_java_source_file_for_class(element.class_name, element.file_name)

	if not path then
		log.error("cannot make qf item:" .. error)
		return nil
	end

	return {
		filename = path,
		lnum = element.line_number,
		col = 1,
		text = element.class_name,
		type = "E",
	}
end

---@param stack_trace JavaStackTraceElement[]
---@return table?
local function java_stack_trace_to_quickfix_items(stack_trace)
	local items = {}
	local previously_converted = {}

	for _, element in ipairs(stack_trace) do
		if not contains_stack_trace_element(previously_converted, element) then
			local item = java_stack_trace_element_to_quickfix_item(element)

			previously_converted[#previously_converted + 1] = element

			if item then
				items[#items + 1] = item
			end
		end
	end

	if #items > 0 then
		return items
	end

	log.error("Could not convert stack trace to quickfix items")

	return nil
end

---@param stack_trace JavaStackTraceElement[]
local function send_java_stack_trace_to_quickfix_list(stack_trace)
	local items = java_stack_trace_to_quickfix_items(stack_trace)

	if items then
		log.info("Stack trace sent to quickfix list")
		vim.fn.setqflist(items, "r")
	end
end

---@param stack_trace JavaStackTraceElement[]
local function send_java_stack_trace_to_quickfix_list_in_bg(stack_trace)
	local co = coroutine.create(function()
		send_java_stack_trace_to_quickfix_list(stack_trace)
	end)

	coroutine.resume(co)
end

function M.send_java_stack_trace_to_quickfix_list()
	if not current_loaded_stack_trace then
		load_java_stack_trace_around_cursor()
	end

	if not current_loaded_stack_trace then
		log.error("No Java stack trace found to copy to quickfix list")
		return
	end

	send_java_stack_trace_to_quickfix_list_in_bg(current_loaded_stack_trace)
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
	vim.api.nvim_create_user_command("JavaHelpersSendStackTraceToQuickfix", M.send_java_stack_trace_to_quickfix_list, {
		desc = "Send Java stack trace to Quickfix List",
	})
end

return M
