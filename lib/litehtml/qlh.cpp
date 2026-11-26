#include "qlh.h"
#include <litehtml.h>
#include <litehtml/render_item.h>
#include <cstring>

using namespace litehtml;

static uint32_t qlh_color(const web_color& c)
{
	return (uint32_t(c.red) << 24) | (uint32_t(c.green) << 16) | (uint32_t(c.blue) << 8) | uint32_t(c.alpha);
}

static qlh_rect qlh_pos(const position& p)
{
	return qlh_rect{float(p.x), float(p.y), float(p.width), float(p.height)};
}

class qlh_container : public document_container
{
  public:
	qlh_callbacks cb;
	int           cell_w = 8;
	int           cell_h = 16;
	pixel_t       view_w = 800;

	uint_ptr create_font(const font_description& d, const document*, font_metrics* fm) override
	{
		int flags = 0;
		if(d.weight >= 600) flags |= QLH_BOLD;
		if(d.style != font_style_normal) flags |= QLH_ITALIC;
		if(d.family.find("mono") != std::string::npos || d.family.find("courier") != std::string::npos) flags |= QLH_MONO;
		if(d.decoration_line & text_decoration_line_underline) flags |= QLH_UNDERLINE;
		if(d.decoration_line & text_decoration_line_line_through) flags |= QLH_STRIKE;
		if(fm)
		{
			fm->font_size   = d.size;
			fm->height      = pixel_t(cell_h);
			fm->ascent      = pixel_t(cell_h - cell_h / 4);
			fm->descent     = pixel_t(cell_h / 4);
			fm->x_height    = pixel_t(cell_h / 2);
			fm->ch_width    = pixel_t(cell_w);
			fm->draw_spaces = true;
			fm->sub_shift   = 0;
			fm->super_shift = 0;
		}
		return uint_ptr(flags + 1);
	}
	void    delete_font(uint_ptr) override {}
	pixel_t text_width(const char* text, uint_ptr font) override { return cb.text_width(cb.user, text, int(font) - 1); }
	void    draw_text(uint_ptr, const char* text, uint_ptr font, web_color color, const position& pos) override
	{
		cb.draw_text(cb.user, text, int(font) - 1, qlh_color(color), qlh_pos(pos));
	}
	pixel_t     pt_to_px(float pt) const override { return pixel_t(pt * cell_h / 12.0f); }
	pixel_t     get_default_font_size() const override { return pixel_t(cell_h); }
	const char* get_default_font_name() const override { return "sans-serif"; }
	void        draw_list_marker(uint_ptr, const list_marker& m) override
	{
		cb.marker(cb.user, int(m.marker_type), m.index, qlh_color(m.color), int(m.font) - 1, qlh_pos(m.pos));
	}
	void load_image(const char*, const char*, bool) override {}
	void get_image_size(const char* src, const char*, size& sz) override
	{
		int w = 0, h = 0;
		cb.image_size(cb.user, src, &w, &h);
		sz.width  = pixel_t(w);
		sz.height = pixel_t(h);
	}
	void draw_image(uint_ptr, const background_layer& layer, const std::string& url, const std::string&) override
	{
		cb.draw_image(cb.user, url.c_str(), qlh_pos(layer.border_box));
	}
	void draw_solid_fill(uint_ptr, const background_layer& layer, const web_color& color) override
	{
		if(layer.is_root) return;
		cb.fill(cb.user, qlh_color(color), qlh_pos(layer.border_box), qlh_pos(layer.clip_box));
	}
	void draw_linear_gradient(uint_ptr, const background_layer&, const background_layer::linear_gradient&) override {}
	void draw_radial_gradient(uint_ptr, const background_layer&, const background_layer::radial_gradient&) override {}
	void draw_conic_gradient(uint_ptr, const background_layer&, const background_layer::conic_gradient&) override {}
	void draw_borders(uint_ptr, const borders& b, const position& pos, bool root) override
	{
		if(root) return;
		qlh_border sides[4] = {
			{float(b.left.width), int(b.left.style), qlh_color(b.left.color)},
			{float(b.top.width), int(b.top.style), qlh_color(b.top.color)},
			{float(b.right.width), int(b.right.style), qlh_color(b.right.color)},
			{float(b.bottom.width), int(b.bottom.style), qlh_color(b.bottom.color)},
		};
		cb.borders(cb.user, sides, qlh_pos(pos));
	}
	void draw_combobox_marker(uint_ptr, const position&, const web_color&) override {}
	void draw_checkbox_marker(uint_ptr, const position& pos, const web_color& color) override
	{
		cb.draw_text(cb.user, "x", 0, qlh_color(color), qlh_pos(pos));
	}
	void set_caption(const char*) override {}
	void set_base_url(const char*) override {}
	void link(const std::shared_ptr<document>&, const element::ptr&) override {}
	void on_anchor_click(const char*, const element::ptr&) override {}
	void on_mouse_event(const element::ptr&, mouse_event) override {}
	void set_cursor(const char*) override {}
	void transform_text(std::string&, text_transform) override {}
	void import_css(std::string&, const std::string&, std::string&) override {}
	void set_clip(const position& pos, const border_radiuses&) override { cb.set_clip(cb.user, qlh_pos(pos)); }
	void del_clip() override { cb.del_clip(cb.user); }
	void get_viewport(position& v) const override { v = position(0, 0, view_w, 100000); }
	element::ptr create_element(const char*, const string_map&, const std::shared_ptr<document>&) override { return nullptr; }
	void         get_media_features(media_features& m) const override
	{
		m.type          = media_type_screen;
		m.width         = view_w;
		m.height        = 100000;
		m.device_width  = view_w;
		m.device_height = 100000;
		m.color         = 8;
		m.monochrome    = 0;
		m.color_index   = 256;
		m.resolution    = 96;
	}
	void get_language(std::string& language, std::string& culture) const override
	{
		language = "en";
		culture  = "";
	}
};

