# Copyright Francesco Di Blasi 2026 - All Rights Reserved

"""Generate the native Tweaker's editor Help data from its class XML."""

from runpy import run_path
import sys


if __name__ == "__main__":
    generator, output, *sources = sys.argv[1:]
    run_path(generator)["generate_doc_source"](output, sources)
