# --- Dark Blue Theme ---

set -l bg 121212
set -l fg dcdcdc

set -l blue 00afff
set -l cyan 00d7ff
set -l green 5fff87
set -l yellow ffd75f
set -l red ff5f5f

set -l gray 808080
set -l gray_dark 5f5f5f

set -g fish_color_normal $fg

set -g fish_color_command $blue
set -g fish_color_param $fg

set -g fish_color_keyword $cyan
set -g fish_color_quote $green

set -g fish_color_redirection $cyan
set -g fish_color_end $yellow

set -g fish_color_error $red

set -g fish_color_operator $cyan
set -g fish_color_escape $yellow

set -g fish_color_autosuggestion $gray
set -g fish_color_search_match --background=$gray_dark

set -g fish_color_selection --background=$gray_dark
