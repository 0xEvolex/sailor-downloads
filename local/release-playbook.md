# Release Playbook (Local)

This is your personal checklist for publishing releases across apps.

## Before you start
- Update version in the project `version.txt`
- Regenerate release notes draft:
  - `local/generate-release.ps1 -ProjectId <id>`
  - Output drafts are placed in `local/releases/<id>/<tag>.md`
- Confirm the hero image renders (raw URL works in GH Releases)

## Publishing (GitHub UI)
1. Create a new release.
2. Tag name: `<tag>` (e.g., `sailor-events-v1.6`).
3. Target: `main`.
4. Title: `<Project Name> <Version>`.
5. Paste contents of `drafts/<tag>.md`.
6. Upload asset(s): `.rar` corresponding to this release.
7. Publish.

## Publishing (GitHub CLI)
- Tag and push:
  - `git tag <tag>`
  - `git push origin <tag>`
- Create release with notes:
  - `gh release create <tag> --title "<Project Name> <Version>" --notes-file "local/releases/<id>/<tag>.md"`
- Upload asset(s):
  - `gh release upload <tag> <path-to-rar>`

## After publishing
- Verify download and extraction.
- Update any public docs or pinned links if needed.

## App IDs in manifest (examples)
- `sailor-events`
- `sailor-hide`
- `sailor-signal`
- `sailor-navi`
- `sailor-jarvis`
