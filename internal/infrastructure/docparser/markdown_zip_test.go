package docparser

import (
	"archive/zip"
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/Tencent/WeKnora/internal/types"
	"golang.org/x/text/encoding/simplifiedchinese"
)

func buildTestZip(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, data := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatalf("create zip entry %s: %v", name, err)
		}
		if _, err := w.Write(data); err != nil {
			t.Fatalf("write zip entry %s: %v", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("close zip: %v", err)
	}
	return buf.Bytes()
}

func TestMarkdownZipToResultUnpacksSiblingImages(t *testing.T) {
	png := createTestPNG(120, 80)
	md := "# FAQ\n\n![登录超时](images/session-timeout.png)\n"
	data := buildTestZip(t, map[string][]byte{
		"faq.md":                     []byte(md),
		"images/session-timeout.png": png,
		"__MACOSX/._faq.md":          []byte("junk"),
		"images/.DS_Store":           []byte("junk"),
	})

	result, err := markdownZipToResult(data)
	if err != nil {
		t.Fatalf("markdownZipToResult: %v", err)
	}
	if result.MarkdownContent != md {
		t.Fatalf("markdown changed: %q", result.MarkdownContent)
	}
	if len(result.ImageRefs) == 0 {
		t.Fatal("expected image refs from zip")
	}
	found := false
	for _, ref := range result.ImageRefs {
		if ref.OriginalRef == "images/session-timeout.png" {
			found = true
			if !ref.IsOriginal {
				t.Fatal("zip images should be marked original so icon filter keeps them")
			}
			if !bytes.Equal(ref.ImageData, png) {
				t.Fatal("image bytes do not match zip contents")
			}
		}
	}
	if !found {
		t.Fatalf("missing OriginalRef images/session-timeout.png in %+v", result.ImageRefs)
	}
}

func TestMarkdownZipToResultNestedFolder(t *testing.T) {
	png := createTestPNG(80, 80)
	md := "![图](images/示意图.png)"
	data := buildTestZip(t, map[string][]byte{
		"手册/工具端常见问题与配置.md":  []byte(md),
		"手册/images/示意图.png": png,
	})
	result, err := markdownZipToResult(data)
	if err != nil {
		t.Fatalf("markdownZipToResult: %v", err)
	}
	if got := result.ImageRefs[0].OriginalRef; got != "images/示意图.png" {
		t.Fatalf("OriginalRef = %q, want the markdown-literal path", got)
	}
}

func TestMarkdownZipToResultPrefersMarkdownNextToImages(t *testing.T) {
	png := createTestPNG(90, 90)
	data := buildTestZip(t, map[string][]byte{
		"README.md":        []byte("no pictures"),
		"doc/guide.md":     []byte("![x](images/a.png)"),
		"doc/images/a.png": png,
	})
	result, err := markdownZipToResult(data)
	if err != nil {
		t.Fatalf("markdownZipToResult: %v", err)
	}
	if !strings.Contains(result.MarkdownContent, "images/a.png") {
		t.Fatalf("picked the wrong markdown file: %q", result.MarkdownContent)
	}
	if len(result.ImageRefs) == 0 {
		t.Fatal("expected the nested guide.md images to be resolved")
	}
}

func TestMarkdownZipToResultRequiresMarkdown(t *testing.T) {
	data := buildTestZip(t, map[string][]byte{
		"images/a.png": createTestPNG(80, 80),
	})
	if _, err := markdownZipToResult(data); err == nil {
		t.Fatal("expected error when zip has no markdown")
	}
}

func TestMarkdownZipRejectsPathTraversal(t *testing.T) {
	data := buildTestZip(t, map[string][]byte{
		"doc.md":          []byte("ok"),
		"../escape.png":   createTestPNG(80, 80),
		"/abs/hack.png":   createTestPNG(80, 80),
		"images/../x.png": createTestPNG(80, 80),
	})
	files, err := readMarkdownZip(data)
	if err != nil {
		t.Fatalf("readMarkdownZip: %v", err)
	}
	for name := range files {
		if strings.Contains(name, "..") || strings.HasPrefix(name, "/") {
			t.Fatalf("unsafe zip path kept: %q", name)
		}
	}
}

func TestMarkdownZipDecodesGBKEntryNames(t *testing.T) {
	png := createTestPNG(100, 80)
	utf8Name := "images/超时.png"
	gbkName, err := simplifiedchinese.GBK.NewEncoder().String(utf8Name)
	if err != nil {
		t.Fatalf("gbk encode: %v", err)
	}

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	mdw, err := zw.Create("faq.md")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := mdw.Write([]byte("![超时](images/超时.png)\n")); err != nil {
		t.Fatal(err)
	}
	hdr := &zip.FileHeader{Name: gbkName, Method: zip.Store}
	w, err := zw.CreateHeader(hdr)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write(png); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}

	result, err := markdownZipToResult(buf.Bytes())
	if err != nil {
		t.Fatalf("markdownZipToResult: %v", err)
	}
	found := false
	for _, ref := range result.ImageRefs {
		if ref.OriginalRef == "images/超时.png" && bytes.Equal(ref.ImageData, png) {
			found = true
		}
	}
	if !found {
		t.Fatalf("GBK zip entry was not matched to markdown path, refs=%+v", originalRefs(result.ImageRefs))
	}
}

func originalRefs(refs []types.ImageRef) []string {
	out := make([]string, 0, len(refs))
	for _, ref := range refs {
		out = append(out, ref.OriginalRef)
	}
	return out
}

func TestSimpleFormatReaderReadsMarkdownZip(t *testing.T) {
	png := createTestPNG(120, 90)
	data := buildTestZip(t, map[string][]byte{
		"faq.md":       []byte("![图](images/a.png)"),
		"images/a.png": png,
	})
	reader := &SimpleFormatReader{}
	result, err := reader.Read(context.Background(), &types.ReadRequest{
		FileName:    "faq.zip",
		FileType:    "zip",
		FileContent: data,
	})
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if len(result.ImageRefs) == 0 {
		t.Fatal("simple reader did not attach zip image refs")
	}

	svc := &captureSaveBytes{}
	updated, images, err := NewImageResolver().ResolveAndStore(context.Background(), result, svc, 1)
	if err != nil {
		t.Fatalf("ResolveAndStore: %v", err)
	}
	if len(images) == 0 || !strings.Contains(updated, "local://") {
		t.Fatalf("relative images were not rewritten: md=%q images=%+v", updated, images)
	}
	if strings.Contains(updated, "images/a.png") {
		t.Fatalf("markdown still has the relative path: %q", updated)
	}
}

func TestNewReaderKeepsZipOnSimpleReader(t *testing.T) {
	ctx := context.Background()
	deps := ReaderDeps{Remote: &stubRemote{}}
	for _, engine := range []string{"", BuiltinEngineName, SimpleEngineName, AnydocEngineName} {
		reader, err := NewReader(ctx, engine, "zip", false, deps)
		if err != nil {
			t.Fatalf("NewReader(%q): %v", engine, err)
		}
		if _, ok := reader.(*SimpleFormatReader); !ok {
			t.Fatalf("engine %q routed zip to %T, want *SimpleFormatReader", engine, reader)
		}
	}
}
