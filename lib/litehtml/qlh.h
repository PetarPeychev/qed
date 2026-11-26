#ifndef QLH_H
#define QLH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
	QLH_BOLD      = 1,
	QLH_ITALIC    = 2,
	QLH_MONO      = 4,
	QLH_UNDERLINE = 8,
	QLH_STRIKE    = 16,
};

typedef struct qlh_rect {
	float x, y, w, h;
} qlh_rect;

typedef struct qlh_border {
	float    width;
	int      style;
	uint32_t color;
} qlh_border;

typedef struct qlh_callbacks {
	void* user;
	float (*text_width)(void* user, const char* text, int font);
	void (*draw_text)(void* user, const char* text, int font, uint32_t color, qlh_rect pos);
	void (*fill)(void* user, uint32_t color, qlh_rect box, qlh_rect clip);
	void (*borders)(void* user, const qlh_border* sides, qlh_rect box);
	void (*marker)(void* user, int type, int index, uint32_t color, int font, qlh_rect pos);
	void (*image_size)(void* user, const char* src, int* w, int* h);
	void (*draw_image)(void* user, const char* src, qlh_rect box);
	void (*set_clip)(void* user, qlh_rect box);
	void (*del_clip)(void* user);
} qlh_callbacks;

typedef void (*qlh_walk_proc)(void* user, const char* tag, const char* href, const char* sourcepos, const char* alt, const char* id, qlh_rect box);

typedef struct qlh_doc qlh_doc;

qlh_doc* qlh_create(const char* html, const char* master_css, const char* user_css, const qlh_callbacks* cb, int cell_w, int cell_h);
float    qlh_render(qlh_doc* doc, float width);
float    qlh_height(qlh_doc* doc);
void     qlh_draw(qlh_doc* doc, qlh_rect clip);
void     qlh_walk(qlh_doc* doc, qlh_walk_proc proc, void* user);
void     qlh_destroy(qlh_doc* doc);

#ifdef __cplusplus
}
#endif

#endif
