# airbrake-autofix-agent

An agent that turns production errors into pull requests, and knows when not to.

It reads new error groups from Airbrake, investigates each one against your code with Claude, and sorts it into one of two groups:

- **fixable_by_ai**: the root cause is confirmed from the backtrace and a fix fully resolves it. The agent opens a pull request.
- **needs_human**: anything else. The agent writes down the suspected cause and what blocked it, and touches no code.

## How it works

1. **Fetch.** Pulls error groups from the Airbrake API, either newly created or with a new occurrence in the last N minutes. It also gathers occurrence counts, severity and affected hosts.
2. **Investigate.** Runs the `claude` CLI as a read-only agent (Read, Grep and Glob only) inside a clone of your repository. It gets the backtrace, `git blame` on the failing lines and the commits since the error first appeared.
3. **Check.** The root cause must cite frames that are really in the backtrace. An answer that is not grounded in the backtrace is downgraded to `needs_human`.
4. **Fix.** With `AUTO_FIX_PRS=true`, each fixable group gets a fresh branch off the base branch, a second agent that may edit files but cannot run commands, a commit, and a labelled pull request through the GitHub CLI.
5. **Report.** Posts a short Slack message with a threaded reply: the proposed fix and PR link, or the root cause and blockers.
6. **Remember.** Investigations and pull requests are stored in SQLite by Airbrake group id, so a group is investigated and fixed once. A claim table stops two runs working on the same group, and stale claims expire after 30 minutes.

## Safety

- Auto-fix is off by default. Without `AUTO_FIX_PRS=true` the script only reads, investigates and prints.
- The investigating agent cannot edit files or run shell commands. The fixing agent can edit files but cannot run git.
- Fixes are made one group at a time, never in parallel.
- Both agents follow `airbrake_fix_rules.md`, which rejects band-aids such as adding `&.`, swallowing the exception or a silent default. Edit that file to change the policy.
- Every model call has a timeout.

## Requirements

- Ruby 3.x and `bundle install`
- The [`claude` CLI](https://docs.claude.com/en/docs/claude-code), signed in
- The [GitHub CLI](https://cli.github.com), signed in with access to the repository
- A local clone of the application repository
- An Airbrake project id and key

## Usage

```bash
bundle install
cp .env.example .env   # fill it in, then export the values

# Investigate errors first seen in the last 30 minutes and print the results
AIRBRAKE_PROJECT_ID=123 AIRBRAKE_PROJECT_KEY=abc REPO_DIR=/path/to/app \
  SINCE_MINUTES=30 ECHO=true bundle exec ruby airbrake_agent.rb

# Also open pull requests for the fixable ones
AUTO_FIX_PRS=true AIRBRAKE_PROJECT_ID=123 AIRBRAKE_PROJECT_KEY=abc REPO_DIR=/path/to/app \
  SINCE_MINUTES=30 bundle exec ruby airbrake_agent.rb

# Work on one specific Airbrake group
GROUP_ID=98765 AIRBRAKE_PROJECT_ID=123 AIRBRAKE_PROJECT_KEY=abc REPO_DIR=/path/to/app \
  ECHO=true bundle exec ruby airbrake_agent.rb
```

Run it from cron or a scheduler every few minutes. The full list of settings is documented at the top of `airbrake_agent.rb`.

## Notes

The prompts assume a Ruby on Rails application. The fetch, cache, claim, pull request and Slack steps are not specific to Rails.
