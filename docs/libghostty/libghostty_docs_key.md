[Logo] libghostty
Loading...
Searching...
No Matches
Key Encoding
***** Detailed Description *****
Utilities for encoding key events into terminal escape sequences, supporting both legacy encoding as well as Kitty
Keyboard Protocol.
Basic Usage
   1. Create an encoder instance with ghostty_key_encoder_new()
   2. Configure encoder options with ghostty_key_encoder_setopt().
   3. For each key event:
          o Create a key event with ghostty_key_event_new()
          o Set event properties (action, key, modifiers, etc.)
          o Encode with ghostty_key_encoder_encode()
          o Free the event with ghostty_key_event_free()
          o Note: You can also reuse the same key event multiple times by changing its properties.
   4. Free the encoder with ghostty_key_encoder_free() when done
Example
#include <assert.h>
#include <stdio.h>
#include <ghostty/vt.h>
int main() {
// Create encoder
GhosttyKeyEncoder encoder;
GhosttyResult result = ghostty_key_encoder_new(NULL, &encoder);
assert(result == GHOSTTY_SUCCESS);
// Enable Kitty keyboard protocol with all features
ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS,
&(uint8_t){GHOSTTY_KITTY_KEY_ALL});
// Create and configure key event for Ctrl+C press
GhosttyKeyEvent event;
result = ghostty_key_event_new(NULL, &event);
assert(result == GHOSTTY_SUCCESS);
ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS);
ghostty_key_event_set_key(event, GHOSTTY_KEY_C);
ghostty_key_event_set_mods(event, GHOSTTY_MODS_CTRL);
// Encode the key event
char buf[128];
size_t written = 0;
result = ghostty_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
assert(result == GHOSTTY_SUCCESS);
// Use the encoded sequence (e.g., write to terminal)
fwrite(buf, 1, written, stdout);
// Cleanup
ghostty_key_event_free(event);
ghostty_key_encoder_free(encoder);
return 0;
}
GHOSTTY_KITTY_KEY_ALL
#define GHOSTTY_KITTY_KEY_ALL
Definition encoder.h:56
GHOSTTY_MODS_CTRL
#define GHOSTTY_MODS_CTRL
Definition event.h:61
ghostty_key_event_set_mods
void ghostty_key_event_set_mods(GhosttyKeyEvent event, GhosttyMods mods)
GhosttyKeyEncoder
struct GhosttyKeyEncoder * GhosttyKeyEncoder
Definition encoder.h:24
ghostty_key_event_set_action
void ghostty_key_event_set_action(GhosttyKeyEvent event, GhosttyKeyAction action)
ghostty_key_encoder_new
GhosttyResult ghostty_key_encoder_new(const GhosttyAllocator *allocator, GhosttyKeyEncoder *encoder)
ghostty_key_event_new
GhosttyResult ghostty_key_event_new(const GhosttyAllocator *allocator, GhosttyKeyEvent *event)
ghostty_key_encoder_setopt
void ghostty_key_encoder_setopt(GhosttyKeyEncoder encoder, GhosttyKeyEncoderOption option, const void *value)
GhosttyKeyEvent
struct GhosttyKeyEvent * GhosttyKeyEvent
Definition event.h:24
ghostty_key_encoder_encode
GhosttyResult ghostty_key_encoder_encode(GhosttyKeyEncoder encoder, GhosttyKeyEvent event, char *out_buf, size_t out_
buf_size, size_t *out_len)
ghostty_key_encoder_free
void ghostty_key_encoder_free(GhosttyKeyEncoder encoder)
ghostty_key_event_free
void ghostty_key_event_free(GhosttyKeyEvent event)
ghostty_key_event_set_key
void ghostty_key_event_set_key(GhosttyKeyEvent event, GhosttyKey key)
GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS
@ GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS
Definition encoder.h:102
GHOSTTY_KEY_ACTION_PRESS
@ GHOSTTY_KEY_ACTION_PRESS
Definition event.h:35
GhosttyResult
GhosttyResult
Definition result.h:13
GHOSTTY_SUCCESS
@ GHOSTTY_SUCCESS
Definition result.h:15
vt.h
For a complete working example, see example/c-vt-key-encode in the repository.
Typedefs
typedef struct GhosttyKeyEncoder *  GhosttyKeyEncoder
                   typedef uint8_t  GhosttyKittyKeyFlags
  typedef struct GhosttyKeyEvent *  GhosttyKeyEvent
                  typedef uint16_t  GhosttyMods
