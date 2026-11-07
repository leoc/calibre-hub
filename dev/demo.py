#!/usr/bin/env python3
"""The demo library and the files of the Eingang, for dev/up.

Usage: demo.py <out> <books.tsv> <spec fixtures>. Writes <out>/calibre,
<out>/backlog and <out>/inbox. Runs in the sandbox (dev/lib.sh) with calibre on
the path: nothing here touches a real library, and all text is generated, only
titles of old books are real. What each file in the Eingang is for stands next
to it below; dev/up copies the result, so it runs once.
"""
import os
import random
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

OUT = Path(sys.argv[1])
BOOKS = Path(sys.argv[2])
FIXTURES = Path(sys.argv[3])
LIBRARY = OUT / "calibre"
BACKLOG = OUT / "backlog"
INBOX = OUT / "inbox"
WORK = OUT / "work"
# older than the Eingang's two minutes for a file still being copied
OLD = 1_700_000_000

WORDS = {
    "deu": "der die das und ein eine Zeit Haus Weg Licht Nacht Fluss Stadt Brief Mann Frau Kind Herz Hand "
    "ging sah sprach kam blieb wusste dachte hörte über unter nach vor langsam still fern tief".split(),
    "eng": "the a and of to in time house road light night river town letter man woman child heart hand "
    "went saw spoke came stayed knew thought heard over under after before slowly still far deep".split(),
}


def run(*args, **kw):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True, **kw).stdout


def text(title, author, language="deu", chapters=6, seed=None, title_page=True):
    """A book's text; the same for the same seed, so two files can be one."""
    r = random.Random(seed or title)
    words = WORDS[language]
    head = f"# {title}\n\n{author}\n\n" if title_page else ""
    body = []
    for c in range(1, chapters + 1):
        sentences = [" ".join(r.choices(words, k=r.randint(8, 16))).capitalize() + "." for _ in range(60)]
        paragraphs = [" ".join(sentences[i : i + 6]) for i in range(0, 60, 6)]
        body.append(f"## {'Kapitel' if language == 'deu' else 'Chapter'} {c}\n\n" + "\n\n".join(paragraphs))
    return head + "\n\n".join(body) + "\n"


_n = iter(range(1, 100000))


def convert(target, title, author, *, language="deu", content=None, series="", index="", tags="", publisher="", year="", isbn="", cover=True):
    """An e-book from generated text, with these metadata in it"""
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    source = WORK / f"src-{next(_n)}.txt"
    source.write_text(content or text(title, author, language))
    args = ["ebook-convert", source, target, "--formatting-type", "markdown", "--title", title, "--authors", author, "--language", language]
    for flag, value in (("--series", series), ("--series-index", index), ("--tags", tags), ("--publisher", publisher), ("--isbn", isbn)):
        if value:
            args += [flag, value]
    if year:
        args += ["--pubdate", f"{year}-01-01"]
    if not cover and target.suffix == ".epub":
        args.append("--no-default-epub-cover")
    run(*args)
    return target


def read_books():
    rows = []
    for line in BOOKS.read_text().splitlines():
        if line and not line.startswith("#"):
            author, title, series, index, kategorie, tags, language, publisher, year, formats = line.split("\t")
            rows.append(dict(author=author, title=title, series=series, index=index, kategorie=kategorie, tags=tags, language=language, publisher=publisher, year=year, formats=formats.split(",")))
    return rows


def make_library():
    books = read_books()
    run("calibredb", "--with-library", LIBRARY, "list")
    run("calibredb", "--with-library", LIBRARY, "add_custom_column", "kategorie", "Kategorie", "text")

    def files(n_book):
        n, b = n_book
        made = []
        for fmt in b["formats"]:
            made.append(convert(WORK / f"book{n}" / f"book.{fmt.lower()}", b["title"], b["author"], language=b["language"], series=b["series"], index=b["index"], tags=b["tags"], publisher=b["publisher"], year=b["year"]))
        return made

    with ThreadPoolExecutor(6) as pool:
        made = list(pool.map(files, enumerate(books)))
    # one process each: calibredb takes about a second to start
    run("calibredb", "--with-library", LIBRARY, "add", "--duplicates", *[m[0] for m in made])
    script = WORK / "fill.py"
    script.write_text(
        """
import json, sys
from calibre.library import db
api = db(sys.argv[1]).new_api
by_title = {api.field_for('title', i): i for i in api.all_book_ids()}
values = {}
for b in json.load(open(sys.argv[2])):
    i = by_title[b['title']]
    values[i] = b['kategorie']
    for f in b['more']:
        api.add_format(i, f.rsplit('.', 1)[1].upper(), f)
api.set_field('#kategorie', values)
"""
    )
    import json

    plan = WORK / "fill.json"
    plan.write_text(json.dumps([{"title": b["title"], "kategorie": b["kategorie"], "more": [str(p) for p in m[1:]]} for b, m in zip(books, made)]))
    run("calibre-debug", "-c", f"import runpy, sys; sys.argv = ['fill', {str(LIBRARY)!r}, {str(plan)!r}]; runpy.run_path({str(script)!r}, run_name='__main__')")
    return books


