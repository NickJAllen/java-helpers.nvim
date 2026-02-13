local M = {}

local log = require("plenary.log").new({ plugin = "java-helpers", level = "info" })
M.log = log

local function can_window_switch_buffers(win)
	return not vim.wo[win].winfixbuf
end

local function is_window_editing_a_normal_buffer(win)
	local buf = vim.api.nvim_win_get_buf(win)
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })

	return buftype == ""
end

local function find_editable_window()
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
	local current_win = vim.api.nvim_get_current_win()

	if can_window_switch_buffers(current_win) and is_window_editing_a_normal_buffer(current_win) then
		return true
	end

	local win = find_editable_window()

	if not win then
		return false
	end

	vim.api.nvim_set_current_win(win)
	return true
end

---@param file_path string
---@param line_number integer
function M.go_to_file_and_line_number(file_path, line_number)
	if not select_editable_window() then
		log.error("Could not find an editable window to use to go to line number")
		return
	end

	local bufnr = vim.fn.bufadd(file_path)
	vim.fn.bufload(bufnr)

	vim.api.nvim_set_current_buf(bufnr)

	vim.api.nvim_win_set_cursor(0, { line_number, 0 })
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
-- If the user is focused in neo-tree then it retuns the path to the current directory that is selected there.
-- If the current buffer is an oil buffer then returns the directory of oil.
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

return M