Enumerations
enum   GhosttyOptionAsAlt { GHOSTTY_OPTION_AS_ALT_FALSE = 0 , GHOSTTY_OPTION_AS_ALT_TRUE = 1 , GHOSTTY_OPTION_AS_ALT_
       LEFT = 2 , GHOSTTY_OPTION_AS_ALT_RIGHT = 3 }
enum   GhosttyKeyEncoderOption {
         GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION = 0 , GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION = 1 ,
       GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK = 2 , GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX = 3 ,
         GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2 = 4 , GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS = 5 , GHOSTTY_KEY_
       ENCODER_OPT_MACOS_OPTION_AS_ALT = 6
       }
enum   GhosttyKeyAction { GHOSTTY_KEY_ACTION_RELEASE = 0 , GHOSTTY_KEY_ACTION_PRESS = 1 , GHOSTTY_KEY_ACTION_REPEAT = 2
       }
enum   GhosttyKey
Functions
   GhosttyResult  ghostty_key_encoder_new (const GhosttyAllocator *allocator, GhosttyKeyEncoder *encoder)
            void  ghostty_key_encoder_free (GhosttyKeyEncoder encoder)
            void  ghostty_key_encoder_setopt (GhosttyKeyEncoder encoder, GhosttyKeyEncoderOption option, const void
                  *value)
   GhosttyResult  ghostty_key_encoder_encode (GhosttyKeyEncoder encoder, GhosttyKeyEvent event, char *out_buf, size_
                  t out_buf_size, size_t *out_len)
   GhosttyResult  ghostty_key_event_new (const GhosttyAllocator *allocator, GhosttyKeyEvent *event)
            void  ghostty_key_event_free (GhosttyKeyEvent event)
            void  ghostty_key_event_set_action (GhosttyKeyEvent event, GhosttyKeyAction action)
GhosttyKeyAction  ghostty_key_event_get_action (GhosttyKeyEvent event)
            void  ghostty_key_event_set_key (GhosttyKeyEvent event, GhosttyKey key)
      GhosttyKey  ghostty_key_event_get_key (GhosttyKeyEvent event)
            void  ghostty_key_event_set_mods (GhosttyKeyEvent event, GhosttyMods mods)
     GhosttyMods  ghostty_key_event_get_mods (GhosttyKeyEvent event)
            void  ghostty_key_event_set_consumed_mods (GhosttyKeyEvent event, GhosttyMods consumed_mods)
     GhosttyMods  ghostty_key_event_get_consumed_mods (GhosttyKeyEvent event)
            void  ghostty_key_event_set_composing (GhosttyKeyEvent event, bool composing)
            bool  ghostty_key_event_get_composing (GhosttyKeyEvent event)
            void  ghostty_key_event_set_utf8 (GhosttyKeyEvent event, const char *utf8, size_t len)
    const char *  ghostty_key_event_get_utf8 (GhosttyKeyEvent event, size_t *len)
            void  ghostty_key_event_set_unshifted_codepoint (GhosttyKeyEvent event, uint32_t codepoint)
        uint32_t  ghostty_key_event_get_unshifted_codepoint (GhosttyKeyEvent event)
***** Typedef Documentation *****
***** ◆ GhosttyKeyEncoder *****
typedef struct GhosttyKeyEncoder* GhosttyKeyEncoder
Opaque handle to a key encoder instance.
This handle represents a key encoder that converts key events into terminal escape sequences.
  Examples
      c-vt-key-encode/src/main.c.
Definition at line 24 of file encoder.h.
***** ◆ GhosttyKeyEvent *****
typedef struct GhosttyKeyEvent* GhosttyKeyEvent
Opaque handle to a key event.
This handle represents a keyboard input event containing information about the physical key pressed, modifiers, and
generated text.
  Examples
      c-vt-key-encode/src/main.c.
