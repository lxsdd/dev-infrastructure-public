# Central Discogs OAuth QA – protected environment

Location: lxsdd/dev-infrastructure-public, protected main, environment \`discogs-live-qa\`.
The public repository contains **no credentials**. Set four **environment** secrets (not ordinary repository secrets):

- \`DISCOGS_OAUTH_CONSUMER_KEY\`: Discogs registered application consumer key.
- \`DISCOGS_OAUTH_CONSUMER_SECRET\`: matching application consumer secret.
- \`DISCOGS_OAUTH_ACCESS_TOKEN\`: authorized Discogs OAuth1 access token (not a personal access token).
- \`DISCOGS_OAUTH_TOKEN_SECRET\`: matching OAuth1 access token secret.

The manual workflow runs only from protected central main, uses the selected-branch environment, and performs only official read-only identity, release and search GET requests. No third-party component binaries, PR code, user media, or dynamically named repositories are executed. Logs contain only fixed public release IDs and PASS/REVIEW markers; no API payload, identity, authorization header or secret is logged. No artifacts.

Repo-local CI must not receive central secrets. A reusable \`workflow_call\` is NOT a cross-repository secret store; the caller context and secret propagation rules differ. For now authorized central tests are manually started through GitHub Actions. Future orchestration requires narrowly scoped authentication and a reviewed exact-SHA allowlist.

This tests the authenticated **Discogs OAuth1 API**, not native Discogger GUI selection/tag writes. It also does not replace an existing Personal Access Token held in another repo's read-only API QA. Native GUI write acceptance is a separate SHA-pinned follow-on using disposable synthetic media.

Never paste credentials into any issue, PR, chat, source file or workflow log. Revoke compromised credentials immediately. Maintain main branch protection and review workflow/script changes before merging.
