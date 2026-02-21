local M = {}

local utils = require("java-helpers.utils")
local log = utils.log
local java_ls_names = {
	jdtls = true,
	java_language_server = true,
}

---@class JavaHelpers.StackTraceConfig
---@field deobfuscate_command string? Command to use to deobfuscate stack traces (defaults to "retrace"). This command should take obfuscated stack on stdin and a mapping file as an argument and output the deobfuscated stack on stdout.
---@field obfuscation_mappings_dir string? Path to directory where should select obfuscation mappings from

---@type JavaHelpers.StackTraceConfig
local default_config = {
	deobfuscate_command = "retrace",
	obfuscation_mappings_dir = nil,
}

---@type JavaHelpers.StackTraceConfig
local config = {}

---@class JavaHelpers.StackTraceElement
---@field class_name string
---@field method_name string
---@field file_name string?
---@field line_number integer

---@type JavaHelpers.StackTraceElement[]?
local current_loaded_stack_trace = nil

---@type integer
local current_loaded_stack_trace_index = 0

---@type string?
local current_obfusction_file = nil

local begin_regex = "%s*at "
local module_regex = "[%w%._]+"
local class_name_regex = "[%w%.%$_]+"
local method_name_regexes = { "<?[%w_]+>?", "lambda%$%d+", "lambda%$static%$%d+" }
local line_number_regex = "%d+"
local file_name_regexes = { "[%w%.%-]+", "Unknown Source", "Native Method" }

---@param line string
---@return boolean
local function is_more_line(line)
	local more_regex = "... %d+ more.*"

	local result = line:find(more_regex)

	return result ~= nil
end

---@param line string
---@return boolean
local function is_caused_by_line(line)
	local caused_by_regex = "Caused by:.*"

	local result = line:find(caused_by_regex)

	return result ~= nil
end

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

---@return string? outer_class_name
local function get_outer_class_name(full_class_name)
	-- for method_name_regex in ipairs(method_name_regexes) do
	-- 	local regex = "(" .. class_name_regex .. ")." .. method_name_regex
	--
	-- 	local outer_class_name = full_class_name:match(regex)
	--
	-- 	if outer_class_name then
	-- 		return outer_class_name
	-- 	end
	-- end

	return full_class_name:match("([^%$]+)")
end

---@param line string The line to be parsed
---@return JavaHelpers.StackTraceElement? result The parsed java stack trace element or nil if could not be parsed
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

---@param e1 JavaHelpers.StackTraceElement
---@param e2 JavaHelpers.StackTraceElement?
---@return boolean True if the same
local function is_same_stack_track_element(e1, e2)
	if not e2 then
		return false
	end

	return e1.class_name == e2.class_name and e1.file_name == e2.file_name and e1.line_number == e2.line_number
end

---@param stack_trace JavaHelpers.StackTraceElement[]
---@param element JavaHelpers.StackTraceElement
---@return boolean
local function contains_stack_trace_element(stack_trace, element)
	for _, existing in ipairs(stack_trace) do
		if is_same_stack_track_element(existing, element) then
			return true
		end
	end

	return false
end

---@param lines JavaHelpers.TextLines
---@param line integer
---@return JavaHelpers.StackTraceElement? element
---@return integer? first_line
---@return integer? last_line
local function parse_java_stack_trace_line_in_lines(lines, line)
	local line_text = lines.get_line_text(line)
	local element = M.parse_java_stack_trace_line(line_text)

	if element then
		return element, line, line
	end

	-- Maybe the lines have been  wrapped with a hard <CR> between them
	-- Try joining with the line above if it is also not valid but works when joined then use that

	if line > 1 then
		local line_above = lines.get_line_text(line - 1)

		if not M.parse_java_stack_trace_line(line_above) then
			local joined = line_above .. line_text
			element = M.parse_java_stack_trace_line(joined)

			if element then
				return element, line - 1, line
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
				return element, line, line + 1
			end
		end
	end

	return nil, nil, nil
end

