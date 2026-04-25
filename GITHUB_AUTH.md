# GitHub Authentication

NSheep uses the GitHub API to fetch repository metadata, releases, and tarballs. Without authentication, the API is aggressively rate-limited.

## Rate Limits

| Authentication | Limit |
|----------------|-------|
| None | 60 requests / hour |
| Token (classic or fine-grained) | 5,000 requests / hour |

At 60 req/hr, a full ingestion of the nimble packages list will fail partway through. A token is effectively required for production use.

## Configuration

Add your token to `cfg.yaml`:

```yaml
github:
  token: "ghp_xxxxxxxxxxxxxxxxxxxx"
```

The token is passed as a `Bearer` Authorization header on every GitHub API request. It is kept in memory only and never logged.

## Creating a Token

### Classic PAT (recommended)

1. GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token → **No scopes required**
3. Since NSheep only reads *public* repositories, a token with zero scopes works fine

### Fine-grained PAT

1. GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
2. Generate new token → **No repository access** (public repos are readable without access)
3. Expiration: set according to your ops policy

## Verifying

Check that the fetcher is using the token by watching the logs on startup:

```
info  Fetcher starting  interval=3600 validation=true
```

If you see repeated `HTTP 403` or `rate limit` errors in the fetcher logs, the token is missing, expired, or invalid.

## Quick Check

Test the token manually:

```bash
curl -H "Authorization: Bearer ghp_xxxxxxxx" \
  https://api.github.com/rate_limit
```

Look for `"limit": 5000` in the response to confirm authenticated access.
