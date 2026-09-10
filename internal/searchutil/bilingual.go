package searchutil

import (
	"regexp"
	"sort"
	"strings"
	"unicode"
)

const maxBilingualAddedTerms = 8

// BilingualExpansion holds retrieval variants for mixed-language queries.
type BilingualExpansion struct {
	// Query is the original text plus missing cross-script synonyms.
	Query string
	// Replaced swaps matched foreign technical terms for the other-script primary synonym.
	// Empty when no replacement is useful.
	Replaced string
	// Added lists synonyms appended to Query (not already present).
	Added []string
	// Mixed is true when the original query contains both Han and Latin letters.
	Mixed bool
}

type synonymGroup struct {
	terms []string
}

// Concept-level EN/ZH synonyms that commonly appear in enterprise/IT documents.
// Longer, more specific groups must stay first so "session timeout" wins over "timeout".
var bilingualSynonymGroups = []synonymGroup{
	{[]string{"session timeout", "session_timeout", "session-timeout", "sessiontimeout", "登录超时", "会话超时", "超时锁屏", "会话过期"}},
	{[]string{"idle timeout", "idle_timeout", "空闲超时", "闲置超时"}},
	{[]string{"keep-alive", "keepalive", "keep alive", "心跳保活", "连接保活"}},
	{[]string{"access token", "access_token", "访问令牌"}},
	{[]string{"refresh token", "refresh_token", "刷新令牌"}},
	{[]string{"single sign-on", "single sign on", "sso", "单点登录"}},
	{[]string{"timeout", "time out", "超时", "超时时间", "超时退出"}},
	{[]string{"session", "会话", "登录会话"}},
	{[]string{"login", "log in", "sign in", "登录"}},
	{[]string{"logout", "log out", "sign out", "登出", "退出登录"}},
	{[]string{"password", "passwd", "密码"}},
	{[]string{"captcha", "verification code", "验证码"}},
	{[]string{"token", "令牌", "凭证"}},
	{[]string{"jwt", "json web token"}},
	{[]string{"oauth", "开放授权"}},
	{[]string{"cookie", "cookies", "浏览器 cookie"}},
	{[]string{"csrf", "跨站请求伪造"}},
	{[]string{"gateway", "网关"}},
}

var (
	camelBoundary     = regexp.MustCompile(`([a-z0-9])([A-Z])`)
	multiSpace        = regexp.MustCompile(`\s+`)
	nonAlnumToSpace   = regexp.MustCompile(`[^0-9a-z\p{Han}]+`)
	englishWordSeq    = regexp.MustCompile(`(?i)\b[a-z][a-z0-9]*(?:\s+[a-z][a-z0-9]*)*\b`)
	latinLetterRegexp = regexp.MustCompile(`[A-Za-z]`)
	englishSurface    = map[string]*regexp.Regexp{}
)

func init() {
	sort.SliceStable(bilingualSynonymGroups, func(i, j int) bool {
		return longestTermLen(bilingualSynonymGroups[i]) > longestTermLen(bilingualSynonymGroups[j])
	})
	for _, group := range bilingualSynonymGroups {
		for _, term := range group.terms {
			if hasHan(term) {
				continue
			}
			nt := normalizeTerm(term)
			if nt == "" || englishSurface[nt] != nil {
				continue
			}
			englishSurface[nt] = regexp.MustCompile(`(?i)` + strings.Join(escapeEnglishParts(nt), `[\s_-]*`))
		}
	}
}

func escapeEnglishParts(normalized string) []string {
	parts := strings.Fields(normalized)
	out := make([]string, len(parts))
	for i, p := range parts {
		out[i] = regexp.QuoteMeta(p)
	}
	return out
}

func longestTermLen(g synonymGroup) int {
	maxLen := 0
	for _, t := range g.terms {
		if n := len([]rune(normalizeTerm(t))); n > maxLen {
			maxLen = n
		}
	}
	return maxLen
}

// ExpandBilingualQuery appends missing Chinese/English synonyms so keyword and
// vector retrieval can hit documents written in the other script.
func ExpandBilingualQuery(query string) BilingualExpansion {
	query = strings.TrimSpace(query)
	out := BilingualExpansion{Query: query, Mixed: isMixedLanguage(query)}
	if query == "" {
		return out
	}

	normalized := normalizeTerm(query)
	chineseHits := collectPresentChineseTerms(query)

	var added []string
	seenAdded := map[string]struct{}{}
	replaced := query

	for _, group := range bilingualSynonymGroups {
		engHit, chHit, engSurface, chSurface := groupHits(query, normalized, group, chineseHits)
		if !engHit && !chHit {
			continue
		}
		if engHit && !chHit {
			for _, term := range chineseTerms(group) {
				addSynonym(&added, seenAdded, query, term)
			}
			if engSurface != "" {
				if chSurfacePrimary := preferredChinese(group); chSurfacePrimary != "" {
					replaced = replaceEnglishSurface(replaced, engSurface, chSurfacePrimary)
				}
			}
		}
		if chHit && !engHit {
			if eng := preferredEnglish(group); eng != "" {
				addSynonym(&added, seenAdded, query, eng)
			}
			if chSurface != "" {
				if eng := preferredEnglish(group); eng != "" {
					replaced = strings.ReplaceAll(replaced, chSurface, eng)
				}
			}
		}
		if len(added) >= maxBilingualAddedTerms {
			break
		}
	}

	if len(added) > maxBilingualAddedTerms {
		added = added[:maxBilingualAddedTerms]
	}
	out.Added = added
	if len(added) > 0 {
		out.Query = strings.TrimSpace(query + " " + strings.Join(added, " "))
	}
	if trimmed := strings.TrimSpace(replaced); trimmed != "" && !strings.EqualFold(trimmed, query) {
		out.Replaced = trimmed
	}
	return out
}

