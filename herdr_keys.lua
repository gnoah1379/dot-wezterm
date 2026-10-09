local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

local home_dir = os.getenv 'HOME' or wezterm.home_dir

-- File cấu hình Herdr dành riêng cho WezTerm (bộ keybinding kiểu Ghostty/macOS).
-- Herdr đọc biến môi trường HERDR_CONFIG_PATH thay cho ~/.config/herdr/config.toml.
M.config_path = home_dir .. '/.config/wezterm/herdr.toml'

-- Session Herdr riêng cho WezTerm (server/socket tách khỏi session mặc định chạy từ Ghostty)
M.session = 'wezterm'

-- true  = WezTerm tự chạy Herdr ngay khi mở cửa sổ/tab mới
M.autostart = true

-- true  = chỉ nhường phím khi pane đang chạy Herdr (giữ phím tắt gốc của WezTerm ở pane khác)
-- false = luôn nhường phím cho Herdr (hợp lý khi Herdr là default_prog)
M.only_when_herdr_is_running = false

--------------------------------------------------------------------------------
-- Tìm binary herdr
--------------------------------------------------------------------------------

local function resolve_herdr_bin()
    local candidates = {'/opt/homebrew/bin/herdr', '/usr/local/bin/herdr', home_dir .. '/.local/bin/herdr'}
    for _, path in ipairs(candidates) do
        local f = io.open(path, 'r')
        if f then
            f:close()
            return path
        end
    end
    return 'herdr'
end

M.bin = resolve_herdr_bin()

--------------------------------------------------------------------------------
-- Nhận diện pane đang chạy Herdr (chỉ dùng khi only_when_herdr_is_running = true)
--------------------------------------------------------------------------------

local function looks_like_herdr(name)
    if not name or name == '' then
        return false
    end
    name = name:lower()
    return name == 'herdr' or name:match '/herdr$' ~= nil or name:match '^herdr%s' ~= nil
end

local function scan_process(proc, depth)
    if not proc or depth > 2 then
        return false
    end
    if looks_like_herdr(proc.name) or looks_like_herdr(proc.executable) then
        return true
    end
    if proc.children then
        for _, child in pairs(proc.children) do
            if scan_process(child, depth + 1) then
                return true
            end
        end
    end
    return false
end

local function pane_runs_herdr(pane)
    if not pane then
        return false
    end

    local ok, info = pcall(function()
        return pane:get_foreground_process_info()
    end)
    if ok and info and scan_process(info, 0) then
        return true
    end

    local ok_name, name = pcall(function()
        return pane:get_foreground_process_name()
    end)
    if ok_name and looks_like_herdr(name) then
        return true
    end

    local ok_title, title = pcall(function()
        return pane:get_title()
    end)
    if ok_title and title and title:lower():find('herdr', 1, true) then
        return true
    end

    return false
end

--------------------------------------------------------------------------------
-- Binding
--------------------------------------------------------------------------------

-- to_herdr: action dùng khi Herdr đang chạy trong pane
-- fallback: action gốc của WezTerm khi pane không chạy Herdr (chỉ dùng ở chế độ có điều kiện)
local function herdr_first(key, mods, to_herdr, fallback)
    if not M.only_when_herdr_is_running then
        return {
            key = key,
            mods = mods,
            action = to_herdr
        }
    end

    return {
        key = key,
        mods = mods,
        action = wezterm.action_callback(function(window, pane)
            if pane_runs_herdr(pane) then
                window:perform_action(to_herdr, pane)
            elseif fallback then
                window:perform_action(fallback, pane)
            end
        end)
    }
end

-- Phím trùng phím tắt mặc định của WezTerm: nhường xuống pane để Herdr xử lý.
-- DisableDefaultAssignment giữ nguyên bộ mã hoá Kitty Keyboard Protocol của WezTerm.
local function passthrough(key, mods, fallback)
    local to_herdr = M.only_when_herdr_is_running and act.SendKey {
        key = key,
        mods = mods
    } or act.DisableDefaultAssignment
    return herdr_first(key, mods, to_herdr, fallback)
end

