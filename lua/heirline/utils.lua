local M = {}

---Get highlight properties for a given highlight name
---@param name string
---@return table
function M.get_highlight(name)
    local hl = vim.api.nvim_get_hl_by_name(name, vim.o.termguicolors)
    if vim.o.termguicolors then
        hl.fg = hl.foreground
        hl.bg = hl.background
        hl.sp = hl.special
        hl.foreground = nil
        hl.background = nil
        hl.special = nil
    else
        hl.ctermfg = hl.foreground
        hl.ctermbg = hl.background
        hl.foreground = nil
        hl.background = nil
        hl.special = nil
    end
    return hl
end

---Copy the given component, merging its fields with `with`
---@param block table
---@param with? table
---@return table
function M.clone(block, with)
    return vim.tbl_deep_extend("force", block, with or {})
end

---Surround component with separators and adjust coloring
---@param delimiters table<string> { "left", "right" } delimiters
---@param color string | function
---@param component table
---@return table
function M.surround(delimiters, color, component)
    component = M.clone(component)

    local surround_color = function(self)
        if type(color) == "function" then
            return color(self)
        else
            return color
        end
    end

    return {
        {
            provider = delimiters[1],
            hl = function(self)
                local s_color = surround_color(self)
                if s_color then
                    return { fg = s_color }
                end
            end,
        },
        {
            hl = function(self)
                local s_color = surround_color(self)
                if s_color then
                    return { bg = s_color }
                end
            end,
            component,
        },
        {
            provider = delimiters[2],
            hl = function(self)
                local s_color = surround_color(self)
                if s_color then
                    return { fg = s_color }
                end
            end,
        },
    }
end

---return a copy of `destination` component where each `child` in `...`
---(variable arguments) is appended to its children (if any).
---@param destination table
---@vararg table
---@return table
function M.insert(destination, ...)
    local children = { ... }
    local new = M.clone(destination)
    for _, child in ipairs(children) do
        local new_child = M.clone(child)
        table.insert(new, new_child)
    end
    return new
end

---Calculate the length of a format-string
---@param str string
---@return integer
function M.count_chars(str)
    return vim.api.nvim_eval_statusline(str, { winid = 0, maxwidth = 0 }).width
end

---Create a flexible component
---@param priority integer
---@vararg table list of components that should evaluate to shorter strings in descending order.
---@return table
function M.make_flexible_component(priority, ...)
    local new = M.insert({}, ...)

    new.static = {
        _priority = priority,
    }
    new.init = function(self)
        if not vim.tbl_contains(self._flexible_components, self) then
            table.insert(self._flexible_components, self)
        end
        self:set_win_attr("_win_child_index", nil, 1)
        self.pick_child = { self:get_win_attr("_win_child_index") }
    end
    new.restrict = { _win_child_index = true }

    return new
end

local function next_child(self)
    local pi = self:get_win_attr("_win_child_index") + 1
    if pi > #self then
        return false
    end
    self:set_win_attr("_win_child_index", pi)
    return true
end

local function prev_child(self)
    local pi = self:get_win_attr("_win_child_index") - 1
    if pi < 1 then
        return false
    end
    self:set_win_attr("_win_child_index", pi)
    return true
end

local function is_child(child, parent)
    if not (child and parent) then
        return false
    end
    if #child.id <= #parent.id then
        return false
    end
    for i, v in ipairs(parent.id) do
        if child.id[i] ~= v then
            return false
        end
    end
    return true
end

local function group_flexible_components(flexible_components, mode)
    local priority_groups = {}
    local priorities = {}
    local cur_priority
    local prev_component

    for _, component in ipairs(flexible_components) do
        local priority
        if prev_component and is_child(component, prev_component) then
            priority = cur_priority + mode
            -- if mode == -1 then
            --     priority = ec.priority < cur_priority + mode and ec.priority or cur_priority + mode
            -- elseif mode == 1 then
            --     priority = ec.priority > cur_priority + mode and ec.priority or cur_priority + mode
            -- end
        else
            priority = component._priority
        end

        prev_component = component
        cur_priority = priority

        priority_groups[priority] = priority_groups[priority] or {}
        table.insert(priority_groups[priority], component)
        if not priorities[priority] then
            table.insert(priorities, priority)
        end

        local comp = mode == -1 and function(a, b)
            return a < b
        end or function(a, b)
            return a > b
        end
        table.sort(priorities, comp)
    end
    return priority_groups, priorities
end

