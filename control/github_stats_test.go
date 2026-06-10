package control

import (
	"testing"

	"github.com/getplumber/plumber/configuration"
	"github.com/getplumber/plumber/internal/ir"
)

// TestAggregate_ReusableWorkflowRefsCountTowardActionPinning locks
// the parity between the action-unpinned Rego rule (which has two
// `deny` blocks — one for steps[].uses and one for jobs.<id>.uses)
// and the Go stats counter. Without this, dashboards show
// "actionRefsUnpinned: 0" alongside N ISSUE-701 findings whenever
// the project uses reusable workflow calls — the exact bug we hit
// on facebook/react where 10 unpinned reusable WF calls appeared
// as 10 findings but 0 in the counter.
func TestAggregate_ReusableWorkflowRefsCountTowardActionPinning(t *testing.T) {
	pipeline := &ir.NormalizedPipeline{
		Jobs: []ir.Job{
			// Step-level: 1 trusted-owner SHA-pinned, 1 third-party SHA-pinned,
			// 1 third-party with mutable ref.
			{
				Name: "build",
				Uses: []ir.Action{
					{Uses: "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd"},
					{Uses: "anchore/scan-action@2.0.0"}, // not SHA, third-party → unpinned
					{Uses: "aquasecurity/trivy-action@de4ee9c3a1e0d44ac3f97d7baa4f49adf01b6b27"},
				},
			},
			// Reusable workflow call, mutable ref — was being silently
			// dropped from the counter before the fix.
			{
				Name:                 "deploy",
				ReusableWorkflowUses: "someorg/somerepo/.github/workflows/deploy.yml@v1",
			},
			// Reusable workflow call, SHA-pinned — counted but not unpinned.
			{
				Name:                 "release",
				ReusableWorkflowUses: "someorg/somerepo/.github/workflows/release.yml@abcdef0123456789abcdef0123456789abcdef01",
			},
			// Reusable workflow call to a trusted owner — exempt.
			{
				Name:                 "lint",
				ReusableWorkflowUses: "actions/reusable/.github/workflows/lint.yml@v3",
			},
		},
	}

	pc := &configuration.PlumberConfig{
		GitHub: &configuration.ProviderConfig{
			Controls: configuration.ControlsConfig{
				ActionsMustBePinnedByCommitSha: &configuration.ActionsPinnedByShaControlConfig{
					TrustedOwners: []string{"actions", "github"},
				},
			},
		},
	}

	stats := AggregateGitHubStats(pipeline, pc)

	// Expected breakdown:
	//   step-level: 1 exempt (actions/checkout), 2 in-scope (1 unpinned)
	//   reusable WF: 1 exempt (actions/reusable), 2 in-scope (1 unpinned)
	// Totals: 3 exempt, 4 in-scope, 2 unpinned.
	if stats.ActionRefsExempt != 2 {
		t.Errorf("ActionRefsExempt = %d, want 2 (1 step + 1 reusable WF)", stats.ActionRefsExempt)
	}
	if stats.ActionRefsTotal != 4 {
		t.Errorf("ActionRefsTotal = %d, want 4 (2 step-level in-scope + 2 reusable WF in-scope)", stats.ActionRefsTotal)
	}
	if stats.ActionRefsUnpinned != 2 {
		t.Errorf("ActionRefsUnpinned = %d, want 2 (1 step + 1 reusable WF)", stats.ActionRefsUnpinned)
	}
	if stats.ReusableCalls != 3 {
		t.Errorf("ReusableCalls = %d, want 3 (the three jobs with ReusableWorkflowUses set)", stats.ReusableCalls)
	}
}

// TestHasDangerousTrigger_MatchesRegoEventSet locks the metric's
// dangerous-trigger set to the ISSUE-802 Rego rule's dangerous_events.
// When they drift, workflowsWithDangerousTrigger disagrees with the
// emitted findings — e.g. an issue_comment job fires 3 ISSUE-802 issues
// while the metric reports 0 dangerous-trigger workflows (#235).
func TestHasDangerousTrigger_MatchesRegoEventSet(t *testing.T) {
	fires := []string{
		"workflow_run", "issue_comment", "pull_request_review",
		"pull_request_review_comment", "discussion_comment", "discussion",
		"gollum", "fork",
	}
	for _, ev := range fires {
		if !hasDangerousTrigger([]string{ev}) {
			t.Errorf("%q must count as a dangerous trigger — ISSUE-802 fires on it", ev)
		}
	}
	// pull_request_target is ISSUE-804's concern and is excluded from the
	// ISSUE-802 rule, so it must not inflate this control's metric.
	if hasDangerousTrigger([]string{"pull_request_target"}) {
		t.Error("pull_request_target must not count for the ISSUE-802 metric (owned by ISSUE-804)")
	}
	if hasDangerousTrigger([]string{"push"}) {
		t.Error("push must not count as a dangerous trigger")
	}
}
