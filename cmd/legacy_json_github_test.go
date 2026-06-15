package cmd

import (
	"testing"

	"github.com/getplumber/plumber/control"
	opaengine "github.com/getplumber/plumber/internal/engine/opa"
)

// TestPullRequestTargetHeadCheckoutJSONBlock locks the ISSUE-804 fix: the
// JSON export must carry a pullRequestTargetHeadCheckoutResult block whose
// issues[] surface the file/job/line, not just a plumberScore.codeLosses
// line. Before the fix the dispatch returned ("", nil) for this control,
// so dashboards saw the criticals with no location.
func TestPullRequestTargetHeadCheckoutJSONBlock(t *testing.T) {
	entry := control.ControlEntry{
		DisplayName: "pull_request_target workflows must not check out the PR head",
		ControlName: "pullRequestTargetMustNotCheckoutHead",
	}
	findings := []opaengine.Finding{{
		Code: "ISSUE-804",
		Job:  "ci/build",
		File: ".github/workflows/ci.yml",
		Line: 12,
		URL:  ".github/workflows/ci.yml:12",
	}}
	result := &control.AnalysisResult{
		CiValid:     true,
		GitHubStats: &control.GitHubAnalysisStats{WorkflowsTotal: 3},
	}

	name, block := buildLegacyResultGitHub(entry, result, nil, findings)
	if name != "pullRequestTargetHeadCheckoutResult" {
		t.Fatalf("block name = %q, want pullRequestTargetHeadCheckoutResult", name)
	}
	m, ok := block.(map[string]any)
	if !ok {
		t.Fatalf("block is %T, want map[string]any", block)
	}
	issues, ok := m["issues"].([]map[string]any)
	if !ok || len(issues) != 1 {
		t.Fatalf("issues = %v, want exactly 1 entry", m["issues"])
	}
	if issues[0]["code"] != "ISSUE-804" {
		t.Errorf("issue code = %v, want ISSUE-804", issues[0]["code"])
	}
	if issues[0]["jobName"] != "ci/build" {
		t.Errorf("issue jobName = %v, want ci/build", issues[0]["jobName"])
	}
	if issues[0]["url"] == nil {
		t.Errorf("issue must carry a url (file:line link), got %v", issues[0])
	}
	if m["compliance"] != 0.0 {
		t.Errorf("compliance with a finding = %v, want 0", m["compliance"])
	}

	// Clean run: no findings → 100% compliant, empty issues.
	cleanName, cleanBlock := buildLegacyResultGitHub(entry, result, nil, nil)
	if cleanName != "pullRequestTargetHeadCheckoutResult" {
		t.Fatalf("clean block name = %q", cleanName)
	}
	if cm := cleanBlock.(map[string]any); cm["compliance"] != 100.0 {
		t.Errorf("clean compliance = %v, want 100", cm["compliance"])
	}
}
