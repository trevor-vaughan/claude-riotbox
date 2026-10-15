# scripts/lib/terminal-clean.jq — make container-written text safe to print.
#
# `clean` replaces with "?" every code point a terminal may act on: C0
# controls (newline included), DEL and C1 controls (U+0080-U+009F). It also
# replaces those that make printed text read differently from its bytes: the
# bidi controls (U+061C, U+200E, U+200F, U+202A-U+202E, U+2066-U+2069), the
# zero-width characters (U+200B-U+200D, U+FEFF) and the line and paragraph
# separators (U+2028, U+2029).
#
# `clean_text` is the same but keeps tab, for multi-line text such as a diff
# read line by line (`jq -R`), where the newline is the line separator.
#
# Used with `jq -L <this dir>` and `include "terminal-clean";` by
# scripts/git-ai-riotbox.sh (its text report) and by terminal_clean in
# scripts/lib/session-state.sh (session project paths, overlay-diff output).
def _terminal_unsafe_rest: "\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2066-\u2069\ufeff";
def clean: tostring | gsub("[\u0000-\u001f" + _terminal_unsafe_rest + "]"; "?");
def clean_text: tostring | gsub("[\u0000-\u0008\u000a-\u001f" + _terminal_unsafe_rest + "]"; "?");
