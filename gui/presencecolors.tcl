# Colour per presence show state, shared by everything that paints one: the
# MUC participant list and the legend that explains it.
proc presence_colors {} {
    return {
        available green4
        away      goldenrod3
        xa        darkorange3
        dnd       red3
        offline   gray50
    }
}