def library_file(title, ext="epub"):
    """A book's file as the library has it"""
    found = [p for p in LIBRARY.rglob(f"*.{ext}") if p.stem.startswith(title.split(".")[0][:20].replace(":", "_"))]
    if not found:
        raise SystemExit(f"demo: no {ext} of {title} in the library")
    return found[0]


def embed(title):
    """What the hub does after an edit: same book, other bytes"""
    ids = run("calibredb", "--with-library", LIBRARY, "search", f'title:"={title}"').strip()
    run("calibredb", "--with-library", LIBRARY, "embed_metadata", ids)


def scan(target, pdf, pages=6):
    """A PDF of page images, no text layer, like a scanner's"""
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    work = WORK / f"scan-{next(_n)}"
    work.mkdir()
    run("pdftoppm", "-r", "110", "-gray", "-l", pages, "-png", pdf, work / "p")
    run("magick", *sorted(work.glob("p*.png")), "-compress", "jpeg", "-quality", "60", target)
    # ImageMagick signs as the author
    run("ebook-meta", target, "--authors", "Unknown")


def large_pdf(target, title, author):
    """Over the hub's 8 MB for first pages, and over their 30 pages"""
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    book = convert(WORK / "large-text.pdf", title, author, content=text(title, author, chapters=20))
    noise = WORK / "noise.pdf"
    run("magick", "-size", "500x700", "xc:gray", "+noise", "Random", "-quality", "30", noise)
    run("pdfunite", book, *[noise] * 90, target)


def djvu_book(target, pages):
    """The fixture's page, again and again: more pages than a look shows"""
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    run("djvm", "-c", target, *[FIXTURES / "scan.djvu"] * pages)


def make_backlog():
    def d(path):
        return BACKLOG / path

    cases = [
        # sure: the file's metadata and its name say the same
        lambda: convert(d("Adalbert Stifter - Der Nachsommer.epub"), "Der Nachsommer", "Adalbert Stifter", publisher="Heckenast", year="1857"),
        lambda: convert(d("Wilhelm Raabe - Stopfkuchen.epub"), "Stopfkuchen", "Wilhelm Raabe", publisher="Janke", year="1891"),
        lambda: convert(d("Klassiker/Eduard Mörike - Mozart auf der Reise nach Prag.epub"), "Mozart auf der Reise nach Prag", "Eduard Mörike"),
        lambda: convert(d("Klassiker/Joseph von Eichendorff - Aus dem Leben eines Taugenichts.epub"), "Aus dem Leben eines Taugenichts", "Joseph von Eichendorff"),
        lambda: convert(d("Klassiker/Novalis - Heinrich von Ofterdingen.pdf"), "Heinrich von Ofterdingen", "Novalis"),
        lambda: convert(d("English/Lewis Carroll - Through the Looking-Glass.epub"), "Through the Looking-Glass", "Lewis Carroll", language="eng"),
        # to review: good metadata under a name that says nothing, a clear
        # name without metadata, a live-style name with noise in it
        lambda: convert(d("Unsortiert/x3f9q.epub"), "Der Sandmann", "E. T. A. Hoffmann"),
        lambda: convert(d("Unsortiert/Theodor Storm - Der Schimmelreiter.pdf"), "Unknown", "Unknown", content=text("Der Schimmelreiter", "Theodor Storm")),
        lambda: convert(d("Die Elixiere des Teufels - E.T.A. Hoffmann (Duncker, 1815) WW.epub"), "Die Elixiere des Teufels", "E. T. A. Hoffmann", publisher="Duncker"),
        # unsure: nothing in the file, nothing in the name
        lambda: convert(d("Unsortiert/1380293052863.pdf"), "Unknown", "Unknown", content=text("", "", title_page=False)),
        lambda: convert(d("Unsortiert/download (3).epub"), "Unknown", "Unknown", content=text("", "", title_page=False, seed="download")),
        # two copies of one file, the library doesn't have it
        lambda: copy_twins(),
        # the calibre folder of an old library
        lambda: calibre_folder(),
        # a large PDF: the reader takes its first pages
        lambda: large_pdf(d("Alexander von Humboldt - Kosmos.pdf"), "Kosmos", "Alexander von Humboldt"),
    ]
    with ThreadPoolExecutor(6) as pool:
        list(pool.map(lambda case: case(), cases))

    # a scan without a text layer, read by OCR: a book's pages, and the specs' page
    title_pages = convert(WORK / "scanned.pdf", "Der arme Spielmann", "Franz Grillparzer", content=text("Der arme Spielmann", "Franz Grillparzer"))
    scan(d("Scans/Scan_0042.pdf"), title_pages)
    (d("Scans")).mkdir(exist_ok=True)
    shutil.copy(FIXTURES / "scan.pdf", d("Scans/Scan_0043.pdf"))
    # DjVu: short, and long enough for first pages
    shutil.copy(FIXTURES / "scan.djvu", d("Scans/Seite.djvu"))
    djvu_book(d("Scans/Handbuch der Fotografie.djvu"), 35)

    # byte for byte a file of the library: leaves for the trash folder by itself
    (d("Kopien")).mkdir(exist_ok=True)
    shutil.copy(library_file("Woyzeck"), d("Kopien/Woyzeck.epub"))
    shutil.copy(library_file("Lenz"), d("Kopien/Georg Büchner - Lenz (Kopie).epub"))
    # the same book, its metadata embedded by calibre since: other bytes
    original = library_file("Die Verwandlung")
    shutil.copy(original, d("Kopien/Franz Kafka - Die Verwandlung.epub"))
    embed("Die Verwandlung")
    # a possible duplicate: the title, one of the authors; and what the hub
    # takes for a book of its own, one letter off
    convert(d("Dubletten/Oliver Twist - Charles Dickens, George Cruikshank.epub"), "Oliver Twist", "Charles Dickens & George Cruikshank", language="eng")
    convert(d("Dubletten/Franz Kafka - Der Prozess.epub"), "Der Prozess", "Franz Kafka", content=text("Der Prozess", "Franz Kafka", seed="neu"))
    # same title and authors, another edition: same format, a further format
    convert(d("Dubletten/Theodor Fontane - Effi Briest (andere Ausgabe).epub"), "Effi Briest", "Theodor Fontane", content=text("Effi Briest", "Theodor Fontane", seed="zweite Ausgabe"), publisher="Reclam")
    convert(d("Dubletten/Karl May - Winnetou I.pdf"), "Winnetou I", "Karl May", content=text("Winnetou I", "Karl May", seed="pdf"))

    # broken: not what the name says, a PDF that ends early, a zip with nothing in it
    (d("Kaputt")).mkdir(exist_ok=True)
    d("Kaputt/kaputt.pdf").write_bytes(b"this is no PDF\n" * 400)
    d("Kaputt/abgebrochen.pdf").write_bytes(b"%PDF-1.4\n" + random.Random(1).randbytes(8000))
    d("Kaputt/kaputt.epub").write_bytes(b"PK\x03\x04" + random.Random(2).randbytes(8000))

    # not books: they stay where they are
    d("Klassiker/Liesmich.nfo").write_text("Keine Bücher, nur eine Notiz.\n")


