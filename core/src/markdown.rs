// Markdown laid out as the rich text the interface draws: headings, lists, quotes, code, tables and local pictures,
// in the colours of the theme the interface passes. Raw HTML and remote pictures are left out: a preview never
// reaches the network.

use crate::util;
use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::Path;

struct Look {
    ink: String,
    ink2: String,
    ink3: String,
    line: String,
    fill: String,
    accent: String,
    mono: String,
    base: f64,
    width: f64,
}

fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(c),
        }
    }
    out
}

fn px(v: f64) -> String {
    format!("{}px", v.round() as i64)
}

/// A picture beside the file: its URL and the size it takes, no wider than the page.
fn picture(dir: &Path, dest: &str, width: f64) -> Option<(String, Option<(f64, f64)>)> {
    if dest.contains("://") && !dest.starts_with("file://") {
        return None;
    }
    let path = if let Some(p) = util::path_from_uri(dest) {
        p
    } else {
        let clean = dest.split(['#', '?']).next().unwrap_or("");
        let decoded = percent_encoding::percent_decode_str(clean).decode_utf8_lossy().into_owned();
        let p = Path::new(&decoded);
        if p.is_absolute() { p.to_path_buf() } else { dir.join(p) }
    };
    if !path.is_file() {
        return None;
    }
    let size = imagesize::size(&path).ok().map(|s| {
        let (w, h) = (s.width as f64, s.height as f64);
        let scale = if w > width { width / w } else { 1.0 };
        (w * scale, h * scale)
    });
    Some((util::uri(&path), size))
}

