# Installing Arctic Archive for Doom Emacs

## 1. Copy the themes

Create Doom's personal theme folder if it does not already exist. For a current
default installation:

```sh
mkdir -p ~/.config/doom/themes
```

If you set `DOOMDIR`, use its `themes` subfolder instead:

```text
$DOOMDIR/themes/
```

Older installations often use:

```text
~/.doom.d/themes/
```

Copy both files into that folder:

```text
arctic-archive-dark-theme.el
arctic-archive-light-theme.el
```

## 2. Choose a theme

Add one of these lines to `$DOOMDIR/config.el`.

Dark:

```elisp
(setq doom-theme 'arctic-archive-dark)
```

Light:

```elisp
(setq doom-theme 'arctic-archive-light)
```

The theme name does not include the `-theme.el` filename suffix.

## 3. Load or reload it

Restart Emacs, or evaluate the `setq` form and run:

```text
M-x doom/reload-theme
```

You can also test either theme without changing `config.el`:

```text
M-x load-theme RET arctic-archive-dark RET
```

Replacing an existing theme file normally requires only
`M-x doom/reload-theme`; `doom sync` is not required. Run `doom sync` from a
terminal after changing Doom modules or packages, or if your Doom installation
specifically reports that its generated files are out of date. Then restart
Emacs.

## Optional: modeline padding

Both files follow Doom's global `doom-themes-padded-modeline` setting. You can
also control them individually. Put the setting before `doom-theme` in
`config.el`:

```elisp
(setq arctic-archive-dark-padded-modeline 4
      doom-theme 'arctic-archive-dark)
```

Use `nil` for no padding, `t` for four pixels, or an integer for a specific
amount. The active doom-modeline bar uses Arctic Archive cobalt; modified,
warning, and error states use copper, amber, and red.

## Optional: fonts

The themes do not change fonts. A quiet starting point is a monospaced face for
code and a separate variable-pitch face for prose:

```elisp
(setq doom-font (font-spec :family "Iosevka" :size 14)
      doom-variable-pitch-font (font-spec :family "Avenir Next" :size 14))
```

Use fonts installed on your system. After changing them, run:

```text
M-x doom/reload-font
```
