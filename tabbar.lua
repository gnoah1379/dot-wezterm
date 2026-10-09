--[[
  tabbar.lua - Hiển thị Quota (Claude & Codex) trực tiếp lên tab-bar của WezTerm,
  đồng thời điều phối agent_status.lua để vẽ chấm trạng thái agent (giống
  wezterm-agent-deck) trên tab-title và badge tổng hợp trên right-status.
  Không spawn pane phụ, không ghi/đọc file cache tạm: mọi thứ được tính trong
  tiến trình WezTerm và đẩy thẳng vào tab-bar.
--]] local wezterm = require 'wezterm'
local agent_status = require 'agent_status'

local M = {}

-- Cấu hình mặc định
M.default_opts = {
    refresh_interval = 10, -- Chu kỳ đọc quota Claude & Codex (giây)
    -- Bật/tắt phần badge + chấm trạng thái agent. Khi Herdr là chương trình mặc định,
    -- WezTerm chỉ thấy duy nhất tiến trình herdr nên phần này không còn dò được agent.
    agent_status = true,
    total_blocks = 6,
    -- Ký tự vẽ thanh quota. Bắt buộc dùng ký tự thuộc khối Block Elements
    -- (U+2580–U+259F): WezTerm tự vẽ chúng theo đúng ô (custom_block_glyphs),
    -- nên không cần mượn font nào và không bao giờ lệch baseline.
    -- Trước đây dùng ▰/▱ (U+25B0/25B1) — font chính không có, WezTerm phải mượn
    -- Menlo (x_adv=7, khác metric của cell) nên phần đã dùng bị đẩy lệch xuống.
    bar_chars = {
        filled = '█',
        empty = '░'
    },
    paths = {
        claude_json = (os.getenv 'HOME' or '') .. '/.claude.json',
        codex_sessions = (os.getenv 'HOME' or '') .. '/.codex/sessions'
    },
    colors = {
        claude = '#D97757',
        codex = '#10A37F',
        bar_empty = '#4B5563',
        label = '#9CA3AF',
        text = '#E5E7EB',
        time = '#9CA3AF',
        separator = '#4B5563'
    }
}

-- Bảng màu thay thế khi color_scheme có nền sáng. Bộ màu mặc định ở trên vẽ cho
-- nền tối nên trên nền sáng sẽ chìm hẳn (ví dụ text #E5E7EB chỉ đạt tương phản
-- 1.09 trên nền Catppuccin Latte). Các giá trị dưới đây đều >= 4.3 cho phần chữ.
M.light_colors = {
    claude = '#c2410c',
    codex = '#047857',
    bar_empty = '#9ca0b0',
    label = '#5c5f77',
    text = '#4c4f69',
    time = '#6c6f85',
    separator = '#8c8fa1'
}

-- Độ sáng tương đối (WCAG) của một mã màu #rrggbb
local function relative_luminance(hex)
    if type(hex) ~= 'string' or #hex ~= 7 then
        return nil
    end
    local channels = {}
    for i = 1, 3 do
        local c = tonumber(hex:sub(i * 2, i * 2 + 1), 16)
        if not c then
            return nil
        end
        c = c / 255
        channels[i] = (c <= 0.03928) and (c / 12.92) or (((c + 0.055) / 1.055) ^ 2.4)
    end
    return 0.2126 * channels[1] + 0.7152 * channels[2] + 0.0722 * channels[3]
end

-- Màu nền thực tế của cấu hình: ưu tiên colors.background, sau đó tra color_scheme
local function config_background(config)
    if not config then
        return nil
    end
    if config.colors and config.colors.background then
        return config.colors.background
    end
    if config.color_scheme then
        local ok, schemes = pcall(wezterm.color.get_builtin_schemes)
        if ok and schemes[config.color_scheme] then
            return schemes[config.color_scheme].background
        end
    end
    return nil
end

function M.colors_for(config)
    local lum = relative_luminance(config_background(config))
    if lum and lum > 0.5 then
        return M.light_colors
    end
    return M.default_opts.colors
end

--------------------------------------------------------------------------------
-- Trích xuất Quota: Claude & Codex
--------------------------------------------------------------------------------