--- Private function.
---@param flexible_components table
---@param full_width boolean
---@param out string
function M.expand_or_contract_flexible_components(flexible_components, full_width, out)
    if not flexible_components or not next(flexible_components) then
        return
    end

    local winw = (full_width and vim.o.columns) or vim.api.nvim_win_get_width(0)

    local stl_len = M.count_chars(out)

    if stl_len > winw then
        local priority_groups, priorities = group_flexible_components(flexible_components, -1)

        local saved_chars = 0

        for _, p in ipairs(priorities) do
            while true do
                local out_of_components = true
                for _, component in ipairs(priority_groups[p]) do
                    -- try increasing the child index and return success
                    if next_child(component) then
                        out_of_components = false
                        local prev_len = M.count_chars(component:traverse())
                        local cur_len = M.count_chars(component:eval())
                        -- component:clear_tree()
                        -- component._tree[1] = component[component:get_win_attr("_win_child_index")]:traverse()
                        saved_chars = saved_chars + (prev_len - cur_len)
                    end
                end

                if stl_len - saved_chars <= winw then
                    return
                end

                if out_of_components then
                    break
                end
            end
        end
    elseif stl_len < winw then
        local gained_chars = 0

        local priority_groups, priorities = group_flexible_components(flexible_components, 1)

        for _, p in ipairs(priorities) do
            while true do
                local out_of_components = true
                for _, component in ipairs(priority_groups[p]) do
                    if prev_child(component) then
                        out_of_components = false
                        local prev_len = M.count_chars(component:traverse())
                        local cur_len = M.count_chars(component:eval())
                        -- component:clear_tree()
                        gained_chars = gained_chars + (cur_len - prev_len)
                    end
                end

                if stl_len + gained_chars > winw then
                    for _, component in ipairs(priority_groups[p]) do
                        next_child(component)
                        -- here we need to manually reset the component tree, as we are increasing the
                        -- child index but without calling eval (wich should handle that);
                        -- since we went "one index too little", the next-index child tree has been already evaluated
                        -- in the previous loop.
                        component:clear_tree()
                        component._tree[1] = component[component:get_win_attr("_win_child_index")]:traverse()
                    end
                    return
                end
                if out_of_components then
                    break
                end
            end
        end
    end
end

--- Utility function to set component.pick_child on the first child that has a true condition,
--- this must be called within the component init.
---@param component table
function M.pick_child_on_condition(component)
    vim.notify_once(
        [[Heirline: utils.pick_child_on_condition() is deprecated, please use the fallthrough field instead. To retain the same functionality, replace `init = utils.pick_child_on_condition()` with `fallthrough = false`]],
        vim.log.levels.ERROR
    )
    component.pick_child = {}
    for i, child in ipairs(component) do
        if not child.condition or child:condition() then
            table.insert(component.pick_child, i)
            return
        end
    end
end

local function with_cache(func, cache)
    cache = cache or {}
    if not cache.au_id then
        cache.au_id = vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete" }, {
            callback = function()
                for i = 1, #cache do
                    cache[i] = nil
                end
            end,
            desc = "Heirline: release cache for buflist get_bufs()",
        })
    end
    return function()
        if cache and cache[1] ~= nil then
            return cache
        else
            local res = func()
            for i, v in ipairs(res) do
                cache[i] = v
            end
            for i = #res + 1, #cache do
                cache[i] = nil
            end
            return res
        end
    end
end

local function get_bufs()
    return vim.tbl_filter(function(bufnr)
        return vim.api.nvim_buf_get_option(bufnr, "buflisted")
    end, vim.api.nvim_list_bufs())
end

local function bufs_in_tab(tabnr)
    tabnr = tabnr or 0
    local buf_set = {}
    local wins = vim.api.nvim_tabpage_list_wins(tabnr)
    for _, winid in ipairs(wins) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        buf_set[bufnr] = true
    end
    return buf_set
end

--- Make a tablist, rendering all open tabs
--- using `tab_component` as a template.
---@param tab_component table
---@return table
function M.make_tablist(tab_component)
    local tablist = {
        init = function(self)
            local tabpages = vim.api.nvim_list_tabpages()
            for i, tabpage in ipairs(tabpages) do
                local tabnr = vim.api.nvim_tabpage_get_number(tabpage)
                local child = self[i]
                if not (child and child.tabnr == tabnr) then
                    self[i] = self:new(tab_component, i)
                    child = self[i]
                    child.tabnr = tabnr
                end
                if tabpage == vim.api.nvim_get_current_tabpage() then
                    child.is_active = true
                    self.active_child = i
                else
                    child.is_active = false
                end
            end
            if #self > #tabpages then
                for i = #self, #tabpages + 1, -1 do
                    self[i] = nil
                end
            end
        end,
    }
    return tablist
end

-- record how many times users called this function
-- TODO: might be worth it to export the callback and delegate the user to create the next/prev components on_click fields, removing all defaults
local NTABLINES = 0

