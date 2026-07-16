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
pub const SGR_ATTR_BLINK = c.GHOSTTY_SGR_ATTR_BLINK;
pub const SGR_ATTR_RESET_BLINK = c.GHOSTTY_SGR_ATTR_RESET_BLINK;
pub const SGR_ATTR_UNDERLINE = c.GHOSTTY_SGR_ATTR_UNDERLINE;
pub const SGR_ATTR_RESET_UNDERLINE = c.GHOSTTY_SGR_ATTR_RESET_UNDERLINE;
pub const SGR_ATTR_INVERSE = c.GHOSTTY_SGR_ATTR_INVERSE;
pub const SGR_ATTR_RESET_INVERSE = c.GHOSTTY_SGR_ATTR_RESET_INVERSE;
pub const SGR_ATTR_STRIKETHROUGH = c.GHOSTTY_SGR_ATTR_STRIKETHROUGH;
pub const SGR_ATTR_RESET_STRIKETHROUGH = c.GHOSTTY_SGR_ATTR_RESET_STRIKETHROUGH;
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

// Key codes - using proper GhosttyKey enum from C API
// The GhosttyKey enum is a sequential enum based on W3C UI Events KeyboardEvent code standard
pub const Key = c.GhosttyKey;

// Common keys (from GhosttyKey enum in event.h)
pub const KEY_ENTER = c.GHOSTTY_KEY_ENTER;
pub const KEY_RETURN = c.GHOSTTY_KEY_ENTER; // Alias for compatibility
pub const KEY_ESCAPE = c.GHOSTTY_KEY_ESCAPE;
pub const KEY_BACKSPACE = c.GHOSTTY_KEY_BACKSPACE;
pub const KEY_TAB = c.GHOSTTY_KEY_TAB;
pub const KEY_SPACE = c.GHOSTTY_KEY_SPACE;
pub const KEY_DELETE = c.GHOSTTY_KEY_DELETE;

// Navigation keys
pub const KEY_HOME = c.GHOSTTY_KEY_HOME;
pub const KEY_PAGE_UP = c.GHOSTTY_KEY_PAGE_UP;
pub const KEY_END = c.GHOSTTY_KEY_END;
pub const KEY_PAGE_DOWN = c.GHOSTTY_KEY_PAGE_DOWN;

// Arrow keys
pub const KEY_ARROW_DOWN = c.GHOSTTY_KEY_ARROW_DOWN;
pub const KEY_ARROW_LEFT = c.GHOSTTY_KEY_ARROW_LEFT;
pub const KEY_ARROW_RIGHT = c.GHOSTTY_KEY_ARROW_RIGHT;
pub const KEY_ARROW_UP = c.GHOSTTY_KEY_ARROW_UP;
// Legacy aliases for compatibility
pub const KEY_DOWN = c.GHOSTTY_KEY_ARROW_DOWN;
pub const KEY_LEFT = c.GHOSTTY_KEY_ARROW_LEFT;
pub const KEY_RIGHT = c.GHOSTTY_KEY_ARROW_RIGHT;
pub const KEY_UP = c.GHOSTTY_KEY_ARROW_UP;

// Function keys (F1-F12)
pub const KEY_F1 = c.GHOSTTY_KEY_F1;
pub const KEY_F2 = c.GHOSTTY_KEY_F2;
pub const KEY_F3 = c.GHOSTTY_KEY_F3;
pub const KEY_F4 = c.GHOSTTY_KEY_F4;
pub const KEY_F5 = c.GHOSTTY_KEY_F5;
pub const KEY_F6 = c.GHOSTTY_KEY_F6;
pub const KEY_F7 = c.GHOSTTY_KEY_F7;
pub const KEY_F8 = c.GHOSTTY_KEY_F8;
pub const KEY_F9 = c.GHOSTTY_KEY_F9;
pub const KEY_F10 = c.GHOSTTY_KEY_F10;
pub const KEY_F11 = c.GHOSTTY_KEY_F11;
pub const KEY_F12 = c.GHOSTTY_KEY_F12;

// Letter keys (A-Z)
pub const KEY_A = c.GHOSTTY_KEY_A;
pub const KEY_B = c.GHOSTTY_KEY_B;
pub const KEY_C = c.GHOSTTY_KEY_C;
pub const KEY_D = c.GHOSTTY_KEY_D;
pub const KEY_E = c.GHOSTTY_KEY_E;
pub const KEY_F = c.GHOSTTY_KEY_F;
pub const KEY_G = c.GHOSTTY_KEY_G;
pub const KEY_H = c.GHOSTTY_KEY_H;
pub const KEY_I = c.GHOSTTY_KEY_I;
pub const KEY_J = c.GHOSTTY_KEY_J;
pub const KEY_K = c.GHOSTTY_KEY_K;
pub const KEY_L = c.GHOSTTY_KEY_L;
pub const KEY_M = c.GHOSTTY_KEY_M;
pub const KEY_N = c.GHOSTTY_KEY_N;
pub const KEY_O = c.GHOSTTY_KEY_O;
pub const KEY_P = c.GHOSTTY_KEY_P;
pub const KEY_Q = c.GHOSTTY_KEY_Q;
pub const KEY_R = c.GHOSTTY_KEY_R;
pub const KEY_S = c.GHOSTTY_KEY_S;
pub const KEY_T = c.GHOSTTY_KEY_T;
pub const KEY_U = c.GHOSTTY_KEY_U;
pub const KEY_V = c.GHOSTTY_KEY_V;
pub const KEY_W = c.GHOSTTY_KEY_W;
pub const KEY_X = c.GHOSTTY_KEY_X;
pub const KEY_Y = c.GHOSTTY_KEY_Y;
pub const KEY_Z = c.GHOSTTY_KEY_Z;

// Digit keys (0-9)
pub const KEY_DIGIT_0 = c.GHOSTTY_KEY_DIGIT_0;
pub const KEY_DIGIT_1 = c.GHOSTTY_KEY_DIGIT_1;
pub const KEY_DIGIT_2 = c.GHOSTTY_KEY_DIGIT_2;
pub const KEY_DIGIT_3 = c.GHOSTTY_KEY_DIGIT_3;
pub const KEY_DIGIT_4 = c.GHOSTTY_KEY_DIGIT_4;
pub const KEY_DIGIT_5 = c.GHOSTTY_KEY_DIGIT_5;
pub const KEY_DIGIT_6 = c.GHOSTTY_KEY_DIGIT_6;
pub const KEY_DIGIT_7 = c.GHOSTTY_KEY_DIGIT_7;
pub const KEY_DIGIT_8 = c.GHOSTTY_KEY_DIGIT_8;
pub const KEY_DIGIT_9 = c.GHOSTTY_KEY_DIGIT_9;

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
