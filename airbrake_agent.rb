#!/usr/bin/env ruby
# Fetches Airbrake error groups active within the last N minutes, either
# newly created (MODE=new_errors) or with a new occurrence (MODE=new_occurrences),
# along with per-group insights (occurrence volume, severity, affected hosts) and
# an AI root-cause investigation that categorizes each group as "fixable_by_ai"
# or "needs_human"; the latter is left open with a suspected-cause summary for
# a human instead of touching any code.
#
# Required ENV vars:
# AIRBRAKE_PROJECT_ID - Airbrake project id
# AIRBRAKE_PROJECT_KEY - Airbrake project api key
# SINCE_MINUTES - how many minutes back to look for matching groups
# (not required if GROUP_ID is set -- see below)
#
# Optional ENV vars:
# GROUP_ID - when set, resolves this one specific Airbrake group id directly
# (fetched via the API's single-group endpoint) instead of
# scanning by time window. SINCE_MINUTES/MODE are ignored in this
# mode; INSIGHTS_WINDOW_MINUTES still applies (default 1440 =
# 1 day) to size the occurrence/host/severity insights for it.
# Everything downstream (caching, investigation, AUTO_FIX_PRS,
# Slack, ECHO) behaves exactly as it does for a group found via
# the normal scan -- this only changes how the group is found.
# MODE - "new_errors" (default) for groups first seen in the window, or
# "new_occurrences" for groups with any occurrence in the window
# (ignored when GROUP_ID is set)
# INSIGHTS_WINDOW_MINUTES - how many minutes back to aggregate occurrence/host/
# severity insights for each matching group
# (defaults to SINCE_MINUTES)
# LOCAL_DB_PATH - path to the sqlite cache of AI investigations and opened PRs,
# keyed by Airbrake group id, so a group is only ever
# investigated/fixed once (default: local_db.sqlite3
# next to this script)
# AUTO_FIX_PRS - when "true", enables the auto-fix-and-PR feature below for
# groups categorized "fixable_by_ai". OFF by default -- with
# this unset, the script only fetches/investigates/prints and
# never touches git/gh/the fixer agent.
# ECHO - when "true", prints the title, insights and category of each match
# SLACK_BOT_TOKEN / SLACK_CHANNEL_ID - when both are set, posts a short
# top-level Slack message (with a threaded reply carrying the
# detail: proposed fix if auto-fixed, otherwise root cause +
# blockers) for a group whenever ANY of the following holds:
# - a PR was newly opened for it on this run (a PR already
# on file from an earlier run does not re-trigger this)
# - occurrences in the insights window exceed
# SLACK_MIN_OCCURRENCES_IN_WINDOW (even if needs_human)
# - it's newly detected this run (not just re-seen from cache)
# Skipped entirely if either env var is unset, or if no groups
# matched.
#
# Categorization runs the `claude` CLI as a read-only investigation agent
# (Read/Grep/Glob against REPO_DIR, no Bash/Edit/Write) that opens the actual
# source at the failing backtrace frames, identifies the root cause from
# evidence, and categorizes the group as "fixable_by_ai" only if it has both
# correctly identified the root cause AND a fix that fully resolves it, per
# explicit conditions (see investigation_prompt) -- otherwise "needs_human",
# and the suspected cause / blockers are stored (and printed under ECHO=true)
# instead of touching any code.
#
# Both the investigation (classifier) and fix (fixer) agents run on
# CLASSIFIER_MODEL / FIXER_MODEL (Sonnet), and both are given the same
# root-cause-over-band-aid rules (RULES_PATH, see airbrake_fix_rules.md next
# to this script) appended to their system prompt. Those rules are the single
# source of truth for what counts as a real fix vs. a defensive patch (adding
# `&.`, `.present?`/`.blank?`/`.nil?` guards, swallowing exceptions, silent
# `|| default` fallbacks, or narrowing a query to exclude the crashing case)
# -- edit that file to tune the policy without touching this script.
#
# When AUTO_FIX_PRS=true, for every group categorized "fixable_by_ai" that
# doesn't already have a PR on file, this script (sequentially, one group at a
# time -- never in parallel):
# 1. resets REPO_DIR to the latest BASE_BRANCH
# 2. creates branch hotfix/airbrake_<group_id> (force-reset if it already exists)
# 3. runs the claude CLI as a coding agent, restricted to Read/Edit/Write/Grep/Glob,
# to make a code fix using the error's type/message/backtrace/environment
# 4. if it produced any changes, commits, force-pushes the branch, and opens a
# PR against BASE_BRANCH labeled "Auto Fix Airbrake" via `gh pr create`,
# with the investigation's root cause and proposed fix included in the PR
# description (alongside a note that the actual diff may have diverged
# from that proposed fix, since the fixer verifies/adjusts it against the
# real code)
# 5. records the PR number/url in the airbrake_prs table so reruns never
# duplicate a PR (or re-run the fixer agent) for the same group id
#
# Usage:
# AIRBRAKE_PROJECT_ID=123 AIRBRAKE_PROJECT_KEY=abc SINCE_MINUTES=30 ECHO=true ruby airbrake_agent.rb
# rubocop:todo Layout/LineLength
# MODE=new_occurrences AIRBRAKE_PROJECT_ID=123 AIRBRAKE_PROJECT_KEY=abc SINCE_MINUTES=30 ECHO=true ruby airbrake_agent.rb
# rubocop:enable Layout/LineLength
# rubocop:todo Layout/LineLength
# AIRBRAKE_PROJECT_ID=123 AIRBRAKE_PROJECT_KEY=abc SINCE_MINUTES=30 INSIGHTS_WINDOW_MINUTES=1440 ECHO=true ruby airbrake_agent.rb
# rubocop:enable Layout/LineLength
# AUTO_FIX_PRS=true AIRBRAKE_PROJECT_ID=123 AIRBRAKE_PROJECT_KEY=abc SINCE_MINUTES=30 ECHO=true ruby airbrake_agent.rb
# GROUP_ID=98765 AIRBRAKE_PROJECT_ID=123 AIRBRAKE_PROJECT_KEY=abc ECHO=true ruby airbrake_agent.rb
# GROUP_ID=98765 AUTO_FIX_PRS=true AIRBRAKE_PROJECT_ID=123 AIRBRAKE_PROJECT_KEY=abc ECHO=true ruby airbrake_agent.rb

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'open3'
require 'sqlite3'
require 'timeout'
require 'active_support'
require 'active_support/time'
Time.zone = "UTC"
AIRBRAKE_API_BASE = 'https://api.airbrake.io/api/v4'.freeze
AIRBRAKE_APP_BASE = 'https://airbrake.io'.freeze
CLASSIFIER_MODEL = ENV.fetch('CLASSIFIER_MODEL', 'sonnet').freeze
FIXER_MODEL = ENV.fetch('FIXER_MODEL', 'sonnet').freeze
CLASSIFY_TIMEOUT_SECONDS = 600
FIXER_TIMEOUT_SECONDS = 900
REPO_DIR = ENV.fetch('REPO_DIR') { abort 'REPO_DIR is required: path to a clone of the app repository' }.freeze
BASE_BRANCH = ENV.fetch('BASE_BRANCH', 'main').freeze
PR_LABEL = 'Auto Fix Airbrake'.freeze
# Optional. When one repository serves several separately deployed products,
# set PRODUCT_LABELS_JSON to map a host domain to a pull request label, e.g.
# {"shop.example.com": {"name": "Shop", "color": "1D76DB"}}
# It is matched against the notice's context.hostname as a substring, so any
# subdomain of each domain matches. Leave it unset to skip product labels.
PRODUCT_LABELS = JSON.parse(ENV.fetch('PRODUCT_LABELS_JSON', '{}'))
                     .transform_values { |label| label.transform_keys(&:to_sym) }
                     .freeze
