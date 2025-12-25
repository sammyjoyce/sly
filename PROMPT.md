Read all documents in @docs/libghostty, and then explore the project codebase. Once you have a deep understanding of the both the project and the libghostty library, write documents in ./specs. These documents should include detailed specifications, design decisions, and implementation plans for a deep refactor of the sly project to fully utilize the capabilities of libghostty. Ensure that the documents are clear, comprehensive, and provide a solid foundation for the refactor process. Do not refer to the current project state, or mention any existing code. Focus solely on the new design and specifications for sly rebuilt on libghostty.

## End User UX Flow

The expected user experience should be:
1. **Hash (#) key** - User presses # to enter natural language mode
2. **Natural language input** - User types their command request in plain English
3. **Enter key** - Replace the input buffer with the LLM-generated shell command
4. **Enter key again** - Execute the generated command
