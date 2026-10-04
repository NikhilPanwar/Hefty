import json, os, re
# Regenerates ../index.html, robots.txt and sitemap.xml from page.html + faq.json.
# Run: python3 landing-page/_src/build.py
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
URL = "https://nikhilpanwar.github.io/Hefty/"
REPO = "https://github.com/NikhilPanwar/Hefty"
s = open(__import__('os').path.join(__import__('os').path.dirname(__file__),'page.html')).read()
style_end = s.index('</style>') + len('</style>')
head_part, body_part = s[:style_end], s[style_end:]
# drop artifact title/description; replaced by SEO versions below
head_part = re.sub(r'<title>.*?</title>\n', '', head_part)
head_part = re.sub(r'<meta name="description"[^>]*>\n', '', head_part)
title = "Hefty: Large File Editor for Mac | Open Multi-GB Logs, SQL, CSV & JSON"
desc = "Free, open-source large file editor for Mac. Open, search and edit huge 10 GB to 100 GB text files, log files, SQL dumps, CSV and JSON on macOS in seconds."
faq = json.load(open(__import__('os').path.join(__import__('os').path.dirname(__file__),'faq.json')))
ld = [
 {"@context":"https://schema.org","@type":"SoftwareApplication","name":"Hefty","alternateName":"Hefty for Mac",
  "description":desc,"applicationCategory":"DeveloperApplication","applicationSubCategory":"Text editor",
  "operatingSystem":"macOS 13 or later","softwareVersion":"1.0.0","url":URL,"downloadUrl":REPO+"/releases/latest",
  "installUrl":REPO+"/releases/latest","codeRepository":REPO,"isAccessibleForFree":True,"image":URL+"hefty-icon-1024.png",
  "offers":{"@type":"Offer","price":"0","priceCurrency":"USD"},
  "featureList":["Open multi-GB and 100 GB text files instantly","Large log file viewer that follows growing files","Edit large SQL dumps","Open large CSV files without Excel","Pretty-print large JSON","Regex find and replace across huge files","Undo and redo","Word wrap","Syntax highlighting for SQL, JSON, XML and CSV","25 text encodings"],
  "keywords":"large file editor mac, big file viewer mac, open large text file mac, huge log file viewer, large csv viewer mac, sql dump editor, EmEditor alternative mac"},
 {"@context":"https://schema.org","@type":"FAQPage","mainEntity":[{"@type":"Question","name":q,"acceptedAnswer":{"@type":"Answer","text":a}} for q,a in faq]},
 {"@context":"https://schema.org","@type":"WebSite","name":"Hefty","url":URL},
]
head = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{title}</title>
<meta name="description" content="{desc}">
<meta name="keywords" content="large file editor mac, open large text file mac, big file viewer mac, huge file editor macos, multi gb file opener, 10gb text file mac, 100gb file editor, large log file viewer mac, open large csv mac, large json viewer mac, sql dump editor mac, emeditor for mac, emeditor alternative mac, ultraedit alternative mac">
<meta name="robots" content="index, follow, max-image-preview:large">
<meta name="theme-color" content="#0B1322">
<link rel="canonical" href="{URL}">
<link rel="apple-touch-icon" href="hefty-icon-1024.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Hefty">
<meta property="og:url" content="{URL}">
<meta property="og:title" content="Hefty: open the file nothing else can">
<meta property="og:description" content="{desc}">
<meta property="og:image" content="{URL}og-image.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:type" content="image/png">
<meta property="og:image:alt" content="Hefty, a free Mac editor for huge log files, SQL dumps, CSV and JSON. Opens a 10 GB file in under 3 seconds using 72 MB of RAM.">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="Hefty: large file editor for Mac">
<meta name="twitter:description" content="{desc}">
<meta name="twitter:image" content="{URL}og-image.png">
<meta name="twitter:image:alt" content="Hefty, a free Mac editor for huge log files, SQL dumps, CSV and JSON.">
<script type="application/ld+json">{json.dumps(ld, ensure_ascii=False)}</script>
'''
out = head + head_part + '\n</head>\n<body>' + body_part + '\n</body>\n</html>\n'
open(os.path.join(OUT,'index.html'),'w').write(out)
open(os.path.join(OUT,'robots.txt'),'w').write(f"User-agent: *\nAllow: /\n\nSitemap: {URL}sitemap.xml\n")
open(os.path.join(OUT,'sitemap.xml'),'w').write(f'''<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>{URL}</loc><lastmod>2026-10-04</lastmod><changefreq>weekly</changefreq><priority>1.0</priority></url>
</urlset>
''')
open(os.path.join(OUT,'.nojekyll'),'w').write('')