Definition at line 24 of file event.h.
***** ◆ GhosttyKittyKeyFlags *****
typedef uint8_t GhosttyKittyKeyFlags
Kitty keyboard protocol flags.
Bitflags representing the various modes of the Kitty keyboard protocol. These can be combined using bitwise OR
operations. Valid values all start with GHOSTTY_KITTY_KEY_.
Definition at line 35 of file encoder.h.
***** ◆ GhosttyMods *****
typedef uint16_t GhosttyMods
Keyboard modifier keys bitmask.
A bitmask representing all keyboard modifiers. This tracks which modifier keys are pressed and, where supported by the
platform, which side (left or right) of each modifier is active.
Use the GHOSTTY_MODS_* constants to test and set individual modifiers.
Modifier side bits are only meaningful when the corresponding modifier bit is set. Not all platforms support
distinguishing between left and right modifier keys and Ghostty is built to expect that some platforms may not provide
this information.
Definition at line 56 of file event.h.
***** Enumeration Type Documentation *****
***** ◆ GhosttyKey *****
enum GhosttyKey
Physical key codes.
The set of key codes that Ghostty is aware of. These represent physical keys on the keyboard and are layout-independent.
For example, the "a" key on a US keyboard is the same as the "Ñ" key on a Russian keyboard, but both will report the
same key_a value.
Layout-dependent strings are provided separately as UTF-8 text and are produced by the platform. These values are based
on the W3C UI Events KeyboardEvent code standard. See: https://www.w3.org/TR/uievents-code
Definition at line 106 of file event.h.
***** ◆ GhosttyKeyAction *****
enum GhosttyKeyAction
Keyboard input event types.
Enumerator
GHOSTTY_KEY_ACTION_RELEASE  Key was released
GHOSTTY_KEY_ACTION_PRESS    Key was pressed
GHOSTTY_KEY_ACTION_REPEAT   Key is being repeated (held down)
Definition at line 31 of file event.h.
***** ◆ GhosttyKeyEncoderOption *****
enum GhosttyKeyEncoderOption
Key encoder option identifiers.
These values are used with ghostty_key_encoder_setopt() to configure the behavior of the key encoder.
Enumerator
GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION      Terminal DEC mode 1: cursor key application mode (value: bool)
GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION      Terminal DEC mode 66: keypad key application mode (value: bool)
GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK  Terminal DEC mode 1035: ignore keypad with numlock (value: bool)
GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX              Terminal DEC mode 1036: alt sends escape prefix (value: bool)
GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2   xterm modifyOtherKeys mode 2 (value: bool)
GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS                 Kitty keyboard protocol flags (value: GhosttyKittyKeyFlags bitmask)
GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT         macOS option-as-alt setting (value: GhosttyOptionAsAlt)
Definition at line 85 of file encoder.h.
***** ◆ GhosttyOptionAsAlt *****
enum GhosttyOptionAsAlt
macOS option key behavior.
Determines whether the "option" key on macOS is treated as "alt" or not. See the Ghostty macos-option-as-alt
configuration option for more details.
Enumerator
GHOSTTY_OPTION_AS_ALT_FALSE  Option key is not treated as alt
GHOSTTY_OPTION_AS_ALT_TRUE   Option key is treated as alt
GHOSTTY_OPTION_AS_ALT_LEFT   Only left option key is treated as alt
GHOSTTY_OPTION_AS_ALT_RIGHT  Only right option key is treated as alt
Definition at line 66 of file encoder.h.
***** Function Documentation *****
***** ◆ ghostty_key_encoder_encode() *****
GhosttyResult ghostty_key_encoder_encode ( GhosttyKeyEncoder encoder,
                                           GhosttyKeyEvent   event,
                                           char *            out_buf,
                                           size_t            out_buf_size,
                                           size_t *          out_len )
Encode a key event into a terminal escape sequence.
Converts a key event into the appropriate terminal escape sequence based on the encoder's current options. The sequence
is written to the provided buffer.
Not all key events produce output. For example, unmodified modifier keys typically don't generate escape sequences.
Check the out_len parameter to determine if any data was written.
If the output buffer is too small, this function returns GHOSTTY_OUT_OF_MEMORY and out_len will contain the required
buffer size. The caller can then allocate a larger buffer and call the function again.
  Parameters
      encoder      The encoder handle, must not be NULL
      event        The key event to encode, must not be NULL
      out_buf      Buffer to write the encoded sequence to
      out_buf_size Size of the output buffer in bytes
      out_len      Pointer to store the number of bytes written (may be NULL)
  Returns
      GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY if buffer too small, or other error code
