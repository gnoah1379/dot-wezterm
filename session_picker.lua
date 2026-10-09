local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

--------------------------------------------------------------------------------
-- Cấu hình (setup() ghi đè)
--------------------------------------------------------------------------------

M.bin = 'herdr'
M.config_path = nil -- HERDR_CONFIG_PATH truyền cho mọi lệnh herdr
M.auto_show = true -- tự mở picker khi cửa sổ WezTerm mới xuất hiện
M.key = {
    key = 's',
    mods = 'CMD|SHIFT'
} -- phím mở lại picker

-- Đánh dấu cửa sổ đã được mời chọn session (theo window_id) để không mở lại picker
-- mỗi lần update-status chạy.
local greeted = {}

--------------------------------------------------------------------------------
-- Helper chạy lệnh herdr
--------------------------------------------------------------------------------

local function shq(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

-- Ghép lệnh herdr hoàn chỉnh (đã quote) để chạy qua /bin/sh.
local function herdr_cmd(args)
    local parts = {shq(M.bin)}
    for _, a in ipairs(args) do
        parts[#parts + 1] = shq(a)
    end
    local cmd = table.concat(parts, ' ')
    if M.config_path then
        cmd = 'HERDR_CONFIG_PATH=' .. shq(M.config_path) .. ' ' .. cmd
    end
    return cmd
end

-- Script POSIX sh chạy Herdr trong pane.
--   * Herdr thoát bình thường (mã 0) -> sh thoát theo -> pane đóng, y như khi Herdr là default_prog.
--   * Herdr lỗi -> in mã lỗi rồi `exec` lại shell đăng nhập, KHÔNG để pane đóng.
-- Quan trọng: pane có thể chạy zsh/fish, mà zsh không hiểu `exec VAR=val cmd`
-- (exec thất bại -> zsh thoát -> đóng luôn cửa sổ WezTerm). Vì vậy mọi thứ được
-- gói trong đúng một chuỗi `/bin/sh -c '...'`, nơi cú pháp POSIX luôn đúng.
local function launch_script(args)
    return table.concat({herdr_cmd(args), '__st=$?',
                         '[ "$__st" -eq 0 ] && exit 0',
                         'printf \'\\n\\033[31m[herdr] lệnh thoát với mã %s\\033[0m\\n\' "$__st" >&2',
                         'exec "${SHELL:-/bin/sh}" -l'}, '; ')
end

local function run_herdr(args)
    local ok, stdout, stderr = wezterm.run_child_process {'/bin/sh', '-c', herdr_cmd(args)}
    return ok, stdout or '', stderr or ''
end

local function notify(window, title, message)
    wezterm.log_info('herdr session picker: ' .. title .. ' — ' .. message)
    pcall(function()
        window:toast_notification(title, message, nil, 4000)
    end)
end

local function list_sessions(window)
    local ok, stdout, stderr = run_herdr {'session', 'list', '--json'}
    if not ok then
        notify(window, 'Herdr', 'Không chạy được `herdr session list`: ' .. (stderr ~= '' and stderr or '?'))
        return nil
    end

    local parsed_ok, data = pcall(wezterm.json_parse, stdout)
    if not parsed_ok or type(data) ~= 'table' or type(data.sessions) ~= 'table' then
        notify(window, 'Herdr', 'Không đọc được JSON từ `herdr session list`')
        return nil
    end

    -- Session đang chạy lên trước, còn lại giữ thứ tự herdr trả về.
    local running, stopped = {}, {}
    for _, s in ipairs(data.sessions) do
        table.insert(s.running and running or stopped, s)
    end
    for _, s in ipairs(stopped) do
        table.insert(running, s)
    end
    return running
end

--------------------------------------------------------------------------------
-- Định dạng nhãn
--------------------------------------------------------------------------------

local home = os.getenv 'HOME' or wezterm.home_dir

local function tilde(path)
    if path and home and path:sub(1, #home) == home then
        return '~' .. path:sub(#home + 1)
    end
    return path or ''
end

local function pad(s, width)
    local n = #s
    return n >= width and s or s .. string.rep(' ', width - n)
end

local function name_width(sessions)
    local w = 8
    for _, s in ipairs(sessions) do
        if #s.name > w then
            w = #s.name
        end
    end
    return w
end

local function session_label(s, width)
    local dot = s.running and {{
        Foreground = {
            AnsiColor = 'Green'
        }
    }, {
        Text = '● '
    }} or {{
        Foreground = {
            AnsiColor = 'Grey'
        }
    }, {
        Text = '○ '
    }}

    local items = {}
    for _, it in ipairs(dot) do
        items[#items + 1] = it
    end
    items[#items + 1] = {
        Attribute = {
            Intensity = 'Bold'
        }
    }
    items[#items + 1] = {
        Text = pad(s.name, width + 2)
    }
    items[#items + 1] = {
        Attribute = {
            Intensity = 'Half'
        }
    }
    items[#items + 1] = {
        Foreground = {
            AnsiColor = s.running and 'Green' or 'Grey'
        }
    }
    items[#items + 1] = {
        Text = pad(s.running and 'running' or 'stopped', 10)
    }
    items[#items + 1] = {
        Foreground = {
            AnsiColor = 'Silver'
        }
    }
    items[#items + 1] = {
        Text = tilde(s.session_dir) .. (s.default and '  (default)' or '')
    }
    return wezterm.format(items)
end

local function menu_label(icon, text, color)
    return wezterm.format {{
        Foreground = {
            AnsiColor = color
        }
    }, {
        Text = icon .. '  '
    }, {
        Attribute = {
            Intensity = 'Half'
        }
    }, {
        Text = text
    }}
end

--------------------------------------------------------------------------------
-- Chạy session trong pane hiện tại
--------------------------------------------------------------------------------

local SHELLS = {
    zsh = true,
    bash = true,
    sh = true,
    fish = true,
    dash = true,
    ksh = true
}

-- Pane khởi động chạy shell => `exec herdr ...` thay chỗ shell, thoát herdr là đóng pane.
-- Pane đang chạy thứ khác (kể cả herdr) => mở tab mới để không phá tiến trình đang chạy.
local function pane_is_shell(pane)
    local ok, name = pcall(function()
        return pane:get_foreground_process_name()
    end)
    if not ok or not name then
        return false
    end
    return SHELLS[name:match '([^/]+)$' or ''] == true
end

-- Ghi script ra file tạm rồi chỉ gõ `exec /bin/sh <file>` vào pane: chuỗi lệnh
-- hiện trên màn hình ngắn gọn thay vì một dòng quote dài loằng ngoằng.
-- Script tự xoá mình ngay dòng đầu nên không để lại rác.
local launch_seq = 0

local function write_launch_script(script)
    local tmp = os.getenv 'TMPDIR' or '/tmp/'
    if tmp:sub(-1) ~= '/' then
        tmp = tmp .. '/'
    end
    launch_seq = launch_seq + 1
    local path = string.format('%swezterm-herdr-launch-%d-%d.sh', tmp, os.time(), launch_seq)

    local f = io.open(path, 'w')
    if not f then
        return nil
    end
    f:write('rm -f ' .. shq(path) .. '\n' .. script .. '\n')
    f:close()
    return path
end

-- Đóng pane launcher mà không gõ gì lên màn hình: kill đúng PID của shell trong
-- pane đó. Chỉ gọi SAU khi tab mới đã spawn thành công, và chỉ với pane đang chạy
-- shell — không bao giờ đụng tới pane đang chạy Herdr.
local function close_launcher_pane(pane)
    local ok, info = pcall(function()
        return pane:get_foreground_process_info()
    end)
    -- SIGHUP chứ không phải SIGTERM: shell tương tác (zsh, bash) bỏ qua SIGTERM,
    -- kill thường sẽ im lặng thất bại và để lại tab launcher thừa bên cạnh Herdr.
    if ok and info and info.pid then
        if pcall(wezterm.background_child_process, {'/bin/kill', '-HUP', tostring(info.pid)}) then
            return
        end
    end
    pcall(function()
        pane:send_text 'exit\r'
    end)
end

local function launch(window, pane, args)
    local script = launch_script(args)

    -- Đường đi chính: tab mới chạy thẳng /bin/sh -c <script>, không qua shell của
    -- pane nên không có dòng lệnh nào bị echo ra màn hình.
    local mux_win = window:mux_window()
    if mux_win then
        local spawned = pcall(function()
            mux_win:spawn_tab {
                args = {'/bin/sh', '-c', script}
            }
        end)
        if spawned then
            if pane_is_shell(pane) then
                close_launcher_pane(pane)
            end
            return
        end
    end

    -- Dự phòng (spawn_tab lỗi): quay lại cách gõ lệnh vào shell của pane.
    if pane_is_shell(pane) then
        local path = write_launch_script(script)
        pane:send_text('exec /bin/sh ' .. shq(path or '') .. '\r')
    else
        window:perform_action(act.SpawnCommandInNewTab {
            args = {'/bin/sh', '-c', script}
        }, pane)
    end
end

--------------------------------------------------------------------------------
-- Các màn hình
--------------------------------------------------------------------------------

local show_main -- forward declaration

-- Chọn 1 session trong danh sách đã lọc rồi gọi on_pick(window, pane, session).
local function pick_session(window, pane, opts)
    local sessions = {}
    for _, s in ipairs(opts.sessions) do
        if not opts.filter or opts.filter(s) then
            table.insert(sessions, s)
        end
    end

    if #sessions == 0 then
        notify(window, 'Herdr', opts.empty_message)
        show_main(window, pane)
        return
    end

    local width = name_width(sessions)
    local choices = {}
    local by_id = {}
    for _, s in ipairs(sessions) do
        local id = 'session:' .. s.name
        by_id[id] = s
        table.insert(choices, {
            id = id,
            label = session_label(s, width)
        })
    end
    table.insert(choices, {
        id = 'back',
        label = menu_label('←', 'Quay lại', 'Blue')
    })

    window:perform_action(act.InputSelector {
        title = opts.title,
        description = opts.description,
        choices = choices,
        action = wezterm.action_callback(function(win, p, id)
            if not id then
                return
            end
            if id == 'back' then
                show_main(win, p)
                return
            end
            opts.on_pick(win, p, by_id[id])
        end)
    }, pane)
end

local function confirm(window, pane, opts)
    window:perform_action(act.InputSelector {
        title = opts.title,
        description = opts.description,
        choices = {{
            id = 'no',
            label = menu_label('✗', 'Không, quay lại', 'Blue')
        }, {
            id = 'yes',
            label = menu_label('✓', opts.yes_label, 'Red')
        }},
        action = wezterm.action_callback(function(win, p, id)
            if id == 'yes' then
                opts.on_yes(win, p)
            elseif id == 'no' then
                show_main(win, p)
            end
        end)
    }, pane)
end

local function do_stop(window, pane, name)
    local ok, _, stderr = run_herdr {'session', 'stop', name}
    notify(window, 'Herdr', ok and ('Đã stop session "' .. name .. '"') or
        ('Stop "' .. name .. '" thất bại: ' .. stderr))
    show_main(window, pane)
end

local function do_delete(window, pane, session)
    if session.running then
        local ok, _, stderr = run_herdr {'session', 'stop', session.name}
        if not ok then
            notify(window, 'Herdr', 'Không stop được "' .. session.name .. '": ' .. stderr)
            show_main(window, pane)
            return
        end
    end
    local ok, _, stderr = run_herdr {'session', 'delete', session.name}
    notify(window, 'Herdr', ok and ('Đã xoá session "' .. session.name .. '"') or
        ('Xoá "' .. session.name .. '" thất bại: ' .. stderr))
    show_main(window, pane)
end

local function prompt_new_session(window, pane)
    window:perform_action(act.PromptInputLine {
        description = wezterm.format {{
            Attribute = {
                Intensity = 'Bold'
            }
        }, {
            Foreground = {
                AnsiColor = 'Fuchsia'
            }
        }, {
            Text = 'Tên session mới (a-z, 0-9, . _ -):'
        }},
        action = wezterm.action_callback(function(win, p, line)
            if not line or line == '' then
                show_main(win, p)
                return
            end
            local name = line:match '^%s*(.-)%s*$'
            if not name:match '^[%w._-]+$' then
                notify(win, 'Herdr', 'Tên session không hợp lệ: ' .. name)
                show_main(win, p)
                return
            end
            launch(win, p, {'--session', name})
        end)
    }, pane)
end

show_main = function(window, pane)
    local sessions = list_sessions(window)
    if not sessions then
        return
    end

    local width = name_width(sessions)
    local choices = {}
    local by_id = {}

    for _, s in ipairs(sessions) do
        local id = 'attach:' .. s.name
        by_id[id] = s
        table.insert(choices, {
            id = id,
            label = session_label(s, width)
        })
    end

    table.insert(choices, {
        id = 'new',
        label = menu_label('＋', 'Session mới…', 'Fuchsia')
    })
    table.insert(choices, {
        id = 'stop',
        label = menu_label('⏹', 'Stop một session…', 'Olive')
    })
    table.insert(choices, {
        id = 'delete',
        label = menu_label('🗑', 'Xoá một session…', 'Red')
    })
    table.insert(choices, {
        id = 'shell',
        label = menu_label('⌨', 'Bỏ qua, dùng shell', 'Silver')
    })

    window:perform_action(act.InputSelector {
        title = 'Herdr sessions',
        description = 'Chọn session để attach — Enter: chọn, gõ để lọc, Esc: bỏ qua',
        fuzzy_description = 'Herdr session > ',
        choices = choices,
        action = wezterm.action_callback(function(win, p, id)
            if not id or id == 'shell' then
                return
            end

            local session = by_id[id]
            if session then
                -- Session đang chạy: attach vào server sẵn có.
                -- Session đã stop: `herdr --session <name>` để khởi động lại rồi attach.
                launch(win, p, session.running and {'session', 'attach', session.name} or
                    {'--session', session.name})
                return
            end

            if id == 'new' then
                prompt_new_session(win, p)
            elseif id == 'stop' then
                pick_session(win, p, {
                    sessions = sessions,
                    title = 'Stop session',
                    description = 'Chọn session đang chạy để stop — Esc: huỷ',
                    filter = function(s)
                        return s.running
                    end,
                    empty_message = 'Không có session nào đang chạy',
                    on_pick = function(w2, p2, s)
                        do_stop(w2, p2, s.name)
                    end
                })
            elseif id == 'delete' then
                pick_session(win, p, {
                    sessions = sessions,
                    title = 'Xoá session',
                    description = 'Chọn session để xoá — Esc: huỷ',
                    empty_message = 'Không có session nào để xoá',
                    on_pick = function(w2, p2, s)
                        confirm(w2, p2, {
                            title = 'Xoá session "' .. s.name .. '"?',
                            description = s.running and ('Session "' .. s.name ..
                                              '" đang chạy: sẽ stop trước rồi xoá. Thao tác không hoàn tác được.') or
                                ('Xoá vĩnh viễn session "' .. s.name .. '" (' .. tilde(s.session_dir) ..
                                    '). Thao tác không hoàn tác được.'),
                            yes_label = 'Xoá "' .. s.name .. '"',
                            on_yes = function(w3, p3)
                                do_delete(w3, p3, s)
                            end
                        })
                    end
                })
            end
        end)
    }, pane)
end

M.show = show_main

--------------------------------------------------------------------------------
-- Cài đặt
--------------------------------------------------------------------------------

local function maybe_greet(window)
    if not M.auto_show or not window then
        return
    end
    local ok, id = pcall(function()
        return window:window_id()
    end)
    if not ok or greeted[id] then
        return
    end
    greeted[id] = true

    local pane = window:active_pane()
    if not pane then
        greeted[id] = nil
        return
    end
    if not pcall(show_main, window, pane) then
        greeted[id] = nil -- để update-status thử lại ở nhịp sau
    end
end

function M.setup(config, opts)
    opts = opts or {}
    M.bin = opts.bin or M.bin
    M.config_path = opts.config_path or M.config_path
    if opts.auto_show ~= nil then
        M.auto_show = opts.auto_show
    end
    M.key = opts.key or M.key

    -- Pane khởi động là shell: picker sẽ `exec herdr …` đè lên nó khi bạn chọn,
    -- và Esc thì bạn còn nguyên một shell bình thường để dùng.
    config.default_prog = opts.default_prog or {os.getenv 'SHELL' or '/bin/zsh', '-l'}

    config.keys = config.keys or {}
    table.insert(config.keys, {
        key = M.key.key,
        mods = M.key.mods,
        action = wezterm.action_callback(function(window, pane)
            show_main(window, pane)
        end)
    })

    -- gui-attached: mở picker ngay khi cửa sổ đầu tiên sẵn sàng.
    wezterm.on('gui-attached', function()
        for _, mux_win in ipairs(wezterm.mux.all_windows()) do
            local ok, gui_win = pcall(function()
                return mux_win:gui_window()
            end)
            if ok and gui_win then
                maybe_greet(gui_win)
            end
        end
    end)

    -- update-status: lưới an toàn — bắt luôn cửa sổ mở thêm sau này (Cmd+N).
    wezterm.on('update-status', function(window)
        maybe_greet(window)
    end)

    return config
end

return M
