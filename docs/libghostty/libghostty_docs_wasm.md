[Logo] libghostty
Loading...
Searching...
No Matches
WebAssembly Utilities
***** Detailed Description *****
Convenience functions for allocating various types in WebAssembly builds. These are only available the libghostty-vt
wasm module.
Ghostty relies on pointers to various types for ABI compatibility, and creating those pointers in Wasm can be tedious.
These functions provide a purely additive set of utilities that simplify memory management in Wasm environments without
changing the core C library API.
  Note
      These functions always use the default allocator. If you need custom allocation strategies, you should allocate
      types manually using your custom allocator. This is a very rare use case in the WebAssembly world so these are
      optimized for simplicity.
Example Usage
Here's a simple example of using the Wasm utilities with the key encoder:
const { exports } = wasmInstance;
const view = new DataView(wasmMemory.buffer);
// Create key encoder
const encoderPtr = exports.ghostty_wasm_alloc_opaque();
exports.ghostty_key_encoder_new(null, encoderPtr);
const encoder = view.getUint32(encoder, true);
// Configure encoder with Kitty protocol flags
const flagsPtr = exports.ghostty_wasm_alloc_u8();
view.setUint8(flagsPtr, 0x1F);
exports.ghostty_key_encoder_setopt(encoder, 5, flagsPtr);
// Allocate output buffer and size pointer
const bufferSize = 32;
const bufPtr = exports.ghostty_wasm_alloc_u8_array(bufferSize);
const writtenPtr = exports.ghostty_wasm_alloc_usize();
// Encode the key event
exports.ghostty_key_encoder_encode(
encoder, eventPtr, bufPtr, bufferSize, writtenPtr
);
// Read encoded output
const bytesWritten = view.getUint32(writtenPtr, true);
const encoded = new Uint8Array(wasmMemory.buffer, bufPtr, bytesWritten);
  Remarks
      The code above is pretty ugly! This is the lowest level interface to the libghostty-vt Wasm module. In practice,
      this should be wrapped in a higher-level API that abstracts away all this.
Functions
GhosttySgrAttribute *  ghostty_wasm_alloc_sgr_attribute (void)
                 void  ghostty_wasm_free_sgr_attribute (GhosttySgrAttribute *attr)
              void **  ghostty_wasm_alloc_opaque (void)
                 void  ghostty_wasm_free_opaque (void **ptr)
            uint8_t *  ghostty_wasm_alloc_u8_array (size_t len)
                 void  ghostty_wasm_free_u8_array (uint8_t *ptr, size_t len)
           uint16_t *  ghostty_wasm_alloc_u16_array (size_t len)
                 void  ghostty_wasm_free_u16_array (uint16_t *ptr, size_t len)
            uint8_t *  ghostty_wasm_alloc_u8 (void)
                 void  ghostty_wasm_free_u8 (uint8_t *ptr)
             size_t *  ghostty_wasm_alloc_usize (void)
                 void  ghostty_wasm_free_usize (size_t *ptr)
***** Function Documentation *****
***** ◆ ghostty_wasm_alloc_opaque() *****
void ** ghostty_wasm_alloc_opaque ( void  )
Allocate an opaque pointer. This can be used for any opaque pointer types such as GhosttyKeyEncoder, GhosttyKeyEvent,
etc.
  Returns
      Pointer to allocated opaque pointer, or NULL if allocation failed
***** ◆ ghostty_wasm_alloc_sgr_attribute() *****
GhosttySgrAttribute * ghostty_wasm_alloc_sgr_attribute ( void  )
Allocate memory for an SGR attribute (WebAssembly only).
This is a convenience function for WebAssembly environments to allocate memory for an SGR attribute structure that can
be passed to ghostty_sgr_next.
  Returns
      Pointer to the allocated attribute structure
***** ◆ ghostty_wasm_alloc_u16_array() *****
uint16_t * ghostty_wasm_alloc_u16_array ( size_t len )
Allocate an array of uint16_t values.
  Parameters
      len Number of uint16_t elements to allocate
  Returns
      Pointer to allocated array, or NULL if allocation failed
***** ◆ ghostty_wasm_alloc_u8() *****
uint8_t * ghostty_wasm_alloc_u8 ( void  )
Allocate a single uint8_t value.
  Returns
      Pointer to allocated uint8_t, or NULL if allocation failed
***** ◆ ghostty_wasm_alloc_u8_array() *****
uint8_t * ghostty_wasm_alloc_u8_array ( size_t len )
Allocate an array of uint8_t values.
  Parameters
      len Number of uint8_t elements to allocate
  Returns
      Pointer to allocated array, or NULL if allocation failed
***** ◆ ghostty_wasm_alloc_usize() *****
size_t * ghostty_wasm_alloc_usize ( void  )
Allocate a single size_t value.
  Returns
      Pointer to allocated size_t, or NULL if allocation failed
***** ◆ ghostty_wasm_free_opaque() *****
void ghostty_wasm_free_opaque ( void ** ptr )
Free an opaque pointer allocated by ghostty_wasm_alloc_opaque().
  Parameters
      ptr Pointer to free, or NULL (NULL is safely ignored)
***** ◆ ghostty_wasm_free_sgr_attribute() *****
void ghostty_wasm_free_sgr_attribute ( GhosttySgrAttribute * attr )
Free memory for an SGR attribute (WebAssembly only).
Frees memory allocated by ghostty_wasm_alloc_sgr_attribute.
  Parameters
      attr Pointer to the attribute structure to free
***** ◆ ghostty_wasm_free_u16_array() *****
void ghostty_wasm_free_u16_array ( uint16_t * ptr,
                                   size_t     len )
Free an array allocated by ghostty_wasm_alloc_u16_array().
  Parameters
      ptr Pointer to the array to free, or NULL (NULL is safely ignored)
      len Length of the array (must match the length passed to alloc)
***** ◆ ghostty_wasm_free_u8() *****
void ghostty_wasm_free_u8 ( uint8_t * ptr )
Free a uint8_t allocated by ghostty_wasm_alloc_u8().
  Parameters
      ptr Pointer to free, or NULL (NULL is safely ignored)
***** ◆ ghostty_wasm_free_u8_array() *****
void ghostty_wasm_free_u8_array ( uint8_t * ptr,
                                  size_t    len )
Free an array allocated by ghostty_wasm_alloc_u8_array().
  Parameters
      ptr Pointer to the array to free, or NULL (NULL is safely ignored)
      len Length of the array (must match the length passed to alloc)
***** ◆ ghostty_wasm_free_usize() *****
void ghostty_wasm_free_usize ( size_t * ptr )
Free a size_t allocated by ghostty_wasm_alloc_usize().
  Parameters
      ptr Pointer to free, or NULL (NULL is safely ignored)
    * Generated by [doxygen]1.14.0
