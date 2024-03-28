#!/bin/bash -i

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

echo 'export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"' >> ~/.profile
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
brew analytics off