---@param lines JavaHelpers.TextLines The lines to search for first line in
---@param start_from_line integer The line number (1 based) to start from
---@return integer? The first line number (1 based) or nil if no line found
local function find_first_java_stack_trace_line(lines, start_from_line)
	local line = start_from_line

	while line <= lines.line_count do
		local element, first_line = parse_java_stack_trace_line_in_lines(lines, line)

		if element then
			return first_line
		end

		line = line + 1
	end

	return nil
end

---@param lines JavaHelpers.TextLines The lines to search for first line in
---@param current_line integer The line number (1 based) to start from
---@return integer? The first line number (1 based) or nil if no line found
local function find_beginning_of_java_stack_trace_line(lines, current_line)
	local line = current_line
	local beginning_line = nil

	while line >= 1 do
		local element, first_line = parse_java_stack_trace_line_in_lines(lines, line)

		if element then
			beginning_line = first_line
			line = first_line - 1
		else
			local line_text = lines.get_line_text(line)

			if not is_more_line(line_text) and not is_caused_by_line(line_text) then
				return beginning_line
			end

			line = line - 1
		end
	end

	return beginning_line
end

---@param stack_trace JavaHelpers.StackTraceElement[]
---@return JavaHelpers.StackTraceElement[] reduced
local function reduce_stack_trace(stack_trace)
	local reduced = {}
	local prev_element = nil

	for _, element in ipairs(stack_trace) do
		if not is_same_stack_track_element(element, prev_element) then
			table.insert(reduced, element)
			prev_element = element
		end
	end

	return reduced
end

