#!/bin/bash
# i finally have switched to a shell-script-based build :/

export OS="ULOS"
export DATE="$(date +%y.%m)"
export ULOSREL="1.6"
export ULOSVERSION="$OS $DATE-$ULOSREL"
export PREPROCESSOR="$PWD/utils/proc.lua"

ogdir=$PWD
external="cldr corelibs coreutils manpages upm"
tobuild="cynosure external/usysd"

build() {
  printf ":: building $1\n"
  cd $1; ./build.sh; cd $ogdir
}

rm -rf out && mkdir -p out/boot
for b in $tobuild; do
  build $b
done

for ext in $external; do
  cp -r external/${ext}/* out/
done

cp cynosure/kernel.lua out/boot/cynosure.lua
cp -r external/usysd/out/* out/
echo "VERSION=\"$ULOSVERSION\"" | cat external/os-release - > out/etc/os-release
