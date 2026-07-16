# sly Specifications

This directory contains the design specifications for sly, a shell command generator built on libghostty-vt.

## Document Index

| Document | Description |
|----------|-------------|
| [00-OVERVIEW](00-OVERVIEW.md) | High-level architecture, vision, and goals |
| [01-CORE-ARCHITECTURE](01-CORE-ARCHITECTURE.md) | Terminal runtime and component design |
| [02-USER-EXPERIENCE](02-USER-EXPERIENCE.md) | UX flow, # key trigger, command replacement |
| [03-SHELL-INTEGRATION](03-SHELL-INTEGRATION.md) | Shell plugin design for bash/zsh |
| [04-KEY-ENCODING](04-KEY-ENCODING.md) | Key encoding and Kitty keyboard protocol |
| [05-TERMINAL-STATE](05-TERMINAL-STATE.md) | Framebuffer, SGR, OSC, and snapshots |
| [06-SECURITY-POLICY](06-SECURITY-POLICY.md) | Security model and policy engine |
| [07-LLM-INTEGRATION](07-LLM-INTEGRATION.md) | Provider abstraction and CommandPlan schema |
| [08-IMPLEMENTATION-PHASES](08-IMPLEMENTATION-PHASES.md) | Implementation roadmap and milestones |

## Quick Reference

### User Experience Flow

```
1. # key      → Enter natural language mode
2. Type query → "find all pdf files"
3. Enter      → Replace buffer with generated command
4. Enter      → Execute command
```

### Architecture Layers

```
┌─────────────────────────────────┐
│       Shell Plugins             │  ← bash/zsh integration
├─────────────────────────────────┤
│       sly CLI                   │  ← argument parsing
├─────────────────────────────────┤
│       Command Planner           │  ← plan generation/validation
├─────────────────────────────────┤
│       Terminal Runtime          │  ← libghostty integration
├─────────────────────────────────┤
│       Policy Engine             │  ← security decisions
├─────────────────────────────────┤
│       Provider Adapters         │  ← LLM providers
├─────────────────────────────────┤
│       libghostty-vt             │  ← terminal emulation
└─────────────────────────────────┘
```

### libghostty-vt Capabilities

- **Key Encoding**: Kitty keyboard protocol, legacy encoding
- **SGR Parser**: Text styling (bold, italic, colors)
- **OSC Parser**: Window titles, shell integration, clipboard
- **Paste Utils**: Safety validation for paste operations

### Implementation Phases

1. **Foundation**: libghostty bindings, runtime skeleton
2. **Terminal State**: Framebuffer, SGR/OSC parsing, snapshots
3. **Input & Paste**: Key encoding, paste validation
4. **Policy Engine**: OSC policies, security model
5. **Integration**: Shell plugins, UX flow, command planner

## Legacy Documents

The following documents are from earlier design iterations:

- `libghostty-refactor-spec.md` - Original refactor specification
- `libghostty-implementation-plan.md` - Initial implementation plan
- `libghostty-design-decisions.md` - Design decision log
- `FEEDBYTES_IMPLEMENTATION_GUIDE.md` - feedbytes command guide
- `IMPLEMENTATION_STATUS.md` - Legacy status tracking

## Contributing

When adding or modifying specifications:

1. Follow the established numbering scheme
2. Include code examples where appropriate
3. Update this README with any new documents
4. Keep documents focused on design, not implementation details
