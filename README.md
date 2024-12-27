# mho-dotfiles
My dotfiles managed by GNU Stow

Using the ~-t~ (target) option and setting it to the home directory and
then calling the name of the path to stow.

## Example
```shell
stow -t ~ doom
```
## texmf

```shell
stow -t /usr/local/texlive/texmf-local/tex/latex/local/ texmf 
```

## Typst
Typst looks for all local packages in the `~/Library/Application \ Support`path as per the [Typst documentation](https://github.com/typst/packages).
```shell
stow -t "$HOME/Library/Application Support/" typst
```

There are currently two custom local packages:
1. [mho-notes](typst/typst/packages/local/mho-notes/0.1.0)
2. [nord](/typst/typst/packages/local/nord/0.1.0)

## Beorg 
To Access Beorg on macOS, I use a symbolic link.
```shell
ln -s ~/Library/Mobile\ Documents/iCloud\~com\~appsonthemove\~beorg/Documents ~/Documents/Beorg 
```