Example: Calculate required buffer size
// Query the required size with a NULL buffer (always returns OUT_OF_MEMORY)
size_t required = 0;
GhosttyResult result = ghostty_key_encoder_encode(encoder, event, NULL, 0, &required);
assert(result == GHOSTTY_OUT_OF_MEMORY);
// Allocate buffer of required size
char *buf = malloc(required);
// Encode with properly sized buffer
size_t written = 0;
result = ghostty_key_encoder_encode(encoder, event, buf, required, &written);
assert(result == GHOSTTY_SUCCESS);
// Use the encoded sequence...
free(buf);
GHOSTTY_OUT_OF_MEMORY
@ GHOSTTY_OUT_OF_MEMORY
Definition result.h:17
Example: Direct encoding with static buffer
// Most escape sequences are short, so a static buffer often suffices
char buf[128];
size_t written = 0;
GhosttyResult result = ghostty_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
if (result == GHOSTTY_SUCCESS) {
// Write the encoded sequence to the terminal
write(pty_fd, buf, written);
} else if (result == GHOSTTY_OUT_OF_MEMORY) {
// Buffer too small, written contains required size
char *dynamic_buf = malloc(written);
result = ghostty_key_encoder_encode(encoder, event, dynamic_buf, written, &written);
assert(result == GHOSTTY_SUCCESS);
write(pty_fd, dynamic_buf, written);
free(dynamic_buf);
}
  Examples
      c-vt-key-encode/src/main.c.
***** ◆ ghostty_key_encoder_free() *****
void ghostty_key_encoder_free ( GhosttyKeyEncoder encoder )
Free a key encoder instance.
Releases all resources associated with the key encoder. After this call, the encoder handle becomes invalid and must not
be used.
  Parameters
      encoder The encoder handle to free (may be NULL)
  Examples
      c-vt-key-encode/src/main.c.
***** ◆ ghostty_key_encoder_new() *****
GhosttyResult ghostty_key_encoder_new ( const GhosttyAllocator * allocator,
                                        GhosttyKeyEncoder *      encoder )
Create a new key encoder instance.
Creates a new key encoder with default options. The encoder can be configured using ghostty_key_encoder_setopt() and
must be freed using ghostty_key_encoder_free() when no longer needed.
  Parameters
      allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
      encoder   Pointer to store the created encoder handle
  Returns
      GHOSTTY_SUCCESS on success, or an error code on failure
  Examples
      c-vt-key-encode/src/main.c.
***** ◆ ghostty_key_encoder_setopt() *****
void ghostty_key_encoder_setopt ( GhosttyKeyEncoder       encoder,
                                  GhosttyKeyEncoderOption option,
                                  const void *            value )
Set an option on the key encoder.
Configures the behavior of the key encoder. Options control various aspects of encoding such as terminal modes (cursor
key application mode, keypad mode), protocol selection (Kitty keyboard protocol flags), and platform-specific behaviors
(macOS option-as-alt).
A null pointer value does nothing. It does not reset the value to the default. The setopt call will do nothing.
  Parameters
      encoder The encoder handle, must not be NULL
      option  The option to set
      value   Pointer to the value to set (type depends on the option)
  Examples
      c-vt-key-encode/src/main.c.
***** ◆ ghostty_key_event_free() *****
void ghostty_key_event_free ( GhosttyKeyEvent event )
Free a key event instance.
Releases all resources associated with the key event. After this call, the event handle becomes invalid and must not be
used.
  Parameters
      event The key event handle to free (may be NULL)
  Examples
      c-vt-key-encode/src/main.c.
***** ◆ ghostty_key_event_get_action() *****
GhosttyKeyAction ghostty_key_event_get_action ( GhosttyKeyEvent event )
Get the key action (press, release, repeat).
  Parameters
      event The key event handle, must not be NULL
  Returns
      The key action
***** ◆ ghostty_key_event_get_composing() *****
bool ghostty_key_event_get_composing ( GhosttyKeyEvent event )
Get whether the key event is part of a composition sequence.
  Parameters
      event The key event handle, must not be NULL
  Returns
      Whether the key event is part of a composition sequence
***** ◆ ghostty_key_event_get_consumed_mods() *****
GhosttyMods ghostty_key_event_get_consumed_mods ( GhosttyKeyEvent event )
Get the consumed modifiers bitmask.
  Parameters
      event The key event handle, must not be NULL
  Returns
      The consumed modifiers bitmask
