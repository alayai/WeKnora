package searchutil

import (
	"strings"
	"testing"
)

func TestExpandBilingualQueryMixedSessionTimeout(t *testing.T) {
	got := ExpandBilingualQuery("如何设置session timeout时间？")

	if !got.Mixed {
		t.Fatal("expected mixed-language query")
	}
	if !containsAll(got.Query, "session timeout", "登录超时", "会话超时") {
		t.Fatalf("expanded query missing bilingual terms: %q", got.Query)
	}
	if !strings.Contains(got.Replaced, "登录超时") {
		t.Fatalf("replaced query should use Chinese synonym, got %q", got.Replaced)
	}
	if strings.Contains(strings.ToLower(got.Replaced), "session timeout") {
		t.Fatalf("replaced query still contains English term: %q", got.Replaced)
	}
}

func TestExpandBilingualQueryCamelCase(t *testing.T) {
	got := ExpandBilingualQuery("如何设置SessionTimeout")
	if !containsAll(got.Query, "登录超时") {
		t.Fatalf("camelCase term was not expanded: %q", got.Query)
	}
}

func TestExpandBilingualQueryChineseAddsEnglish(t *testing.T) {
	got := ExpandBilingualQuery("登录超时锁屏怎么配置")
	if !strings.Contains(strings.ToLower(got.Query), "session timeout") {
		t.Fatalf("Chinese query was not expanded with English synonym: %q", got.Query)
	}
}

func TestExpandBilingualQueryIdempotentWhenAlreadyBilingual(t *testing.T) {
	got := ExpandBilingualQuery("如何设置 session timeout 登录超时")
	if strings.Count(got.Query, "登录超时") != 1 {
		t.Fatalf("should not duplicate existing Chinese synonym: %q", got.Query)
	}
}

func TestExpandBilingualQueryPureChineseUnrelated(t *testing.T) {
	q := "项目预算如何编制"
	got := ExpandBilingualQuery(q)
	if got.Query != q {
		t.Fatalf("unrelated Chinese query changed: %q", got.Query)
	}
	if got.Replaced != "" {
		t.Fatalf("unrelated query should not produce replacement, got %q", got.Replaced)
	}
}

func TestExpandBilingualQueryDoesNotTreatTimeoutAsSubstringOfLoginTimeout(t *testing.T) {
	got := ExpandBilingualQuery("登录超时怎么设置")
	// "超时" is a substring of "登录超时" and must not fire the generic timeout group
	// as if it were an independent match that drops the more specific phrase.
	if !strings.Contains(strings.ToLower(got.Query), "session timeout") {
		t.Fatalf("expected session timeout synonym, got %q", got.Query)
	}
}

func containsAll(s string, parts ...string) bool {
	for _, p := range parts {
		if !strings.Contains(strings.ToLower(s), strings.ToLower(p)) {
			return false
		}
	}
	return true
}
