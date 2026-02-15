local M = {}

local utils = require("java-helpers.utils")
local log = utils.log
local java_ls_names = {
	jdtls = true,
	java_language_server = true,
}

---@class JavaStackTraceElement
---@field class_name string
---@field method_name string
---@field file_name string?
---@field line_number integer

---@type JavaStackTraceElement[]?
local current_loaded_stack_trace = nil

---@type integer
local current_loaded_stack_trace_index = 0

local begin_regex = "%s*at "
local module_regex = "[%w%._]+"
local class_name_regex = "[%w%.%$_]+"
local method_name_regexes = { "<?[%w_]+>?", "lambda%$%d+" }
local line_number_regex = "%d+"
local file_name_regexes = { "[%w%.%-]+%.%w+", "Unknown Source", "Native Method" }

---@param with_module boolean
---@param file_name_regex string
---@param with_line_number boolean
local function create_regex(with_module, file_name_regex, method_name_regex, with_line_number)
	local r = begin_regex

	if with_module then
		r = r .. module_regex .. "/"
	end

	r = r .. "(" .. class_name_regex .. ")%.(" .. method_name_regex .. ")%((" .. file_name_regex .. ")"

	if with_line_number then
		r = r .. ":(" .. line_number_regex .. ")"
	end

	r = r .. "%).*"

	return r
end

---@param line string
---@return string? class_name
---@return string? method_name
---@return string? file_path
---@return integer? line_number
local function parse_class_name_file_and_line_number(line)
	for _, file_name_regex in ipairs(file_name_regexes) do
		for _, method_name_regex in ipairs(method_name_regexes) do
			local regex = create_regex(false, file_name_regex, method_name_regex, true)

			local class_name, method_name, file_name, line_number_string = line:match(regex)

			if class_name then
				return class_name, method_name, file_name, tonumber(line_number_string)
			end

			regex = create_regex(true, file_name_regex, method_name_regex, true)

			class_name, method_name, file_name, line_number_string = line:match(regex)

			if class_name then
				return class_name, method_name, file_name, tonumber(line_number_string)
			end
		end
	end

	return nil
end

---@param line string
---@return string? class_name
---@return string? method_name
---@return string? file_path
local function parse_class_name_and_file(line)
	for _, file_name_regex in ipairs(file_name_regexes) do
		for _, method_name_regex in ipairs(method_name_regexes) do
			local regex = create_regex(false, file_name_regex, method_name_regex, false)

			local class_name, method_name, file_name = line:match(regex)

			if class_name then
				return class_name, method_name, file_name
			end

			regex = create_regex(true, file_name_regex, method_name_regex, false)

			class_name, method_name, file_name = line:match(regex)

			if class_name then
				return class_name, method_name, file_name
			end
		end
	end

	return nil
end

local function get_outer_class_name(full_class_name)
	return full_class_name:match("([^%$]+)")
end

