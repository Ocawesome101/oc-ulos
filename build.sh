#!/bin/bash
# i finally have switched to a shell-script-based build :/

source utils/env.sh

ogdir=$PWD
external="cldr/ corelibs/ coreutils/ manpages/ upm/ uwm/ gpuproxy/ bsh/ norris/ pkserv/"
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
  cp -r external/${ext}* out/
done

cd tle; ./standalone.lua; cd ..
cp tle/tle out/bin/tle.lua
mkdir -p out/usr/share
cp -r tle/syntax out/usr/share/VLE

cp cynosure/kernel.lua out/boot/cynosure.lua
cp -rv external/usysd/out/* out/
printf "VERSION=\"$ULOSVERSION\"\nBUILD_ID=\"$DATE\"\nVERSION_ID=\"$ULOSREL\"\n" | cat external/os-release - > out/etc/os-release
printf "ulos\n" > out/etc/hostname
