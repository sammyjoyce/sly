# Sly libghostty Refactor Implementation Guide

0a. Study specs/* to learn about the sly architecture and libghostty integration specifications.

0b. The source code of sly is in src/.

0c. Study docs/libghostty/* for libghostty API documentation and integration patterns.

1. Your task is to implement the libghostty-based terminal runtime (see @specs/*) and produce a fully functional shell AI command generator using parallel subagents. Follow the specs/08-IMPLEMENTATION-PHASES.md and choose the most important 10 items. Before making changes search codebase (don't assume not implemented) using subagents. You may use up to 500 parallel subagents for all operations but only 1 subagent for build/tests.

2. After implementing functionality or resolving problems, run the tests for that unit of code that was improved. If functionality is missing then it's your job to add it as per the specifications. Think hard.

3. When you discover a terminal, key encoding, VT parsing, or libghostty integration issue, immediately update @specs/IMPLEMENTATION_STATUS.md with your findings using a subagent. When the issue is resolved, update @specs/IMPLEMENTATION_STATUS.md and remove the item using a subagent.

4. When the tests pass update the @specs/IMPLEMENTATION_STATUS.md, then add changed code and @specs/IMPLEMENTATION_STATUS.md with "git add -A" via bash then do a "git commit" with a message that describes the changes you made to the code. After the commit do a "git push" to push the changes to the remote repository.

999. Important: When authoring documentation capture the why tests and the backing implementation is important.

9999. Important: We want single sources of truth, no migrations/adapters. If tests unrelated to your work fail then it's your job to resolve these tests as part of the increment of change.

999999. As soon as there are no build or test errors create a git tag. If there are no git tags start at 0.0.0 and increment patch by 1 for example 0.0.1 if 0.0.0 does not exist.

999999999. You may add extra logging if required to be able to debug the issues.

9999999999. ALWAYS KEEP @specs/IMPLEMENTATION_STATUS.md up to date with your learnings using a subagent. Especially after wrapping up/finishing your turn.

99999999999. When you learn something new about how to build or test sly make sure you update @AGENTS.md using a subagent but keep it brief. For example if you run commands multiple times before learning the correct command then that file should be updated.

999999999999. IMPORTANT DO NOT IGNORE: The shell integration plugins (lib/sly.zsh, lib/sly.bash) should be authored to work seamlessly with the libghostty terminal runtime. If you find deprecated implementations then delete/migrate them.

99999999999999. IMPORTANT when you discover a bug resolve it using subagents even if it is unrelated to the current piece of work after documenting it in @specs/IMPLEMENTATION_STATUS.md.

9999999999999999. When you start implementing the libghostty integration, start with the core VT parser and key encoder so that terminal state management can be tested.

99999999999999999. The tests for sly should be located in src/ alongside the source code using Zig's built-in test framework. Ensure you document modules with doc comments.

9999999999999999999. Keep AGENTS.md up to date with information on how to build sly and your learnings to optimise the build/test loop using a subagent.

999999999999999999999. For any bugs you notice, it's important to resolve them or document them in @specs/IMPLEMENTATION_STATUS.md to be resolved using a subagent.

99999999999999999999999. When implementing libghostty integration components you may author multiple modules at once using up to 1000 parallel subagents.

99999999999999999999999999. When @specs/IMPLEMENTATION_STATUS.md becomes large periodically clean out the items that are completed from the file using a subagent.

99999999999999999999999999. If you find inconsistencies in the specs/* then use the oracle and then update the specs. Specifically around key encoding, VT sequences, and terminal state.

9999999999999999999999999999. DO NOT IMPLEMENT PLACEHOLDER OR SIMPLE IMPLEMENTATIONS. WE WANT FULL IMPLEMENTATIONS. DO IT OR I WILL YELL AT YOU.

9999999999999999999999999999999. SUPER IMPORTANT DO NOT IGNORE. DO NOT PLACE STATUS REPORT UPDATES INTO @AGENTS.md.

## End User UX Flow

The expected user experience should be:
1. **Hash (#) key** - User presses # to enter natural language mode
2. **Natural language input** - User types their command request in plain English
3. **Enter key** - Replace the input buffer with the LLM-generated shell command
4. **Enter key again** - Execute the generated command
