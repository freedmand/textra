
#!/usr/bin/env bash
# Script adapted from Bun for use with textra: https://bun.sh/install
set -euo pipefail


# Reset
Color_Off=''

# Regular Colors
Red=''
Green=''
Dim='' # White

# Bold
Bold_White=''
Bold_Green=''

if [[ -t 1 ]]; then
    # Reset
    Color_Off='\033[0m' # Text Reset

    # Regular Colors
    Red='\033[0;31m'   # Red
    Green='\033[0;32m' # Green
    Dim='\033[0;2m'    # White

    # Bold
    Bold_Green='\033[1;32m' # Bold Green
    Bold_White='\033[1m'    # Bold White
fi

error() {
    echo -e "${Red}error${Color_Off}:" "$@" >&2
    exit 1
}

info() {
    echo -e "${Dim}$@ ${Color_Off}"
}

info_bold() {
    echo -e "${Bold_White}$@ ${Color_Off}"
}

success() {
    echo -e "${Green}$@ ${Color_Off}"
}

command -v unzip >/dev/null ||
    error 'unzip is required to install textra. This can be installed with Homebrew: https://formulae.brew.sh/formula/unzip'

if [[ $# -gt 1 ]]; then
    error 'Too many arguments, only 1 is allowed'
fi

# Check if the OS is macOS
if [[ $(uname) != "Darwin" ]]; then
    error 'Mac OS is required to run textra'
fi


# Check if the Mac OS version is greater than or equal to 13
if [[ $(sw_vers -productVersion | cut -d . -f 1) -lt 13 ]]; then
    error 'Mac OS 13 or greater is required to run textra since it depends on Apple''s updated Vision APIs. Please upgrade your Mac and try again.'
fi

download_uri="https://github.com/freedmand/textra/releases/download/0.0.2/textra-0.0.2.zip"

install_env=TEXTRA_INSTALL
bin_env=\$$install_env/bin

install_dir=${!install_env:-$HOME/.textra}
bin_dir=$install_dir/bin
exe=$bin_dir/textra

if [[ ! -d $bin_dir ]]; then
    mkdir -p "$bin_dir" ||
        error "Failed to create install directory \"$bin_dir\""
fi

curl --fail --location --progress-bar --output "$exe.zip" "$download_uri" ||
    error "Failed to download textra from \"$download_uri\""

unzip -oqd "$bin_dir" "$exe.zip" ||
    error 'Failed to extract textra'

mv "$bin_dir/textra" "$exe" ||
    error 'Failed to move extracted textra to destination'

chmod +x "$exe" ||
    error 'Failed to set permissions on textra executable'

rm "$exe.zip"

tildify() {
    if [[ $1 = $HOME/* ]]; then
        local replacement=\~/

        echo "${1/$HOME\//$replacement}"
    else
        echo "$1"
    fi
}

success "textra was installed successfully to $Bold_Green$(tildify "$exe")"

if command -v textra >/dev/null; then
    echo "Run 'textra' to get started"
    exit
fi

refresh_command=''

tilde_bin_dir=$(tildify "$bin_dir")
quoted_install_dir=\"${install_dir//\"/\\\"}\"

if [[ $quoted_install_dir = \"$HOME/* ]]; then
    quoted_install_dir=${quoted_install_dir/$HOME\//\$HOME/}
fi

echo

case $(basename "$SHELL") in
fish)
    commands=(
        "set --export $install_env $quoted_install_dir"
        "set --export PATH $bin_env \$PATH"
    )

    fish_config=$HOME/.config/fish/config.fish
    tilde_fish_config=$(tildify "$fish_config")

    if [[ -w $fish_config ]]; then
        {
            echo -e '\n# textra'

            for command in "${commands[@]}"; do
                echo "$command"
            done
        } >>"$fish_config"

        info "Added \"$tilde_bin_dir\" to \$PATH in \"$tilde_fish_config\""

        refresh_command="source $tilde_fish_config"
    else
        echo "Manually add the directory to $tilde_fish_config (or similar):"

        for command in "${commands[@]}"; do
            info_bold "  $command"
        done
    fi
    ;;
zsh)
    commands=(
        "export $install_env=$quoted_install_dir"
        "export PATH=\"$bin_env:\$PATH\""
    )

    zsh_config=$HOME/.zshrc
    tilde_zsh_config=$(tildify "$zsh_config")

    if [[ -w $zsh_config ]]; then
        {
            echo -e '\n# textra'

            for command in "${commands[@]}"; do
                echo "$command"
            done
        } >>"$zsh_config"

        info "Added \"$tilde_bin_dir\" to \$PATH in \"$tilde_zsh_config\""

        refresh_command="exec $SHELL"
    else
        echo "Manually add the directory to $tilde_zsh_config (or similar):"

        for command in "${commands[@]}"; do
            info_bold "  $command"
        done
    fi
    ;;
*)
    echo 'Manually add the directory to ~/.bashrc (or similar):'
    info_bold "  export $install_env=$quoted_install_dir"
    info_bold "  export PATH=\"$bin_env:\$PATH\""
    ;;
esac

echo
info "To get started, run:"
echo

if [[ $refresh_command ]]; then
    info_bold "  $refresh_command"
fi

info_bold "  textra"
