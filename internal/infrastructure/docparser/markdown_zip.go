package docparser

import (
	"archive/zip"
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/Tencent/WeKnora/internal/types"
	"golang.org/x/text/encoding/simplifiedchinese"
)

const (
	maxMarkdownZipFiles         = 2000
	maxMarkdownZipUncompressed  = 512 << 20
	maxMarkdownZipFileBytes     = 64 << 20
	maxMarkdownZipDeclaredRatio = 50
)

// markdownZipToResult unpacks a zip that contains one markdown file plus the
// local images it references (typically an images/ folder next to the .md).
func markdownZipToResult(data []byte) (*types.ReadResult, error) {
	files, err := readMarkdownZip(data)
	if err != nil {
		return nil, err
	}

	mdPath, markdown, err := pickMarkdownFile(files)
	if err != nil {
		return nil, err
	}

	mdDir := path.Dir(mdPath)
	if mdDir == "." {
		mdDir = ""
	}

	refs := collectZipImageRefs(markdown, mdDir, files)
	return &types.ReadResult{
		MarkdownContent: markdown,
		ImageRefs:       refs,
		Metadata: map[string]string{
			"parser":        SimpleEngineName,
			"source_format": "markdown_zip",
			"markdown_file": path.Base(mdPath),
		},
	}, nil
}

func readMarkdownZip(data []byte) (map[string][]byte, error) {
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("不是有效的 zip 文件: %w", err)
	}
	if len(zr.File) == 0 {
		return nil, fmt.Errorf("zip 是空的")
	}
	if len(zr.File) > maxMarkdownZipFiles {
		return nil, fmt.Errorf("zip 内文件过多（最多 %d 个）", maxMarkdownZipFiles)
	}

	var declared uint64
	for _, f := range zr.File {
		declared += f.UncompressedSize64
	}
	if declared > maxMarkdownZipUncompressed {
		return nil, fmt.Errorf("zip 解压后过大（最多 %d MB）", maxMarkdownZipUncompressed>>20)
	}
	if len(data) > 0 && declared > uint64(len(data))*maxMarkdownZipDeclaredRatio && declared > 64<<20 {
		return nil, fmt.Errorf("zip 压缩比异常，已拒绝解压")
	}

	out := make(map[string][]byte, len(zr.File))
	var total int
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		name, ok := cleanZipPath(decodeZipName(f.Name))
		if !ok {
			continue
		}
		if f.UncompressedSize64 > maxMarkdownZipFileBytes {
			return nil, fmt.Errorf("zip 内文件过大: %s", name)
		}
		rc, err := f.Open()
		if err != nil {
			return nil, fmt.Errorf("无法读取 zip 内文件 %s: %w", name, err)
		}
		limited := io.LimitReader(rc, maxMarkdownZipFileBytes+1)
		body, err := io.ReadAll(limited)
		rc.Close()
		if err != nil {
			return nil, fmt.Errorf("无法读取 zip 内文件 %s: %w", name, err)
		}
		if len(body) > maxMarkdownZipFileBytes {
			return nil, fmt.Errorf("zip 内文件过大: %s", name)
		}
		total += len(body)
		if total > maxMarkdownZipUncompressed {
			return nil, fmt.Errorf("zip 解压后过大（最多 %d MB）", maxMarkdownZipUncompressed>>20)
		}
		out[name] = body
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("zip 中没有可用文件")
	}
	return out, nil
}

func isMarkdownZipFileType(fileType string) bool {
	return strings.EqualFold(strings.TrimPrefix(strings.TrimSpace(fileType), "."), "zip")
}

func decodeZipName(name string) string {
	if utf8.ValidString(name) {
		return name
	}
	if decoded, err := simplifiedchinese.GBK.NewDecoder().String(name); err == nil && utf8.ValidString(decoded) {
		return decoded
	}
	if decoded, err := simplifiedchinese.GB18030.NewDecoder().String(name); err == nil && utf8.ValidString(decoded) {
		return decoded
	}
	return name
}