--- Make a list of buffers, rendering all listed buffers
--- using `buffer_component` as a template.
---@param buffer_component table
---@param left_trunc? table left truncation marker, shown is buffer list is too long
---@param right_trunc? table right truncation marker, shown is buffer list is too long
---@param buf_func? function return a list of <integer> bufnr handlers.
---@return table
function M.make_buflist(buffer_component, left_trunc, right_trunc, buf_func, buf_cache)
    buf_func = buf_func or get_bufs
    buf_func = with_cache(buf_func, buf_cache)

    left_trunc = left_trunc or {
        provider = "<",
    }

    right_trunc = right_trunc or {
        provider = ">",
    }

    NTABLINES = NTABLINES + 1
    left_trunc.on_click = {
        callback = function(self)
            self._buflist[1]._cur_page = self._cur_page - 1
            self._buflist[1]._force_page = true
            vim.cmd("redrawtabline")
        end,
        name = "Heirline_tabline_prev_" .. NTABLINES,
    }

    right_trunc.on_click = {
        callback = function(self)
            self._buflist[1]._cur_page = self._cur_page + 1
            self._buflist[1]._force_page = true
            vim.cmd("redrawtabline")
        end,
        name = "Heirline_tabline_next_" .. NTABLINES,
    }

    local bufferline = {
        static = {
            _left_trunc = left_trunc,
            _right_trunc = right_trunc,
            _cur_page = 1,
            _force_page = false,
        },
        init = function(self)
            -- register the buflist component reference as global statusline attr
            if vim.tbl_isempty(self._buflist) then
                table.insert(self._buflist, self)
            end
            if not self.left_trunc then
                self.left_trunc = self:new(self._left_trunc)
            end
            if not self.right_trunc then
                self.right_trunc = self:new(self._right_trunc)
            end

            if not self._once then
                vim.api.nvim_create_autocmd({ "BufEnter" }, {
                    callback = function()
                        self._force_page = false
                    end,
                    desc = "Heirline release lock for next/prev buttons",
                })
                self._once = true
            end

            self.active_child = false
            local bufs = buf_func()
            bufs = vim.tbl_filter(function(bufnr)
                return vim.api.nvim_buf_is_valid(bufnr)
            end, bufs)
            local visible_buffers = bufs_in_tab()

            for i, bufnr in ipairs(bufs) do
                local child = self[i]
                if not (child and child.bufnr == bufnr) then
                    self[i] = self:new(buffer_component, i)
                    child = self[i]
                    child.bufnr = bufnr
                end

                if bufnr == tonumber(vim.g.actual_curbuf) then
                    child.is_active = true
                    self.active_child = i
                else
                    child.is_active = false
                end

                if visible_buffers[bufnr] then
                    child.is_visible = true
                else
                    child.is_visible = false
                end
            end
            if #self > #bufs then
                for i = #bufs + 1, #self do
                    self[i] = nil
                end
            end
        end,
    }
    return bufferline
end

--- Private function
---@param buflist table
function M.page_buflist(buflist, maxwidth)
    if not buflist or #buflist == 0 then
        return
    end

    local bfl = {}
    maxwidth = maxwidth - 2 -- leave some space for {right,left}_trunc

    local pages = { {} }
    local active_page
    local page_counter = 1
    local page_length = 0
    local active_page_index

    local page = pages[1]
    for _, child in ipairs(buflist) do
        local len = M.count_chars(child:traverse())

        if page_length + len > maxwidth then
            page_length = 0
            page = {}
            table.insert(pages, page)
            page_counter = page_counter + 1
        end

        table.insert(page, child)
        page_length = page_length + len

        if child.is_active then
            active_page = page
            active_page_index = page_counter
        end
    end

    local page_index
    if active_page and not buflist._force_page then
        page = active_page
        page_index = active_page_index
        buflist._cur_page = page_index
    else
        page = pages[buflist._cur_page]
        page_index = buflist._cur_page
    end

    if not page then
        -- print("Invalid page nr.", page_index, 'for', #pages, 'pages')
        return
    end

    if page_index > 1 then
        table.insert(bfl, buflist.left_trunc:eval())
    end

    for _, child in ipairs(page) do
        table.insert(bfl, child:traverse())
    end

    -- table.insert(tbl, "%=")

    if page_index < #pages then
        table.insert(bfl, buflist.right_trunc:eval())
    end
    buflist:clear_tree()
    buflist._tree[1] = table.concat(bfl, "")
end

---ColorScheme callback useful to reset highlights
---@param colors table<string, string|integer>
function M.on_colorscheme(colors)
    colors = colors or {}
    require("heirline").reset_highlights()
    require("heirline").clear_colors()
    require("heirline").load_colors(colors)
    require("heirline").statusline:broadcast(function(self)
        self._win_cache = nil
    end)
end

return M