local function parse_iso8601_to_epoch(iso_str)
    if not iso_str or type(iso_str) ~= 'string' then
        return nil
    end
    local year, month, day, hour, min, sec = iso_str:match '^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)'
    if not year then
        return nil
    end

    local target_table = {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec)
    }
    local target_time = os.time(target_table)

    local now = os.time()
    local utc_date = os.date('!*t', now)
    local local_date = os.date('*t', now)
    local tz_offset = os.time(local_date) - os.time(utc_date)
    local epoch = target_time + tz_offset

    local tz_sign, tz_h, tz_m = iso_str:match '([+-])(%d%d):?(%d%d)$'
    if tz_sign then
        local offset_sec = (tonumber(tz_h) * 3600) + (tonumber(tz_m) * 60)
        if tz_sign == '+' then
            epoch = epoch - offset_sec
        else
            epoch = epoch + offset_sec
        end
    end
    return epoch
end

function M.get_claude_quota(file_path)
    file_path = file_path or M.default_opts.paths.claude_json
    local res = {
        h5_pct = 0,
        h5_reset = nil,
        d7_pct = 0,
        d7_reset = nil
    }
    local f = io.open(file_path, 'r')
    if not f then
        return res
    end
    local content = f:read '*a'
    f:close()

    local fh_str = content:match '"five_hour"%s*:%s*{(.-)}'
    if fh_str then
        local u = fh_str:match '"utilization"%s*:%s*([%d%.]+)'
        if u then
            res.h5_pct = tonumber(u) or 0
        end
        local r = fh_str:match '"resets_at"%s*:%s*"([^"]+)"'
        if r then
            res.h5_reset = parse_iso8601_to_epoch(r)
        end
    end

    local sd_str = content:match '"seven_day"%s*:%s*{(.-)}'
    if sd_str then
        local u = sd_str:match '"utilization"%s*:%s*([%d%.]+)'
        if u then
            res.d7_pct = tonumber(u) or 0
        end
        local r = sd_str:match '"resets_at"%s*:%s*"([^"]+)"'
        if r then
            res.d7_reset = parse_iso8601_to_epoch(r)
        end
    end

    for lim in content:gmatch '{(.-)}' do
        if lim:find '"session"' and lim:find '"percent"' then
            local p = lim:match '"percent"%s*:%s*([%d%.]+)'
            local r = lim:match '"resets_at"%s*:%s*"([^"]+)"'
            if p and tonumber(p) and tonumber(p) > 0 then
                res.h5_pct = tonumber(p)
            end
            if r and not res.h5_reset then
                res.h5_reset = parse_iso8601_to_epoch(r)
            end
        elseif lim:find '"weekly_all"' and lim:find '"percent"' then
            local p = lim:match '"percent"%s*:%s*([%d%.]+)'
            local r = lim:match '"resets_at"%s*:%s*"([^"]+)"'
            if p and tonumber(p) and tonumber(p) > 0 then
                res.d7_pct = tonumber(p)
            end
            if r and not res.d7_reset then
                res.d7_reset = parse_iso8601_to_epoch(r)
            end
        end
    end

    if res.h5_pct > 0 and res.h5_pct < 1 then
        res.h5_pct = res.h5_pct * 100
    end
    if res.d7_pct > 0 and res.d7_pct < 1 then
        res.d7_pct = res.d7_pct * 100
    end
    res.h5_pct = math.max(0, math.min(100, math.floor(res.h5_pct + 0.5)))
    res.d7_pct = math.max(0, math.min(100, math.floor(res.d7_pct + 0.5)))

    return res
end

