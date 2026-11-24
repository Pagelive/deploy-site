# Deploy to Pagelive

Publish a built folder as a new version of a [Pagelive](https://pagelive.io) site from GitHub Actions.
Your workflow builds the site (for example `npm run build`); this action zips the output folder and
uploads it. Pagelive never runs your build.

Every file is checked for safety before anything is served, exactly like an upload in the dashboard.
The link stays the same from version to version.

Sites are on Pagelive Solo and Team, including the card trial. Create the site once (upload a zip in
the dashboard), then copy its id or slug from the site's page.

## Sign in with GitHub (no secret)

Connect the repository on the site's page in Pagelive (Connect GitHub, then pick the repository and
branch). The workflow asks GitHub for a short-lived OIDC token and Pagelive checks that it comes from
that repository and branch, so nothing secret is stored in the repository.

```yaml
name: Deploy to Pagelive

on:
  push:
    branches: ["main"]
  workflow_dispatch:

permissions:
  contents: read
  id-token: write

concurrency:
  group: pagelive-deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - run: npm ci
      - run: npm run build
      - uses: pagelive/deploy-site@v1
        with:
          site: "your-site-slug"
          directory: "dist"
```

This is the workflow for a Vite or React app, which is what Lovable and Bolt export. For a plain folder
of HTML, CSS and images, leave out the three Node steps and set `directory` to the folder that holds
`index.html` (`.` for the repository root).

## Sign in with an API key

For a repository that is not connected in Pagelive, create an API key in the dashboard (API keys),
store it as the repository secret `PAGELIVE_API_KEY`, drop `id-token: write`, and add:

```yaml
      - uses: pagelive/deploy-site@v1
        with:
          site: "your-site-slug"
          directory: "dist"
          api-key: ${{ secrets.PAGELIVE_API_KEY }}
```

## Inputs

| Input | Required | Default | What it is |
|---|---|---|---|
| `site` | yes | | The site to update: its id or slug. |
| `directory` | no | `dist` | The folder to publish, with `index.html` at its top. |
| `api-key` | no | | A Pagelive API key. Leave it out to sign in with GitHub OIDC. |
| `workspace` | no | | With an API key, the team workspace (id or slug). Usually not needed. |
| `api-url` | no | `https://app.pagelive.io` | The Pagelive API. |

## Outputs

`url` (the site's address), `slug`, `site-id`.

## Limits

One upload can be up to 95 MB zipped; a site up to 100 MB and 1,000 files. Hidden files (`.git`,
`.env` and the like) and `node_modules` are never uploaded. Runs on Linux and macOS runners (it needs
`bash`, `zip`, `curl` and `jq`, which GitHub's hosted runners have).

## What it calls

Two requests, which any CI system can make with curl:

1. `POST https://app.pagelive.io/api/sites/upload?site=<site>` with the zip as the body
   (`content-type: application/zip`) answers `{ "uploadId": "..." }`.
2. `POST https://app.pagelive.io/api/sites` with `{ "uploadId": "...", "site": "<site>" }` publishes it
   and answers `{ "id", "slug", "url" }`.

Both take `Authorization: Bearer <API key or GitHub OIDC token>`. The OIDC token's audience is
`https://app.pagelive.io`.