---@param line string The line to be parsed
---@return JavaStackTraceElement? result The parsed java stack trace element or nil if could not be parsed
function M.parse_java_stack_trace_line(line)
	local class_name, method_name, file_name, line_number = parse_class_name_file_and_line_number(line)

	if not class_name then
		-- Could be a stack trace line that has a module in it so try that as well
		class_name, method_name, file_name = parse_class_name_and_file(line)

		if not class_name then
			return nil
		end
	end

	if not line_number then
		line_number = 1
	end

	return {
		class_name = class_name,
		method_name = method_name,
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
---
---@class TextLines
---@field line_count integer The number of lines in the source
---@field get_line_text function(line : integer) : string Retrieves a line from the source

---@param bufnr integer The buffer
---@param line integer The line number
local function get_buffer_line(bufnr, line)
	return vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
end

local function get_buffer_line_count(bufnr)
	return vim.api.nvim_buf_line_count(bufnr)
end

---@param bufnr integer The buffer to read lines from
---@return TextLines
local function create_text_lines_from_buffer(bufnr)
	return {
		line_count = get_buffer_line_count(bufnr),
		get_line_text = function(line)
			return get_buffer_line(bufnr, line)
		end,
	}
end

---@param lines_array string[]
---@return TextLines
local function create_text_lines_from_array(lines_array)
	return {
		line_count = #lines_array,
		get_line_text = function(line)
			return lines_array[line]
		end,
	}
end

local function create_text_lines_from_string(text)
	local lines = vim.split(text, "\n", { plain = true })

	return create_text_lines_from_array(lines)
end

---@param lines TextLines
---@param line integer
---@return JavaStackTraceElement? element
local function parse_java_stack_trace_line_in_lines(lines, line)
	local line_text = lines.get_line_text(line)
	local element = M.parse_java_stack_trace_line(line_text)

	if element then
		return element
	end

	-- Maybe the lines have been  wrapped with a hard <CR> between them
	-- Try joining with the line above if it is also not valid but works when joined then use that

	if line > 1 then
		local line_above = lines.get_line_text(line - 1)

		if not M.parse_java_stack_trace_line(line_above) then
			local joined = line_above .. line_text
			element = M.parse_java_stack_trace_line(joined)

			if element then
				return element
			end
		end
	end

	local total_lines = lines.line_count

	if line < total_lines then
		local line_below = lines.get_line_text(line + 1)

		if not M.parse_java_stack_trace_line(line_below) then
			local joined = line_text .. line_below
			element = M.parse_java_stack_trace_line(joined)

			if element then
				return element
			end
		end
	end

	return nil
end

---@param lines TextLines The lines to search for first line in
---@param start_from_line integer The line number (1 based) to start from
---@return integer? The first line number (1 based) or nil if no line found
local function find_first_java_stack_trace_line(lines, start_from_line)
	local line = start_from_line

	while line <= lines.line_count do
		local element = parse_java_stack_trace_line_in_lines(lines, line)

		if element then
			return line
		end

		line = line + 1
	end

	return nil
end

--- Parses all contiguous stack trace lines around the cursor
--- @param lines TextLines
--- @param cursor_line integer The line around which we should try to parse a stack trace from (looks up and down)
--- @return JavaStackTraceElement[]|nil
--- @return integer index The 1 based index where the current line was found in the stack trace
local function parse_java_stack_around_line(lines, cursor_line)
	local total_lines = lines.line_count
	local current_element = parse_java_stack_trace_line_in_lines(lines, cursor_line)

	if not current_element then
		return nil, 0
	end

	local stack_elements = {}

	local prev_element = nil

	-- Look Upwards
	local up = cursor_line - 1
	while up >= 1 do
		local element = parse_java_stack_trace_line_in_lines(lines, up)

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
		local element = parse_java_stack_trace_line_in_lines(lines, down)

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

local class_and_expected_file_name_to_file_path_cache = {}

--- @param full_class_name string Full class name that we want to resolve
--- @param expected_file_name string? The expected file name we are looking for which can be used when multiple results are found to find the most likely
local function get_cache_key(full_class_name, expected_file_name)
	if not expected_file_name then
		return full_class_name
	end

	return full_class_name .. expected_file_name
end

--- @param full_class_name string Full class name that we want to resolve
--- @param expected_file_name string? The expected file name we are looking for which can be used when multiple results are found to find the most likely
--- @return string? path The found path or nil
local function get_cached_file_path(full_class_name, expected_file_name)
	local key = get_cache_key(full_class_name, expected_file_name)

	return class_and_expected_file_name_to_file_path_cache[key]
end

--- @param full_class_name string Full class name that we want to resolve
--- @param expected_file_name string? The expected file name we are looking for which can be used when multiple results are found to find the most likely
--- @param file_path string
local function remember_cached_file_path(full_class_name, expected_file_name, file_path)
	local key = get_cache_key(full_class_name, expected_file_name)

	class_and_expected_file_name_to_file_path_cache[key] = file_path

	assert(get_cached_file_path(full_class_name, expected_file_name) == file_path)
end

--- @param full_class_name string Full class name that we want to resolve
--- @param expected_file_name string? The expected file name we are looking for which can be used when multiple results are found to find the most likely
--- @return string? path The found path or nil
--- @return string? error The error message or nil
local function find_java_source_file_for_class(full_class_name, expected_file_name)
	local cached_path = get_cached_file_path(full_class_name, expected_file_name)

	if cached_path then
		return cached_path, nil
	end

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

						remember_cached_file_path(full_class_name, expected_file_name, file_path)

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
local function find_java_source_file_for_element(element)
	local class_name = get_outer_class_name(element.class_name)

	return find_java_source_file_for_class(class_name, element.file_name)
end

---@param element JavaStackTraceElement
local function go_to_java_stack_trace_element(element)
	log.trace("Go to " .. element.class_name .. " " .. element.file_name .. " " .. element.line_number)

	local file_path, error = find_java_source_file_for_element(element)

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

	local ok, error = coroutine.resume(co)

	if not ok then
		print(debug.traceback(co))
	end
end

---@param text string The text to be parsed and used as a stack trace
---@return JavaStackTraceElement[]? The parsed Java stack trace elements
local function parse_java_stack_trace_from_text(text)
	local lines = create_text_lines_from_string(text)
	local first_line = find_first_java_stack_trace_line(lines, 1)

	if not first_line then
		return nil
	end

	local stack_trace, index = parse_java_stack_around_line(lines, first_line)

	assert(stack_trace)
	assert(index == 1)

	return stack_trace
end

---@param name string The name of the register to use as the source of a stack trace
local function parse_java_stack_track_from_register(name)
	assert(#name == 1)

	local text = vim.fn.getreg(name)

	return parse_java_stack_trace_from_text(text)
end

---@param win integer The window id
local function parse_java_stack_around_cursor(win)
	local bufnr = vim.api.nvim_win_get_buf(win)
	local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
	local lines = create_text_lines_from_buffer(bufnr)

	return parse_java_stack_around_line(lines, cursor_line)
end

-- Sets up the Java stack trace to be navigated for a command based on the argument provided to it
---@param register_name_or_text_to_parse string? Optional argument to command that defines a register to use (if just a single character), the string that should be parsed, or if nil uses the stack trace found at the cursor position
local function setup_stack_trace(register_name_or_text_to_parse)
	if register_name_or_text_to_parse and #register_name_or_text_to_parse == 1 then
		-- We want to use a named register

		current_loaded_stack_trace = parse_java_stack_track_from_register(register_name_or_text_to_parse)
		current_loaded_stack_trace_index = 1

		if not current_loaded_stack_trace then
			log.error("Could not lead stack trace from register " .. register_name_or_text_to_parse)
		end

		return
	end

	if register_name_or_text_to_parse and #register_name_or_text_to_parse > 1 then
		current_loaded_stack_trace = parse_java_stack_trace_from_text(register_name_or_text_to_parse)
		current_loaded_stack_trace_index = 1

		if not current_loaded_stack_trace then
			log.error("Could not lead stack trace from supplied text " .. register_name_or_text_to_parse)
		end

		return
	end

	local stack_trace, current_index = parse_java_stack_around_cursor(0)

	if stack_trace then
		current_loaded_stack_trace = stack_trace
		current_loaded_stack_trace_index = current_index
	end
end

---@param new_pos_callback function() : integer
local function navigate_current_stack_trace(new_pos_callback)
	if not current_loaded_stack_trace then
		log.error("No Java stack trace found")
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

---@param register_name_or_text_to_parse string? If a single character then defines the register name, if multiple characters then will parse trhe supplied text, if nil or empty then uses the text around the current cursor position
function M.go_to_current_java_stack_trace_line(register_name_or_text_to_parse)
	setup_stack_trace(register_name_or_text_to_parse)

	navigate_current_stack_trace(function()
		return current_loaded_stack_trace_index
	end)
end

---@param register_name_or_text_to_parse string? If a single character then defines the register name, if multiple characters then will parse trhe supplied text, if nil or empty then uses the text around the current cursor position
function M.go_to_bottom_of_stack_trace(register_name_or_text_to_parse)
	setup_stack_trace(register_name_or_text_to_parse)

	navigate_current_stack_trace(function()
		return 1
	end)
end

---@param register_name_or_text_to_parse string? If a single character then defines the register name, if multiple characters then will parse trhe supplied text, if nil or empty then uses the text around the current cursor position
function M.go_to_top_of_stack_trace(register_name_or_text_to_parse)
	setup_stack_trace(register_name_or_text_to_parse)

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
	local path, _error = find_java_source_file_for_element(element)

	if not path then
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

	local ok, error = coroutine.resume(co)

	if not ok then
		print(debug.traceback(co))
	end
end

---@param register_name_or_text_to_parse string? If a single character then defines the register name, if multiple characters then will parse trhe supplied text, if nil or empty then uses the text around the current cursor position
function M.send_java_stack_trace_to_quickfix_list(register_name_or_text_to_parse)
	setup_stack_trace(register_name_or_text_to_parse)

	if not current_loaded_stack_trace then
		log.error("No Java stack trace found to send to quickfix list")
		return
	end

	send_java_stack_trace_to_quickfix_list_in_bg(current_loaded_stack_trace)
end

---@param element JavaStackTraceElement
---@param index integer
local function java_stack_trace_element_to_snacks_item(element, index)
	local path, error = find_java_source_file_for_element(element)

	if not path then
		return nil
	end

	return {
		file = path,
		pos = { tonumber(element.line_number), 0 },
		text = element.class_name .. "." .. element.method_name,
		java_stack_trace_element = element,
		java_stack_trace_index = index,
	}
end

---@param stack_trace JavaStackTraceElement[]
---@return table? items
local function java_stack_trace_to_snacks_items(stack_trace)
	local items = {}
	local previously_converted = {}

	for i, element in ipairs(stack_trace) do
		if not contains_stack_trace_element(previously_converted, element) then
			local item = java_stack_trace_element_to_snacks_item(element, i)

			previously_converted[#previously_converted + 1] = element

			if item then
				items[#items + 1] = item
			end
		end
	end

	if #items > 0 then
		return items
	end

	log.error("Could not convert stack trace to snacks picker items")

	return nil
end

---@param stack_trace JavaStackTraceElement[]
---@param initially_selected integer
local function pick_java_stack_trace_line(stack_trace, initially_selected)
	local items = java_stack_trace_to_snacks_items(stack_trace)

	if not items then
		return
	end

	local max_class_and_method_length = 1

	for _, item in ipairs(items) do
		---@type JavaStackTraceElement
		local element = item.java_stack_trace_element
		local class_name = element.class_name
		local method_name = element.method_name
		local width = #class_name + 1 + #method_name

		if width > max_class_and_method_length then
			max_class_and_method_length = width
		end
	end

	local picker = require("snacks.picker")

	picker.pick({
		source = "stack",
		items = items,
		format = function(item, _)
			local cols = {}
			local element = item.java_stack_trace_element

			assert(element)

			local class_name = element.class_name
			local method_name = element.method_name
			local width = #class_name + 1 + #method_name

			table.insert(cols, { class_name, "SnacksLabel" })
			table.insert(cols, { ".", "SnacksPickerSpecial" })
			table.insert(cols, { method_name, "SnacksPickerSpecial" })
			table.insert(cols, { string.rep(" ", max_class_and_method_length - width + 2), "SnacksLabel" })

			local file_name = element.file_name

			if file_name then
				table.insert(cols, { file_name, "SnacksPickerFile" })
				table.insert(cols, { ":", "SnacksLabel" })
			end

			table.insert(cols, { tostring(element.line_number), "SnacksPickerRow" })

			return cols
		end,
		confirm = function(p, item)
			p:close()
			if item then
				utils.go_to_file_and_line_number(item.file, item.pos[1])

				if stack_trace == current_loaded_stack_trace then
					local index = item.java_stack_trace_index

					if index then
						current_loaded_stack_trace_index = index
					end
				end
			end
		end,
	})
end

---@param stack_trace JavaStackTraceElement[]
---@param initially_selected integer
local function pick_java_stack_trace_line_in_bg(stack_trace, initially_selected)
	local co = coroutine.create(function()
		pick_java_stack_trace_line(stack_trace, initially_selected)
	end)

	local ok, error = coroutine.resume(co)

	if not ok then
		print(debug.traceback(co))
	end
end

---@param register_name_or_text_to_parse string? If a single character then defines the register name, if multiple characters then will parse trhe supplied text, if nil or empty then uses the text around the current cursor position
function M.pick_java_stack_trace_line(register_name_or_text_to_parse)
	setup_stack_trace(register_name_or_text_to_parse)

	if not current_loaded_stack_trace then
		log.error("No Java stack trace for picking")
		return
	end

	pick_java_stack_trace_line_in_bg(current_loaded_stack_trace, current_loaded_stack_trace_index)
end

function M.setup(_)
	vim.api.nvim_create_user_command("JavaHelpersGoToStackTraceLine", function(opts)
		M.go_to_current_java_stack_trace_line(opts.args)
	end, {
		desc = "Go to line in Java stack",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("JavaHelpersPickStackTraceLine", function(opts)
		M.pick_java_stack_trace_line(opts.args)
	end, {
		desc = "Pick line frome Java stack trace",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("JavaHelpersGoDownStackTrace", M.go_down_java_stack_trace, {
		desc = "Go down Java stack trace",
	})

	vim.api.nvim_create_user_command("JavaHelpersGoUpStackTrace", M.go_up_java_stack_trace, {
		desc = "Go up Java stack trace",
	})

	vim.api.nvim_create_user_command("JavaHelpersGoToBottomOfStackTrace", function(opts)
		M.go_to_bottom_of_stack_trace(opts.args)
	end, {
		desc = "Go to bottom of Java stack trace",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("JavaHelpersGoToTopOfStackTrace", function(opts)
		M.go_to_top_of_stack_trace(opts.args)
	end, {
		desc = "Go to top of Java stack trace",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("JavaHelpersSendStackTraceToQuickfix", function(opts)
		M.send_java_stack_trace_to_quickfix_list(opts.args)
	end, {
		desc = "Send Java stack trace to Quickfix List",
		nargs = "?",
	})
end

return M