func cleanZipPath(name string) (string, bool) {
	name = strings.ReplaceAll(name, "\\", "/")
	name = strings.TrimPrefix(name, "/")
	if name == "" || name == "." {
		return "", false
	}
	parts := strings.Split(name, "/")
	var cleaned []string
	for _, part := range parts {
		if part == "" || part == "." {
			continue
		}
		if part == ".." {
			return "", false
		}
		cleaned = append(cleaned, part)
	}
	if len(cleaned) == 0 {
		return "", false
	}
	if cleaned[0] == "__MACOSX" {
		return "", false
	}
	base := cleaned[len(cleaned)-1]
	if base == ".DS_Store" || strings.HasPrefix(base, "._") {
		return "", false
	}
	return strings.Join(cleaned, "/"), true
}

func pickMarkdownFile(files map[string][]byte) (string, string, error) {
	var mds []string
	for name := range files {
		ext := strings.ToLower(path.Ext(name))
		if ext == ".md" || ext == ".markdown" {
			mds = append(mds, name)
		}
	}
	if len(mds) == 0 {
		return "", "", fmt.Errorf("zip 中没有找到 markdown 文件（.md），请把 .md 和 images 文件夹一起打包")
	}
	sort.Slice(mds, func(i, j int) bool {
		si, sj := markdownZipScore(mds[i], files), markdownZipScore(mds[j], files)
		if si != sj {
			return si > sj
		}
		di, dj := strings.Count(mds[i], "/"), strings.Count(mds[j], "/")
		if di != dj {
			return di < dj
		}
		return mds[i] < mds[j]
	})
	chosen := mds[0]
	return chosen, string(files[chosen]), nil
}

func markdownZipScore(mdPath string, files map[string][]byte) int {
	dir := path.Dir(mdPath)
	score := 0
	for name := range files {
		if !isZipImagePath(name) {
			continue
		}
		if dir == "." {
			if strings.HasPrefix(name, "images/") {
				score++
			}
			continue
		}
		if strings.HasPrefix(name, dir+"/images/") {
			score++
		}
	}
	return score
}

func isZipImagePath(name string) bool {
	ext := strings.ToLower(strings.TrimPrefix(path.Ext(name), "."))
	return imageFormats[ext]
}

func collectZipImageRefs(markdown, mdDir string, files map[string][]byte) []types.ImageRef {
	seen := map[string]struct{}{}
	var refs []types.ImageRef
	add := func(originalRef string, data []byte, filename string) {
		originalRef = strings.TrimSpace(originalRef)
		if originalRef == "" || len(data) == 0 {
			return
		}
		if _, ok := seen[originalRef]; ok {
			return
		}
		seen[originalRef] = struct{}{}
		mime := http.DetectContentType(data)
		if !strings.HasPrefix(mime, "image/") {
			if ext := strings.ToLower(path.Ext(filename)); imageFormats[strings.TrimPrefix(ext, ".")] {
				mime = mimeFromImageExt(ext)
			} else {
				return
			}
		}
		refs = append(refs, types.ImageRef{
			Filename:    filename,
			OriginalRef: originalRef,
			MimeType:    mime,
			ImageData:   data,
			IsOriginal:  true,
		})
	}

	for _, refPath := range markdownImageRelPaths(markdown) {
		data, filename, ok := resolveZipImage(refPath, mdDir, files)
		if !ok {
			continue
		}
		add(refPath, data, filename)
		for _, alias := range zipImageAliases(refPath) {
			add(alias, data, filename)
		}
	}
	return refs
}

func mimeFromImageExt(ext string) string {
	switch strings.ToLower(strings.TrimPrefix(ext, ".")) {
	case "png":
		return "image/png"
	case "jpg", "jpeg":
		return "image/jpeg"
	case "gif":
		return "image/gif"
	case "webp":
		return "image/webp"
	case "bmp":
		return "image/bmp"
	case "tiff", "tif":
		return "image/tiff"
	default:
		return "application/octet-stream"
	}
}

