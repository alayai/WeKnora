package chatpipeline

import (
	"strings"

	"github.com/Tencent/WeKnora/internal/searchutil"
	"github.com/Tencent/WeKnora/internal/types"
)

// kbRetrievalQuery returns the query used for knowledge-base search and rerank.
// Mixed-language questions are expanded with cross-script synonyms so keyword
// and vector recall can hit documents that do not use the user's original script.
func kbRetrievalQuery(chatManage *types.ChatManage) string {
	if chatManage == nil {
		return ""
	}
	if q := strings.TrimSpace(chatManage.RetrievalQuery); q != "" {
		return q
	}
	base := strings.TrimSpace(chatManage.RewriteQuery)
	if base == "" {
		base = strings.TrimSpace(chatManage.Query)
	}
	expanded := searchutil.ExpandBilingualQuery(base)
	if strings.TrimSpace(expanded.Query) != "" {
		chatManage.RetrievalQuery = expanded.Query
		return chatManage.RetrievalQuery
	}
	chatManage.RetrievalQuery = base
	return base
}