fn render(src: &str, dir: &Path, k: &Look) -> String {
    let opts = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS | Options::ENABLE_FOOTNOTES | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS;
    let gap = k.base * 0.8;
    let mut out = String::with_capacity(src.len() * 2);
    let mut aligns: Vec<Alignment> = Vec::new();
    let mut cell = 0usize;
    let mut head = false;
    let mut in_code = false;
    let mut in_meta = false;
    // Alt text gathers here while a picture is open.
    let mut alt: Option<String> = None;
    let mut pic_dest = String::new();
    // A footnote's mark waits for the first paragraph of its text.
    let mut note: Option<String> = None;
    // Qt's rich text draws a line as a coloured rule; borders of single cells it leaves out.
    let rule = |out: &mut String, top: f64, bottom: f64| {
        out.push_str(&format!("<hr style=\"background-color: {}; margin-top: {}; margin-bottom: {};\"/>", k.line, px(top), px(bottom)));
    };
    let events: Vec<Event> = Parser::new_ext(src, opts).collect();
    // Lists of tasks: their boxes are the marks, and Qt cannot hide a bullet, so they are laid out as lines.
    let tasks: HashSet<usize> = (0..events.len())
        .filter(|&i| matches!(events[i], Event::Start(Tag::List(None))))
        .filter(|&i| events[i + 1..].iter().take(3).any(|e| matches!(e, Event::TaskListMarker(_))))
        .collect();
    let mut kinds: Vec<bool> = Vec::new();
    let mut task_p: Option<(usize, usize)> = None;
    let mut task_paras = 0usize;
    for (i, ev) in events.into_iter().enumerate() {
        let in_task = kinds.last() == Some(&true);
        if let Some(a) = alt.as_mut() {
            match ev {
                Event::Text(t) | Event::Code(t) => a.push_str(&t),
                Event::End(TagEnd::Image) => {
                    let text = alt.take().unwrap_or_default();
                    match picture(dir, &pic_dest, k.width) {
                        Some((url, Some((w, h)))) => out.push_str(&format!("<img src=\"{}\" width=\"{}\" height=\"{}\" alt=\"{}\">", esc(&url), w.round(), h.round(), esc(&text))),
                        Some((url, None)) => out.push_str(&format!("<img src=\"{}\" width=\"{}\" alt=\"{}\">", esc(&url), k.width.min(480.0).round(), esc(&text))),
                        None if !text.is_empty() => out.push_str(&format!("<span style=\"color: {};\">[{}]</span>", k.ink3, esc(&text))),
                        None => {}
                    }
                }
                _ => {}
            }
            continue;
        }
        match ev {
            Event::Start(tag) => match tag {
                Tag::Paragraph if in_task => {
                    if task_paras > 0 {
                        out.push_str("<br>");
                    }
                    task_paras += 1;
                }
                Tag::Paragraph => {
                    out.push_str(&format!("<p style=\"margin-top: 0; margin-bottom: {}; line-height: 150%;\">", px(gap)));
                    if let Some(n) = note.take() {
                        out.push_str(&format!("<sup style=\"color: {};\">{}</sup>&nbsp;", k.accent, esc(&n)));
                    }
                }
                Tag::Heading { level, .. } => {
                    let (scale, weight) = match level {
                        HeadingLevel::H1 => (1.9, 700),
                        HeadingLevel::H2 => (1.5, 650),
                        HeadingLevel::H3 => (1.25, 650),
                        HeadingLevel::H4 => (1.1, 600),
                        _ => (1.0, 600),
                    };
                    out.push_str(&format!(
                        "<p style=\"margin-top: {}; margin-bottom: {}; font-size: {}; font-weight: {}; color: {};\">",
                        px(k.base * 1.1), px(k.base * 0.45), px(k.base * scale), weight, k.ink
                    ));
                }
                Tag::BlockQuote(_) => out.push_str(&format!(
                    "<table width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" style=\"margin-top: {}; margin-bottom: {};\"><tr><td width=\"3\" bgcolor=\"{}\"></td><td style=\"padding-left: {}; color: {};\">",
                    px(k.base * 0.4), px(gap), k.accent, px(k.base), k.ink2
                )),
                Tag::CodeBlock(kind) => {
                    in_code = true;
                    let lang = match kind { CodeBlockKind::Fenced(l) => l.split_whitespace().next().unwrap_or("").to_string(), _ => String::new() };
                    out.push_str(&format!(
                        "<table width=\"100%\" cellspacing=\"0\" cellpadding=\"{}\" style=\"border-collapse: collapse; margin-bottom: {}; background-color: {};\"><tr><td>",
                        (k.base * 0.9).round(), px(gap), k.fill
                    ));
                    if !lang.is_empty() {
                        out.push_str(&format!("<p style=\"margin: 0 0 {} 0; font-size: {}; color: {};\">{}</p>", px(k.base * 0.4), px(k.base * 0.8), k.ink3, esc(&lang)));
                    }
                    out.push_str(&format!("<pre style=\"margin: 0; font-family: '{}'; font-size: {}; color: {};\">", esc(&k.mono), px(k.base * 0.92), k.ink));
                }
                Tag::List(None) if tasks.contains(&i) => kinds.push(true),
                Tag::List(Some(start)) => {
                    kinds.push(false);
                    out.push_str(&format!("<ol start=\"{}\" style=\"margin-top: 0; margin-bottom: {};\">", start, px(gap)));
                }
                Tag::List(None) => {
                    kinds.push(false);
                    out.push_str(&format!("<ul style=\"margin-top: 0; margin-bottom: {};\">", px(gap)));
                }
                Tag::Item if in_task => {
                    task_paras = 0;
                    let tag = format!("<p style=\"margin-top: 0; margin-bottom: {}; margin-left: {}; line-height: 150%;\">", px(k.base * 0.3), px(k.base * 2.1 * kinds.len() as f64));
                    task_p = Some((out.len(), tag.len()));
                    out.push_str(&tag);
                }
                Tag::Item => out.push_str(&format!("<li style=\"margin-bottom: {}; line-height: 150%;\">", px(k.base * 0.25))),
                Tag::Table(a) => {
                    aligns = a;
                    out.push_str(&format!(
                        "<table border=\"1\" cellspacing=\"0\" cellpadding=\"{}\" style=\"border-collapse: collapse; border-style: solid; border-color: {}; margin-bottom: {};\">",
                        (k.base * 0.5).round(), k.line, px(gap)
                    ));
                }
                Tag::TableHead => {
                    head = true;
                    cell = 0;
                    out.push_str("<tr>");
                }
                Tag::TableRow => {
                    cell = 0;
                    out.push_str("<tr>");
                }
                Tag::TableCell => {
                    let align = match aligns.get(cell) { Some(Alignment::Center) => "center", Some(Alignment::Right) => "right", _ => "left" };
                    let (tag, weight) = if head { ("th", 650) } else { ("td", 400) };
                    out.push_str(&format!(
                        "<{} align=\"{}\" style=\"font-weight: {}; padding-left: {}; padding-right: {};\">",
                        tag, align, weight, px(k.base * 0.8), px(k.base * 0.8)
                    ));
                }
                Tag::Emphasis => out.push_str("<i>"),
                Tag::Strong => out.push_str("<span style=\"font-weight: 650;\">"),
                Tag::Strikethrough => out.push_str(&format!("<s style=\"color: {};\">", k.ink2)),
                Tag::Link { dest_url, .. } => out.push_str(&format!("<a href=\"{}\" style=\"color: {}; text-decoration: none;\">", esc(&dest_url), k.accent)),
                Tag::Image { dest_url, .. } => {
                    pic_dest = dest_url.to_string();
                    alt = Some(String::new());
                }
                Tag::FootnoteDefinition(name) => {
                    note = Some(name.to_string());
                    out.push_str(&format!("<div style=\"font-size: {}; color: {};\">", px(k.base * 0.88), k.ink2));
                }
                Tag::MetadataBlock(_) => in_meta = true,
                _ => {}
            },
            Event::End(tag) => match tag {
                TagEnd::Paragraph if in_task => {}
                TagEnd::Paragraph => out.push_str("</p>"),
                TagEnd::Heading(level) => {
                    out.push_str("</p>");
                    if matches!(level, HeadingLevel::H1 | HeadingLevel::H2) {
                        rule(&mut out, 0.0, k.base * 0.7);
                    }
                }
                TagEnd::BlockQuote(..) => out.push_str("</td></tr></table>"),
                TagEnd::CodeBlock => {
                    in_code = false;
                    // The last line break of a block is its end, not an empty line.
                    if out.ends_with('\n') {
                        out.pop();
                    }
                    out.push_str("</pre></td></tr></table>");
                }
                TagEnd::List(ordered) => {
                    if kinds.pop() == Some(true) {
                        // The last task keeps the room a list leaves below itself.
                        if let Some((at, len)) = task_p.take() {
                            let tag = out[at..at + len].replacen(&format!("margin-bottom: {};", px(k.base * 0.3)), &format!("margin-bottom: {};", px(gap)), 1);
                            out.replace_range(at..at + len, &tag);
                        }
                    } else {
                        out.push_str(if ordered { "</ol>" } else { "</ul>" });
                    }
                }
                TagEnd::Item if in_task => out.push_str("</p>"),
                TagEnd::Item => out.push_str("</li>"),
                TagEnd::Table => out.push_str("</table>"),
                TagEnd::TableHead => {
                    head = false;
                    out.push_str("</tr>");
                }
                TagEnd::TableRow => out.push_str("</tr>"),
                TagEnd::TableCell => {
                    out.push_str(if head { "</th>" } else { "</td>" });
                    cell += 1;
                }
                TagEnd::Emphasis => out.push_str("</i>"),
                TagEnd::Strong => out.push_str("</span>"),
                TagEnd::Strikethrough => out.push_str("</s>"),
                TagEnd::Link => out.push_str("</a>"),
                TagEnd::FootnoteDefinition => out.push_str("</div>"),
                TagEnd::MetadataBlock(_) => in_meta = false,
                _ => {}
            },
            Event::Text(t) if in_meta => drop(t),
            Event::Text(t) => out.push_str(&esc(&t)),
            Event::Code(t) => out.push_str(&format!(
                "<span style=\"font-family: '{}'; font-size: {}; background-color: {};\">&nbsp;{}&nbsp;</span>",
                esc(&k.mono), px(k.base * 0.9), k.fill, esc(&t)
            )),
            Event::SoftBreak => out.push(if in_code { '\n' } else { ' ' }),
            Event::HardBreak => out.push_str("<br>"),
            Event::Rule => rule(&mut out, k.base * 0.4, k.base * 1.0),
            Event::TaskListMarker(done) => {
                out.push_str(&format!(
                "<span style=\"color: {};\">{}</span>&nbsp;",
                if done { &k.accent } else { &k.ink3 },
                if done { "\u{2611}" } else { "\u{2610}" }
            ))
            }
            Event::FootnoteReference(name) => out.push_str(&format!("<sup style=\"color: {};\">{}</sup>", k.accent, esc(&name))),
            Event::Html(h) | Event::InlineHtml(h) => {
                let t = h.trim().to_ascii_lowercase();
                if t == "<br>" || t == "<br/>" || t == "<br />" {
                    out.push_str("<br>");
                }
            }
            _ => {}
        }
    }
    out
}