function M.get_codex_quota(sessions_dir)
    sessions_dir = sessions_dir or M.default_opts.paths.codex_sessions
    local res = {
        h5_pct = 0,
        h5_reset = nil,
        d7_pct = 0,
        d7_reset = nil
    }

    local f_pipe = io.popen('ls -1dt ' .. sessions_dir .. '/*/*/*/*.jsonl 2>/dev/null | head -n 8')
    if not f_pipe then
        return res
    end
    local files_str = f_pipe:read '*a'
    f_pipe:close()

    local best_ts = ''

    for path in files_str:gmatch '[^\r\n]+' do
        local f = io.open(path, 'r')
        if f then
            local fsize = f:seek 'end'
            local read_sz = math.min(65536, fsize)
            f:seek('set', math.max(0, fsize - read_sz))
            local chunk = f:read '*a'
            f:close()

            if chunk and chunk:find 'rate_limits' then
                for line in chunk:gmatch '[^\r\n]+' do
                    if line:find 'rate_limits' then
                        local ts = line:match '"timestamp"%s*:%s*"([^"]+)"' or ''
                        if ts > best_ts then
                            best_ts = ts
                            local function parse_entry(ent_str)
                                if not ent_str then
                                    return
                                end
                                local w = tonumber(ent_str:match '"window_minutes"%s*:%s*(%d+)') or 0
                                local p = tonumber(ent_str:match '"used_percent"%s*:%s*([%d%.]+)') or 0
                                local r = ent_str:match '"resets_at"%s*:%s*(%d+)' or
                                              ent_str:match '"resets_at"%s*:%s*"([^"]+)"'
                                local reset_epoch = tonumber(r)
                                if not reset_epoch and r then
                                    reset_epoch = parse_iso8601_to_epoch(r)
                                end

                                if w > 0 and w <= 360 then
                                    res.h5_pct = p
                                    res.h5_reset = reset_epoch
                                elseif w > 360 then
                                    res.d7_pct = p
                                    res.d7_reset = reset_epoch
                                end
                            end

                            parse_entry(line:match '"primary"%s*:%s*({[^}]+})')
                            parse_entry(line:match '"secondary"%s*:%s*({[^}]+})')
                        end
                    end
                end
            end
        end
    end

    res.h5_pct = math.max(0, math.min(100, math.floor(res.h5_pct + 0.5)))
    res.d7_pct = math.max(0, math.min(100, math.floor(res.d7_pct + 0.5)))

    return res
end

--------------------------------------------------------------------------------
-- Render Quota trực tiếp lên tab-bar (wezterm.format + right_status)
--------------------------------------------------------------------------------

local function format_remaining_time(epoch)
    if not epoch then
        return '--'
    end
    local now = os.time()
    local diff = epoch - now
    if diff <= 0 then
        return '0m'
    end
    local days = math.floor(diff / 86400)
    local rem = diff % 86400
    local hours = math.floor(rem / 3600)
    local mins = math.floor((rem % 3600) / 60)

    if days > 0 then
        return string.format('%dd-%dh', days, hours)
    elseif hours > 0 then
        return string.format('%dh-%dm', hours, mins)
    else
        return string.format('%dm', mins)
    end
end

local function calc_bar_blocks(pct, total_blocks)
    total_blocks = total_blocks or 6
    pct = math.max(0, math.min(100, pct or 0))
    local filled = math.floor((pct / 100) * total_blocks + 0.5)
    return filled, total_blocks - filled
end

M.format_remaining_time = format_remaining_time
M.calc_bar_blocks = calc_bar_blocks

-- Dựng danh sách phần tử wezterm.format() cho một block "5h/7d" (nhãn + thanh + % + thời gian còn lại)
local function push_bar(elements, colors, label, pct, reset_epoch, total_blocks, accent)
    table.insert(elements, {
        Foreground = {
            Color = colors.label
        }
    })
    table.insert(elements, {
        Text = label .. ' '
    })

    local filled, empty = calc_bar_blocks(pct, total_blocks)
    local chars = M.default_opts.bar_chars
    table.insert(elements, {
        Foreground = {
            Color = accent
        }
    })
    table.insert(elements, {
        Text = string.rep(chars.filled, filled)
    })
    table.insert(elements, {
        Foreground = {
            Color = colors.bar_empty
        }
    })
    table.insert(elements, {
        Text = string.rep(chars.empty, empty)
    })

    table.insert(elements, {
        Foreground = {
            Color = colors.text
        }
    })
    table.insert(elements, {
        Text = string.format(' %d%% ', pct)
    })
    table.insert(elements, {
        Foreground = {
            Color = colors.time
        }
    })
    table.insert(elements, {
        Text = format_remaining_time(reset_epoch) .. '  '
    })
end

