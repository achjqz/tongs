#!/usr/bin/env python3
"""Writes public/index.html and public/zh/index.html from src/index.html, plus sitemap.xml.

The source holds both languages inline as <span data-l="en|zh">. Each page keeps only its own, so
every language has one URL with one language of text in it, which is what search engines index.
wrangler runs this before each deploy.
"""
import datetime
import json
import pathlib
import re

SITE = "https://tongs.roamake.com"
HERE = pathlib.Path(__file__).parent

PAGES = {
    "en": dict(
        lang="en",
        path="/",
        out="public/index.html",
        title="tongs: API key manager for Claude Code and Codex on macOS",
        description="Let coding agents use your API keys without seeing them. tongs keeps keys in the macOS Keychain, asks for Touch ID, and masks values in command output. Free and open source.",
        og_locale="en_US",
        og_image="og-en.jpg",
        og_alt="Forged steel tongs holding a red-hot key, with the headline: Let coding agents use your API keys without seeing them",
        other_url="/zh/",
        other_lang="zh-CN",
        other_short="中文",
        other_label="中文",
        demo_label="Demo",
        panel_image="panel-en.png",
        panel_alt="The tongs panel asking for STRIPE_SECRET_KEY",
    ),
    "zh": dict(
        lang="zh-CN",
        path="/zh/",
        out="public/zh/index.html",
        title="tongs：让 Claude Code 和 Codex 使用 API key 而看不到它的值",
        description="让编程 agent 使用你的 API key，而看不到它的值。tongs 把 key 存在 macOS 钥匙串里，用 Touch ID 批准，并遮掉命令输出里的值。免费开源。",
        og_locale="zh_CN",
        og_image="og-zh.jpg",
        og_alt="一把锻钢钳子夹着烧红的钥匙，标题是：让编程 agent 使用你的 API key，而看不到它的值",
        other_url="/",
        other_lang="en",
        other_short="EN",
        other_label="English",
        demo_label="演示",
        panel_image="panel-zh.png",
        panel_alt="tongs 面板正在请求 STRIPE_SECRET_KEY",
    ),
}


def keep_language(html, keep):
    """Drops <span data-l="other">…</span> with its contents and strips the attribute from our own."""
    out, i = [], 0
    opener = re.compile(r'<span data-l="(en|zh)">')
    while True:
        m = opener.search(html, i)
        if not m:
            out.append(html[i:])
            return "".join(out)
        out.append(html[i:m.start()])
        if m.group(1) == keep:
            out.append("<span>")
            i = m.end()
            continue
        depth, j = 1, m.end()
        while depth:
            t = re.compile(r"<span\b|</span>").search(html, j)
            depth += 1 if t.group() != "</span>" else -1
            j = t.end()
        i = j


def jsonld(page):
    return json.dumps({
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "tongs",
        "url": SITE + page["path"],
        "description": page["description"],
        "inLanguage": page["lang"],
        "applicationCategory": "DeveloperApplication",
        "operatingSystem": "macOS 15 or later",
        "softwareVersion": VERSION,
        "license": "https://www.apache.org/licenses/LICENSE-2.0",
        "downloadUrl": "https://github.com/achjqz/tongs/releases/latest",
        "installUrl": SITE + "/llms.txt",
        "sameAs": "https://github.com/achjqz/tongs",
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "author": {"@type": "Person", "name": "achjqz", "url": "https://github.com/achjqz"},
    }, ensure_ascii=False, separators=(",", ":"))


VERSION = re.search(r'let version = "([^"]+)"', (HERE.parent / "Sources/tongs/main.swift").read_text()).group(1)
source = (HERE / "src/index.html").read_text()

for key, page in PAGES.items():
    html = keep_language(source, key)
    values = {**page, "url": SITE + page["path"], "url_path": page["path"], "jsonld": jsonld(page)}
    html = re.sub(r"\{\{(\w+)\}\}", lambda m: values[m.group(1)], html)
    out = HERE / page["out"]
    out.parent.mkdir(exist_ok=True)
    out.write_text(html)

today = datetime.date.today().isoformat()
links = "".join(f'    <xhtml:link rel="alternate" hreflang="{p["lang"]}" href="{SITE}{p["path"]}"/>\n' for p in PAGES.values())
links += f'    <xhtml:link rel="alternate" hreflang="x-default" href="{SITE}/"/>\n'
urls = "".join(f"  <url>\n    <loc>{SITE}{p['path']}</loc>\n    <lastmod>{today}</lastmod>\n{links}  </url>\n" for p in PAGES.values())
(HERE / "public/sitemap.xml").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
    f"{urls}</urlset>\n"
)
