local M = {}

local log = require("plenary.log").new({ plugin = "java-helpers", level = "trace" })
M.log = log

local function can_window_switch_buffers(win)
	return not vim.wo[win].winfixbuf
end

local function is_window_editing_a_normal_buffer(win)
	local buf = vim.api.nvim_win_get_buf(win)
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })

	return buftype == ""
end

---Tries to find an existing window that should be used for editing a file
---@return integer? win
local function find_editable_window()
	local current_win = vim.api.nvim_get_current_win()

	if can_window_switch_buffers(current_win) and is_window_editing_a_normal_buffer(current_win) then
		return current_win
	end

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if can_window_switch_buffers(win) and is_window_editing_a_normal_buffer(win) then
			return win
		end
	end

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if can_window_switch_buffers(win) then
			return win
		end
	end

	return nil
end

---@return boolean success
local function select_editable_window()
	local win = find_editable_window()

	if not win then
		return false
	end

	vim.api.nvim_set_current_win(win)
	return true
end

---@param file_path string
---@param line_number integer 1 based line number
---@param col integer? 0 based column
function M.go_to_file_and_line_number(file_path, line_number, col)
	if not select_editable_window() then
		log.error("Could not find an editable window to use to go to line number")
		return
	end

	if not col then
		col = 0
	end

	local bufnr = vim.fn.bufadd(file_path)
	vim.fn.bufload(bufnr)

	vim.api.nvim_set_current_buf(bufnr)

	vim.api.nvim_win_set_cursor(0, { line_number, col })
end

