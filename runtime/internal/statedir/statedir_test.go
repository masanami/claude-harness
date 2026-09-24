package statedir

import (
	"path/filepath"
	"testing"
)

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestResolve(t *testing.T) {
	cwd, err := filepath.Abs(".")
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"HARNESS_STATE_DIR overrides everything", map[string]string{"HARNESS_STATE_DIR": "/x/state", "XDG_STATE_HOME": "/xdg", "HOME": "/home/u"}, "/x/state"},
		{"relative HARNESS_STATE_DIR is made absolute", map[string]string{"HARNESS_STATE_DIR": "rel", "HOME": "/home/u"}, filepath.Join(cwd, "rel")},
		{"XDG_STATE_HOME when set", map[string]string{"XDG_STATE_HOME": "/xdg", "HOME": "/home/u"}, "/xdg/claude-harness"},
		{"relative XDG_STATE_HOME is ignored", map[string]string{"XDG_STATE_HOME": "xdg", "HOME": "/home/u"}, "/home/u/.local/state/claude-harness"},
		{"HOME fallback", map[string]string{"HOME": "/home/u"}, "/home/u/.local/state/claude-harness"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := Resolve(env(c.env))
			if err != nil {
				t.Fatal(err)
			}
			if got != c.want {
				t.Fatalf("Resolve = %q, want %q", got, c.want)
			}
		})
	}
	if _, err := Resolve(env(nil)); err == nil {
		t.Fatal("Resolve with no environment must fail rather than guess a directory")
	}
}