func markdownImageRelPaths(markdown string) []string {
	var out []string
	for _, span := range scanMarkdownImageTargets(markdown) {
		raw := markdown[span.TargetStart:span.TargetEnd]
		refPath := markdownImageDestinationPath(raw)
		if refPath == "" {
			continue
		}
		if strings.HasPrefix(refPath, "http://") || strings.HasPrefix(refPath, "https://") ||
			isProviderScheme(refPath) || strings.HasPrefix(strings.ToLower(refPath), "data:") {
			continue
		}
		out = append(out, refPath)
	}
	return out
}

func markdownImageDestinationPath(raw string) string {
	start, end := trimMarkdownSpaceBounds(raw, 0, len(raw))
	if start >= end {
		return ""
	}
	trimmed := raw[start:end]
	if trimmed[0] == '<' {
		closeIdx := strings.IndexByte(trimmed, '>')
		if closeIdx <= 1 {
			return ""
		}
		return strings.TrimSpace(trimmed[1:closeIdx])
	}
	titleStart, found := parseMarkdownImageTitleSuffix(trimmed)
	if !found {
		return trimmed
	}
	pathEnd := titleStart
	for pathEnd > 0 && isMarkdownSpace(trimmed[pathEnd-1]) {
		pathEnd--
	}
	if pathEnd == 0 {
		return ""
	}
	return trimmed[:pathEnd]
}

func resolveZipImage(refPath, mdDir string, files map[string][]byte) ([]byte, string, bool) {
	candidates := zipImageLookupKeys(refPath, mdDir)
	for _, key := range candidates {
		if data, ok := files[key]; ok && isZipImagePath(key) {
			return data, path.Base(key), true
		}
	}

	wantBase := path.Base(unescapeZipPath(refPath))
	if wantBase == "" || wantBase == "." {
		return nil, "", false
	}
	var matches []string
	prefix := "images/"
	if mdDir != "" {
		prefix = mdDir + "/images/"
	}
	for name := range files {
		if !isZipImagePath(name) {
			continue
		}
		if (strings.HasPrefix(name, prefix) || path.Dir(name) == mdDir || (mdDir == "" && !strings.Contains(name, "/"))) &&
			path.Base(name) == wantBase {
			matches = append(matches, name)
		}
	}
	if len(matches) == 1 {
		return files[matches[0]], path.Base(matches[0]), true
	}
	return nil, "", false
}

func zipImageLookupKeys(refPath, mdDir string) []string {
	unescaped := unescapeZipPath(refPath)
	variants := []string{refPath, unescaped, strings.ReplaceAll(unescaped, "\\", "/")}
	seen := map[string]struct{}{}
	var keys []string
	add := func(s string) {
		s = strings.TrimSpace(strings.ReplaceAll(s, "\\", "/"))
		s = strings.TrimPrefix(s, "./")
		if s == "" {
			return
		}
		if _, ok := seen[s]; ok {
			return
		}
		seen[s] = struct{}{}
		keys = append(keys, s)
		if mdDir != "" && !path.IsAbs(s) && !strings.HasPrefix(s, mdDir+"/") {
			joined := path.Join(mdDir, s)
			if _, ok := seen[joined]; !ok {
				seen[joined] = struct{}{}
				keys = append(keys, joined)
			}
		}
	}
	for _, v := range variants {
		add(v)
	}
	return keys
}

func zipImageAliases(refPath string) []string {
	unescaped := unescapeZipPath(refPath)
	normalized := strings.TrimPrefix(strings.ReplaceAll(unescaped, "\\", "/"), "./")
	aliases := []string{unescaped, "./" + normalized, strings.ReplaceAll(normalized, " ", "%20")}
	escaped := escapeZipPath(normalized)
	if escaped != normalized {
		aliases = append(aliases, escaped)
	}
	return aliases
}

func unescapeZipPath(p string) string {
	if decoded, err := url.PathUnescape(p); err == nil && decoded != "" {
		return decoded
	}
	return p
}

func escapeZipPath(p string) string {
	parts := strings.Split(p, "/")
	for i, part := range parts {
		parts[i] = url.PathEscape(part)
	}
	return strings.Join(parts, "/")
}