struct qlh_doc
{
	qlh_container container;
	document::ptr doc;
};

extern "C" qlh_doc* qlh_create(const char* html, const char* master_css, const char* user_css, const qlh_callbacks* cb, int cell_w, int cell_h)
{
	auto d              = new qlh_doc;
	d->container.cb     = *cb;
	d->container.cell_w = cell_w;
	d->container.cell_h = cell_h;
	d->doc = document::createFromString(html, &d->container, master_css ? std::string(master_css) : std::string(litehtml::master_css),
	                                    user_css ? user_css : "");
	return d;
}

extern "C" float qlh_render(qlh_doc* d, float width)
{
	d->container.view_w = width;
	d->doc->media_changed();
	return float(d->doc->render(width));
}

extern "C" float qlh_height(qlh_doc* d) { return float(d->doc->height()); }

extern "C" void qlh_draw(qlh_doc* d, qlh_rect clip)
{
	position p(clip.x, clip.y, clip.w, clip.h);
	d->doc->draw(0, 0, 0, &p);
}

static void qlh_walk_el(const element::ptr& el, qlh_walk_proc proc, void* user)
{
	const char* tag  = el->get_tagName();
	bool        img  = tag && strcmp(tag, "img") == 0;
	const char* href = el->get_attr(img ? "src" : "href");
	const char* sp   = el->get_attr("data-sourcepos");
	const char* id   = el->get_attr("id");
	if(href || sp || img || id)
	{
		const char* alt = el->get_attr("alt");
		auto        ri  = el->get_render_item();
		if(ri)
		{
			ri->get_rendering_boxes([&](const position& box) { proc(user, tag, href, sp, alt, id, qlh_pos(box)); }, false);
		}
	}
	for(auto& child : el->children()) qlh_walk_el(child, proc, user);
}

extern "C" void qlh_walk(qlh_doc* d, qlh_walk_proc proc, void* user) { qlh_walk_el(d->doc->root(), proc, user); }

extern "C" void qlh_destroy(qlh_doc* d) { delete d; }
