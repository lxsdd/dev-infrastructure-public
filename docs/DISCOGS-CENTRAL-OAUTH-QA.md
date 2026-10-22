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
