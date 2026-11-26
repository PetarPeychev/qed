#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cmark-gfm.h"
#include "cmark-gfm-core-extensions.h"

typedef char* (*qmd_code_proc)(void* user, const char* info, const char* code, int first_line);

static void qmd_attach(cmark_parser* parser, const char* name)
{
	cmark_syntax_extension* ext = cmark_find_syntax_extension(name);
	if (ext) cmark_parser_attach_syntax_extension(parser, ext);
}

static void qmd_tag_sourcepos(cmark_node* node)
{
	const char* lit = cmark_node_get_literal(node);
	if (!lit || lit[0] != '<' || !((lit[1] >= 'a' && lit[1] <= 'z') || (lit[1] >= 'A' && lit[1] <= 'Z'))) return;
	size_t name = 1;
	while ((lit[name] >= 'a' && lit[name] <= 'z') || (lit[name] >= 'A' && lit[name] <= 'Z') || (lit[name] >= '0' && lit[name] <= '9')) name++;
	size_t n = strlen(lit) + 64;
	char* out = malloc(n);
	snprintf(out, n, "%.*s data-sourcepos=\"%d:%d-%d:%d\"%s", (int)name, lit, cmark_node_get_start_line(node),
	         cmark_node_get_start_column(node), cmark_node_get_end_line(node), cmark_node_get_end_column(node), lit + name);
	cmark_node_set_literal(node, out);
	free(out);
}

void cmark_manage_extensions_special_characters(cmark_parser* parser, int add);

static cmark_parser* qmd_parser(int options)
{
	cmark_parser* parser = cmark_parser_new(options);
	qmd_attach(parser, "table");
	qmd_attach(parser, "strikethrough");
	qmd_attach(parser, "autolink");
	qmd_attach(parser, "tagfilter");
	qmd_attach(parser, "tasklist");
	return parser;
}

void qmd_init(void)
{
	static int done;
	if (done) return;
	done = 1;
	cmark_gfm_core_extensions_ensure_registered();
	cmark_parser* parser = qmd_parser(0);
	cmark_manage_extensions_special_characters(parser, 1);
	cmark_parser_free(parser);
}

/* A piece may start before a top-level block whose predecessor ends with a one-row bottom margin; the marker gives
   the block's first line, so the pieces' source rows can be relative; the nonce keeps a comment in the source from
   passing for one. Footnote definitions render inside one
   section and never start a piece. */
static void qmd_mark_pieces(cmark_node* doc, unsigned long long nonce)
{
	cmark_node* prev = cmark_node_first_child(doc);
	if (!prev) return;
	for (cmark_node* node = cmark_node_next(prev); node; node = cmark_node_next(node)) {
		cmark_node_type before = cmark_node_get_type(prev);
		const char* name = cmark_node_get_type_string(prev);
		int margin = before == CMARK_NODE_PARAGRAPH || before == CMARK_NODE_HEADING || before == CMARK_NODE_LIST ||
		             before == CMARK_NODE_BLOCK_QUOTE || before == CMARK_NODE_CODE_BLOCK || before == CMARK_NODE_THEMATIC_BREAK ||
		             (name && strcmp(name, "table") == 0);
		prev = node;
		if (!margin || cmark_node_get_type(node) == CMARK_NODE_FOOTNOTE_DEFINITION) continue;
		char marker[64];
		snprintf(marker, sizeof marker, "<!--qed-piece %llx %d-->\n", nonce, cmark_node_get_start_line(node));
		cmark_node* raw = cmark_node_new(CMARK_NODE_HTML_BLOCK);
		cmark_node_set_literal(raw, marker);
		cmark_node_insert_before(node, raw);
	}
}

char* qmd_to_html(const char* md, size_t len, int sourcepos, unsigned long long nonce, qmd_code_proc code, void* user)
{
	int options = CMARK_OPT_UNSAFE | CMARK_OPT_GITHUB_PRE_LANG | CMARK_OPT_FOOTNOTES | (sourcepos ? CMARK_OPT_SOURCEPOS : 0);
	cmark_parser* parser = qmd_parser(options);
	cmark_parser_feed(parser, md, len);
	cmark_node* doc = cmark_parser_finish(parser);
	if (sourcepos) qmd_mark_pieces(doc, nonce);
	{
		cmark_node** blocks = NULL;
		size_t count = 0, cap = 0;
		cmark_iter* it = cmark_iter_new(doc);
		cmark_event_type ev;
		while ((ev = cmark_iter_next(it)) != CMARK_EVENT_DONE) {
			cmark_node* node = cmark_iter_get_node(it);
			if (ev != CMARK_EVENT_ENTER) continue;
			if (sourcepos && cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK) qmd_tag_sourcepos(node);
			if (cmark_node_get_type(node) != CMARK_NODE_CODE_BLOCK) continue;
			if (count == cap) {
				cap = cap ? cap * 2 : 16;
				blocks = realloc(blocks, cap * sizeof(*blocks));
			}
			blocks[count++] = node;
		}
		cmark_iter_free(it);
		for (size_t i = 0; i < count; i++) {
			cmark_node* node = blocks[i];
			if (!code) break;
			const char* info = cmark_node_get_fence_info(node);
			int fence_len = 0, fence_off = 0;
			char fence_ch = 0;
			int fenced = cmark_node_get_fenced(node, &fence_len, &fence_off, &fence_ch);
			char* body = code(user, info ? info : "", cmark_node_get_literal(node), cmark_node_get_start_line(node) + (fenced ? 1 : 0));
			if (!body) continue;
			size_t n = strlen(body) + 128;
			char* html = malloc(n);
			snprintf(html, n, "<pre data-sourcepos=\"%d:%d-%d:%d\"><code>%s</code></pre>\n", cmark_node_get_start_line(node),
			         cmark_node_get_start_column(node), cmark_node_get_end_line(node), cmark_node_get_end_column(node), body);
			free(body);
			cmark_node* raw = cmark_node_new(CMARK_NODE_HTML_BLOCK);
			cmark_node_set_literal(raw, html);
			free(html);
			cmark_node_insert_before(node, raw);
			cmark_node_free(node);
		}
		free(blocks);
	}
	char* html = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser));
	cmark_node_free(doc);
	cmark_parser_free(parser);
	return html;
}

void qmd_free(char* p) { free(p); }