--- @param str string
--- @param ending string
--- @return boolean
function string.ends_with(str, ending)
	return ending == "" or str:sub(-#ending) == ending
end

---@param java_source_code string
---@return string | nil
local function get_package_from_java_source_code(java_source_code)
	return java_source_code:match("package%s+([^;]+);")
end

--- @param buffer_id integer
--- @return string | nil source_dir_path
--- @return string | nil package_name
function M.determine_source_directory_and_package_from_buffer(buffer_id)
	local path = vim.api.nvim_buf_get_name(buffer_id)

	if not path:ends_with(".java") then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(buffer_id, 0, -1, true)

	for _, line in ipairs(lines) do
		local package_name = get_package_from_java_source_code(line)

		if package_name then
			local buffer_dir = vim.fn.fnamemodify(path, ":p:h")

			return buffer_dir, package_name
		end
	end
end

---Finds the line and column of the start of the suppied substring in the given text
---@param text string
---@param substring string
---@return integer | nil line Line number (1 based)
---@return integer | nil column Column number (0 based)
function M.find_line_col(text, substring)
	-- Split text into lines
	local lines = vim.split(text, "\n", { plain = true })

	for line_num, line_text in ipairs(lines) do
		local col = string.find(line_text, substring, 1, true) -- plain text search
		if col then
			col = col - 1

			return line_num, col
		end
	end

	return nil, nil
end

---@return table|nil picker The snacks picker that is for the supplied buffer
local function get_snacks_explorer_for_buffer(buf)
	local file_type = vim.bo[buf].filetype

	if file_type ~= "snacks_picker_list" then
		return nil
	end

	local has_snacks, Snacks = pcall(require, "snacks")

	if not has_snacks then
		return nil
	end

	for _, picker in ipairs(Snacks.picker.get({ source = "explorer" })) do
		if picker and picker.layout.wins.list.buf == buf then
			return picker
		end
	end

	return nil
end

---Determines the current directory selected in Snacks explorer or nil if none
---@param buf integer The buffer number to check if it's an oil buffer or not
---@return string|nil dir_path The path to the current directory in the snacks picker
local function get_snacks_explorer_current_dir(buf)
	local picker = get_snacks_explorer_for_buffer(buf)

	if picker then
		local dir = picker:dir()

		if dir then
			return vim.fs.normalize(dir)
		end
	end

	return nil
end

---@param buf integer The buffer number to check if it's an oil buffer or not
---@return string|nil dir_path The path to the current directory in the oil buffer or nil if the buffer is not an oil buffer.
local function get_mini_files_current_dir(buf)
	local file_type = vim.bo[buf].filetype

	if file_type ~= "minifiles" then
		return nil
	end

	local buffer_name = vim.api.nvim_buf_get_name(buf)
	local regex = "minifiles://%d+/(.+)"

	local path = buffer_name:match(regex)

	if not path or #path == 0 then
		log.error("Could not parse minifiles buffer name: " .. buffer_name)
		return nil
	end

	return path
end

---@param buf integer The buffer number to check if it's an oil buffer or not
---@return string|nil dir_path The path to the current directory in the oil buffer or nil if the buffer is not an oil buffer.
local function get_oil_current_dir(buf)
	local file_type = vim.bo[buf].filetype

	if file_type ~= "oil" then
		return nil
	end

	local filepath = vim.api.nvim_buf_get_name(buf)
	local prefix = "oil://"

	if not filepath:sub(1, #prefix) == prefix then
		log.error("File path for oil buffer does not start with " .. prefix)
		return nil
	end

	return vim.fn.fnamemodify(filepath:sub(#prefix + 1), ":p:h")
end

---If the supplied path is a directory then returns that otherwise if it is a file then the directory the file is inside
---@param path string The path name
---@return string
local function get_dir(path)
	-- Make path absolute
	local abs_path = vim.fn.fnamemodify(path, ":p")

	-- Check if it's a directory
	if vim.fn.isdirectory(abs_path) == 1 then
		return abs_path -- keep directory as-is
	else
		-- It's a file, return parent directory
		return vim.fn.fnamemodify(abs_path, ":h")
	end
end

---@return string|nil
local function get_neo_tree_current_dir_impl()
	local manager = require("neo-tree.sources.manager")

	local state = manager.get_state("filesystem")
	local node = state.tree:get_node()
	local path = node:get_id()

	if path then
		return get_dir(path)
	end

	return nil
end

---@param buf integer The buffer number to check if it's a neo-tree or not
---@return string|nil dir_path The path to the current directory in neo tree or nil if the buffer is not a neo tree buffer.
local function get_neo_tree_current_dir(buf)
	local file_type = vim.bo[buf].filetype

	if file_type ~= "neo-tree" then
		return nil
	end

	local ok, dir = pcall(get_neo_tree_current_dir_impl)

	if not ok then
		log.error("Could not get current directory in neo tree: " .. tostring(dir))
		return nil
	end

	return dir
end

-- Gets the current directory in an intelligent way.
-- If the user is focused in file explorer then it retuns the path to the current directory that is selected there.
-- Otherwise, if the user is editing a file then it uses the current diretory of that file.
-- If none of those work then it returns vim.fn.getcwd()
--- @return string
function M.get_current_directory()
	local buf = vim.api.nvim_get_current_buf()

	if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
		local dir = get_snacks_explorer_current_dir(buf)

		if dir then
			return dir
		end

		dir = get_neo_tree_current_dir(buf)

		if dir then
			return dir
		end

		dir = get_mini_files_current_dir(buf)

		if dir then
			return dir
		end

		dir = get_oil_current_dir(buf)

		if dir then
			return dir
		end

		if vim.bo[buf].buftype == "" then
			local filepath = vim.api.nvim_buf_get_name(buf)

			if filepath and filepath ~= "" then
				return vim.fn.fnamemodify(filepath, ":p:h")
			end
		end
	end

	return vim.fn.getcwd()
end

-- Performs an async request to an LSP server. Must be called from a coroutine.
---@param client vim.lsp.Client The LSP client to use
---@param request string The request to invoke
---@param params table Parameters to the request
---@return string? err
---@return any result
function M.await_lsp_request(client, request, params)
	local co = coroutine.running()

	log.trace(
		"Sending request to LSP server " .. client.name .. ": " .. request .. " with params " .. vim.inspect(params)
	)

	assert(co, "request_async must be called from within a coroutine")

	local request_id = client.request(request, params, function(err, result)
		vim.schedule(function()
			coroutine.resume(co, err, result)
		end)
	end)

	if not request_id then
		local message = "Could not send request to LSP server"
		log.error(message)
		return message, nil
	end

	local err, result = coroutine.yield()

	if err then
		return vim.inspect(err), nil
	end

	return nil, result
end

---@param input_text string
---@param command string[]
---@return vim.SystemCompleted
function M.await_filter_text_with_command(input_text, command)
	local co = coroutine.running()

	assert(co, "await_filter_text_with_command must be called within a coroutine")

	vim.system(command, {
		stdin = input_text,
		text = true,
	}, function(r)
		vim.schedule(function()
			coroutine.resume(co, r)
		end)
	end)

	return coroutine.yield()
end

---@param prompt string
---@param directory string?
---@return string? selected_file
function M.await_pick_file(prompt, directory)
	local co = coroutine.running()

	assert(co, "await_pick_file must be called within a coroutine")

	if not directory then
		directory = M.get_current_directory()
	end

	log.trace("Asking user to pick a file. Prompt = " .. prompt .. " dir = " .. directory)

	require("snacks.picker").files({
		dirs = { directory },
		prompt = prompt,
		confirm = function(picker, item)
			picker:close()

			vim.schedule(function()
				if item then
					log.trace("User chose file " .. item.file)
					coroutine.resume(co, item.file)
				else
					log.trace("User canceled file selection")
					coroutine.resume(co, nil)
				end
			end)
		end,
	})

	return coroutine.yield()
end

---@class JavaHelpers.TextLines
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
---@return JavaHelpers.TextLines
function M.create_text_lines_from_buffer(bufnr)
	return {
		line_count = get_buffer_line_count(bufnr),
		get_line_text = function(line)
			return get_buffer_line(bufnr, line)
		end,
	}
end

---@param lines_array string[]
---@return JavaHelpers.TextLines
function M.create_text_lines_from_array(lines_array)
	return {
		line_count = #lines_array,
		get_line_text = function(line)
			return lines_array[line]
		end,
	}
end

---@param text string
---@return string[] lines
function M.split_lines(text)
	return vim.split(text, "\n", { plain = true })
end

---@param text string
function M.create_text_lines_from_string(text)
	local lines = M.split_lines(text)

	return M.create_text_lines_from_array(lines)
end

---@param lines JavaHelpers.TextLines
---@param start_line integer
---@param end_line integer
---@return string[] result
function M.line_range_as_string_array(lines, start_line, end_line)
	local result = {}

	for line_number = start_line, end_line, 1 do
		local line = lines.get_line_text(line_number)

		table.insert(result, line)
	end

	return result
end

---@param lines JavaHelpers.TextLines
---@param start_line integer
---@param end_line integer
---@return string result
function M.line_range_as_string(lines, start_line, end_line)
	local result = ""

	for line_number = start_line, end_line, 1 do
		local line = lines.get_line_text(line_number)

		result = result .. line .. "\n"
	end

	return result
end

---@param bufnr integer
---@param from_line integer
---@param to_line integer
---@param lines string[]
function M.replace_buffer_line_range_with_lines_array(bufnr, from_line, to_line, lines)
	vim.api.nvim_buf_set_lines(bufnr, from_line - 1, to_line, false, lines)
end

---@param bufnr integer
---@param from_line integer
---@param to_line integer
---@param lines JavaHelpers.TextLines
function M.replace_buffer_line_range_with_lines(bufnr, from_line, to_line, lines)
	local lines_array = M.line_range_as_string_array(lines, 1, lines.line_count)

	return M.replace_buffer_line_range_with_lines_array(bufnr, from_line, to_line, lines_array)
end

---@param bufnr integer
---@param from_line integer
---@param to_line integer
---@param lines string
function M.replace_buffer_line_range_with_string(bufnr, from_line, to_line, lines)
	local lines_array = M.split_lines(lines)

	return M.replace_buffer_line_range_with_lines_array(bufnr, from_line, to_line, lines_array)
end

return M
