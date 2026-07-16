[Logo] libghostty
Loading...
Searching...
No Matches
SGR Parser
***** Detailed Description *****
SGR (Select Graphic Rendition) attribute parser.
SGR sequences are the syntax used to set styling attributes such as bold, italic, underline, and colors for text in
terminal emulators. For example, you may be familiar with sequences like ESC[1;31m. The 1;31 is the SGR attribute list.
The parser processes SGR parameters from CSI sequences (e.g., ESC[1;31m) and returns individual text attributes like
bold, italic, colors, etc. It supports both semicolon (;) and colon (:) separators, possibly mixed, and handles various
color formats including 8-color, 16-color, 256-color, X11 named colors, and RGB in multiple formats.
Basic Usage
   1. Create a parser instance with ghostty_sgr_new()
   2. Set SGR parameters with ghostty_sgr_set_params()
   3. Iterate through attributes using ghostty_sgr_next()
   4. Free the parser with ghostty_sgr_free() when done
Example
#include <assert.h>
#include <stdio.h>
#include <ghostty/vt.h>
int main() {
// Create parser
GhosttySgrParser parser;
GhosttyResult result = ghostty_sgr_new(NULL, &parser);
assert(result == GHOSTTY_SUCCESS);
// Parse "bold, red foreground" sequence: ESC[1;31m
uint16_t params[] = {1, 31};
result = ghostty_sgr_set_params(parser, params, NULL, 2);
assert(result == GHOSTTY_SUCCESS);
// Iterate through attributes
GhosttySgrAttribute attr;
while (ghostty_sgr_next(parser, &attr)) {
switch (attr.tag) {
case GHOSTTY_SGR_ATTR_BOLD:
printf("Bold enabled\n");
break;
case GHOSTTY_SGR_ATTR_FG_8:
printf("Foreground color: %d\n", attr.value.fg_8);
break;
default:
break;
}
}
// Cleanup
ghostty_sgr_free(parser);
return 0;
}
GhosttySgrParser
struct GhosttySgrParser * GhosttySgrParser
Definition sgr.h:93
ghostty_sgr_next
bool ghostty_sgr_next(GhosttySgrParser parser, GhosttySgrAttribute *attr)
ghostty_sgr_new
GhosttyResult ghostty_sgr_new(const GhosttyAllocator *allocator, GhosttySgrParser *parser)
ghostty_sgr_set_params
GhosttyResult ghostty_sgr_set_params(GhosttySgrParser parser, const uint16_t *params, const char *separators, size_
t len)
ghostty_sgr_free
void ghostty_sgr_free(GhosttySgrParser parser)
GhosttyResult
GhosttyResult
Definition result.h:13
GHOSTTY_SUCCESS
@ GHOSTTY_SUCCESS
Definition result.h:15
GhosttySgrAttribute
Definition sgr.h:204
vt.h
Typedefs
                  typedef uint8_t  GhosttyColorPaletteIndex
typedef struct GhosttySgrParser *  GhosttySgrParser
Enumerations
enum   GhosttySgrAttributeTag
enum   GhosttySgrUnderline
Functions
                      void  ghostty_color_rgb_get (GhosttyColorRgb color, uint8_t *r, uint8_t *g, uint8_t *b)
             GhosttyResult  ghostty_sgr_new (const GhosttyAllocator *allocator, GhosttySgrParser *parser)
                      void  ghostty_sgr_free (GhosttySgrParser parser)
                      void  ghostty_sgr_reset (GhosttySgrParser parser)
             GhosttyResult  ghostty_sgr_set_params (GhosttySgrParser parser, const uint16_t *params, const char
                            *separators, size_t len)
                      bool  ghostty_sgr_next (GhosttySgrParser parser, GhosttySgrAttribute *attr)
                    size_t  ghostty_sgr_unknown_full (GhosttySgrUnknown unknown, const uint16_t **ptr)
                    size_t  ghostty_sgr_unknown_partial (GhosttySgrUnknown unknown, const uint16_t **ptr)
    GhosttySgrAttributeTag  ghostty_sgr_attribute_tag (GhosttySgrAttribute attr)
GhosttySgrAttributeValue *  ghostty_sgr_attribute_value (GhosttySgrAttribute *attr)
Macros
#define  GHOSTTY_COLOR_NAMED_BLACK   0
#define  GHOSTTY_COLOR_NAMED_RED   1
#define  GHOSTTY_COLOR_NAMED_GREEN   2
#define  GHOSTTY_COLOR_NAMED_YELLOW   3
#define  GHOSTTY_COLOR_NAMED_BLUE   4
#define  GHOSTTY_COLOR_NAMED_MAGENTA   5
#define  GHOSTTY_COLOR_NAMED_CYAN   6
#define  GHOSTTY_COLOR_NAMED_WHITE   7
#define  GHOSTTY_COLOR_NAMED_BRIGHT_BLACK   8
#define  GHOSTTY_COLOR_NAMED_BRIGHT_RED   9
#define  GHOSTTY_COLOR_NAMED_BRIGHT_GREEN   10
#define  GHOSTTY_COLOR_NAMED_BRIGHT_YELLOW   11
#define  GHOSTTY_COLOR_NAMED_BRIGHT_BLUE   12
#define  GHOSTTY_COLOR_NAMED_BRIGHT_MAGENTA   13
#define  GHOSTTY_COLOR_NAMED_BRIGHT_CYAN   14
#define  GHOSTTY_COLOR_NAMED_BRIGHT_WHITE   15
Data Structures
struct   GhosttyColorRgb
struct   GhosttySgrUnknown
 union   GhosttySgrAttributeValue
struct   GhosttySgrAttribute
***** Typedef Documentation *****
***** ◆ GhosttyColorPaletteIndex *****
typedef uint8_t GhosttyColorPaletteIndex
Palette color index (0-255).
Definition at line 32 of file color.h.
***** ◆ GhosttySgrParser *****
typedef struct GhosttySgrParser* GhosttySgrParser
Opaque handle to an SGR parser instance.
This handle represents an SGR (Select Graphic Rendition) parser that can be used to parse SGR sequences and extract
individual text attributes.
  Examples
      c-vt-sgr/src/main.c.
Definition at line 93 of file sgr.h.
***** Enumeration Type Documentation *****
***** ◆ GhosttySgrAttributeTag *****
enum GhosttySgrAttributeTag
SGR attribute tags.
These values identify the type of an SGR attribute in a tagged union. Use the tag to determine which field in the
attribute value union to access.
Definition at line 103 of file sgr.h.
***** ◆ GhosttySgrUnderline *****
enum GhosttySgrUnderline
Underline style types.
Definition at line 143 of file sgr.h.
***** Function Documentation *****
***** ◆ ghostty_color_rgb_get() *****
void ghostty_color_rgb_get ( GhosttyColorRgb color,
                             uint8_t *       r,
                             uint8_t *       g,
                             uint8_t *       b )
Get the RGB color components.
This function extracts the individual red, green, and blue components from a GhosttyColorRgb value. Primarily useful in
WebAssembly environments where accessing struct fields directly is difficult.
  Parameters
      color The RGB color value
      r     Pointer to store the red component (0-255)
      g     Pointer to store the green component (0-255)
      b     Pointer to store the blue component (0-255)
***** ◆ ghostty_sgr_attribute_tag() *****
GhosttySgrAttributeTag ghostty_sgr_attribute_tag ( GhosttySgrAttribute attr )
Get the tag from an SGR attribute.
This function extracts the tag that identifies which type of attribute this is. Primarily useful in WebAssembly
environments where accessing struct fields directly is difficult.
  Parameters
      attr The SGR attribute
  Returns
      The attribute tag
***** ◆ ghostty_sgr_attribute_value() *****
GhosttySgrAttributeValue * ghostty_sgr_attribute_value ( GhosttySgrAttribute * attr )
Get the value from an SGR attribute.
This function returns a pointer to the value union from an SGR attribute. Use the tag to determine which field of the
union is valid. Primarily useful in WebAssembly environments where accessing struct fields directly is difficult.
  Parameters
      attr Pointer to the SGR attribute
  Returns
      Pointer to the attribute value union
***** ◆ ghostty_sgr_free() *****
void ghostty_sgr_free ( GhosttySgrParser parser )
Free an SGR parser instance.
Releases all resources associated with the SGR parser. After this call, the parser handle becomes invalid and must not
be used. This includes any attributes previously returned by ghostty_sgr_next().
  Parameters
      parser The parser handle to free (may be NULL)
  Examples
      c-vt-sgr/src/main.c.
***** ◆ ghostty_sgr_new() *****
GhosttyResult ghostty_sgr_new ( const GhosttyAllocator * allocator,
                                GhosttySgrParser *       parser )
Create a new SGR parser instance.
Creates a new SGR (Select Graphic Rendition) parser using the provided allocator. The parser must be freed using
ghostty_sgr_free() when no longer needed.
  Parameters
      allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
      parser    Pointer to store the created parser handle
  Returns
      GHOSTTY_SUCCESS on success, or an error code on failure
  Examples
      c-vt-sgr/src/main.c.
***** ◆ ghostty_sgr_next() *****
bool ghostty_sgr_next ( GhosttySgrParser      parser,
                        GhosttySgrAttribute * attr )
Get the next SGR attribute.
Parses and returns the next attribute from the parameter list. Call this function repeatedly until it returns false to
process all attributes in the sequence.
  Parameters
      parser The parser handle, must not be NULL
      attr   Pointer to store the next attribute
  Returns
      true if an attribute was returned, false if no more attributes
  Examples
      c-vt-sgr/src/main.c.
***** ◆ ghostty_sgr_reset() *****
void ghostty_sgr_reset ( GhosttySgrParser parser )
Reset an SGR parser instance to the beginning of the parameter list.
Resets the parser's iteration state without clearing the parameters. After calling this, ghostty_sgr_next() will start
from the beginning of the parameter list again.
  Parameters
      parser The parser handle to reset, must not be NULL
***** ◆ ghostty_sgr_set_params() *****
GhosttyResult ghostty_sgr_set_params ( GhosttySgrParser parser,
                                       const uint16_t * params,
                                       const char *     separators,
                                       size_t           len )
Set SGR parameters for parsing.
Sets the SGR parameter list to parse. Parameters are the numeric values from a CSI SGR sequence (e.g., for ESC[1;31m,
params would be {1, 31}).
The separators array optionally specifies the separator type for each parameter position. Each byte should be either ';'
for semicolon or ':' for colon. This is needed for certain color formats that use colon separators (e.g., ESC[4:3m for
curly underline). Any invalid separator values are treated as semicolons. The separators array must have the same length
as the params array, if it is not NULL.
If separators is NULL, all parameters are assumed to be semicolon-separated.
This function makes an internal copy of the parameter and separator data, so the caller can safely free or modify the
input arrays after this call.
After calling this function, the parser is automatically reset and ready to iterate from the beginning.
  Parameters
      parser     The parser handle, must not be NULL
      params     Array of SGR parameter values
      separators Optional array of separator characters (';' or ':'), or NULL
      len        Number of parameters (and separators if provided)
  Returns
      GHOSTTY_SUCCESS on success, or an error code on failure
  Examples
      c-vt-sgr/src/main.c.
***** ◆ ghostty_sgr_unknown_full() *****
size_t ghostty_sgr_unknown_full ( GhosttySgrUnknown unknown,
                                  const uint16_t ** ptr )
Get the full parameter list from an unknown SGR attribute.
This function retrieves the full parameter list that was provided to the parser when an unknown attribute was
encountered. Primarily useful in WebAssembly environments where accessing struct fields directly is difficult.
  Parameters
      unknown The unknown attribute data
      ptr     Pointer to store the pointer to the parameter array (may be NULL)
  Returns
      The length of the full parameter array
***** ◆ ghostty_sgr_unknown_partial() *****
size_t ghostty_sgr_unknown_partial ( GhosttySgrUnknown unknown,
                                     const uint16_t ** ptr )
Get the partial parameter list from an unknown SGR attribute.
This function retrieves the partial parameter list where parsing stopped when an unknown attribute was encountered.
Primarily useful in WebAssembly environments where accessing struct fields directly is difficult.
  Parameters
      unknown The unknown attribute data
      ptr     Pointer to store the pointer to the parameter array (may be NULL)
  Returns
      The length of the partial parameter array
***** Macro Definition Documentation *****
***** ◆ GHOSTTY_COLOR_NAMED_BLACK *****
#define GHOSTTY_COLOR_NAMED_BLACK   0
Black color (0)
Definition at line 39 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_BLUE *****
#define GHOSTTY_COLOR_NAMED_BLUE   4
Blue color (4)
Definition at line 47 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_BRIGHT_BLACK *****
#define GHOSTTY_COLOR_NAMED_BRIGHT_BLACK   8
Bright black color (8)
Definition at line 55 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_BRIGHT_BLUE *****
#define GHOSTTY_COLOR_NAMED_BRIGHT_BLUE   12
Bright blue color (12)
Definition at line 63 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_BRIGHT_CYAN *****
#define GHOSTTY_COLOR_NAMED_BRIGHT_CYAN   14
Bright cyan color (14)
Definition at line 67 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_BRIGHT_GREEN *****
#define GHOSTTY_COLOR_NAMED_BRIGHT_GREEN   10
Bright green color (10)
Definition at line 59 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_BRIGHT_MAGENTA *****
#define GHOSTTY_COLOR_NAMED_BRIGHT_MAGENTA   13
Bright magenta color (13)
Definition at line 65 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_BRIGHT_RED *****
#define GHOSTTY_COLOR_NAMED_BRIGHT_RED   9
Bright red color (9)
Definition at line 57 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_BRIGHT_WHITE *****
#define GHOSTTY_COLOR_NAMED_BRIGHT_WHITE   15
Bright white color (15)
Definition at line 69 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_BRIGHT_YELLOW *****
#define GHOSTTY_COLOR_NAMED_BRIGHT_YELLOW   11
Bright yellow color (11)
Definition at line 61 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_CYAN *****
#define GHOSTTY_COLOR_NAMED_CYAN   6
Cyan color (6)
Definition at line 51 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_GREEN *****
#define GHOSTTY_COLOR_NAMED_GREEN   2
Green color (2)
Definition at line 43 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_MAGENTA *****
#define GHOSTTY_COLOR_NAMED_MAGENTA   5
Magenta color (5)
Definition at line 49 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_RED *****
#define GHOSTTY_COLOR_NAMED_RED   1
Red color (1)
Definition at line 41 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_WHITE *****
#define GHOSTTY_COLOR_NAMED_WHITE   7
White color (7)
Definition at line 53 of file color.h.
***** ◆ GHOSTTY_COLOR_NAMED_YELLOW *****
#define GHOSTTY_COLOR_NAMED_YELLOW   3
Yellow color (3)
Definition at line 45 of file color.h.
    * Generated by [doxygen]1.14.0