def copy_twins():
    twin = convert(BACKLOG / "Sammlung A/Gustav Freytag - Soll und Haben.epub", "Soll und Haben", "Gustav Freytag")
    (BACKLOG / "Sammlung B").mkdir(exist_ok=True)
    shutil.copy(twin, BACKLOG / "Sammlung B/Gustav Freytag - Soll und Haben.epub")


def calibre_folder():
    folder = BACKLOG / "Alte Bibliothek/Jean Paul/Titan (42)"
    book = convert(folder / "Titan - Jean Paul.epub", "Titan", "Jean Paul", publisher="Matzdorff", year="1800")
    meta = run("ebook-meta", book, "--to-opf", "/dev/stdout")
    (folder / "metadata.opf").write_text(meta[meta.index("<?xml") :] if "<?xml" in meta else meta)
    run("ebook-meta", book, "--get-cover", folder / "cover.jpg")


def make_inbox():
    # sorted into folders like over Samba on dmt; the sure one goes to the library by itself
    convert(INBOX / "Roman/Krimi/Friedrich Glauser - Wachtmeister Studer.epub", "Wachtmeister Studer", "Friedrich Glauser", publisher="Morgarten")
    convert(INBOX / "Fachbuch/Mathematik/f7a1.epub", "Theorie der Parallellinien", "Johann Heinrich Lambert")
    (INBOX / "Roman").mkdir(exist_ok=True)
    # byte for byte in the library: to _duplicates
    shutil.copy(library_file("Der Stechlin"), INBOX / "Roman/Der Stechlin.epub")
    (INBOX / "kaputt.pdf").write_bytes(b"%PDF-1.4\n" + random.Random(3).randbytes(8000))


def settle():
    """As on dmt: folders 2775, files group-writable, not just written"""
    for root in (BACKLOG, INBOX):
        for path in [root, *root.rglob("*")]:
            path.chmod(0o2775 if path.is_dir() else 0o664)
        for path in sorted(root.rglob("*"), reverse=True):
            os.utime(path, (OLD, OLD))


def main():
    WORK.mkdir(parents=True)
    make_library()
    make_backlog()
    make_inbox()
    settle()
    shutil.rmtree(WORK)
    print(f"demo: {sum(1 for _ in BACKLOG.rglob('*') if _.is_file())} files in the backlog, {sum(1 for _ in INBOX.rglob('*') if _.is_file())} in the inbox")


main()
