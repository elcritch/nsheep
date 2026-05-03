# Dependency Analytics — Implementation Plan

## Goal

Add dependency graph tracking so we can answer questions like:
> "How many packages depend on libraries tagged with `library`?"

This surfaces influential foundational packages in the Nim ecosystem.

---

## 1. Parse `requires` from `.nimble` files

**File:** `src/nsheep/ingest.nim`

Extend `parseNimbleSimple` to extract the `requires` field. Nimble supports:

```nim
requires "nim >= 2.0.0"
requires "jsony >= 1.1.0"
requires "httpx"
```

Implementation:
- Add `requires` to the parsed fields list
- Handle comma-separated declarations on a single line
- Strip version constraints (store them separately if useful)
- Skip the implicit `requires "nim >= x.x.x"` since every package has it

---

## 2. Add `dependencies` table to the database

**File:** `src/nsheep/storage.nim`

```sql
CREATE TABLE IF NOT EXISTS dependencies (
    package_name TEXT NOT NULL,
    depends_on TEXT NOT NULL,
    version_constraint TEXT DEFAULT '',
    PRIMARY KEY (package_name, depends_on)
);

CREATE INDEX idx_deps_package ON dependencies(package_name);
CREATE INDEX idx_deps_depends_on ON dependencies(depends_on);
```

New storage procedures:
- `storeDependencies(pkgName, seq[(depName, versionConstraint)])`
- `getDependents(pkgName)` — who depends on this package
- `getDependencies(pkgName)` — what this package depends on
- `clearDependencies(pkgName)` — wipe old deps before re-ingest

---

## 3. Store dependencies during ingestion

**File:** `src/nsheep/ingest.nim`

In the `ingest` proc, after fetching the `.nimble` file:

1. Parse `requires` into a list of `(name, version_constraint)` tuples
2. Call `clearDependencies(store, pkgName)` to remove stale entries
3. Call `storeDependencies(store, pkgName, deps)`

This runs during the normal fetcher cycle, so dependencies stay current as packages are re-ingested.

---

## 4. Add dependency stats to the API

**File:** `src/nsheep/server.nim`

Extend `/api/v1/stats` with a new section:

```json
{
  "totalPackages": 2601,
  "topLibrariesByDependents": [
    {"name": "jsony", "dependentCount": 342},
    {"name": "httpx", "dependentCount": 198},
    ...
  ],
  "mostDependedOn": [
    {"name": "jsony", "dependentCount": 342},
    ...
  ]
}
```

Query for "top libraries by dependents" (packages tagged `library`):

```sql
SELECT d.depends_on, COUNT(*) as dependent_count
FROM dependencies d
JOIN packages p ON p.name = d.depends_on
WHERE p.tags LIKE '%"library"%'
GROUP BY d.depends_on
ORDER BY dependent_count DESC
LIMIT 20;
```

Also add `/api/v1/packages/{name}/dependents` endpoint for package detail pages.

---

## 5. Frontend stats panel

**File:** `frontend/app.nim`

Add two new panels to `/stats`:

- **"Most Depended On"** — bar chart of top 10 packages by reverse-dependency count
- **"Top Libraries"** — same but filtered to packages whose tags include `library`

Also add a **"Dependents"** section to individual package pages showing which packages import it.

---

## Migration path

Since existing ingested packages have no dependency data:

1. Add the schema migration (SQLite `ALTER TABLE` or new table creation)
2. Run a one-time backfill script that re-parses all stored `.nimble` files (or re-ingests) to populate `dependencies`
3. The fetcher will naturally fill in missing data on its next cycle for packages it touches

---

## Files to modify

| File | Changes |
|------|---------|
| `src/nsheep/ingest.nim` | Parse `requires`, store deps during ingestion |
| `src/nsheep/storage.nim` | `dependencies` table + CRUD procs |
| `src/nsheep/server.nim` | Stats API + `/dependents` endpoint |
| `frontend/app.nim` | New stats panels + package page dependents list |
| `frontend/app.css` | Panel styles |