func collectPresentChineseTerms(query string) []string {
	var terms []string
	for _, group := range bilingualSynonymGroups {
		for _, term := range group.terms {
			if !hasHan(term) {
				continue
			}
			if strings.Contains(query, term) {
				terms = append(terms, term)
			}
		}
	}
	sort.Slice(terms, func(i, j int) bool {
		return len([]rune(terms[i])) > len([]rune(terms[j]))
	})
	return terms
}

func groupHits(query, normalized string, group synonymGroup, chineseHits []string) (engHit, chHit bool, engSurface, chSurface string) {
	for _, term := range group.terms {
		if hasHan(term) {
			if chineseTermPresent(query, term, chineseHits) {
				chHit = true
				if chSurface == "" || len([]rune(term)) > len([]rune(chSurface)) {
					chSurface = term
				}
			}
			continue
		}
		if englishTermPresent(normalized, term) {
			engHit = true
			if surface := englishSurfaceIn(query, term); surface != "" && (engSurface == "" || len(surface) > len(engSurface)) {
				engSurface = surface
			}
		}
	}
	return engHit, chHit, engSurface, chSurface
}

func chineseTermPresent(query, term string, longerHits []string) bool {
	if !strings.Contains(query, term) {
		return false
	}
	for _, longer := range longerHits {
		if longer != term && strings.Contains(longer, term) && strings.Contains(query, longer) {
			return false
		}
	}
	return true
}

func englishTermPresent(normalizedQuery, term string) bool {
	nt := normalizeTerm(term)
	if nt == "" {
		return false
	}
	padded := " " + normalizedQuery + " "
	return strings.Contains(padded, " "+nt+" ")
}

func englishSurfaceIn(query, term string) string {
	nt := normalizeTerm(term)
	if nt == "" {
		return ""
	}
	matches := englishWordSeq.FindAllString(query, -1)
	for _, m := range matches {
		if normalizeTerm(m) == nt {
			return m
		}
	}
	if re := englishSurface[nt]; re != nil {
		if loc := re.FindStringIndex(query); loc != nil {
			return query[loc[0]:loc[1]]
		}
	}
	return ""
}

func replaceEnglishSurface(query, surface, replacement string) string {
	if surface == "" || replacement == "" {
		return query
	}
	return strings.Replace(query, surface, replacement, 1)
}

func addSynonym(added *[]string, seen map[string]struct{}, query, term string) {
	term = strings.TrimSpace(term)
	if term == "" || len(*added) >= maxBilingualAddedTerms {
		return
	}
	if strings.Contains(strings.ToLower(query), strings.ToLower(term)) {
		return
	}
	key := strings.ToLower(term)
	if _, ok := seen[key]; ok {
		return
	}
	seen[key] = struct{}{}
	*added = append(*added, term)
}

func chineseTerms(group synonymGroup) []string {
	var out []string
	for _, t := range group.terms {
		if hasHan(t) {
			out = append(out, t)
		}
	}
	return out
}

func preferredChinese(group synonymGroup) string {
	for _, t := range group.terms {
		if hasHan(t) {
			return t
		}
	}
	return ""
}

func preferredEnglish(group synonymGroup) string {
	var fallback string
	for _, t := range group.terms {
		if hasHan(t) {
			continue
		}
		if strings.ContainsAny(t, "_-") {
			if fallback == "" {
				fallback = t
			}
			continue
		}
		return t
	}
	return fallback
}

func isMixedLanguage(query string) bool {
	return hasHan(query) && latinLetterRegexp.MatchString(query)
}

func hasHan(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Han, r) {
			return true
		}
	}
	return false
}

func normalizeTerm(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	s = camelBoundary.ReplaceAllString(s, "$1 $2")
	s = strings.ToLower(s)
	s = isolateLatinFromHan(s)
	s = nonAlnumToSpace.ReplaceAllString(s, " ")
	s = multiSpace.ReplaceAllString(s, " ")
	return strings.TrimSpace(s)
}

func isolateLatinFromHan(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 8)
	var prev rune
	for i, r := range s {
		if i > 0 && needsScriptSpace(prev, r) {
			b.WriteByte(' ')
		}
		b.WriteRune(r)
		prev = r
	}
	return b.String()
}

func needsScriptSpace(prev, curr rune) bool {
	return (isHan(prev) && isASCIIWord(curr)) || (isASCIIWord(prev) && isHan(curr))
}

func isHan(r rune) bool {
	return unicode.Is(unicode.Han, r)
}

func isASCIIWord(r rune) bool {
	return r < 128 && (unicode.IsLetter(r) || unicode.IsDigit(r))
}
