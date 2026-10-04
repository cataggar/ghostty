import os
import pathlib
import sys

source, prefix = sys.argv[1:]
prefix = os.path.abspath(prefix)
sys.stdout.write(
    pathlib.Path(source).read_text().replace("@GHOSTTY_INSTALL_PREFIX@", prefix)
)
