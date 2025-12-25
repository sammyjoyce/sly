/// Zig bindings for libghostty-vt C API
/// This provides access to the Ghostty virtual terminal library for terminal emulation.

// Import the C headers
pub const c = @cImport({
    @cInclude("ghostty/vt.h");
});

// Re-export common types for convenience
pub const Result = c.GhosttyResult;
pub const Allocator = c.GhosttyAllocator;
pub const AllocatorVtable = c.GhosttyAllocatorVtable;

// Result codes
pub const SUCCESS = c.GHOSTTY_SUCCESS;
pub const OUT_OF_MEMORY = c.GHOSTTY_OUT_OF_MEMORY;
pub const INVALID_VALUE = c.GHOSTTY_INVALID_VALUE;

// Key encoding types
pub const KeyEncoder = c.GhosttyKeyEncoder;
pub const KeyEvent = c.GhosttyKeyEvent;
pub const KeyAction = c.GhosttyKeyAction;
pub const KeyMods = c.GhosttyMods;
pub const KeyEncoderOption = c.GhosttyKeyEncoderOption;
pub const KittyKeyFlags = c.GhosttyKittyKeyFlags;

// Key actions
pub const KEY_ACTION_RELEASE = c.GHOSTTY_KEY_ACTION_RELEASE;
pub const KEY_ACTION_PRESS = c.GHOSTTY_KEY_ACTION_PRESS;
pub const KEY_ACTION_REPEAT = c.GHOSTTY_KEY_ACTION_REPEAT;

// Modifiers
pub const MODS_SHIFT = c.GHOSTTY_MODS_SHIFT;
pub const MODS_CTRL = c.GHOSTTY_MODS_CTRL;
pub const MODS_ALT = c.GHOSTTY_MODS_ALT;
pub const MODS_SUPER = c.GHOSTTY_MODS_SUPER;
pub const MODS_CAPS_LOCK = c.GHOSTTY_MODS_CAPS_LOCK;
pub const MODS_NUM_LOCK = c.GHOSTTY_MODS_NUM_LOCK;

// Kitty keyboard protocol flags
pub const KITTY_KEY_DISABLED = c.GHOSTTY_KITTY_KEY_DISABLED;
pub const KITTY_KEY_DISAMBIGUATE = c.GHOSTTY_KITTY_KEY_DISAMBIGUATE;
pub const KITTY_KEY_REPORT_EVENTS = c.GHOSTTY_KITTY_KEY_REPORT_EVENTS;
pub const KITTY_KEY_REPORT_ALTERNATES = c.GHOSTTY_KITTY_KEY_REPORT_ALTERNATES;
pub const KITTY_KEY_REPORT_ALL = c.GHOSTTY_KITTY_KEY_REPORT_ALL;
pub const KITTY_KEY_REPORT_ASSOCIATED = c.GHOSTTY_KITTY_KEY_REPORT_ASSOCIATED;
pub const KITTY_KEY_ALL = c.GHOSTTY_KITTY_KEY_ALL;

// Key encoder options
pub const KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION = c.GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION;
pub const KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION = c.GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION;
pub const KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK = c.GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK;
pub const KEY_ENCODER_OPT_ALT_ESC_PREFIX = c.GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX;
pub const KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2 = c.GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2;
pub const KEY_ENCODER_OPT_KITTY_FLAGS = c.GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS;
pub const KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT = c.GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT;

// SGR (Select Graphic Rendition) types
pub const SgrParser = c.GhosttySgrParser;
pub const SgrAttribute = c.GhosttySgrAttribute;
pub const SgrAttributeTag = c.GhosttySgrAttributeTag;
pub const SgrUnderline = c.GhosttySgrUnderline;

// SGR attribute tags
pub const SGR_ATTR_UNSET = c.GHOSTTY_SGR_ATTR_UNSET;
pub const SGR_ATTR_UNKNOWN = c.GHOSTTY_SGR_ATTR_UNKNOWN;
pub const SGR_ATTR_BOLD = c.GHOSTTY_SGR_ATTR_BOLD;
pub const SGR_ATTR_RESET_BOLD = c.GHOSTTY_SGR_ATTR_RESET_BOLD;
pub const SGR_ATTR_ITALIC = c.GHOSTTY_SGR_ATTR_ITALIC;
pub const SGR_ATTR_RESET_ITALIC = c.GHOSTTY_SGR_ATTR_RESET_ITALIC;
pub const SGR_ATTR_FAINT = c.GHOSTTY_SGR_ATTR_FAINT;
pub const SGR_ATTR_UNDERLINE = c.GHOSTTY_SGR_ATTR_UNDERLINE;
pub const SGR_ATTR_RESET_UNDERLINE = c.GHOSTTY_SGR_ATTR_RESET_UNDERLINE;
pub const SGR_ATTR_INVERSE = c.GHOSTTY_SGR_ATTR_INVERSE;
pub const SGR_ATTR_RESET_INVERSE = c.GHOSTTY_SGR_ATTR_RESET_INVERSE;
pub const SGR_ATTR_FG_8 = c.GHOSTTY_SGR_ATTR_FG_8;
pub const SGR_ATTR_BG_8 = c.GHOSTTY_SGR_ATTR_BG_8;
pub const SGR_ATTR_FG_256 = c.GHOSTTY_SGR_ATTR_FG_256;
pub const SGR_ATTR_BG_256 = c.GHOSTTY_SGR_ATTR_BG_256;
pub const SGR_ATTR_DIRECT_COLOR_FG = c.GHOSTTY_SGR_ATTR_DIRECT_COLOR_FG;
pub const SGR_ATTR_DIRECT_COLOR_BG = c.GHOSTTY_SGR_ATTR_DIRECT_COLOR_BG;

