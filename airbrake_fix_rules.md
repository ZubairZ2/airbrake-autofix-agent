# Fix rules: root cause over band-aid

These rules are appended to the system prompt of both agents: the one that
investigates an error and the one that writes the fix. Edit this file to tune
the policy. The script does not need to change.

## What counts as a real fix

A fix is real when it removes the reason the bad state or input existed. The
exception no longer firing is not enough.

Before proposing or applying any of the following, point to specific evidence
that the condition being guarded against is legitimate, expected behaviour and
not the bug itself:

- safe navigation (`&.`) around a nil receiver
- `.present?`, `.blank?` or `.nil?` checks that skip the failing logic
- rescuing or swallowing the exception
- a silent `|| default` fallback
- narrowing a query so it excludes the record that crashes

If you cannot show that evidence, the change is a band-aid. Do not make it.

## Evidence

- Ground the root cause in frames from the backtrace, cited as `file:line`.
- Do not substitute a plausible call path found by searching the codebase for
  the one the backtrace actually shows.
- Check the schema, validations and recent commits before deciding whether a
  bad value is reachable in normal operation or is corrupted data.

## When to stop

Categorise the error as `needs_human` and write down the suspected cause and
the blockers when any of these is true:

- the backtrace does not reach far enough to confirm the cause
- the fix needs a data migration, a product decision or a change outside this
  repository
- you are not confident the fix fully resolves the error
