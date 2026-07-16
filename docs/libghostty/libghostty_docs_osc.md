[Logo] libghostty
Loading...
Searching...
No Matches
OSC Parser
***** Detailed Description *****
OSC (Operating System Command) sequence parser and command handling.
The parser operates in a streaming fashion, processing input byte-by-byte to handle OSC sequences that may arrive in
fragments across multiple reads. This interface makes it easy to integrate into most environments and avoids over-
allocating buffers.
Basic Usage
   1. Create a parser instance with ghostty_osc_new()
   2. Feed bytes to the parser using ghostty_osc_next()
   3. Finalize parsing with ghostty_osc_end() to get the command
   4. Query command type and extract data using ghostty_osc_command_type() and ghostty_osc_command_data()
   5. Free the parser with ghostty_osc_free() when done
Typedefs
 typedef struct GhosttyOscParser *  GhosttyOscParser
typedef struct GhosttyOscCommand *  GhosttyOscCommand
Enumerations
enum   GhosttyOscCommandType
enum   GhosttyOscCommandData { GHOSTTY_OSC_DATA_INVALID = 0 , GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR = 1 }
Functions
        GhosttyResult  ghostty_osc_new (const GhosttyAllocator *allocator, GhosttyOscParser *parser)
                 void  ghostty_osc_free (GhosttyOscParser parser)
                 void  ghostty_osc_reset (GhosttyOscParser parser)
                 void  ghostty_osc_next (GhosttyOscParser parser, uint8_t byte)
    GhosttyOscCommand  ghostty_osc_end (GhosttyOscParser parser, uint8_t terminator)
GhosttyOscCommandType  ghostty_osc_command_type (GhosttyOscCommand command)
                 bool  ghostty_osc_command_data (GhosttyOscCommand command, GhosttyOscCommandData data, void *out)
***** Typedef Documentation *****
***** ◆ GhosttyOscCommand *****
typedef struct GhosttyOscCommand* GhosttyOscCommand
Opaque handle to a single OSC command.
This handle represents a parsed OSC (Operating System Command) command. The command can be queried for its type and
associated data.
  Examples
      c-vt/src/main.c.
Definition at line 34 of file osc.h.
***** ◆ GhosttyOscParser *****
typedef struct GhosttyOscParser* GhosttyOscParser
Opaque handle to an OSC parser instance.
This handle represents an OSC (Operating System Command) parser that can be used to parse the contents of OSC sequences.
  Examples
      c-vt/src/main.c.
Definition at line 24 of file osc.h.
***** Enumeration Type Documentation *****
***** ◆ GhosttyOscCommandData *****
enum GhosttyOscCommandData
OSC command data types.
These values specify what type of data to extract from an OSC command using ghostty_osc_command_data.
Enumerator
GHOSTTY_OSC_DATA_INVALID                  Invalid data type. Never results in any data extraction.
                                          Window title string data.
                                          Valid for: GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE
GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR  Output type: const char ** (pointer to null-terminated string)
                                          Lifetime: Valid until the next call to any ghostty_osc_* function with the
                                          same parser instance. Memory is owned by the parser.
Definition at line 94 of file osc.h.
***** ◆ GhosttyOscCommandType *****
enum GhosttyOscCommandType
OSC command types.
  Examples
      c-vt/src/main.c.
Definition at line 62 of file osc.h.
***** Function Documentation *****
***** ◆ ghostty_osc_command_data() *****
bool ghostty_osc_command_data ( GhosttyOscCommand     command,
                                GhosttyOscCommandData data,
                                void *                out )
Extract data from an OSC command.
Extracts typed data from the given OSC command based on the specified data type. The output pointer must be of the
appropriate type for the requested data kind. Valid command types, output types, and memory safety information are
documented in the GhosttyOscCommandData enum.
  Parameters
      command The OSC command handle to query (may be NULL)
      data    The type of data to extract
      out     Pointer to store the extracted data (type depends on data parameter)
  Returns
      true if data extraction was successful, false otherwise
  Examples
      c-vt/src/main.c.
***** ◆ ghostty_osc_command_type() *****
GhosttyOscCommandType ghostty_osc_command_type ( GhosttyOscCommand command )
Get the type of an OSC command.
Returns the type identifier for the given OSC command. This can be used to determine what kind of command was parsed and
what data might be available from it.
  Parameters
      command The OSC command handle to query (may be NULL)
  Returns
      The command type, or GHOSTTY_OSC_COMMAND_INVALID if command is NULL
  Examples
      c-vt/src/main.c.
***** ◆ ghostty_osc_end() *****
GhosttyOscCommand ghostty_osc_end ( GhosttyOscParser parser,
                                    uint8_t          terminator )
Finalize OSC parsing and retrieve the parsed command.
Call this function after feeding all bytes of an OSC sequence to the parser using ghostty_osc_next() with the exception
of the terminating character (ESC or ST). This function finalizes the parsing process and returns the parsed OSC
command.
The return value is never NULL. Invalid commands will return a command with type GHOSTTY_OSC_COMMAND_INVALID.
The terminator parameter specifies the byte that terminated the OSC sequence (typically 0x07 for BEL or 0x5C for ST
after ESC). This information is preserved in the parsed command so that responses can use the same terminator format for
better compatibility with the calling program. For commands that do not require a response, this parameter is ignored
and the resulting command will not retain the terminator information.
The returned command handle is valid until the next call to any ghostty_osc_* function with the same parser instance
with the exception of command introspection functions such as ghostty_osc_command_type.
  Parameters
      parser     The parser handle, must not be null.
      terminator The terminating byte of the OSC sequence (0x07 for BEL, 0x5C for ST)
  Returns
      Handle to the parsed OSC command
  Examples
      c-vt/src/main.c.
***** ◆ ghostty_osc_free() *****
void ghostty_osc_free ( GhosttyOscParser parser )
Free an OSC parser instance.
Releases all resources associated with the OSC parser. After this call, the parser handle becomes invalid and must not
be used.
  Parameters
      parser The parser handle to free (may be NULL)
  Examples
      c-vt/src/main.c.
***** ◆ ghostty_osc_new() *****
GhosttyResult ghostty_osc_new ( const GhosttyAllocator * allocator,
                                GhosttyOscParser *       parser )
Create a new OSC parser instance.
Creates a new OSC (Operating System Command) parser using the provided allocator. The parser must be freed using
ghostty_vt_osc_free() when no longer needed.
  Parameters
      allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
      parser    Pointer to store the created parser handle
  Returns
      GHOSTTY_SUCCESS on success, or an error code on failure
  Examples
      c-vt/src/main.c.
***** ◆ ghostty_osc_next() *****
void ghostty_osc_next ( GhosttyOscParser parser,
                        uint8_t          byte )
Parse the next byte in an OSC sequence.
Processes a single byte as part of an OSC sequence. The parser maintains internal state to track the progress through
the sequence. Call this function for each byte in the sequence data.
When finished pumping the parser with bytes, call ghostty_osc_end to get the final result.
  Parameters
      parser The parser handle, must not be null.
      byte   The next byte to parse
  Examples
      c-vt/src/main.c.
***** ◆ ghostty_osc_reset() *****
void ghostty_osc_reset ( GhosttyOscParser parser )
Reset an OSC parser instance to its initial state.
Resets the parser state, clearing any partially parsed OSC sequences and returning the parser to its initial state. This
is useful for reusing a parser instance or recovering from parse errors.
  Parameters
      parser The parser handle to reset, must not be null.
    * Generated by [doxygen]1.14.0
