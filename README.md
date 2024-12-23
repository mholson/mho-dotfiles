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

## Beorg 
To Access Beorg on macOS, I use a symbolic link.
```shell
ln -s ~/Library/Mobile\ Documents/iCloud\~com\~appsonthemove\~beorg/Documents ~/Documents/Beorg 
```
