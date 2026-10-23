# Central Discogs OAuth QA – protected environment

Central repository: `lxsdd/dev-infrastructure-public`, protected `main`, environment `discogs-live-qa`.
The repository contains **no credentials**. The four **environment** secrets are:

- `DISCOGS_OAUTH_CONSUMER_KEY` – newly registered Discogs application Consumer Key.
- `DISCOGS_OAUTH_CONSUMER_SECRET` – matching Consumer Secret.
- `DISCOGS_OAUTH_ACCESS_TOKEN` – OAuth1 token authorized for this SAME application (not a personal access token or the OAuth token from older Discogger).
- `DISCOGS_OAUTH_TOKEN_SECRET` – matching token secret.

## One-time OAuth1 browser authorization

With the new Consumer Key and Secret already saved at GitHub, obtain the paired Access Token/Token Secret through the official Discogs OAuth flow. In Windows PowerShell 5.1 or PowerShell 7 run the reviewed source-only helper `scripts/discogs-oauth-local-bootstrap.ps1` with no arguments. The helper prompts for the application Consumer Key and Consumer Secret **privately**, signs a POST to `api.discogs.com/oauth/request_token`, opens the official Discogs authorization page, prompts for the private PIN, signs a POST to `api.discogs.com/oauth/access_token`, and verifies identity via a **GET** to `api.discogs.com/oauth/identity`.

After the independent identity test, the helper guides you through inserting **only the two new Access values** as Environment Secrets at GitHub. They are copied **one at a time** to the local clipboard; no values are printed in a console, stored in a file, sent to ChatGPT or committed. The clipboard is cleared after each confirmation if it still contains the token. An unexpected termination may leave the last value in the clipboard: clear it manually.

No extra runtime or account credentials are required, and this process does not modify existing Discogger authentication. Do not pipe downloaded scripts directly into a shell; review the file and run it locally.

## Central test boundary

The manual workflow `discogs-oauth-live-qa.yml` runs only from protected main, references the selected-branch environment, and performs only official read-only identity/release/search GET requests. No third-party component binaries, PR code, user media, dynamic repository names, identity output, or artifacts are used. It never proves actual native Discogger GUI/tag-writing acceptance: that must be established separately with pinned, reviewed binaries and disposable synthetic media.

Repo-local CI must not receive central credentials. A reusable `workflow_call` is **not** a cross-repository secret store. Future orchestration needs strictly limited, reviewed code and authorization. Never paste credentials into issues, PRs, chats, logs, or sources.

## OAuth1 signature compatibility

The original manual Windows bootstrap failed before the PIN stage. The local helper and central read-only QA now use Discogs-compatible OAuth1 **PLAINTEXT** signatures over verified **HTTPS only**, not HMAC-SHA1. This method includes secret components inside the TLS-protected Authorization header, so headers, HTTP exceptions and full responses must never be printed. The local CLI reports only the endpoint and safe status-code diagnostic. The original helper also had a PowerShell inline-hashtable conditional that could fail at runtime; offline tests now construct request headers in Windows PowerShell 5.1 and 7.


## Automated Discogs OAuth1 evidence across projects — 2026-10-23

Central read-only OAuth1 API QA runs every day at 04:37 UTC from protected main (and remains manually dispatchable). All four OAuth1 credentials stay exclusively inside the `discogs-live-qa` Environment; no downstream repository receives or inherits them. GitHub may delay scheduled runs and may disable public repo schedules after 60 days of inactivity. The consuming checks reject stale evidence (72 hours by default) and more recent failures.

The secret-free reusable workflow `.github/workflows/discogs-oauth-evidence.yml` is intended for `lxsdd/foo_discogger`, `lxsdd/music-metadata-studio` and `lxsdd/foo_metadata_isolation`. Consumers pin it to an exact immutable commit. It runs the pinned public verifier at source commit `85c38656dbcdf7a93d640b174f39bddfaedaa29c` and reads only public GitHub Actions run/job metadata from the fixed central repository. It verifies workflow ID 393372974, the central repo, workflow path, `main`, permitted event (`workflow_dispatch` or `schedule`), completion, latest success, freshness, and successful OAuth selftest + live API job steps. No caller PR source is executed; it does not use `pull_request_target` or any cross-repository token.

The last accepted central live run must prove Discogs OAuth identity and five direct release API queries; four structured searches were exact and the fifth (`37332711`, Kyau & Albert x Maywave) required a collaborator fallback and identity review. This is **not a native Discogger GUI or foobar2000 tagging/cue write gate**. Each component retains its own synthetic media, GUI and write-safety checks. Never copy OAuth secrets into consumer repositories. [First validated live run 39920726555](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/39920726555).