function M.build_keys()
    local keys = {}

    local conflicting = {{
        key = 't',
        mods = 'CMD',
        fallback = act.SpawnTab 'CurrentPaneDomain'
    }, -- new_tab
    {
        key = 'w',
        mods = 'CMD',
        fallback = act.CloseCurrentTab {
            confirm = true
        }
    }, -- close_pane
    {
        key = 'w',
        mods = 'CMD|ALT'
    }, -- close_tab
    {
        key = 'n',
        mods = 'CMD',
        fallback = act.SpawnWindow
    }, -- new_workspace
    {
        key = '[',
        mods = 'CMD|SHIFT',
        fallback = act.ActivateTabRelative(-1)
    }, -- previous_tab
    {
        key = ']',
        mods = 'CMD|SHIFT',
        fallback = act.ActivateTabRelative(1)
    }, -- next_tab
    {
        key = '{',
        mods = 'CMD',
        fallback = act.ActivateTabRelative(-1)
    }, {
        key = '{',
        mods = 'CMD|SHIFT',
        fallback = act.ActivateTabRelative(-1)
    }, {
        key = '}',
        mods = 'CMD',
        fallback = act.ActivateTabRelative(1)
    }, {
        key = '}',
        mods = 'CMD|SHIFT',
        fallback = act.ActivateTabRelative(1)
    }, {
        key = 'Tab',
        mods = 'CTRL',
        fallback = act.ActivateTabRelative(1)
    }, -- next_tab
    {
        key = 'Tab',
        mods = 'CTRL|SHIFT',
        fallback = act.ActivateTabRelative(-1)
    } -- previous_tab
    }

    -- Cmd+1..9: switch_tab trong Herdr (Cmd+9 = tab cuối như WezTerm)
    for i = 1, 9 do
        table.insert(conflicting, {
            key = tostring(i),
            mods = 'CMD',
            fallback = act.ActivateTab(i == 9 and -1 or i - 1)
        })
    end

    for _, item in ipairs(conflicting) do
        table.insert(keys, passthrough(item.key, item.mods, item.fallback))
    end

    -- Khắc phục lỗi macOS: WezTerm bị nuốt modifier khi nhấn tổ hợp CMD / CMD+SHIFT
    -- (IME forwarding + Cocoa command-layer strip) khiến Cmd+Shift+D thành chữ "d" thường.
    -- Gửi thẳng escape sequence Kitty Keyboard Protocol mà Herdr mong đợi.
    local raw_sequences = { -- Cmd+D: split_vertical (CSI 100;9u)
    {
        key = 'd',
        mods = 'CMD',
        seq = '\x1b[100;9u'
    }, {
        key = 'phys:d',
        mods = 'CMD',
        seq = '\x1b[100;9u'
    }, -- Cmd+Shift+D: split_horizontal (CSI 100:68;10u)
    {
        key = 'd',
        mods = 'CMD|SHIFT',
        seq = '\x1b[100:68;10u'
    }, {
        key = 'D',
        mods = 'CMD|SHIFT',
        seq = '\x1b[100:68;10u'
    }, {
        key = 'D',
        mods = 'CMD',
        seq = '\x1b[100:68;10u'
    }, {
        key = 'phys:d',
        mods = 'CMD|SHIFT',
        seq = '\x1b[100:68;10u'
    }, -- Cmd+Shift+Enter: zoom pane (CSI 13;10u)
    {
        key = 'Enter',
        mods = 'CMD|SHIFT',
        seq = '\x1b[13;10u'
    }}

    for _, item in ipairs(raw_sequences) do
        table.insert(keys, herdr_first(item.key, item.mods, act.SendString(item.seq), nil))
    end

    return keys
end

--------------------------------------------------------------------------------
-- Cài đặt vào config của WezTerm
--------------------------------------------------------------------------------

function M.setup(config)
    config.set_environment_variables = config.set_environment_variables or {}

    -- Mọi tiến trình herdr spawn từ WezTerm đều đọc ~/.config/wezterm/herdr.toml
    config.set_environment_variables.HERDR_CONFIG_PATH = M.config_path

    -- WezTerm mở từ Dock/Spotlight không kế thừa PATH của shell: bổ sung Homebrew
    local current_path = os.getenv 'PATH'
    local brew_path = '/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin'
    config.set_environment_variables.PATH =
        (current_path and current_path ~= '') and (brew_path .. ':' .. current_path) or
            (brew_path .. ':/usr/bin:/bin:/usr/sbin:/sbin')

    -- Kitty Keyboard Protocol là điều kiện bắt buộc để phím Cmd tới được Herdr
    config.enable_kitty_keyboard = true

    if M.autostart then
        config.default_prog = {M.bin, '--session', M.session}
    end

    config.keys = config.keys or {}
    for _, key in ipairs(M.build_keys()) do
        table.insert(config.keys, key)
    end

    return config
end

return M