SLACK_MIN_OCCURRENCES_IN_WINDOW = 10
# Shared root-cause-over-band-aid policy, appended to both the classifier's
# and the fixer's system prompt. Kept in its own file (rather than inlined)
# so the policy can be tuned/reviewed without touching this script.
RULES_PATH = File.join(__dir__, 'airbrake_fix_rules.md').freeze
# How long a claim (see claim_issue! below) is honored before it's treated
# as abandoned -- a crashed/killed process that never finished investigating
# -- and can be retried by a later run instead of being stuck forever.
CLAIM_STALE_SECONDS = 30 * 60

MODES = {
  'new_errors' => { timestamp_field: 'createdAt', order: 'created' },
  'new_occurrences' => { timestamp_field: 'lastNoticeAt', order: 'last_notice' }
}.freeze

def airbrake_get(path, project_key, params = {})
  uri = URI("#{AIRBRAKE_API_BASE}#{path}")
  uri.query = URI.encode_www_form(params.merge(key: project_key))

  response = Net::HTTP.get_response(uri)
  unless response.is_a?(Net::HTTPSuccess)
    raise "Airbrake API request failed: #{response.code} #{response.body}"
  end

  JSON.parse(response.body)
end

def fetch_groups(project_id, project_key, since_minutes, mode)
  mode_config = MODES.fetch(mode) { raise "Unknown MODE: #{mode} (expected one of #{MODES.keys.join(', ')})" }
  since_time = Time.now.utc - (since_minutes * 60)

  # The API's start_time filter doesn't behave as documented (verified live: a
  # recent timestamp returns unrelated stale groups, 0 returns everything), so
  # we sort server-side and filter client-side below instead.
  body = airbrake_get("/projects/#{project_id}/groups", project_key, order: mode_config[:order])
  groups = body['groups'] || []

  groups.select do |group|
    timestamp = group[mode_config[:timestamp_field]]
  timestamp && Time.parse(timestamp) >= since_time # rubocop:todo Layout/IndentationConsistency
  end
end

# Airbrake's API v4 has NO plain "get a single group by id" endpoint --
# /projects/{id}/groups/{group_id} only supports DELETE, plus the .../notices
# and .../stats sub-resources. (An earlier version of this function called
# GET on that path directly; it doesn't exist, so the response came back
# without a real id, which then broke every subsequent notices/insights call
# built from it.) So instead: page through the documented list-groups
# endpoint (cursor pagination -- "start"/"end" per Airbrake's docs) and find
# the matching id client-side. Used for on-demand GROUP_ID runs, so a human
# can say "resolve this one specific error" rather than only scanning by
# time window. Raises if the id isn't found within max_pages, or isn't
# visible with this project key.
def fetch_group(project_id, project_key, group_id, max_pages: 100)
  cursor = nil

  max_pages.times do
    params = cursor ? { start: cursor } : {}
  body = airbrake_get("/projects/#{project_id}/groups", project_key, params) # rubocop:todo Layout/IndentationConsistency
  groups = body['groups'] || [] # rubocop:todo Layout/IndentationConsistency

  match = groups.find { |group| group['id'].to_s == group_id.to_s } # rubocop:todo Layout/IndentationConsistency
  return match if match # rubocop:todo Layout/IndentationConsistency

  cursor = body['end'] # rubocop:todo Layout/IndentationConsistency
  break if cursor.to_s.empty? || groups.empty? # rubocop:todo Layout/IndentationConsistency
  end

  raise "Airbrake group #{group_id} not found in project #{project_id} " \
  "(paged through up to #{max_pages} pages of the groups list without a match -- " \
  "check the id and that this project key can see it)"
end

# Fetches the most recent page of notices for a group and aggregates them into
# insights: how many occurred in the window, their severities, and which hosts
# they came from. Only the latest page (up to 100) is inspected, so counts for
# very high-volume groups are a sample rather than an exact total.
def fetch_latest_notice(project_id, project_key, group)
  body = airbrake_get("/projects/#{project_id}/groups/#{group['id']}/notices", project_key)
  (body['notices'] || []).first
end

def fetch_group_insights(project_id, project_key, group, since_time)
  body = airbrake_get("/projects/#{project_id}/groups/#{group['id']}/notices", project_key)
  notices = body['notices'] || []
  recent_notices = notices.select { |n| n['createdAt'] && Time.parse(n['createdAt']) >= since_time }

  hosts = Hash.new(0)
  severities = Hash.new(0)
  recent_notices.each do |notice|
    context = notice['context'] || {}
  hosts[context['hostname']] += 1 if context['hostname'] # rubocop:todo Layout/IndentationConsistency
  severities[context['severity']] += 1 if context['severity'] # rubocop:todo Layout/IndentationConsistency
  end

  {
    occurrences_in_window: recent_notices.size,
    sampled_total_on_page: notices.size,
    total_notice_count: group['noticeTotalCount'],
    resolved: group['resolved'],
    hosts: hosts.sort_by { |_, count| -count }.to_h,
    severities: severities.sort_by { |_, count| -count }.to_h
  }
end

