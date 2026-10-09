local wezterm = require 'wezterm'
local herdr_keys = require 'herdr_keys'
local session_picker = require 'session_picker'
local tabbar = require 'tabbar'

local config = wezterm.config_builder()

-- WezTerm chỉ làm lớp vẽ, mọi tab/pane do Herdr quản lý.
-- setup() lo luôn: HERDR_CONFIG_PATH -> ~/.config/wezterm/herdr.toml, PATH Homebrew,
-- Kitty Keyboard Protocol, và nhường các phím Cmd/Ctrl+Tab xuống Herdr.
-- autostart = false: không attach thẳng vào session 'wezterm' nữa, để session_picker
-- quyết định session nào được mở.
herdr_keys.autostart = false
herdr_keys.setup(config)

-- Mở cửa sổ WezTerm => hiện menu chọn session (InputSelector) lấy từ `herdr session list`.
-- Chọn session -> `herdr session attach <name>`; menu còn có tạo mới / stop / xoá.
-- Cmd+Shift+S mở lại menu bất cứ lúc nào.
session_picker.setup(config, {
    bin = herdr_keys.bin,
    config_path = herdr_keys.config_path,
    auto_show = true,
    key = {
        key = 's',
        mods = 'CMD|SHIFT'
    }
})

config.color_scheme = 'Catppuccin Latte'
config.window_background_opacity = 0.9
config.macos_window_background_blur = 20
config.status_update_interval = 1000

-- Trên macOS, snap kích thước cửa sổ theo cell để không sinh dải pixel dư
-- sau khi double-click titlebar để maximize/restore.
config.use_resize_increments = true

-- Giữ tab-bar để làm thanh hiển thị usage Claude/Codex, nhưng ẩn hết phần tab
-- (Herdr đã có tab riêng) => chỉ còn right-status.
config.enable_tab_bar = true
config.hide_tab_bar_if_only_one_tab = false
config.use_fancy_tab_bar = false
config.show_tabs_in_tab_bar = false
config.show_new_tab_button_in_tab_bar = false
config.tab_bar_at_bottom = true

local scheme = wezterm.color.get_builtin_schemes()[config.color_scheme]
config.colors = {
    tab_bar = {
        background = scheme.background
    }
}
config.window_decorations = "TITLE | RESIZE | MACOS_USE_BACKGROUND_COLOR_AS_TITLEBAR_COLOR"
config.window_frame = {
    active_titlebar_bg = scheme.background,
    inactive_titlebar_bg = scheme.background
}

-- Bảng màu bám theo độ sáng nền của color_scheme đang dùng
local status_colors = tabbar.colors_for(config)

-- Chỉ hiển thị usage Claude/Codex trên tab-bar; tắt badge/chấm trạng thái agent
-- vì dưới Herdr, WezTerm chỉ thấy đúng một tiến trình herdr nên không dò được agent.
tabbar.setup_pane(config, {
    agent_status = false,
    colors = status_colors
})


return config