pub fn markdown(req: &Value) -> Result<Value, String> {
    let path = Path::new(req["path"].as_str().unwrap_or(""));
    let limit = req["limit"].as_u64().unwrap_or(1 << 20) as usize;
    let head = crate::info::text_head(path, limit);
    let src = head["text"].as_str().ok_or("read")?;
    let s = |key: &str, or: &str| req["look"][key].as_str().unwrap_or(or).to_string();
    let k = Look {
        ink: s("ink", "#e6e7eb"),
        ink2: s("ink2", "#a0a2a8"),
        ink3: s("ink3", "#7d8087"),
        line: s("line", "#33353a"),
        fill: s("fill", "#24262b"),
        accent: s("accent", "#a8c7fa"),
        mono: s("mono", "monospace"),
        base: req["look"]["base"].as_f64().unwrap_or(13.0).max(8.0),
        width: req["look"]["width"].as_f64().unwrap_or(640.0).max(64.0),
    };
    let dir = path.parent().unwrap_or(Path::new("/"));
    Ok(json!({"html": render(src, dir, &k), "truncated": head["truncated"]}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn look() -> Look {
        Look { ink: "i".into(), ink2: "i2".into(), ink3: "i3".into(), line: "l".into(), fill: "f".into(), accent: "a".into(), mono: "m".into(), base: 10.0, width: 300.0 }
    }

    #[test]
    fn escapes_and_drops_raw_html() {
        let html = render("a <b>&</b> <script>x</script>\n", Path::new("/"), &look());
        assert!(html.contains("a "));
        assert!(!html.contains("<script>"));
        assert!(!html.contains("<b>"));
    }

    #[test]
    fn remote_pictures_stay_text() {
        let html = render("![logo](https://example.com/a.png)", Path::new("/"), &look());
        assert!(!html.contains("<img"));
        assert!(html.contains("[logo]"));
    }

    #[test]
    fn tables_and_tasks() {
        let html = render("| a | b |\n|:-:|--:|\n| 1 | 2 |\n\n- [x] done\n- [ ] open\n", Path::new("/"), &look());
        assert!(html.contains("<th align=\"center\""));
        assert!(!html.contains("<ul"));
        assert!(html.contains("<td align=\"right\""));
        assert!(html.contains("\u{2611}") && html.contains("\u{2610}"));
    }
}