def open_category_db(path)
  db = SQLite3::Database.new(path)
  db.busy_timeout = 5000
  # airbrake_id as INTEGER PRIMARY KEY aliases SQLite's rowid, making id lookups
  # a direct O(log n) index seek instead of a text comparison.
  db.execute(<<~SQL)
    CREATE TABLE IF NOT EXISTS airbrake_categories (
    airbrake_id INTEGER PRIMARY KEY,
    category TEXT NOT NULL,
    root_cause TEXT,
    backtrace_evidence TEXT,
    proposed_fix TEXT,
    blockers TEXT,
    categorized_at TEXT NOT NULL
    )
  SQL
  # Migrates DBs created before condition-based investigation was added.
  %w[root_cause:TEXT backtrace_evidence:TEXT proposed_fix:TEXT blockers:TEXT].each do |column|
    name, type = column.split(':')
    db.execute("ALTER TABLE airbrake_categories ADD COLUMN #{name} #{type}")
  rescue SQLite3::SQLException
    # column already exists
  end
  db.execute(<<~SQL)
    CREATE TABLE IF NOT EXISTS airbrake_prs (
    airbrake_id INTEGER PRIMARY KEY,
    pr_number INTEGER,
    pr_url TEXT NOT NULL,
    branch TEXT NOT NULL,
    created_at TEXT NOT NULL
    )
  SQL
  # Separate, single-purpose table: just "which groups is someone actively
  # investigating right now." A row goes in immediately before the `claude`
  # CLI is invoked (see claim_issue!) and is only ever looked at to decide
  # whether to skip a group this run -- it doesn't carry any result data,
  # so it can't drift out of sync with airbrake_categories.
  db.execute(<<~SQL)
    CREATE TABLE IF NOT EXISTS claimed_issues (
    airbrake_id INTEGER PRIMARY KEY,
    claimed_at TEXT NOT NULL
    )
  SQL
  db
end

def cached_investigations(db, group_ids)
  return {} if group_ids.empty?

  placeholders = group_ids.map { '?' }.join(',')
  rows = db.execute(
    "SELECT airbrake_id, category, root_cause, backtrace_evidence, proposed_fix, blockers " \
    "FROM airbrake_categories WHERE airbrake_id IN (#{placeholders})", group_ids
  )
  rows.to_h do |airbrake_id, category, root_cause, backtrace_evidence, proposed_fix, blockers|
    [airbrake_id.to_s, { category: category, root_cause: root_cause,
                         backtrace_evidence: backtrace_evidence, proposed_fix: proposed_fix,
                         blockers: blockers }]
  end
end

# Claims a group right before it's actually investigated. A plain INSERT
# against the airbrake_id PRIMARY KEY is the whole mechanism: if another
# process already claimed this group, the insert hits the key constraint
# and fails -- that failure IS the "already being investigated" signal, no
# separate check-then-act race to worry about.
#
# Returns true if the claim succeeded (go ahead and investigate), false if
# another process already holds it (skip this group this run).
def claim_issue!(db, group_id)
  claimed_at = db.get_first_value('SELECT claimed_at FROM claimed_issues WHERE airbrake_id = ?', [group_id])
  if claimed_at && (Time.now.utc - Time.parse(claimed_at)) >= CLAIM_STALE_SECONDS
  # Abandoned claim from a crashed/killed process -- clear it so it can be
  # retried instead of being stuck forever.
  db.execute('DELETE FROM claimed_issues WHERE airbrake_id = ?', [group_id]) # rubocop:todo Layout/IndentationWidth
  end

  db.execute('INSERT INTO claimed_issues (airbrake_id, claimed_at) VALUES (?, ?)', [group_id, Time.now.utc.iso8601])
  true
rescue SQLite3::ConstraintException
  false # rubocop:todo Layout/IndentationWidth
end

def store_investigation(db, group_id, investigation)
  db.execute(
    'INSERT OR REPLACE INTO airbrake_categories ' \
    '(airbrake_id, category, root_cause, backtrace_evidence, proposed_fix, blockers, categorized_at) ' \
    'VALUES (?, ?, ?, ?, ?, ?, ?)',
    [group_id, investigation[:category], investigation[:root_cause],
     investigation[:backtrace_evidence], investigation[:proposed_fix], investigation[:blockers],
     Time.now.utc.iso8601]
  )
end

def backtrace_text(error_source)
  first_error = error_source['errors']&.first || {}
  frames = first_error['backtrace'] || []

  frames.map { |frame| "#{frame['file']}:#{frame['line']} in #{frame['function']}" }.join("\n")
end

def backtrace_blame_text(backtrace, limit: 5)
  frames = backtrace.to_s.lines.first(limit).filter_map do |raw_line|
  file, rest = raw_line.split(':', 2) # rubocop:todo Layout/IndentationWidth
  next unless file && rest

  line_number = rest.strip.split(' ').first
  [file.strip, line_number] if line_number
  end

  frames.filter_map do |file, line_number|
    blame = git_blame_text(file, line_number)
  "#{file}:#{line_number} -- #{blame.strip}" unless blame.strip.empty? # rubocop:todo Layout/IndentationConsistency
  end.join("\n")
end