// SGR underline styles
pub const SGR_UNDERLINE_NONE = c.GHOSTTY_SGR_UNDERLINE_NONE;
pub const SGR_UNDERLINE_SINGLE = c.GHOSTTY_SGR_UNDERLINE_SINGLE;
pub const SGR_UNDERLINE_DOUBLE = c.GHOSTTY_SGR_UNDERLINE_DOUBLE;
pub const SGR_UNDERLINE_CURLY = c.GHOSTTY_SGR_UNDERLINE_CURLY;
pub const SGR_UNDERLINE_DOTTED = c.GHOSTTY_SGR_UNDERLINE_DOTTED;
pub const SGR_UNDERLINE_DASHED = c.GHOSTTY_SGR_UNDERLINE_DASHED;

// SGR functions
pub const sgr_new = c.ghostty_sgr_new;
pub const sgr_free = c.ghostty_sgr_free;
pub const sgr_set_params = c.ghostty_sgr_set_params;
pub const sgr_next = c.ghostty_sgr_next;

// OSC (Operating System Command) types
pub const OscParser = c.GhosttyOscParser;
pub const OscCommand = c.GhosttyOscCommand;
pub const OscCommandType = c.GhosttyOscCommandType;
pub const OscCommandData = c.GhosttyOscCommandData;

// OSC command types
pub const OSC_COMMAND_INVALID = c.GHOSTTY_OSC_COMMAND_INVALID;
pub const OSC_COMMAND_CHANGE_WINDOW_TITLE = c.GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE;
pub const OSC_COMMAND_CHANGE_WINDOW_ICON = c.GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_ICON;
pub const OSC_COMMAND_PROMPT_START = c.GHOSTTY_OSC_COMMAND_PROMPT_START;
pub const OSC_COMMAND_PROMPT_END = c.GHOSTTY_OSC_COMMAND_PROMPT_END;
pub const OSC_COMMAND_END_OF_INPUT = c.GHOSTTY_OSC_COMMAND_END_OF_INPUT;
pub const OSC_COMMAND_END_OF_COMMAND = c.GHOSTTY_OSC_COMMAND_END_OF_COMMAND;
pub const OSC_COMMAND_CLIPBOARD_CONTENTS = c.GHOSTTY_OSC_COMMAND_CLIPBOARD_CONTENTS;
pub const OSC_COMMAND_REPORT_PWD = c.GHOSTTY_OSC_COMMAND_REPORT_PWD;
pub const OSC_COMMAND_MOUSE_SHAPE = c.GHOSTTY_OSC_COMMAND_MOUSE_SHAPE;
pub const OSC_COMMAND_COLOR_OPERATION = c.GHOSTTY_OSC_COMMAND_COLOR_OPERATION;
pub const OSC_COMMAND_KITTY_COLOR_PROTOCOL = c.GHOSTTY_OSC_COMMAND_KITTY_COLOR_PROTOCOL;
pub const OSC_COMMAND_SHOW_DESKTOP_NOTIFICATION = c.GHOSTTY_OSC_COMMAND_SHOW_DESKTOP_NOTIFICATION;
pub const OSC_COMMAND_HYPERLINK_START = c.GHOSTTY_OSC_COMMAND_HYPERLINK_START;
pub const OSC_COMMAND_HYPERLINK_END = c.GHOSTTY_OSC_COMMAND_HYPERLINK_END;

// OSC data types
pub const OSC_DATA_CHANGE_WINDOW_TITLE_STR = c.GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR;

// OSC functions
pub const osc_new = c.ghostty_osc_new;
pub const osc_free = c.ghostty_osc_free;
pub const osc_reset = c.ghostty_osc_reset;
pub const osc_next = c.ghostty_osc_next;
pub const osc_end = c.ghostty_osc_end;
pub const osc_command_type = c.ghostty_osc_command_type;
pub const osc_command_data = c.ghostty_osc_command_data;

// Paste utilities
pub const paste_is_safe = c.ghostty_paste_is_safe;

// Color types
pub const Color = c.GhosttyColor;
pub const ColorRGB = c.GhosttyColorRGB;

// Key encoding functions
pub const key_encoder_new = c.ghostty_key_encoder_new;
pub const key_encoder_free = c.ghostty_key_encoder_free;
pub const key_encoder_setopt = c.ghostty_key_encoder_setopt;
pub const key_encoder_encode = c.ghostty_key_encoder_encode;

pub const key_event_new = c.ghostty_key_event_new;
pub const key_event_free = c.ghostty_key_event_free;
pub const key_event_set_action = c.ghostty_key_event_set_action;
pub const key_event_set_key = c.ghostty_key_event_set_key;
pub const key_event_set_mods = c.ghostty_key_event_set_mods;
pub const key_event_set_utf8 = c.ghostty_key_event_set_utf8;

// Helper function to check if a result is successful
pub fn isSuccess(result: Result) bool {
    return result == SUCCESS;
}

// Helper function to get a result error message
pub fn resultMessage(result: Result) []const u8 {
    return switch (result) {
        SUCCESS => "success",
        OUT_OF_MEMORY => "out of memory",
        INVALID_VALUE => "invalid value",
        else => "unknown error",
    };
}
