--[[
  agent_status.lua - Phát hiện AI coding agent (Claude, Codex, Gemini, Aider,
  OpenCode) đang chạy trong từng pane và trạng thái của nó (working / waiting /
  idle / inactive), lấy cảm hứng từ cách wezterm-agent-deck
  (https://github.com/Eric162/wezterm-agent-deck) hiển thị chấm trạng thái màu
  trên tab, viết lại gọn cho phù hợp với setup Herdr + Catppuccin Macchiato.
--]]
local wezterm = require 'wezterm'

local M = {}

-- Màu theo bảng Catppuccin Macchiato để đồng bộ với color_scheme hiện tại
M.colors = {
    working = '#a6da95', -- green
    waiting = '#eed49f', -- yellow
    idle = '#8aadf4', -- blue
    inactive = '#6e738d' -- overlay0
}

M.icons = {
    working = '●',
    waiting = '◔',
    idle = '○',
    inactive = '◌'
}

M.display_names = {
    claude = 'Claude',
    codex = 'Codex',
    gemini = 'Gemini',
    aider = 'Aider',
    opencode = 'OpenCode'
}

local agents = {
    claude = {
        patterns = {'claude'},
        exe_patterns = {'claude%-code', '/claude$', '^claude$'}
    },
    codex = {
        patterns = {'codex'}
    },
    gemini = {
        patterns = {'gemini'}
    },
    aider = {
        patterns = {'aider'}
    },
    opencode = {
        patterns = {'opencode'}
    }
}

local status_patterns = {
    working = {
        'esc to interrupt', 'ctrl%+c to interrupt', 'thinking', 'pondering', 'processing',
        'analyzing', 'generating', 'writing', 'reading', 'searching', 'running commands',
        'gathering context', 'making edits', 'delegating work', 'planning next steps'
    },
    waiting = {
        'esc to cancel', 'yes, allow once', 'yes, allow always', 'allow once', 'allow always',
        'do you trust', 'continue%?', 'proceed%?', '%(y/n%)', '%[y/n%]', '%(y/N%)', '%[Y/n%]',
        '%(Y/N%)', '%[Y/N%]', 'approve this plan', 'press enter to continue', 'do you want to proceed'
    },
    idle = {'^>%s*$'}
}

-- pane_id -> {agent_type, status, last_update, undetected_since, cooldown_start}
local state = {}
-- pane_id -> {agent = type|nil, ts = epoch_ms}
local detect_cache = {}

local CACHE_TTL_MS = 1500
local GRACE_MS = 5000 -- chờ trước khi coi agent đã thoát hẳn (tránh nhấp nháy)
local COOLDOWN_MS = 2000 -- chờ trước khi chuyển working -> idle (tránh nhấp nháy)

local function matches(str, patterns)
    if not str or str == '' then
        return false
    end
    local s = str:lower()
    for _, p in ipairs(patterns) do
        local ok, found = pcall(string.find, s, p:lower())
        if ok and found then
            return true
        end
    end
    return false
end

local function exe_name(path)
    if not path then
        return ''
    end
    return (path:match '[/\\]([^/\\]+)$' or path):gsub('%.exe$', '')
end

local function detect_agent_type(pane)
    local pid = pane:pane_id()
    local now = os.time() * 1000
    local cached = detect_cache[pid]
    if cached and (now - cached.ts) < CACHE_TTL_MS then
        return cached.agent
    end

    local agent = nil
    local ok, info = pcall(function()
        return pane:get_foreground_process_info()
    end)
    if ok and info then
        local exe = exe_name(info.executable or '')
        local argv = table.concat(info.argv or {}, ' ')
        for name, cfg in pairs(agents) do
            if matches(exe, cfg.patterns) or matches(argv, cfg.patterns) or
                (cfg.exe_patterns and matches(info.executable or '', cfg.exe_patterns)) then
                agent = name
                break
            end
        end
    end

    if not agent then
        local ok2, title = pcall(function()
            return pane:get_title()
        end)
        if ok2 and title then
            for name, cfg in pairs(agents) do
                if matches(title, cfg.patterns) then
                    agent = name
                    break
                end
            end
        end
    end

    detect_cache[pid] = {
        agent = agent,
        ts = now
    }
    return agent
end

local function strip_ansi(text)
    if not text then
        return ''
    end
    local result = text:gsub('\27%[[0-9;]*[A-Za-z]', '')
    result = result:gsub('\27%].-\7', '')
    result = result:gsub('\r', '')
    return result
end

local function detect_pane_status(pane, agent_type)
    if not agent_type then
        return 'inactive'
    end
    local ok, text = pcall(function()
        return pane:get_lines_as_text(60)
    end)
    if not ok or not text or text == '' then
        return 'inactive'
    end

    local clean = strip_ansi(text)
    local lines = {}
    for line in clean:gmatch '[^\n]+' do
        lines[#lines + 1] = line
    end
    if #lines == 0 then
        return 'inactive'
    end

    for i = math.max(1, #lines - 4), #lines do
        local t = lines[i]:match '^%s*(.-)%s*$'
        if t == '>' or t:match '^>%s' or matches(t, status_patterns.idle) then
            return 'idle'
        end
    end

    local from = math.max(1, #lines - 10)
    local recent = table.concat(lines, '\n', from, #lines)
    if matches(recent, status_patterns.working) then
        return 'working'
    end

    local last = lines[#lines]:match '^%s*(.-)%s*$'
    if last == '' then
        return 'idle'
    end

    if matches(recent, status_patterns.waiting) then
        return 'waiting'
    end

    return 'idle'
end

function M.update_pane(pane)
    local pid = pane:pane_id()
    local now = os.time() * 1000
    local agent_type = detect_agent_type(pane)
    local cur = state[pid]

    if not agent_type then
        if cur then
            if not cur.undetected_since then
                cur.undetected_since = now
                return cur
            elseif (now - cur.undetected_since) < GRACE_MS then
                return cur
            end
            state[pid] = nil
        end
        return nil
    end

    if cur then
        cur.undetected_since = nil
    end

    local new_status = detect_pane_status(pane, agent_type)

    if not cur then
        cur = {
            agent_type = agent_type,
            status = new_status,
            last_update = now
        }
        state[pid] = cur
        return cur
    end

    -- Cooldown: working -> idle cần vài giây ổn định để tránh nhấp nháy khi
    -- agent tạm dừng render giữa các bước xử lý.
    if cur.status == 'working' and new_status == 'idle' then
        if not cur.cooldown_start then
            cur.cooldown_start = now
            return cur
        elseif (now - cur.cooldown_start) < COOLDOWN_MS then
            return cur
        end
        cur.cooldown_start = nil
    elseif new_status == 'working' then
        cur.cooldown_start = nil
    end

    cur.status = new_status
    cur.agent_type = agent_type
    cur.last_update = now
    return cur
end

function M.get_state(pane_id)
    return state[pane_id]
end

function M.counts()
    local c = {
        working = 0,
        waiting = 0,
        idle = 0,
        inactive = 0
    }
    for _, s in pairs(state) do
        c[s.status] = (c[s.status] or 0) + 1
    end
    return c
end

function M.cleanup(window)
    local alive = {}
    pcall(function()
        for _, t in ipairs(window:mux_window():tabs()) do
            for _, p in ipairs(t:panes()) do
                alive[p:pane_id()] = true
            end
        end
    end)
    for pid in pairs(state) do
        if not alive[pid] then
            state[pid] = nil
        end
    end
    for pid in pairs(detect_cache) do
        if not alive[pid] then
            detect_cache[pid] = nil
        end
    end
end

function M.update_all(window)
    pcall(function()
        for _, t in ipairs(window:mux_window():tabs()) do
            for _, p in ipairs(t:panes()) do
                M.update_pane(p)
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Render: chấm trạng thái trên tab-title + badge tổng hợp trên right-status
--------------------------------------------------------------------------------

-- Trả về element list cho format-tab-title: mỗi agent (duy nhất theo loại)
-- đang chạy trong các pane của tab sẽ có một chấm màu theo trạng thái.
function M.tab_title_elements(tab)
    local seen = {}
    local dots = {}
    for _, pane_info in ipairs(tab.panes or {}) do
        local s = state[pane_info.pane_id]
        if s and not seen[s.agent_type] then
            seen[s.agent_type] = true
            table.insert(dots, s.status)
        end
    end

    local title = (tab.active_pane and tab.active_pane.title) or ''
    if title == '' then
        title = 'shell'
    end
    if #title > 24 then
        title = title:sub(1, 23) .. '…'
    end

    local elements = {}
    table.insert(elements, {
        Text = ' '
    })
    for _, status in ipairs(dots) do
        table.insert(elements, {
            Foreground = {
                Color = M.colors[status] or M.colors.inactive
            }
        })
        table.insert(elements, {
            Text = M.icons[status] or M.icons.inactive
        })
        table.insert(elements, {
            Text = ' '
        })
    end
    table.insert(elements, {
        Attribute = {
            Intensity = 'Normal'
        }
    })
    table.insert(elements, {
        Text = title .. ' '
    })
    return elements
end

-- Badge tổng hợp số agent đang "waiting"/"working" trên toàn bộ cửa sổ, để
-- ghép vào right-status cùng với quota Claude/Codex.
function M.right_status_elements()
    local c = M.counts()
    local elements = {}

    if c.waiting > 0 then
        table.insert(elements, {
            Foreground = {
                Color = M.colors.waiting
            }
        })
        table.insert(elements, {
            Text = M.icons.waiting .. ' ' .. c.waiting .. ' '
        })
    end

    if c.working > 0 then
        table.insert(elements, {
            Foreground = {
                Color = M.colors.working
            }
        })
        table.insert(elements, {
            Text = M.icons.working .. ' ' .. c.working .. ' '
        })
    end

    if #elements > 0 then
        table.insert(elements, {
            Foreground = {
                Color = '#5b6078'
            }
        })
        table.insert(elements, {
            Text = '| '
        })
    end

    return elements
end

return M
