paths="manpages coresvc upm uwm gpuproxy bsh"

rm -rf webman
mkdir -p webman

htmlbase="
<!DOCTYPE html>

<link rel='stylesheet' href='https://oz-craft.pickardayune.com/man/ulos/style.css'>

<html>
  <title>ULOS Manual Pages</title>
  <body>
    ULOS Manual Pages - Directory listing | <a href='..'>Back</a><br><br>
    In this directory:<br>
"

htmlend="
    <br><span style='text-style:italic'>This page was auto-generated.</span>
  </body>
</html>
"

printf "$htmlbase" > webman/index.html
wget https://raw.githubusercontent.com/ocawesome101/ulos/master/style.css -O webman/style.css

for category in $(seq 1 9); do
  mkdir -p webman/$category
  printf "<a href='./%s'>%s</a>&nbsp;&nbsp;" $category $category >> webman/index.html
  printf "$htmlbase" > webman/$category/index.html
done

for name in $paths; do
  path=external/$name/usr/man/
  for category in $(ls $path); do
    for file in $(ls $path/$category); do
      utils/manfmt.lua $path/$category/$file > webman/$category/$file.html
      printf "<a href='./%s.html'>%s</a><br>" $file $file >> webman/$category/index.html
    done
  done
done

for category in $(seq 1 9); do
  printf "$htmlend" >> webman/$category/index.html
done

printf "$htmlend" >> webman/index.html

if [ "$1" = "upload" ]; then
  cd webman
  tar cf /tmp/man.tar ./*
  cd ..
  scp /tmp/man.tar meow:ozcraft/man/ulos
  ssh meow -tx "cd ozcraft/man/ulos; tar xf man.tar; rm man.tar"
fi
