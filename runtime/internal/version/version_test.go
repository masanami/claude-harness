package version

import (
	"errors"
	"testing"
)

func TestCheckPlugin(t *testing.T) {
	for _, c := range []struct {
		plugin string
		update string // "" = 範囲内、"error" = 版として読めない
	}{
		{"4.9.0", ""},
		{"4.9.1", ""},
		{"4.99.0", ""},
		{"v4.9.1", ""},
		{"4.9.1+local", ""},
		{"4.8.1", "plugin"},      // 修正（#279・#282）を含まない版
		{"4.9.0-rc.1", "plugin"}, // 4.9.0 の pre-release は 4.9.0 より前
		{"3.0.0", "plugin"},
		{"5.0.0", "cli"},
		{"5.0.0-rc.1", ""}, // 5.0.0 より前なので範囲内
		{"6.1.0", "cli"},
		{"4.8", "error"},
		{"04.8.0", "error"},
		{"", "error"},
		{"latest", "error"},
	} {
		err := CheckPlugin(c.plugin)
		var m *Mismatch
		switch {
		case c.update == "" && err != nil:
			t.Errorf("%q: want in range, got %v", c.plugin, err)
		case c.update == "error" && (err == nil || errors.As(err, &m)):
			t.Errorf("%q: want a parse error, got %v", c.plugin, err)
		case c.update == "plugin" || c.update == "cli":
			if !errors.As(err, &m) || m.Update != c.update {
				t.Errorf("%q: want mismatch updating %s, got %v", c.plugin, c.update, err)
			}
		}
	}
}

func TestCLIPrefersTheLinkedVersion(t *testing.T) {
	old := Version
	defer func() { Version = old }()
	Version = "v1.2.3"
	if got := CLI(); got != "1.2.3" {
		t.Fatalf("CLI() = %q", got)
	}
	Version = ""
	// テストのバイナリはモジュールの版を持たない（(devel)）。
	if got := CLI(); got != Dev {
		t.Fatalf("CLI() = %q, want %q", got, Dev)
	}
}

func TestSupportsSchema(t *testing.T) {
	if !SupportsSchema("harness.workflow/v1") || SupportsSchema("harness.workflow/v2") {
		t.Fatal("schema set")
	}
}
