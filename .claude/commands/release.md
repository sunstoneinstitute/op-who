# Release op-who

You are performing a release of op-who. Arguments: $ARGUMENTS

## Step 1: Determine bump level

Parse `$ARGUMENTS` for `--bump {major,minor,patch}`. If no `--bump` argument is provided, determine the bump level automatically:

1. Find the latest version tag: `git tag --sort=-v:refname | head -1`
2. Get the diff summary since that tag: `git log <tag>..HEAD --oneline`
3. Classify:
   - **minor**: if there are any `feat:` commits (new features, new functionality)
   - **patch**: if only `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, or similar non-feature commits
   - **NEVER bump major** unless the user explicitly passed `--bump major`

State the bump level and why.

## Step 2: Generate changelog entry

Review the commits since the last version tag and write a changelog entry in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Group changes under the appropriate headings:

- **Added** — new features
- **Changed** — changes in existing functionality
- **Fixed** — bug fixes
- **Removed** — removed features

Only include headings that have entries. Be concise but descriptive. Each entry should be one line. Do NOT include the version header line — the release script adds that.

## Step 3: Confirm with user

Show the user:
- Current version → new version
- The bump level and reasoning
- The changelog entry

Ask for confirmation before proceeding. If the user wants changes, revise accordingly.

## Step 4: Run the release script

Once confirmed, pipe the changelog entry to the release script:

```bash
scripts/release-version.sh --bump <level> <<'CHANGELOG'
<changelog entry>
CHANGELOG
```

## Step 5: Report result

Show the user the new version tag and remind them to push with tags when ready:

```
git push && git push --tags
```