-- Dựng element list cho phần quota (chưa wezterm.format) để có thể ghép nối
-- với các phần khác (badge agent status) trước khi format 1 lần duy nhất.
function M.build_quota_elements(claude, codex, opts)
    opts = opts or M.default_opts
    local colors = opts.colors or M.default_opts.colors
    local total_blocks = opts.total_blocks or M.default_opts.total_blocks

    local elements = {}

    table.insert(elements, {
        Foreground = {
            Color = colors.claude
        }
    })
    table.insert(elements, {
        Text = 'Claude '
    })
    push_bar(elements, colors, '5h', claude.h5_pct, claude.h5_reset, total_blocks, colors.claude)
    push_bar(elements, colors, '7d', claude.d7_pct, claude.d7_reset, total_blocks, colors.claude)

    table.insert(elements, {
        Foreground = {
            Color = colors.separator
        }
    })
    table.insert(elements, {
        Text = '| '
    })

    table.insert(elements, {
        Foreground = {
            Color = colors.codex
        }
    })
    table.insert(elements, {
        Text = 'Codex '
    })
    push_bar(elements, colors, '5h', codex.h5_pct, codex.h5_reset, total_blocks, colors.codex)
    push_bar(elements, colors, '7d', codex.d7_pct, codex.d7_reset, total_blocks, colors.codex)

    return elements
end

-- Giữ nguyên API cũ (trả về chuỗi đã format) cho trường hợp gọi độc lập.
function M.build_status(claude, codex, opts)
    return wezterm.format(M.build_quota_elements(claude, codex, opts))
end

--------------------------------------------------------------------------------
-- Tích hợp WezTerm: định kỳ tính quota và đẩy thẳng lên right-status của tab-bar
--------------------------------------------------------------------------------

function M.setup_pane(config, user_opts)
    local opts = {}
    for k, v in pairs(M.default_opts) do
        opts[k] = v
    end
    if user_opts then
        for k, v in pairs(user_opts) do
            opts[k] = v
        end
    end

    -- Chưa chỉ định màu thì bám theo độ sáng nền của color_scheme đang dùng
    if not (user_opts and user_opts.colors) then
        opts.colors = M.colors_for(config)
    end

    local empty_quota = {
        h5_pct = 0,
        h5_reset = nil,
        d7_pct = 0,
        d7_reset = nil
    }
    local cached_claude = empty_quota
    local cached_codex = empty_quota
    local last_update = 0

    local function refresh_quota(force)
        local now = os.time()
        local interval = opts.refresh_interval or M.default_opts.refresh_interval
        if not force and now - last_update < interval then
            return
        end
        last_update = now

        local ok_claude, claude = pcall(M.get_claude_quota, opts.paths and opts.paths.claude_json)
        if ok_claude then
            cached_claude = claude
        end

        local ok_codex, codex = pcall(M.get_codex_quota, opts.paths and opts.paths.codex_sessions)
        if ok_codex then
            cached_codex = codex
        end
    end

    -- Tính quota ngay khi WezTerm khởi động để tab-bar có dữ liệu từ đầu
    refresh_quota(true)

    -- Một handler update-status duy nhất: cập nhật trạng thái agent (cho tab
    -- dots) rồi ghép badge agent + quota Claude/Codex thành 1 right-status.
    wezterm.on('update-status', function(window)
        if opts.agent_status then
            agent_status.cleanup(window)
            agent_status.update_all(window)
        end
        refresh_quota(false)

        local elements = {}
        if opts.agent_status then
            local ok_agent, agent_elems = pcall(agent_status.right_status_elements)
            if ok_agent then
                for _, e in ipairs(agent_elems) do
                    table.insert(elements, e)
                end
            end
        end

        local ok_quota, quota_elems = pcall(M.build_quota_elements, cached_claude, cached_codex, opts)
        if ok_quota then
            for _, e in ipairs(quota_elems) do
                table.insert(elements, e)
            end
        end

        window:set_right_status(wezterm.format(elements))
    end)

    -- Chấm trạng thái agent (working/waiting/idle) trên từng tab, giống
    -- phong cách wezterm-agent-deck.
    if opts.agent_status then
        wezterm.on('format-tab-title', function(tab, tabs, panes, wezterm_config, hover, max_width)
            local ok, elements = pcall(agent_status.tab_title_elements, tab)
            if ok then
                return elements
            end
            return nil
        end)
    end
end

return M