--- Parses all contiguous stack trace lines around the cursor
--- @param lines JavaHelpers.TextLines
--- @param cursor_line integer The line around which we should try to parse a stack trace from (looks up and down)
--- @return JavaHelpers.StackTraceElement[]? stack_trace The parsed stack trace
--- @return integer? cursor_line_stack_index The 1 based index where the current line was found in the stack trace
--- @return integer? first_line The first is the source text where the stack trace started
--- @return integer? last_line The last is the source text where the stack trace finished
local function parse_java_stack_around_line(lines, cursor_line)
	local first_line_in_source = find_beginning_of_java_stack_trace_line(lines, cursor_line)

	if not first_line_in_source then
		return nil, nil
	end

	local total_lines = lines.line_count
	local stack_elements = {}
	local insert_index = 1
	local prev_element = nil
	local current_line = first_line_in_source
	---
	---@type JavaHelpers.StackTraceElement
	local cursor_line_element = nil
	local last_line_in_source = first_line_in_source
	local is_done = false

	while not is_done and current_line <= total_lines do
		local element, first_line, last_line = parse_java_stack_trace_line_in_lines(lines, current_line)

		if element then
			assert(first_line)
			assert(last_line)

			if not is_same_stack_track_element(element, prev_element) then
				table.insert(stack_elements, insert_index, element)
				insert_index = insert_index + 1
				prev_element = element
			end

			if cursor_line >= first_line and cursor_line <= last_line then
				cursor_line_element = element
			end

			current_line = last_line + 1
			last_line_in_source = last_line
		else
			local line_text = lines.get_line_text(current_line)

			if is_caused_by_line(line_text) then
				insert_index = 1
				prev_element = nil
				last_line_in_source = current_line
				current_line = current_line + 1
			elseif is_more_line(line_text) then
				last_line_in_source = current_line
				current_line = current_line + 1
			else
				is_done = true
			end
		end
	end

	assert(#stack_elements >= 1)

	stack_elements = reduce_stack_trace(stack_elements)

	assert(#stack_elements >= 1)

	local cursor_line_index = nil

	if cursor_line_element then
		for index, element in ipairs(stack_elements) do
			if is_same_stack_track_element(element, cursor_line_element) then
				cursor_line_index = index
				break
			end
		end

		assert(cursor_line_index)
	end

	return stack_elements, cursor_line_index, first_line_in_source, last_line_in_source
end

---@param client vim.lsp.Client
---@return boolean
local function is_java_client(client)
	return java_ls_names[client.name]
end

---@return clients vim.lsp.Client[]
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

	log.trace("Found Java source file for class " .. full_class_name .. ": " .. file_path)
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

	log.trace("Finding Java source file for class " .. full_class_name .. " in expected file " .. expected_file_name)

	local clients = get_java_clients()

	if #clients == 0 then
		return nil, "No Java clients found for resolving stack trace navigation"
	end

	local params = { query = full_class_name }
	local error = nil

	for _, client in ipairs(clients) do
		local err, result = utils.await_lsp_request(client, "workspace/symbol", params)

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

---@param element JavaHelpers.StackTraceElement
--- @return string? path The found path or nil
--- @return string? error The error message or nil
local function find_java_source_file_for_element(element)
	local class_name = get_outer_class_name(element.class_name)

	if not class_name then
		local message = "Could not get outer class name for " .. element.class_name
		log.trace(message)
		return nil, message
	end

	return find_java_source_file_for_class(class_name, element.file_name)
end

---@param element JavaHelpers.StackTraceElement
local function go_to_java_stack_trace_element(element)
	log.trace("Go to " .. element.class_name .. " " .. element.file_name .. " " .. element.line_number)

	local file_path, error = find_java_source_file_for_element(element)

	if file_path then
		utils.go_to_file_and_line_number(file_path, element.line_number)
	else
		log.error(error)
	end
end

---Converts a stack strace back to its original text format
---@param stack_trace JavaHelpers.StackTraceElement[]
---@return string
local function stack_trace_to_string(stack_trace)
	local result = ""

	for _, element in ipairs(stack_trace) do
		result = result
			.. "at "
			.. element.class_name
			.. "."
			.. element.method_name
			.. "("
			.. element.file_name
			.. ":"
			.. element.line_number
			.. ")\n"
	end

	return result
end

---@param input string The text to be deobfuscated
---@param mapping_file string The mapping file to use
---@return string? output
local function deobfuscate_string(input, mapping_file)
	log.trace("About to deobfuscate:\n" .. input)

	local result = utils.await_filter_text_with_command(input, { config.deobfuscate_command, mapping_file })
	local stdout = result.stdout

	if #stdout == 0 then
		log.trace("Deobfuscation command " .. config.deobfuscate_command .. " produced no output")
		return nil
	end

	log.trace("Deobfuscated:\n" .. stdout)

	return stdout
end

---@param stack_trace JavaHelpers.StackTraceElement[]
---@param mapping_file string The mapping file to use
---@retern JavaStackTraceElement[]? deobfuscate_stack_trace
local function deobfuscate_stack_trace(stack_trace, mapping_file)
	local text = stack_trace_to_string(stack_trace)

	local deobfuscated_stack_string = deobfuscate_string(text, mapping_file)

	if not deobfuscated_stack_string then
		return nil
	end

	local deobfuscated_lines = utils.create_text_lines_from_string(deobfuscated_stack_string)
	local deobfuscated_stack_trace = parse_java_stack_around_line(deobfuscated_lines, 1)

	if not deobfuscated_stack_trace then
		log.trace("Could not parse deobfuscated stack trace:\n" .. deobfuscated_stack_string)
	else
		log.trace("Successfully parsed deobfuscated stack trace:\n" .. stack_trace_to_string(deobfuscated_stack_trace))
	end

	return deobfuscated_stack_trace
end

---@param lines JavaHelpers.TextLines
---@param cursor_line integer
--- @return JavaHelpers.StackTraceElement[]?
--- @return integer? index The 1 based index where the current line was found in the stack trace
--- @return integer? first_line The first is the source text where the stack trace started
--- @return integer? last_line The last is the source text where the stack trace finished
local function deobfuscate_and_parse(lines, cursor_line)
	local stack_trace, index = parse_java_stack_around_line(lines, cursor_line)

	if not current_obfusction_file or not stack_trace then
		return stack_trace, index
	end

	local deobfuscated_stack_trace = deobfuscate_stack_trace(stack_trace, current_obfusction_file)

	if #stack_trace ~= #deobfuscated_stack_trace then
		index = 1
	end

	return deobfuscated_stack_trace, index
end

---@param text string The text to be parsed and used as a stack trace
---@return JavaHelpers.StackTraceElement[]? stack_trace The parsed Java stack trace elements
local function parse_java_stack_trace_from_text(text)
	local lines = utils.create_text_lines_from_string(text)
	local first_line = find_first_java_stack_trace_line(lines, 1)

	if not first_line then
		return nil
	end

	local stack_trace = deobfuscate_and_parse(lines, first_line)

	assert(stack_trace)

	return stack_trace
end

---@param name string The name of the register to use as the source of a stack trace
---@return JavaHelpers.StackTraceElement[]? stack_trace The parsed Java stack trace elements
local function parse_java_stack_track_from_register(name)
	assert(#name == 1)

	local text = vim.fn.getreg(name)

	return parse_java_stack_trace_from_text(text)
end

---@param win integer The window id
--- @return JavaHelpers.StackTraceElement[]?
--- @return integer? cursor_line_stack_index The 1 based index where the current line was found in the stack trace
--- @return integer? first_line The first is the source text where the stack trace started
--- @return integer? last_line The last is the source text where the stack trace finished
local function parse_java_stack_around_cursor(win)
	local bufnr = vim.api.nvim_win_get_buf(win)
	local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
	local lines = utils.create_text_lines_from_buffer(bufnr)

	return deobfuscate_and_parse(lines, cursor_line)
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
			return
		end

		log.trace(
			"Setup stack trace from register "
				.. register_name_or_text_to_parse
				.. ":\n"
				.. stack_trace_to_string(current_loaded_stack_trace)
		)

		return
	end

	if register_name_or_text_to_parse and #register_name_or_text_to_parse > 1 then
		current_loaded_stack_trace = parse_java_stack_trace_from_text(register_name_or_text_to_parse)
		current_loaded_stack_trace_index = 1

		if not current_loaded_stack_trace then
			log.error("Could not lead stack trace from supplied text " .. register_name_or_text_to_parse)
			return
		end

		log.trace(
			"Setup stack trace from string "
				.. register_name_or_text_to_parse
				.. ":\n"
				.. stack_trace_to_string(current_loaded_stack_trace)
		)
		return
	end

	local stack_trace, current_index = parse_java_stack_around_cursor(0)

	if stack_trace then
		current_loaded_stack_trace = stack_trace

		log.trace(
			"Setup stack trace from cursor "
				.. register_name_or_text_to_parse
				.. ":\n"
				.. stack_trace_to_string(current_loaded_stack_trace)
		)

		if current_index then
			current_loaded_stack_trace_index = current_index
		else
			current_loaded_stack_trace_index = 1
		end
	end
end

---@param new_pos_callback function() : integer
local function navigate_current_stack_trace(new_pos_callback)
	if not current_loaded_stack_trace then
		log.error("No Java stack trace found for navigation")
		return
	end

	log.trace("Navigationg stack trace:\n" .. stack_trace_to_string(current_loaded_stack_trace))

	assert(#current_loaded_stack_trace >= 1)
	assert(current_loaded_stack_trace_index >= 1)
	assert(current_loaded_stack_trace_index <= #current_loaded_stack_trace)

	local new_pos = new_pos_callback()

	assert(new_pos >= 1)
	assert(new_pos <= #current_loaded_stack_trace)

	local element = current_loaded_stack_trace[new_pos]

	assert(element ~= nil)

	current_loaded_stack_trace_index = new_pos

	go_to_java_stack_trace_element(element)
end

---@param f function()
local function run_in_bg(f)
	local co = coroutine.create(f)

	coroutine.resume(co)
end

---@param register_name_or_text_to_parse string? If a single character then defines the register name, if multiple characters then will parse trhe supplied text, if nil or empty then uses the text around the current cursor position
function M.go_to_current_java_stack_trace_line(register_name_or_text_to_parse)
	run_in_bg(function()
		setup_stack_trace(register_name_or_text_to_parse)

		navigate_current_stack_trace(function()
			return current_loaded_stack_trace_index
		end)
	end)
end

---@param register_name_or_text_to_parse string? If a single character then defines the register name, if multiple characters then will parse trhe supplied text, if nil or empty then uses the text around the current cursor position
function M.go_to_bottom_of_stack_trace(register_name_or_text_to_parse)
	run_in_bg(function()
		setup_stack_trace(register_name_or_text_to_parse)

		navigate_current_stack_trace(function()
			return 1
		end)
	end)
end

---@param register_name_or_text_to_parse string? If a single character then defines the register name, if multiple characters then will parse trhe supplied text, if nil or empty then uses the text around the current cursor position
function M.go_to_top_of_stack_trace(register_name_or_text_to_parse)
	run_in_bg(function()
		setup_stack_trace(register_name_or_text_to_parse)

		navigate_current_stack_trace(function()
			return #current_loaded_stack_trace
		end)
	end)
end

function M.go_up_java_stack_trace()
	run_in_bg(function()
		navigate_current_stack_trace(function()
			if current_loaded_stack_trace_index == #current_loaded_stack_trace then
				log.info("At top of stack trace")
				return #current_loaded_stack_trace
			else
				return current_loaded_stack_trace_index + 1
			end
		end)
	end)
end

function M.go_down_java_stack_trace()
	run_in_bg(function()
		navigate_current_stack_trace(function()
			if current_loaded_stack_trace_index == 1 then
				log.info("At bottom of stack trace")
				return 1
			else
				return current_loaded_stack_trace_index - 1
			end
		end)
	end)
end

---@param element JavaHelpers.StackTraceElement
---@return table? item
local function java_stack_trace_element_to_quickfix_item(element)
	local path, error = find_java_source_file_for_element(element)

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

---@param stack_trace JavaHelpers.StackTraceElement[]
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

---@param stack_trace JavaHelpers.StackTraceElement[]
local function send_java_stack_trace_to_quickfix_list(stack_trace)
	local items = java_stack_trace_to_quickfix_items(stack_trace)

	if items then
		log.info("Stack trace sent to quickfix list")
		vim.fn.setqflist(items, "r")
	end
end

---@param register_name_or_text_to_parse string? If a single character then defines the register name, if multiple characters then will parse trhe supplied text, if nil or empty then uses the text around the current cursor position
function M.send_java_stack_trace_to_quickfix_list(register_name_or_text_to_parse)
	run_in_bg(function()
		setup_stack_trace(register_name_or_text_to_parse)

		if not current_loaded_stack_trace then
			log.error("No Java stack trace found to send to quickfix list")
			return
		end

		send_java_stack_trace_to_quickfix_list(current_loaded_stack_trace)
	end)
end

---@param element JavaHelpers.StackTraceElement
---@param index integer
---@return table? snacks_item
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

---@param stack_trace JavaHelpers.StackTraceElement[]
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

---@param stack_trace JavaHelpers.StackTraceElement[]
---@param initially_selected integer
local function pick_java_stack_trace_line(stack_trace, initially_selected)
	if #stack_trace == 1 then
		go_to_java_stack_trace_element(stack_trace[1])
		return
	end

	local items = java_stack_trace_to_snacks_items(stack_trace)

	if not items then
		return
	end

	local max_class_and_method_length = 1

	for _, item in ipairs(items) do
		---@type JavaHelpers.StackTraceElement
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

---@param register_name_or_text_to_parse string? If a single character then defines the register name, if multiple characters then will parse trhe supplied text, if nil or empty then uses the text around the current cursor position
function M.pick_java_stack_trace_line(register_name_or_text_to_parse)
	run_in_bg(function()
		setup_stack_trace(register_name_or_text_to_parse)

		if not current_loaded_stack_trace then
			log.error("No Java stack trace for picking")
			return
		end

		pick_java_stack_trace_line(current_loaded_stack_trace, current_loaded_stack_trace_index)
	end)
end

local function select_obfuscation_file()
	local file = utils.await_pick_file("Obfuscation File: ", config.obfuscation_mappings_dir)

	if file then
		current_obfusction_file = file
		log.trace("User chose obfuscation file " .. file)
	else
		log.trace("User canceled obfuscation file selection")
	end
end

---@param file_path string? File path to select or nil or empty string if should ask the user to select a file
function M.select_obfuscation_file(file_path)
	if file_path and #file_path > 0 then
		current_obfusction_file = file_path
		return
	end

	run_in_bg(function()
		select_obfuscation_file()
	end)
end

local function select_obfuscation_file_if_needed()
	if not current_obfusction_file then
		select_obfuscation_file()
	end
end

---@param register_name string? Register name or nil to deobfuscate under the cursor
local function deobfuscate_register(register_name)
	select_obfuscation_file_if_needed()

	if not current_obfusction_file then
		log.trace("No obfuscation file selected")
		return
	end

	log.trace("Deobfuscating register " .. register_name .. " using mapping file " .. current_obfusction_file)

	local text = vim.fn.getreg(register_name)
	local deobfuscated = deobfuscate_string(text, current_obfusction_file)

	if deobfuscated then
		vim.fn.setreg(register_name, deobfuscated)

		log.info("Deobfuscated '" .. register_name .. "' register")
	end
end

---@param win integer The window id or 0 for current
local function deobfuscate_at_cursor(win)
	select_obfuscation_file_if_needed()

	if not current_obfusction_file then
		log.trace("No obfuscation file selected")
		return
	end

	log.trace("Deobfuscating at cursor position")

	local bufnr = vim.api.nvim_win_get_buf(win)
	local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
	local lines = utils.create_text_lines_from_buffer(bufnr)

	local _, _, first_line, last_line = parse_java_stack_around_line(lines, cursor_line)

	if not first_line then
		log.error("No stack trace found at cursor")
		return
	end

	assert(last_line)
	assert(last_line >= first_line)

	log.trace("Found stack trace around cursor for line range " .. first_line .. " to " .. last_line)

	local text = utils.line_range_as_string(lines, first_line, last_line)
	local deobfuscated = deobfuscate_string(text, current_obfusction_file)

	if not deobfuscated then
		return
	end

	utils.replace_buffer_line_range_with_string(bufnr, first_line, last_line, deobfuscated)
end

---@param register_name string? Register name or nil to deobfuscate under the cursor
function M.deobfuscate(register_name)
	if register_name and #register_name > 1 then
		log.error("Invalid register name " .. register_name)
		return
	end

	run_in_bg(function()
		if register_name and #register_name == 1 then
			deobfuscate_register(register_name)
		else
			deobfuscate_at_cursor(0)
		end
	end)
end

---@param lines JavaHelpers.TextLines
---@param cursor_line integer
---@return integer? next_start_line
local function find_next_stack_trace(lines, cursor_line)
	local line_count = lines.line_count
	local line_to_start_from = cursor_line

	-- Go past the end of the current stack trace

	while line_to_start_from < line_count do
		local line_text = lines.get_line_text(line_to_start_from)

		if is_caused_by_line(line_text) or is_more_line(line_text) then
			line_to_start_from = line_to_start_from + 1
		else
			local element, _, last_line = parse_java_stack_trace_line_in_lines(lines, line_to_start_from)

			if element then
				line_to_start_from = last_line + 1
			else
				break
			end
		end
	end

	local line = line_to_start_from

	while line < line_count do
		local line_text = lines.get_line_text(line)

		if is_caused_by_line(line_text) or is_more_line(line_text) then
			line = line + 1
		else
			local element, first_line = parse_java_stack_trace_line_in_lines(lines, line)

			if element then
				return first_line
			end

			line = line + 1
		end
	end

	return nil
end

-- Finds the next stack trace after the current cursor position
---@param win integer
function M.go_to_next_stack_trace(win)
	local bufnr = vim.api.nvim_win_get_buf(win)
	local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
	local lines = utils.create_text_lines_from_buffer(bufnr)
	local line_to_go_to = find_next_stack_trace(lines, cursor_line)

	if not line_to_go_to then
		log.error("No more Java stack traces found")
		return
	end

	vim.api.nvim_win_set_cursor(win, { line_to_go_to, 0 })
end

---@param lines JavaHelpers.TextLines
---@param cursor_line integer
---@return integer? next_start_line
local function find_prev_stack_trace(lines, cursor_line)
	local line_count = lines.line_count
	local line_to_start_from = cursor_line

	-- Go past the beginning of the current stack trace

	while line_to_start_from > 1 do
		local line_text = lines.get_line_text(line_to_start_from)

		if is_caused_by_line(line_text) or is_more_line(line_text) then
			line_to_start_from = line_to_start_from - 1
		else
			local element, first_line = parse_java_stack_trace_line_in_lines(lines, line_to_start_from)

			if element then
				line_to_start_from = first_line - 1
			else
				break
			end
		end
	end

	log.trace("Searching for previous stack trace from line " .. line_to_start_from)

	-- Find last line of previous stack trace

	local line = line_to_start_from
	local last_line_of_prev_stack_trace = nil

	while line >= 1 do
		local line_text = lines.get_line_text(line)

		if is_caused_by_line(line_text) or is_more_line(line_text) then
			line = line - 1
		else
			local element, first_line = parse_java_stack_trace_line_in_lines(lines, line)

			if element then
				last_line_of_prev_stack_trace = first_line
				break
			end

			line = line - 1
		end
	end

	if not last_line_of_prev_stack_trace then
		log.trace("Did not find last line of previous stack trace")
		return nil
	end

	log.trace("Last line of previous stack trace is " .. last_line_of_prev_stack_trace)

	local first_line_of_prev_stack_trace = last_line_of_prev_stack_trace
	line = last_line_of_prev_stack_trace

	while line >= 1 do
		local line_text = lines.get_line_text(line)

		if is_caused_by_line(line_text) or is_more_line(line_text) then
			line = line - 1
		else
			local element, first_line = parse_java_stack_trace_line_in_lines(lines, line)

			if element then
				first_line_of_prev_stack_trace = first_line
				line = first_line - 1
			else
				break
			end
		end
	end

	return first_line_of_prev_stack_trace
end

-- Finds the next stack trace after the current cursor position
---@param win integer
function M.go_to_prev_stack_trace(win)
	local bufnr = vim.api.nvim_win_get_buf(win)
	local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
	local lines = utils.create_text_lines_from_buffer(bufnr)
	local line_to_go_to = find_prev_stack_trace(lines, cursor_line)

	if not line_to_go_to then
		log.error("No previous Java stack trace found")
		return
	end

	vim.api.nvim_win_set_cursor(win, { line_to_go_to, 0 })
end

---@param opts JavaHelpers.StackTraceConfig? User-provided configuration to override defaults.
function M.setup(opts)
	log.trace("Setup stack trace with options " .. vim.inspect(opts))

	config = vim.tbl_deep_extend("force", default_config, opts or {})

	log.trace("Stack trace setup with options " .. vim.inspect(config))

	vim.api.nvim_create_user_command("JavaHelpersGoToStackTraceLine", function(command_opts)
		M.go_to_current_java_stack_trace_line(command_opts.args)
	end, {
		desc = "Go to line in Java stack",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("JavaHelpersPickStackTraceLine", function(command_opts)
		M.pick_java_stack_trace_line(command_opts.args)
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

	vim.api.nvim_create_user_command("JavaHelpersGoToBottomOfStackTrace", function(command_opts)
		M.go_to_bottom_of_stack_trace(command_opts.args)
	end, {
		desc = "Go to bottom of Java stack trace",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("JavaHelpersGoToTopOfStackTrace", function(command_opts)
		M.go_to_top_of_stack_trace(command_opts.args)
	end, {
		desc = "Go to top of Java stack trace",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("JavaHelpersGoToNextStackTrace", function()
		M.go_to_next_stack_trace(0)
	end, {
		desc = "Go to next Java stack trace",
	})

	vim.api.nvim_create_user_command("JavaHelpersGoToPrevStackTrace", function()
		M.go_to_prev_stack_trace(0)
	end, {
		desc = "Go to previous Java stack trace",
	})

	vim.api.nvim_create_user_command("JavaHelpersSendStackTraceToQuickfix", function(command_opts)
		M.send_java_stack_trace_to_quickfix_list(command_opts.args)
	end, {
		desc = "Send Java stack trace to Quickfix List",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("JavaHelpersDeobfuscate", function(command_opts)
		M.deobfuscate(command_opts.args)
	end, {
		desc = "Deobfuscate stack trace",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("JavaHelpersSelectObfuscationFile", function(command_opts)
		M.select_obfuscation_file(command_opts.args)
	end, {
		desc = "Select obfuscation file",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("JavaHelpersForgetObfuscationFile", function()
		current_obfusction_file = nil
	end, {
		desc = "Forget obfuscation file",
	})
end

return M