***** ◆ ghostty_key_event_get_key() *****
GhosttyKey ghostty_key_event_get_key ( GhosttyKeyEvent event )
Get the physical key code.
  Parameters
      event The key event handle, must not be NULL
  Returns
      The physical key code
***** ◆ ghostty_key_event_get_mods() *****
GhosttyMods ghostty_key_event_get_mods ( GhosttyKeyEvent event )
Get the modifier keys bitmask.
  Parameters
      event The key event handle, must not be NULL
  Returns
      The modifier keys bitmask
***** ◆ ghostty_key_event_get_unshifted_codepoint() *****
uint32_t ghostty_key_event_get_unshifted_codepoint ( GhosttyKeyEvent event )
Get the unshifted Unicode codepoint.
  Parameters
      event The key event handle, must not be NULL
  Returns
      The unshifted Unicode codepoint
***** ◆ ghostty_key_event_get_utf8() *****
const char * ghostty_key_event_get_utf8 ( GhosttyKeyEvent event,
                                          size_t *        len )
Get the UTF-8 text generated by the key event.
The returned pointer is valid until the event is freed or the UTF-8 text is modified.
  Parameters
      event The key event handle, must not be NULL
      len   Pointer to store the length of the UTF-8 text in bytes (may be NULL)
  Returns
      The UTF-8 text (or NULL for empty)
***** ◆ ghostty_key_event_new() *****
GhosttyResult ghostty_key_event_new ( const GhosttyAllocator * allocator,
                                      GhosttyKeyEvent *        event )
Create a new key event instance.
Creates a new key event with default values. The event must be freed using ghostty_key_event_free() when no longer
needed.
  Parameters
      allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
      event     Pointer to store the created key event handle
  Returns
      GHOSTTY_SUCCESS on success, or an error code on failure
  Examples
      c-vt-key-encode/src/main.c.
***** ◆ ghostty_key_event_set_action() *****
void ghostty_key_event_set_action ( GhosttyKeyEvent  event,
                                    GhosttyKeyAction action )
Set the key action (press, release, repeat).
  Parameters
      event  The key event handle, must not be NULL
      action The action to set
  Examples
      c-vt-key-encode/src/main.c.
***** ◆ ghostty_key_event_set_composing() *****
void ghostty_key_event_set_composing ( GhosttyKeyEvent event,
                                       bool            composing )
Set whether the key event is part of a composition sequence.
  Parameters
      event     The key event handle, must not be NULL
      composing Whether the key event is part of a composition sequence
***** ◆ ghostty_key_event_set_consumed_mods() *****
void ghostty_key_event_set_consumed_mods ( GhosttyKeyEvent event,
                                           GhosttyMods     consumed_mods )
Set the consumed modifiers bitmask.
  Parameters
      event         The key event handle, must not be NULL
      consumed_mods The consumed modifiers bitmask to set
***** ◆ ghostty_key_event_set_key() *****
void ghostty_key_event_set_key ( GhosttyKeyEvent event,
                                 GhosttyKey      key )
Set the physical key code.
  Parameters
      event The key event handle, must not be NULL
      key   The physical key code to set
  Examples
      c-vt-key-encode/src/main.c.
***** ◆ ghostty_key_event_set_mods() *****
void ghostty_key_event_set_mods ( GhosttyKeyEvent event,
                                  GhosttyMods     mods )
Set the modifier keys bitmask.
  Parameters
      event The key event handle, must not be NULL
      mods  The modifier keys bitmask to set
  Examples
      c-vt-key-encode/src/main.c.
***** ◆ ghostty_key_event_set_unshifted_codepoint() *****
void ghostty_key_event_set_unshifted_codepoint ( GhosttyKeyEvent event,
                                                 uint32_t        codepoint )
Set the unshifted Unicode codepoint.
  Parameters
      event     The key event handle, must not be NULL
      codepoint The unshifted Unicode codepoint to set
***** ◆ ghostty_key_event_set_utf8() *****
void ghostty_key_event_set_utf8 ( GhosttyKeyEvent event,
                                  const char *    utf8,
                                  size_t          len )
Set the UTF-8 text generated by the key event.
The key event does NOT take ownership of the text pointer. The caller must ensure the string remains valid for the
lifetime needed by the event.
  Parameters
      event The key event handle, must not be NULL
      utf8  The UTF-8 text to set (or NULL for empty)
      len   Length of the UTF-8 text in bytes
    * Generated by [doxygen]1.14.0
