#!/bin/bash
# i finally have switched to a shell-script-based build :/

source utils/env.sh

ogdir=$PWD
external="cldr corelibs coreutils manpages upm uwm gpuproxy"
tobuild="cynosure external/usysd"

build() {
  printf ":: building $1\n"
  cd $1; ./build.sh; cd $ogdir
}

rm -rf out && mkdir -p out/{r,b}oot
for b in $tobuild; do
  build $b
done

for ext in $external; do
  cp -r external/${ext}/* out/
done

cp cynosure/kernel.lua out/boot/cynosure.lua
cp -rv external/usysd/out/* out/
echo "VERSION=\"$ULOSVERSION\"" | cat external/os-release - > out/etc/os-release
