# ~/.zshrc
HISTFILE=~/.zsh_history HISTSIZE=10000 SAVEHIST=10000
setopt share_history hist_ignore_all_dups autocd
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
bindkey -e
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[3~' delete-char
PROMPT='%F{cyan}%n@%m%f %F{blue}%~%f %# '
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh   # must stay last
