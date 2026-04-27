#!/bin/bash
# Delete all GitHub Actions workflow runs for nim-community/nsheep

set -e

OWNER="nim-community"
REPO="nsheep"

echo "Fetching workflow runs for $OWNER/$REPO..."

# Get all run IDs
RUN_IDS=$(gh api repos/$OWNER/$REPO/actions/runs --paginate --jq '.workflow_runs[].id')

TOTAL=$(echo "$RUN_IDS" | wc -l | tr -d ' ')
echo "Found $TOTAL workflow runs to delete"

if [ "$TOTAL" -eq 0 ]; then
    echo "Nothing to delete."
    exit 0
fi

echo "Deleting..."
echo "$RUN_IDS" | while read -r run_id; do
    gh api -X DELETE repos/$OWNER/$REPO/actions/runs/$run_id --silent
    echo "Deleted run $run_id"
done

echo "Done! All workflow runs deleted."