# A root_cause is only as trustworthy as the frame it's actually anchored to --
# checks that backtrace_evidence cites a file:line that's really in the backtrace
# we gave the model, rather than one it found by searching the codebase. Matches
# on file basename + line number appearing anywhere in the evidence text (not as
# one exact glued-together substring), since citing several frames from the same
# file in prose naturally drops the repeated filename (e.g. "listing.rb:70 and
# :44/:31") without meaning those later line numbers are any less grounded.
def grounded_in_backtrace?(backtrace, backtrace_evidence)
  return false if backtrace.to_s.strip.empty? || backtrace_evidence.to_s.strip.empty?

  backtrace.lines.any? do |line|
    file, rest = line.split(':', 2)
  next false unless file && rest # rubocop:todo Layout/IndentationConsistency

  line_number = rest.strip.split(' ').first # rubocop:todo Layout/IndentationConsistency
  next false unless line_number # rubocop:todo Layout/IndentationConsistency

  basename = File.basename(file.strip) # rubocop:todo Layout/IndentationConsistency
 # rubocop:todo Layout/IndentationConsistency
 backtrace_evidence.include?(basename) && backtrace_evidence.match?(/(?<!\d)#{Regexp.escape(line_number)}(?!\d)/)
    # rubocop:enable Layout/IndentationConsistency
  end
end

# Loaded fresh (not memoized) so an operator can edit airbrake_fix_rules.md
# between runs -- e.g. to tighten the policy after seeing a bad PR -- without
# needing to restart or redeploy anything.
def load_rules_text
  File.read(RULES_PATH)
rescue Errno::ENOENT
  warn "Warning: rules file not found at #{RULES_PATH}; proceeding without it." # rubocop:todo Layout/IndentationWidth
  ''
end

def investigation_prompt(group, backtrace)
  first_error = group['errors']&.first || {}
  blame = backtrace_blame_text(backtrace)
  recent_commits = recent_commits_text(group['createdAt'])

  if ENV['ECHO'] == 'true'
    if backtrace.nil? || backtrace.empty?
    puts "Empty backtrace for group #{group['id']}" # rubocop:todo Layout/IndentationWidth
    else
  # rubocop:todo Layout/IndentationWidth
  puts "Backtrace sent to investigation agent for group #{group['id']}:\n#{backtrace}"
      # rubocop:enable Layout/IndentationWidth
    end
  end

  <<~PROMPT
    Investigate the root cause of this application error using the source code in
    #{REPO_DIR}. Do not edit any files -- this is investigation only.

    - Read the full backtrace below and open the actual source at the failing
    location and the relevant frames above it. Trace back to where the bad
    state/input originated.
    - Decide which cause is actually responsible using EVIDENCE from the
    backtrace, params, and code -- not assumption. Your root cause must be
    grounded in specific frames from the backtrace below (cite the exact
    file:line). Do not substitute a plausible-sounding call path you found
    by searching the codebase if it isn't actually the one shown in the
    backtrace -- if the backtrace doesn't reach far enough to confirm it,
    say so as a blocker instead of guessing.
    - Check whether a commit shown below (via blame on the failing lines, or in
    the repo-wide history since first occurrence) plausibly introduced this
    bug. If so, cite that commit as part of your evidence. If nothing in the
    given history explains it, treat the bug as pre-existing and reason from
    the code itself -- don't assume a cause you can't tie to either the
    backtrace or this history.
    - Before concluding EITHER "this is data corruption" (needs_human) OR
    "the fix is to add a check for this value/state" (fixable_by_ai), you
    need affirmative evidence for which one it actually is -- not a guess
    in either direction. Both are ways of avoiding the harder question, so
    work through this explicitly whenever the bug involves a value being
    nil/invalid/unexpected where the code assumed otherwise:
    1. Check the schema/migrations for the column/association involved.
    Does the database itself currently allow the value or absence
    you're looking at (nullable column, no FK/NOT NULL constraint,
    no enum restriction)? If the DB allows it, that's a signal the
    state is reachable through normal operation, not necessarily
    corruption.
    2. Check the model-level validations that exist in the code TODAY
    (validates presence, validates inclusion, required: true
    associations, etc.). Would the app, as currently written, allow a
    record to be saved in this state right now? If yes, this is a
    state the code must handle correctly -- that points to a real
    code fix, not "needs_human: data corruption."
    3. If current validations WOULD prevent this state, check when the
    affected record was created relative to when that validation or
    constraint was added (blame the migration/validation code, and
    compare against the record's own created_at if you can find it
    mentioned in the error/notice data). A record predating the
    constraint is a genuine data-corruption candidate. A record
    created after the constraint existed despite the guard suggests
    something bypassed validations (raw SQL, an import/rake task, a
    background job using update_column/update_all) -- name that
    specifically rather than writing "corruption" vaguely.
    4. Weigh how common the anomaly looks, using the insights you have
    (occurrence count, hosts, all-time total) plus anything the code
    tells you about how the value is set. A single one-off outlier
    leans toward corruption/an orphaned record. A pattern that would
    hit routinely for a whole class of legitimate input leans toward
    an actual code gap that's never been handled, not corruption.
    5. Trace where the value is actually set: direct user input via a
    form/API param, another internal process, an import script, a
    migration, or a default. If it's set through a normal, currently
    reachable app code path with nothing blocking it, that's a code
    correctness issue -- the fix belongs at the point that allows an
    unhandled value through (or in the specific operation that can't
    cope with it), not a guard on the reader.
    6. Do not default to needs_human/"data corruption" just because a
    guard is easier to write than tracing the real cause -- that is
    the same laziness as a band-aid fix, only relabeled, and it needs
    the same evidence discipline as everything else here.
    7. Do not default to "add a check" just because the value's presence
    contradicts what the reading code assumed, either. If steps 1-3
    show the state should be impossible under everything currently
    enforced and the record predates the relevant constraint, the
    honest category is needs_human, with the corruption named
    explicitly (which table/column/record pattern, and why you
    believe it predates current validation) -- not a silent guard
    that quietly makes future occurrences of the same bad data
    disappear from view.
    State in root_cause/blockers which of steps 1-5 you actually performed
    and what they showed (e.g. "the `amount` column is nullable and no
    model validation requires it, so nil here is a state the code must
    handle" or "assets.status has a DB CHECK constraint added in migration
    20230114... that would reject this value; this row's created_at
    predates that migration, so it's pre-existing bad data") -- a bare
    assertion of "likely corrupt data" or "just needs a nil check" without
    this isn't enough to categorize either way.
    - Do NOT categorize as fixable_by_ai on the strength of a fix that merely
    stops the exception from firing. In particular, treat each of the
    following as a symptom-mask, NOT a root-cause fix, unless you can state
    concrete evidence that the guarded condition is legitimate, expected
    behavior (not the bug):
    - safe navigation (&.) added around a nil receiver
    - .present?/.blank?/.nil? used to skip the failing logic entirely
    - a rescue clause added to swallow the exception
    - .try(...) in place of understanding why the receiver lacks the method
    - an `|| default` fallback (`|| []`, `|| 0`, `|| ''`, etc.) substituted
    for the real value
    - narrowing a query/scope to exclude whatever crashed
    If the only fix you can articulate is one of these with no other change,
    that means you have not yet found the root cause -- categorize
    needs_human and say what's still missing, rather than proposing the
    guard.
    - For this error (or each distinct case within it), decide whether you have
    both (a) correctly identified the root cause and (b) a fix that fully
    resolves it. Categorize as fixable_by_ai ONLY if ALL of these hold:
    - The root cause is unambiguous and directly supported by the backtrace + code.
    - The fix targets the actual cause, not the symptom (see above).
    - The fix relies on nothing you couldn't verify (no guessing about data/behavior).
    - No unconfirmed external dependency is involved.
    - The fix is fully achievable by editing source code in this repo, and it
    resolves the error as already reported -- not merely one that prevents
    recurrence going forward.
    - The fix is correct everywhere it reaches, not just at the one call site
    in the backtrace: check other callers, serializers/views, jobs, and
    any sibling method/class doing the same kind of operation elsewhere in
    the repo. If the same bug pattern (same missing check, same wrong
    assumption) exists in more than one place, a fix that only touches the
    reported call site is incomplete -- note the other occurrences so the
    fixer (or a human) addresses all of them, not just this one.
    If any condition is uncertain, categorize as needs_human.
    - Before proposing a fix that narrows a query/scope to exclude the type or
    value that crashed, check whether that exclusion would silently drop
    functionality a user could legitimately trigger (e.g. data the user
    explicitly selected, or a type the feature's naming/design suggests it
    should support). If so, that is the symptom, not the cause -- the real
    fix is more likely that downstream code needs to correctly handle that
    type (or skip just the specific operation that doesn't apply to it), not
    that upstream code should exclude the object from the whole feature.
    Silently dropping a user's selected data without any error or feedback
    is not a resolution.
    - Also sanity-check whether the failing operation conceptually applies to
    the object type involved at all (e.g. depreciation applies to capital/
    fixed assets, not consumable/stock items). If it doesn't, the fix likely
    belongs as a guard on that specific operation for that type, not as an
    exclusion further upstream.
    - If you categorize as fixable_by_ai, state the specific fix: which
    file/method to change and what the change is. If needs_human, leave
    proposed_fix empty -- do not describe a fix you aren't sure of.

    Airbrake group id: #{group['id']}
    Error type: #{first_error['type']}
    Error message: #{first_error['message']}
    Environment: #{group.dig('context', 'environment')}
    First occurrence: #{group['createdAt']}
    Latest occurrence: #{group['lastNoticeAt']}
    Backtrace:
    #{backtrace || 'unavailable'}

    Blame on the failing backtrace lines:
    #{blame.empty? ? 'unavailable' : blame}

    Repo-wide commits since first occurrence (most recent errors first):
    #{recent_commits.empty? ? 'unavailable' : recent_commits}

    Respond with:
    - root_cause: the specific root cause you identified (or your best-supported
    suspicion if uncertain)
    - backtrace_evidence: the exact file:line frame(s) from the backtrace above
    that support the root cause
    - category: "fixable_by_ai" or "needs_human"
    - proposed_fix: the specific fix (file/method + change), only if fixable_by_ai
    (empty string otherwise)
    - blockers: what prevents certainty (empty string if fixable_by_ai)
  PROMPT
end

def investigation_json_schema
  {
    type: 'object',
    properties: {
      root_cause: { type: 'string' },
      backtrace_evidence: { type: 'string' },
      category: { type: 'string', enum: %w[fixable_by_ai needs_human] },
      proposed_fix: { type: 'string' },
      blockers: { type: 'string' }
    },
    required: %w[root_cause backtrace_evidence category proposed_fix blockers]
  }
end

# Runs a subprocess with a hard wall-clock timeout, killing it if exceeded, so a
# hung `claude`/`git`/`gh` call can't stall the whole (sequential) run forever.
def run_with_timeout(*cmd, chdir: Dir.pwd, timeout_seconds:)
  stdout_str = +''
  stderr_str = +''
  status = nil

  Open3.popen3(*cmd, chdir: chdir) do |stdin, stdout, stderr, wait_thr|
    stdin.close
  begin # rubocop:todo Layout/IndentationConsistency
    Timeout.timeout(timeout_seconds) do
    stdout_str = stdout.read # rubocop:todo Layout/IndentationWidth
    stderr_str = stderr.read
    status = wait_thr.value
    end
  rescue Timeout::Error
    Process.kill('TERM', wait_thr.pid) # rubocop:todo Layout/IndentationWidth
    raise "Command timed out after #{timeout_seconds}s: #{cmd.join(' ')}"
  end
  end

  [stdout_str, stderr_str, status]
end

# Runs a read-only investigation agent (Read/Grep/Glob against REPO_DIR, no
# Bash/Edit/Write) that opens the actual source at the failing backtrace frames
# and categorizes fixable_by_ai vs needs_human against explicit conditions.
# That category gates whether fix_and_open_pr ever touches code for this group.
#
# Claims the group (see claim_issue!) right before actually calling the
# `claude` CLI -- if another process already claimed it (e.g. an overlapping
# cron run), this returns nil immediately instead of investigating, so the
# same group is never investigated twice in parallel.
def investigate_error(group, project_id, project_key, db)
  return nil unless claim_issue!(db, group['id'].to_i)

  notice = fetch_latest_notice(project_id, project_key, group)
  backtrace = notice ? backtrace_text(notice) : backtrace_text(group)

  stdout, stderr, status = run_with_timeout(
    'claude', '-p',
    '--output-format', 'json',
    '--json-schema', JSON.generate(investigation_json_schema),
    '--permission-mode', 'bypassPermissions',
    '--allowedTools', 'Read,Grep,Glob',
    '--model', CLASSIFIER_MODEL,
    '--append-system-prompt', load_rules_text,
    investigation_prompt(group, backtrace),
    chdir: REPO_DIR, timeout_seconds: CLASSIFY_TIMEOUT_SECONDS
  )
  raise "claude CLI investigation failed: #{stderr}" unless status.success?

  result = JSON.parse(stdout)['structured_output']
  category = result['category']
  blockers = result['blockers'].to_s
  proposed_fix = result['proposed_fix'].to_s

  unless grounded_in_backtrace?(backtrace, result['backtrace_evidence'])
    category = 'needs_human'
  proposed_fix = '' # rubocop:todo Layout/IndentationConsistency
 # rubocop:todo Layout/IndentationConsistency
 blockers = [blockers, 'backtrace_evidence did not cite a frame actually present in the reported backtrace.']
            .reject(&:empty?).join(' ')
    # rubocop:enable Layout/IndentationConsistency
  end

  {
    category: category,
    root_cause: result['root_cause'],
    backtrace_evidence: result['backtrace_evidence'],
    proposed_fix: proposed_fix,
    blockers: blockers
  }
end

def group_title(group)
  first_error = group['errors']&.first
  first_error ? "#{first_error['type']}: #{first_error['message'][0, 20]}" : group['id']
end

def airbrake_group_url(project_id, group)
  "#{AIRBRAKE_APP_BASE}/projects/#{project_id}/groups/#{group['id']}"
end

# Which of PRODUCT_LABELS a reporting host belongs to, or nil if it doesn't
# match any known product domain (e.g. hostname missing from this notice, or
# a host that hasn't been mapped yet).
def detect_product_label(hostname)
  return nil if hostname.to_s.strip.empty?

  PRODUCT_LABELS.find { |domain, _| hostname.include?(domain) }&.last
end

# Airbrake error messages sometimes embed a multi-line code snippet, which would
# make a poor (and technically invalid) single-line git commit subject / PR title.
def short_title(group)
  group_title(group).to_s.lines.first.to_s.strip
end

def existing_pr(db, group_id)
  db.get_first_value(<<~SQL, [group_id])
    SELECT pr_url FROM airbrake_prs
    WHERE airbrake_id = ?
    AND state NOT IN ('CLOSED', 'MERGED')
  SQL
end

def store_pr(db, group_id, pr_number, pr_url, branch)
  db.execute(
    'INSERT OR REPLACE INTO airbrake_prs (airbrake_id, pr_number, pr_url, branch, created_at) VALUES (?, ?, ?, ?, ?)',
    [group_id, pr_number, pr_url, branch, Time.now.utc.iso8601]
  )
end

def run_repo_cmd!(*cmd)
  stdout, stderr, status = run_with_timeout(*cmd, chdir: REPO_DIR, timeout_seconds: FIXER_TIMEOUT_SECONDS)
  raise "#{cmd.join(' ')} failed: #{stderr}" unless status.success?

  stdout
end

# Who last touched the failing line, and when -- a line changed right before an
# error's first occurrence is strong evidence of the regression's origin,
# independent of anything derivable from the backtrace itself.
def git_blame_text(file, line)
  run_repo_cmd!('git', 'blame', '-L', "#{line},#{line}", '--', file)
rescue StandardError
  '' # rubocop:todo Layout/IndentationWidth
end

# Repo-wide (not just backtrace files) commit history since an error's first
# occurrence -- catches regressions introduced by a change to a file that never
# appears in the backtrace (a shared concern, a migration, a config change).
def recent_commits_text(since, max_count: 50)
  return '' if since.to_s.strip.empty?

  run_repo_cmd!('git', 'log', '--oneline', "--since=#{since}", "--max-count=#{max_count}")
rescue StandardError
  '' # rubocop:todo Layout/IndentationWidth
end

def fixer_prompt(group, backtrace, proposed_fix)
  first_error = group['errors']&.first || {}

  <<~PROMPT
    An Airbrake error was reported in this Rails app. Investigate the root cause using the
    backtrace below and make a fix in this repo.

    Do not run any git commands and do not commit -- only edit the source files needed for the fix.

    Source Code Directory: #{REPO_DIR}
    Airbrake group id: #{group['id']}
    Error type: #{first_error['type']}
    Error message: #{first_error['message']}
    Environment: #{group.dig('context', 'environment')}
    Backtrace:
    #{backtrace || 'unavailable'}

    A prior investigation of this error proposed the following fix -- use it as your
    starting point, but verify it against the actual code before applying it, and
    diverge from it if you find it doesn't hold up:
    #{proposed_fix.to_s.empty? ? 'none provided' : proposed_fix}

    Do not stop at whatever change makes the exception stop firing. Before you
    treat any of the following as your fix, you must be able to point to
    specific evidence (not assumption) that the condition it guards against is
    legitimate, expected behavior -- not the bug itself:
    - safe navigation (&.) around a nil receiver
    - .present?/.blank?/.nil? used to skip the failing logic
    - a rescue clause that swallows the exception
    - .try(...) instead of understanding why the receiver lacks the method
    - an `|| default` fallback (`|| []`, `|| 0`, `|| ''`, etc.)
    - narrowing a query/scope to exclude whatever crashed
    If, after tracing the value back to its source, the only change you can
    justify is one of these with nothing else alongside it, that means you
    have not found the root cause yet -- keep reading further up the call
    stack, the model, the schema/migrations, and recent commit history before
    concluding a guard is the (only) right change. If the actual cause turns
    out to be bad data already in the database (not something code produces
    going forward), say so plainly instead of patching around it -- a guard
    clause does not fix rows that are already wrong.

    Before finishing, you MUST verify the impact of your change everywhere it
    reaches -- this is a required step, not optional, and "everywhere" means
    the whole repo, not just the file(s) you already have open:

    1. List every variable, method, return value, or behavior your edit
    changes.
    2. For each one, use Grep across the ENTIRE repo (not just the files
    already open) to find every place that reads or calls it afterward --
    later in the same method (including any other branch/elsif/else that
    could now execute because of the new value or new path), every other
    caller anywhere in the codebase, and anything that consumes it
    indirectly: serializers, views/templates, API responses, background
    jobs, rake tasks, callbacks, and existing tests.
    3. For each place found, trace through what actually happens with the new
    value/behavior and confirm the resulting outcome is correct there too
    -- not just that it avoids a crash at the original call site, but that
    it produces the right result at every one of these other sites.
    4. Separately, check whether the same root-cause pattern (the same
    missing check, same wrong assumption, same unhandled shape of data)
    exists in sibling methods or classes that do analogous work elsewhere
    in the codebase -- e.g. other controllers/services/models that perform
    the same kind of operation on the same or a related model. If the
    reported error is one instance of a pattern present in several places,
    fixing only the single call site from this backtrace is not the proper
    fix -- it leaves the identical bug live everywhere else it also
    occurs. Apply the fix consistently to every place you find it, not
    just the one that happened to be reported.
    5. If any downstream read, or any sibling occurrence found in step 4,
    would produce an incorrect, unintended, or misleading result, revise
    the fix until it doesn't. Do not consider the fix finished until this
    check passes everywhere you changed something, and everywhere you
    found the same pattern.
  PROMPT
end

# Runs claude as a coding agent scoped to Read/Edit/Write/Grep/Glob only (no Bash,
# so it can't run git/other commands itself -- this script owns all git/gh calls).
def run_fixer_agent(group, backtrace, proposed_fix)
  run_with_timeout(
    'claude', '-p',
    '--permission-mode', 'bypassPermissions',
    '--allowedTools', 'Read,Edit,Write,Grep,Glob',
    '--model', FIXER_MODEL,
    '--append-system-prompt', load_rules_text,
    fixer_prompt(group, backtrace, proposed_fix),
    chdir: REPO_DIR, timeout_seconds: FIXER_TIMEOUT_SECONDS
  )
end

def ensure_label_exists(name, color)
  Open3.capture3('gh', 'label', 'create', name, '--color', color, '--force', chdir: REPO_DIR)
end

# For a group already known to be fixable_by_ai with no PR on file yet: resets the
# repo to a fresh branch off BASE_BRANCH, runs the fixer agent, and if it produced
# any changes, commits/pushes/opens a PR (with the investigation's root cause and
# proposed fix included in the PR description) and records it. Returns the PR url,
# or nil if the agent made no changes (nothing is recorded, so a future run will
# retry).
def fix_and_open_pr(db, group, project_id, project_key, investigation)
  group_id = group['id'].to_i
  branch = "hotfix/auto_fix_airbrake_#{group_id}_#{Time.zone.now.to_i}"
  notice = fetch_latest_notice(project_id, project_key, group)
  backtrace = notice ? backtrace_text(notice) : backtrace_text(group)

  run_repo_cmd!('git', 'checkout', BASE_BRANCH)
  run_repo_cmd!('git', 'fetch', 'origin', BASE_BRANCH)
  run_repo_cmd!('git', 'reset', '--hard', "origin/#{BASE_BRANCH}")
  run_repo_cmd!('git', 'checkout', '-B', branch)

  _stdout, stderr, status = run_fixer_agent(group, backtrace, investigation[:proposed_fix])
  raise "claude fixer agent failed: #{stderr}" unless status.success?

  if run_repo_cmd!('git', 'status', '--porcelain').strip.empty?
    run_repo_cmd!('git', 'checkout', BASE_BRANCH)
  return nil # rubocop:todo Layout/IndentationConsistency
  end

  title = "Auto-fix: #{short_title(group)} (Airbrake ##{group_id})"
  body = <<~BODY
    Auto-generated fix for Airbrake error ##{group_id}.

    #{group_title(group)}

    - Airbrake: #{airbrake_group_url(project_id, group)}
    - Environment: #{group.dig('context', 'environment')}
    - Occurrences (all-time): #{group['noticeTotalCount']}
    - Resolved in Airbrake: #{group['resolved']}

    ## Root cause
    #{investigation[:root_cause].to_s.empty? ? 'Not recorded.' : investigation[:root_cause]}

    ## Proposed fix (from investigation)
    #{investigation[:proposed_fix].to_s.empty? ? 'Not recorded.' : investigation[:proposed_fix]}

    Note: the diff in this PR is what the fixer agent actually produced after
    verifying the proposed fix against the code -- it may have diverged from
    the proposed fix above if the agent found it didn't hold up. Review the
    diff itself, not just this description, before merging.
  BODY

  run_repo_cmd!('git', 'add', '-A')
  run_repo_cmd!('git', 'commit', '-m', title)
  run_repo_cmd!('git', 'push', '--force', '-u', 'origin', branch)

  ensure_label_exists(PR_LABEL, 'B60205')
  label_args = ['--label', PR_LABEL]

  product = detect_product_label(notice&.dig('context', 'hostname'))
  if product
    ensure_label_exists(product[:name], product[:color])
  label_args += ['--label', product[:name]] # rubocop:todo Layout/IndentationConsistency
  end

  pr_url = run_repo_cmd!(
    'gh', 'pr', 'create',
    '--base', BASE_BRANCH, '--head', branch,
    '--title', title, '--body', body, *label_args
  ).strip

  pr_number = pr_url.split('/').last.to_i
  store_pr(db, group_id, pr_number, pr_url, branch)
  run_repo_cmd!('git', 'checkout', BASE_BRANCH)
  pr_url
end

def format_insights(insights, investigation, top_hosts: 5)
  severity_summary = insights[:severities].map { |severity, count| "#{severity}(#{count})" }.join(', ')
  severity_summary = 'unknown' if severity_summary.empty?

  hosts = insights[:hosts].first(top_hosts).map { |host, count| "#{host}(#{count})" }
  hosts << "+#{insights[:hosts].size - top_hosts} more" if insights[:hosts].size > top_hosts
  host_summary = hosts.empty? ? 'unknown' : hosts.join(', ')

  lines = [
    " category: #{investigation[:category]}",
    " root cause: #{investigation[:root_cause]}",
    " backtrace evidence: #{investigation[:backtrace_evidence]}",
    " occurrences: #{insights[:occurrences_in_window]} in window (#{insights[:total_notice_count]} all-time) | " \
    "resolved: #{insights[:resolved]} | severity: #{severity_summary}",
    " hosts: #{host_summary}"
  ]

  if investigation[:category] == 'fixable_by_ai'
    lines << " proposed fix: #{investigation[:proposed_fix]}" unless investigation[:proposed_fix].to_s.empty?
  else
    lines << " blockers: #{investigation[:blockers]}" unless investigation[:blockers].to_s.empty?
  end

  lines.join("\n")
end

# Short top-level message: error, occurrence volume, PR link if fixed. Kept
# deliberately terse -- the "why" lives in the thread reply, not here, so the
# channel stays scannable instead of turning into a wall of text per error.
def slack_main_text(group, pr_url, insights, project_id, product)
  title = short_title(group)
  title = "[#{product[:name]}] #{title}" if product
  occurrences = "#{insights[:occurrences_in_window]} in window (#{insights[:total_notice_count]} all-time)"
  airbrake_link = "<#{airbrake_group_url(project_id, group)}|##{group['id']}>"

  if pr_url
    [
      ":white_check_mark: *#{title}*",
      "*Airbrake:* #{airbrake_link} · *PR:* #{pr_url}",
      "*Occurrences:* #{occurrences}"
    ].join("\n")
  else
    [
      ":warning: *#{title}*",
      "*Airbrake:* #{airbrake_link}",
      "*Occurrences:* #{occurrences}"
    ].join("\n")
  end
end

# Thread reply carrying the detail that made the main message noisy: the
# proposed fix for auto-fixed groups, or root cause + blockers for groups left
# for a human. Posted as a reply (thread_ts) so it never appears in the main
# channel feed.
def slack_thread_text(investigation, pr_url)
  if pr_url
  fix = investigation[:proposed_fix].to_s # rubocop:todo Layout/IndentationWidth
  fix.empty? ? nil : "*Proposed fix:* #{fix}"
  else
  lines = [] # rubocop:todo Layout/IndentationWidth
  lines << "*Reason:* #{investigation[:root_cause]}" unless investigation[:root_cause].to_s.empty?
  lines << "*Blockers:* #{investigation[:blockers]}" unless investigation[:blockers].to_s.empty?
  lines.empty? ? nil : lines.join("\n")
  end
end

# Posts a single Slack message, optionally as a threaded reply (thread_ts).
# Returns the message's ts so a caller can thread a follow-up reply under it.
def post_slack_message(token, channel_id, text, thread_ts: nil)
  uri = URI('https://slack.com/api/chat.postMessage')
  request = Net::HTTP::Post.new(uri)
  request['Authorization'] = "Bearer #{token}"
  request['Content-Type'] = 'application/json; charset=utf-8'
  payload = { channel: channel_id, text: text }
  payload[:thread_ts] = thread_ts if thread_ts
  request.body = JSON.generate(payload)

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  raise "Slack API request failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

  body = JSON.parse(response.body)
  raise "Slack API error: #{body['error']}" unless body['ok']

  body['ts']
end

# Posts the short main message for a group, then -- if there's anything worth
# saying -- posts the reason/blockers or proposed fix as a threaded reply so
# the channel itself stays to one line-item per error.
def post_slack_for_group(token, channel_id, group, investigation, pr_url, insights, project_id)
  product = detect_product_label(insights[:hosts].keys.first)
  main_text = slack_main_text(group, pr_url, insights, project_id, product)
  thread_ts = post_slack_message(token, channel_id, main_text)

  thread_text = slack_thread_text(investigation, pr_url)
  post_slack_message(token, channel_id, thread_text, thread_ts: thread_ts) if thread_text
end

if $PROGRAM_NAME == __FILE__
  project_id = ENV.fetch('AIRBRAKE_PROJECT_ID')
  project_key = ENV.fetch('AIRBRAKE_PROJECT_KEY')
  group_id_override = ENV['GROUP_ID']
  mode = ENV.fetch('MODE', 'new_errors')
  local_db_path = ENV.fetch('LOCAL_DB_PATH', File.join(__dir__, 'local_db.sqlite3'))
  echo = ENV['ECHO'].to_s.downcase == 'true'
  auto_fix_prs = ENV['AUTO_FIX_PRS'].to_s.downcase == 'true'
  slack_bot_token = ENV['SLACK_BOT_TOKEN']
  slack_channel_id = ENV['SLACK_TEST_CHANNEL_ID']
  slack_enabled = !slack_bot_token.to_s.empty? && !slack_channel_id.to_s.empty?

  if group_id_override
    # On-demand mode: resolve one specific, already-known Airbrake group by
    # id, regardless of when it last fired. SINCE_MINUTES/MODE (the
    # time-window discovery below) don't apply here, so SINCE_MINUTES isn't
    # required in this mode. INSIGHTS_WINDOW_MINUTES still controls how far
    # back to aggregate occurrence/host/severity insights for it -- it
    # defaults to a day since there's no SINCE_MINUTES to fall back on.
    insights_window_minutes = Integer(ENV.fetch('INSIGHTS_WINDOW_MINUTES', (24 * 60).to_s))
  groups = [fetch_group(project_id, project_key, group_id_override)] # rubocop:todo Layout/IndentationConsistency
  puts "Resolving Airbrake group #{group_id_override}" if echo # rubocop:todo Layout/IndentationConsistency
  else
    since_minutes = Integer(ENV.fetch('SINCE_MINUTES'))
 # rubocop:todo Layout/IndentationConsistency
 insights_window_minutes = Integer(ENV.fetch('INSIGHTS_WINDOW_MINUTES', since_minutes))
  # rubocop:enable Layout/IndentationConsistency
  groups = fetch_groups(project_id, project_key, since_minutes, mode) # rubocop:todo Layout/IndentationConsistency
  puts "Airbrakes Found: #{groups.size}" if echo # rubocop:todo Layout/IndentationConsistency
  end

  insights_since_time = Time.now.utc - (insights_window_minutes * 60)

  category_db = open_category_db(local_db_path)
  investigations = cached_investigations(category_db, groups.map { |group| group['id'].to_i })

  puts "Cached investigations: #{investigations.size}" if echo

  groups.each do |group|
    group_id = group['id'].to_s
  # Tracked before the cache lookup below mutates `investigations`, so this
  # reflects whether the group was actually new to this run (as opposed to
  # already known from a prior run) -- that's the "new airbrake" condition
  # for Slack notification, independent of whether it needed investigating.
  newly_seen_this_run = !investigations.key?(group_id) # rubocop:todo Layout/IndentationConsistency

  unless investigations.key?(group_id) # rubocop:todo Layout/IndentationConsistency
    puts "Investigating group #{group_id}..." if echo
  result = investigate_error(group, project_id, project_key, category_db) # rubocop:todo Layout/IndentationConsistency
  if result.nil? # rubocop:todo Layout/IndentationConsistency
    puts " group #{group_id} is already being investigated by another run -- skipping" if echo
  next # rubocop:todo Layout/IndentationConsistency
  end
  investigations[group_id] = result # rubocop:todo Layout/IndentationConsistency
 # rubocop:todo Layout/IndentationConsistency
 store_investigation(category_db, group['id'].to_i, investigations[group_id])
    # rubocop:enable Layout/IndentationConsistency
  end

  investigation = investigations[group_id] # rubocop:todo Layout/IndentationConsistency

  pr_url = nil # rubocop:todo Layout/IndentationConsistency
  pr_freshly_opened = false # rubocop:todo Layout/IndentationConsistency
  if auto_fix_prs && investigation[:category] == 'fixable_by_ai' # rubocop:todo Layout/IndentationConsistency
    # Checked before touching claude/git/gh at all: a group with a PR on file
    # already never triggers another fixer run or another `gh pr create`.
    pr_url = existing_pr(category_db, group['id'].to_i)
  if pr_url.nil? # rubocop:todo Layout/IndentationConsistency
    pr_url = fix_and_open_pr(category_db, group, project_id, project_key, investigation)
  pr_freshly_opened = !pr_url.nil? # rubocop:todo Layout/IndentationConsistency
  end
  end
 # rubocop:todo Layout/IndentationConsistency
 insights = fetch_group_insights(project_id, project_key, group, insights_since_time)
  # rubocop:enable Layout/IndentationConsistency

  # Slack notification fires if ANY of these hold (not all required together):
  # 1. A PR was opened for this group ON THIS RUN -- a pre-existing PR found
  # via existing_pr (opened on some earlier run) does NOT re-trigger this;
  # only pr_freshly_opened counts, so the same PR link doesn't get
  # re-announced every run the group happens to still show up in.
  # 2. Occurrences in the window exceed the threshold -- worth flagging even
  # if the category is needs_human, since volume alone matters to a human.
  # 3. The group is newly detected this run (not just re-seen from cache) --
  # same "tell me about anything new" behavior as before, independent of
  # volume or whether it got fixed.
  pr_opened = pr_freshly_opened # rubocop:todo Layout/IndentationConsistency
 # rubocop:todo Layout/IndentationConsistency
 high_volume = insights[:occurrences_in_window] > SLACK_MIN_OCCURRENCES_IN_WINDOW
  # rubocop:enable Layout/IndentationConsistency
  newly_detected = newly_seen_this_run # rubocop:todo Layout/IndentationConsistency
  should_notify = pr_opened || high_volume || newly_detected # rubocop:todo Layout/IndentationConsistency

  if slack_enabled && should_notify # rubocop:todo Layout/IndentationConsistency
    post_slack_for_group(slack_bot_token, slack_channel_id, group, investigation, pr_url, insights, project_id)
  end

  next unless echo # rubocop:todo Layout/IndentationConsistency

  puts group_title(group) # rubocop:todo Layout/IndentationConsistency
  puts format_insights(insights, investigation) # rubocop:todo Layout/IndentationConsistency
  puts " pr: #{pr_url}" if pr_url # rubocop:todo Layout/IndentationConsistency
  puts " slack notified: #{should_notify}" # rubocop:todo Layout/IndentationConsistency
  end
end
