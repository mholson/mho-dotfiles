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

