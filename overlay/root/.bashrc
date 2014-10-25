#!/bin/bash
git clone http://israellevin@github.com/israellevin/dotfiles
cp dotfiles/.* .
cp -r dotfiles/bin/ .
git clone http://github.com/clvv/fasd
mv fasd/fasd /usr/bin/.
rm -rf fasd
bash
exit
