#!/usr/bin/env bash
# Deploy to Pagelive: zip a built folder and publish it as a new version of a site.
#
# The two calls of the Pagelive site API (the same ones a dashboard upload makes):
#   1. POST /api/sites/upload   the zip as the raw body; answers { uploadId, files, warnings }
#   2. POST /api/sites          { uploadId, site }; answers { id, slug, url } once every file is checked
# Auth is `Authorization: Bearer` with an API key, or with a GitHub Actions OIDC token whose
# audience is the API origin (no secret in the repository; the site must be connected to this
# repository in Pagelive). Inputs arrive as environment variables, never spliced into the script.
set -euo pipefail

API="${PAGELIVE_API_URL:-https://app.pagelive.io}"
API="${API%/}"
SITE="${PAGELIVE_SITE:-}"
DIR="${PAGELIVE_DIRECTORY:-dist}"
WORKSPACE="${PAGELIVE_WORKSPACE:-}"
MAX_ZIP=$((95 * 1024 * 1024))

fail() {
	echo "::error title=Pagelive::$1"
	exit 1
}

for tool in curl zip jq; do
	command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed on this runner. Use ubuntu-latest or macos-latest."
done
[ -n "$SITE" ] || fail "Set the site input to the site's id or slug, from its page in Pagelive."
[ -d "$DIR" ] || fail "The folder $DIR does not exist. Build first (for example npm run build), or set directory to the folder that holds index.html."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ZIP="$TMP/site.zip"

# Hidden files and folders (.git, .github, .env) are left out; Pagelive skips them anyway.
(cd "$DIR" && zip -q -r -X -D "$ZIP" . -x '.*' -x '*/.*' -x 'node_modules/*' -x '*/node_modules/*')
SIZE="$(wc -c <"$ZIP" | tr -d ' ')"
[ "$SIZE" -le "$MAX_ZIP" ] || fail "The zip of $DIR is $((SIZE / 1024 / 1024)) MB. One upload can be up to 95 MB."

uri() { jq -rn --arg v "$1" '$v|@uri'; }

# Sets TOKEN for the next call. Never run in a subshell, so a failure stops the script and its
# message reaches the log.
get_token() {
	if [ -n "${PAGELIVE_API_KEY:-}" ]; then
		TOKEN="$PAGELIVE_API_KEY"
		echo "::add-mask::$TOKEN"
		return
	fi
	[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] ||
		fail "No api-key was given and this job cannot ask GitHub for an OIDC token. Add 'permissions: id-token: write' to the workflow, or pass api-key."
	# A fresh token for each call: they are short-lived.
	TOKEN="$(curl -sS --fail -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$(uri "$API")" | jq -r '.value // empty')" || TOKEN=""
	[ -n "$TOKEN" ] || fail "GitHub did not give this job an OIDC token."
	echo "::add-mask::$TOKEN"
}

QUERY="site=$(uri "$SITE")"
[ -z "$WORKSPACE" ] || QUERY="$QUERY&workspace=$(uri "$WORKSPACE")"

echo "Uploading $DIR ($((SIZE / 1024)) KB) to Pagelive"
get_token
STATUS="$(curl -sS -o "$TMP/upload.json" -w '%{http_code}' --max-time 300 -X POST \
	-H "authorization: Bearer $TOKEN" -H 'content-type: application/zip' \
	--data-binary "@$ZIP" "$API/api/sites/upload?$QUERY")" || fail "The upload did not reach Pagelive."
[ "$STATUS" = 200 ] || fail "Upload refused ($STATUS): $(jq -r '.message // "no reason given"' "$TMP/upload.json" 2>/dev/null || cat "$TMP/upload.json")"
UPLOAD_ID="$(jq -r '.uploadId' "$TMP/upload.json")"
jq -r '.warnings[]? | "::warning title=Pagelive::" + .' "$TMP/upload.json"

BODY="$(jq -n --arg u "$UPLOAD_ID" --arg s "$SITE" --arg w "$WORKSPACE" '{uploadId: $u, site: $s} + (if $w != "" then {workspace: $w} else {} end)')"
echo "Publishing (every file is checked before it is served, this can take a minute)"
get_token
STATUS="$(curl -sS -o "$TMP/commit.json" -w '%{http_code}' --max-time 600 -X POST \
	-H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
	--data "$BODY" "$API/api/sites")" || fail "Publishing did not reach Pagelive."
[ "$STATUS" = 200 ] || fail "Publish refused ($STATUS): $(jq -r '.message // "no reason given"' "$TMP/commit.json" 2>/dev/null || cat "$TMP/commit.json")"

URL="$(jq -r '.url' "$TMP/commit.json")"
{
	echo "url=$URL"
	echo "slug=$(jq -r '.slug' "$TMP/commit.json")"
	echo "site-id=$(jq -r '.id' "$TMP/commit.json")"
} >>"$GITHUB_OUTPUT"
jq -r '.warnings[]? | "::warning title=Pagelive::" + .' "$TMP/commit.json"
LOCK="$(jq -r '.lockNote // empty' "$TMP/commit.json")"
[ -z "$LOCK" ] || echo "::notice title=Pagelive::$LOCK"
echo "::notice title=Pagelive::Published $(jq -r '.files' "$TMP/commit.json") files to $URL"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	echo "Published to Pagelive: $URL" >>"$GITHUB_STEP_SUMMARY"
fi
