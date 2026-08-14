# Project Instructions

## Workflow

- Use `$adept:attunement` before repository changes to discover the host, target
  architectures, branch state, and guardrails.
- Use `$adept:forge` for implementation work. Its focused verification and
  repository guardrail suite replace the retired `$verification-before-completion`
  skill.
- Before claiming a change is complete, run `just check`.
- For changes that affect the running server, also run `just smoke` against the
  started container. For context-window or KV-cache changes, additionally run
  `just long-context`.
- Report which verification commands ran and any checks that the environment could
  not exercise.
