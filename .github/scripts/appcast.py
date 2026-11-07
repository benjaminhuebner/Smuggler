#!/usr/bin/env python3
import argparse
import email.utils
import plistlib
import re
import sys
from datetime import datetime
from xml.dom import minidom

EMPTY_FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Smuggler</title>
        <link>https://smuggler.benjaminhuebner.com/appcast.xml</link>
        <description>Updates for Smuggler</description>
    </channel>
</rss>
"""
GERMAN_HEADING = re.compile(r"^#{1,6}[ \t]*(?:deutsch|german)[ \t#]*$", re.IGNORECASE | re.MULTILINE)
ENGLISH_HEADING = re.compile(r"^#{1,6}[ \t]*(?:english|englisch)[ \t#]*$", re.IGNORECASE | re.MULTILINE)
COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
ITEM_INDENT = "\n" + " " * 8
CHILD_INDENT = "\n" + " " * 12


def split_notes(body):
    text = COMMENT.sub("", body.replace("\r\n", "\n"))
    german = GERMAN_HEADING.search(text)
    english_text = ENGLISH_HEADING.sub("", text[: german.start()] if german else text, count=1).strip()
    german_text = text[german.end() :].strip() if german else ""
    return english_text or german_text, german_text or english_text


def element(doc, name, text=None, attributes=()):
    node = doc.createElement(name)
    for key, value in attributes:
        node.setAttribute(key, value)
    if text is not None:
        node.appendChild(doc.createTextNode(text))
    return node


def description(doc, language, notes):
    node = element(doc, "description", attributes=[("xml:lang", language), ("sparkle:format", "markdown")])
    # "]]>" would end the CDATA section; markdown turns the entity back into ">".
    node.appendChild(doc.createCDATASection("\n" + notes.replace("]]>", "]]&gt;") + "\n"))
    return node


def build_item(doc, info, args, notes):
    version = info["CFBundleShortVersionString"]
    minimum = info["LSMinimumSystemVersion"]
    minimum += ".0" * (2 - minimum.count("."))
    published = datetime.fromisoformat(args.published.replace("Z", "+00:00"))
    english, german = notes
    children = [element(doc, "title", f"Version {version}")]
    if english:
        children += [description(doc, "en", english), description(doc, "de", german)]
    children += [
        element(doc, "pubDate", email.utils.format_datetime(published)),
        element(doc, "sparkle:version", info["CFBundleVersion"]),
        element(doc, "sparkle:shortVersionString", version),
        element(doc, "sparkle:minimumSystemVersion", minimum),
        element(
            doc,
            "enclosure",
            attributes=[
                ("url", args.url),
                ("sparkle:edSignature", args.signature),
                ("length", str(args.length)),
                ("type", "application/octet-stream"),
            ],
        ),
    ]
    item = doc.createElement("item")
    for child in children:
        item.appendChild(doc.createTextNode(CHILD_INDENT))
        item.appendChild(child)
    item.appendChild(doc.createTextNode(ITEM_INDENT))
    return item


def add(args):
    if not args.signature or args.length <= 0:
        sys.exit("error: the update archive needs a signature and a length")
    with open(f"{args.app}/Contents/Info.plist", "rb") as file:
        info = plistlib.load(file)
    if info["CFBundleShortVersionString"] != args.expect_version:
        sys.exit(f"error: the archive holds {info['CFBundleShortVersionString']}, expected {args.expect_version}")
    with open(args.notes, encoding="utf-8") as file:
        notes = split_notes(file.read())
    doc = minidom.parse(args.appcast)
    channel = doc.getElementsByTagName("channel")[0]
    item = build_item(doc, info, args, notes)
    newest = next((n for n in channel.childNodes if n.nodeType == n.ELEMENT_NODE and n.tagName == "item"), None)
    if newest is not None:
        channel.insertBefore(item, newest)
        channel.insertBefore(doc.createTextNode(ITEM_INDENT), newest)
    else:
        closing = channel.lastChild
        channel.insertBefore(doc.createTextNode(ITEM_INDENT), closing)
        channel.insertBefore(item, closing)
    with open(args.appcast, "wb") as file:
        file.write(doc.toxml(encoding="utf-8") + b"\n")


def main():
    parser = argparse.ArgumentParser(description="Write Smuggler's Sparkle appcast, newest item first.")
    commands = parser.add_subparsers(dest="command", required=True)
    new = commands.add_parser("new", help="start an appcast without items")
    new.add_argument("appcast")
    item = commands.add_parser("add", help="put a release's item on top")
    item.add_argument("appcast")
    item.add_argument("--app", required=True, help="Smuggler.app inside the mounted update archive")
    item.add_argument("--expect-version", required=True, help="version the release tag names")
    item.add_argument("--url", required=True)
    item.add_argument("--length", required=True, type=int)
    item.add_argument("--signature", required=True, help="EdDSA signature of the update archive")
    item.add_argument("--published", required=True, help="ISO 8601 publication time")
    item.add_argument("--notes", required=True, help='markdown file; a "## Deutsch" section holds the German notes')
    args = parser.parse_args()
    if args.command == "new":
        with open(args.appcast, "w", encoding="utf-8") as file:
            file.write(EMPTY_FEED)
    else:
        add(args)


if __name__ == "__main__":
    main()
